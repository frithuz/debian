#!/usr/bin/env bash
# Sourced before setup-storage: disk1 must refer only to the selected target,
# never to the first device in FAI's unfiltered discovery order.
[[ $FAI_ACTION == install ]] || return 0

disk_choice_args=()
[[ -z ${flag_menu:-} ]] || disk_choice_args+=(--interactive)
if ! udevadm settle --timeout=120 ||
   ! install_disk=$("$FAI/bin/select-install-disk" "${disk_choice_args[@]}" "${FAI_INSTALL_DISK:-}"); then
    # Also skip the task if task_error returns after an installer rescue shell.
    touch "$LOGDIR/skip.partition"
    task_error 999
    return 1
fi
export disklist=${install_disk#/dev/}
if ! lvm_plan=$("$FAI/bin/prepare-metal-storage" "$install_disk" "$FAI/disk_config/METAL_EFI"); then
    touch "$LOGDIR/skip.partition"
    task_error 999
    return 1
fi
read -r install_vg foreign_vgs <<< "$lvm_plan"
export SS_IGNORE_VG="${SS_IGNORE_VG:-} ${foreign_vgs:-}"
echo "Install target: $install_disk (disk1); all data on this disk will be erased."
echo "Target volume group: $install_vg; ignoring unrelated groups: ${foreign_vgs:-none}"
unset install_disk disk_choice_args lvm_plan install_vg foreign_vgs
