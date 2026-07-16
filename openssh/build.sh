#!/usr/bin/env bash
# Cross-compile official OpenSSH Portable for Android (NDK clang + Bionic).
#
# Sources (upstream only):
#   OpenSSH: https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/
#   OpenSSL: https://www.openssl.org/source/  (static)
#   zlib:    https://github.com/madler/zlib/releases  (static)
#
# Usage:
#   ./openssh/build.sh                    # default arm64 API 24
#   ./openssh/build.sh arm64
#   ./openssh/build.sh all
#   OPENSSH_VER=9.9p2 OPENSSL_VER=3.3.3 ./openssh/build.sh arm64
#
# Output:
#   out/<ABI>/{ssh,scp,sftp,sshd,ssh-keygen,...}
#   out/<ABI>/BUILD_INFO.txt
#
# Notes:
#   - Clients + server are dynamic PIE against Bionic; OpenSSL/zlib static.
#   - Fully static arm64 binaries abort on modern Bionic (TLS underalignment).
#   - Sandbox disabled (seccomp not portable for generic Android userland).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-/tmp/openssh-android-build}"
OPENSSH_VER="${OPENSSH_VER:-9.9p2}"
OPENSSL_VER="${OPENSSL_VER:-3.3.3}"
ZLIB_VER="${ZLIB_VER:-1.3.1}"
API="${API:-24}"
OUT_DIR="${OUT_DIR:-$ROOT/out}"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
JOBS="$(nproc 2>/dev/null || echo 2)"
PREFIX_SHARED="${PREFIX_SHARED:-}"  # optional: reuse curl's static prefix
LINK_MODE="${LINK_MODE:-static}"    # static|dynamic
DEPS_PREFIX="${DEPS_PREFIX:-}"      # dynamic: common/deps/out/<ABI>

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

  local otar="openssh-${OPENSSH_VER}.tar.gz"
  if [[ ! -d "$BUILD_ROOT/openssh-${OPENSSH_VER}" ]]; then
    if [[ ! -f "$BUILD_ROOT/$otar" ]]; then
      download_tar \
        "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/$otar" \
        "https://ftp.openbsd.org/pub/OpenBSD/OpenSSH/portable/$otar" \
        "$BUILD_ROOT/$otar"
    fi
    log "Extracting $otar (official OpenSSH portable)"
    tar -xf "$BUILD_ROOT/$otar" -C "$BUILD_ROOT"
  fi

  local ssl_tar="openssl-${OPENSSL_VER}.tar.gz"
  if [[ ! -d "$BUILD_ROOT/openssl-${OPENSSL_VER}" ]]; then
    if [[ ! -f "$BUILD_ROOT/$ssl_tar" ]]; then
      download_tar \
        "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/$ssl_tar" \
        "https://www.openssl.org/source/$ssl_tar" \
        "$BUILD_ROOT/$ssl_tar"
    fi
    log "Extracting $ssl_tar"
    tar -xf "$BUILD_ROOT/$ssl_tar" -C "$BUILD_ROOT"
  fi

  local ztar="zlib-${ZLIB_VER}.tar.gz"
  if [[ ! -d "$BUILD_ROOT/zlib-${ZLIB_VER}" ]]; then
    if [[ ! -f "$BUILD_ROOT/$ztar" ]]; then
      download_tar \
        "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/$ztar" \
        "https://zlib.net/fossils/$ztar" \
        "$BUILD_ROOT/$ztar"
    fi
    log "Extracting $ztar"
    tar -xf "$BUILD_ROOT/$ztar" -C "$BUILD_ROOT"
  fi

  apply_patches "$BUILD_ROOT/openssh-${OPENSSH_VER}"
}

apply_patches() {
  local src_dir="$1"
  local stamp="$src_dir/.android-patches-applied"
  [[ -f "$stamp" ]] && return 0
  local p
  for p in "$ROOT/patches/"*.patch; do
    [[ -f "$p" ]] || continue
    log "Applying $(basename "$p")"
    (cd "$src_dir" && patch -p1 --forward < "$p") || {
      log "WARN: patch may already be applied: $(basename "$p")"
    }
  done
  touch "$stamp"
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
  [[ -f "$prefix/lib/libssl.a" ]] || { echo "OpenSSL libs missing"; exit 1; }
  touch "$stamp"
  log "OpenSSL OK"
}

post_configure_fixes() {
  local cfg="$1/config.h"
  # clang supports sentinel attribute
  if ! grep -q 'HAVE_ATTRIBUTE__SENTINEL__ 1' "$cfg"; then
    echo '#define HAVE_ATTRIBUTE__SENTINEL__ 1' >> "$cfg"
  fi
  # Bionic has bzero as macro/inline
  if grep -q '/\* #undef HAVE_BZERO \*/' "$cfg"; then
    sed -i 's|/\* #undef HAVE_BZERO \*/|#define HAVE_BZERO 1|' "$cfg"
  fi
  # mblen: avoid empty openbsd macro path
  if grep -q '/\* #undef HAVE_MBLEN \*/' "$cfg"; then
    sed -i 's|/\* #undef HAVE_MBLEN \*/|#define HAVE_MBLEN 1|' "$cfg"
  fi
  # mail dir
  if grep -q '/\* #undef MAIL_DIRECTORY \*/' "$cfg"; then
    sed -i 's|/\* #undef MAIL_DIRECTORY \*/|#define MAIL_DIRECTORY "/data/local/tmp/ssh/mail"|' "$cfg"
  elif ! grep -q 'MAIL_DIRECTORY' "$cfg"; then
    echo '#define MAIL_DIRECTORY "/data/local/tmp/ssh/mail"' >> "$cfg"
  fi
}

build_one() {
  local name="$1"
  resolve_abi "$name"

  local prefix
  local src="$BUILD_ROOT/openssh-${OPENSSH_VER}"
  local bdir="$BUILD_ROOT/build-$ABI"
  local dest="$OUT_DIR/$ABI"
  local cc="${CLANG_PREFIX}${API}-clang"
  local rpath_flag=""  # set via patchelf post-link

  if [[ "$LINK_MODE" == "dynamic" ]]; then
    prefix="${DEPS_PREFIX:-$REPO_ROOT/common/deps/out/$ABI}"
    if [[ ! -e "$prefix/lib/libssl.so" && ! -e "$prefix/lib/libssl.so.3" ]]; then
      echo "ERROR: shared deps missing at $prefix (run ./common/deps/build.sh $name)"
      exit 1
    fi
    log "Using shared deps: $prefix"
    rpath_flag=""
  else
    prefix="${PREFIX_SHARED:-$BUILD_ROOT/prefix-$ABI}"
    if [[ -z "${PREFIX_SHARED}" && -f /tmp/curl-android-build/prefix-$ABI/lib/libssl.a ]]; then
      prefix="/tmp/curl-android-build/prefix-$ABI"
      log "Reusing OpenSSL/zlib prefix: $prefix"
    fi
  fi

  mkdir -p "$dest"
  if [[ "$LINK_MODE" != "dynamic" ]]; then
    mkdir -p "$prefix"
    if [[ "$prefix" != /tmp/curl-android-build/prefix-* ]]; then
      build_zlib "$prefix"
      build_openssl "$prefix"
    fi
  fi

  log "Building OpenSSH ${OPENSSH_VER} for $ABI (API $API) LINK_MODE=$LINK_MODE"
  rm -rf "$bdir"
  mkdir -p "$bdir"
  cd "$bdir"

  export CC="$cc" CXX="${CLANG_PREFIX}${API}-clang++"
  export AR=llvm-ar RANLIB=llvm-ranlib STRIP=llvm-strip
  export CFLAGS="-O2 -fPIE -fPIC -DANDROID -fno-addrsig -I${prefix}/include"
  export CPPFLAGS="-I${prefix}/include"
  export LDFLAGS="-pie -L${prefix}/lib ${rpath_flag}"
  export LIBS="-lssl -lcrypto -lz"

  "$src/configure" \
    --host="${TRIPLE}" \
    --build="$(uname -m)-pc-linux-gnu" \
    --prefix="/data/local/tmp/ssh" \
    --with-ssl-dir="$prefix" \
    --with-zlib="$prefix" \
    --with-pie \
    --with-sandbox=no \
    --without-openssl-header-check \
    --without-zlib-version-check \
    --disable-etc-default-login \
    --disable-lastlog --disable-utmp --disable-utmpx \
    --disable-wtmp --disable-wtmpx \
    --disable-pututline --disable-pututxline \
    --with-privsep-path=/data/local/tmp/ssh/empty \
    --with-privsep-user=shell \
    --with-maildir=/data/local/tmp/ssh/mail \
    --without-pam --without-selinux --without-kerberos5 \
    --without-libedit --without-ldns \
    --without-security-key-builtin \
    ac_cv_file__dev_ptmx=yes \
    ac_cv_file__dev_ptc=no \
    ac_cv_func_setresuid=yes \
    ac_cv_func_setresgid=yes \
    ac_cv_have_decl___attribute__=yes \
    >configure.log 2>&1 || {
      echo "ERROR: OpenSSH configure failed"; tail -50 configure.log; exit 1
    }

  post_configure_fixes "$bdir"

  # Compile Android stubs and inject into LIBS
  "$cc" -O2 -fPIE -fPIC -DANDROID -c "$ROOT/compat/android_compat.c" -o android_compat.o
  # Patch Makefile LIBS
  if grep -q '^LIBS=' Makefile; then
    sed -i 's|^LIBS=.*|LIBS=android_compat.o -lssl -lcrypto -lz|' Makefile
  fi

  make -j"$JOBS" >make.log 2>&1 || {
    echo "ERROR: OpenSSH make failed"; grep -iE 'error:' make.log | sort -u | tail -40; exit 1
  }

  local bins=(ssh scp sftp ssh-keygen ssh-add ssh-agent sshd ssh-keyscan
              sftp-server ssh-keysign ssh-pkcs11-helper ssh-sk-helper sshd-session)
  local b
  for b in "${bins[@]}"; do
    if [[ -f "$b" ]]; then
      if file "$b" | grep -q 'statically linked'; then
        echo "ERROR: $b is fully static (TLS risk on arm64)"
        exit 1
      fi
      llvm-strip -s -o "$dest/$b" "$b"
      chmod 755 "$dest/$b"
    fi
  done
  [[ -f "$dest/ssh" ]] || { echo "ERROR: ssh binary missing"; exit 1; }

  if [[ "$LINK_MODE" == "dynamic" ]]; then
    mkdir -p "$dest/lib"
    local f
    for f in "$prefix"/lib/libz.so* "$prefix"/lib/libssl.so* "$prefix"/lib/libcrypto.so*; do
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
    for b in "$dest"/ssh "$dest"/scp "$dest"/sftp "$dest"/sshd "$dest"/ssh-keygen              "$dest"/ssh-add "$dest"/ssh-agent "$dest"/ssh-keyscan              "$dest"/sftp-server "$dest"/ssh-keysign "$dest"/sshd-session; do
      [[ -f "$b" ]] || continue
      set_rpath '$ORIGIN/lib' "$b"
    done
    set_rpath '$ORIGIN' "$dest"/lib/libssl.so* "$dest"/lib/libcrypto.so* 2>/dev/null || true
  fi

  {
    echo "OpenSSH ${OPENSSH_VER} (portable)"
    echo "ABI: $ABI"
    echo "API: $API"
    echo "NDK: $(grep Pkg.Revision "$NDK/source.properties" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
    echo "source: official OpenBSD portable"
    echo "TLS: OpenSSL ${OPENSSL_VER} (${LINK_MODE})"
    echo "zlib: ${ZLIB_VER} (${LINK_MODE})"
    echo "link_mode: ${LINK_MODE}"
    echo "link: dynamic PIE (bionic) + ${LINK_MODE} ssl/crypto/z"
    echo "sandbox: none"
    file "$dest/ssh"
    ls -lh "$dest"
    echo "--- needed libs (ssh) ---"
    llvm-readobj --needed-libs "$dest/ssh" 2>/dev/null || true
  } | tee "$dest/BUILD_INFO.txt"

  log "OK -> $dest/ssh"
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
  log "openssh=${OPENSSH_VER} openssl=${OPENSSL_VER} zlib=${ZLIB_VER} API=${API} LINK_MODE=${LINK_MODE}"
  local t
  for t in "${targets[@]}"; do build_one "$t"; done
  log "Done. Binaries under: $OUT_DIR"
  find "$OUT_DIR" -type f -name ssh -exec ls -lh {} \;
}

main "$@"
