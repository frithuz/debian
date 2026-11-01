#!/usr/bin/env bash
set -euo pipefail
here=$(dirname "$(realpath "$0")")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
modules=$work/root/usr/lib/dracut/modules.d
mkdir -p "$modules/90livenet" "$modules/35network-legacy" "$work/bin"
cat > "$modules/90livenet/parse-livenet.sh" <<'EOF'
#!/bin/sh
get_url_handler
command -v get_url_handler > /dev/null || . "$URL_LIB"
get_url_handler "$root"
EOF
cat > "$work/url-lib.sh" <<'EOF'
get_url_handler() { printf 'handled:%s\n' "$1"; }
EOF
cat > "$modules/35network-legacy/ifup.sh" <<'EOF'
#!/bin/sh
ip link set lo up
ip addr add 127.0.0.1/8 dev lo
EOF
cat > "$work/bin/ip" <<'EOF'
#!/bin/sh
[ "$1" = addr ] || exit 0
if [ "$2" = add ] && [ -e "$IP_STATE" ]; then
    echo 'Error: ipv4: Address already assigned.' >&2
    exit 2
fi
touch "$IP_STATE"
EOF
chmod +x "$work/bin/ip"
export URL_LIB=$work/url-lib.sh root=live:CDLABEL=FAI_CD IP_STATE=$work/ip-state
export PATH=$work/bin:$PATH
cat > "$work/grub.cfg" <<'EOF'
menuentry "install" {
    linux /boot/vmlinuz root=live:CDLABEL=FAI_CD quiet
}
menuentry "rescue" {
    linux /boot/vmlinuz FAI_ACTION=sysinfo root=live:CDLABEL=FAI_CD quiet
}
menuentry "static server" {
    linux /boot/vmlinuz ip=192.168.33.250::192.168.33.1:255.255.255.0:faiserver:eth0:off quiet
}
menuentry "serial" {
    linux /boot/vmlinuz console=ttyAMA0,115200n8 root=live:CDLABEL=FAI_CD quiet
}
EOF
prepare=$here/../config/bin/prepare-installer-boot
"$prepare" "$work/root" "$work/grub.cfg"
actual=$(sh "$modules/90livenet/parse-livenet.sh" 2> "$work/url-stderr")
[[ $actual == handled:live:CDLABEL=FAI_CD && ! -s $work/url-stderr ]]
sh "$modules/35network-legacy/ifup.sh"
sh "$modules/35network-legacy/ifup.sh" 2> "$work/ip-stderr"
[[ ! -s $work/ip-stderr ]]
awk '
    /^[[:space:]]*linux[[:space:]]/ {
        ips=0
        consoles=0
        for (i=1; i<=NF; i++) {
            if ($i ~ /^ip=/) ips++
            if ($i ~ /^console=/) consoles++
        }
        if (ips != 1) exit 1
        if (consoles != 1) exit 1
        if (/console=ttyAMA0,115200n8/) serial++
        else if (/console=tty0([[:space:]]|$)/) local_console++
        else exit 1
        if (/rd.debug/) { if (!/loglevel=7/ || /quiet/) exit 1; debug++ }
        else if (!/loglevel=3/) exit 1
    }
    END { if (debug != 1 || serial != 1 || local_console != 4) exit 1 }
' "$work/grub.cfg"
cp "$work/grub.cfg" "$work/first.cfg"
"$prepare" "$work/root" "$work/grub.cfg"
cmp "$work/first.cfg" "$work/grub.cfg"
echo 'installer boot preparation: ok'
