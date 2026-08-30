#!/usr/bin/env bash
#
# install-game.sh - unpack a GOG offline installer of Heroes of Might and
# Magic III Complete into a plain directory. No Wine and no Windows needed.
#
# YOU MUST OWN THE GAME. Buy it on GOG.com, then in your GOG library choose
# "Download offline backup game installers" for Windows. You get two files:
#     setup_heroes_of_might_and_magic_3_complete_..._.exe
#     setup_heroes_of_might_and_magic_3_complete_..._-1.bin
# Keep them side by side and point this script at the .exe.
#
# USAGE
#   ./install-game.sh /path/to/setup_heroes..._.exe [target-dir]
#
# The default target is ~/Games/heroes3
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/common.sh"

SETUP="${1:-}"
TARGET="${2:-$HOME/Games/heroes3}"

[ -n "$SETUP" ] || die "usage: $0 /path/to/setup_heroes...exe [target-dir]"
[ -f "$SETUP" ] || die "installer not found: $SETUP"
command -v innoextract >/dev/null || die "innoextract is missing - run ./install-deps.sh first"

step "Inspecting the installer"
innoextract --gog -l -s "$SETUP" >/dev/null 2>&1 \
  && ok "innoextract can read this installer" \
  || die "innoextract cannot read this file. Is it really a GOG Windows installer?
         Note innoextract needs the accompanying .bin file next to the .exe."

if [ -e "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
  warn "target directory is not empty: $TARGET"
  read -r -p "Extract into it anyway? [y/N] " a; [ "$a" = "y" ] || exit 1
fi

step "Extracting to $TARGET"
mkdir -p "$TARGET"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
innoextract --gog -d "$TMP" "$SETUP" || die "extraction failed"

# GOG installers put the game under app/ - flatten that away.
SRC="$TMP/app"
[ -d "$SRC" ] || SRC="$TMP"
cp -a "$SRC/." "$TARGET/" || die "copy failed"

step "Verifying the install"
if is_game_dir "$TARGET"; then
  ok "Heroes3.exe and Data/ are in place"
  info "game directory: $TARGET"
  ls "$TARGET/Data" 2>/dev/null | head -4 | sed 's/^/      /'
else
  err "the extracted tree does not look like a HoMM3 install"
  info "expected $TARGET/Heroes3.exe and $TARGET/Data/"
fi

echo
echo "Next:  ./scripts/fix-heroes3.sh --game-dir \"$TARGET\""
exit "$ERRORS"
