#!/usr/bin/env bash
set -euo pipefail
here=$(dirname "$(realpath "$0")")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/etc" "$work/usr/lib"
cat > "$work/usr/lib/os-release" <<'EOF'
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
VERSION_ID="13"
VERSION="13 (trixie)"
VERSION_CODENAME=trixie
ID=debian
SUPPORT_URL="https://www.debian.org/support"
EOF
ln -s ../usr/lib/os-release "$work/etc/os-release"
cp "$work/usr/lib/os-release" "$work/vendor-before"
updater=$here/../config/files/usr/local/sbin/update-frithuz-branding/SERVER
"$updater" "$work"
cmp "$work/vendor-before" "$work/usr/lib/os-release"
[[ ! -L $work/etc/os-release ]]
grep -qx 'PRETTY_NAME="Frithuz - Debian 13"' "$work/etc/os-release"
grep -qx 'VARIANT="Frithuz"' "$work/etc/os-release"
grep -qx 'VARIANT_ID=frithuz' "$work/etc/os-release"
grep -vE '^(PRETTY_NAME|VARIANT|VARIANT_ID)=' "$work/etc/os-release" > "$work/identity"
grep -v '^PRETTY_NAME=' "$work/vendor-before" > "$work/expected-identity"
cmp "$work/identity" "$work/expected-identity"
cp "$work/etc/os-release" "$work/branded-before"
"$updater" "$work"
cmp "$work/branded-before" "$work/etc/os-release"
# Regenerate from updated Debian data, without duplicate or stale keys.
sed 's/13/14/g; s/trixie/forky/g' "$work/vendor-before" > "$work/usr/lib/os-release"
"$updater" "$work"
grep -qx 'PRETTY_NAME="Frithuz - Debian 14"' "$work/etc/os-release"
grep -qx 'VERSION_CODENAME=forky' "$work/etc/os-release"
[[ $(grep -c '^PRETTY_NAME=' "$work/etc/os-release") == 1 ]]
echo 'Frithuz branding: ok'
