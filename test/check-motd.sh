#!/usr/bin/env bash
# Exercise the login script with deterministic machine/Docker/login fixtures.
set -euo pipefail
here=$(dirname "$(realpath "$0")")
cfg=$here/../config
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export MOTD_FIXTURE=$work
cat > "$work/os-release" <<'EOF'
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
EOF
printf 'ENV="dev"\n' > "$work/environment"
printf '0.10 0.03 0.01 1/100 123\n' > "$work/loadavg"
printf 'MemTotal: 1000 kB\nMemAvailable: 980 kB\n' > "$work/meminfo"
sed -e "s|/etc/environment|$work/environment|g" \
    -e "s|/etc/os-release|$work/os-release|g" \
    -e "s|/proc/loadavg|$work/loadavg|g" \
    -e "s|/proc/meminfo|$work/meminfo|g" \
    "$cfg/files/etc/update-motd.d/05-frithuz/SERVER" > "$work/motd"
cat > "$work/bin/fixture" <<'EOF'
#!/bin/bash
cmd=${0##*/}
printf '%s %s\n' "$cmd" "$*" >> "$MOTD_FIXTURE/calls"
case $cmd in
    hostname) echo just-my-castle ;;
    uname) echo 6.12.0-test ;;
    uptime) echo 'up 2 days, 15 hours, 57 minutes' ;;
    nproc) echo 8 ;;
    free) printf '              total used free shared buff/cache available\nMem:           31Gi 864Mi 1Gi 0B 30Gi 30Gi\n' ;;
    df) printf 'Filesystem Size Used Avail Use%% Mounted on\n/dev/vda1 1.8T 3.9G 1.8T 1%% /\n' ;;
    ip) cat <<'IPS'
2: docker0    inet 172.17.0.1/16 scope global docker0
3: br-test    inet 172.18.0.1/16 scope global br-test
4: veth123    inet 172.19.0.1/16 scope global veth123
5: ens3    inet 147.135.36.92/24 scope global ens3
IPS
        ;;
    docker)
        [[ ${MOCK_DOCKER:-empty} != down ]] || exit 1
        case $1 in
            info)
                if [[ ${MOCK_DOCKER:-empty} == empty ]]; then echo '0 0 1'
                else echo '10 2 3'; fi ;;
            ps) for i in {1..10}; do echo "app-$i"; done ;;
            stats)
                [[ ${MOCK_DOCKER:-} != no-stats ]] || exit 1
                for i in {1..8}; do echo "app-$i|0.10%|10MiB / 100MiB"; done ;;
            *) exit 1 ;;
        esac ;;
    wtmpdb|last)
        [[ $cmd != wtmpdb || ${MOCK_HISTORY:-valid} != fallback ]] || exit 1
        [[ ${MOCK_HISTORY:-valid} != none ]] || exit 0
        cat <<'LOGINS'
reboot system boot 6.12-test Sat Oct 31 00:00 still running
jonathan pts/0 192.0.2.1 Sat Oct 31 02:07 - 04:43 (02:36)
jonathan pts/1 192.0.2.2 Sat Oct 31 01:07 - 02:43 (01:36)

wtmpdb begins Sat Oct 31 00:00
LOGINS
        ;;
    apt|apt-get|apt-cache|dpkg|unattended-upgrade)
        echo 'MOTD invoked a package manager' >&2; exit 99 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$work/bin/fixture"
for cmd in hostname uname uptime nproc free df ip docker wtmpdb last apt apt-get apt-cache dpkg unattended-upgrade; do
    ln -s fixture "$work/bin/$cmd"
done
export PATH=$work/bin:$PATH
render() {
    : > "$work/calls"
    bash "$work/motd" > "$work/colored"
    sed -E $'s/\033\\[[0-9;]*m//g' "$work/colored" > "$work/plain"
    ! grep -Eq '^(apt|apt-get|apt-cache|dpkg|unattended-upgrade) ' "$work/calls"
    ! grep -q Updates "$work/plain"
}
unset ENV
render
grep -qF ' DEV   just-my-castle · Docker, AI agents & the Frithuz web host' "$work/plain"
grep -qF 'Debian GNU/Linux 13 (trixie) · kernel 6.12.0-test' "$work/plain"
grep -qF '0.10, 0.03, 0.01  (8 cores)' "$work/plain"
grep -qF '2%  864Mi / 31Gi' "$work/plain"
grep -qF '1%  3.9G / 1.8T' "$work/plain"
grep -qF '147.135.36.92' "$work/plain"
! grep -q '172\.' "$work/plain"
grep -qF 'Docker  0 running  ·  1 image' "$work/plain"
grep -qF 'Jonathan Garbee <garbee@frithuz.com>' "$work/plain"
grep -qF 'Just be chill.' "$work/plain"
! grep -qE 'reboot|wtmpdb begins' "$work/plain"

for env_name in local dev test staging production; do
    export ENV=$env_name
    "$cfg/bin/check-motd-env" "$ENV"
    render
    label=$(printf '%s' "$ENV" | tr '[:lower:]' '[:upper:]')
    grep -qF " $label " "$work/plain"
done
for env_name in '' invalid PRODUCTION; do
    export ENV=$env_name
    if "$cfg/bin/check-motd-env" "$ENV" 2>/dev/null; then
        echo "invalid MOTD_ENV accepted: '$ENV'" >&2; exit 1
    fi
done
export ENV=invalid
render
grep -qF ' UNKNOWN ENV ' "$work/plain"
unset ENV
: > "$work/environment"
render
grep -qF ' UNKNOWN ENV ' "$work/plain"

# Check both percentage color boundaries against the actual ANSI output.
for available in 310 300 110 100; do
    printf 'MemTotal: 1000 kB\nMemAvailable: %s kB\n' "$available" > "$work/meminfo"
    render
    case $available in
        310) expected=$'\e[32m69%' ;;
        300) expected=$'\e[33m70%' ;;
        110) expected=$'\e[33m89%' ;;
        100) expected=$'\e[31m90%' ;;
    esac
    grep -qF "$expected" "$work/colored"
done
export MOCK_DOCKER=busy
render
grep -qF 'Docker  10 running  ·  2 stopped  ·  3 images' "$work/plain"
[[ $(grep -c '● app-' "$work/plain") == 8 ]]
! grep -q 'app-9' "$work/plain"
grep -qF 'cpu 0.10%  mem 10MiB / 100MiB' "$work/plain"
grep -qF '… and 2 more' "$work/plain"
[[ $(grep -c '^docker stats ' "$work/calls") == 1 ]]
export MOCK_DOCKER=no-stats
render
grep -qF 'cpu n/a  mem n/a' "$work/plain"
export MOCK_DOCKER=down MOCK_HISTORY=none
render
grep -qF 'Docker  not running' "$work/plain"
grep -qF 'no login history (install wtmpdb + libpam-wtmpdb)' "$work/plain"
export MOCK_HISTORY=fallback
render
grep -q '^last -n 3 -a$' "$work/calls"
grep -qF '192.0.2.1' "$work/plain"

# Installation preserves unrelated environment settings and Debian's PAM
# stacks, removes the static MOTD, and disables the stock uname hook.
mkdir -p "$work/target/etc/pam.d" "$work/target/etc/update-motd.d"
for stack in sshd login; do
    cat > "$work/target/etc/pam.d/$stack" <<'EOF'
@include common-auth
session optional pam_motd.so motd=/run/motd.dynamic
session optional pam_motd.so noupdate
@include common-session
EOF
    cp "$work/target/etc/pam.d/$stack" "$work/$stack.before"
done
printf 'LANG=C\nENV=old\n' > "$work/target/etc/environment"
printf 'old static MOTD\n' > "$work/target/etc/motd"
touch "$work/target/etc/update-motd.d/10-uname"
chmod 0755 "$work/target/etc/update-motd.d/10-uname"
fcopy() { install -m 0755 "$FAI/files$3/SERVER" "$target$3"; }
export -f fcopy
export FAI=$cfg target=$work/target
if [[ $(id -u) == 0 ]]; then
    MOTD_ENV=staging bash "$cfg/scripts/SERVER/45-motd"
    [[ ! -s $target/etc/motd && ! -x $target/etc/update-motd.d/10-uname ]]
    grep -qx 'LANG=C' "$target/etc/environment"
    grep -qx 'ENV=staging' "$target/etc/environment"
    [[ $(grep -c '^ENV=' "$target/etc/environment") == 1 ]]
    [[ -x $target/etc/update-motd.d/05-frithuz ]]
    for stack in sshd login; do cmp "$work/$stack.before" "$target/etc/pam.d/$stack"; done
    cp "$target/etc/environment" "$work/environment.before"
    if MOTD_ENV=invalid bash "$cfg/scripts/SERVER/45-motd" 2>/dev/null; then
        echo 'installer accepted invalid MOTD_ENV' >&2; exit 1
    fi
    cmp "$work/environment.before" "$target/etc/environment"
fi
echo 'Frithuz login MOTD: ok'
