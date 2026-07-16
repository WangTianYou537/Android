#!/usr/bin/env bash
# Build shared runtime deps for Android packages (dynamic link mode).
#
# Produces per-ABI install trees:
#   common/deps/out/<ABI>/{lib,include,bin}
#     libz.so  libssl.so  libcrypto.so  libcurl.so
#
# Usage:
#   ./common/deps/build.sh              # arm64
#   ./common/deps/build.sh arm64 arm
#   ./common/deps/build.sh all
#   OPENSSL_VER=3.3.3 ZLIB_VER=1.3.1 CURL_VER=8.21.0 API=24 ./common/deps/build.sh arm64
#
# Env:
#   DEPS_OUT     install root (default: <repo>/common/deps/out)
#   BUILD_ROOT   source/build cache (default: /tmp/android-deps-build)
#   LINK_MODE is always shared here.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-/tmp/android-deps-build}"
DEPS_OUT="${DEPS_OUT:-$ROOT/out}"
OPENSSL_VER="${OPENSSL_VER:-3.3.3}"
ZLIB_VER="${ZLIB_VER:-1.3.1}"
CURL_VER="${CURL_VER:-8.21.0}"
API="${API:-24}"
JOBS="$(nproc 2>/dev/null || echo 2)"

if [[ -z "${NDK:-}" ]]; then
  for cand in \
    "$REPO_ROOT/android-ndk-r27d" \
    /opt/android-ndk-r27d \
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
  echo "ERROR: Android NDK not found"
  exit 1
fi

HOST_TAG=linux-x86_64
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
[[ -d "$TOOLCHAIN" ]] || { echo "ERROR: NDK toolchain missing"; exit 1; }
export PATH="$TOOLCHAIN/bin:$PATH"
export ANDROID_NDK_ROOT="$NDK"
export ANDROID_NDK_HOME="$NDK"

log() { printf '==> [deps] %s\n' "$*"; }

download_tar() {
  local dest="${*: -1}"
  local urls=("${@:1:$#-1}") u
  for u in "${urls[@]}"; do
    log "Downloading $u"
    if wget -q -O "$dest" "$u" || curl -fsSL -L -o "$dest" "$u"; then
      return 0
    fi
    rm -f "$dest"
  done
  echo "Failed to download: ${urls[*]}"
  return 1
}

ensure_sources() {
  mkdir -p "$BUILD_ROOT"
  local otar="openssl-${OPENSSL_VER}.tar.gz"
  if [[ ! -d "$BUILD_ROOT/openssl-${OPENSSL_VER}" ]]; then
    if [[ ! -f "$BUILD_ROOT/$otar" ]]; then
      download_tar \
        "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/$otar" \
        "https://www.openssl.org/source/$otar" \
        "$BUILD_ROOT/$otar"
    fi
    tar -xf "$BUILD_ROOT/$otar" -C "$BUILD_ROOT"
  fi
  local ztar="zlib-${ZLIB_VER}.tar.gz"
  if [[ ! -d "$BUILD_ROOT/zlib-${ZLIB_VER}" ]]; then
    if [[ ! -f "$BUILD_ROOT/$ztar" ]]; then
      download_tar \
        "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/$ztar" \
        "https://zlib.net/fossils/$ztar" \
        "$BUILD_ROOT/$ztar"
    fi
    tar -xf "$BUILD_ROOT/$ztar" -C "$BUILD_ROOT"
  fi
  local ctar="curl-${CURL_VER}.tar.xz"
  if [[ ! -d "$BUILD_ROOT/curl-${CURL_VER}" ]]; then
    if [[ ! -f "$BUILD_ROOT/$ctar" ]]; then
      download_tar \
        "https://curl.se/download/$ctar" \
        "https://github.com/curl/curl/releases/download/curl-${CURL_VER//./_}/$ctar" \
        "$BUILD_ROOT/$ctar"
    fi
    tar -xf "$BUILD_ROOT/$ctar" -C "$BUILD_ROOT"
  fi
}

resolve_abi() {
  case "$1" in
    arm64|aarch64|arm64-v8a)
      ABI=arm64-v8a; TRIPLE=aarch64-linux-android
      CLANG_PREFIX=aarch64-linux-android; OPENSSL_TARGET=android-arm64 ;;
    arm|armeabi-v7a|armv7)
      ABI=armeabi-v7a; TRIPLE=armv7a-linux-androideabi
      CLANG_PREFIX=armv7a-linux-androideabi; OPENSSL_TARGET=android-arm ;;
    x86_64|x64)
      ABI=x86_64; TRIPLE=x86_64-linux-android
      CLANG_PREFIX=x86_64-linux-android; OPENSSL_TARGET=android-x86_64 ;;
    x86|i686)
      ABI=x86; TRIPLE=i686-linux-android
      CLANG_PREFIX=i686-linux-android; OPENSSL_TARGET=android-x86 ;;
    *) echo "Unknown ABI: $1"; exit 1 ;;
  esac
}

set_cross_env() {
  export CC="${CLANG_PREFIX}${API}-clang"
  export CXX="${CLANG_PREFIX}${API}-clang++"
  export AR=llvm-ar RANLIB=llvm-ranlib STRIP=llvm-strip NM=llvm-nm
  export CFLAGS="-O2 -fPIC -DANDROID -fno-addrsig"
  export CXXFLAGS="$CFLAGS"
  unset LDFLAGS LIBS CPPFLAGS PKG_CONFIG_PATH || true
}

build_zlib_shared() {
  local prefix="$1"
  local stamp="$prefix/.stamp-zlib-${ZLIB_VER}-shared"
  if [[ -f "$stamp" ]] && ls "$prefix"/lib/libz.so* >/dev/null 2>&1; then
    log "zlib shared ready ($ABI)"; return
  fi
  local bdir="$BUILD_ROOT/zlib-shared-$ABI"
  rm -rf "$bdir"
  cp -a "$BUILD_ROOT/zlib-${ZLIB_VER}" "$bdir"
  cd "$bdir"
  set_cross_env
  export CHOST="$TRIPLE"
  # shared build (default for modern zlib when not --static)
  # Cross clang often fails zlib's shared-lib probe; force SHAREDLIB* after configure.
  ./configure --prefix="$prefix" >configure.log 2>&1 || {
    echo "ERROR: zlib configure"; tail -40 configure.log; exit 1
  }
  python3 - "$prefix" << 'PY'
from pathlib import Path
import re, sys
prefix = sys.argv[1]
p = Path("Makefile")
t = p.read_text()
t = re.sub(r"^SHAREDLIB=\s*$", "SHAREDLIB=libz.so", t, flags=re.M)
t = re.sub(r"^SHAREDLIBV=\s*$", "SHAREDLIBV=libz.so.1.3.1", t, flags=re.M)
t = re.sub(r"^SHAREDLIBM=\s*$", "SHAREDLIBM=libz.so.1", t, flags=re.M)
# version from env not available — detect from existing Makefile VER=
import re as _re
m = _re.search(r"^VER\s*=\s*(\S+)", t, _re.M)
ver = m.group(1) if m else "1"
t = _re.sub(r"^SHAREDLIBV=.*$", f"SHAREDLIBV=libz.so.{ver}", t, count=1, flags=_re.M)
t = _re.sub(r"^SHAREDLIBM=.*$", "SHAREDLIBM=libz.so.1", t, count=1, flags=_re.M)
t = _re.sub(r"^SHAREDLIB=.*$", "SHAREDLIB=libz.so", t, count=1, flags=_re.M)
# ensure -shared on LDSHARED
lines = []
for line in t.splitlines(True):
    if line.startswith("LDSHARED=") and "-shared" not in line:
        line = line.rstrip("\n") + " -shared\n"
    lines.append(line)
Path("Makefile").write_text("".join(lines))
print("zlib Makefile forced shared")
PY
  # Build the versioned shared object explicitly (skip broken test programs)
  make -j"$JOBS" "$prefix/../" 2>/dev/null || true
  # Prefer versioned target from Makefile
  ver=$(awk -F= '/^VER *=/{gsub(/ /,"",$2); print $2; exit}' Makefile)
  make -j"$JOBS" "libz.so.${ver}" >make.log 2>&1 || make -j"$JOBS" libz.so >make.log 2>&1 || {
    echo "ERROR: zlib shared make"; tail -40 make.log; exit 1
  }
  # install .so manually (make install may only install static when SHAREDLIB was empty at configure)
  mkdir -p "$prefix/lib" "$prefix/include"
  cp -a libz.so* "$prefix/lib/" 2>/dev/null || true
  cp -a zlib.h zconf.h "$prefix/include/" 2>/dev/null || true
  # also keep static for packages that still want it
  make libz.a >/dev/null 2>&1 || true
  [[ -f libz.a ]] && cp -a libz.a "$prefix/lib/"
  ls "$prefix"/lib/libz.so* >/dev/null 2>&1 || { echo "ERROR: libz.so not installed"; ls -la; exit 1; }
  touch "$stamp"
  log "zlib shared OK -> $prefix/lib"
  ls -lh "$prefix"/lib/libz.so*
}

build_openssl_shared() {
  local prefix="$1"
  local stamp="$prefix/.stamp-openssl-${OPENSSL_VER}-shared"
  if [[ -f "$stamp" && -f "$prefix/lib/libssl.so" ]]; then
    log "OpenSSL shared ready ($ABI)"; return
  fi
  local bdir="$BUILD_ROOT/openssl-shared-$ABI"
  rm -rf "$bdir"
  cp -a "$BUILD_ROOT/openssl-${OPENSSL_VER}" "$bdir"
  cd "$bdir"
  set_cross_env
  # shared is default when not no-shared; keep docs/tests off
  ./Configure "$OPENSSL_TARGET" -D__ANDROID_API__="${API}" \
    --prefix="$prefix" --libdir=lib \
    shared no-tests no-ui-console no-docs \
    >configure.log 2>&1 || {
      echo "ERROR: OpenSSL Configure"; tail -50 configure.log; exit 1
    }
  make -j"$JOBS" >make.log 2>&1 || {
    echo "ERROR: OpenSSL make"; grep -iE 'error:|fatal' make.log | tail -30; exit 1
  }
  make install_sw >install.log 2>&1
  # normalize lib64 if any
  if [[ ! -f "$prefix/lib/libssl.so" && -d "$prefix/lib64" ]]; then
    mkdir -p "$prefix/lib"
    cp -a "$prefix/lib64/"* "$prefix/lib/" 2>/dev/null || true
  fi
  [[ -f "$prefix/lib/libssl.so" || -f "$prefix/lib/libssl.so.3" ]] || {
    echo "ERROR: libssl.so missing"; ls -la "$prefix/lib"; exit 1
  }
  # ensure unversioned soname symlinks exist for -lssl
  (
    cd "$prefix/lib"
    if [[ ! -e libssl.so ]]; then
      so=$(ls libssl.so.* 2>/dev/null | head -1 || true)
      [[ -n "$so" ]] && ln -sfn "$so" libssl.so
    fi
    if [[ ! -e libcrypto.so ]]; then
      so=$(ls libcrypto.so.* 2>/dev/null | head -1 || true)
      [[ -n "$so" ]] && ln -sfn "$so" libcrypto.so
    fi
  )
  touch "$stamp"
  log "OpenSSL shared OK"
  ls -lh "$prefix"/lib/libssl.so* "$prefix"/lib/libcrypto.so* 2>/dev/null | head
}

build_libcurl_shared() {
  local prefix="$1"
  local stamp="$prefix/.stamp-libcurl-${CURL_VER}-shared"
  if [[ -f "$stamp" ]] && ls "$prefix"/lib/libcurl.so* >/dev/null 2>&1; then
    log "libcurl shared ready ($ABI)"; return
  fi
  local bdir="$BUILD_ROOT/curl-shared-$ABI"
  rm -rf "$bdir"
  mkdir -p "$bdir"
  cd "$bdir"
  set_cross_env
  export CFLAGS="-O2 -fPIC -DANDROID -fno-addrsig -I${prefix}/include"
  export CPPFLAGS="-I${prefix}/include"
  # rpath for curl.so itself to find libssl/libz at runtime next to it
  export LDFLAGS="-L${prefix}/lib -Wl,-rpath,\$ORIGIN"
  export LIBS="-lssl -lcrypto -lz"
  export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig"
  "$BUILD_ROOT/curl-${CURL_VER}/configure" \
    --host="${TRIPLE}" --build="$(uname -m)-pc-linux-gnu" \
    --prefix="$prefix" \
    --with-ssl="$prefix" --with-zlib="$prefix" \
    --enable-shared --disable-static \
    --enable-ipv6 --disable-ldap --disable-ldaps \
    --disable-manual --disable-docs \
    --without-libpsl --without-brotli --without-zstd \
    --without-libidn2 --without-libssh2 --without-nghttp2 \
    --without-ca-bundle --without-ca-path --with-ca-fallback \
    >configure.log 2>&1 || {
      echo "ERROR: curl configure"; tail -50 configure.log; exit 1
    }
  make -j"$JOBS" >make.log 2>&1 || {
    echo "ERROR: curl make"; grep -iE 'error:|undefined' make.log | tail -30; exit 1
  }
  make install >install.log 2>&1
  (
    cd "$prefix/lib"
    if [[ ! -e libcurl.so ]]; then
      so=$(ls libcurl.so.* 2>/dev/null | head -1 || true)
      [[ -n "$so" ]] && ln -sfn "$so" libcurl.so
    fi
  )
  [[ -e "$prefix/lib/libcurl.so" ]] || { echo "libcurl.so missing"; ls -la "$prefix/lib"; exit 1; }
  touch "$stamp"
  log "libcurl shared OK"
  ls -lh "$prefix"/lib/libcurl.so*
}

strip_libs() {
  local prefix="$1"
  local f
  for f in "$prefix"/lib/libz.so* "$prefix"/lib/libssl.so* "$prefix"/lib/libcrypto.so* "$prefix"/lib/libcurl.so*; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    llvm-strip -s "$f" 2>/dev/null || true
  done
}

build_one() {
  local name="$1"
  resolve_abi "$name"
  local prefix="$DEPS_OUT/$ABI"
  mkdir -p "$prefix"
  log "=== shared deps for $ABI (API $API) -> $prefix ==="
  build_zlib_shared "$prefix"
  build_openssl_shared "$prefix"
  build_libcurl_shared "$prefix"
  strip_libs "$prefix"
  {
    echo "shared deps"
    echo "ABI: $ABI"
    echo "API: $API"
    echo "zlib: ${ZLIB_VER}"
    echo "OpenSSL: ${OPENSSL_VER}"
    echo "libcurl: ${CURL_VER}"
    echo "NDK: $(grep Pkg.Revision "$NDK/source.properties" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
    ls -lh "$prefix"/lib/*.so* 2>/dev/null | head -40
  } | tee "$prefix/BUILD_INFO.txt"
  log "OK deps $ABI"
}

expand_targets() {
  local -a raw=("$@") out=() t a
  [[ ${#raw[@]} -eq 0 ]] && raw=(arm64)
  for t in "${raw[@]}"; do
    if [[ "$t" == "all" ]]; then out+=(arm64 arm x86_64 x86); else out+=("$t"); fi
  done
  local -a uniq=()
  for a in "${out[@]}"; do
    local seen=0
    for u in "${uniq[@]+"${uniq[@]}"}"; do [[ "$u" == "$a" ]] && { seen=1; break; }; done
    [[ $seen -eq 0 ]] && uniq+=("$a")
  done
  printf '%s\n' "${uniq[@]}"
}

main() {
  ensure_sources
  local -a targets
  mapfile -t targets < <(expand_targets "$@")
  [[ ${#targets[@]} -eq 0 ]] && targets=(arm64)
  log "Targets: ${targets[*]}"
  log "zlib=${ZLIB_VER} openssl=${OPENSSL_VER} curl=${CURL_VER} API=${API}"
  local t
  for t in "${targets[@]}"; do build_one "$t"; done
  log "Done. Install trees under: $DEPS_OUT"
  find "$DEPS_OUT" -name 'libcurl.so' -o -name 'libssl.so' 2>/dev/null | head
}

main "$@"
