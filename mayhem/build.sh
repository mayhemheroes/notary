#!/usr/bin/env bash
#
# notary/mayhem/build.sh — build the OSS-Fuzz notary fuzz targets as sanitized
# libFuzzer binaries, replicating the cncf-fuzzing projects/notary build
# (github.com/cncf/cncf-fuzzing projects/notary/build.sh) for the targets that
# live in THIS repo (github.com/theupdateframework/notary):
#
#   /mayhem/notary-cryptoservice        cryptoservice/fuzz.Fuzz          (classic go-fuzz, dvyukov go-fuzz-build)
#   /mayhem/fuzz_import_keys_simple     trustmanager.FuzzImportKeysSimple     (native, go-118-fuzz-build)
#   /mayhem/fuzz_import_keys_structured trustmanager.FuzzImportKeysStructured (native, go-118-fuzz-build)
#   /mayhem/fuzz_parse_pem_private_key  tuf/utils.FuzzParsePEMPrivateKey      (native, go-118-fuzz-build)
#
# The cncf build's remaining targets live in other repos (notation-go,
# notation-core-go) or need heavier test scaffolding (server/handlers,
# signer/keydbstore, server/storage) — see mayhem/README notes in the fork.
#
# Build-time tree edits below (sed go.mod, drop vendor/, copy harnesses) happen
# INSIDE the image copy of the repo — the git branch itself stays purely additive.
#
# DWARF gate (SPEC §6.2 item 10): Go's gc always emits DWARF4; the C shims
# (LLVMFuzzerTestOneInput wrapper) are forced to DWARF3 via CGO_*FLAGS and the
# final clang++ link, so the FIRST CU is DWARF3 (< 4).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASan-only for the libFuzzer link.
: "${SANITIZER_FLAGS=-fsanitize=address}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS MAYHEM_JOBS

: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Air-gapped contract (SPEC §6.5): offline re-runs resolve from the in-image
# module cache via the file proxy; network entries only fill first-build misses.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

cd "$SRC"
go version

# ── Replicate cncf-fuzzing projects/notary/build.sh tree preparation ─────────
# (idempotent: sed no-ops on re-run; cp overwrites; go mod edit -replace is stable)
sed -i 's/^go 1\.17$/go 1.19/' go.mod
# The repo ships a vendor/ dir pinned to the un-fuzzed module graph; drop it and
# build from the module cache instead (-mod=mod), matching the cncf re-vendor step.
rm -rf vendor

# Vendored cncf-fuzzing harnesses (mayhem/ copies carry a `//go:build ignore`
# guard so `go test ./...` ignores them there; strip it when placing in-tree).
strip_ignore() { grep -vE '^//go:build ignore$' "$1" > "$2"; }
strip_ignore "$SRC/mayhem/fuzz_trustmanager_test.go" "$SRC/trustmanager/fuzz_trustmanager_test.go"
strip_ignore "$SRC/mayhem/fuzz_tuf_utils.go"         "$SRC/tuf/utils/fuzz_tuf_utils.go"
printf 'package trustmanager\nimport _ "github.com/AdamKorcz/go-118-fuzz-build/testing"\n' > "$SRC/trustmanager/registerfuzzdep.go"
# cncf build.sh: promote the test helpers the trustmanager harnesses use
# (NewTestImportStore, passphraseRetriever) out of _test.go files so
# go-118-fuzz-build keeps them (guarded mv keeps re-runs idempotent).
[ -f "$SRC/trustmanager/keys_test.go" ]     && mv "$SRC/trustmanager/keys_test.go"     "$SRC/trustmanager/keys_test_fuzz.go"
[ -f "$SRC/trustmanager/keystore_test.go" ] && mv "$SRC/trustmanager/keystore_test.go" "$SRC/trustmanager/keystore_test_fuzz.go"
true

# Pinned RESOLVED pseudo-version (cncf pins the raw commit hash, but a raw hash
# forces a network resolve on every run — the offline re-run would die on it).
go mod edit -replace github.com/AdaLogics/go-fuzz-headers=github.com/AdamKorcz/go-fuzz-headers-1@v0.0.0-20230111232327-1f10f66a31bf
go mod tidy 2>&1 | tail -2
# go-fuzz-build needs go-fuzz-dep on the module graph; the go-118 builder needs
# the AdamKorcz testing shim. `go get` AFTER tidy (tidy would prune them).
go get github.com/dvyukov/go-fuzz/go-fuzz-dep@v0.0.0-20240924070022-e577bee5275c 2>&1 | tail -2
go get github.com/AdamKorcz/go-118-fuzz-build/testing@v0.0.0-20250520111509-a70c2aa677fa 2>&1 | tail -2

mkdir -p "$SRC/mayhem-build"

link_target() { # <archive> <out>
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$1" -o "/mayhem/$2"
  echo "built /mayhem/$2"
}

# ── classic go-fuzz target: cryptoservice/fuzz.Fuzz (compile_go_fuzzer) ──────
echo "=== building notary-cryptoservice (go-fuzz-build -libfuzzer) ==="
(
  cd "$SRC/cryptoservice/fuzz"
  go-fuzz-build -libfuzzer -func Fuzz -o "$SRC/mayhem-build/notary-cryptoservice.a"
)
link_target "$SRC/mayhem-build/notary-cryptoservice.a" notary-cryptoservice

# ── native go-1.18 fuzz targets (compile_native_go_fuzzer) ───────────────────
build_native() { # <pkg-dir> <func> <out>
  echo "=== building $3 ($2, go-118-fuzz-build) ==="
  go-118-fuzz-build -o "$SRC/mayhem-build/$3.a" -func "$2" "$SRC/$1"
  link_target "$SRC/mayhem-build/$3.a" "$3"
}
build_native trustmanager FuzzImportKeysSimple     fuzz_import_keys_simple
build_native trustmanager FuzzImportKeysStructured fuzz_import_keys_structured
build_native tuf/utils    FuzzParsePEMPrivateKey   fuzz_parse_pem_private_key

echo "build.sh complete:"
ls -la /mayhem/notary-cryptoservice /mayhem/fuzz_import_keys_simple /mayhem/fuzz_import_keys_structured /mayhem/fuzz_parse_pem_private_key
