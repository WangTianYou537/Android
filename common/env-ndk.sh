# Shared NDK environment for all packages.
# Usage:  source common/env-ndk.sh
#
# Search order:
#   1. $NDK / $ANDROID_NDK_HOME / $ANDROID_NDK_ROOT (if already set and valid)
#   2. /opt/android-ndk-r27d  (recommended permanent install)
#   3. <repo-root>/android-ndk-r27d  (symlink or extracted tree)
#   4. $HOME/Android/Sdk/ndk/*  (latest)

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo="$(cd "$_here/.." && pwd)"

_ndk_ok() {
  [[ -n "${1:-}" && -d "$1/toolchains/llvm/prebuilt" ]]
}

if ! _ndk_ok "${NDK:-}" && ! _ndk_ok "${ANDROID_NDK_HOME:-}" && ! _ndk_ok "${ANDROID_NDK_ROOT:-}"; then
  unset NDK
  if _ndk_ok /opt/android-ndk-r27d; then
    NDK=/opt/android-ndk-r27d
  elif _ndk_ok "$_repo/android-ndk-r27d"; then
    NDK="$_repo/android-ndk-r27d"
  else
    # pick highest version under Android SDK if present
    _sdk_ndk="$(ls -d "$HOME"/Android/Sdk/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
    if _ndk_ok "$_sdk_ndk"; then
      NDK="$_sdk_ndk"
    fi
  fi
else
  # prefer explicit vars in order
  if _ndk_ok "${NDK:-}"; then
    :
  elif _ndk_ok "${ANDROID_NDK_HOME:-}"; then
    NDK="$ANDROID_NDK_HOME"
  else
    NDK="$ANDROID_NDK_ROOT"
  fi
fi

export NDK="${NDK:-}"
export ANDROID_NDK_HOME="${NDK:-}"
export ANDROID_NDK_ROOT="${NDK:-}"

if _ndk_ok "$NDK"; then
  _host=linux-x86_64
  [[ -d "$NDK/toolchains/llvm/prebuilt/darwin-x86_64" ]] && _host=darwin-x86_64
  _bin="$NDK/toolchains/llvm/prebuilt/$_host/bin"
  case ":${PATH}:" in
    *":${_bin}:"*) ;;
    *) PATH="${_bin}:${PATH}" ;;
  esac
  export PATH
  echo "NDK=$NDK"
  echo "clang: $("$NDK/toolchains/llvm/prebuilt/$_host/bin/clang" --version | head -1)"
else
  echo "NDK not found. Install to /opt/android-ndk-r27d or set NDK=/path/to/ndk"
  unset _here _repo _sdk_ndk _host _bin
  return 1 2>/dev/null || exit 1
fi
unset _here _repo _sdk_ndk _host _bin
