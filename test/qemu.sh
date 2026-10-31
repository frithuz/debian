#!/usr/bin/env bash
# Boot the build artifacts in QEMU (UEFI). No root needed.
#
#   qemu.sh cloud         BUILD   boot cloud-$ARCH.qcow2 (throwaway overlay) + NoCloud seed
#   qemu.sh metal-install BUILD   boot metal-$ARCH.iso with a blank 32G "server disk"
#   qemu.sh metal-boot    BUILD   boot that disk after installing
#
# Environment:
#   ARCH=amd64|arm64   guest architecture (default: this host's). Same as the host -> KVM
#                      when /dev/kvm is usable; otherwise full emulation (slow).
#   USERDATA=FILE      cloud-init user-data for the cloud seed (default: config/cloud-init/user-data)
#   HEADLESS=1         run in the background: no display, serial console to $work/serial.log,
#                      PID in $work/qemu.pid (used by test/ci-boot-test.sh)
#   QEMU_WORK=DIR      scratch dir for disks, NVRAM, seed (default: test/work)
#
# SSH into the guest: ssh -p 2222 jonathan@localhost (or `make ssh`)
set -euo pipefail

mode=${1:?mode: cloud | metal-install | metal-boot}
build=$(realpath "${2:?build dir}")
here=$(dirname "$(realpath "$0")")
work=${QEMU_WORK:-$here/work}
arch=${ARCH:-$(dpkg --print-architecture)}
userdata=${USERDATA:-$here/../config/cloud-init/user-data}
mkdir -p "$work"

need() { [[ -f $1 ]] || { echo "missing $1; build it first (sudo make $2 ARCH=$arch)" >&2; exit 1; }; }

case $arch in
amd64)
    qemu="qemu-system-x86_64"
    machine=(-machine q35)
    fw_code=/usr/share/OVMF/OVMF_CODE_4M.fd fw_vars=/usr/share/OVMF/OVMF_VARS_4M.fd fw_pkg=ovmf
    gfx=()
    ;;
arm64)
    qemu="qemu-system-aarch64"
    machine=(-machine "virt,gic-version=max")
    fw_code=/usr/share/AAVMF/AAVMF_CODE.fd fw_vars=/usr/share/AAVMF/AAVMF_VARS.fd fw_pkg=qemu-efi-aarch64
    gfx=(-device virtio-gpu-pci -device qemu-xhci -device usb-kbd)   # virt has no VGA/PS2
    ;;
*) echo "unsupported ARCH=$arch" >&2; exit 2 ;;
esac
command -v $qemu >/dev/null || { echo "$qemu not found; sudo make deps" >&2; exit 1; }
[[ -r $fw_code ]] || { echo "UEFI firmware $fw_code not found; apt install $fw_pkg" >&2; exit 1; }

host_arch=$(dpkg --print-architecture 2>/dev/null || true)
if [[ $arch == "$host_arch" && -w /dev/kvm ]]; then
    accel=(-accel kvm -cpu host)
else
    accel=(-accel tcg -cpu max)
    echo "note: no KVM for $arch on this host, using full emulation (slow)" >&2
fi

uefi() { # per-VM writable NVRAM
    local vars=$work/$1-$arch-vars.fd
    [[ -f $vars ]] || cp "$fw_vars" "$vars"
    echo -drive "if=pflash,format=raw,readonly=on,file=$fw_code" \
         -drive "if=pflash,format=raw,file=$vars"
}

common=("${machine[@]}" -m 2048 -smp 2 "${accel[@]}"
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22"
        -device "virtio-net-pci,netdev=n0"
        -device "virtio-scsi-pci,id=scsi0")

console() { # $@ = how to show the console interactively
    if [[ ${HEADLESS:-0} == 1 ]]; then
        echo -display none -serial "file:$work/serial.log" -daemonize -pidfile "$work/qemu.pid"
    else
        echo "$@"
    fi
}
cdrom() { echo -drive "if=none,id=cd0,media=cdrom,readonly=on,format=raw,file=$1" -device scsi-cd,drive=cd0,bus=scsi0.0; }
disk_nvme() { echo -drive "if=none,id=d0,format=qcow2,file=$1" -device nvme,drive=d0,serial=fai-test; }

case $mode in
cloud)
    image=$build/cloud-$arch.qcow2
    need "$image" cloud
    command -v cloud-localds >/dev/null || { echo "apt install cloud-image-utils" >&2; exit 1; }
    printf 'instance-id: test-%s\nlocal-hostname: cloud-test\n' "$(date +%s)" > "$work/meta-data"
    cloud-localds "$work/seed.iso" "$userdata" "$work/meta-data"

    # overlay so every test run starts from the pristine image, like a real cloud
    rm -f "$work/cloud-run.qcow2" "$work/cloud-$arch-vars.fd" "$work/serial.log"
    qemu-img create -q -f qcow2 -F qcow2 -b "$image" "$work/cloud-run.qcow2" 10G

    [[ ${HEADLESS:-0} == 1 ]] || echo ">>> serial console below (Ctrl-a x to quit). Then: make ssh"
    # shellcheck disable=SC2046
    exec $qemu "${common[@]}" $(uefi cloud) $(console -nographic) \
        -drive "if=virtio,format=qcow2,file=$work/cloud-run.qcow2" \
        -drive "if=virtio,format=raw,readonly=on,file=$work/seed.iso"
    ;;
metal-install)
    iso=$build/metal-$arch.iso
    need "$iso" metal-iso
    rm -f "$work/metal-$arch-disk.qcow2" "$work/metal-$arch-vars.fd"
    qemu-img create -q -f qcow2 "$work/metal-$arch-disk.qcow2" 32G
    echo ">>> choose 'Client standalone installation - select installation type from menu',"
    echo ">>> then the 'Hardened server' profile. Close the window when it says it's done."
    # shellcheck disable=SC2046
    exec $qemu "${common[@]}" $(uefi metal) "${gfx[@]}" \
        $(disk_nvme "$work/metal-$arch-disk.qcow2") $(cdrom "$iso") -boot order=d
    ;;
metal-boot)
    [[ -f $work/metal-$arch-disk.qcow2 ]] || { echo "run 'make test-metal' first" >&2; exit 1; }
    [[ ${HEADLESS:-0} == 1 ]] || echo ">>> serial console below (Ctrl-a x to quit). Then: make ssh"
    # shellcheck disable=SC2046
    exec $qemu "${common[@]}" $(uefi metal) $(console -nographic) \
        $(disk_nvme "$work/metal-$arch-disk.qcow2")
    ;;
*)
    echo "unknown mode: $mode" >&2; exit 2 ;;
esac
