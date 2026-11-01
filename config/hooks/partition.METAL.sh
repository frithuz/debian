#!/usr/bin/env bash
# Sourced before setup-storage: disk1 must refer only to the selected target,
# never to the first device in FAI's unfiltered discovery order.
[[ $FAI_ACTION == install ]] || return 0

if ! udevadm settle --timeout=120 ||
   ! install_disk=$("$FAI/bin/select-install-disk" "${FAI_INSTALL_DISK:-}"); then
    # Also skip the task if task_error returns after an installer rescue shell.
    touch "$LOGDIR/skip.partition"
    task_error 999
    return 1
fi
export disklist=${install_disk#/dev/}
echo "Install target: $install_disk (disk1); all data on this disk will be erased."
unset install_disk
