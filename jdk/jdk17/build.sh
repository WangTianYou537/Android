#!/usr/bin/env bash
# Build OpenJDK 17 (headless JRE/JDK) for Android with NDK r27d + clang.
#
# Usage (from repo root or jdk/jdk17/):
#   ./jdk/jdk17/build.sh                 # default: arm64 API 24
#   ./jdk/jdk17/build.sh arm64
#   ./jdk/jdk17/build.sh arm64 x86_64    # multi-ABI
#   ./jdk/jdk17/build.sh all
#   API=28 JOBS=2 ./jdk/jdk17/build.sh arm64
#   JDK_TAG=jdk-17.0.10-ga ./jdk/jdk17/build.sh arm64
#   NDK=/opt/android-ndk-r27d ./jdk/jdk17/build.sh arm64
#
# Output:
#   out/<ABI>/jre/   — runnable JRE tree (push to device)
#   out/<ABI>/jdk/   — full JDK tree
#   out/<ABI>/jre17-<abi>-release.tar.xz
#   out/<ABI>/jdk17-<abi>-release.tar.xz
#
# Based on FCL-Team/Android-OpenJDK-Build (Build_JRE_17) patches,
# reworked for NDK r27d LLVM clang (no GCC standalone toolchain / no NDK r21).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-/tmp/android-jdk-build}"
JDK_TAG="${JDK_TAG:-jdk-17.0.10-ga}"
FREETYPE_VER="${FREETYPE_VER:-2.10.0}"
CUPS_VER="${CUPS_VER:-2.2.4}"
API="${API:-24}"
OUT_DIR="${OUT_DIR:-$ROOT/out}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
# Cap jobs on low-memory hosts (Hotspot link is memory hungry)
if [[ -z "${JOBS_FORCE:-}" ]]; then
  mem_kb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 2000000)
  if (( mem_kb < 3000000 )) && (( JOBS > 2 )); then
    JOBS=2
  fi
fi
JDK_DEBUG_LEVEL="${JDK_DEBUG_LEVEL:-release}"
JVM_VARIANTS="${JVM_VARIANTS:-server}"

# Package = jdk/jdk17 ; monorepo root = ../../
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"

# ---------- NDK discovery (prefer r27) ----------
if [[ -z "${NDK:-}" ]]; then
  for cand in \
    /opt/android-ndk-r27d \
    "$REPO_ROOT/android-ndk-r27d" \
    "$ROOT/android-ndk-r27d" \
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
  echo "ERROR: Android NDK not found. Set NDK=/opt/android-ndk-r27d"
  exit 1
fi

HOST_TAG=linux-x86_64
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
if [[ ! -d "$TOOLCHAIN" ]]; then
  echo "ERROR: NDK LLVM toolchain missing under $NDK/toolchains/llvm/prebuilt"
  exit 1
fi
SYSROOT="$TOOLCHAIN/sysroot"
# Host tools (/usr/bin) MUST come before NDK bin: host clang++ looks up "ld" on PATH,
# and NDK's ld is LLD which rejects incomplete JVM version-scripts.
# Target wrappers (aarch64-linux-android24-clang, llvm-ar, …) keep unique names.
export PATH="/usr/bin:$TOOLCHAIN/bin:$PATH"

# Host boot JDK
if [[ -z "${JAVA_HOME:-}" ]]; then
  for j in /usr/lib/jvm/java-17-openjdk-amd64 /usr/lib/jvm/java-17-openjdk /usr/lib/jvm/default-java; do
    if [[ -x "$j/bin/javac" ]]; then JAVA_HOME=$j; break; fi
  done
fi
if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/javac" ]]; then
  echo "ERROR: Boot JDK 17 required. Install: sudo apt install openjdk-17-jdk-headless"
  exit 1
fi
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

log() { printf '==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

resolve_abi() {
  case "$1" in
    arm64|aarch64|arm64-v8a)
      ABI=arm64-v8a
      TARGET=aarch64-linux-android
      TARGET_JDK=aarch64
      TARGET_SHORT=arm64
      CLANG_PREFIX=aarch64-linux-android
      HOTSPOT_ARCH=aarch64
      if [[ -z "${JVM_VARIANTS_FORCE:-}" ]]; then
        JVM_VARIANTS=server
      fi
      ;;
    arm|armeabi-v7a|armv7)
      ABI=armeabi-v7a
      TARGET=armv7a-linux-androideabi
      TARGET_JDK=arm
      TARGET_SHORT=arm
      CLANG_PREFIX=armv7a-linux-androideabi
      HOTSPOT_ARCH=arm
      # client JVM is lighter on 32-bit arm
      if [[ -z "${JVM_VARIANTS_FORCE:-}" ]]; then
        JVM_VARIANTS=client
      fi
      ;;
    x86_64|x64)
      ABI=x86_64
      TARGET=x86_64-linux-android
      TARGET_JDK=x86_64
      TARGET_SHORT=x86_64
      CLANG_PREFIX=x86_64-linux-android
      HOTSPOT_ARCH=x86_64
      if [[ -z "${JVM_VARIANTS_FORCE:-}" ]]; then
        JVM_VARIANTS=server
      fi
      ;;
    x86|i686)
      ABI=x86
      TARGET=i686-linux-android
      TARGET_JDK=x86
      TARGET_SHORT=x86
      CLANG_PREFIX=i686-linux-android
      HOTSPOT_ARCH=x86
      if [[ -z "${JVM_VARIANTS_FORCE:-}" ]]; then
        JVM_VARIANTS=client
      fi
      ;;
    *)
      die "Unknown ABI: $1 (supported: arm64, arm, x86_64, x86)"
      ;;
  esac
}

# ---------- sources ----------
ensure_openjdk() {
  mkdir -p "$BUILD_ROOT"
  if [[ ! -d "$BUILD_ROOT/openjdk/.git" ]]; then
    log "Cloning OpenJDK $JDK_TAG ..."
    rm -rf "$BUILD_ROOT/openjdk"
    git clone --branch "$JDK_TAG" --depth 1 https://github.com/openjdk/jdk17u "$BUILD_ROOT/openjdk"
  else
    log "OpenJDK source present: $BUILD_ROOT/openjdk"
  fi
}

ensure_libs_src() {
  mkdir -p "$BUILD_ROOT"
  if [[ ! -d "$BUILD_ROOT/freetype-$FREETYPE_VER" ]]; then
    log "Downloading FreeType $FREETYPE_VER ..."
    local tar="freetype-$FREETYPE_VER.tar.gz"
    if [[ ! -f "$BUILD_ROOT/$tar" ]]; then
      wget -nv -O "$BUILD_ROOT/$tar" \
        "https://downloads.sourceforge.net/project/freetype/freetype2/$FREETYPE_VER/$tar" \
        || curl -fsSL -o "$BUILD_ROOT/$tar" \
        "https://download.savannah.gnu.org/releases/freetype/$tar"
    fi
    tar -xf "$BUILD_ROOT/$tar" -C "$BUILD_ROOT"
  fi
  if [[ ! -d "$BUILD_ROOT/cups-$CUPS_VER" ]]; then
    log "Downloading CUPS $CUPS_VER (headers only) ..."
    local tar="cups-$CUPS_VER-source.tar.gz"
    if [[ ! -f "$BUILD_ROOT/$tar" ]]; then
      wget -nv -O "$BUILD_ROOT/$tar" \
        "https://github.com/apple/cups/releases/download/v$CUPS_VER/$tar" \
        || curl -fsSL -o "$BUILD_ROOT/$tar" \
        "https://github.com/apple/cups/releases/download/v$CUPS_VER/$tar"
    fi
    tar -xf "$BUILD_ROOT/$tar" -C "$BUILD_ROOT"
  fi
}

# ---------- FreeType for target ----------
build_freetype() {
  local prefix="$BUILD_ROOT/freetype-$FREETYPE_VER/build_android-$TARGET_SHORT"
  if [[ -f "$prefix/lib/libfreetype.a" || -f "$prefix/lib/libfreetype.so" ]]; then
    log "FreeType already built: $prefix"
    FREETYPE_DIR=$prefix
    return 0
  fi
  log "Building FreeType for $ABI (API $API) ..."
  local src="$BUILD_ROOT/freetype-$FREETYPE_VER"
  # clean previous in-tree config
  if [[ -f "$src/config.mk" || -f "$src/builds/unix/config.status" ]]; then
    make -C "$src" distclean >/dev/null 2>&1 || true
  fi
  pushd "$src" >/dev/null
  export CC="${CLANG_PREFIX}${API}-clang"
  export CXX="${CLANG_PREFIX}${API}-clang++"
  export AR=llvm-ar
  export RANLIB=llvm-ranlib
  export STRIP=llvm-strip
  export CFLAGS="-O2 -fPIC -fPIE"
  export LDFLAGS="-pie"
  ./configure \
    --host="$TARGET" \
    --prefix="$prefix" \
    --without-zlib \
    --with-png=no \
    --with-harfbuzz=no \
    --with-bzip2=no \
    --enable-shared \
    --disable-static \
    >"$BUILD_ROOT/freetype-configure-$ABI.log" 2>&1 \
    || { cat "$BUILD_ROOT/freetype-configure-$ABI.log"; die "freetype configure failed"; }
  make -j"$JOBS" >"$BUILD_ROOT/freetype-make-$ABI.log" 2>&1 \
    || { tail -50 "$BUILD_ROOT/freetype-make-$ABI.log"; die "freetype make failed"; }
  make install >>"$BUILD_ROOT/freetype-make-$ABI.log" 2>&1
  popd >/dev/null
  # Do not leak target flags into OpenJDK configure
  unset CC CXX AR RANLIB STRIP CFLAGS LDFLAGS
  FREETYPE_DIR=$prefix
  log "FreeType OK -> $FREETYPE_DIR"
}

# Dummy empty archives: OpenJDK link lines often pull -lpthread -lrt -lthread_db
# which Bionic folds into libc. Provide empty .a so the linker is happy.
make_dummy_libs() {
  local d="$BUILD_ROOT/dummy_libs-$ABI"
  mkdir -p "$d"
  if [[ ! -f "$d/libpthread.a" ]]; then
    llvm-ar cru "$d/libpthread.a"
    llvm-ar cru "$d/librt.a"
    llvm-ar cru "$d/libthread_db.a"
  fi
  DUMMY_LIBS=$d
}

# ---------- configure + build OpenJDK ----------
build_jdk() {
  local dest="$OUT_DIR/$ABI"
  local work="$BUILD_ROOT/jdk-build-$ABI"
  local patch="$ROOT/patches/jdk17u_android.diff"
  [[ -f "$patch" ]] || die "Missing Android patch: $patch"

  log "Building OpenJDK $JDK_TAG for $ABI (API $API, $JVM_VARIANTS, clang/NDK r27)"
  log "NDK: $NDK"
  log "JAVA_HOME: $JAVA_HOME"
  log "JOBS: $JOBS"

  # Fresh source tree copy per ABI so patches/configure don't fight
  rm -rf "$work"
  mkdir -p "$work"
  # Use git worktree-like cheap copy via hardlinks where possible
  cp -a "$BUILD_ROOT/openjdk/." "$work/"

  pushd "$work" >/dev/null

  log "Applying Android patch ..."
  # Prefer git apply, fall back to patch
  if ! git apply --reject --whitespace=fix "$patch" >"$BUILD_ROOT/patch-$ABI.log" 2>&1; then
    if ! patch -p1 < "$patch" >>"$BUILD_ROOT/patch-$ABI.log" 2>&1; then
      tail -80 "$BUILD_ROOT/patch-$ABI.log"
      log "WARNING: patch had rejects; continuing (some may be expected on this tag)"
    fi
  fi

  # Bionic posix_spawn is API 28+. Main patch adds libjava/posix_spawn.{c,h}
  # but ProcessImpl_md.c still includes system <spawn.h>, which has no
  # prototype under minSdk < 28 → -Werror-ish implicit-function-declaration.
  local spawn_fix="src/java.base/unix/native/libjava/ProcessImpl_md.c"
  local spawn_patch="$ROOT/patches/processimpl_posix_spawn_compat.diff"
  if [[ -f "$spawn_fix" ]]; then
    if grep -q '#include <spawn.h>' "$spawn_fix"; then
      log "Pointing ProcessImpl_md.c at local posix_spawn.h (API < 28 compat)"
      if [[ -f "$spawn_patch" ]]; then
        patch -p1 < "$spawn_patch" >>"$BUILD_ROOT/patch-$ABI.log" 2>&1 \
          || sed -i 's|#include <spawn.h>|#include "posix_spawn.h"|' "$spawn_fix"
      else
        sed -i 's|#include <spawn.h>|#include "posix_spawn.h"|' "$spawn_fix"
      fi
    fi
    # Sanity: compat sources must exist (from main Android patch)
    if [[ ! -f src/java.base/unix/native/libjava/posix_spawn.c \
       || ! -f src/java.base/unix/native/libjava/posix_spawn.h ]]; then
      die "Android patch did not add libjava/posix_spawn.{c,h}"
    fi
    grep -q 'posix_spawn.h' "$spawn_fix" \
      || die "Failed to retarget ProcessImpl_md.c to posix_spawn.h"
  fi

  # Host X11 / fontconfig / alsa headers for configure probes
  # (headless still needs includes; target clang uses sysroot, so point explicitly)
  local android_include="$SYSROOT/usr/include"
  mkdir -p "$BUILD_ROOT/extra-include"
  ln -sfn /usr/include/X11 "$BUILD_ROOT/extra-include/X11"
  ln -sfn /usr/include/fontconfig "$BUILD_ROOT/extra-include/fontconfig"
  ln -sfn /usr/include/alsa "$BUILD_ROOT/extra-include/alsa"
  # cups headers
  ln -sfn "$BUILD_ROOT/cups-$CUPS_VER/cups" "$BUILD_ROOT/extra-include/cups"

  make_dummy_libs
  # empty libasound so -lasound link lines succeed (sound is unused on Android headless)
  if [[ ! -f "$DUMMY_LIBS/libasound.a" ]]; then
    llvm-ar cru "$DUMMY_LIBS/libasound.a"
  fi

  local cc="${CLANG_PREFIX}${API}-clang"
  local cxx="${CLANG_PREFIX}${API}-clang++"
  command -v "$cc" >/dev/null || die "clang wrapper missing: $cc"

  # Target CFLAGS. -DANDROID / -D__ANDROID__ required by the FCL patch set.
  # -DLE_STANDALONE mirrors mobile/OpenJDK android builds.
  # --undefined-version: NDK LLD is strict about JVM mapfile symbols that may be
  # compiled out (G1 local classes etc.); GNU ld was lenient.
  local target_cflags="-O3 -fPIC -fPIE -DANDROID -D__ANDROID__=1 -DLE_STANDALONE"
  local target_ldflags="-L$DUMMY_LIBS -Wl,--as-needed -Wl,--undefined-version"
  if [[ "$TARGET_JDK" == "arm" ]]; then
    target_cflags+=" -D__thumb__"
  elif [[ "$TARGET_JDK" == "x86" ]]; then
    target_cflags+=" -mstackrealign"
  fi

  # OpenJDK configure ignores AR/NM/STRIP from the environment — pass as args.
  # BUILD_* must also be clang: OpenJDK reuses many target CFLAGS for the
  # intermediate buildjdk, and clang-only flags (-mllvm, -flimit-debug-info)
  # break host g++. Use system clang (not NDK clang) so host libstdc++ is found.
  local host_clang host_clangxx
  if [[ -x /usr/bin/clang && -x /usr/bin/clang++ ]]; then
    host_clang=/usr/bin/clang
    host_clangxx=/usr/bin/clang++
  else
    host_clang="$TOOLCHAIN/bin/clang"
    host_clangxx="$TOOLCHAIN/bin/clang++"
  fi
  # Sanity: host clang must compile C++
  if ! echo 'int main(){return 0;}' | "$host_clangxx" -x c++ - -c -o /tmp/android-jdk-hostcxx-probe.o 2>/dev/null; then
    die "Host clang++ cannot compile C++ (install libstdc++-12-dev or matching -dev). Tried: $host_clangxx"
  fi

  log "Running configure (target=$cc, host=$host_clang) ..."
  bash ./configure \
    --openjdk-target="$TARGET" \
    --with-boot-jdk="$JAVA_HOME" \
    --with-toolchain-type=clang \
    --with-extra-cflags="$target_cflags" \
    --with-extra-cxxflags="$target_cflags" \
    --with-extra-ldflags="$target_ldflags" \
    --with-sysroot="$SYSROOT" \
    --disable-precompiled-headers \
    --disable-warnings-as-errors \
    --enable-option-checking=fatal \
    --enable-headless-only=yes \
    --with-jvm-variants="$JVM_VARIANTS" \
    --with-jvm-features=-dtrace,-zero,-vm-structs,-epsilongc \
    --with-debug-level="$JDK_DEBUG_LEVEL" \
    --with-native-debug-symbols=none \
    --with-cups-include="$BUILD_ROOT/cups-$CUPS_VER" \
    --with-freetype=bundled \
    --with-fontconfig-include="$BUILD_ROOT/extra-include" \
    --with-alsa-include="$BUILD_ROOT/extra-include" \
    --with-alsa-lib="$DUMMY_LIBS" \
    --x-includes="$BUILD_ROOT/extra-include" \
    --x-libraries=/usr/lib \
    --with-stdc++lib=static \
    CC="$cc" \
    CXX="$cxx" \
    AR=llvm-ar \
    NM=llvm-nm \
    STRIP=llvm-strip \
    OBJCOPY=llvm-objcopy \
    OBJDUMP=llvm-objdump \
    RANLIB=llvm-ranlib \
    BUILD_CC="$host_clang" \
    BUILD_CXX="$host_clangxx" \
    BUILD_AR=ar \
    BUILD_NM=nm \
    BUILD_OBJCOPY=objcopy \
    BUILD_STRIP=strip \
    >"$BUILD_ROOT/configure-$ABI.log" 2>&1 \
    || {
      echo "===== configure failed; last 120 lines of log ====="
      tail -120 "$BUILD_ROOT/configure-$ABI.log"
      if [[ -f config.log ]]; then
        echo "===== config.log (tail) ====="
        tail -80 config.log
      fi
      die "configure failed (see $BUILD_ROOT/configure-$ABI.log)"
    }

  local build_dir
  build_dir=$(echo build/linux-${TARGET_JDK}-${JVM_VARIANTS}-${JDK_DEBUG_LEVEL})
  [[ -d "$build_dir" ]] || build_dir=$(find build -maxdepth 1 -type d -name "linux-*" | head -1)
  [[ -n "$build_dir" && -d "$build_dir" ]] || die "build dir not found after configure"

  log "make images in $build_dir (JOBS=$JOBS) ..."
  (
    cd "$build_dir"
    # Retry once — Hotspot sometimes flakes under memory pressure
    if ! make JOBS="$JOBS" images >"$BUILD_ROOT/make-$ABI.log" 2>&1; then
      log "make failed once, retrying ..."
      make JOBS="$JOBS" images >>"$BUILD_ROOT/make-$ABI.log" 2>&1 \
        || {
          tail -100 "$BUILD_ROOT/make-$ABI.log"
          die "make images failed (see $BUILD_ROOT/make-$ABI.log)"
        }
    fi
  )

  local images="$build_dir/images"
  [[ -d "$images/jdk" ]] || die "images/jdk missing"

  # Bundle freetype if we built a shared one (optional; with-freetype=bundled embeds static)
  if [[ -f "$FREETYPE_DIR/lib/libfreetype.so" ]]; then
    cp -f "$FREETYPE_DIR/lib/libfreetype.so" "$images/jdk/lib/" || true
  fi

  # Produce JRE via jlink (host jlink from boot JDK works on jmods)
  log "Creating JRE with jlink ..."
  rm -rf "$BUILD_ROOT/jreout-$ABI" "$BUILD_ROOT/jdkout-$ABI"
  cp -a "$images/jdk" "$BUILD_ROOT/jdkout-$ABI"

  local extra_jlink=""
  if [[ "$TARGET_JDK" == "aarch64" || "$TARGET_JDK" == "x86_64" ]]; then
    extra_jlink=",jdk.internal.vm.ci"
  fi

  "$JAVA_HOME/bin/jlink" \
    --module-path="$BUILD_ROOT/jdkout-$ABI/jmods" \
    --add-modules "java.base,java.compiler,java.datatransfer,java.desktop,java.instrument,java.logging,java.management,java.management.rmi,java.naming,java.net.http,java.prefs,java.rmi,java.scripting,java.se,java.security.jgss,java.security.sasl,java.sql,java.sql.rowset,java.transaction.xa,java.xml,java.xml.crypto,jdk.accessibility,jdk.charsets,jdk.crypto.cryptoki,jdk.crypto.ec,jdk.dynalink,jdk.httpserver,jdk.jdwp.agent,jdk.jfr,jdk.jsobject,jdk.localedata,jdk.management,jdk.management.agent,jdk.management.jfr,jdk.naming.dns,jdk.naming.rmi,jdk.net,jdk.nio.mapmode,jdk.sctp,jdk.security.auth,jdk.security.jgss,jdk.unsupported,jdk.xml.dom,jdk.zipfs${extra_jlink}" \
    --output "$BUILD_ROOT/jreout-$ABI" \
    --strip-debug \
    --no-man-pages \
    --no-header-files \
    --release-info="$BUILD_ROOT/jdkout-$ABI/release" \
    --compress=2

  if [[ -f "$FREETYPE_DIR/lib/libfreetype.so" ]]; then
    cp -f "$FREETYPE_DIR/lib/libfreetype.so" "$BUILD_ROOT/jreout-$ABI/lib/" || true
  fi

  # Optional: font overrides from FCL
  if [[ -d "$ROOT/jre_override/lib" ]]; then
    cp -a "$ROOT/jre_override/lib/." "$BUILD_ROOT/jreout-$ABI/lib/" || true
  elif [[ -d /tmp/android-jdk-build/fcl-scripts/jre_override/lib ]]; then
    cp -a /tmp/android-jdk-build/fcl-scripts/jre_override/lib/. "$BUILD_ROOT/jreout-$ABI/lib/" || true
  fi

  # Strip native libs with NDK llvm-strip
  find "$BUILD_ROOT/jreout-$ABI" "$BUILD_ROOT/jdkout-$ABI" -name '*.so' -type f \
    -exec llvm-strip --strip-unneeded {} + 2>/dev/null || true

  # Stage outputs
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -a "$BUILD_ROOT/jreout-$ABI" "$dest/jre"
  cp -a "$BUILD_ROOT/jdkout-$ABI" "$dest/jdk"

  # Pack
  local stamp
  stamp=$(date +%Y%m%d)
  tar -C "$dest/jre" -cJf "$dest/jre17-${TARGET_SHORT}-${stamp}-${JDK_DEBUG_LEVEL}.tar.xz" .
  tar -C "$dest/jdk" -cJf "$dest/jdk17-${TARGET_SHORT}-${stamp}-${JDK_DEBUG_LEVEL}.tar.xz" .
  # Stable names for CI / Release (clobber-friendly)
  cp -f "$dest/jre17-${TARGET_SHORT}-${stamp}-${JDK_DEBUG_LEVEL}.tar.xz" \
        "$dest/jre17-${TARGET_SHORT}.tar.xz"
  cp -f "$dest/jdk17-${TARGET_SHORT}-${stamp}-${JDK_DEBUG_LEVEL}.tar.xz" \
        "$dest/jdk17-${TARGET_SHORT}.tar.xz"

  # BUILD_INFO
  {
    echo "OpenJDK $JDK_TAG (Android / Bionic)"
    echo "ABI: $ABI"
    echo "API: $API"
    echo "TARGET: $TARGET"
    echo "JVM: $JVM_VARIANTS / $JDK_DEBUG_LEVEL"
    echo "NDK: $(grep Pkg.Revision "$NDK/source.properties" | cut -d= -f2 | tr -d ' ')"
    echo "toolchain: clang (NDK llvm), headless"
    echo "boot JDK: $($JAVA_HOME/bin/java -version 2>&1 | head -1)"
    echo "patch: patches/jdk17u_android.diff (FCL Build_JRE_17)"
    echo "--- jre java binary ---"
    file "$dest/jre/bin/java" || true
    ls -lh "$dest/jre/bin/java" || true
    echo "--- needed libs (java) ---"
    llvm-readobj --needed-libs "$dest/jre/bin/java" 2>/dev/null || true
    echo "--- jre libjvm ---"
    find "$dest/jre/lib" -name 'libjvm.so' -exec ls -lh {} \; -exec file {} \;
    echo "--- package ---"
    ls -lh "$dest"/*.tar.xz
  } | tee "$dest/BUILD_INFO.txt"

  popd >/dev/null
  log "OK -> $dest"
}

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

main() {
  log "=== Android OpenJDK build ==="
  log "NDK=$NDK JOBS=$JOBS BUILD_ROOT=$BUILD_ROOT OUT=$OUT_DIR"
  log "JDK_TAG=$JDK_TAG API=$API"

  ensure_openjdk
  ensure_libs_src

  local -a targets
  mapfile -t targets < <(expand_targets "$@")
  [[ ${#targets[@]} -gt 0 ]] || targets=(arm64)

  log "Targets: ${targets[*]}"
  local t
  for t in "${targets[@]}"; do
    # reset per-ABI defaults that resolve_abi may override
    JVM_VARIANTS="${JVM_VARIANTS_FORCE:-server}"
    resolve_abi "$t"
    build_freetype
    build_jdk
  done

  log "Done."
  find "$OUT_DIR" -maxdepth 3 -type f \( -name 'java' -o -name '*.tar.xz' -o -name 'BUILD_INFO.txt' \) | sort
}

main "$@"
