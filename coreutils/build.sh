#!/usr/bin/env bash
# Cross-compile official GNU coreutils for Android (NDK clang + Bionic).
#
# Source: https://ftp.gnu.org/gnu/coreutils/coreutils-<ver>.tar.xz
# NOT Termux packages — only GNU upstream tarballs.
#
# Usage (from repo root or coreutils/):
#   ./coreutils/build.sh                 # default arm64, coreutils 9.11, API 24
#   ./coreutils/build.sh arm64
#   ./coreutils/build.sh arm64 arm
#   ./coreutils/build.sh all
#   COREUTILS_VER=9.11 API=28 ./coreutils/build.sh arm64
#   NDK=/opt/android-ndk-r27d ./coreutils/build.sh arm64
#
# Output:
#   out/<ABI>/bin/coreutils          # multicall PIE binary
#   out/<ABI>/bin/{ls,cp,...}        # symlinks -> coreutils
#   out/<ABI>/BUILD_INFO.txt
#
# Notes:
#   - Dynamic PIE (not fully static) — arm64 static TLS underalignment abort.
#   - --enable-single-binary=symlinks for one-file push to device.
#   - Skips pinky/users/who/stdbuf (useless / needs LD_PRELOAD).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-/tmp/coreutils-android-build}"
COREUTILS_VER="${COREUTILS_VER:-9.11}"
API="${API:-24}"
OUT_DIR="${OUT_DIR:-$ROOT/out}"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
JOBS="$(nproc 2>/dev/null || echo 2)"

# Programs not useful or not portable on Android without extra deps
NO_INSTALL_PROGRAM="${NO_INSTALL_PROGRAM:-pinky,users,who,stdbuf}"

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
[[ -d "$TOOLCHAIN" ]] || { echo "ERROR: NDK toolchain missing"; exit 1; }
export PATH="$TOOLCHAIN/bin:$PATH"

log() { printf '==> %s\n' "$*"; }

download_tar() {
  local dest="${*: -1}"
  local urls=("${@:1:$#-1}") u
  for u in "${urls[@]}"; do
    log "Downloading $u"
    if wget -q -O "$dest" "$u" || curl -fsSL -o "$dest" "$u"; then
      return 0
    fi
    rm -f "$dest"
  done
  echo "Failed to download: ${urls[*]}"
  return 1
}

ensure_source() {
  mkdir -p "$BUILD_ROOT"
  local tar="coreutils-${COREUTILS_VER}.tar.xz"
  local src_dir="$BUILD_ROOT/coreutils-${COREUTILS_VER}"
  if [[ ! -d "$src_dir" ]]; then
    if [[ ! -f "$BUILD_ROOT/$tar" ]]; then
      download_tar \
        "https://mirrors.kernel.org/gnu/coreutils/$tar" \
        "https://ftp.gnu.org/gnu/coreutils/$tar" \
        "$BUILD_ROOT/$tar"
    fi
    log "Extracting $tar (official GNU)"
    tar -xf "$BUILD_ROOT/$tar" -C "$BUILD_ROOT"
  fi

  # Apply Android patches (idempotent)
  apply_patches "$src_dir"
}

apply_patches() {
  local src_dir="$1"
  local stamp="$src_dir/.android-patches-applied"
  if [[ -f "$stamp" ]]; then
    return 0
  fi

  # hostid declaration patch works across 9.5–9.11
  local p
  for p in "$ROOT/patches/"*gethostid*.patch; do
    [[ -f "$p" ]] || continue
    if grep -q 'ANDROID_GETHOSTID_DECL' "$src_dir/src/hostid.c" 2>/dev/null; then
      log "gethostid patch already present"
      continue
    fi
    log "Applying $(basename "$p")"
    (cd "$src_dir" && patch -p1 --forward < "$p") || true
  done

  # timezone_t: only needed on older gnulib (coreutils <= 9.5) where there is a bare
  # "typedef struct tm_zone *timezone_t" that collides with Bionic.
  # coreutils 9.6+ / 9.11: gnulib has HAVE_TIMEZONE_T / rpl_timezone_t branching —
  # we force that path via configure cache vars instead of patching.
  if grep -q 'GNULIB_defined_timezone_t\|HAVE_TZALLOC\|rpl_timezone_t' "$src_dir/lib/time.in.h" 2>/dev/null; then
    log "time.in.h: modern gnulib (9.6+) — use configure cache for timezone_t (no source patch)"
  else
    for p in "$ROOT/patches/"*timezone*.patch; do
      [[ -f "$p" ]] || continue
      if grep -q 'gl_timezone_t' "$src_dir/lib/time.in.h" 2>/dev/null; then
        log "timezone patch already present"
        continue
      fi
      log "Applying $(basename "$p") (legacy gnulib)"
      (cd "$src_dir" && patch -p1 --forward < "$p") || true
    done
  fi

  ensure_inline_patches "$src_dir"
  touch "$stamp"
}

ensure_inline_patches() {
  local src_dir="$1"

  # hostid.c declaration (all versions)
  if ! grep -q 'ANDROID_GETHOSTID_DECL' "$src_dir/src/hostid.c"; then
    python3 - "$src_dir/src/hostid.c" << 'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
insert = "\n/* ANDROID_GETHOSTID_DECL: Bionic lacks gethostid declaration/export. */\nlong gethostid (void);\n"
key = '#include "system.h"'
if key not in t:
    raise SystemExit("system.h include not found in hostid.c")
i = t.find(key)
e = t.find("\n", i)
p.write_text(t[: e + 1] + insert + t[e + 1 :])
print("inline-patched hostid.c")
PY
  fi

  # Legacy time.in.h only (pre-9.6 style bare typedef)
  if grep -q 'GNULIB_defined_timezone_t\|rpl_timezone_t' "$src_dir/lib/time.in.h" 2>/dev/null; then
    return 0
  fi
  if grep -q 'gl_timezone_t' "$src_dir/lib/time.in.h" 2>/dev/null; then
    return 0
  fi
  python3 - "$src_dir/lib/time.in.h" << 'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = "/* Represents a time zone.\n   (timezone_t) NULL stands for UTC.  */\ntypedef struct tm_zone *timezone_t;"
new = """/* Represents a time zone.
   (timezone_t) NULL stands for UTC.  */
/* ANDROID: Bionic (API < 35) typedefs an incomplete timezone_t without mktime_z.
   Shadow it with a macro so this gnulib typedef binds to a new name. */
#if defined __ANDROID__
# define timezone_t gl_timezone_t
#endif
typedef struct tm_zone *timezone_t;"""
if old not in t:
    # Non-fatal for versions we don't recognize — build may still work via configure caches.
    print(f"WARN: legacy time.in.h pattern missing in {p}; skipping shadow patch")
    raise SystemExit(0)
p.write_text(t.replace(old, new, 1))
print("inline-patched time.in.h (legacy)")
PY
}

resolve_abi() {
  case "$1" in
    arm64|aarch64|arm64-v8a)
      ABI=arm64-v8a; TRIPLE=aarch64-linux-android; CLANG_PREFIX=aarch64-linux-android ;;
    arm|armeabi-v7a|armv7)
      ABI=armeabi-v7a; TRIPLE=armv7a-linux-androideabi; CLANG_PREFIX=armv7a-linux-androideabi ;;
    x86_64|x64)
      ABI=x86_64; TRIPLE=x86_64-linux-android; CLANG_PREFIX=x86_64-linux-android ;;
    x86|i686)
      ABI=x86; TRIPLE=i686-linux-android; CLANG_PREFIX=i686-linux-android ;;
    *)
      echo "Unknown ABI: $1 (arm64|arm|x86_64|x86|all)"; exit 1 ;;
  esac
}

build_one() {
  local name="$1"
  resolve_abi "$name"

  local src_dir="$BUILD_ROOT/coreutils-${COREUTILS_VER}"
  local build_dir="$BUILD_ROOT/build-$ABI"
  local dest="$OUT_DIR/$ABI"
  local cc="${CLANG_PREFIX}${API}-clang"
  local compat_c="$ROOT/compat/android_compat.c"

  log "Building official GNU coreutils ${COREUTILS_VER} for $ABI (API $API)"
  log "NDK: $NDK"
  log "CC : $cc"

  rm -rf "$build_dir"
  mkdir -p "$build_dir" "$dest/bin"
  cd "$build_dir"

  export CC="$cc"
  export CXX="${CLANG_PREFIX}${API}-clang++"
  export AR=llvm-ar RANLIB=llvm-ranlib STRIP=llvm-strip
  # Do NOT put -include into configure CFLAGS (breaks gnulib feature tests).
  export CFLAGS="-O2 -fPIE -fPIC -DANDROID -fno-addrsig -D__USE_FORTIFY_LEVEL=0"
  export LDFLAGS="-pie"
  unset LIBS CPPFLAGS

  "$cc" $CFLAGS -c "$compat_c" -o android_compat.o

  # Bionic always has timezone_t typedef, but tzalloc/mktime_z only for API >= 35.
  # modern gnulib (9.6+): ac_cv_type_timezone_t=yes → rpl_timezone_t + #define
  # legacy gnulib (9.5):  ac_cv_type_timezone_t=no  + source shadow patch
  local tz_type_cv=yes
  if ! grep -q 'rpl_timezone_t\|GNULIB_defined_timezone_t' "$src_dir/lib/time.in.h" 2>/dev/null; then
    tz_type_cv=no
  fi

  "$src_dir/configure" \
    --host="${TRIPLE}" \
    --build="$(uname -m)-pc-linux-gnu" \
    --prefix="/data/local/tmp/coreutils" \
    --disable-nls \
    --disable-rpath \
    --disable-acl \
    --disable-xattr \
    --disable-libcap \
    --without-selinux \
    --without-libgmp \
    --with-openssl=no \
    --enable-single-binary=symlinks \
    --enable-no-install-program="${NO_INSTALL_PROGRAM}" \
    --enable-install-program=arch,hostname \
    gl_cv_host_operating_system=Android \
    ac_cv_func_malloc_0_nonnull=yes \
    ac_cv_func_realloc_0_nonnull=yes \
    ac_cv_func_calloc_0_nonnull=yes \
    ac_cv_func_gethostid=yes \
    ac_cv_type_timezone_t=${tz_type_cv} \
    ac_cv_func_tzalloc=no \
    ac_cv_func_tzfree=no \
    ac_cv_func_localtime_rz=no \
    ac_cv_func_mktime_z=no \

    gl_cv_func_working_mktime=yes \
    gl_cv_func_working_re_compile_pattern=yes \
    gl_cv_func_printf_directive_n=no \
    gl_cv_func_printf_infinite=yes \
    gl_cv_func_printf_infinite_long_double=yes \
    gl_cv_func_snprintf_retval_c99=yes \
    gl_cv_func_snprintf_truncation_c99=yes \
    gl_cv_func_strstr_linear=yes \
    gl_cv_func_strtod_works=yes \
    gl_cv_func_tzset_clobbers_localtime=no \
    gl_cv_func_getcwd_null=yes \
    gl_cv_func_getcwd_path_max=yes \
    gl_cv_func_getcwd_abort_bug=no \
    gl_cv_func_fcntl_f_dupfd_cloexec=yes \
    gl_cv_func_fdopendir_works=yes \
    gl_cv_func_fstatat_zero_flag=yes \
    gl_cv_func_lstat_dereferences_slashed_symlink=yes \
    gl_cv_func_mkdir_trailing_slash_bug=no \
    gl_cv_func_realpath_works=yes \
    gl_cv_func_symlink_works=yes \
    gl_cv_func_ungetc_works=yes \
    gl_cv_have_proc_uptime=yes \
    utils_cv_localtime_cache=no \
    am_cv_func_working_getline=yes \
    >configure.log 2>&1 || {
      echo "ERROR: configure failed. See $build_dir/configure.log"
      tail -40 configure.log
      exit 1
    }

  # Inject gethostid stub only into the multicall binary link line
  python3 - << 'PY'
from pathlib import Path
p = Path("Makefile")
lines = p.read_text().splitlines(True)
out = []
did = False
for line in lines:
    if (not did) and line.startswith("src_coreutils_LDADD =") and "android_compat.o" not in line:
        line = line.rstrip("\n") + " $(top_builddir)/android_compat.o\n"
        did = True
        print("patched src_coreutils_LDADD")
    out.append(line)
if not did:
    raise SystemExit("src_coreutils_LDADD not found")
p.write_text("".join(out))
PY

  make -j"$JOBS" >make.log 2>&1 || {
    echo "ERROR: make failed. See $build_dir/make.log"
    grep -iE 'error:|undefined symbol' make.log | tail -40
    exit 1
  }

  if [[ ! -f src/coreutils ]]; then
    echo "ERROR: src/coreutils not produced"
    exit 1
  fi
  if file src/coreutils | grep -q 'statically linked'; then
    echo "ERROR: static binary would abort on arm64 Bionic (TLS)"
    exit 1
  fi

  # Install into staging to get symlink applets
  local stage="$build_dir/stage"
  rm -rf "$stage"
  make install DESTDIR="$stage" >install.log 2>&1

  local bindir
  bindir="$(find "$stage" -type d -name bin | head -1)"
  [[ -n "$bindir" ]] || { echo "ERROR: install produced no bin/"; exit 1; }

  rm -rf "$dest/bin"
  mkdir -p "$dest/bin"
  cp -a "$bindir/." "$dest/bin/"
  # Replace with stripped multicall
  cp -f src/coreutils "$dest/bin/coreutils.unstripped"
  llvm-strip -s -o "$dest/bin/coreutils" src/coreutils
  chmod 755 "$dest/bin/coreutils"

  # Normalize symlinks to point at coreutils
  (
    cd "$dest/bin"
    for f in *; do
      [[ "$f" == coreutils || "$f" == coreutils.unstripped ]] && continue
      rm -f "$f"
      ln -s coreutils "$f"
    done
  )

  {
    echo "coreutils ${COREUTILS_VER}"
    echo "ABI: $ABI"
    echo "API: $API"
    echo "NDK: $(grep Pkg.Revision "$NDK/source.properties" 2>/dev/null | cut -d= -f2 | tr -d ' ')"
    echo "source: GNU official (ftp.gnu.org/gnu/coreutils)"
    echo "link: dynamic PIE (bionic)"
    echo "mode: single-binary=symlinks"
    echo "skipped: ${NO_INSTALL_PROGRAM}"
    echo "compat: gethostid stub; timezone_t shadow (API < 35)"
    file "$dest/bin/coreutils"
    ls -lh "$dest/bin/coreutils"
    echo "applets: $(find "$dest/bin" -type l | wc -l)"
    echo "--- needed libs ---"
    llvm-readobj --needed-libs "$dest/bin/coreutils" 2>/dev/null || true
  } | tee "$dest/BUILD_INFO.txt"

  log "OK -> $dest/bin/coreutils"
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
  ensure_source
  local -a targets
  mapfile -t targets < <(expand_targets "$@")
  [[ ${#targets[@]} -eq 0 ]] && targets=(arm64)
  log "Targets: ${targets[*]}"
  log "coreutils=${COREUTILS_VER} API=${API}"
  local t
  for t in "${targets[@]}"; do build_one "$t"; done
  log "Done. Binaries under: $OUT_DIR"
  find "$OUT_DIR" -type f -name coreutils -exec ls -lh {} \;
}

main "$@"
