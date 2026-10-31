#!/usr/bin/env bash
# Files named *.sh are sourced by fai-class; their output is ignored.
#
# Only UEFI installs are supported, but fai-cd always makes the amd64 ISO bootable
# in legacy BIOS mode too. Stop such an install before it touches the disks.

inside_nfsroot || return 0
[ -d /sys/firmware/efi ] && return 0

echo "ERROR: the installer was booted in legacy BIOS mode. Only UEFI installs are" >&2
echo "       supported: enable UEFI boot in the firmware and boot the ISO again." >&2
task_error 999
