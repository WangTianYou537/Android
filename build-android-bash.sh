#!/usr/bin/env bash
# Build GNU bash for Android (PIE, dynamically linked against Bionic)
# Usage:
#   ./build-android-bash.sh              # default: aarch64 API 24
#   ./build-android-bash.sh arm64
#   ./build-android-bash.sh arm          # armeabi-v7a
#   ./build-android-bash.sh x86_64
#   ./build-android-bash.sh x86
#   ./build-android-bash.sh all
#   API=28 ./build-android-bash.sh arm64
#   NDK=/path/to/ndk ./build-android-bash.sh arm64
#
# Why not fully static?
#   Static arm64 binaries abort on modern Android Bionic with:
#     "executable's TLS segment is underaligned: alignment is 8, needs to be at least 64"
#   Link dynamically against Bionic instead (only needs system libc/libdl).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-/tmp/bash4droid-build}"
BASH_VER="${BASH_VER:-5.2.37}"
API="${API:-24}"
OUT_DIR="${OUT_DIR:-$ROOT/out}"

if [[ -z "${NDK:-}" ]]; then
  for cand in \
    "$ROOT/android-ndk-r27d" \
    /opt/android-ndk-r27d \
    "$BUILD_ROOT/android-ndk-r27d" \
    "${ANDROID_NDK_HOME:-}" \
    "${ANDROID_NDK_ROOT:-}" \
    "$HOME/Android/Sdk/ndk/"*
  do
    if [[ -n "$cand" && -d "$cand/toolchains/llvm/prebuilt" ]]; then
      NDK="$cand"
      break
    fi
  done
fi

if [[ -z "${NDK:-}" || ! -d "$NDK" ]]; then
  echo "ERROR: Android NDK not found."
  echo "Set NDK=/path/to/android-ndk-r27d or extract the zip next to this script."
  exit 1
fi

HOST_TAG=linux-x86_64
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
if [[ ! -d "$TOOLCHAIN" ]]; then
  if [[ -d "$NDK/toolchains/llvm/prebuilt/darwin-x86_64" ]]; then
    HOST_TAG=darwin-x86_64
    TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
  else
    echo "ERROR: NDK prebuilt toolchain not found under $NDK/toolchains/llvm/prebuilt"
    exit 1
  fi
fi
export PATH="$TOOLCHAIN/bin:$PATH"

log() { printf '==> %s\n' "$*"; }

ensure_source() {
  mkdir -p "$BUILD_ROOT"
  local tar="bash-${BASH_VER}.tar.gz"
  if [[ ! -d "$BUILD_ROOT/bash-${BASH_VER}" ]]; then
    if [[ ! -f "$BUILD_ROOT/$tar" ]]; then
      log "Downloading bash ${BASH_VER}..."
      local urls=(
        "https://mirrors.kernel.org/gnu/bash/$tar"
        "https://ftp.gnu.org/gnu/bash/$tar"
      )
      local ok=0
      for u in "${urls[@]}"; do
        if wget -q -O "$BUILD_ROOT/$tar" "$u" || curl -fsSL -o "$BUILD_ROOT/$tar" "$u"; then
          ok=1
          break
        fi
      done
      [[ $ok -eq 1 ]] || { echo "Failed to download bash source"; exit 1; }
    fi
    log "Extracting $tar"
    tar -xf "$BUILD_ROOT/$tar" -C "$BUILD_ROOT"
  fi
}

ensure_compat() {
  mkdir -p "$ROOT/compat" "$BUILD_ROOT/compat"
  local src="$ROOT/compat/android_compat.c"
  if [[ ! -f "$src" ]]; then
    cat > "$src" << 'EOF'
/* Bionic shims: mblen is not exported from Android libc.so. */
#include <stddef.h>
#include <wchar.h>
#include <string.h>

int mblen(const char *s, size_t n)
{
  if (s == NULL)
    return 0; /* always initial shift state */
  if (n == 0)
    return -1;
  mbstate_t st;
  memset(&st, 0, sizeof(st));
  size_t r = mbrlen(s, n, &st);
  if (r == (size_t)-1 || r == (size_t)-2)
    return -1;
  return (int)r;
}
EOF
  fi
}

resolve_abi() {
  case "$1" in
    arm64|aarch64|arm64-v8a)
      ABI=arm64-v8a
      TRIPLE=aarch64-linux-android
      CLANG_PREFIX=aarch64-linux-android
      ;;
    arm|armeabi-v7a|armv7)
      ABI=armeabi-v7a
      TRIPLE=armv7a-linux-androideabi
      CLANG_PREFIX=armv7a-linux-androideabi
      ;;
    x86_64|x64)
      ABI=x86_64
      TRIPLE=x86_64-linux-android
      CLANG_PREFIX=x86_64-linux-android
      ;;
    x86|i686)
      ABI=x86
      TRIPLE=i686-linux-android
      CLANG_PREFIX=i686-linux-android
      ;;
    *)
      echo "Unknown ABI: $1"
      echo "Supported: arm64, arm, x86_64, x86, all"
      exit 1
      ;;
  esac
}

build_one() {
  local name="$1"
  resolve_abi "$name"

  local build_dir="$BUILD_ROOT/bash-build-$ABI"
  local dest="$OUT_DIR/$ABI"
  local cc="${CLANG_PREFIX}${API}-clang"

  log "Building bash ${BASH_VER} for $ABI (API $API) [dynamic PIE]"
  log "NDK: $NDK"
  log "CC : $cc"

  rm -rf "$build_dir"
  mkdir -p "$build_dir" "$dest"
  cd "$build_dir"

  export CC="$cc"
  export CXX="${CLANG_PREFIX}${API}-clang++"
  export AR=llvm-ar
  export RANLIB=llvm-ranlib
  export STRIP=llvm-strip
  # Dynamic PIE against Bionic — avoids arm64 static TLS underalignment abort.
  export CFLAGS="-O2 -fPIE -fPIC -DANDROID -fno-addrsig"
  export LDFLAGS="-pie"
  unset LIBS

  # Cross-compile aarch64 mblen shim (do NOT put it in LIBS — that breaks host tools)
  "$CC" $CFLAGS -c "$ROOT/compat/android_compat.c" -o android_compat.o

  "$BUILD_ROOT/bash-${BASH_VER}/configure" \
    --host="${TRIPLE}" \
    --build="$(uname -m)-pc-linux-gnu" \
    --prefix="/data/local/tmp/bash" \
    --without-bash-malloc \
    --disable-nls \
    --disable-rpath \
    --enable-job-control \
    --enable-history \
    --disable-readline \
    --disable-net-redirections \
    bash_cv_dev_fd=present \
    bash_cv_dev_stdin=present \
    bash_cv_getcwd_malloc=yes \
    bash_cv_job_control_missing=present \
    bash_cv_sys_named_pipes=present \
    bash_cv_func_sigsetjmp=present \
    bash_cv_printf_a_format=yes \
    bash_cv_unusable_rtsigs=no \
    bash_cv_sys_siglist=yes \
    bash_cv_under_sys_siglist=yes \
    ac_cv_func_mmap_fixed_mapped=yes \
    ac_cv_c_bigendian=no \
    ac_cv_func_setvbuf_reversed=no \
    gt_cv_int_divbyzero_sigfpe=yes \
    >configure.log 2>&1

  # -rdynamic is useless on Android; drop it
  sed -i 's/^LOCAL_LDFLAGS = -rdynamic/LOCAL_LDFLAGS = /' Makefile

  # Inject compat object into OBJECTS (tab-separated in bash Makefile)
  python3 - << 'PY'
from pathlib import Path
import re
p = Path("Makefile")
t = p.read_text()
m = re.search(r'^OBJECTS\s*=\s*', t, re.M)
if not m:
    raise SystemExit("OBJECTS line not found in Makefile")
# already injected?
line_end = t.find("\n", m.start())
line = t[m.start():line_end]
if "android_compat.o" not in line:
    t = t[:m.end()] + "android_compat.o " + t[m.end():]
    p.write_text(t)
print("OBJECTS ok")
PY

  make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)" >make.log 2>&1 || {
    echo "ERROR: make failed. See $build_dir/make.log"
    grep -iE 'error:|undefined symbol' make.log | tail -30
    exit 1
  }

  if [[ ! -f bash ]]; then
    echo "ERROR: bash binary not produced. See $build_dir/make.log"
    exit 1
  fi

  if file bash | grep -q 'statically linked'; then
    echo "ERROR: got a static binary; Android arm64 will abort with TLS underalignment."
    exit 1
  fi

  cp -f bash "$dest/bash.unstripped"
  llvm-strip -s -o "$dest/bash" bash
  chmod 755 "$dest/bash"

  {
    echo "bash ${BASH_VER}"
    echo "ABI: $ABI"
    echo "API: $API"
    echo "NDK: $(grep Pkg.Revision "$NDK/source.properties" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
    echo "link: dynamic PIE (bionic)"
    echo "static: no"
    echo "readline: no"
    echo "compat: mblen via android_compat.o"
    file "$dest/bash"
    ls -lh "$dest/bash"
    echo "--- needed libs ---"
    llvm-readobj --needed-libs "$dest/bash" 2>/dev/null || true
    echo "--- TLS ---"
    readelf -l "$dest/bash" | grep -A1 TLS || echo "(no TLS PHDR)"
  } | tee "$dest/BUILD_INFO.txt"

  log "OK -> $dest/bash"
}

main() {
  ensure_source
  ensure_compat
  local target="${1:-arm64}"
  if [[ "$target" == "all" ]]; then
    for a in arm64 arm x86_64 x86; do
      build_one "$a"
    done
  else
    build_one "$target"
  fi
  log "Done. Binaries under: $OUT_DIR"
  find "$OUT_DIR" -type f -name bash -exec ls -lh {} \;
}

main "$@"
