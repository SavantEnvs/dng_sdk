# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for the Adobe DNG SDK parser fuzzer. Builds on the org
# C/C++ base (clang/llvm + libFuzzer + build-contract ENV) and adds the JPEG-XL /
# highway / brotli / jpeg / zlib dev libraries the SDK links against, then builds
# the fuzz harness + oracle probe (mayhem/build.sh) and runs the oracle (test.sh).

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# Dev libraries the DNG SDK needs (XMP/expat is NOT needed — we build qDNGUseXMP=0).
# libjxl pulls in highway + brotli. python3 drives the additive dng_jxl shadow patch.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        libjxl-dev libhwy-dev libbrotli-dev libjpeg-dev zlib1g-dev python3 \
    && rm -rf /var/lib/apt/lists/*
USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
