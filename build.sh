#!/usr/bin/env bash
# ============================================================================
#  ASM OS build system  -  ASM Industries
#
#  Builds a bootable hybrid (BIOS + UEFI) live ISO: out/ASM-OS.iso
#  Base: Debian stable, kernel: Debian linux-image-amd64 (mainline Linux LTS)
#
#  Usage:   sudo ./build.sh [all|rootfs|iso|shell|clean]
#     all     (default) rootfs + iso
#     rootfs  only (re)build the root filesystem in build/rootfs
#     iso     only repackage build/rootfs into the ISO (fast iteration)
#     shell   open a root shell inside build/rootfs for debugging
#     clean   delete build/ and out/
#
#  Configure with environment variables, e.g.
#     sudo WITH_KICAD=1 SQUASHFS_COMP=xz ./build.sh
# ============================================================================
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------ Tunables
: "${ASM_VERSION:=1.0}"
: "${ASM_HOME_URL:=https://asm-industries.example}"   # <- put your real URL here
: "${SUITE:=trixie}"                  # Debian 13 (stable). bookworm also works.
: "${MIRROR:=http://deb.debian.org/debian}"
: "${SECURITY_MIRROR:=http://security.debian.org/debian-security}"
: "${WORKDIR:=${PROJECT_DIR}/build}"
: "${OUTDIR:=${PROJECT_DIR}/out}"
: "${ISO_NAME:=ASM-OS.iso}"
: "${BROWSER_PKG:=falkon}"            # falkon | chromium | netsurf-gtk | epiphany-browser
: "${SQUASHFS_COMP:=zstd}"            # zstd = fastest boot, xz = smallest ISO
: "${WITH_FIRMWARE:=1}"               # Wi-Fi / GPU / microcode blobs (non-free-firmware)
: "${WITH_PLYMOUTH:=1}"               # graphical boot splash
: "${WITH_KICAD:=0}"                  # full KiCad (heavy: wants >=1.5 GB RAM + zram)
: "${WITH_ARM:=0}"                    # arm-none-eabi toolchain (~200 MB installed)
: "${WITH_WIRESHARK:=0}"              # Wireshark Qt GUI (TShark is always included)
: "${KEEP_DOCS:=0}"                   # 1 = keep man pages/locales (bigger image)
: "${DEBOOTSTRAP_ARGS:=}"             # extra args, e.g. "--no-check-gpg" (not advised)
: "${ARDUINO_CLI_URL:=https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_Linux_64bit.tar.gz}"
: "${ARDUINO_CLI_SHA256:=}"           # set to enforce a checksum

ROOTFS="${WORKDIR}/rootfs"
ISO_DIR="${WORKDIR}/iso"
BRAND_DIR="${WORKDIR}/branding"
ISO_PATH="${OUTDIR}/${ISO_NAME}"

# Kernel command line shared by ISOLINUX (BIOS) and GRUB (UEFI).
KERNEL_CMDLINE="boot=live components quiet splash loglevel=3 nowatchdog live-config.username=asm live-config.hostname=asm-os"

HOST_PKGS=(debootstrap squashfs-tools xorriso dosfstools mtools grub-common
           grub-efi-amd64-bin isolinux syslinux-common imagemagick fonts-dejavu-core
           debian-archive-keyring ca-certificates curl)

# ------------------------------------------------------------------- Helpers
log()  { printf '\033[1;36m[ASM]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ASM][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ASM][error]\033[0m %s\n' "$*" >&2; exit 1; }

CHROOT_MOUNTED=0

mount_chroot() {
    [[ $CHROOT_MOUNTED == 1 ]] && return 0
    mount --bind /dev     "$ROOTFS/dev"
    mount --bind /dev/pts "$ROOTFS/dev/pts"
    mount -t proc  proc   "$ROOTFS/proc"
    mount -t sysfs sysfs  "$ROOTFS/sys"
    CHROOT_MOUNTED=1
}

umount_chroot() {
    local m
    for m in sys proc dev/pts dev; do
        if mountpoint -q "$ROOTFS/$m" 2>/dev/null; then
            umount -l "$ROOTFS/$m" 2>/dev/null || warn "could not unmount $ROOTFS/$m"
        fi
    done
    CHROOT_MOUNTED=0
}

cleanup() {
    local rc=$?
    umount_chroot || true
    if [[ $rc -ne 0 ]]; then
        warn "build failed (exit $rc). Re-run to resume; 'sudo ./build.sh shell' to inspect."
    fi
    exit "$rc"
}

chroot_run() {
    chroot "$ROOTFS" /usr/bin/env -i HOME=/root TERM="${TERM:-xterm}" \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

# ----------------------------------------------------------------- Preflight
preflight() {
    [[ $EUID -eq 0 ]] || die "Run as root:  sudo ./build.sh"
    [[ $(uname -m) == x86_64 ]] || die "Build host must be x86_64."

    command -v dpkg >/dev/null || die "Build host must be Debian/Ubuntu based (dpkg missing). Use a Debian container/VM."
    local missing=() p
    for p in "${HOST_PKGS[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if ((${#missing[@]})); then
        log "Installing missing host packages: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    fi

    # Older debootstrap releases (e.g. Ubuntu 22.04) lack a script for new suites.
    if [[ ! -e /usr/share/debootstrap/scripts/$SUITE ]]; then
        warn "debootstrap has no script for '$SUITE'; linking it to 'sid'."
        ln -s sid "/usr/share/debootstrap/scripts/$SUITE"
    fi

    local avail_kb
    avail_kb=$(df --output=avail -k "$(dirname "$WORKDIR")" | tail -n1)
    ((avail_kb > 8*1024*1024)) || warn "Less than 8 GB free in $(dirname "$WORKDIR"); the build may run out of space."
}

# -------------------------------------------------------------- Package list
# packages.list syntax:  name | ?optional | [FLAG] name   (see file header)
parse_packages() {
    local req_file=$1 opt_file=$2 line tok var
    local -a toks
    : > "$req_file"; : > "$opt_file"
    while IFS= read -r line || [[ -n $line ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z $line ]] && continue
        if [[ $line =~ ^\[([A-Z0-9_]+)\][[:space:]]*(.*)$ ]]; then
            var="WITH_${BASH_REMATCH[1]}"
            line="${BASH_REMATCH[2]}"
            [[ "${!var:-0}" == 1 ]] || continue
        fi
        read -r -a toks <<< "$line"
        for tok in "${toks[@]}"; do
            if [[ $tok == \?* ]]; then printf '%s\n' "${tok#\?}" >> "$opt_file"
            else                       printf '%s\n' "$tok"       >> "$req_file"
            fi
        done
    done < "$PROJECT_DIR/packages.list"
    printf '%s\n' "$BROWSER_PKG" >> "$req_file"
}

# ------------------------------------------------------------ Stage: rootfs
bootstrap() {
    if [[ -x "$ROOTFS/usr/bin/apt-get" ]]; then
        log "Reusing existing bootstrap in $ROOTFS (run 'clean' for a fresh one)"
        return
    fi
    log "debootstrap: Debian $SUITE (minbase) -> $ROOTFS"
    mkdir -p "$ROOTFS"
    local -a extra=() keyring=()
    [[ -n $DEBOOTSTRAP_ARGS ]] && read -r -a extra <<< "$DEBOOTSTRAP_ARGS"
    [[ -f /usr/share/keyrings/debian-archive-keyring.gpg ]] && \
        keyring=(--keyring=/usr/share/keyrings/debian-archive-keyring.gpg)
    debootstrap --arch=amd64 --variant=minbase "${keyring[@]}" "${extra[@]}" \
        "$SUITE" "$ROOTFS" "$MIRROR"
}

configure_apt() {
    local comps="main"
    [[ $WITH_FIRMWARE == 1 ]] && comps="main non-free-firmware"
    rm -f "$ROOTFS/etc/apt/sources.list.d/debian.sources"
    cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE $comps
deb $MIRROR ${SUITE}-updates $comps
deb $SECURITY_MIRROR ${SUITE}-security $comps
EOF
    cat > "$ROOTFS/etc/apt/apt.conf.d/99-asm-os" <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
EOF
    if [[ $KEEP_DOCS != 1 ]]; then
        cat > "$ROOTFS/etc/dpkg/dpkg.cfg.d/01-asm-slim" <<'EOF'
# ASM OS: keep the image small. License files are always preserved.
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/groff/*
path-exclude=/usr/share/lintian/*
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/en*/*
path-include=/usr/share/locale/locale.alias
EOF
    fi
}

setup_dns() {
    local src=/etc/resolv.conf
    if grep -qE '^nameserver[[:space:]]+127\.' "$src" 2>/dev/null && [[ -s /run/systemd/resolve/resolv.conf ]]; then
        src=/run/systemd/resolve/resolv.conf
    fi
    rm -f "$ROOTFS/etc/resolv.conf"
    if grep -qE '^nameserver[[:space:]]+127\.' "$src" 2>/dev/null || [[ ! -s $src ]]; then
        printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$ROOTFS/etc/resolv.conf"
    else
        cp "$src" "$ROOTFS/etc/resolv.conf"
    fi
}

policy_rc_block() {   # stop package postinst scripts from starting daemons in the chroot
    printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
    chmod 0755 "$ROOTFS/usr/sbin/policy-rc.d"
}

apply_overlay() {
    log "Applying overlay (configs, theme, scripts)"
    cp -a --no-preserve=ownership "$PROJECT_DIR/overlay/." "$ROOTFS/"
    chmod 0755 "$ROOTFS"/usr/local/bin/* "$ROOTFS"/usr/local/sbin/* \
               "$ROOTFS/etc/skel/.config/openbox/autostart"
    if [[ $WITH_KICAD != 1 ]]; then
        sed -i '/ASM_KICAD/d' "$ROOTFS/etc/skel/.config/openbox/menu.xml"
    fi
    if [[ $WITH_WIRESHARK == 1 ]]; then
        sed -i 's|<!-- ASM_WIRESHARK ||; s| ASM_WIRESHARK -->||' "$ROOTFS/etc/skel/.config/openbox/menu.xml"
    fi
}

generate_branding() {
    log "Generating ASM Industries branding assets"
    bash "$PROJECT_DIR/tools/gen-branding.sh" "$BRAND_DIR" "$ASM_VERSION"
}

install_branding() {
    install -Dm0644 "$BRAND_DIR/wallpaper.png" "$ROOTFS/usr/share/backgrounds/asm-os/wallpaper.png"
    install -Dm0644 "$BRAND_DIR/logo.png"      "$ROOTFS/usr/share/plymouth/themes/asm/logo.png"
    install -Dm0644 "$BRAND_DIR/bar.png"       "$ROOTFS/usr/share/plymouth/themes/asm/bar.png"
    install -Dm0644 "$BRAND_DIR/icon.png"      "$ROOTFS/usr/share/pixmaps/asm-os-logo.png"
}

install_arduino_cli() {
    log "Fetching Arduino CLI"
    local tmp="$WORKDIR/arduino-cli"
    rm -rf "$tmp"; mkdir -p "$tmp"
    if ! curl -fsSL --retry 3 -o "$tmp/ac.tgz" "$ARDUINO_CLI_URL"; then
        warn "Could not download Arduino CLI from $ARDUINO_CLI_URL - continuing without it."
        return 0
    fi
    if [[ -n $ARDUINO_CLI_SHA256 ]]; then
        echo "$ARDUINO_CLI_SHA256  $tmp/ac.tgz" | sha256sum -c - || die "Arduino CLI checksum mismatch"
    fi
    tar -xzf "$tmp/ac.tgz" -C "$tmp" arduino-cli
    install -m0755 "$tmp/arduino-cli" "$ROOTFS/usr/local/bin/arduino-cli"
}

stage_rootfs() {
    log "=== Stage 1/2: root filesystem (Debian $SUITE) ==="
    generate_branding
    bootstrap
    mount_chroot
    configure_apt
    setup_dns
    policy_rc_block

    parse_packages "$ROOTFS/root/pkgs.required" "$ROOTFS/root/pkgs.optional"
    install -m0755 "$PROJECT_DIR/chroot/setup.sh" "$ROOTFS/root/asm-setup.sh"

    log "Installing packages (this is the long step)"
    chroot_run /root/asm-setup.sh packages

    apply_overlay
    install_branding
    install_arduino_cli

    log "Finalizing image (branding, services, initramfs)"
    chroot_run env ASM_VERSION="$ASM_VERSION" SUITE="$SUITE" ASM_HOME_URL="$ASM_HOME_URL" \
        WITH_PLYMOUTH="$WITH_PLYMOUTH" /root/asm-setup.sh finalize

    rm -f "$ROOTFS/usr/sbin/policy-rc.d" "$ROOTFS/root/asm-setup.sh" \
          "$ROOTFS/root/pkgs.required" "$ROOTFS/root/pkgs.optional"
    : > "$ROOTFS/etc/resolv.conf"
    umount_chroot
    log "Root filesystem ready: $(du -sh "$ROOTFS" | cut -f1) uncompressed"
}

# -------------------------------------------------------------- Stage: ISO
render_template() {
    sed -e "s|@CMDLINE@|${KERNEL_CMDLINE}|g" -e "s|@VERSION@|${ASM_VERSION}|g" "$1" > "$2"
}

stage_iso() {
    log "=== Stage 2/2: bootable ISO ==="
    [[ -x "$ROOTFS/usr/bin/apt-get" ]] || die "No rootfs found - run './build.sh rootfs' first."
    [[ -f "$BRAND_DIR/bootsplash.png" ]] || generate_branding

    rm -rf "$ISO_DIR"
    mkdir -p "$ISO_DIR"/{live,isolinux,boot/grub,EFI/boot} "$OUTDIR"

    local kernel initrd
    kernel=$(ls -1 "$ROOTFS"/boot/vmlinuz-*    2>/dev/null | sort -V | tail -n1 || true)
    initrd=$(ls -1 "$ROOTFS"/boot/initrd.img-* 2>/dev/null | sort -V | tail -n1 || true)
    [[ -f $kernel && -f $initrd ]] || die "Kernel/initrd missing in $ROOTFS/boot"
    log "Kernel: $(basename "$kernel")"
    cp "$kernel" "$ISO_DIR/live/vmlinuz"
    cp "$initrd" "$ISO_DIR/live/initrd.img"

    # Kernel + initrd live outside the squashfs (saves ~100 MB of duplicate data).
    ls -1 "$ROOTFS"/boot/vmlinuz-* "$ROOTFS"/boot/initrd.img-* | sed "s|^$ROOTFS/||" > "$WORKDIR/squashfs-exclude.txt"
    local -a comp
    if [[ $SQUASHFS_COMP == xz ]]; then comp=(-comp xz -Xbcj x86 -b 1M)
    else                                comp=(-comp zstd -Xcompression-level 19 -b 256K)
    fi
    log "mksquashfs ($SQUASHFS_COMP) - takes a few minutes"
    mksquashfs "$ROOTFS" "$ISO_DIR/live/filesystem.squashfs" -noappend -quiet \
        -ef "$WORKDIR/squashfs-exclude.txt" "${comp[@]}"

    # --- BIOS: ISOLINUX ----------------------------------------------------
    cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
    cp /usr/lib/syslinux/modules/bios/{ldlinux.c32,libcom32.c32,libutil.c32,vesamenu.c32,menu.c32} "$ISO_DIR/isolinux/"
    cp "$BRAND_DIR/bootsplash.png" "$ISO_DIR/isolinux/bootsplash.png"
    render_template "$PROJECT_DIR/boot/isolinux.cfg.in" "$ISO_DIR/isolinux/isolinux.cfg"

    # --- UEFI: standalone GRUB inside a FAT image ---------------------------
    cp "$BRAND_DIR/bootsplash.png" "$ISO_DIR/boot/grub/bootsplash.png"
    cp /usr/share/grub/unicode.pf2 "$ISO_DIR/boot/grub/unicode.pf2"
    render_template "$PROJECT_DIR/boot/grub.cfg.in" "$ISO_DIR/boot/grub/grub.cfg"
    : > "$ISO_DIR/ASM_OS_LIVE"      # marker file GRUB searches for

    cat > "$WORKDIR/grub-embed.cfg" <<'EOF'
search --no-floppy --set=root --file /ASM_OS_LIVE
configfile /boot/grub/grub.cfg
EOF
    grub-mkstandalone --format=x86_64-efi --output="$WORKDIR/bootx64.efi" \
        --locales="" --fonts="" \
        --modules="part_gpt part_msdos fat iso9660 normal linux configfile search search_fs_file echo test all_video gfxterm font png" \
        "boot/grub/grub.cfg=$WORKDIR/grub-embed.cfg"
    cp "$WORKDIR/bootx64.efi" "$ISO_DIR/EFI/boot/bootx64.efi"

    local efi_mb=$(( $(stat -c %s "$WORKDIR/bootx64.efi") / 1048576 + 4 ))
    dd if=/dev/zero of="$ISO_DIR/boot/grub/efi.img" bs=1M count="$efi_mb" status=none
    mkfs.vfat -n ASM_EFI "$ISO_DIR/boot/grub/efi.img" >/dev/null
    mmd   -i "$ISO_DIR/boot/grub/efi.img" ::/EFI ::/EFI/BOOT
    mcopy -i "$ISO_DIR/boot/grub/efi.img" "$WORKDIR/bootx64.efi" ::/EFI/BOOT/BOOTX64.EFI

    # --- Assemble hybrid ISO (BIOS El Torito + UEFI El Torito + GPT/MBR) ----
    log "xorriso -> $ISO_PATH"
    rm -f "$ISO_PATH"
    xorriso -as mkisofs \
        -iso-level 3 -full-iso9660-filenames \
        -volid "ASM_OS" -publisher "ASM Industries" -appid "ASM OS $ASM_VERSION" \
        -joliet -joliet-long -rational-rock \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -eltorito-boot isolinux/isolinux.bin \
        -eltorito-catalog isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat \
        -output "$ISO_PATH" "$ISO_DIR"

    ( cd "$OUTDIR" && sha256sum "$ISO_NAME" > "$ISO_NAME.sha256" )
    log "Done: $ISO_PATH  ($(du -h "$ISO_PATH" | cut -f1))"
    log "SHA-256: $(cut -d' ' -f1 "$ISO_PATH.sha256")"
}

# ---------------------------------------------------------------------- Main
usage() { sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
    local cmd="${1:-all}"
    case "$cmd" in
        -h|--help|help) usage; return 0 ;;
        clean)  [[ $EUID -eq 0 ]] || die "Run as root"; umount_chroot; rm -rf "$WORKDIR" "$OUTDIR"; log "Cleaned."; return 0 ;;
    esac
    trap cleanup EXIT
    preflight
    case "$cmd" in
        all)    stage_rootfs; stage_iso ;;
        rootfs) stage_rootfs ;;
        iso)    stage_iso ;;
        shell)  bootstrap; mount_chroot; setup_dns; chroot_run /bin/bash -l ;;
        *)      die "Unknown command '$cmd' (try --help)" ;;
    esac
}

# Allow `source build.sh` for testing individual functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
