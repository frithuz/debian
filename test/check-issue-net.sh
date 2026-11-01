#!/usr/bin/env bash
set -euo pipefail
here=$(dirname "$(realpath "$0")")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/etc" "$work/usr/local/share/frithuz"
cp "$here/../config/files/usr/local/share/frithuz/issue.net/SERVER" \
    "$work/usr/local/share/frithuz/issue.net"
updater=$here/../config/files/usr/local/sbin/update-frithuz-issue/SERVER

check_name() {
    local name=$1 rendered expected
    printf '%s\n' "$name" > "$work/etc/hostname"
    "$updater" "$work"
    # Both fields retain the walls and all hostname characters, in order.
    rendered=$(awk 'NR == 10 || NR == 11 {
        if (length($0) != 55) exit 1
        printf "%s", substr($0, 17, 33)
    }' "$work/etc/issue.net")
    expected=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
    [[ ${rendered// /} == "$expected" ]]
    ! grep -q '@HOSTNAME' "$work/etc/issue.net"
    # The updater only substitutes the hostname; the rest of the template
    # (including the complete legal notice and literal backslashes) survives.
    sed '10,11d' "$work/etc/issue.net" > "$work/actual"
    sed '10,11d' "$work/usr/local/share/frithuz/issue.net" > "$work/expected"
    cmp "$work/expected" "$work/actual"
    [[ -n $(find "$work/etc/issue.net" -perm 0644) ]]
}
check_name just-my-castle
grep -qF 'J U S T - M Y -' "$work/etc/issue.net"
grep -qF 'C A S T L E' "$work/etc/issue.net"
check_name frithuz-001c42f09e11
check_name a
check_name abcdefghijklmnopq
check_name abcdefghijklmnopqrstuvwxyz12345678
check_name abcdefghijklmnopqrstuvwxyz123456789
check_name abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz01
check_name host.example.com
cp "$work/etc/issue.net" "$work/before"
"$updater" "$work"
cmp "$work/before" "$work/etc/issue.net"
for invalid in '' 'bad hostname' 'bad\name' "$(printf '%065d' 0)"; do
    printf '%s\n' "$invalid" > "$work/etc/hostname"
    if "$updater" "$work" 2>/dev/null; then
        echo "invalid hostname accepted: $invalid" >&2; exit 1
    fi
    cmp "$work/before" "$work/etc/issue.net"
done
echo 'hostname SSH banner: ok'
