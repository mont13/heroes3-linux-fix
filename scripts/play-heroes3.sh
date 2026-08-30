#!/usr/bin/env bash
#
# play-heroes3.sh - start Heroes of Might and Magic III.
#
# WHY IT USES A NESTED X SERVER
#   Heroes III renders through DirectDraw in exclusive full-screen mode. Wine
#   only takes that path when the game window really covers the whole screen.
#   On GNOME it never does: the window manager places the window inside the
#   work area (below the top bar, right of the dock) and ignores the fullscreen
#   request, because Wine keeps _NET_WM_STATE_ABOVE on the window. Wine then
#   falls back to the windowed DirectDraw path, which repaints only when
#   something asks it to - so the screen appears frozen until you Alt+Tab, and
#   a click seems to redraw just a corner of the screen.
#
#   Running the game inside Xephyr - a nested X server with no window manager -
#   puts the window at 0,0 covering the entire (nested) screen, so the
#   full-screen path is used and every frame is drawn. Verified by comparing
#   against a bare Xvfb run.
#
# USAGE
#   ./play-heroes3.sh                windowed 800x600 on your desktop
#   ./play-heroes3.sh --fullscreen   fills the screen (resolution is restored on exit)
#   ./play-heroes3.sh --direct       no nested server; debugging only, repaints badly
#
#   HEROES3_DIR, HEROES3_PREFIX and HEROES3_WINE override auto-detection.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/common.sh"

MODE="window"
case "${1:-}" in
  --fullscreen|--cela) MODE="fullscreen" ;;
  --direct)            MODE="direct" ;;
  -h|--help)           sed -n '2,26p' "$0"; exit 0 ;;
  "") ;;
  *) die "unknown option: $1" ;;
esac

GAME_DIR="$(find_game_dir || true)"
[ -n "$GAME_DIR" ] || die "no Heroes III install found - run ./scripts/install-game.sh or set HEROES3_DIR"
WINE="$(find_wine || true)"
[ -n "$WINE" ] || die "no Wine found - see README, or set HEROES3_WINE"
PREFIX="$(default_prefix)"
[ -d "$PREFIX/drive_c" ] || die "Wine prefix not set up yet - run ./scripts/fix-heroes3.sh first"

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/heroes3-linux-fix"
LOG_DIR="$STATE_DIR/logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/play_$(date +%Y%m%d-%H%M%S).log"

MISSING="$(missing_i386_libs)"
[ -n "$MISSING" ] && { warn "missing 32-bit libraries:$MISSING"; info "run ./scripts/install-deps.sh - expect a black screen or silence without them"; }

[ -n "${DISPLAY:-}" ] || export DISPLAY=:0
HOST_DISPLAY="$DISPLAY"
export WINEPREFIX="$PREFIX"
wine_stop "$WINE" "$PREFIX"

NESTED=":89"
ORIG_MODE=""; ORIG_OUTPUT=""
cleanup() {
  wine_stop "$WINE" "$PREFIX"
  for pid in $(pgrep -x Xephyr 2>/dev/null); do
    grep -qa -- "$NESTED" "/proc/$pid/cmdline" 2>/dev/null && kill "$pid" 2>/dev/null
  done
  if [ -n "$ORIG_MODE" ] && [ -n "$ORIG_OUTPUT" ]; then
    DISPLAY="$HOST_DISPLAY" xrandr --output "$ORIG_OUTPUT" --mode "$ORIG_MODE" 2>/dev/null \
      && echo "Screen resolution restored to $ORIG_MODE."
  fi
}
trap cleanup EXIT INT TERM

if [ "$MODE" = "direct" ]; then
  cd "$GAME_DIR" || exit 1
  echo "Starting directly on your desktop (log: $LOG)"
  WINEDEBUG="${WINEDEBUG:-fixme-all}" "$WINE" Heroes3.exe >"$LOG" 2>&1
  exit $?
fi

command -v Xephyr >/dev/null || die "Xephyr is missing - run ./scripts/install-deps.sh (package xserver-xephyr)"

XEPHYR_ARGS=(-screen 800x600 -title "Heroes III")
if [ "$MODE" = "fullscreen" ]; then
  if command -v xrandr >/dev/null; then
    ORIG_OUTPUT="$(DISPLAY="$HOST_DISPLAY" xrandr --query | awk '/ connected/{print $1; exit}')"
    ORIG_MODE="$(DISPLAY="$HOST_DISPLAY" xrandr --query | awk '/\*/{print $1; exit}')"
    if DISPLAY="$HOST_DISPLAY" xrandr --output "$ORIG_OUTPUT" --mode 800x600 2>/dev/null; then
      echo "Screen switched to 800x600 (restored to $ORIG_MODE when the game exits)."
    else
      warn "the display does not offer an 800x600 mode; the game will be letterboxed"
      ORIG_MODE=""; ORIG_OUTPUT=""
    fi
  fi
  XEPHYR_ARGS+=(-fullscreen)
fi

DISPLAY="$HOST_DISPLAY" Xephyr "$NESTED" "${XEPHYR_ARGS[@]}" >"$LOG_DIR/xephyr.log" 2>&1 &
sleep 4
DISPLAY="$NESTED" xdpyinfo >/dev/null 2>&1 || die "Xephyr failed to start - see $LOG_DIR/xephyr.log"

cd "$GAME_DIR" || exit 1
echo "Starting Heroes III ($MODE). Log: $LOG"
DISPLAY="$NESTED" WINEDEBUG="${WINEDEBUG:-fixme-all}" "$WINE" Heroes3.exe >"$LOG" 2>&1
