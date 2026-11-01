#!/usr/bin/env bash
# Verify HTTPS/trust are established before the first APT invocation, including
# old-style, deb822, inherited FAI sources and a target with no CA package yet.
set -euo pipefail
here=$(dirname "$(realpath "$0")")
cfg=$here/../config
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root/etc/apt/sources.list.d" "$work/bin"
cat > "$work/root/etc/apt/sources.list" <<'EOF'
deb http://deb.debian.org/debian trixie main
deb-src [signed-by=/key.gpg] http://deb.debian.org/debian trixie main
deb file:///media/mirror trixie main
EOF
cat > "$work/root/etc/apt/sources.list.d/vendor.sources" <<'EOF'
Types: deb
URIs: http://mirror.example/debian
 http://other.example/debian https://secure.example/debian
Suites: trixie
Components: main
Signed-By: /etc/apt/keyrings/vendor.asc
EOF
printf 'deb http://legacy.example/debian trixie main\n' > "$work/root/etc/apt/sources.list.d/legacy.list"
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'fixture trust' '-----END CERTIFICATE-----' > "$work/ca.crt"
export APT_CALLS=$work/calls
cat > "$work/bin/chroot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=$1; shift
[[ $1 != dpkg-divert ]] || exit 0
[[ $1 == apt-get ]]
[[ -s $root/etc/ssl/certs/ca-certificates.crt ]]
! grep -r 'http://' "$root/etc/apt/sources.list" "$root/etc/apt/sources.list.d"
grep -q 'Verify-Peer "true"' "$root/etc/apt/apt.conf.d/99-frithuz-https"
grep -q 'Verify-Host "true"' "$root/etc/apt/apt.conf.d/99-frithuz-https"
grep -Fxq 'Dir::Bin::Methods::http "false";' "$root/etc/apt/apt.conf.d/99-frithuz-https"
grep -Fxq 'Dir::Bin::Methods::mirror+http "false";' "$root/etc/apt/apt.conf.d/99-frithuz-https"
printf '%s\n' "$*" >> "$APT_CALLS"
[[ ${FAIL_APT_UPDATE:-0} != 1 || $* != *' update' ]]
EOF
chmod +x "$work/bin/chroot"
export PATH=$work/bin:$PATH
"$cfg/bin/bootstrap-apt" "$work/root" "$work/ca.crt"
cat > "$work/expected" <<'EOF'
apt-get --error-on=any update
apt-get -y --no-install-recommends install ca-certificates
EOF
cmp "$work/expected" "$work/calls"
cmp "$work/ca.crt" "$work/root/etc/ssl/certs/ca-certificates.crt"
grep -qx 'deb file:///media/mirror trixie main' "$work/root/etc/apt/sources.list"
grep -qx 'Signed-By: /etc/apt/keyrings/vendor.asc' "$work/root/etc/apt/sources.list.d/vendor.sources"
# Existing target trust survives repeated preparation.
printf 'existing local trust\n' >> "$work/root/etc/ssl/certs/ca-certificates.crt"
cp "$work/root/etc/ssl/certs/ca-certificates.crt" "$work/trust-before"
"$cfg/bin/prepare-apt" "$work/root" "$work/ca.crt"
cmp "$work/trust-before" "$work/root/etc/ssl/certs/ca-certificates.crt"

# No CA bundle or failed HTTPS metadata must stop before a package install.
rm -f "$work/root/etc/ssl/certs/ca-certificates.crt"
: > "$work/calls"
if "$cfg/bin/bootstrap-apt" "$work/root" "$work/missing" 2>/dev/null; then
    echo 'missing bootstrap trust accepted' >&2; exit 1
fi
[[ ! -s $work/calls ]]
if FAIL_APT_UPDATE=1 "$cfg/bin/bootstrap-apt" "$work/root" "$work/ca.crt"; then
    echo 'failed HTTPS update accepted' >&2; exit 1
fi
[[ $(wc -l < "$work/calls") == 1 ]]

# The ISO's base-system recipe must include CA certificates and preserve
# pre-existing include lists (debootstrap only honors its last --include).
mkdir -p "$work/fai/apt/sources.list.d"
cp "$work/root/etc/apt/sources.list" "$work/fai/apt/sources.list"
printf 'URIs: http://mirror.example/debian\n' > "$work/fai/apt/sources.list.d/debian.sources"
for opts in '' '--variant=minbase --include=aptitude,locales' '--include locales --variant=minbase'; do
    printf 'FAI_DEBOOTSTRAP="trixie http://deb.debian.org/debian"\nFAI_DEBOOTSTRAP_OPTS="%s"\n' "$opts" > "$work/fai/nfsroot.conf"
    "$cfg/bin/prepare-fai-https" "$work/fai"
    cp "$work/fai/nfsroot.conf" "$work/nfsroot-before"
    "$cfg/bin/prepare-fai-https" "$work/fai"
    cmp "$work/nfsroot-before" "$work/fai/nfsroot.conf"
    (
        # shellcheck source=/dev/null
        . "$work/fai/nfsroot.conf"
        [[ $FAI_DEBOOTSTRAP == 'trixie https://deb.debian.org/debian' ]]
        [[ $FAI_DEBOOTSTRAP_OPTS == *--include*ca-certificates* ]]
        [[ $FAI_DEBOOTSTRAP_OPTS != *' --include='*' --include='* ]]
        if [[ $opts == *locales* ]]; then [[ $FAI_DEBOOTSTRAP_OPTS == *locales* ]]; fi
        if [[ $opts == *aptitude* ]]; then [[ $FAI_DEBOOTSTRAP_OPTS == *aptitude* ]]; fi
    )
done
! grep -r 'http://' "$work/fai"

# Exercise FAI's actual hook order: updatebase must refresh certificates
# before instsoft.DEBIAN installs locales, which precedes instsoft.SERVER.
mkdir -p "$work/root/usr/bin" "$work/root/usr/sbin" "$work/root/etc/dpkg/dpkg.cfg.d"
export FAI=$cfg target=$work/root FAI_ACTION=install APTPROXY='' verbose=0
export ROOTCMD="chroot $target"
fcopy() { :; }
ainsl() { :; }
install_packages() { echo ' locales '; }
export -f fcopy ainsl install_packages
: > "$work/calls"
bash "$cfg/hooks/updatebase.DEBIAN"
grep -qx force-unsafe-io "$target/etc/dpkg/dpkg.cfg.d/unsafe-io"
bash "$cfg/hooks/instsoft.DEBIAN"
printf '%s\n' 'apt-get -y install locales' >> "$work/expected"
cmp "$work/expected" "$work/calls"

# Finalization must normalize re-copied sources for both live and snapshot
# builds; a local/source override cannot reintroduce HTTP in the final image.
ifclass() { [[ $1 == SERVER || $1 == METAL ]]; }
fcopy() { printf 'deb http://deb.debian.org/debian trixie main\n' > "$target/etc/apt/sources.list"; }
export -f ifclass fcopy
export apt_cdn=https://deb.debian.org release=trixie
for snapshot in '' 20261031T000000Z; do
    fcopy
    rm -f "$target/etc/apt/apt.conf.d/99-frithuz-https"
    APT_SNAPSHOT=$snapshot bash "$cfg/scripts/LAST/96-final-sources"
    ! grep -r 'http://' "$target/etc/apt/sources.list" "$target/etc/apt/sources.list.d"
    grep -Fxq 'Dir::Bin::Methods::http "false";' "$target/etc/apt/apt.conf.d/99-frithuz-https"
    grep -Fxq 'Dir::Bin::Methods::mirror+http "false";' "$target/etc/apt/apt.conf.d/99-frithuz-https"
done
echo 'APT HTTPS bootstrap: ok'
