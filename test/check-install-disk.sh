#!/usr/bin/env bash
# Exercise storage selection without touching any real devices.
set -euo pipefail
here=$(dirname "$(realpath "$0")")
selector=$here/../config/bin/select-install-disk
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
export DISK_FIXTURE=$work/disks
cat > "$work/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output='' device=''
while (( $# )); do
    case $1 in
        --output) output=$2; shift 2 ;;
        /dev/*) device=$1; shift ;;
        *) shift ;;
    esac
done
while IFS='|' read -r name type removable readonly size transport mounts; do
    [[ -z $device || $device == "$name" ]] || continue
    case $output in
        NAME,TYPE) printf '%s %s\n' "$name" "$type" ;;
        NAME) printf '%s\n' "$name" ;;
        RM,RO,SIZE,TRAN) printf '%s %s %s %s\n' "$removable" "$readonly" "$size" "$transport" ;;
        SIZE,MODEL,SERIAL) printf '%s Fixture-SSD serial-%s\n' "$size" "${name##*/}" ;;
        MOUNTPOINTS)
            [[ $mounts != ERROR ]] || exit 1
            [[ $mounts == - ]] || printf '%s\n' "$mounts"
            ;;
        *) exit 2 ;;
    esac
done < "$DISK_FIXTURE"
EOF
chmod +x "$work/bin/lsblk"
export PATH=$work/bin:$PATH

selected() {
    local actual
    actual=$("$selector" "${2:-}" 2> "$work/stderr")
    [[ $actual == "$1" ]] || { echo "expected $1, got $actual" >&2; exit 1; }
}
refused() {
    if "$selector" "${1:-}" > "$work/stdout" 2> "$work/stderr"; then
        echo "unsafe or ambiguous disk selection succeeded" >&2
        exit 1
    fi
    [[ ! -s $work/stdout ]]
}

# A fixed USB key can report RM=0; even if it sorts first it isn't a target.
cat > "$DISK_FIXTURE" <<'EOF'
/dev/sda|disk|0|0|64000000000|usb|-
/dev/nvme0n1|disk|0|0|256000000000|nvme|-
/dev/sr0|rom|1|0|500000000|sata|/run/initramfs/live
/dev/vda|disk|0|1|500000|virtio|-
EOF
selected /dev/nvme0n1
refused /dev/sda
ln -s /dev/nvme0n1 "$work/internal"
selected /dev/nvme0n1 "$work/internal"

# Removable media, mounted descendants (including mapped ISO media), swap,
# read-only devices, undersized disks and unknown sizes are never selected.
for properties in \
    '1|0|64000000000|mmc|-' \
    '0|0|64000000000||/run/initramfs/live' \
    '0|0|64000000000||[SWAP]' \
    '0|1|64000000000|sata|-' \
    '0|0|4000000000|sata|-' \
    '0|0|34359738368|nvme|-' \
    '0|0|51539607551|nvme|-' \
    '0|0|unknown|sata|-' \
    '0|0|64000000000|sata|ERROR'; do
    printf '/dev/sda|disk|%s\n' "$properties" > "$DISK_FIXTURE"
    refused
    refused /dev/sda
done

# Multiple internal drives require an explicit choice; a missing drive fails.
cat > "$DISK_FIXTURE" <<'EOF'
/dev/sda|disk|1|0|0|usb|-
/dev/sdb|disk|0|0|32000000000|usb|/run/initramfs/live
/dev/nvme1n1|disk|0|0|256000000000|nvme|-
/dev/nvme0n1|disk|0|0|256000000000|nvme|-
EOF
refused
selected /dev/nvme0n1 /dev/nvme0n1
refused /dev/missing

# Exercise the interactive path in a real pseudo-terminal. The dialog stub
# selects the second disk and checks that both identifiable choices are shown.
export DIALOG_ARGS=$work/dialog-args DIALOG_CHOICE=/dev/nvme1n1 DIALOG_CANCEL=0
cat > "$work/bin/dialog" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$DIALOG_ARGS"
[[ $DIALOG_CANCEL == 0 ]] || exit 1
printf '%s\n' "$DIALOG_CHOICE" >&3
EOF
chmod +x "$work/bin/dialog"
printf -v menu_command '%q --interactive 2>%q' "$selector" "$work/menu-stderr"
actual=$(script --quiet --return --command "$menu_command" /dev/null | tr -d '\r')
[[ $actual == /dev/nvme1n1 ]]
grep -q serial-nvme0n1 "$DIALOG_ARGS"
grep -q serial-nvme1n1 "$DIALOG_ARGS"
! grep -q /dev/sdb "$DIALOG_ARGS"
export DIALOG_CANCEL=1
if script --quiet --return --command "$menu_command" /dev/null > "$work/cancelled.log"; then
    echo 'cancelled dialog accepted a disk' >&2
    exit 1
fi
export DIALOG_CANCEL=0 DIALOG_CHOICE=/dev/sdb
if script --quiet --return --command "$menu_command" /dev/null > "$work/invalid-choice.log"; then
    echo 'dialog accepted an excluded USB disk' >&2
    exit 1
fi
# An explicit target works without a terminal, bypassing the menu.
actual=$("$selector" --interactive /dev/nvme0n1 2> "$work/stderr")
[[ $actual == /dev/nvme0n1 ]]

: > "$DISK_FIXTURE"
refused

# QEMU's single blank NVMe disk remains eligible, as does internal eMMC.
printf '/dev/nvme0n1|disk|0|0|68719476736|nvme|-\n' > "$DISK_FIXTURE"
selected /dev/nvme0n1
printf '/dev/nvme0n1|disk|0|0|51539607552|nvme|-\n' > "$DISK_FIXTURE"
selected /dev/nvme0n1
printf '/dev/mmcblk0|disk|0|0|64000000000||-\n' > "$DISK_FIXTURE"
selected /dev/mmcblk0

# The sourced hook must update the environment used by setup-storage, and
# must prevent partitioning even if FAI's error handler returns to its caller.
mkdir -p "$work/fai/bin" "$work/fai/hooks" "$work/fai/disk_config"
cp "$here/../config/bin/"{select-install-disk,prepare-metal-storage} "$work/fai/bin/"
cp "$here/../config/hooks/partition.METAL.sh" "$work/fai/hooks/"
cp "$here/../config/disk_config/METAL_EFI" "$work/fai/disk_config/"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/pvs"
chmod +x "$work/bin/pvs"
export FAI=$work/fai FAI_ACTION=install LOGDIR=$work
udevadm() { return 0; }
task_error() { [[ $1 == 999 ]]; }
export -f udevadm task_error
bash -ec 'source "$FAI/hooks/partition.METAL.sh"; [[ $disklist == mmcblk0 ]]' > "$work/hook.log"
cat > "$DISK_FIXTURE" <<'EOF'
/dev/nvme0n1|disk|0|0|256000000000|nvme|-
/dev/nvme1n1|disk|0|0|256000000000|nvme|-
EOF
export flag_menu=1 DIALOG_CHOICE=/dev/nvme1n1
printf -v hook_command 'bash -ec %q' 'source "$FAI/hooks/partition.METAL.sh"; [[ $disklist == nvme1n1 ]]'
SHELL=/bin/bash script --quiet --return --command "$hook_command" /dev/null > "$work/hook-menu.log"
unset flag_menu
: > "$DISK_FIXTURE"
if bash -ec 'source "$FAI/hooks/partition.METAL.sh"' > "$work/hook.log" 2>&1; then
    echo "partition hook accepted an absent target" >&2
    exit 1
fi
[[ -f $LOGDIR/skip.partition ]]
echo 'install disk selection: ok'
