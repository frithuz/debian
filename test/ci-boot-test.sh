#!/usr/bin/env bash
# Boot test for CI (also runs locally): boot an artifact headless, log in, and check
# the running system.
#
#   ARCH=amd64 test/ci-boot-test.sh build          # build/cloud-$ARCH.qcow2
#   ARCH=amd64 test/ci-boot-test.sh build metal    # build/metal-$ARCH.iso
#
# metal first installs from the ISO onto a blank 64G NVMe disk, unattended (see
# `qemu.sh metal-install`), then boots that disk. Results go to $OUT (default
# build/boot-test-$ARCH, or build/boot-test-metal-$ARCH).
#
# Login uses a throwaway key generated here and added to a copy of the real user-data,
# so the test doesn't need anyone's private key. The real user-data (incl. the GitHub
# key import) is still applied, so that path is exercised too.
#
# Checks (any failure -> exit 1):
#   - SSH comes up as the default user; cloud-init finishes without errors
#   - no swap; DNS works, LLMNR off; packages.tsv present; live package list captured (live-packages.tsv)
#   - `cis-check` passes on the running system (after the first-boot AIDE baseline)
#   - metal: FAI finishes and powers off, reports no task errors (its logs are saved
#     in fai-install/), used the hardened classes, and created the separate mounts
# Warnings only: GitHub key import (rate limits on shared CI IPs), failed units (their
# journals are saved as journal-UNIT.txt).
#
# Progress: script lines are prefixed with the elapsed time ([mm:ss]), waits report
# their state about once a minute, and the VM's serial console is streamed with a
# [vm] prefix (SERIAL=0 to turn that off). A table of phase durations is printed at
# the end and, in GitHub Actions, added to the job summary.
set -euo pipefail

build=$(realpath "${1:?build dir}")
kind=${2:-cloud}
[[ $kind == cloud || $kind == metal ]] || { echo "unknown artifact: $kind (cloud | metal)" >&2; exit 2; }
arch=${ARCH:-$(dpkg --print-architecture)}
here=$(dirname "$(realpath "$0")")
if [[ $kind == cloud ]]; then out=${OUT:-$build/boot-test-$arch}; else out=${OUT:-$build/boot-test-metal-$arch}; fi
user=${SSH_USER:-jonathan}
rm -rf "$out"; mkdir -p "$out"
export QEMU_WORK=$out/qemu ARCH=$arch HEADLESS=1

if [[ -w /dev/kvm && $arch == "$(dpkg --print-architecture)" ]]; then
    install_timeout=3600 boot_timeout=600 ci_timeout=600 aide_timeout=1200
else install_timeout=10800 boot_timeout=2400 ci_timeout=2400 aide_timeout=3600; fi     # emulated: much slower
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
        printf '### Boot test (%s, %s): %s\n\n%s\n\n' "$kind" "$arch" "$1" "$table" >> "$GITHUB_STEP_SUMMARY"
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

# Keep network diagnostics available even when the guest never accepts SSH.
# Vendor-data leaves the real user-data intact; bootcmd runs after cloud-init
# has rendered networking, including when network-online timed out.
cat > "$out/vendor-data" <<'EOF'
#cloud-config
bootcmd:
  - |
    {
      echo '=== boot network diagnostics ==='
      ip -br link
      ip -br addr
      networkctl status --all --no-pager
      grep -r . /etc/systemd/network /run/systemd/network 2>/dev/null
      journalctl -b -u systemd-networkd --no-pager -o short-monotonic
      echo '=== end boot network diagnostics ==='
    } > /dev/console 2>&1
EOF
export VENDORDATA=$out/vendor-data

# QEMU removes its pidfile when it exits, so remember the PID.
qemu_pid='' serial_pid=''
start_qemu() { # qemu.sh arguments
    "$here/qemu.sh" "$@" "$build"
    qemu_pid=$(cat "$QEMU_WORK/qemu.pid")
    # Serial console -> job log, live. tail exits with QEMU; ANSI colours and CRs stripped.
    if [[ ${SERIAL:-1} == 1 ]]; then
        tail -n +1 -F --pid="$qemu_pid" "$QEMU_WORK/serial.log" 2>/dev/null \
            | sed -u -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r//g' -e 's/^/[vm] /' &
        serial_pid=$!
    fi
}
stop_qemu() {
    if [[ -n $qemu_pid ]]; then kill "$qemu_pid" 2>/dev/null || true; fi
    if [[ -n $serial_pid ]]; then sleep 1; kill "$serial_pid" 2>/dev/null || true; fi
    qemu_pid='' serial_pid=''
}
qemu_running() {
    local state
    [[ -n $qemu_pid ]] || return 1
    # QEMU daemonizes, so container PID 1 must reap it. Some CI containers
    # leave the exited process as a zombie: /proc/PID and kill -0 still
    # succeed even though the guest has powered off.
    state=$(ps -o stat= -p "$qemu_pid" 2>/dev/null) || return 1
    [[ -n $state && $state != Z* && $state != X* ]]
}

cleanup() {
    local rc=$?
    phase
    stop_qemu
    cp -f "$QEMU_WORK/serial.log" "$out/serial.log" 2>/dev/null || true
    rm -f "$QEMU_WORK/id_ci" "$QEMU_WORK/cloud-run.qcow2" "$QEMU_WORK/metal-$arch-disk.qcow2"
    if [[ $rc == 0 && $fail == 0 ]]; then summary passed; else summary FAILED; fi
}
trap cleanup EXIT

if [[ $kind == metal ]]; then
    phase "install from ISO (up to ${install_timeout}s)"
    # The install uses the user-data baked into the ISO; the test key comes in at boot.
    start_qemu metal-install
    deadline=$((SECONDS + install_timeout)) next=$((SECONDS + heartbeat))
    while qemu_running; do
        if grep -q 'FATAL ERROR' "$QEMU_WORK/serial.log" 2>/dev/null; then
            bad "FAI stopped the installation (see install-serial.log)"; exit 1
        fi
        (( SECONDS < deadline )) || { bad "install not finished within ${install_timeout}s (see install-serial.log)"; exit 1; }
        if (( SECONDS >= next )); then
            log "still installing: $(sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r//g' "$QEMU_WORK/serial.log" 2>/dev/null | grep -v '^\s*$' | tail -1)"
            next=$((SECONDS + heartbeat))
        fi
        sleep 10
    done
    stop_qemu
    mv "$QEMU_WORK/serial.log" "$out/install-serial.log"
    log "installer powered off"
    phase "start VM (installed disk)"
fi
export USERDATA=$out/user-data
if [[ $kind == metal ]]; then start_qemu metal-boot; else start_qemu cloud; fi

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
vm 'sudo cat /var/log/cloud-init-output.log' > "$out/cloud-init-output.log" 2>&1 || true

phase "user development tools"
# Plain SSH uses non-interactive Bash startup; also check a login shell.
# Commands and their targets must belong to the user, not a global install.
vm 'set -e; for tool in claude codex pnpm; do
    expected="$HOME/.local/bin/$tool"
    if [ "$tool" = pnpm ]; then expected="$PNPM_HOME/bin/pnpm"; fi
    test "$(command -v "$tool")" = "$expected"
    test -O "$expected"
    "$tool" --version
done' > "$out/user-agents.txt" 2>&1 || bad "development tools missing, not user-owned, or absent from SSH PATH"
vm 'bash -lc '\''set -e; for tool in claude codex pnpm; do
    expected="$HOME/.local/bin/$tool"
    if [ "$tool" = pnpm ]; then expected="$PNPM_HOME/bin/pnpm"; fi
    test "$(command -v "$tool")" = "$expected"
done'\''' || bad "development tools absent from login shell PATH"

phase "GitHub key import"
n=$(vm 'grep -v ci-boot-test ~/.ssh/authorized_keys | grep -c . || true' 2>/dev/null || true)
[[ $n =~ ^[0-9]+$ ]] || n=0
if (( n > 0 )); then log "imported $n key(s) via ssh_import_id"
else warn "no keys imported from GitHub (network or API rate limit on shared CI IPs?)"; fi

phase "basics"
vm 'set -e
    test ! -s /etc/motd
    test ! -x /etc/update-motd.d/10-uname
    test -x /etc/update-motd.d/05-frithuz
    test -x /etc/update-motd.d/92-unattended-upgrades
    grep -qF "Just be chill." /run/motd.dynamic
    grep -qF "Jonathan Garbee <garbee@frithuz.com>" /run/motd.dynamic
    grep -qE "^ENV=(local|dev|test|staging|production)$" /etc/environment
    sudo systemctl is-active --quiet docker.service containerd.service
    sudo docker info --format "{{.ServerVersion}}"' \
    || bad "Frithuz PAM MOTD, environment, or Docker is not configured"
vm 'set -e
    sudo systemctl is-active --quiet frithuz-issue.service
    expected=$(hostname | tr "[:lower:]" "[:upper:]" | tr -d "\n")
    actual=$(awk "NR == 10 || NR == 11 {printf \"%s\", substr(\$0, 17, 33)}" /etc/issue.net | tr -d " ")
    test "$actual" = "$expected"
    grep -qF "*** AUTHORIZED ACCESS ONLY ***" /etc/issue.net
    test "$(stat -c %a /etc/issue.net)" = 644' \
    || bad "SSH castle banner is missing or has the wrong hostname or permissions"
vm '. /etc/os-release; test "$ID" = debian && test "$VARIANT_ID" = frithuz && test "$PRETTY_NAME" = "Frithuz - Debian $VERSION_ID"' \
    || bad "Frithuz OS display metadata is missing or changed Debian identity"
vm '. /etc/os-release; sudo grep -qF "Frithuz - Debian $VERSION_ID" /boot/grub/grub.cfg' \
    || bad "Frithuz GRUB label is missing"
# sudo: swapon is in /usr/sbin, and systemctl needs dbus (not installed) unless run as root.
# Without it these checks see empty output and pass without checking anything.
sw=$(vm 'sudo swapon --show --noheadings') || bad "could not check swap"
[[ -z $sw ]] || bad "swap is active"
sudo_version=$(vm 'sudo --version' 2>&1) || true
[[ $sudo_version == sudo-rs* ]] || bad "sudo is not sudo-rs: $(head -1 <<< "$sudo_version")"
# -n: fail instead of prompting. jonathan has no password, so a prompt means no NOPASSWD rule.
vm 'sudo -n true' || bad "$user has no passwordless sudo"
# sbin is on $user's PATH (DEBIAN/30-sudo-rs), in plain ssh sessions and login shells.
# sudo searches the caller's PATH, so without it `sudo cis-check` is "command not found".
for sh in 'echo "$PATH"' 'bash -lc '\''echo "$PATH"'\'''; do
    p=$(vm "$sh" 2>&1) || true
    [[ :$p: == *:/usr/sbin:* && :$p: == *:/usr/local/sbin:* ]] || bad "no sbin on $user's PATH ($sh): '$p'"
done
# The caller's PATH survives sudo (Defaults:%sudo !secure_path in /etc/sudoers).
mapfile -t paths < <(vm 'export PATH=/opt/ci-path-test:$PATH; echo "$PATH"; sudo -n sh -c '\''echo "$PATH"'\''' 2>&1)
[[ ${paths[0]} == /opt/ci-path-test:* && ${paths[1]-} == "${paths[0]}" ]] \
    || bad "sudo did not keep $user's PATH: '${paths[0]-}' became '${paths[1]-}'"
vm 'cat /var/lib/fai-build/packages.tsv' > "$out/packages.tsv" || bad "no /var/lib/fai-build/packages.tsv"
# what is really installed now, after first boot (compared with the build manifest in CI)
vm "dpkg-query -W -f='\${db:Status-Status}\t\${binary:Package}\t\${Version}\n' | awk -F'\t' '\$1==\"installed\" {print \$2 \"\t\" \$3}' | sort" \
    > "$out/live-packages.tsv" || bad "could not list installed packages"
vm 'cat /var/lib/fai-build/build-info' > "$out/build-info.txt" || true
# network as configured (cloud-init's systemd-networkd files) and as it came up
vm 'sudo grep -r . /etc/systemd/network/; ip -br addr; sudo networkctl --no-pager; sudo resolvectl status --no-pager' \
    > "$out/network.txt" 2>&1 || true
vm 'getent ahosts deb.debian.org >/dev/null' || bad "DNS lookup failed in the VM (see network.txt)"
llmnr=$(vm 'sudo resolvectl llmnr' 2>&1) || true
[[ $llmnr == *'Global: no'* && $llmnr != *': yes'* ]] || bad "LLMNR is not off: $(tr '\n' ' ' <<< "$llmnr")"
vm 'sudo systemctl --failed --no-legend --plain' > "$out/failed-units.txt" || true
# Each failed unit's journal for this boot: saved in full, the tail shown here.
for unit in $(awk '{print $1}' "$out/failed-units.txt"); do
    warn "failed unit: $unit (journal: journal-$unit.txt)"
    vm "sudo journalctl -b -u '$unit' --no-pager -o short-monotonic" > "$out/journal-$unit.txt" 2>&1 || true
    tail -n 20 "$out/journal-$unit.txt" | sed "s/^/  [$unit] /"
done

if [[ $kind == metal ]]; then
    phase "metal install"
    # FAI's logs from the install, saved on the disk (fai-savelog), incl. its cis-check.txt
    mkdir -p "$out/fai-install"
    vm 'sudo tar -C /var/log/fai/metal-test/last/ -cf - .' | tar -C "$out/fai-install" -xf - \
        || bad "no FAI install logs in /var/log/fai/metal-test/last/"
    task_error=$(cat "$out/fai-install/task_error" 2>/dev/null || echo missing)
    if [[ $task_error != 0 ]]; then
        bad "FAI install reported errors (task_error: $task_error; see fai-install/)"
        tail -n 20 "$out/fai-install/error.log" 2>/dev/null | sed 's/^/  [error.log] /' || true
    fi
    classes=$(tr '\n' ' ' < "$out/fai-install/FAI_CLASSES" 2>/dev/null || true)
    log "classes: $classes"
    for c in DEBIAN SERVER HARDEN METAL GRUB_EFI METAL_EFI LAST; do
        [[ " $classes " == *" $c "* ]] || bad "class $c missing from the install"
    done
    for m in /boot /boot/efi /var /var/log /var/log/audit /home /tmp; do
        vm "findmnt -n '$m' >/dev/null" || bad "$m is not a separate mount"
    done
    vm 'sudo test -s /var/lib/cloud/seed/nocloud/user-data' || bad "no NoCloud seed baked into the install"
fi

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
for _ in $(seq 60); do qemu_running || break; sleep 2; done

[[ $fail == 0 ]] && log "== boot test passed ($kind, $arch)" || log "== boot test FAILED ($kind, $arch); results in $out"
exit $fail
