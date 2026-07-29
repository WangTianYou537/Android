#!/usr/bin/env bash
# Stage per-ABI dynamic bundles: shared libs + curl + openssh + git.
#
# Usage (from repo root, after builds):
#   ./common/package-dynamic.sh arm64 x86_64
#   ABIS="arm64 x86_64" ./common/package-dynamic.sh
#
# Output:
#   dist/android-dynamic-<short>.tar.gz
#   dist/SUMMARY.txt
#   dist/RELEASE_NOTES.txt  (caller may overwrite notes)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

declare -A MAP=([arm64]=arm64-v8a [arm]=armeabi-v7a [x86_64]=x86_64 [x86]=x86)

if [[ $# -gt 0 ]]; then
  shorts=("$@")
elif [[ -n "${ABIS:-}" ]]; then
  # shellcheck disable=SC2206
  shorts=(${ABIS})
else
  shorts=(arm64)
fi

mkdir -p dist
assets=()

write_curl_launcher() {
  local dest="$1"
  cat > "$dest" << 'WRAP'
#!/system/bin/sh
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
export CURL_CA_BUNDLE="${CURL_CA_BUNDLE:-$ROOT/cacert.pem}"
export SSL_CERT_FILE="${SSL_CERT_FILE:-$ROOT/cacert.pem}"
export LD_LIBRARY_PATH="$ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/curl" "$@"
WRAP
  chmod 755 "$dest"
}

write_env_sh() {
  local dest="$1"
  cat > "$dest" << 'ENV'
# source this on device, then run binaries
HERE="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="$HERE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$HERE/bin:$HERE/openssh:$HERE/git:$PATH"
export GIT_EXEC_PATH="$HERE/git"
ENV
}

for short in "${shorts[@]}"; do
  abi="${MAP[$short]:-}"
  if [[ -z "$abi" ]]; then
    echo "ERROR: unknown ABI short name: $short" >&2
    exit 1
  fi

  stage="dist/android-dynamic-${short}"
  rm -rf "$stage"
  mkdir -p "$stage"/{lib,bin,openssh,git}

  # shared libs once
  if compgen -G "common/deps/out/${abi}/lib/"'*.so*' >/dev/null; then
    cp -a "common/deps/out/${abi}/lib/"*.so* "$stage/lib/"
  fi

  # curl package (binary + CA + launcher; libs already in stage/lib)
  if [[ -f "curl/out/${abi}/curl" ]]; then
    cp -a "curl/out/${abi}/curl" "$stage/bin/curl"
    [[ -f "curl/out/${abi}/cacert.pem" ]] && cp -a "curl/out/${abi}/cacert.pem" "$stage/cacert.pem"
    if [[ -f "curl/out/${abi}/curl.sh" ]]; then
      # rewrite launcher for bundle layout (bin/ under stage root)
      write_curl_launcher "$stage/bin/curl.sh"
    else
      write_curl_launcher "$stage/bin/curl.sh"
    fi
    if [[ ! -f "$stage/cacert.pem" ]]; then
      wget -q -O "$stage/cacert.pem" https://curl.se/ca/cacert.pem || true
    fi
  fi

  # openssh
  for b in ssh scp sftp sshd ssh-keygen ssh-add ssh-agent ssh-keyscan sftp-server; do
    [[ -f "openssh/out/${abi}/$b" ]] && cp -a "openssh/out/${abi}/$b" "$stage/openssh/"
  done

  # git
  if [[ -d "git/out/${abi}/bin" ]]; then
    cp -a "git/out/${abi}/bin/." "$stage/git/"
  fi
  if [[ -d "git/out/${abi}/libexec" ]]; then
    mkdir -p "$stage/git-libexec"
    cp -a "git/out/${abi}/libexec/." "$stage/git-libexec/"
  fi

  write_env_sh "$stage/env.sh"

  # Prefer rpath; env.sh is fallback
  if command -v patchelf >/dev/null; then
    for f in "$stage"/bin/* "$stage"/openssh/* "$stage"/git/*; do
      [[ -f "$f" && ! -L "$f" ]] || continue
      file "$f" | grep -q ELF || continue
      patchelf --set-rpath '$ORIGIN/../lib' "$f" 2>/dev/null || true
    done
    if [[ -d "$stage/git-libexec" ]]; then
      while IFS= read -r -d '' f; do
        file "$f" | grep -q ELF || continue
        patchelf --set-rpath '$ORIGIN/../../lib' "$f" 2>/dev/null || true
      done < <(find "$stage/git-libexec" -type f -print0 2>/dev/null)
    fi
    for f in "$stage"/lib/*.so*; do
      [[ -f "$f" && ! -L "$f" ]] || continue
      patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null || true
    done
  fi

  # Minimal README
  cat > "$stage/README.txt" << EOF
Android dynamic tools (${short} / ${abi})
========================================
Layout:
  lib/          shared deps (libz, libssl, libcrypto, libcurl)
  bin/curl      curl binary
  bin/curl.sh   launcher (sets CURL_CA_BUNDLE + LD_LIBRARY_PATH)
  cacert.pem    Mozilla CA store
  openssh/      ssh, scp, sftp, sshd, ...
  git/          git + helpers
  env.sh        source to prepend PATH / LD_LIBRARY_PATH

Usage:
  adb push android-dynamic-${short} /data/local/tmp/
  adb shell
  cd /data/local/tmp/android-dynamic-${short}
  . ./env.sh
  curl.sh -I https://example.com
  ssh -V
  git --version
EOF

  tar -C dist -czf "dist/android-dynamic-${short}.tar.gz" "android-dynamic-${short}"
  assets+=("dist/android-dynamic-${short}.tar.gz")
  echo "packed android-dynamic-${short}.tar.gz"
done

{
  echo "assets:"
  for a in "${assets[@]}"; do
    ls -lh "$a"
  done
} | tee dist/SUMMARY.txt

# default notes (workflow may overwrite)
{
  echo "Android dynamic bundle"
  echo "ABIs: ${shorts[*]}"
  echo "layout: lib/*.so + bin/curl + openssh/* + git/*"
  echo "rpath: binaries use \$ORIGIN/../lib"
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee dist/RELEASE_NOTES.txt

printf '%s\n' "${assets[@]}" > dist/asset-files.txt
echo "Done. Packages under dist/"
