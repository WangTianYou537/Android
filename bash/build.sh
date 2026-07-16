#!/usr/bin/env bash
# Build GNU bash for Android (PIE, dynamically linked against Bionic)
# WITH readline + ncurses support.
#
# Usage (from repo root or bash/):
#   ./bash/build.sh                            # default: arm64 API 24
#   ./bash/build.sh arm64
#   ./bash/build.sh arm64 arm                  # multi-ABI
#   ./bash/build.sh all                        # all four ABIs
#   API=28 ./bash/build.sh arm64 arm
#   BASH_VER=5.2.37 ./bash/build.sh all
#   NDK=/path/to/ndk ./bash/build.sh arm64
#
# Why not fully static?
#   Static arm64 binaries abort on modern Android Bionic with:
#     "executable's TLS segment is underaligned: alignment is 8, needs to be at least 64"
#   Link dynamically against Bionic instead (only needs system libc/libdl).
#
# Notes:
#   getgrent/getpwent family is forced off (Bionic headers only declare them
#   for API >= 26). Only group/username DB completion is lost; path/cmd Tab
#   completion is unaffected.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-/tmp/bash4droid-build}"
BASH_VER="${BASH_VER:-5.3}"
API="${API:-24}"
OUT_DIR="${OUT_DIR:-$ROOT/out}"

# Versions of readline & ncurses to cross-compile
READLINE_VER="${READLINE_VER:-8.3}"
NCURSES_VER="${NCURSES_VER:-6.5}"

# Package dir = bash/; repo root = parent (for shared NDK / future packages)
REPO_ROOT="$(cd "$ROOT/.." && pwd)"

if [[ -z "${NDK:-}" ]]; then
  for cand in \
    "$REPO_ROOT/android-ndk-r27d" \
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

# ---------------------------------------------------------------------------
# Source download helpers
# ---------------------------------------------------------------------------

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

ensure_ncurses() {
  local tar="ncurses-${NCURSES_VER}.tar.gz"
  if [[ ! -d "$BUILD_ROOT/ncurses-${NCURSES_VER}" ]]; then
    if [[ ! -f "$BUILD_ROOT/$tar" ]]; then
      log "Downloading ncurses ${NCURSES_VER}..."
      local urls=(
        "https://mirrors.kernel.org/gnu/ncurses/$tar"
        "https://ftp.gnu.org/gnu/ncurses/$tar"
        "https://invisible-mirror.net/archives/ncurses/$tar"
      )
      local ok=0
      for u in "${urls[@]}"; do
        if wget -q -O "$BUILD_ROOT/$tar" "$u" || curl -fsSL -o "$BUILD_ROOT/$tar" "$u"; then
          ok=1
          break
        fi
      done
      [[ $ok -eq 1 ]] || { echo "Failed to download ncurses source"; exit 1; }
    fi
    log "Extracting $tar"
    tar -xf "$BUILD_ROOT/$tar" -C "$BUILD_ROOT"
  fi
}

ensure_readline() {
  local tar="readline-${READLINE_VER}.tar.gz"
  if [[ ! -d "$BUILD_ROOT/readline-${READLINE_VER}" ]]; then
    if [[ ! -f "$BUILD_ROOT/$tar" ]]; then
      log "Downloading readline ${READLINE_VER}..."
      local urls=(
        "https://mirrors.kernel.org/gnu/readline/$tar"
        "https://ftp.gnu.org/gnu/readline/$tar"
      )
      local ok=0
      for u in "${urls[@]}"; do
        if wget -q -O "$BUILD_ROOT/$tar" "$u" || curl -fsSL -o "$BUILD_ROOT/$tar" "$u"; then
          ok=1
          break
        fi
      done
      [[ $ok -eq 1 ]] || { echo "Failed to download readline source"; exit 1; }
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

# ---------------------------------------------------------------------------
# ABI resolution
# ---------------------------------------------------------------------------

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
      echo "Multiple ABIs: ./bash/build.sh arm64 arm x86_64"
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Android: disable passwd/group iteration (needs API 26+)
# Critical: must #undef at END of config.h so it wins over earlier #define.
# CFLAGS -U is NOT enough — config.h re-#defines after command-line -U.
# ---------------------------------------------------------------------------

android_disable_grent_pwent() {
  local cfg="$1"
  [[ -f "$cfg" ]] || { echo "ERROR: $cfg missing after configure"; exit 1; }

  # Drop any previous injection (reconfigure / retry safe)
  if grep -q 'ANDROID_DISABLE_GRENT_PWENT' "$cfg"; then
    # delete from marker to EOF
    sed -i '/ANDROID_DISABLE_GRENT_PWENT/,$d' "$cfg"
  fi

  cat >> "$cfg" << 'EOF'

/* ANDROID_DISABLE_GRENT_PWENT
 * Bionic only declares getgrent/getpwent family for API >= 26.
 * Configure link-tests may still set HAVE_*=1; force them off so
 * bashline.c group/user DB completion is not compiled.
 * Path / command / variable Tab completion is unaffected.
 */
#undef HAVE_GETGRENT
#undef HAVE_SETGRENT
#undef HAVE_ENDGRENT
#undef HAVE_GETPWENT
#undef HAVE_SETPWENT
#undef HAVE_ENDPWENT
#undef HAVE_GETGRENT_R
#undef HAVE_GETPWENT_R
EOF

  log "config.h: forced #undef of getgrent/getpwent family"
  grep -nE 'HAVE_(GET|SET|END)(GR|PW)ENT' "$cfg" | tail -20 || true
}

# ---------------------------------------------------------------------------
# Cross-compile ncurses for one ABI
# ---------------------------------------------------------------------------

build_ncurses() {
  local ncurses_build="$BUILD_ROOT/ncurses-build-$ABI"
  local ncurses_prefix="$BUILD_ROOT/prefix-$ABI"

  if [[ -f "$ncurses_prefix/lib/libncursesw.a" ]]; then
    log "ncurses already built for $ABI, skipping"
    return
  fi

  log "Building ncurses ${NCURSES_VER} for $ABI"
  rm -rf "$ncurses_build"
  mkdir -p "$ncurses_build"
  cd "$ncurses_build"

  export CC="${CLANG_PREFIX}${API}-clang"
  export CXX="${CLANG_PREFIX}${API}-clang++"
  export AR=llvm-ar
  export RANLIB=llvm-ranlib
  export STRIP=llvm-strip
  export CFLAGS="-O2 -fPIE -fPIC -DANDROID"
  export LDFLAGS="-pie"
  unset LIBS CPPFLAGS PKG_CONFIG_PATH || true

  "$BUILD_ROOT/ncurses-${NCURSES_VER}/configure" \
    --host="${TRIPLE}" \
    --build="$(uname -m)-pc-linux-gnu" \
    --prefix="$ncurses_prefix" \
    --with-shared \
    --with-normal \
    --with-termlib \
    --enable-widec \
    --enable-pc-files \
    --disable-database \
    --disable-home-terminfo \
    --with-fallbacks="xterm,xterm-256color,linux,vt100,screen,screen-256color,tmux,tmux-256color" \
    --without-debug \
    --without-tests \
    --without-progs \
    --without-cxx-binding \
    --without-ada \
    --without-manpages \
    --without-cxx \
    --enable-overwrite \
    >configure.log 2>&1 || {
      echo "ERROR: ncurses configure failed. See $ncurses_build/configure.log"
      tail -30 configure.log
      exit 1
    }

  make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)" >make.log 2>&1 || {
    echo "ERROR: ncurses make failed. See $ncurses_build/make.log"
    grep -iE 'error:|undefined' make.log | tail -20
    exit 1
  }

  make install >install.log 2>&1 || {
    echo "ERROR: ncurses make install failed. See $ncurses_build/install.log"
    exit 1
  }

  log "ncurses OK -> $ncurses_prefix"
}

# ---------------------------------------------------------------------------
# Cross-compile readline for one ABI (static lib, linked into bash)
# ---------------------------------------------------------------------------

build_readline() {
  local rl_build="$BUILD_ROOT/readline-build-$ABI"
  local ncurses_prefix="$BUILD_ROOT/prefix-$ABI"
  local rl_prefix="$BUILD_ROOT/prefix-$ABI"

  if [[ -f "$rl_prefix/lib/libreadline.a" ]]; then
    log "readline already built for $ABI, skipping"
    return
  fi

  log "Building readline ${READLINE_VER} for $ABI"
  rm -rf "$rl_build"
  mkdir -p "$rl_build"
  cd "$rl_build"

  export CC="${CLANG_PREFIX}${API}-clang"
  export CXX="${CLANG_PREFIX}${API}-clang++"
  export AR=llvm-ar
  export RANLIB=llvm-ranlib
  export STRIP=llvm-strip
  export CFLAGS="-O2 -fPIE -fPIC -DANDROID -I${ncurses_prefix}/include -I${ncurses_prefix}/include/ncursesw"
  export LDFLAGS="-L${ncurses_prefix}/lib"
  export CPPFLAGS="-I${ncurses_prefix}/include -I${ncurses_prefix}/include/ncursesw"
  unset LIBS PKG_CONFIG_PATH || true

  "$BUILD_ROOT/readline-${READLINE_VER}/configure" \
    --host="${TRIPLE}" \
    --build="$(uname -m)-pc-linux-gnu" \
    --prefix="$rl_prefix" \
    --enable-static \
    --disable-shared \
    --with-curses \
    >configure.log 2>&1 || {
      echo "ERROR: readline configure failed. See $rl_build/configure.log"
      tail -30 configure.log
      exit 1
    }

  make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)" >make.log 2>&1 || {
    echo "ERROR: readline make failed. See $rl_build/make.log"
    grep -iE 'error:|undefined' make.log | tail -20
    exit 1
  }

  make install >install.log 2>&1 || {
    echo "ERROR: readline make install failed. See $rl_build/install.log"
    exit 1
  }

  log "readline OK -> $rl_prefix"
}

# ---------------------------------------------------------------------------
# Build bash for one ABI
# ---------------------------------------------------------------------------

build_one() {
  local name="$1"
  resolve_abi "$name"

  local build_dir="$BUILD_ROOT/bash-build-$ABI"
  local dest="$OUT_DIR/$ABI"
  local cc="${CLANG_PREFIX}${API}-clang"
  local prefix_dir="$BUILD_ROOT/prefix-$ABI"

  # 1. Build ncurses & readline for this ABI (idempotent)
  build_ncurses
  build_readline

  log "Building bash ${BASH_VER} for $ABI (API $API) [dynamic PIE, readline=yes]"
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
  export CFLAGS="-O2 -fPIE -fPIC -DANDROID -fno-addrsig -I${prefix_dir}/include -I${prefix_dir}/include/ncursesw"
  export CPPFLAGS="-I${prefix_dir}/include -I${prefix_dir}/include/ncursesw"
  export LDFLAGS="-pie -L${prefix_dir}/lib"
  export LIBS="-lreadline -lncursesw -ltinfow"
  export PKG_CONFIG_PATH="${prefix_dir}/lib/pkgconfig"

  # Also pre-seed autoconf cache (belt); real fix is config.h #undef below.
  export ac_cv_func_getgrent=no
  export ac_cv_func_setgrent=no
  export ac_cv_func_endgrent=no
  export ac_cv_func_getpwent=no
  export ac_cv_func_setpwent=no
  export ac_cv_func_endpwent=no

  # Cross-compile mblen shim
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
    --enable-readline \
    --with-installed-readline="${prefix_dir}" \
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
    ac_cv_func_getgrent=no \
    ac_cv_func_setgrent=no \
    ac_cv_func_endgrent=no \
    ac_cv_func_getpwent=no \
    ac_cv_func_setpwent=no \
    ac_cv_func_endpwent=no \
    >configure.log 2>&1 || {
      echo "ERROR: bash configure failed. See $build_dir/configure.log"
      tail -40 configure.log
      exit 1
    }

  # **** 真正生效的修复：config.h 末尾强制 #undef ****
  android_disable_grent_pwent "$build_dir/config.h"

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
line_end = t.find("\n", m.start())
line = t[m.start():line_end]
if "android_compat.o" not in line:
    t = t[:m.end()] + "android_compat.o " + t[m.end():]
    p.write_text(t)
print("OBJECTS ok")
PY

  make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)" >make.log 2>&1 || {
    echo "ERROR: make failed. See $build_dir/make.log"
    grep -iE 'error:|undefined symbol' make.log | tail -40
    echo "---- config.h (grent/pwent) ----"
    grep -nE 'HAVE_(GET|SET|END)(GR|PW)ENT|ANDROID_DISABLE' config.h | tail -30 || true
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

  # Copy terminfo database for on-device use
  if [[ -d "$prefix_dir/share/terminfo" ]]; then
    cp -a "$prefix_dir/share/terminfo" "$dest/terminfo"
  fi

  {
    echo "bash ${BASH_VER}"
    echo "ABI: $ABI"
    echo "API: $API"
    echo "NDK: $(grep Pkg.Revision "$NDK/source.properties" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
    echo "link: dynamic PIE (bionic)"
    echo "static: no"
    echo "readline: yes (${READLINE_VER})"
    echo "ncurses: yes (${NCURSES_VER}, wide-char)"
    echo "compat: mblen via android_compat.o"
    echo "getgrent/getpwent: disabled (config.h #undef, Android API < 26 safe)"
    file "$dest/bash"
    ls -lh "$dest/bash"
    echo "--- needed libs ---"
    llvm-readobj --needed-libs "$dest/bash" 2>/dev/null || true
    echo "--- TLS ---"
    readelf -l "$dest/bash" | grep -A1 TLS || echo "(no TLS PHDR)"
  } | tee "$dest/BUILD_INFO.txt"

  log "OK -> $dest/bash"
}

# ---------------------------------------------------------------------------
# Expand "all" / dedupe while preserving order
# ---------------------------------------------------------------------------

expand_targets() {
  local -a raw=("$@")
  local -a out=()
  local t a
  if [[ ${#raw[@]} -eq 0 ]]; then
    raw=(arm64)
  fi
  for t in "${raw[@]}"; do
    if [[ "$t" == "all" ]]; then
      out+=(arm64 arm x86_64 x86)
    else
      out+=("$t")
    fi
  done
  # dedupe
  local -a uniq=()
  for a in "${out[@]}"; do
    local seen=0
    for u in "${uniq[@]+"${uniq[@]}"}"; do
      [[ "$u" == "$a" ]] && { seen=1; break; }
    done
    [[ $seen -eq 0 ]] && uniq+=("$a")
  done
  printf '%s\n' "${uniq[@]}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  ensure_source
  ensure_ncurses
  ensure_readline
  ensure_compat

  local -a targets
  mapfile -t targets < <(expand_targets "$@")
  if [[ ${#targets[@]} -eq 0 ]]; then
    targets=(arm64)
  fi

  log "Targets: ${targets[*]}"
  log "bash=${BASH_VER} readline=${READLINE_VER} ncurses=${NCURSES_VER} api=${API}"
  local t
  for t in "${targets[@]}"; do
    build_one "$t"
  done

  log "Done. Binaries under: $OUT_DIR"
  find "$OUT_DIR" -type f -name bash -exec ls -lh {} \;
}

main "$@"