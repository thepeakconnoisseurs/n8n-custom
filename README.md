# n8n-custom

Custom **[n8n](https://n8n.io)** Docker images for queue-mode self-hosting, built on
top of the official **`stable`** release tags — plus a task-runner image with
**Playwright + Chromium** ready for browser automation from the Code node.

## Images

| Image | Base | Purpose |
|---|---|---|
| `trigidigital/n8n-custom` | `n8nio/n8n:stable` | n8n main / webhook processor / worker. Adds `ffmpeg`, `git`, `graphicsmagick`, `jq`, `curl`. Exposes task-broker port `5679`. |
| `trigidigital/n8n-custom-runner` | `n8nio/runners:stable` | External-mode task runner sidecar (Code node JS + Python). Adds Chromium, Playwright packages, media/image tooling, extra JS/Python libs. |

Both bases are built from n8n's `stable` tag, which n8n publishes for the two
images **in lockstep from the same commit** — so pairing them satisfies the
docs rule that *the runners image version must match the n8n image version*.
CI resolves the actual n8n version after each build and publishes immutable
tags:

```
trigidigital/n8n-custom:2.37.9            # exact n8n release
trigidigital/n8n-custom:2.37.9-1a2b3c4    # release + build commit
trigidigital/n8n-custom:latest            # moving pointer (convenience)
```

## What's inside the runner image

- **JS** (`NODE_FUNCTION_ALLOW_EXTERNAL`): `playwright-core`, `playwright-extra`,
  `ajv`, `ajv-formats`, `lz-string`, `node-imap`, `mailparser`, `tweetnacl`, `imapflow`
- **Python** (`N8N_RUNNERS_EXTERNAL_ALLOW`): `requests`, `pillow`, `pandas`, `numpy`
- **System**: Chromium (wired to Playwright via `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH`),
  ffmpeg, GraphicsMagick, ImageMagick, git

Playwright runs against the system Chromium — no browser download needed.
Puppeteer is intentionally **not** included.

## Quick start

See [`examples/docker-compose.example.yml`](examples/docker-compose.example.yml)
for a full queue-mode reference stack (Postgres + Valkey + main + webhook
processor + worker + task-runner sidecar), including health checks and
horizontal scaling of workers via `docker compose --scale`.

## Building

CI (GitHub Actions) builds and pushes on every push to `main` that touches the
Dockerfiles or runner config. For local builds:

```bash
./scripts/build-local.sh          # build + resolve captured n8n version
./scripts/build-local.sh --push   # also publish versioned tags
```

## Security

- This is a **public** repository: no secrets, no real `.env` values are ever
  committed. CI credentials live in GitHub repository secrets.
- Every CI run is gated by a **gitleaks** secret scan (full git history).
- Task runners use the stock hardened Node flags from the official image
  (`--disallow-code-generation-from-strings`, `--disable-proto=delete`) —
  see `n8n-task-runners.json` for the package allowlists.

## License

[MIT](LICENSE)
