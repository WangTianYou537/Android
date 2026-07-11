# source this file:  source ./env-ndk.sh
# Prefer permanent install under /opt, then project symlink, then /tmp.
if [[ -d /opt/android-ndk-r27d ]]; then
  export NDK=/opt/android-ndk-r27d
elif [[ -d "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-ndk-r27d" ]]; then
  export NDK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-ndk-r27d"
elif [[ -d /tmp/bash4droid-build/android-ndk-r27d ]]; then
  export NDK=/tmp/bash4droid-build/android-ndk-r27d
fi
export ANDROID_NDK_HOME="${NDK:-}"
export ANDROID_NDK_ROOT="${NDK:-}"
if [[ -n "${NDK:-}" && -d "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin" ]]; then
  export PATH="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"
  echo "NDK=$NDK"
  echo "clang: $($NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang --version | head -1)"
else
  echo "NDK not found. Expected /opt/android-ndk-r27d"
  return 1 2>/dev/null || exit 1
fi
