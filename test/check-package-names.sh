#!/usr/bin/env bash
# Check every package name in package_config/ against the real Debian archive index, for
# each architecture, before any build runs. Needs network; no root.
#
#   test/check-package-names.sh [RELEASE]      (default: trixie)
#
# Why: FAI silently drops unknown names from install lists (scripts/LAST/90-verify-packages
# then fails the build late), and `apt-get purge` of an unknown name fails outright.
# Names disappear between releases (e.g. dnsutils, rsh-client, prelink in trixie).
set -euo pipefail

release=${1:-trixie}
mirror=${MIRROR:-https://deb.debian.org/debian}
here=$(dirname "$(realpath "$0")")
cfg=$here/../config
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cloud_classes() { echo "DEBIAN,FAIBASE,SERVER,HARDEN,CLOUD,$1,DHCPC,GRUB_EFI,CLOUD_EFI,LAST"; }
metal_classes() { echo "DEFAULT,$1,DHCPC,INSTALL,FAIBASE,DEBIAN,SERVER,HARDEN,METAL,GRUB_EFI,METAL_EFI,LAST"; }

bad=0
for arch in amd64 arm64; do
    cls=${arch^^}
    for comp in main contrib non-free non-free-firmware; do
        curl -fsSL "$mirror/dists/$release/$comp/binary-$arch/Packages.xz" | xz -d | awk '/^Package: / {print $2}'
    done | sort -u > "$tmp/$arch.names"
    for classes in "$(cloud_classes "$cls")" "$(metal_classes "$cls")"; do
        "$cfg/bin/resolve-packages" --source-vars "$cfg" "$classes"
    done | sort -u > "$tmp/$arch.wanted"
    while IFS=$'\t' read -r pkg action cls_file; do
        grep -qx "$pkg" "$tmp/$arch.names" && continue
        echo "$arch: '$pkg' ($action, package_config/$cls_file) does not exist in $release"
        bad=1
    done < "$tmp/$arch.wanted"
    echo "$arch: $(cut -f1 "$tmp/$arch.wanted" | sort -u | wc -l) names checked against $(wc -l < "$tmp/$arch.names") packages"
done
exit $bad
