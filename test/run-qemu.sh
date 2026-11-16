#!/usr/bin/env bash
# Boot ASM-OS.iso in QEMU with legacy-PC limits.
#
#   ./test/run-qemu.sh [path/to.iso]
#
# Environment overrides (defaults shown):
#   FIRMWARE=bios    bios | uefi            (uefi needs the 'ovmf' package)
#   RAM_MB=1024      try 1536 for the upper end of the target range
#   CPUS=1           try 2 for the upper end
#   ACCEL=auto       auto | kvm | tcg       (tcg = pure emulation, deliberately slow)
#   CPU_MODEL=       e.g. Penryn, Nehalem   (defaults: host with KVM, Penryn with TCG)
#   DISK=            optional qcow2 disk (created if missing) for persistence/install tests
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO="${1:-$HERE/../out/ASM-OS.iso}"
FIRMWARE="${FIRMWARE:-bios}"
RAM_MB="${RAM_MB:-1024}"
CPUS="${CPUS:-1}"
ACCEL="${ACCEL:-auto}"
DISK="${DISK:-}"

[[ -f $ISO ]] || { echo "ISO not found: $ISO" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "Install QEMU: sudo apt install qemu-system-x86" >&2; exit 1; }

if [[ $ACCEL == auto ]]; then
    if [[ -w /dev/kvm ]]; then ACCEL=kvm; else ACCEL=tcg; fi
fi
if [[ $ACCEL == kvm ]]; then
    ACCEL_ARGS=(-enable-kvm -cpu "${CPU_MODEL:-host}")
else
    ACCEL_ARGS=(-accel tcg -cpu "${CPU_MODEL:-Penryn}")
fi

BOOT_ARGS=()
if [[ $FIRMWARE == uefi ]]; then
    OVMF=""
    for f in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF.fd /usr/share/qemu/OVMF.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
        [[ -f $f ]] && { OVMF=$f; break; }
    done
    [[ -n $OVMF ]] || { echo "OVMF firmware not found. Install: sudo apt install ovmf" >&2; exit 1; }
    BOOT_ARGS=(-bios "$OVMF")
fi

DISK_ARGS=()
if [[ -n $DISK ]]; then
    [[ -f $DISK ]] || qemu-img create -f qcow2 "$DISK" 8G
    DISK_ARGS=(-drive "file=$DISK,if=ide,format=qcow2")
fi

echo ">> ${FIRMWARE^^} | ${CPUS} CPU | ${RAM_MB} MB RAM | ${ACCEL}"
exec qemu-system-x86_64 \
    -name "ASM-OS-test" \
    "${ACCEL_ARGS[@]}" \
    -smp "cpus=${CPUS},cores=${CPUS},threads=1,sockets=1" \
    -m "${RAM_MB}" \
    "${BOOT_ARGS[@]}" \
    -cdrom "$ISO" -boot d \
    "${DISK_ARGS[@]}" \
    -vga std \
    -nic user,model=e1000 \
    -usb -device usb-tablet
