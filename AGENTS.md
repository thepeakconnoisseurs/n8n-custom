# AGENTS.md — n8n-custom

Instruksi utama untuk AI/coding agent di repo ini. Repo ini **publik**:
semua konten di sini boleh dibaca siapa pun — JANGAN pernah menuliskan
secret, nilai `.env` asli, domain internal, atau konteks bisnis/operasional
private ke repo ini.

## 1. Identitas & kontrak pembagian tugas

Repo ini adalah **pabrik image Docker** untuk deployment n8n self-host
(queue mode). Ia **tidak menjalankan apa pun** — tidak ada container
produksi yang hidup dari sini.

Pembagian tugas yang disepakati (2026-09-04):

| Urusan | Di mana |
|---|---|
| Build & publish image (`Dockerfile`, `Dockerfile.runner`, config runner, CI) | **repo ini** (publik, GitHub) |
| Compose produksi yang berjalan, `.env` asli, update service/port/container baru, semua docs operasional | **repo deployment private terpisah** (lokal di server, tidak pernah dipublikasikan) |

Alur rilis satu-satunya:

```
push ke main (repo ini) → CI: gitleaks → build 2 image (base :stable)
  → resolve versi n8n aktual → push tag immutabel ke Docker Hub
  → DI REPO DEPLOYMENT: ganti 2 baris `image:` → docker compose up -d
```

**Agent tidak pernah mengedit repo deployment dari konteks repo ini**
dan sebaliknya. Perubahan di sini sampai ke produksi HANYA lewat pergantian
tag image di repo deployment.

## 2. Keputusan desain (ADR ringkas) — beserta buktinya

| # | Keputusan | Alasan & bukti |
|---|---|---|
| D1 | Base image memakai tag **`stable`** (bukan `latest`, bukan pin versi) | n8n merilis `n8nio/n8n:stable` dan `n8nio/runners:stable` **lockstep dari commit yang sama** — terverifikasi 2026-09-04 via Docker Hub API: digest `stable` == digest `2.37.9` di KEDUA image. Konsekuensi (ditangani di CI): versi aktual WAJIB di-resolve setelah build dan dijadikan tag immutabel, karena `stable` adalah tag bergerak. |
| D2 | Tag output immutabel: `<versi>` + `<versi>-<sha7>` + `latest` (pointer) | Rollback produksi = kembali ke tag versi lama. `latest` hanya kenyamanan, tidak dipakai sebagai satu-satunya acuan. |
| D3 | Runner **Playwright-only** (puppeteer/puppeteer-extra/stealth dihapus) | Keputusan owner 2026-09-04. Efek samping positif: flag keamanan `N8N_RUNNERS_ALLOW_PROTOTYPE_MUTATION` (docs n8n menyebut puppeteer sebagai contoh pemicunya) tidak perlu dinyalakan di awal. |
| D4 | Config runner berbasis **stock config resmi** (flag `--disallow-code-generation-from-strings` + `--disable-proto=delete` DIPERTAHANKAN) | Image lama (pendahulu) membuang flag itu demi puppeteer. Sekarang kembali ke default paling ketat; eskalasi hanya bila terbukti perlu (lihat §5). Baseline: `docker/images/runners/n8n-task-runners.json` di repo n8n-io/n8n (master). |
| D5 | **Tanpa autoscaler** (worker fixed, scale manual via `--scale`) | Keputusan owner 2026-09-04. Karena itu service worker & runner di compose referensi TIDAK memakai `container_name` (container_name memblokir `--scale`). |
| D6 | Image dipublish sebagai **`peakwine/n8n`** + **`peakwine/n8n-runner`** (namespace Docker Hub `peakwine`), tidak menimpa image lama | Konsisten dengan namespace image lain yang sudah dipakai (`peakwine/chatwoot`). Image lama (`trigidigital/tridi-n8n`/`tridi-n8n-runner`) tetap utuh = rollback absolut (tinggal kembalikan baris `image:` di repo deployment). |
| D7 | Repo publik sejak commit pertama | Sejarah bersih terjamin struktural. Konsekuensi: disiplin secret ketat (§10) + gerbang gitleaks di CI. |
| D8 | S3/Azure external storage TIDAK dipakai | Docs n8n: fitur berlisensi Business/Enterprise — n8n bahkan menolak start di mode `s3` tanpa lisensi. Edisi komunitas cukup dengan mode `database` (default queue mode sejak 2.0). |
| D9 | Multi-arch belum diaktifkan (amd64 saja) | Deployment target amd64; build QEMU arm64 memperlambat pipeline. Bisa ditambahkan nanti via buildx `--platform` bila dibutuhkan. |

## 3. Layout repo

```
Dockerfile                  # image utama (main/webhook/worker)
Dockerfile.runner           # image task runner (Code node, external mode)
n8n-task-runners.json       # config launcher runner (allowlist paket + flag node)
init-postgres.sh            # inisialisasi DB: pisahkan admin user vs app user
.github/workflows/build.yml # CI: gitleaks → build → resolve versi → push
scripts/build-local.sh      # builder lokal (resep sama dgn CI)
examples/                   # compose referensi + .env.example (untuk fresh install;
                            #   TIDAK mirror dari deployment produksi)
AGENTS.md / CLAUDE.md       # dokumen ini (CLAUDE.md = symlink ke AGENTS.md)
```

## 4. Isi image & mengapa polanya begitu

**Kenapa multi-stage `COPY --from=builder`?** Image resmi n8n (`n8nio/n8n`)
dan runner (`n8nio/runners` ≥ v2.1.0) dikirim **tanpa `apk`**. Satu-satunya
cara menambahkan binary sistem (chromium, ffmpeg, imagemagick, dll.) adalah
menyalinnya dari stage Alpine biasa — termasuk library shared `.so` dan
font. Ini pola yang diakui docs n8n (lihat "Adding extra dependencies" di
halaman *Set up task runners*).

**Paket npm/Python di runner** di-install langsung ke direktori runtime
runner (`/opt/runners/task-runner-javascript` via `pnpm add`, venv Python via
`uv pip install`) — boleh dilakukan tanpa apk sejak runners ≥ 1.121.0. Setiap
paket yang ditambahkan **wajib** juga masuk allowlist `n8n-task-runners.json`
(`NODE_FUNCTION_ALLOW_EXTERNAL` / `N8N_RUNNERS_EXTERNAL_ALLOW`), kalau tidak
Code node tidak bisa meng-importnya. Allowlist ada di file config, BUKAN env
container — itu ketentuan docs untuk external mode.

**Versi Alpine builder (`ARG ALPINE_VERSION=3.23`) harus cocok dengan Alpine
base image resmi.** Saat upgrade, cek dulu:
`docker run --rm n8nio/n8n:stable cat /etc/os-release`.

## 5. Task runner: tangga hardening (baca sebelum melonggarkan apa pun)

Urutan eskalasi bila library/aksi Code node gagal jalan — jangan langsung
loncat ke langkah terakhir:

1. **Default (kondisi sekarang):** flag stock utuh + TANPA
   `N8N_RUNNERS_ALLOW_PROTOTYPE_MUTATION`. Uji dulu di sini.
2. **Env-only:** set `N8N_RUNNERS_ALLOW_PROTOTYPE_MUTATION=true` pada
   environment container runner (bukan edit file config). Dokumentasikan
   library pemicunya di §11 (log).
3. **Terakhir, argumen node:** baru pertimbangkan melepas
   `--disable-proto=delete` dari `n8n-task-runners.json`. Ini pelonggaran
   permanen — wajib ADR baru di §2.

Gejala yang biasanya memicu: `playwright-extra` (sistem plugin-nya menambal
objek browser) gagal register plugin, error mengandung kata
`proto`/`prototype`/`not a function` pada proses inisialisasi library.

## 6. CI — syarat, gerbang, dan secrets

Alur: `security-scan` (gitleaks, scan seluruh history) → `build`
(build `--pull` supaya tag `stable` di-resolve segar → jalankan
`n8n --version` di dalam image → tag `:<versi>`, `:<versi>-<sha7>`, `:latest`
→ push → ringkasan tertulis di job summary).

Secrets GitHub yang wajib diisi (nama saja, nilainya tidak pernah ada di repo):
`DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` (akses key Docker Hub, bukan password
akun). Tanpa keduanya job build gagal — sengaja: jangan pernah menonaktifkan
gerbang gitleaks untuk "ngebut".

Trigger: push ke `main` yang menyentuh `Dockerfile`, `Dockerfile.runner`,
`n8n-task-runners.json`, atau workflow itu sendiri; plus `workflow_dispatch`
(manual dari tab Actions) dengan input opsional `n8n_base` — isi versi pin
(mis. `2.32.7`) untuk **build paritas**: image baru dengan versi n8n yang
sama persis dengan yang berjalan di produksi, supaya saat cutover Fase 1
satu-satunya variabel yang berubah adalah resep image, bukan versi n8n.

## 7. Runbook rilis image → deploy

1. Pastikan CI hijau; catat tag versi yang di-publish (lihat job summary).
2. Di **repo deployment** (bukan di sini): edit `image:` main/webhook/worker
   → `peakwine/n8n:<versi>` dan runner →
   `peakwine/n8n-runner:<versi>` (versi SAMA untuk keduanya).
3. `docker compose pull && docker compose up -d`.
4. Verifikasi: semua container healthy (`/healthz`), log runner menunjukkan
   koneksi ke broker `http://n8n-worker:5679`, lalu uji workflow staging.
5. Rollback: kembalikan baris `image:` ke tag lama → `up -d`. Tag versi tidak
   pernah ditimpa, jadi rollback selalu tersedia.

## 8. Runbook upgrade berkala (rutin, disarankan bulanan)

1. Baca [release notes 2.x] + [v2 breaking changes] docs n8n untuk rentang
   versi yang dilewati.
2. Cek baseline Alpine masih cocok:
   `docker run --rm n8nio/n8n:stable cat /etc/os-release` — bila naik,
   update `ARG ALPINE_VERSION` di kedua Dockerfile dalam commit yang sama.
3. Cek lockstep masih berlaku (opsional tapi murah): bandingkan
   `docker image inspect n8nio/n8n:stable` vs `n8nio/runners:stable` —
   `last-updated`-nya satu rilis bersama.
4. Trigger build (push kecil yang menyentuh path trigger, atau
   `workflow_dispatch`), lalu ikuti runbook rilis (§7).
5. Pantau 24 jam pertama; catat insiden di §11.

[release notes 2.x]: https://docs.n8n.io/changelog/release-notes-2.x
[v2 breaking changes]: https://docs.n8n.io/changelog/v20-breaking-changes

## 9. Troubleshooting log (berjejaring — tambahkan setiap insiden)

| Gejala | Penyebab | Solusi |
|---|---|---|
| Setelah pindah folder / compose dijalankan dari direktori lain, n8n "hilang semua datanya" (instance kosong) | Compose menamai volume `<project>_<volume>`; project name default = **nama folder**. Folder beda → volume baru kosong. | Selaraskan: jalankan dari folder yang sama, ATAU kunci dengan top-level `name:` di compose. Jangan pernah menghapus volume lama saat panik — datanya masih ada. |
| Runner tidak konek ke broker ("connection refused" ke :5679) | `N8N_RUNNERS_TASK_BROKER_URI` salah alamat, atau instance n8n belum set `N8N_RUNNERS_BROKER_LISTEN_ADDRESS=0.0.0.0` (default hanya localhost). | Cek env kedua sisi; URI menunjuk ke container worker/instance yang benar. |
| `apk: not found` saat coba modif Dockerfile | Memang begitu di image resmi (apk dibuang). | Multi-stage `COPY --from` dari stage Alpine — jangan `RUN apk add` di final stage. |
| Build runner gagal `MODULE_NOT_FOUND ... corepack/dist/corepack.js` (insiden CI run pertama, 2026-09-04) | Base runner baru pakai Node ≥25 yang **tidak lagi membundel corepack**, dan runtime-nya juga tanpa npm. Resep corepack adalah warisan image lama (Node 24). | Pakai binary `pnpm` langsung (`pnpm add ...`) — memang disertakan n8nio/runners supaya image bisa di-extend. Tambahkan `--config.minimum-release-age=0` (pnpm 11 default menolak dep yang dipublish <24 jam; sama seperti flag build upstream). |
| `pnpm: Permission denied` (exit 126) saat build runner (insiden CI run kedua, 2026-09-04) | **Bug image resmi n8nio/runners** (terverifikasi pada 2.37.9): symlink `/usr/local/bin/pnpm` menunjuk `bin/pnpm.cjs` yang terbit **tanpa bit eksekusi (mode 644)** — jalankan `pnpm` di image apa adanya pun gagal, bahkan sebagai root. | `RUN chmod +x /usr/local/lib/node_modules/pnpm/bin/pnpm.cjs pnpx.cjs` sebelum dipakai (sudah permanen di Dockerfile.runner). |
| Paket npm di runner "module not found" padahal sudah di-install | Belum masuk allowlist `NODE_FUNCTION_ALLOW_EXTERNAL`, atau library butuh `N8N_RUNNERS_ALLOW_PROTOTYPE_MUTATION` (lihat tangga §5). | Allowlist dulu; eskalasi tangga bila perlu. |
| `docker compose up -d --scale n8n-worker=2` error konflik nama | Service memakai `container_name` fixed. | Hapus `container_name` dari service yang ingin di-scale. |
| Docker Hub menampilkan arsitektur `unknown/unknown` pada tag | Attestasi/provenance buildx. | Nonaktifkan dengan `--provenance=false` (tidak dipakai di pipeline ini). |
| Error `database files are incompatible with server` setelah bump image postgres | Lompat major version PostgreSQL; data dir tak bisa dibuka versi baru. | Ikuti prosedur upgrade resmi PG (`pg_dumpall` / pg_upgrade). postgres:18+ wajib eksplisit `PGDATA` (default pindah lokasi). |
| Image build sukses tapi versi n8n "diam-diam" beda dari harapan | `stable` adalah tag bergerak — itu sifatnya (D1). | Selalu deploy pakai tag versi (bukan `latest`) yang tercatat di job summary CI. |

## 10. Aturan keamanan repo publik (WAJIB untuk agent & kontributor)

1. **Tidak ada secret di repo maupun history** — nilai nyata hanya di GitHub
   secrets (CI) dan `.env` di repo deployment. `.env` apa pun selain
   `.example` sudah diblokir `.gitignore`; gerbang gitleaks memverifikasi.
2. Jangan commit hasil `docker inspect`, `docker compose config` (hasil
   interpolasi!), `pg_dump`, export credentials n8n, atau screenshot yang
   menampakkan nilai.
3. Konteks bisnis/operasional (domain, nama proyek, ID workflow, riwayat
   insiden produksi) TIDAK boleh ditulis di repo ini — itu hidup di repo
   deployment private.
4. Saat menambah dependensi baru: cek lisensinya kompatibel; cantumkan di
   README tabel isi image; allowlist di config runner.
5. Sebelum push ke publik pertama kali / setelah menulis file baru yang
   menyentuh config: jalankan gitleaks lokal
   (`scripts/` tidak menyediakan — jalankan binary gitleaks langsung) atau
   andalkan gerbang CI — tapi jangan pernah menonaktifkan gerbang itu.

## 11. Log progres

### 2026-09-04 — Fase 0: repo dibentuk (commit pertama)

- Analisis awal: scrape docs n8n terbaru (docs baru-baru ini direstrukturisasi;
  halaman lama "build custom image" dihapus — guidance kini di *Set up task
  runners*), verifikasi Docker Hub API (lockstep `stable` n8n↔runners pada
  2.37.9), audit image produksi sebelumnya (base unpinned `:latest`, runner
  tertinggal sebulan → pelanggaran aturan versi-match).
- Keputusan D1–D9 (§2) diambil; config runner ditulis ulang dari stock config
  resmi (flag hardening dipertahankan, allowlist dibersihkan dari puppeteer).
- CI: gitleaks v8.24.3 + build dua image + resolve versi + tag immutabel.
- Yang belum (menunggu perintah owner): set 2 GitHub secrets Docker Hub,
  build pertama via CI, lalu Fase 1 (deploy awal ke produksi, ganti baris
  `image:` di repo deployment) dan Fase 2 (upgrade ke stable terbaru).
- Rencana fase: 0 = repo+CI (risiko nol, produksi tak tersentuh) → 1 =
  deploy image baru versi-match sebagai baseline → 2 = upgrade base ke
  stable terbaru (hari terpisah) → 3 = opsional fitur env baru (mis.
  durable scheduler, `N8N_SCHEDULER_ENABLED` +
  `N8N_USE_WORKFLOW_PUBLICATION_SERVICE`, GA sejak n8n 2.36).

### 2026-09-04 — Insiden CI #1 & perbaikan (run 33832994120)

- Gagal di `pnpm add`: resep warisan memanggil corepack via path
  `/usr/local/lib/node_modules/corepack/...` — Node 26 di base baru tidak
  lagi membundel corepack, dan runtime tidak punya npm (dikonfirmasi dari
  Dockerfile resmi `docker/images/runners/Dockerfile` master: pnpm
  disalinkan sebagai binary mandiri *untuk memudahkan extend*).
- Fix: `pnpm add --prod --no-lockfile --config.minimum-release-age=0 ...`
  (flag release-age meniru build upstream; pnpm 11 default menolak
  dependensi umur <24 jam).
- Pelajaran: **resep lama jangan disalin buta** — selalu cek Dockerfile
  base di master n8n saat base `stable` bergeser (kebiasaan ini masuk
  runbook upgrade §8). Gitleaks gate lolos; job build jalan setelah fix.

### 2026-09-04 — Insiden CI #2 & perbaikan (run 33833257597)

- `pnpm: Permission denied` (126). Terverifikasi langsung di dalam image
  resmi `n8nio/runners:stable` (2.37.9): symlink `/usr/local/bin/pnpm`
  menunjuk `pnpm.cjs` yang ber-mode 644 (tanpa exec bit) — bug upstream.
- Fix permanen di Dockerfile.runner: `chmod +x pnpm.cjs pnpx.cjs`.
- **Prosedur baru**: sebelum push, build & smoke test LOKAL dulu
  (`docker build -f Dockerfile.runner -t peakwine/n8n-runner:localtest .`
  + smoke: import playwright-core/libraries JS, `chromium-browser --version`,
  import paket Python, cek launcher). Build lokal sukses; smoke lulus semua
  (playwright-core OK, Chromium 149 Alpine, pandas 3.0.5/numpy 2.5.2,
  launcher + config di tempatnya).
