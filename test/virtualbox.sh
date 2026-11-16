#!/usr/bin/env bash
# Create (or recreate) a VirtualBox VM limited to 1 vCPU / 1 GB RAM and boot the ISO.
#   ./test/virtualbox.sh [path/to.iso]
#   FIRMWARE=efi ./test/virtualbox.sh        # UEFI boot test
#   RAM_MB=1536 CPUS=2 CPU_CAP=50 ./test/virtualbox.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO="$(readlink -f "${1:-$HERE/../out/ASM-OS.iso}")"
VM="${VM:-ASM-OS-Test}"
RAM_MB="${RAM_MB:-1024}"
CPUS="${CPUS:-1}"
CPU_CAP="${CPU_CAP:-100}"       # % of host CPU time the vCPU may use (50 = half-speed)
FIRMWARE="${FIRMWARE:-bios}"    # bios | efi

[[ -f $ISO ]] || { echo "ISO not found: $ISO" >&2; exit 1; }
command -v VBoxManage >/dev/null || { echo "VirtualBox (VBoxManage) not found" >&2; exit 1; }

VBoxManage controlvm "$VM" poweroff 2>/dev/null || true
sleep 1
VBoxManage unregistervm "$VM" --delete 2>/dev/null || true

VBoxManage createvm --name "$VM" --ostype Debian_64 --register
VBoxManage modifyvm "$VM" \
    --memory "$RAM_MB" --cpus "$CPUS" --cpuexecutioncap "$CPU_CAP" \
    --ioapic on --firmware "$FIRMWARE" \
    --graphicscontroller vmsvga --vram 16 \
    --nic1 nat --nictype1 82540EM \
    --boot1 dvd --boot2 none --boot3 none --boot4 none \
    --mouse usbtablet
VBoxManage storagectl "$VM" --name SATA --add sata --controller IntelAhci
VBoxManage storageattach "$VM" --storagectl SATA --port 0 --device 0 --type dvddrive --medium "$ISO"

echo ">> Starting $VM: ${CPUS} CPU (cap ${CPU_CAP}%), ${RAM_MB} MB RAM, firmware=${FIRMWARE}"
VBoxManage startvm "$VM" --type gui
