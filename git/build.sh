#!/usr/bin/env bash
# Cross-compile official git for Android (NDK clang + Bionic).
#
# Sources (upstream only):
#   git:     https://www.kernel.org/pub/software/scm/git/
#   OpenSSL: https://www.openssl.org/source/  (static)
#   zlib:    https://github.com/madler/zlib  (static)
#   curl:    https://curl.se/download/       (static libcurl for HTTPS)
#
# Usage:
#   ./git/build.sh                          # default arm64, git 2.49.0
#   ./git/build.sh arm64
#   ./git/build.sh all
#   GIT_VER=2.49.0 OPENSSL_VER=3.3.3 ./git/build.sh arm64
#
# Output:
#   out/<ABI>/bin/git
#   out/<ABI>/bin/git-remote-http[s]
#   out/<ABI>/libexec/git-core/...
#   out/<ABI>/BUILD_INFO.txt
#
# Notes:
#   - git is dynamic PIE vs Bionic; OpenSSL/zlib/libcurl are static.
#   - NO_GETTEXT/NO_PERL/NO_PYTHON/NO_ICONV/NO_EXPAT for a lean Android build.
#   - Bionic lacks pthread_setcancelstate (API-independent) and sync_file_range
#     declarations below API 26 — handled via compat header / config.mak.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-/tmp/git-android-build}"
GIT_VER="${GIT_VER:-2.49.0}"
OPENSSL_VER="${OPENSSL_VER:-3.3.3}"
ZLIB_VER="${ZLIB_VER:-1.3.1}"
CURL_VER="${CURL_VER:-8.21.0}"
API="${API:-24}"
OUT_DIR="${OUT_DIR:-$ROOT/out}"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
JOBS="$(nproc 2>/dev/null || echo 2)"
LINK_MODE="${LINK_MODE:-static}"   # static|dynamic
DEPS_PREFIX="${DEPS_PREFIX:-}"     # dynamic: common/deps/out/<ABI>

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

  local gtar="git-${GIT_VER}.tar.xz"
  if [[ ! -d "$BUILD_ROOT/git-${GIT_VER}" ]]; then
    if [[ ! -f "$BUILD_ROOT/$gtar" ]]; then
      download_tar \
        "https://mirrors.edge.kernel.org/pub/software/scm/git/$gtar" \
        "https://www.kernel.org/pub/software/scm/git/$gtar" \
        "$BUILD_ROOT/$gtar"
    fi
    log "Extracting $gtar (official git)"
    tar -xf "$BUILD_ROOT/$gtar" -C "$BUILD_ROOT"
  fi

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

build_zlib() {
  local prefix="$1"
  local stamp="$prefix/.stamp-zlib-${ZLIB_VER}"
  [[ -f "$stamp" && -f "$prefix/lib/libz.a" ]] && { log "zlib ready"; return; }
  local bdir="$BUILD_ROOT/zlib-build-$ABI"
  rm -rf "$bdir"
  cp -a "$BUILD_ROOT/zlib-${ZLIB_VER}" "$bdir"
  cd "$bdir"
  set_cross_env
  export CHOST="$TRIPLE"
  ./configure --static --prefix="$prefix" >configure.log 2>&1
  make -j"$JOBS" >make.log 2>&1
  make install >install.log 2>&1
  touch "$stamp"
  log "zlib OK"
}

build_openssl() {
  local prefix="$1"
  local stamp="$prefix/.stamp-openssl-${OPENSSL_VER}"
  [[ -f "$stamp" && -f "$prefix/lib/libssl.a" ]] && { log "OpenSSL ready"; return; }
  local bdir="$BUILD_ROOT/openssl-build-$ABI"
  rm -rf "$bdir"
  cp -a "$BUILD_ROOT/openssl-${OPENSSL_VER}" "$bdir"
  cd "$bdir"
  set_cross_env
  ./Configure "$OPENSSL_TARGET" -D__ANDROID_API__="${API}" \
    --prefix="$prefix" --libdir=lib \
    no-shared no-tests no-ui-console no-docs \
    >configure.log 2>&1
  make -j"$JOBS" >make.log 2>&1
  make install_sw >install.log 2>&1
  [[ -f "$prefix/lib/libssl.a" ]] || { echo "OpenSSL missing"; exit 1; }
  touch "$stamp"
  log "OpenSSL OK"
}

build_libcurl() {
  local prefix="$1"
  local stamp="$prefix/.stamp-libcurl-${CURL_VER}"
  [[ -f "$stamp" && -f "$prefix/lib/libcurl.a" ]] && { log "libcurl ready"; return; }
  local bdir="$BUILD_ROOT/curl-lib-build-$ABI"
  rm -rf "$bdir"
  mkdir -p "$bdir"
  cd "$bdir"
  set_cross_env
  export CFLAGS="-O2 -fPIC -DANDROID -fno-addrsig -I${prefix}/include"
  export CPPFLAGS="-I${prefix}/include"
  export LDFLAGS="-L${prefix}/lib"
  export LIBS="-lssl -lcrypto -lz"
  export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig"
  "$BUILD_ROOT/curl-${CURL_VER}/configure" \
    --host="${TRIPLE}" --build="$(uname -m)-pc-linux-gnu" \
    --prefix="$prefix" \
    --with-ssl="$prefix" --with-zlib="$prefix" \
    --disable-shared --enable-static \
    --enable-ipv6 --disable-ldap --disable-ldaps \
    --disable-manual --disable-docs \
    --without-libpsl --without-brotli --without-zstd \
    --without-libidn2 --without-libssh2 --without-nghttp2 \
    --without-ca-bundle --without-ca-path --with-ca-fallback \
    >configure.log 2>&1
  make -j"$JOBS" >make.log 2>&1
  make install >install.log 2>&1
  [[ -f "$prefix/lib/libcurl.a" ]] || { echo "libcurl.a missing"; exit 1; }
  touch "$stamp"
  log "libcurl OK"
}

build_one() {
  local name="$1"
  resolve_abi "$name"

  local prefix
  local dest="$OUT_DIR/$ABI"
  local cc="${CLANG_PREFIX}${API}-clang"
  local compat_h="$ROOT/compat/android_compat.h"
  local bdir="$BUILD_ROOT/git-build-$ABI"
  local rpath_flag=""
  local curl_libs=""
  local ext_libs=""

  if [[ "$LINK_MODE" == "dynamic" ]]; then
    prefix="${DEPS_PREFIX:-$REPO_ROOT/common/deps/out/$ABI}"
    if [[ ! -e "$prefix/lib/libcurl.so" && ! -e "$prefix/lib/libcurl.so.4" ]]; then
      echo "ERROR: shared deps missing at $prefix (run ./common/deps/build.sh $name)"
      exit 1
    fi
    log "Using shared deps: $prefix"
    rpath_flag=""
    curl_libs="-L${prefix}/lib -lcurl -lssl -lcrypto -lz -ldl"
    ext_libs="-lssl -lcrypto -lz -ldl -lm"
  else
    prefix="$BUILD_ROOT/prefix-$ABI"
    if [[ -f /tmp/curl-android-build/prefix-$ABI/lib/libssl.a ]]; then
      prefix="/tmp/curl-android-build/prefix-$ABI"
      log "Reusing deps prefix: $prefix"
    fi
    mkdir -p "$prefix"
    if [[ "$prefix" != /tmp/curl-android-build/prefix-* ]]; then
      build_zlib "$prefix"
      build_openssl "$prefix"
    fi
    build_libcurl "$prefix"
    curl_libs="${prefix}/lib/libcurl.a ${prefix}/lib/libssl.a ${prefix}/lib/libcrypto.a ${prefix}/lib/libz.a -ldl"
    ext_libs="${prefix}/lib/libssl.a ${prefix}/lib/libcrypto.a ${prefix}/lib/libz.a -ldl -lm"
  fi

  mkdir -p "$dest/bin" "$dest/libexec/git-core"
  log "Building git ${GIT_VER} for $ABI (API $API) LINK_MODE=$LINK_MODE"
  rm -rf "$bdir"
  cp -a "$BUILD_ROOT/git-${GIT_VER}" "$bdir"
  cd "$bdir"

  cat > config.mak << EOF
override uname_S = Linux
override uname_M = $( [[ "$ABI" == arm64-v8a ]] && echo aarch64 || ([[ "$ABI" == armeabi-v7a ]] && echo armv7l || echo "$ABI") )
override uname_O = Android
# API < 26: sync_file_range not declared in Bionic headers
HAVE_SYNC_FILE_RANGE =
NEEDS_LIBRT =
# Bionic: pthreads in libc
PTHREAD_LIBS =

CC = ${cc}
AR = llvm-ar
RANLIB = llvm-ranlib
STRIP = llvm-strip
CFLAGS = -O2 -fPIE -fPIC -DANDROID -fno-addrsig -I${prefix}/include -include ${compat_h}
LDFLAGS = -pie -L${prefix}/lib ${rpath_flag}
ARFLAGS = rc

NO_GETTEXT = YesPlease
NO_TCLTK = YesPlease
NO_PERL = YesPlease
NO_PYTHON = YesPlease
NO_ICONV = YesPlease
NO_NSEC = YesPlease
NO_EXPAT = YesPlease

OPENSSLDIR = ${prefix}
ZLIB_PATH = ${prefix}
CURLDIR = ${prefix}
CURL_CONFIG = /bin/false
CURL_CFLAGS = -I${prefix}/include
CURL_LDFLAGS =
override CURL_LIBCURL = ${curl_libs}
OPENSSL_LINK =
EXTLIBS = ${ext_libs}

prefix = /data/local/tmp/git
EOF

  make -j"$JOBS" git >make-git.log 2>&1 || {
    echo "ERROR: git make failed"; grep -iE 'error:' make-git.log | tail -40; exit 1
  }
  make -j"$JOBS" \
    git-remote-http git-remote-https \
    git-daemon git-http-backend git-http-fetch \
    >make-helpers.log 2>&1 || {
    echo "ERROR: git helpers make failed"; grep -iE 'error:|undefined' make-helpers.log | tail -40; exit 1
  }

  [[ -f git ]] || { echo "ERROR: git binary missing"; exit 1; }
  if file git | grep -q 'statically linked'; then
    echo "ERROR: fully static git (TLS risk on arm64)"
    exit 1
  fi

  local b
  for b in git git-daemon git-remote-http git-remote-https git-http-fetch git-http-backend; do
    [[ -f "$b" ]] || continue
    llvm-strip -s -o "$dest/bin/$b" "$b"
    chmod 755 "$dest/bin/$b"
  done
  (
    cd "$dest/bin"
    ln -sfn git-remote-http git-remote-ftp
    ln -sfn git-remote-http git-remote-ftps
  )
  # libexec layout (optional helpers path)
  cp -a "$dest/bin/git" "$dest/libexec/git-core/git"
  for b in git-remote-http git-remote-https git-daemon git-http-backend git-http-fetch; do
    [[ -f "$dest/bin/$b" ]] && cp -a "$dest/bin/$b" "$dest/libexec/git-core/"
  done
  (
    cd "$dest/libexec/git-core"
    ln -sfn git-remote-http git-remote-https 2>/dev/null || true
    ln -sfn git-remote-http git-remote-ftp
    ln -sfn git-remote-http git-remote-ftps
  )

  if [[ "$LINK_MODE" == "dynamic" ]]; then
    mkdir -p "$dest/lib"
    local f
    for f in "$prefix"/lib/libz.so* "$prefix"/lib/libssl.so* "$prefix"/lib/libcrypto.so* "$prefix"/lib/libcurl.so*; do
      [[ -e "$f" ]] || continue
      cp -a "$f" "$dest/lib/"
    done
    for f in "$dest"/lib/*.so*; do
      [[ -f "$f" && ! -L "$f" ]] || continue
      llvm-strip -s "$f" 2>/dev/null || true
    done
    # shellcheck source=../common/set-rpath.sh
    source "$REPO_ROOT/common/set-rpath.sh"
    local b
    for b in "$dest"/bin/*; do
      [[ -f "$b" && ! -L "$b" ]] || continue
      set_rpath '$ORIGIN/../lib' "$b"
    done
    for b in "$dest"/libexec/git-core/*; do
      [[ -f "$b" && ! -L "$b" ]] || continue
      set_rpath '$ORIGIN/../../lib' "$b"
    done
    set_rpath '$ORIGIN' "$dest"/lib/libcurl.so* "$dest"/lib/libssl.so* "$dest"/lib/libcrypto.so* 2>/dev/null || true
  fi

  {
    echo "git ${GIT_VER}"
    echo "ABI: $ABI"
    echo "API: $API"
    echo "NDK: $(grep Pkg.Revision "$NDK/source.properties" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
    echo "source: official kernel.org git"
    echo "HTTPS: libcurl ${CURL_VER} + OpenSSL ${OPENSSL_VER} + zlib ${ZLIB_VER} (${LINK_MODE})"
    echo "link_mode: ${LINK_MODE}"
    echo "link: dynamic PIE (bionic)"
    echo "NO_GETTEXT/NO_PERL/NO_PYTHON/NO_ICONV/NO_EXPAT"
    echo "compat: pthread_setcancelstate stub; no sync_file_range (API < 26)"
    file "$dest/bin/git"
    ls -lh "$dest/bin"
    echo "--- needed (git) ---"
    llvm-readobj --needed-libs "$dest/bin/git" 2>/dev/null || true
    if [[ -f "$dest/bin/git-remote-http" ]]; then
      echo "--- needed (git-remote-http) ---"
      llvm-readobj --needed-libs "$dest/bin/git-remote-http" 2>/dev/null || true
    fi
  } | tee "$dest/BUILD_INFO.txt"

  log "OK -> $dest/bin/git"
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
  log "git=${GIT_VER} curl=${CURL_VER} openssl=${OPENSSL_VER} zlib=${ZLIB_VER} API=${API} LINK_MODE=${LINK_MODE}"
  local t
  for t in "${targets[@]}"; do build_one "$t"; done
  log "Done. Binaries under: $OUT_DIR"
  find "$OUT_DIR" -type f -name git -exec ls -lh {} \;
}

main "$@"
