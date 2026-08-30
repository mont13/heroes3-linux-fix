#!/usr/bin/env bash
#
# fix-heroes3.sh - make a legally owned GOG copy of Heroes of Might and Magic
# III Complete run correctly under Wine on a modern Linux desktop.
#
# It is idempotent: run it as many times as you like. Every file it touches is
# backed up first and `--revert` puts the last backup back.
#
# WHAT IT FIXES  (full write-up with log evidence in docs/ROOT-CAUSES.md)
#
#   1. GOG's DirectDraw wrapper crashes under Wine.
#      The GOG build ships DDrawCompat renamed to xdd.dll. It hooks Windows
#      internals that Wine does not implement and dies with 0xc0000409
#      (stack buffer overrun) right after reading its config. Replacing it with
#      Wine's own ddraw.dll - taken from the Wine build on this machine, so no
#      third-party binary is downloaded - makes the game start.
#
#   2. Wine crashes when the game changes screen resolution.
#      wine-10 asserts in winex11.drv/xvidmode.c:
#        Assertion `modes[0].dmDriverExtra == sizeof(XF86VidModeModeInfo *)'
#      Setting UseXVidMode=N makes Wine use XRandR instead.
#
#   3. The whole game freezes on a dead HDMI audio output.
#      If winepulse cannot load, Wine falls back to raw ALSA and opens the
#      first PCM device it finds - on many laptops that is the GPU's HDMI
#      output. With no monitor attached the write blocks forever and the game
#      hangs ("not responding"). Forcing Audio=pulse routes sound through
#      PulseAudio/PipeWire instead.
#
#   4. A broken Wine runner.
#      Some launchers ship Wine 8.x builds in which every Windows program hangs
#      at startup on current kernels: one thread, futex_do_wait, no window.
#      The script refuses to configure such a build and tells you to pick
#      another one.
#
#   Redrawing and window handling are fixed at launch time, see play-heroes3.sh.
#
# USAGE
#   ./fix-heroes3.sh                       auto-detect everything, apply, test
#   ./fix-heroes3.sh --game-dir DIR        point at the game explicitly
#   ./fix-heroes3.sh --prefix DIR          use a specific Wine prefix
#   ./fix-heroes3.sh --status              report only, change nothing
#   ./fix-heroes3.sh --revert              restore the most recent backup
#   ./fix-heroes3.sh --no-test             apply the fixes, skip the test run
#
#   HEROES3_WINE=/path/to/wine  overrides Wine auto-detection.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/common.sh"

GAME_DIR=""; PREFIX=""; ACTION="fix"; RUN_TEST=1
while [ $# -gt 0 ]; do
  case "$1" in
    --game-dir) GAME_DIR="${2:-}"; shift 2 ;;
    --prefix)   PREFIX="${2:-}";   shift 2 ;;
    --status)   ACTION="status";   shift ;;
    --revert)   ACTION="revert";   shift ;;
    --no-test)  RUN_TEST=0;        shift ;;
    -h|--help)  sed -n '2,45p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/heroes3-linux-fix"
BACKUP_ROOT="$STATE_DIR/backup"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$BACKUP_ROOT" "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"

[ -n "$GAME_DIR" ] || GAME_DIR="$(find_game_dir || true)"
[ -n "$GAME_DIR" ] || die "could not find a Heroes III install.
  Pass --game-dir /path/to/game, or run ./scripts/install-game.sh first."
is_game_dir "$GAME_DIR" || die "not a HoMM3 install (no Heroes3.exe + Data/): $GAME_DIR"

WINE="$(find_wine || true)"
[ -n "$WINE" ] || die "no Wine found.
  Install wine (Ubuntu: sudo apt install wine64 wine32), or install a
  GE-Proton build through Heroic/Steam, or set HEROES3_WINE=/path/to/wine."
[ -n "$PREFIX" ] || PREFIX="$(default_prefix)"

# --------------------------------------------------------------- status ----
if [ "$ACTION" = "status" ]; then
  step "Current state (nothing is changed)"
  info "game:   $GAME_DIR"
  info "wine:   $WINE  ($(wine_version "$WINE"))"
  info "prefix: $PREFIX"
  MAJ="$(wine_major "$WINE")"
  [ "${MAJ:-0}" -ge 9 ] 2>/dev/null && ok "Wine $MAJ is recent enough" \
    || warn "Wine ${MAJ:-?} - versions below 9 are known to hang on current kernels"
  M="$(missing_i386_libs)"
  [ -z "$M" ] && ok "32-bit libraries present" || err "missing 32-bit libraries:$M"
  if [ -f "$GAME_DIR/xdd.dll" ]; then
    if file_contains "$GAME_DIR/xdd.dll" "DDrawCompat"; then
      warn "xdd.dll is still GOG's DDrawCompat - it crashes under Wine"
    else
      ok "xdd.dll has been replaced with Wine's ddraw"
    fi
  fi
  [ -f "$GAME_DIR/DDrawCompat.ini" ] && warn "DDrawCompat.ini present (unused, harmless once xdd.dll is replaced)" \
                                     || ok "no DDrawCompat.ini"
  if [ -d "$PREFIX" ]; then
    for kv in "X11 Driver|UseXVidMode|N" "Drivers|Audio|pulse"; do
      K="${kv%%|*}"; rest="${kv#*|}"; V="${rest%%|*}"; WANT="${rest##*|}"
      GOT="$(WINEPREFIX="$PREFIX" WINEDEBUG=-all timeout 120 "$WINE" reg query \
             "HKEY_CURRENT_USER\\Software\\Wine\\$K" /v "$V" 2>/dev/null | awk -v v="$V" '$1==v{print $3}')"
      [ "$GOT" = "$WANT" ] && ok "$K\\$V = $GOT" || warn "$K\\$V = ${GOT:-unset} (expected $WANT)"
    done
  else
    warn "Wine prefix does not exist yet: $PREFIX"
  fi
  exit 0
fi

# --------------------------------------------------------------- revert ----
if [ "$ACTION" = "revert" ]; then
  LAST="$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -1)"
  [ -n "$LAST" ] || die "no backup found in $BACKUP_ROOT"
  step "Restoring $LAST"
  wine_stop "$WINE" "$PREFIX"
  for f in xdd.dll Heroes3.exe DDrawCompat.ini; do
    [ -f "$LAST/$f" ] && cp -a "$LAST/$f" "$GAME_DIR/$f" && ok "restored $f"
  done
  echo; echo "Done."
  exit 0
fi

# ------------------------------------------------------------------ fix ----
echo "heroes3-linux-fix   $(date -Is)"
info "game:   $GAME_DIR"
info "wine:   $WINE  ($(wine_version "$WINE"))"
info "prefix: $PREFIX"

step "1. Host prerequisites"
MISSING="$(missing_i386_libs)"
if [ -z "$MISSING" ]; then
  ok "32-bit graphics and audio libraries present"
else
  err "missing 32-bit libraries:$MISSING"
  info "run ./scripts/install-deps.sh first - without these there is no picture and no sound"
fi
MAJ="$(wine_major "$WINE")"
if [ "${MAJ:-0}" -ge 9 ] 2>/dev/null; then
  ok "Wine $MAJ"
else
  err "Wine ${MAJ:-unknown} is too old or unidentified"
  info "Wine 8.x builds hang at startup on current kernels: the process sits on"
  info "a single thread in futex_do_wait and never opens a window. Use Wine 9+"
  info "or a GE-Proton 9/10 build, or set HEROES3_WINE to a working one."
fi
[ "$ERRORS" -eq 0 ] || { echo; echo "Fix the problems above first."; exit "$ERRORS"; }

step "2. Wine prefix"
if [ -d "$PREFIX/drive_c" ]; then
  ok "using existing prefix: $PREFIX"
else
  info "creating prefix (this takes a moment): $PREFIX"
  mkdir -p "$PREFIX"
  WINEPREFIX="$PREFIX" WINEDEBUG=-all timeout 300 "$WINE" wineboot -u >"$LOG_DIR/wineboot_$STAMP.log" 2>&1
  if [ -d "$PREFIX/drive_c" ]; then
    ok "prefix created"
  else
    err "prefix creation failed or timed out - see $LOG_DIR/wineboot_$STAMP.log"
    info "a wineboot that hangs is the signature of a broken Wine build; try another one"
    exit 1
  fi
fi
ADDED="$(seed_runtime_dlls "$WINE" "$PREFIX")"
if [ "${ADDED:-0}" -gt 0 ]; then
  ok "copied $ADDED runtime DLL(s) the Wine build keeps outside the prefix"
  info "  (Proton stores libvkd3d there; without it wined3d and ddraw cannot load)"
else
  ok "prefix already has the runtime DLLs it needs"
fi
wine_stop "$WINE" "$PREFIX"

step "3. Backup"
BACKUP="$BACKUP_ROOT/$STAMP"
mkdir -p "$BACKUP"
for f in xdd.dll Heroes3.exe DDrawCompat.ini; do
  [ -f "$GAME_DIR/$f" ] && cp -a "$GAME_DIR/$f" "$BACKUP/$f" && ok "backed up $f"
done
{ echo "backup taken $(date -Is) by fix-heroes3.sh"
  echo "game dir: $GAME_DIR"
  echo "restore:  $0 --revert"; } > "$BACKUP/README.txt"
info "backup: $BACKUP"

step "4. DirectDraw wrapper"
PE_DIR="$(wine_pe_dir "$WINE" || true)"
if [ -z "$PE_DIR" ] || [ ! -f "$PE_DIR/ddraw.dll" ]; then
  err "cannot locate Wine's 32-bit ddraw.dll next to $WINE"
  info "expected something like <wine>/lib/wine/i386-windows/ddraw.dll"
elif [ ! -f "$GAME_DIR/xdd.dll" ]; then
  # Nothing to replace: the executable imports ddraw.dll directly and Wine's
  # builtin will be used.
  if file_contains "$GAME_DIR/Heroes3.exe" "ddraw.dll"; then
    ok "Heroes3.exe imports ddraw.dll directly - Wine's builtin will be used"
  else
    warn "no xdd.dll and Heroes3.exe does not import ddraw.dll - unexpected build"
  fi
elif file_contains "$GAME_DIR/xdd.dll" "DDrawCompat"; then
  cp -a "$PE_DIR/ddraw.dll" "$GAME_DIR/xdd.dll" \
    && ok "replaced GOG's DDrawCompat (xdd.dll) with Wine's ddraw" \
    || err "could not write $GAME_DIR/xdd.dll"
else
  ok "xdd.dll is already Wine's ddraw"
fi
if [ -f "$GAME_DIR/DDrawCompat.ini" ]; then
  mv "$GAME_DIR/DDrawCompat.ini" "$BACKUP/DDrawCompat.ini" 2>/dev/null \
    && ok "moved DDrawCompat.ini into the backup (it configures a wrapper we no longer load)"
fi
rm -f "$GAME_DIR/DDrawCompat-Heroes3.log"

step "5. Wine settings"
wine_reg_add "$WINE" "$PREFIX" "X11 Driver" UseXVidMode N \
  && ok "X11 Driver\\UseXVidMode = N   (Wine asserts in xvidmode.c on mode changes)" \
  || err "could not set UseXVidMode"
wine_reg_add "$WINE" "$PREFIX" "Drivers" Audio pulse \
  && ok "Drivers\\Audio = pulse   (stops ALSA grabbing a dead HDMI output)" \
  || err "could not set the audio driver"
# Leftovers from other guides that make things worse:
wine_reg_del "$WINE" "$PREFIX" "Direct3D" renderer
wine_reg_del "$WINE" "$PREFIX" "Direct3D" DirectDrawRenderer
info "removed Direct3D\\renderer and DirectDrawRenderer if they were set"
info "  (renderer=gdi only repaints on Alt+Tab; DirectDrawRenderer is ignored by Wine 10)"
wine_stop "$WINE" "$PREFIX"

if [ "$RUN_TEST" -eq 0 ]; then
  step "6. Test skipped (--no-test)"
else
  step "6. Test run"
  if ! command -v Xvfb >/dev/null; then
    warn "Xvfb is not installed, skipping the automated test"
    info "install it with ./scripts/install-deps.sh, or just run ./scripts/play-heroes3.sh"
  else
    XD=":91"
    for pid in $(pgrep -x Xvfb 2>/dev/null); do
      grep -qa -- "$XD" "/proc/$pid/cmdline" 2>/dev/null && kill "$pid" 2>/dev/null
    done
    Xvfb "$XD" -screen 0 800x600x24 >"$LOG_DIR/xvfb_$STAMP.log" 2>&1 &
    sleep 4
    if ! DISPLAY="$XD" xdpyinfo >/dev/null 2>&1; then
      warn "could not start the test X server, skipping"
    else
      ( cd "$GAME_DIR" && DISPLAY="$XD" WINEPREFIX="$PREFIX" WINEDEBUG=fixme-all \
          setsid nohup "$WINE" Heroes3.exe >"$LOG_DIR/test_$STAMP.log" 2>&1 & )
      info "waiting for the game window..."
      WID=""
      for i in $(seq 1 20); do
        sleep 2
        WID="$(DISPLAY="$XD" xwininfo -root -children 2>/dev/null | grep -i "might and magic" | awk '{print $1}' | head -1)"
        [ -n "$WID" ] && break
      done
      if [ -z "$WID" ]; then
        err "the game window never appeared - see $LOG_DIR/test_$STAMP.log"
        grep -iE "err:|Unhandled|Assertion" "$LOG_DIR/test_$STAMP.log" 2>/dev/null | head -5 | sed 's/^/        /'
      else
        ok "window: $(DISPLAY="$XD" xwininfo -id "$WID" 2>/dev/null | awk '/Width|Height/{printf "%s ", $2}')"
        PID="$(pgrep -x Heroes3.exe | head -1)"
        TH="$(awk '/^Threads/{print $2}' "/proc/$PID/status" 2>/dev/null)"
        [ "${TH:-1}" -gt 1 ] && ok "process is alive, $TH threads" \
                             || err "single thread - the game hung at startup"
        if command -v import >/dev/null; then
          info "checking that the picture actually refreshes..."
          PREV=""; CHANGES=0
          for i in 1 2 3 4; do
            DISPLAY="$XD" import -window root "$LOG_DIR/frame_${STAMP}_$i.png" 2>/dev/null
            CUR="$(md5of "$LOG_DIR/frame_${STAMP}_$i.png")"
            [ -n "$PREV" ] && [ "$PREV" != "$CUR" ] && CHANGES=$((CHANGES+1))
            PREV="$CUR"; sleep 5
          done
          [ "$CHANGES" -ge 2 ] && ok "picture refreshes ($CHANGES of 3 samples differ)" \
                               || err "picture is frozen ($CHANGES of 3 samples differ)"
        fi
        if grep -q "mmdevapi:init_driver No driver" "$LOG_DIR/test_$STAMP.log" 2>/dev/null; then
          err "no audio driver could be loaded - is libudev1:i386 installed?"
        else
          ok "audio driver loaded"
        fi
      fi
      wine_stop "$WINE" "$PREFIX"
      for pid in $(pgrep -x Xvfb 2>/dev/null); do
        grep -qa -- "$XD" "/proc/$pid/cmdline" 2>/dev/null && kill "$pid" 2>/dev/null
      done
    fi
  fi
fi

step "Summary"
if [ "$ERRORS" -eq 0 ]; then
  echo "  All good. Start the game with:"
  echo "      $ROOT/scripts/play-heroes3.sh              windowed, work alongside it"
  echo "      $ROOT/scripts/play-heroes3.sh --fullscreen"
else
  echo "  $ERRORS problem(s) - logs in $LOG_DIR"
  echo "  Undo everything with: $0 --revert"
fi
info "backup: $BACKUP"
exit "$ERRORS"
