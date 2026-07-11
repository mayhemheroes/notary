# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — GO target (go modules / go-fuzz-build). Builds ON TOP
# of the org C/C++ base (ghcr.io/mayhemheroes/base) — clang is needed to link the
# go-fuzz libFuzzer archive — adding a pinned Go toolchain + go-fuzz under
# /opt/toolchains/go, then runs the per-repo mayhem/build.sh.
#
# WHY a Go-specific template (SPEC §6.2 items 8/9, §6.5):
#   Go's GOPATH/GOMODCACHE default to $HOME/go. The commit build and the PATCH RL
#   re-run use DIFFERENT $HOMEs, so a cache left at the default would vanish under
#   the re-run identity. We pin GOROOT/GOPATH/GOMODCACHE at FIXED, $HOME-independent
#   paths under /opt/toolchains so (a) the toolchain locks uniformly (§4/§5) and
#   (b) the module cache the FIRST (online) build fills is found again — by the SAME
#   absolute GOMODCACHE — when build.sh re-runs OFFLINE at the PATCH tier.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t mytag .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS

# ── Go toolchain @ a FIXED, lockable, $HOME-independent prefix ─────────────────
# Pin the Go version AND its tarball sha256 (reproducible fetch). Pin go-fuzz by a
# module pseudo-version (NOT @latest) so the cache is deterministic. EDIT per repo.
ARG GO_VERSION=1.25.5
ARG GO_SHA256=9e9b755d63b36acf30c12a9a3fc379243714c1c6d3dd72861da637f336ebb35b
ARG GO_FUZZ_VERSION=v0.0.0-20240924070022-e577bee5275c

ENV GOROOT=/opt/toolchains/go \
    GOPATH=/opt/toolchains/go-path \
    GOMODCACHE=/opt/toolchains/go-path/pkg/mod \
    GOCACHE=/opt/toolchains/go-path/build-cache \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=mod \
    PATH=/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:${PATH}

USER root
RUN install -d /opt/toolchains/go-path \
 && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz \
 && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
 && tar -C /opt/toolchains -xzf /tmp/go.tgz && rm -f /tmp/go.tgz \
 # go-fuzz + go-fuzz-build (the libFuzzer build path). Installing them also seeds the
 # go-fuzz module (incl. go-fuzz-dep) into GOMODCACHE, which build.sh needs offline.
 && go install "github.com/dvyukov/go-fuzz/go-fuzz@${GO_FUZZ_VERSION}" \
 && go install "github.com/dvyukov/go-fuzz/go-fuzz-build@${GO_FUZZ_VERSION}" \
 # go-118-fuzz-build — native `func FuzzX(f *testing.F)` harnesses (compile_native_go_fuzzer path)
 && go install github.com/AdamKorcz/go-118-fuzz-build@v0.0.0-20250520111509-a70c2aa677fa \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must
 # read the toolchain and read/refresh the module cache, so hand the GOPATH to 2000.
 && chown -R 2000:2000 /opt/toolchains/go-path

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $GOMODCACHE (online, this first build) and builds the libFuzzer target(s).
RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
