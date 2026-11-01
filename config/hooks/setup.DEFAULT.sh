#!/usr/bin/env bash

# use short hostname instead of FQDN
export HOSTNAME=${HOSTNAME%%.*}
if inside_nfsroot; then
  echo $HOSTNAME > /proc/sys/kernel/hostname
  # Apply to the live installer, including udev's LVM commands. Never copy this
  # policy into the installed system or apply it to the native cloud build host.
  "$FAI/bin/disable-lvm-autoactivation" || { task_error 999; return 1; }
fi
