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
#
# Progress: script lines are prefixed with the elapsed time ([mm:ss]), waits report
# their state about once a minute, and the VM's serial console is streamed with a
# [vm] prefix (SERIAL=0 to turn that off). A table of phase durations is printed at
# the end and, in GitHub Actions, added to the job summary.
set -euo pipefail

build=$(realpath "${1:?build dir}")
arch=${ARCH:-$(dpkg --print-architecture)}
here=$(dirname "$(realpath "$0")")
out=${OUT:-$build/boot-test-$arch}
user=${SSH_USER:-jonathan}
rm -rf "$out"; mkdir -p "$out"
export QEMU_WORK=$out/qemu ARCH=$arch HEADLESS=1

if [[ -w /dev/kvm && $arch == "$(dpkg --print-architecture)" ]]; then boot_timeout=600 ci_timeout=600 aide_timeout=1200
else boot_timeout=2400 ci_timeout=2400 aide_timeout=3600; fi     # emulated: much slower
heartbeat=60   # seconds between "still waiting" lines

# --- progress output -------------------------------------------------------------
mmss() { printf '%02d:%02d' $(($1 / 60)) $(($1 % 60)); }
log() { printf '[%s] %s\n' "$(mmss $SECONDS)" "$*"; }
fail=0
bad() { log "FAIL: $*"; fail=1; }
warn() { log "WARN: $*"; }

# phase NAME: end the current phase (if any) and start NAME; `phase` alone just ends it
phases=() durations=() phase_name='' phase_t0=0
phase() {
    if [[ -n $phase_name ]]; then phases+=("$phase_name"); durations+=($((SECONDS - phase_t0))); fi
    phase_name=${1:-} phase_t0=$SECONDS
    [[ -z $phase_name ]] || log "== $phase_name"
}
summary() { # RESULT
    local i table
    table=$(printf '| Phase | Duration |\n|---|---|\n'
            for i in "${!phases[@]}"; do printf '| %s | %s |\n' "${phases[$i]}" "$(mmss "${durations[$i]}")"; done
            printf '| **total** | **%s** |\n' "$(mmss $SECONDS)")
    printf '\n%s\n' "$table"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
        printf '### Boot test (%s): %s\n\n%s\n\n' "$arch" "$1" "$table" >> "$GITHUB_STEP_SUMMARY"
    fi
}

# --- user-data = real user-data + throwaway key ---------------------------------
phase "start VM"
# The key goes in $QEMU_WORK, which CI doesn't upload, so it can't end up in an
# artifact even when the job is cancelled before cleanup runs.
mkdir -p "$QEMU_WORK"
ssh-keygen -q -t ed25519 -N '' -C ci-boot-test -f "$QEMU_WORK/id_ci"
key=$(cat "$QEMU_WORK/id_ci.pub")
src=$here/../config/cloud-init/user-data
if grep -qE '^ssh_authorized_keys:' "$src"; then
    sed "/^ssh_authorized_keys:/a\\  - $key" "$src" > "$out/user-data"
else
    { cat "$src"; printf '\nssh_authorized_keys:\n  - %s\n' "$key"; } > "$out/user-data"
fi

cleanup() {
    local rc=$?
    phase
    if [[ -f $QEMU_WORK/qemu.pid ]]; then kill "$(cat "$QEMU_WORK/qemu.pid")" 2>/dev/null || true; fi
    if [[ -n ${serial_pid:-} ]]; then sleep 1; kill "$serial_pid" 2>/dev/null || true; fi
    cp -f "$QEMU_WORK/serial.log" "$out/serial.log" 2>/dev/null || true
    rm -f "$QEMU_WORK/id_ci" "$QEMU_WORK/cloud-run.qcow2"
    if [[ $rc == 0 && $fail == 0 ]]; then summary passed; else summary FAILED; fi
}
trap cleanup EXIT

USERDATA=$out/user-data "$here/qemu.sh" cloud "$build"

# Serial console -> job log, live. tail exits with QEMU; ANSI colours and CRs stripped.
if [[ ${SERIAL:-1} == 1 ]]; then
    tail -n +1 -F --pid="$(cat "$QEMU_WORK/qemu.pid")" "$QEMU_WORK/serial.log" 2>/dev/null \
        | sed -u -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r//g' -e 's/^/[vm] /' &
    serial_pid=$!
fi

# One multiplexed connection: nftables rate-limits new SSH connections (15/min).
ssh_opts=(-p 2222 -i "$QEMU_WORK/id_ci" -o IdentitiesOnly=yes -o BatchMode=yes
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o ConnectTimeout=10 -o ControlMaster=auto -o "ControlPath=$out/cm-%C" -o ControlPersist=30m)
vm() { ssh "${ssh_opts[@]}" "$user@127.0.0.1" "$@"; }

phase "wait for SSH (up to ${boot_timeout}s)"
deadline=$((SECONDS + boot_timeout)) next=$((SECONDS + heartbeat))
until err=$(vm true 2>&1); do
    (( SECONDS < deadline )) || { bad "no SSH login within ${boot_timeout}s (see serial.log)"; exit 1; }
    if (( SECONDS >= next )); then log "still waiting for SSH: $(tail -1 <<< "${err:-no output}")"; next=$((SECONDS + heartbeat)); fi
    sleep 15
done
log "ssh: up"

phase "cloud-init (up to ${ci_timeout}s)"
# Poll rather than `status --wait`: shows the current stage, and can't hang forever.
deadline=$((SECONDS + ci_timeout)) next=0 last=''
while :; do
    st=$(vm 'cloud-init status --long' 2>&1) || true
    status=$(awk -F': ' '$1 == "status" {print $2; exit}' <<< "$st")
    detail=$(awk -F': ' '$1 == "detail" {print $2; exit}' <<< "$st")
    [[ $status == running || $status == 'not started' || -z $status ]] || break
    if [[ "$status $detail" != "$last" || $SECONDS -ge $next ]]; then
        log "cloud-init: ${status:-no status} ${detail:+($detail)}"; last="$status $detail" next=$((SECONDS + heartbeat))
    fi
    (( SECONDS < deadline )) || { warn "cloud-init still ${status:-unknown} after ${ci_timeout}s"; break; }
    sleep 5
done
printf '%s\n' "$st" > "$out/cloud-init-status.txt"
cat "$out/cloud-init-status.txt"
grep -qE '^status: done' "$out/cloud-init-status.txt" || bad "cloud-init did not finish cleanly"
vm 'sudo cat /var/log/cloud-init.log' > "$out/cloud-init.log" 2>&1 || true

phase "GitHub key import"
n=$(vm 'grep -v ci-boot-test ~/.ssh/authorized_keys | grep -c . || true' 2>/dev/null || true)
[[ $n =~ ^[0-9]+$ ]] || n=0
if (( n > 0 )); then log "imported $n key(s) via ssh_import_id"
else warn "no keys imported from GitHub (network or API rate limit on shared CI IPs?)"; fi

phase "basics"
# sudo: swapon is in /usr/sbin, and systemctl needs dbus (not installed) unless run as root.
# Without it these checks see empty output and pass without checking anything.
sw=$(vm 'sudo swapon --show --noheadings') || bad "could not check swap"
[[ -z $sw ]] || bad "swap is active"
vm 'cat /var/lib/fai-build/packages.tsv' > "$out/packages.tsv" || bad "no /var/lib/fai-build/packages.tsv"
# what is really installed now, after first boot (compared with the build manifest in CI)
vm "dpkg-query -W -f='\${db:Status-Status}\t\${binary:Package}\t\${Version}\n' | awk -F'\t' '\$1==\"installed\" {print \$2 \"\t\" \$3}' | sort" \
    > "$out/live-packages.tsv" || bad "could not list installed packages"
vm 'cat /var/lib/fai-build/build-info' > "$out/build-info.txt" || true
vm 'sudo systemctl --failed --no-legend --plain' > "$out/failed-units.txt" || true
[[ -s $out/failed-units.txt ]] && warn "failed units: $(awk '{print $1}' "$out/failed-units.txt" | tr '\n' ' ')"

phase "AIDE first-boot baseline (up to ${aide_timeout}s)"
deadline=$((SECONDS + aide_timeout)) next=0
aide_state() { vm 'sudo systemctl show -p ActiveState --value aide-firstboot-init.service'; }
# Also wait while it hasn't started yet: it's ordered after cloud-final.service.
while [[ $(aide_state) =~ ^(activating|inactive)$ ]] && ! vm 'sudo test -e /var/lib/aide/aide.db'; do
    (( SECONDS < deadline )) || { warn "AIDE baseline not done after ${aide_timeout}s ($(aide_state)); 6.3.2 will fail"; break; }
    if (( SECONDS >= next )); then
        # etimes/times: wall-clock and CPU seconds of the aide process
        et='' ct=''
        read -r et ct < <(vm 'ps -C aide -o etimes=,times= | head -1' 2>/dev/null || true) || true
        log "AIDE baseline: $(aide_state)${et:+, aide up $(mmss "$et"), $(mmss "${ct:-0}") CPU}"
        next=$((SECONDS + heartbeat))
    fi
    sleep 30
done
log "AIDE: $(vm 'sudo systemctl show -p ActiveState,Result --value aide-firstboot-init.service | paste -sd" "' 2>/dev/null || echo unknown)"

phase "cis-check (running system)"
if vm 'sudo cis-check' > "$out/cis-check.txt" 2>&1; then
    tail -1 "$out/cis-check.txt"
else
    grep -E '^(FAIL|EXCEPT)' "$out/cis-check.txt" || true
    tail -1 "$out/cis-check.txt"
    bad "cis-check reports failures on the running system"
fi

phase "power off"
vm 'sudo systemctl poweroff' 2>/dev/null || true
for _ in $(seq 60); do [[ -e /proc/$(cat "$QEMU_WORK/qemu.pid" 2>/dev/null || echo 0) ]] || break; sleep 2; done

[[ $fail == 0 ]] && log "== boot test passed ($arch)" || log "== boot test FAILED ($arch); results in $out"
exit $fail
