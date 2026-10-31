#!/usr/bin/env bash
# Boot test for CI (also runs locally): boot build/cloud-$ARCH.qcow2 headless, log in,
# and check the running system. Writes results to $OUT (default build/boot-test-$ARCH).
#
#   ARCH=amd64 test/ci-boot-test.sh build
#
# Login uses a throwaway key generated here and added to a copy of the real user-data,
# so the test doesn't need anyone's private key. The real user-data (incl. the GitHub
# key import) is still applied, so that path is exercised too.
#
# Checks (any failure -> exit 1):
#   - SSH comes up as the default user; cloud-init finishes without errors
#   - no swap; packages.tsv present; live package list captured (live-packages.tsv)
#   - `cis-check` passes on the running system (after the first-boot AIDE baseline)
# Warnings only: GitHub key import (rate limits on shared CI IPs), failed units.
set -euo pipefail

build=$(realpath "${1:?build dir}")
arch=${ARCH:-$(dpkg --print-architecture)}
here=$(dirname "$(realpath "$0")")
out=${OUT:-$build/boot-test-$arch}
user=${SSH_USER:-jonathan}
rm -rf "$out"; mkdir -p "$out"
export QEMU_WORK=$out/qemu ARCH=$arch HEADLESS=1

if [[ -w /dev/kvm && $arch == "$(dpkg --print-architecture)" ]]; then boot_timeout=600 aide_timeout=1200
else boot_timeout=2400 aide_timeout=3600; fi     # emulated: much slower

# --- user-data = real user-data + throwaway key ---------------------------------
ssh-keygen -q -t ed25519 -N '' -C ci-boot-test -f "$out/id_ci"
key=$(cat "$out/id_ci.pub")
src=$here/../config/cloud-init/user-data
if grep -qE '^ssh_authorized_keys:' "$src"; then
    sed "/^ssh_authorized_keys:/a\\  - $key" "$src" > "$out/user-data"
else
    { cat "$src"; printf '\nssh_authorized_keys:\n  - %s\n' "$key"; } > "$out/user-data"
fi

cleanup() {
    if [[ -f $QEMU_WORK/qemu.pid ]]; then kill "$(cat "$QEMU_WORK/qemu.pid")" 2>/dev/null || true; fi
    cp -f "$QEMU_WORK/serial.log" "$out/serial.log" 2>/dev/null || true
    rm -f "$out/id_ci" "$QEMU_WORK/cloud-run.qcow2"
}
trap cleanup EXIT

USERDATA=$out/user-data "$here/qemu.sh" cloud "$build"

# One multiplexed connection: nftables rate-limits new SSH connections (15/min).
ssh_opts=(-p 2222 -i "$out/id_ci" -o IdentitiesOnly=yes -o BatchMode=yes
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o ConnectTimeout=10 -o ControlMaster=auto -o "ControlPath=$out/cm-%C" -o ControlPersist=30m)
vm() { ssh "${ssh_opts[@]}" "$user@127.0.0.1" "$@"; }

fail=0
bad() { echo "FAIL: $*"; fail=1; }
warn() { echo "WARN: $*"; }

echo "== waiting up to ${boot_timeout}s for SSH"
deadline=$((SECONDS + boot_timeout))
until vm true 2>/dev/null; do
    (( SECONDS < deadline )) || { bad "no SSH login within ${boot_timeout}s (see serial.log)"; exit 1; }
    sleep 15
done
echo "ssh: up after ${SECONDS}s"

echo "== cloud-init"
vm 'cloud-init status --wait --long' > "$out/cloud-init-status.txt" 2>&1 || true
cat "$out/cloud-init-status.txt"
grep -qE '^status: done' "$out/cloud-init-status.txt" || bad "cloud-init did not finish cleanly"
vm 'sudo cat /var/log/cloud-init.log' > "$out/cloud-init.log" 2>&1 || true

echo "== GitHub key import"
n=$(vm 'grep -v ci-boot-test ~/.ssh/authorized_keys | grep -c . || true' 2>/dev/null || true)
[[ $n =~ ^[0-9]+$ ]] || n=0
if (( n > 0 )); then echo "imported $n key(s) via ssh_import_id"
else warn "no keys imported from GitHub (network or API rate limit on shared CI IPs?)"; fi

echo "== basics"
[[ -z $(vm 'swapon --show --noheadings') ]] || bad "swap is active"
vm 'cat /var/lib/fai-build/packages.tsv' > "$out/packages.tsv" || bad "no /var/lib/fai-build/packages.tsv"
# what is really installed now, after first boot (compared with the build manifest in CI)
vm "dpkg-query -W -f='\${db:Status-Status}\t\${binary:Package}\t\${Version}\n' | awk -F'\t' '\$1==\"installed\" {print \$2 \"\t\" \$3}' | sort" \
    > "$out/live-packages.tsv" || bad "could not list installed packages"
vm 'cat /var/lib/fai-build/build-info' > "$out/build-info.txt" || true
vm 'systemctl --failed --no-legend --plain' > "$out/failed-units.txt" || true
[[ -s $out/failed-units.txt ]] && warn "failed units: $(awk '{print $1}' "$out/failed-units.txt" | tr '\n' ' ')"

echo "== waiting up to ${aide_timeout}s for the first-boot AIDE baseline"
deadline=$((SECONDS + aide_timeout))
while [[ $(vm 'systemctl show -p ActiveState --value aide-firstboot-init.service') == activating ]]; do
    (( SECONDS < deadline )) || { warn "AIDE baseline still running; 6.3.2 will fail"; break; }
    sleep 30
done

echo "== cis-check (running system)"
if vm 'sudo cis-check' > "$out/cis-check.txt" 2>&1; then
    tail -1 "$out/cis-check.txt"
else
    grep -E '^(FAIL|EXCEPT)' "$out/cis-check.txt" || true
    tail -1 "$out/cis-check.txt"
    bad "cis-check reports failures on the running system"
fi

vm 'sudo systemctl poweroff' 2>/dev/null || true
for _ in $(seq 60); do [[ -e /proc/$(cat "$QEMU_WORK/qemu.pid" 2>/dev/null || echo 0) ]] || break; sleep 2; done

[[ $fail == 0 ]] && echo "== boot test passed ($arch)" || echo "== boot test FAILED ($arch); results in $out"
exit $fail
