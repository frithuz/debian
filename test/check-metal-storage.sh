#!/usr/bin/env bash
set -euo pipefail
here=$(dirname "$(realpath "$0")")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
export PV_FIXTURE=$work/pvs
cat > "$work/bin/pvs" <<'EOF'
#!/bin/sh
cat "$PV_FIXTURE"
EOF
cat > "$work/bin/lsblk" <<'EOF'
#!/bin/sh
echo /dev/nvme0n1
echo /dev/nvme0n1p3
EOF
chmod +x "$work/bin/"*
export PATH=$work/bin:$PATH
prepare=$here/../config/bin/prepare-metal-storage
fresh_config() { cp "$here/../config/disk_config/METAL_EFI" "$work/config"; }
fresh_config
: > "$PV_FIXTURE"
[[ $("$prepare" /dev/nvme0n1 "$work/config") == vg0 ]]

# A VG on the other NVMe must be ignored, not reduced or reused.
printf '/dev/nvme1n1p3|vg0|uuid-other\n' > "$PV_FIXTURE"
[[ $("$prepare" /dev/nvme0n1 "$work/config") == 'vg1 vg0' ]]
grep -q '^vg vg1 disk1.3$' "$work/config"
grep -q '^vg1-root / 35G ' "$work/config"
! grep -q '^vg0-' "$work/config"
# Repeating preparation keeps the same target name.
cp "$work/config" "$work/first"
[[ $("$prepare" /dev/nvme0n1 "$work/config") == 'vg1 vg0' ]]
cmp "$work/first" "$work/config"

# A group wholly on the target can be recreated using its original name.
fresh_config
printf '/dev/nvme0n1p3|vg0|uuid-target\n' > "$PV_FIXTURE"
[[ $("$prepare" /dev/nvme0n1 "$work/config") == vg0 ]]

# Refuse groups spanning disks and duplicate names across distinct groups.
for other_uuid in uuid-target uuid-other; do
    fresh_config
    cp "$work/config" "$work/before"
    printf '/dev/nvme0n1p3|vg0|uuid-target\n/dev/nvme1n1p3|vg0|%s\n' "$other_uuid" > "$PV_FIXTURE"
    if "$prepare" /dev/nvme0n1 "$work/config" > "$work/stdout" 2> "$work/stderr"; then
        echo 'unsafe VG cleanup accepted' >&2
        exit 1
    fi
    [[ ! -s $work/stdout ]]
    cmp "$work/before" "$work/config"
done
echo 'metal storage isolation: ok'
