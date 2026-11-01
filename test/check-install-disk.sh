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
        RM,RO,SIZE,TRAN) printf '%s %s %s %s\n' "$removable" "$readonly" "$size" "$transport" ;;
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
export FAI=$here/../config FAI_ACTION=install LOGDIR=$work
udevadm() { return 0; }
task_error() { [[ $1 == 999 ]]; }
export -f udevadm task_error
bash -ec 'source "$FAI/hooks/partition.METAL.sh"; [[ $disklist == mmcblk0 ]]' > "$work/hook.log"
: > "$DISK_FIXTURE"
if bash -ec 'source "$FAI/hooks/partition.METAL.sh"' > "$work/hook.log" 2>&1; then
    echo "partition hook accepted an absent target" >&2
    exit 1
fi
[[ -f $LOGDIR/skip.partition ]]
echo 'install disk selection: ok'
