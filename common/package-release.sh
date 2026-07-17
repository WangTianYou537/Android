#!/usr/bin/env bash
# Package each ABI under <out_root> as <pkg>-<ver>-<abi>.tar.gz for GitHub Release.
#
# Usage:
#   source common/package-release.sh
#   package_abi_releases <pkg> <version> <out_root> [extra exclude patterns...]
#
# Example:
#   package_abi_releases bash 5.3 bash/out
#   # -> dist/bash-5.3-arm64.tar.gz  containing  bash-5.3-arm64/{bash,BUILD_INFO.txt,...}
#
# Includes everything present under out/<ABI>/ except:
#   - *.unstripped (debug)
#   - *.o / .deps (build junk, if any)
#   - any extra patterns passed as args 4+
#
# Writes:
#   dist/*.tar.gz
#   dist/asset-files.txt   (one path per line)
#   dist/SUMMARY.txt
#   dist/RELEASE_NOTES.txt (caller may overwrite; we append package listing)

set -euo pipefail

abi_short() {
  case "$1" in
    arm64-v8a) echo arm64 ;;
    armeabi-v7a) echo arm ;;
    x86_64) echo x86_64 ;;
    x86) echo x86 ;;
    *) echo "$1" ;;
  esac
}

package_abi_releases() {
  local pkg="$1"
  local ver="$2"
  local out_root="$3"
  shift 3 || true
  local -a extra_excludes=("$@")

  mkdir -p dist
  : > dist/SUMMARY.txt
  : > dist/asset-files.txt
  local found=0
  local dir short pkg_dir tar_path

  for dir in arm64-v8a armeabi-v7a x86_64 x86; do
    local src="${out_root}/${dir}"
    [[ -d "$src" ]] || continue
    # must have at least one real file
    if ! find "$src" -type f ! -name '*.unstripped' | grep -q .; then
      continue
    fi
    short="$(abi_short "$dir")"
    pkg_dir="${pkg}-${ver}-${short}"
    tar_path="dist/${pkg_dir}.tar.gz"

    rm -rf "dist/${pkg_dir}"
    mkdir -p "dist/${pkg_dir}"

    # Copy tree, drop unstripped / junk
    (
      cd "$src"
      # shellcheck disable=SC2046
      tar -cf - \
        --exclude='*.unstripped' \
        --exclude='*.o' \
        --exclude='.deps' \
        --exclude='.libs' \
        --exclude='*.zip' \
        --exclude='*.tar' \
        --exclude='*.tar.gz' \
        --exclude='*.static.bak' \
        --exclude='*~' \
        $(printf -- '--exclude=%s ' "${extra_excludes[@]+"${extra_excludes[@]}"}") \
        .
    ) | tar -xf - -C "dist/${pkg_dir}"

    # Ensure BUILD_INFO if present at ABI root was copied
    tar -C dist -czf "$tar_path" "$pkg_dir"

    {
      echo "==> ${pkg_dir}.tar.gz"
      ls -lh "$tar_path"
      echo "contents:"
      find "dist/${pkg_dir}" -type f -o -type l | sed "s|^dist/${pkg_dir}/|  |" | sort
      echo
    } | tee -a dist/SUMMARY.txt

    echo "$tar_path" >> dist/asset-files.txt
    found=1
    rm -rf "dist/${pkg_dir}"
  done

  if [[ "$found" -eq 0 ]]; then
    echo "ERROR: no packageable outputs under ${out_root}/<ABI>/" >&2
    find "$out_root" -type f 2>/dev/null | head -50 || true
    return 1
  fi

  ls -lh dist/*.tar.gz
  return 0
}
