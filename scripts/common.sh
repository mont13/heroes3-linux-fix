#!/usr/bin/env bash
# Shared helpers and auto-detection for heroes3-linux-fix.
# Sourced by the other scripts; not meant to be run directly.

set -uo pipefail

# ---------------------------------------------------------------- output ----
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""
fi
ERRORS=0
step() { echo; echo "== $* =="; }
ok()   { echo "  ${C_OK}[ ok ]${C_OFF}   $*"; }
warn() { echo "  ${C_WARN}[warn]${C_OFF}   $*"; }
err()  { echo "  ${C_ERR}[fail]${C_OFF}   $*"; ERRORS=$((ERRORS+1)); }
info() { echo "  ${C_DIM}$*${C_OFF}"; }
die()  { echo "${C_ERR}error:${C_OFF} $*" >&2; exit 1; }

# grep -q closes the pipe early, which kills the producer with SIGPIPE and,
# under `set -o pipefail`, makes the whole pipeline report failure.
file_contains() {  # <file> <literal string>
  local tmp; tmp="$(mktemp)"
  strings -a "$1" >"$tmp" 2>/dev/null
  local n; n="$(grep -c -F -- "$2" "$tmp")"
  rm -f "$tmp"
  [ "${n:-0}" -gt 0 ]
}

md5of() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }

# ------------------------------------------------------------ wine runtime --
# Heroes III needs a working 32-bit Wine. Wine 8.x builds shipped by some
# launchers are broken on current kernels (every Windows app hangs at startup
# with a single thread in futex_do_wait). Wine 9/10 or GE-Proton 9/10 are fine.
find_wine() {
  if [ -n "${HEROES3_WINE:-}" ]; then
    [ -x "$HEROES3_WINE" ] || die "HEROES3_WINE is set but not executable: $HEROES3_WINE"
    echo "$HEROES3_WINE"; return
  fi
  local c
  # Proton / GE-Proton shipped with Heroic or Steam (newest first)
  for c in \
    "$HOME"/.config/heroic/tools/proton/*/files/bin/wine \
    "$HOME"/.steam/steam/compatibilitytools.d/*/files/bin/wine \
    "$HOME"/.local/share/Steam/compatibilitytools.d/*/files/bin/wine \
    "$HOME"/.steam/steam/steamapps/common/Proton*/files/bin/wine \
    "$HOME"/.local/share/Steam/steamapps/common/Proton*/files/bin/wine
  do
    [ -x "$c" ] && { echo "$c"; return; }
  done
  # system wine
  for c in /usr/bin/wine /usr/local/bin/wine /opt/wine-staging/bin/wine; do
    [ -x "$c" ] && { echo "$c"; return; }
  done
  return 1
}

wine_version() { "$1" --version 2>/dev/null | head -1; }

# Major version number, e.g. 10 for "wine-10.0 (Staging)"
wine_major() { wine_version "$1" | sed -n 's/^wine-\([0-9]\+\).*/\1/p'; }

# Directory holding the PE-format builtin DLLs of that wine build.
wine_pe_dir() {  # <wine binary> -> path containing i386-windows DLLs
  local base; base="$(dirname "$(dirname "$1")")"
  local d
  for d in "$base/lib/wine/i386-windows" "$base/lib32/wine/i386-windows" \
           "$base/lib/wine/i386-unix/../i386-windows"; do
    [ -d "$d" ] && { echo "$d"; return; }
  done
  return 1
}

# ---------------------------------------------------------------- game dir --
# A valid install has Heroes3.exe plus the Data directory with the .lod archives.
is_game_dir() {
  [ -f "$1/Heroes3.exe" ] && [ -d "$1/Data" ]
}

find_game_dir() {
  if [ -n "${HEROES3_DIR:-}" ]; then
    is_game_dir "$HEROES3_DIR" || die "HEROES3_DIR does not look like a HoMM3 install: $HEROES3_DIR"
    echo "$HEROES3_DIR"; return
  fi
  local c
  for c in \
    "$HOME/Games/heroes3" \
    "$HOME/Games/Heroic/HoMM 3 Complete" \
    "$HOME/Games/Heroic/Heroes of Might and Magic 3 Complete" \
    "$HOME/.wine/drive_c/GOG Games/Heroes of Might and Magic 3 Complete" \
    "$HOME/GOG Games/Heroes of Might and Magic 3 Complete"
  do
    is_game_dir "$c" && { echo "$c"; return; }
  done
  return 1
}

# ------------------------------------------------------------------ prefix --
default_prefix() { echo "${HEROES3_PREFIX:-$HOME/.local/share/heroes3-linux-fix/prefix}"; }

# ------------------------------------------------------- 32-bit host libs ----
# The game is a 32-bit process, so it needs i386 builds of the host libraries.
# Without them Wine reports "OpenGL support is disabled" (the picture stops
# refreshing) and "No driver from pulse could be initialized" (no sound).
REQUIRED_I386_LIBS="libGL.so.1 libGLX.so.0 libpulse.so.0 libasound.so.2 libudev.so.1"

missing_i386_libs() {
  local l out=""
  for l in $REQUIRED_I386_LIBS; do
    [ -e "/usr/lib/i386-linux-gnu/$l" ] || out="$out $l"
  done
  echo "${out# }"
}

# Proton builds keep some PE libraries outside the normal Wine directory
# (files/lib/vkd3d) and only put them into a prefix through the `proton` wrapper
# script. Calling files/bin/wine directly skips that, and the prefix ends up
# without libvkd3d-1.dll, so wined3d cannot load, so ddraw cannot load, so the
# game dies with:
#   err:module:import_dll Library libvkd3d-1.dll (needed by wined3d.dll) not found
# Copy the missing pieces in ourselves. Harmless for plain Wine builds.
seed_runtime_dlls() {  # <wine binary> <prefix>  -> echoes how many files it added
  local base sys32 syswow src added=0
  base="$(dirname "$(dirname "$1")")"
  sys32="$2/drive_c/windows/system32"
  syswow="$2/drive_c/windows/syswow64"
  # With a WoW64 prefix system32 holds 64-bit DLLs and syswow64 the 32-bit ones;
  # in a 32-bit-only prefix there is no syswow64 and system32 holds 32-bit.
  local dir32 dir64
  if [ -d "$syswow" ]; then dir32="$syswow"; dir64="$sys32"; else dir32="$sys32"; dir64=""; fi
  for src in "$base/lib/vkd3d/i386-windows" "$base/lib32/vkd3d/i386-windows"; do
    [ -d "$src" ] && [ -n "$dir32" ] || continue
    for f in "$src"/*.dll; do
      [ -f "$f" ] || continue
      [ -e "$dir32/$(basename "$f")" ] || { cp "$f" "$dir32/" 2>/dev/null && added=$((added+1)); }
    done
  done
  for src in "$base/lib/vkd3d/x86_64-windows" "$base/lib64/vkd3d/x86_64-windows"; do
    [ -d "$src" ] && [ -n "$dir64" ] || continue
    for f in "$src"/*.dll; do
      [ -f "$f" ] || continue
      [ -e "$dir64/$(basename "$f")" ] || { cp "$f" "$dir64/" 2>/dev/null && added=$((added+1)); }
    done
  done
  echo "$added"
}

# ------------------------------------------------------------- wine helpers --
wine_reg_add() {  # <wine> <prefix> <key under HKCU\Software\Wine> <value> <data>
  WINEPREFIX="$2" WINEDEBUG=-all timeout 120 "$1" reg add \
    "HKEY_CURRENT_USER\\Software\\Wine\\$3" /v "$4" /t REG_SZ /d "$5" /f >/dev/null 2>&1
}

wine_reg_del() {  # <wine> <prefix> <key> <value>
  WINEPREFIX="$2" WINEDEBUG=-all timeout 120 "$1" reg delete \
    "HKEY_CURRENT_USER\\Software\\Wine\\$3" /v "$4" /f >/dev/null 2>&1 || true
}

wine_stop() {  # <wine> <prefix>
  local ws; ws="$(dirname "$1")/wineserver"
  [ -x "$ws" ] && WINEPREFIX="$2" "$ws" -k >/dev/null 2>&1
  sleep 2
  pgrep -x Heroes3.exe >/dev/null && { pkill -9 -x Heroes3.exe; sleep 1; }
  return 0
}
