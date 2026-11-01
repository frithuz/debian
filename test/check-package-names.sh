#!/usr/bin/env bash
# Check every package name against Debian, NodeSource, Docker and GitHub CLI
# indexes for each architecture before any build runs. Needs network; no root.
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
nodesource=$(awk '/^URIs:/ {print $2}' "$cfg/files/etc/apt/sources.list.d/nodesource.sources/SERVER")
docker_repo=$(awk '/^URIs:/ {print $2}' "$cfg/files/etc/apt/sources.list.d/docker.sources/SERVER")
sbx_source=$cfg/files/etc/apt/sources.list.d/docker-sbx.sources/SERVER
sbx_repo=$(awk '/^URIs:/ {print $2}' "$sbx_source")
sbx_suite=$(awk '/^Suites:/ {print $2}' "$sbx_source")
github_cli=$(awk '/^URIs:/ {print $2}' "$cfg/files/etc/apt/sources.list.d/github-cli.sources/SERVER")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cloud_classes() { echo "DEBIAN,FAIBASE,SERVER,HARDEN,CLOUD,$1,DHCPC,GRUB_EFI,CLOUD_EFI,LAST"; }
metal_classes() { echo "DEFAULT,$1,DHCPC,INSTALL,FAIBASE,DEBIAN,SERVER,HARDEN,METAL,GRUB_EFI,METAL_EFI,LAST"; }

bad=0
for arch in amd64 arm64; do
    cls=${arch^^}
    for comp in main contrib non-free non-free-firmware; do
        curl -fsSL "$mirror/dists/$release/$comp/binary-$arch/Packages.xz" | xz -d | awk '/^Package: / {print $2}'
    done | sort -u > "$tmp/$arch.names"
    curl -fsSL "$nodesource/dists/nodistro/main/binary-$arch/Packages" \
        | awk '/^Package: / {print $2}' | sort -u > "$tmp/$arch.nodesource"
    curl -fsSL "$docker_repo/dists/$release/stable/binary-$arch/Packages.gz" \
        | gzip -d | awk '/^Package: / {print $2}' | sort -u > "$tmp/$arch.docker"
    curl -fsSL "$sbx_repo/dists/$sbx_suite/stable/binary-$arch/Packages.gz" \
        | gzip -d | awk '/^Package: / {print $2}' | sort -u > "$tmp/$arch.sbx"
    curl -fsSL "$github_cli/dists/stable/main/binary-$arch/Packages.gz" \
        | gzip -d | awk '/^Package: / {print $2}' | sort -u > "$tmp/$arch.github-cli"
    for classes in "$(cloud_classes "$cls")" "$(metal_classes "$cls")"; do
        "$cfg/bin/resolve-packages" --source-vars "$cfg" "$classes"
    done | sort -u > "$tmp/$arch.wanted"
    while IFS=$'\t' read -r pkg action cls_file; do
        case $pkg in
            docker-sbx)
                if ! grep -qx "$pkg" "$tmp/$arch.sbx"; then
                    echo "$arch: $pkg (package_config/$cls_file) does not exist in $sbx_repo ($sbx_suite)"
                    bad=1
                fi
                continue ;;
            gh)
                if ! grep -qx "$pkg" "$tmp/$arch.github-cli"; then
                    echo "$arch: $pkg (package_config/$cls_file) does not exist in $github_cli"
                    bad=1
                fi
                continue ;;
            docker-ce|docker-ce-cli|containerd.io)
                if ! grep -qx "$pkg" "$tmp/$arch.docker"; then
                    echo "$arch: $pkg (package_config/$cls_file) does not exist in $docker_repo"
                    bad=1
                fi
                continue ;;
        esac
        if [ "$pkg" = nodejs ] && [ "$action" = install ]; then
            if ! grep -qx "$pkg" "$tmp/$arch.nodesource"; then
                echo "$arch: nodejs (package_config/$cls_file) does not exist in $nodesource"
                bad=1
            fi
            continue
        fi
        grep -qx "$pkg" "$tmp/$arch.names" && continue
        echo "$arch: '$pkg' ($action, package_config/$cls_file) does not exist in $release"
        bad=1
    done < "$tmp/$arch.wanted"
    echo "$arch: $(cut -f1 "$tmp/$arch.wanted" | sort -u | wc -l) names checked against Debian, NodeSource, Docker and GitHub CLI"
done
exit $bad
