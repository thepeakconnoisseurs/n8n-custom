# syntax=docker/dockerfile:1
# =============================================================================
# n8n-custom — main image (editor / API / webhook processor / worker)
#
# Base tag: n8nio/n8n:stable (moving tag). n8n publishes n8nio/n8n:stable and
# n8nio/runners:stable in lockstep from the same commit, so pairing the two
# `stable` bases automatically satisfies the docs rule "runner image version
# must match the n8n image version". CI resolves the actual n8n version after
# build and tags the result immutably (see .github/workflows/build.yml).
#
# Why multi-stage COPY: official n8n images ship WITHOUT apk, so extra system
# binaries must be copied in from a plain Alpine builder stage. Keep the
# builder's Alpine version in sync with the base image's Alpine when upgrading
# (check with: docker run --rm n8nio/n8n:stable cat /etc/os-release).
# =============================================================================
ARG ALPINE_VERSION=3.23
ARG N8N_BASE=stable

FROM alpine:${ALPINE_VERSION} AS builder

RUN apk add --no-cache \
        ffmpeg \
        git \
        openssh-client \
        graphicsmagick \
        jq \
        curl

FROM n8nio/n8n:${N8N_BASE}

LABEL org.opencontainers.image.source="https://github.com/thepeakconnoisseurs/n8n-custom" \
      org.opencontainers.image.description="Custom n8n image with extra CLI tooling, for queue-mode deployments (main/webhook/worker roles)"

USER root

# Copy binaries and their shared libraries from the builder.
# NOTE: this exact set is inherited from the previously proven production
# image — change deliberately, not casually.
COPY --from=builder /usr/bin/ffmpeg /usr/bin/ffmpeg
COPY --from=builder /usr/bin/ffprobe /usr/bin/ffprobe
COPY --from=builder /usr/bin/git /usr/bin/git
COPY --from=builder /usr/bin/gm /usr/bin/gm
COPY --from=builder /usr/bin/jq /usr/bin/jq
COPY --from=builder /usr/bin/curl /usr/bin/curl
COPY --from=builder /usr/lib/libav*.so* /usr/lib/
COPY --from=builder /usr/lib/libsw*.so* /usr/lib/
COPY --from=builder /usr/lib/libcurl*.so* /usr/lib/
COPY --from=builder /usr/lib/libjq*.so* /usr/lib/
COPY --from=builder /usr/lib/libonig*.so* /usr/lib/

# Task broker port for external task runners (n8n 2.x, external mode)
EXPOSE 5679

USER node
