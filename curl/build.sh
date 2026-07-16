#!/usr/bin/env bash
# Cross-compile official curl for Android (NDK clang + Bionic).
#
# Sources (upstream only):
#   curl:    https://curl.se/download/curl-<ver>.tar.xz
#   OpenSSL: https://www.openssl.org/source/openssl-<ver>.tar.gz
#   zlib:    https://github.com/madler/zlib/releases
#
# Usage (from repo root or curl/):
#   ./curl/build.sh                         # default arm64 API 24
#   ./curl/build.sh arm64
#   ./curl/build.sh arm64 arm
#   ./curl/build.sh all
#   CURL_VER=8.21.0 OPENSSL_VER=3.3.3 ZLIB_VER=1.3.1 ./curl/build.sh arm64
#   API=28 NDK=/opt/android-ndk-r27d ./curl/build.sh arm64
#
# Output:
#   out/<ABI>/curl
#   out/<ABI>/curl.unstripped
#   out/<ABI>/BUILD_INFO.txt
#
# Notes:
#   - curl is dynamic PIE against Bionic only (libc / libdl / libm).
#   - OpenSSL + zlib are built static and linked into curl (single-file push).
#   - Fully static curl aborts on modern arm64 Bionic (TLS underalignment).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-/tmp/curl-android-build}"
CURL_VER="${CURL_VER:-8.21.0}"
OPENSSL_VER="${OPENSSL_VER:-3.3.3}"
ZLIB_VER="${ZLIB_VER:-1.3.1}"
API="${API:-24}"
OUT_DIR="${OUT_DIR:-$ROOT/out}"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
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
  echo "ERROR: Android NDK not found. Set NDK=... or source common/env-ndk.sh"
  exit 1
fi

HOST_TAG=linux-x86_64
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
if [[ ! -d "$TOOLCHAIN" ]]; then
  if [[ -d "$NDK/toolchains/llvm/prebuilt/darwin-x86_64" ]]; then
    HOST_TAG=darwin-x86_64
    TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
  else
    echo "ERROR: NDK toolchain missing under $NDK/toolchains/llvm/prebuilt"
    exit 1
  fi
fi
export PATH="$TOOLCHAIN/bin:$PATH"
export ANDROID_NDK_ROOT="$NDK"
export ANDROID_NDK_HOME="$NDK"

log() { printf '==> %s\n' "$*"; }

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

  local ctar="curl-${CURL_VER}.tar.xz"
  if [[ ! -d "$BUILD_ROOT/curl-${CURL_VER}" ]]; then
    if [[ ! -f "$BUILD_ROOT/$ctar" ]]; then
      download_tar \
        "https://curl.se/download/$ctar" \
        "https://github.com/curl/curl/releases/download/curl-${CURL_VER//./_}/$ctar" \
        "$BUILD_ROOT/$ctar"
    fi
    log "Extracting $ctar (official curl)"
    tar -xf "$BUILD_ROOT/$ctar" -C "$BUILD_ROOT"
  fi

  local otar="openssl-${OPENSSL_VER}.tar.gz"
  if [[ ! -d "$BUILD_ROOT/openssl-${OPENSSL_VER}" ]]; then
    if [[ ! -f "$BUILD_ROOT/$otar" ]]; then
      download_tar \
        "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/$otar" \
        "https://www.openssl.org/source/$otar" \
        "$BUILD_ROOT/$otar"
    fi
    log "Extracting $otar (official OpenSSL)"
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
    log "Extracting $ztar (official zlib)"
    tar -xf "$BUILD_ROOT/$ztar" -C "$BUILD_ROOT"
  fi
}

resolve_abi() {
  case "$1" in
    arm64|aarch64|arm64-v8a)
      ABI=arm64-v8a
      TRIPLE=aarch64-linux-android
      CLANG_PREFIX=aarch64-linux-android
      OPENSSL_TARGET=android-arm64
      ;;
    arm|armeabi-v7a|armv7)
      ABI=armeabi-v7a
      TRIPLE=armv7a-linux-androideabi
      CLANG_PREFIX=armv7a-linux-androideabi
      OPENSSL_TARGET=android-arm
      ;;
    x86_64|x64)
      ABI=x86_64
      TRIPLE=x86_64-linux-android
      CLANG_PREFIX=x86_64-linux-android
      OPENSSL_TARGET=android-x86_64
      ;;
    x86|i686)
      ABI=x86
      TRIPLE=i686-linux-android
      CLANG_PREFIX=i686-linux-android
      OPENSSL_TARGET=android-x86
      ;;
    *)
      echo "Unknown ABI: $1 (arm64|arm|x86_64|x86|all)"
      exit 1
      ;;
  esac
}

set_cross_env() {
  export CC="${CLANG_PREFIX}${API}-clang"
  export CXX="${CLANG_PREFIX}${API}-clang++"
  export AR=llvm-ar
  export RANLIB=llvm-ranlib
  export STRIP=llvm-strip
  export NM=llvm-nm
  export CFLAGS="-O2 -fPIC -DANDROID -fno-addrsig"
  export CXXFLAGS="$CFLAGS"
  unset LDFLAGS LIBS CPPFLAGS PKG_CONFIG_PATH || true
}

build_zlib() {
  local prefix="$1"
  local stamp="$prefix/.stamp-zlib-${ZLIB_VER}"
  if [[ -f "$stamp" && -f "$prefix/lib/libz.a" ]]; then
    log "zlib ${ZLIB_VER} already installed -> $prefix"
    return 0
  fi

  local src="$BUILD_ROOT/zlib-${ZLIB_VER}"
  local bdir="$BUILD_ROOT/zlib-build-$ABI"
  rm -rf "$bdir"
  # zlib in-tree configure is simplest; use a clean copy
  cp -a "$src" "$bdir"
  cd "$bdir"

  set_cross_env
  export CHOST="$TRIPLE"
  # static only
  ./configure --static --prefix="$prefix" >configure.log 2>&1 || {
    echo "ERROR: zlib configure failed"; tail -40 configure.log; exit 1
  }
  make -j"$JOBS" >make.log 2>&1 || {
    echo "ERROR: zlib make failed"; grep -iE 'error:' make.log | tail -20; exit 1
  }
  make install >install.log 2>&1 || {
    echo "ERROR: zlib install failed"; tail -20 install.log; exit 1
  }
  touch "$stamp"
  log "zlib OK -> $prefix/lib/libz.a"
}

build_openssl() {
  local prefix="$1"
  local stamp="$prefix/.stamp-openssl-${OPENSSL_VER}"
  if [[ -f "$stamp" && -f "$prefix/lib/libssl.a" && -f "$prefix/lib/libcrypto.a" ]]; then
    log "OpenSSL ${OPENSSL_VER} already installed -> $prefix"
    return 0
  fi
  # OpenSSL 3 may install to lib64 on some hosts; we force --libdir=lib
  local src="$BUILD_ROOT/openssl-${OPENSSL_VER}"
  local bdir="$BUILD_ROOT/openssl-build-$ABI"
  rm -rf "$bdir"
  cp -a "$src" "$bdir"
  cd "$bdir"

  set_cross_env
  # OpenSSL uses its own android-* targets; needs NDK on PATH + ANDROID_NDK_ROOT
  log "Configuring OpenSSL ${OPENSSL_VER} ($OPENSSL_TARGET, API $API)"
  ./Configure "$OPENSSL_TARGET" \
    -D__ANDROID_API__="${API}" \
    --prefix="$prefix" \
    --libdir=lib \
    no-shared \
    no-tests \
    no-ui-console \
    no-docs \
    >configure.log 2>&1 || {
      echo "ERROR: OpenSSL Configure failed"; tail -50 configure.log; exit 1
    }
  make -j"$JOBS" >make.log 2>&1 || {
    echo "ERROR: OpenSSL make failed"; grep -iE 'error:|fatal' make.log | tail -30; exit 1
  }
  make install_sw >install.log 2>&1 || {
    echo "ERROR: OpenSSL install_sw failed"; tail -40 install.log; exit 1
  }
  # Some layouts put libs under lib64
  if [[ ! -f "$prefix/lib/libssl.a" ]]; then
    if [[ -f "$prefix/lib64/libssl.a" ]]; then
      mkdir -p "$prefix/lib"
      cp -a "$prefix/lib64/"*.a "$prefix/lib/" 2>/dev/null || true
    fi
  fi
  [[ -f "$prefix/lib/libssl.a" && -f "$prefix/lib/libcrypto.a" ]] || {
    echo "ERROR: OpenSSL static libs missing under $prefix/lib"
    find "$prefix" -name 'libssl*' -o -name 'libcrypto*' | head
    exit 1
  }
  touch "$stamp"
  log "OpenSSL OK -> $prefix/lib/libssl.a"
}

build_curl() {
  local prefix="$1"
  local dest="$2"
  local src="$BUILD_ROOT/curl-${CURL_VER}"
  local bdir="$BUILD_ROOT/curl-build-$ABI"

  rm -rf "$bdir"
  mkdir -p "$bdir" "$dest"
  cd "$bdir"

  set_cross_env
  export CFLAGS="-O2 -fPIE -fPIC -DANDROID -fno-addrsig -I${prefix}/include"
  export CPPFLAGS="-I${prefix}/include"
  # Static OpenSSL + zlib into PIE curl; still dynamic vs Bionic.
  export LDFLAGS="-pie -L${prefix}/lib"
  export LIBS="-lssl -lcrypto -lz"
  export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig"
  # Avoid picking host pkg-config openssl
  export PKG_CONFIG_LIBDIR="${prefix}/lib/pkgconfig"
  export PKG_CONFIG_SYSROOT_DIR=

  log "Configuring curl ${CURL_VER} for $ABI"
  "$src/configure" \
    --host="${TRIPLE}" \
    --build="$(uname -m)-pc-linux-gnu" \
    --prefix="/data/local/tmp/curl" \
    --with-ssl="${prefix}" \
    --with-zlib="${prefix}" \
    --disable-shared \
    --enable-static \
    --enable-ipv6 \
    --enable-threaded-resolver \
    --disable-ldap \
    --disable-ldaps \
    --disable-rtsp \
    --disable-dict \
    --disable-telnet \
    --disable-tftp \
    --disable-pop3 \
    --disable-imap \
    --disable-smb \
    --disable-smtp \
    --disable-gopher \
    --disable-mqtt \
    --disable-manual \
    --disable-docs \
    --without-libpsl \
    --without-brotli \
    --without-zstd \
    --without-libidn2 \
    --without-libssh2 \
    --without-nghttp2 \
    --without-nghttp3 \
    --without-ngtcp2 \
    --without-librtmp \
    --without-ca-bundle \
    --without-ca-path \
    --with-ca-fallback \
    >configure.log 2>&1 || {
      echo "ERROR: curl configure failed. See $bdir/configure.log"
      tail -60 configure.log
      exit 1
    }

  # Force the curl tool link line to pull static ssl/crypto/z if needed
  # (configure usually gets this via LIBS / libcurl.la)
  make -j"$JOBS" >make.log 2>&1 || {
    echo "ERROR: curl make failed. See $bdir/make.log"
    grep -iE 'error:|undefined symbol' make.log | tail -40
    tail -40 make.log
    exit 1
  }

  local bin=""
  if [[ -f src/curl ]]; then
    bin=src/curl
  elif [[ -f curl ]]; then
    bin=curl
  else
    echo "ERROR: curl binary not found"
    find . -name curl -type f | head
    exit 1
  fi

  if file "$bin" | grep -q 'statically linked'; then
    echo "ERROR: fully static binary — arm64 Bionic TLS underalignment risk"
    exit 1
  fi

  cp -f "$bin" "$dest/curl.unstripped"
  llvm-strip -s -o "$dest/curl" "$bin"
  chmod 755 "$dest/curl"

  {
    echo "curl ${CURL_VER}"
    echo "ABI: $ABI"
    echo "API: $API"
    echo "NDK: $(grep Pkg.Revision "$NDK/source.properties" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
    echo "source: official curl.se + openssl.org + zlib"
    echo "TLS: OpenSSL ${OPENSSL_VER} (static)"
    echo "zlib: ${ZLIB_VER} (static)"
    echo "link: dynamic PIE (bionic) + static ssl/crypto/z"
    echo "features: HTTPS via OpenSSL; HTTP/2 disabled (no nghttp2)"
    file "$dest/curl"
    ls -lh "$dest/curl"
    echo "--- needed libs ---"
    llvm-readobj --needed-libs "$dest/curl" 2>/dev/null || true
    echo "--- TLS PHDR ---"
    readelf -l "$dest/curl" | grep -A1 TLS || echo "(no TLS PHDR)"
    # feature list from binary strings if curl --version not runnable
    strings "$dest/curl" | grep -E 'OpenSSL/|curl/[0-9]|libcurl/' | head -10
  } | tee "$dest/BUILD_INFO.txt"

  log "OK -> $dest/curl"
}

build_one() {
  local name="$1"
  resolve_abi "$name"

  local prefix="$BUILD_ROOT/prefix-$ABI"
  local dest="$OUT_DIR/$ABI"

  log "=== $ABI ==="
  mkdir -p "$prefix" "$dest"
  build_zlib "$prefix"
  build_openssl "$prefix"
  build_curl "$prefix" "$dest"
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
  log "curl=${CURL_VER} openssl=${OPENSSL_VER} zlib=${ZLIB_VER} API=${API}"
  local t
  for t in "${targets[@]}"; do build_one "$t"; done
  log "Done. Binaries under: $OUT_DIR"
  find "$OUT_DIR" -type f -name curl ! -name '*.unstripped' -exec ls -lh {} \;
}

main "$@"
