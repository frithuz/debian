#!/usr/bin/env bash
# Validate the live-installer policy with LVM's own config parser; no disk I/O.
set -euo pipefail
here=$(dirname "$(realpath "$0")")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export LVM_SYSTEM_DIR=$work
cat > "$work/lvm.conf" <<'EOF'
backup { backup = 0 }
activation { auto_activation_volume_list = [ "old-vg" ] }
EOF
cat > "$work/lvmlocal.conf" <<'EOF'
activation { udev_sync = 0 }
EOF
"$here/../config/bin/disable-lvm-autoactivation"
[[ $(lvmconfig --type current --valuesonly activation/auto_activation_volume_list) == '[]' ]]
[[ $(lvmconfig --type current --valuesonly activation/udev_sync) == 0 ]]
[[ $(lvmconfig --type current --valuesonly backup/backup) == 0 ]]
lvmconfig --validate >/dev/null
cp "$work/lvmlocal.conf" "$work/first.conf"
"$here/../config/bin/disable-lvm-autoactivation"
cmp "$work/first.conf" "$work/lvmlocal.conf"
echo 'installer LVM autoactivation policy: ok'
