#!/usr/bin/env bash
#
# bundle-libs.sh - build the offline library bundle (maintainer tool).
#
# Distributions eventually drop end-of-life releases from their archives, and
# the 32-bit packages this fix depends on go with them. This collects the whole
# i386 dependency closure into a directory with checksums, so it can be attached
# to a GitHub release and installed years later with:
#     ./install-deps.sh --offline <dir>
#
# All packages are free software from the Ubuntu archive (mostly MIT/LGPL). The
# manifest records the exact source package of each file, so the corresponding
# sources can always be fetched with `apt-get source <package>`.
#
# USAGE
#   ./bundle-libs.sh [output-dir]        default: ./offline-libs
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/common.sh"

OUT="${1:-$(dirname "$HERE")/offline-libs}"
command -v apt-get >/dev/null || die "this tool needs apt"

SEEDS="libgl1:i386 libglx-mesa0:i386 libgl1-mesa-dri:i386 libpulse0:i386 libasound2t64:i386 libudev1:i386"

step "Resolving the i386 dependency closure"
LIST="$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
         --no-breaks --no-replaces --no-enhances $SEEDS 2>/dev/null \
        | grep -E "^[a-z0-9]" | grep ":i386" | sort -u)"
COUNT="$(echo "$LIST" | grep -c .)"
[ "$COUNT" -gt 0 ] || die "could not resolve any packages"
ok "$COUNT packages"

mkdir -p "$OUT"
step "Downloading into $OUT"
( cd "$OUT" && echo "$LIST" | xargs -r apt-get download ) || die "download failed"

step "Writing the manifest"
( cd "$OUT" && sha256sum ./*.deb > MANIFEST.sha256 )
{
  echo "# heroes3-linux-fix offline library bundle"
  echo "# built $(date -Is) on $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  echo "#"
  echo "# All packages come from the distribution archive and are free software."
  echo "# Sources: apt-get source <source-package>, or the distribution's archive."
  echo "#"
  printf "%-42s %-26s %s\n" "PACKAGE" "VERSION" "SOURCE"
  echo "$LIST" | while read -r p; do
    [ -n "$p" ] || continue
    V="$(apt-cache show "$p" 2>/dev/null | awk '/^Version:/{print $2; exit}')"
    S="$(apt-cache show "$p" 2>/dev/null | awk '/^Source:/{print $2; exit}')"
    printf "%-42s %-26s %s\n" "$p" "${V:-?}" "${S:-${p%%:*}}"
  done
} > "$OUT/MANIFEST.txt"
ok "MANIFEST.txt and MANIFEST.sha256 written"

SIZE="$(du -sh "$OUT" | awk '{print $1}')"
step "Done"
info "bundle: $OUT ($SIZE)"
info "attach it to a release, for example:"
info "  tar czf heroes3-linux-fix-offline-libs.tar.gz -C \"$(dirname "$OUT")\" \"$(basename "$OUT")\""
info "  gh release create v1.0 heroes3-linux-fix-offline-libs.tar.gz"
