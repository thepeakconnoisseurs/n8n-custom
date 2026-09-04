#!/usr/bin/env bash
# =============================================================================
# Local builder — same recipe as CI, for manual/staging builds.
# Requires: docker, logged in to the target registry (docker login).
#
# Usage:
#   ./scripts/build-local.sh            # build only, tag <registry>/n8n-custom:local
#   ./scripts/build-local.sh --push     # build, resolve version, push versioned tags
#
# Override the registry namespace with REG=... (default: trigidigital).
# =============================================================================
set -euo pipefail

REG="${REG:-trigidigital}"
PUSH=0
[ "${1:-}" = "--push" ] && PUSH=1

cd "$(dirname "$0")/.."

echo "==> Building main image"
docker build --pull -t "$REG/n8n-custom:local" -f Dockerfile .

echo "==> Building runner image"
docker build --pull -t "$REG/n8n-custom-runner:local" -f Dockerfile.runner .

VERSION="$(docker run --rm --entrypoint n8n "$REG/n8n-custom:local" --version | tr -d '[:space:]')"
echo "==> Captured n8n base version: $VERSION"

if [ "$PUSH" = 1 ]; then
  DATE_TAG="$(date +%Y%m%d)"
  for IMG in n8n-custom n8n-custom-runner; do
    docker tag "$REG/$IMG:local" "$REG/$IMG:$VERSION"
    docker tag "$REG/$IMG:local" "$REG/$IMG:$VERSION-$DATE_TAG"
    docker tag "$REG/$IMG:local" "$REG/$IMG:latest"
    docker push "$REG/$IMG:$VERSION"
    docker push "$REG/$IMG:$VERSION-$DATE_TAG"
    docker push "$REG/$IMG:latest"
  done
  echo "==> Pushed $REG/n8n-custom:$VERSION (+date tag, +latest) and runner"
else
  echo "==> Local build done ($VERSION). Re-run with --push to publish."
fi
