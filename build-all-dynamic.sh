#!/usr/bin/env bash
# Build shared deps once, then curl/openssh/git with LINK_MODE=dynamic.
#
# Usage:
#   ./build-all-dynamic.sh                 # arm64
#   ./build-all-dynamic.sh arm64
#   ./build-all-dynamic.sh all
#   API=24 ./build-all-dynamic.sh arm64 arm
#
# Layout (per ABI):
#   common/deps/out/<ABI>/lib/{libz,libssl,libcrypto,libcurl}.so*
#   curl/out/<ABI>/{curl,lib/}
#   openssh/out/<ABI>/{ssh,...,lib/}
#   git/out/<ABI>/{bin,lib,libexec}/
#
# On device, push each package dir so $ORIGIN/lib resolves, e.g.:
#   adb push curl/out/arm64-v8a /data/local/tmp/curl-root
#   adb shell /data/local/tmp/curl-root/curl --version

set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

TARGETS=("${@:-arm64}")
export LINK_MODE=dynamic
export API="${API:-24}"
export OPENSSL_VER="${OPENSSL_VER:-3.3.3}"
export ZLIB_VER="${ZLIB_VER:-1.3.1}"
export CURL_VER="${CURL_VER:-8.21.0}"
export OPENSSH_VER="${OPENSSH_VER:-9.9p2}"
export GIT_VER="${GIT_VER:-2.49.0}"

log() { printf '==== %s ====\n' "$*"; }

log "1/4 shared deps (${TARGETS[*]})"
./common/deps/build.sh "${TARGETS[@]}"

# Resolve DEPS_PREFIX per ABI inside each package via default path
# common/deps/out/<ABI>

log "2/4 curl (dynamic)"
LINK_MODE=dynamic ./curl/build.sh "${TARGETS[@]}"

log "3/4 openssh (dynamic)"
LINK_MODE=dynamic ./openssh/build.sh "${TARGETS[@]}"

log "4/4 git (dynamic)"
LINK_MODE=dynamic ./git/build.sh "${TARGETS[@]}"

log "Done (dynamic)"
echo "Artifacts:"
find curl/out openssh/out git/out common/deps/out -type f \( -name curl -o -name ssh -o -name git -o -name 'libcurl.so*' -o -name 'libssl.so' \) 2>/dev/null | head -40
