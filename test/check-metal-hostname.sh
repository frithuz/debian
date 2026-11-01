#!/usr/bin/env bash
set -euo pipefail
here=$(dirname "$(realpath "$0")")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/net" "$work/bin"
hostname_cmd=$here/../config/bin/metal-hostname
cat > "$work/bin/ip" <<'EOF'
#!/bin/sh
case "$2" in
    -4) [ -z "$ROUTE4" ] || echo "$4 dev $ROUTE4 src 192.0.2.2" ;;
    -6) [ -z "$ROUTE6" ] || echo "$4 dev $ROUTE6 src 2001:db8::2" ;;
esac
EOF
chmod +x "$work/bin/ip"
export PATH=$work/bin:$PATH ROUTE4='' ROUTE6=''

nic() {
    mkdir -p "$work/net/$1/device"
    printf '%s\n' "$2" > "$work/net/$1/address"
    printf '%s\n' "${3:-1}" > "$work/net/$1/type"
    printf '1\n' > "$work/net/$1/carrier"
}

# A Parallels NIC yields a DNS-safe lowercase name.
nic enp0s5 00:1C:42:F0:9E:11
[[ $("$hostname_cmd" "$work/net") == frithuz-001c42f09e11 ]]

# Ignore bridges, Wi-Fi, loopback, malformed and non-unicast addresses.
nic br0 00:00:00:00:00:01
rmdir "$work/net/br0/device"
nic wlan0 00:00:00:00:00:02
mkdir "$work/net/wlan0/wireless"
nic lo 00:00:00:00:00:03 772
nic broken invalid
nic zero 00:00:00:00:00:00
nic multicast 01:00:00:00:00:01
[[ $("$hostname_cmd" "$work/net") == frithuz-001c42f09e11 ]]

# With multiple active NICs and no route, MAC order breaks the tie.
nic zzz 00:11:22:33:44:55
[[ $("$hostname_cmd" "$work/net") == frithuz-001122334455 ]]
mv "$work/net/zzz" "$work/net/aaa"
[[ $("$hostname_cmd" "$work/net") == frithuz-001122334455 ]]
# Prefer routed traffic over a lower MAC on another connected NIC.
export ROUTE4=enp0s5
[[ $("$hostname_cmd" "$work/net") == frithuz-001c42f09e11 ]]
export ROUTE4='' ROUTE6=enp0s5
[[ $("$hostname_cmd" "$work/net") == frithuz-001c42f09e11 ]]
# An IPv4 route wins when IPv4 and IPv6 use different interfaces.
export ROUTE4=aaa
[[ $("$hostname_cmd" "$work/net") == frithuz-001122334455 ]]
# Disconnected NICs cannot win, even with a stale route or a lower MAC.
printf '0\n' > "$work/net/aaa/carrier"
[[ $("$hostname_cmd" "$work/net") == frithuz-001c42f09e11 ]]
printf '0\n' > "$work/net/enp0s5/carrier"
if "$hostname_cmd" "$work/net" > "$work/out" 2>/dev/null; then
    echo 'disconnected NIC inventory accepted' >&2; exit 1
fi
mkdir "$work/empty"
if "$hostname_cmd" "$work/empty" > "$work/out" 2>/dev/null; then
    echo 'empty NIC inventory accepted' >&2; exit 1
fi
[[ ! -s $work/out ]]

# Exercise the installer integration: OS files and cloud-init must agree.
mkdir -p "$work/fai/bin" "$work/fai/cloud-init" "$work/target/etc"
cp "$here/../config/cloud-init/user-data" "$work/fai/cloud-init/user-data"
cat > "$work/fai/bin/metal-hostname" <<'EOF'
#!/bin/sh
echo frithuz-001122334455
EOF
chmod +x "$work/fai/bin/metal-hostname"
fcopy() { :; }
ainsl() { printf '%s\n' "$3" >> "$target$2"; }
export -f fcopy ainsl
export FAI=$work/fai target=$work/target HOSTNAME=localhost
bash "$here/../config/scripts/METAL/20-cloud-init-seed"
[[ $(< "$target/etc/hostname") == frithuz-001122334455 ]]
grep -qx '127.0.1.1 frithuz-001122334455' "$target/etc/hosts"
grep -qx 'local-hostname: frithuz-001122334455' "$target/var/lib/cloud/seed/nocloud/meta-data"
echo 'metal hostname: ok'
