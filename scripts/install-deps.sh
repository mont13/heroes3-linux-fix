#!/usr/bin/env bash
#
# install-deps.sh - install everything Heroes III needs from the distribution.
#
# WHY THIS IS NEEDED
#   Heroes III is a 32-bit Windows program, so Wine runs it as a 32-bit Linux
#   process. That process loads 32-bit (i386) host libraries. Ubuntu 22.04 still
#   pulled most of them in by default; Ubuntu 24.04 does not. Without them Wine
#   logs
#       err:wgl:init_opengl Failed to load libGL: libGL.so.1
#       err:wgl:init_opengl OpenGL support is disabled.
#       err:mmdevapi:init_driver No driver from L"pulse" could be initialized
#   which shows up as a picture that only refreshes when you Alt+Tab, clicks
#   that repaint a fraction of the screen, and no sound at all.
#
#   libudev1:i386 is easy to miss: winepulse.so links against it, so without it
#   Wine silently falls back to raw ALSA. See docs/ROOT-CAUSES.md.
#
# OFFLINE FALLBACK
#   Ubuntu releases reach end of life and their i386 packages eventually leave
#   the archive. Grab the offline bundle attached to this project's GitHub
#   release and pass it with --offline <dir>; the .deb files are installed
#   directly, no archive needed.
#
# USAGE
#   ./install-deps.sh                 install from the distribution (apt)
#   ./install-deps.sh --offline DIR   install .deb files from DIR instead
#   ./install-deps.sh --check         only report what is missing
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/common.sh"

MODE="apt"; OFFLINE_DIR=""
case "${1:-}" in
  --check)   MODE="check" ;;
  --offline) MODE="offline"; OFFLINE_DIR="${2:-}"; [ -d "$OFFLINE_DIR" ] || die "--offline needs a directory" ;;
  "") ;;
  *) die "unknown option: $1" ;;
esac

# 32-bit graphics and audio, plus the tools the launcher and installer need.
# Package names differ between releases, so each entry lists alternatives and
# the first one the distribution actually knows about wins.
PKG_ALTERNATIVES=(
  "libgl1:i386"
  "libglx-mesa0:i386"
  "libgl1-mesa-dri:i386"
  "libpulse0:i386"
  "libasound2t64:i386|libasound2:i386"
  "libudev1:i386"
  "xserver-xephyr"
  "x11-utils"
  "xdotool"
  "wmctrl"
  "imagemagick"
  "innoextract"
)

have_pkg() { apt-cache policy "$1" 2>/dev/null | grep -q "Candidate: [^(]"; }

resolve_packages() {
  local entry alt chosen out=""
  for entry in "${PKG_ALTERNATIVES[@]}"; do
    chosen=""
    IFS='|' read -ra ALTS <<< "$entry"
    for alt in "${ALTS[@]}"; do
      have_pkg "$alt" && { chosen="$alt"; break; }
    done
    if [ -n "$chosen" ]; then out="$out $chosen"
    else warn "no candidate found for: $entry"; fi
  done
  echo "${out# }"
}

step "Checking what is already present"
MISSING="$(missing_i386_libs)"
if [ -z "$MISSING" ]; then ok "all required 32-bit libraries are installed"
else warn "missing 32-bit libraries:$MISSING"; fi
for t in Xephyr xdotool wmctrl innoextract import; do
  command -v "$t" >/dev/null && ok "tool present: $t" || warn "tool missing: $t"
done

if [ "$MODE" = "check" ]; then
  [ -z "$MISSING" ] && exit 0 || exit 1
fi

if [ "$MODE" = "offline" ]; then
  step "Installing from offline bundle: $OFFLINE_DIR"
  COUNT="$(find "$OFFLINE_DIR" -name '*.deb' | wc -l)"
  [ "$COUNT" -gt 0 ] || die "no .deb files in $OFFLINE_DIR"
  info "$COUNT .deb files found"
  if [ -f "$OFFLINE_DIR/MANIFEST.sha256" ]; then
    ( cd "$OFFLINE_DIR" && sha256sum -c MANIFEST.sha256 --quiet ) \
      && ok "checksums verified" || die "checksum verification failed - do not install"
  else
    warn "no MANIFEST.sha256 in the bundle, skipping checksum verification"
  fi
  echo
  echo "About to run:  sudo dpkg -i $OFFLINE_DIR/*.deb"
  echo "               sudo apt-get -f install      (to settle any dependencies)"
  read -r -p "Continue? [y/N] " a; [ "$a" = "y" ] || exit 1
  sudo dpkg --add-architecture i386
  sudo dpkg -i "$OFFLINE_DIR"/*.deb || sudo apt-get -f install -y
  exit $?
fi

step "Installing from the distribution"
command -v apt-get >/dev/null || die "this script supports apt-based systems (Ubuntu/Debian); install the equivalents manually"

if ! dpkg --print-foreign-architectures 2>/dev/null | grep -qx i386; then
  info "enabling the i386 architecture (needed for any 32-bit Windows game)"
  sudo dpkg --add-architecture i386 || die "could not enable i386"
  sudo apt-get update || die "apt-get update failed"
fi

PKGS="$(resolve_packages)"
info "packages: $PKGS"
echo
echo "Dry run first, so you can see exactly what would change:"
apt-get install -s $PKGS 2>&1 | grep -E "^(Inst|Conf).*|.*upgraded," | tail -5
echo
echo "About to run:  sudo apt-get install -y $PKGS"
read -r -p "Continue? [y/N] " a; [ "$a" = "y" ] || exit 1
sudo apt-get install -y $PKGS || die "installation failed"

step "Verifying"
MISSING="$(missing_i386_libs)"
if [ -z "$MISSING" ]; then
  ok "all required 32-bit libraries are now present"
else
  err "still missing:$MISSING"
  info "if the packages are gone from your distribution's archive, use the"
  info "offline bundle from this project's GitHub release:"
  info "  ./install-deps.sh --offline /path/to/bundle"
fi
exit "$ERRORS"
