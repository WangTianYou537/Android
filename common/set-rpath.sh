#!/usr/bin/env bash
# set_rpath <rpath> <elf> [elf...]
# Prefer patchelf; no-op if tool missing (caller should still pass -Wl,-rpath at link).
set_rpath() {
  local rpath="$1"; shift
  local f
  command -v patchelf >/dev/null 2>&1 || {
    echo "WARN: patchelf not found; ensure link-time -Wl,-rpath is correct" >&2
    return 0
  }
  for f in "$@"; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    file "$f" | grep -q ELF || continue
    patchelf --set-rpath "$rpath" "$f" 2>/dev/null || true
  done
}
