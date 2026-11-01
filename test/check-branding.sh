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
# FAI copies APT configuration before the branding setup script runs. Execute
# the actual hook command against the fixture, first without its updater.
hook_file=$here/../config/files/etc/apt/apt.conf.d/90-frithuz-branding/SERVER
hook=$(sed -n 's/^DPkg::Post-Invoke { "\(.*\)"; };$/\1/p' "$hook_file")
[[ -n $hook ]]
mkdir -p "$work/bin"
hook=${hook//\/usr\/local\/sbin\/update-frithuz-branding/$work/bin/update-frithuz-branding}
sh -c "$hook"
[[ -L $work/etc/os-release ]]
cmp "$work/vendor-before" "$work/etc/os-release"

# Once installed, the hook must refresh the metadata and propagate failures.
export BRANDING_UPDATER=$updater BRANDING_ROOT=$work
cat > "$work/bin/update-frithuz-branding" <<'EOF'
#!/bin/sh
exec "$BRANDING_UPDATER" "$BRANDING_ROOT"
EOF
chmod +x "$work/bin/update-frithuz-branding"
sh -c "$hook"
cmp "$work/vendor-before" "$work/usr/lib/os-release"
[[ ! -L $work/etc/os-release ]]
grep -qx 'PRETTY_NAME="Frithuz - Debian 13"' "$work/etc/os-release"
grep -qx 'VARIANT="Frithuz"' "$work/etc/os-release"
grep -qx 'VARIANT_ID=frithuz' "$work/etc/os-release"
grep -vE '^(PRETTY_NAME|VARIANT|VARIANT_ID)=' "$work/etc/os-release" > "$work/identity"
grep -v '^PRETTY_NAME=' "$work/vendor-before" > "$work/expected-identity"
cmp "$work/identity" "$work/expected-identity"
cp "$work/etc/os-release" "$work/branded-before"
sh -c "$hook"
cmp "$work/branded-before" "$work/etc/os-release"
# Regenerate from updated Debian data, without duplicate or stale keys.
sed 's/13/14/g; s/trixie/forky/g' "$work/vendor-before" > "$work/usr/lib/os-release"
sh -c "$hook"
grep -qx 'PRETTY_NAME="Frithuz - Debian 14"' "$work/etc/os-release"
grep -qx 'VERSION_CODENAME=forky' "$work/etc/os-release"
[[ $(grep -c '^PRETTY_NAME=' "$work/etc/os-release") == 1 ]]
printf '#!/bin/sh\nexit 42\n' > "$work/bin/update-frithuz-branding"
rc=0
sh -c "$hook" || rc=$?
[[ $rc == 42 ]]
echo 'Frithuz branding: ok'
