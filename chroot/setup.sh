#!/bin/bash
# ============================================================================
#  ASM OS - in-chroot provisioning (Low-RAM 1.5GB Optimized | Live + Installable)
#     asm-setup.sh packages   install the package set
#     asm-setup.sh finalize   branding, user, zram, low-ram tuning, cleanup
# ============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C

log()  { printf '[chroot] %s\n' "$*"; }
warn() { printf '[chroot][warn] %s\n' "$*" >&2; }

APT=(apt-get -y --no-install-recommends
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# ---------------------------------------------------------------- packages --
phase_packages() {
    debconf-set-selections <<'EOF'
wireshark-common wireshark-common/install-setuid boolean true
locales locales/default_environment_locale select en_US.UTF-8
locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8
keyboard-configuration keyboard-configuration/xkb-keymap select us
tzdata tzdata/Areas select Etc
tzdata tzdata/Zones/Etc select UTC
EOF

    log "apt-get update"
    apt-get update

    local -a REQ OPT missing=()
    mapfile -t REQ < /root/pkgs.required
    mapfile -t OPT < /root/pkgs.optional

    # Ensure Live boot, Calamares GUI Installer, Bootloaders (BIOS+UEFI), and Low-RAM tools are included
    local -a EXTRA_PKGS=(
        live-boot
        live-config
        live-config-systemd
        calamares
        calamares-settings-debian
        grub-pc-bin
        grub-efi-amd64-bin
        efibootmgr
        dosfstools
        zstd
        earlyoom
    )
    local ep
    for ep in "${EXTRA_PKGS[@]}"; do
        if apt-cache show "$ep" >/dev/null 2>&1; then
            OPT+=("$ep")
        fi
    done

    # Fail early, with a readable list, if a required package name is wrong.
    local p
    for p in "${REQ[@]}"; do
        apt-cache show "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if ((${#missing[@]})); then
        warn "Required packages not found in the configured suite: ${missing[*]}"
        warn "Fix packages.list (names change between Debian releases) or make them optional with '?'."
        exit 1
    fi

    log "Installing ${#REQ[@]} required packages"
    "${APT[@]}" install "${REQ[@]}"

    log "Installing ${#OPT[@]} optional, installer & low-RAM packages"
    for p in "${OPT[@]}"; do
        if apt-cache show "$p" >/dev/null 2>&1; then
            "${APT[@]}" install "$p" || warn "optional package '$p' failed to install - skipped"
        else
            warn "optional package '$p' not available in this suite - skipped"
        fi
    done
    apt-get clean
}

# ---------------------------------------------------------------- finalize --
phase_finalize() {
    : "${ASM_VERSION:=1.0}" "${SUITE:=trixie}" "${ASM_HOME_URL:=https://asm-industries.example}"

    log "Branding: os-release, issue, motd, hostname"
    dpkg-divert --local --rename --divert /usr/lib/os-release.debian --add /usr/lib/os-release >/dev/null 2>&1 || true
    cat > /usr/lib/os-release <<EOF
PRETTY_NAME="ASM OS ${ASM_VERSION}"
NAME="ASM OS"
VERSION_ID="${ASM_VERSION}"
VERSION="${ASM_VERSION} (${SUITE} base)"
VERSION_CODENAME=${SUITE}
ID=asm-os
ID_LIKE=debian
HOME_URL="${ASM_HOME_URL}"
SUPPORT_URL="${ASM_HOME_URL}"
BUG_REPORT_URL="${ASM_HOME_URL}"
ANSI_COLOR="1;36"
LOGO=asm-os-logo
EOF
    ln -sf ../usr/lib/os-release /etc/os-release

    cat > /etc/issue <<EOF
ASM OS ${ASM_VERSION} - ASM Industries  \\n \\l

EOF
    cp /etc/issue /etc/issue.net
    cat > /etc/motd <<EOF

   ASM OS ${ASM_VERSION}  |  ASM Industries
   Lightweight Low-RAM Edition. Type 'asm-sysinfo' for a memory/boot report.

EOF

    echo asm-os > /etc/hostname
    printf '127.0.0.1\tlocalhost\n127.0.1.1\tasm-os\n::1\tlocalhost ip6-localhost ip6-loopback\n' > /etc/hosts

    log "Locale"
    sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
    locale-gen
    update-locale LANG=en_US.UTF-8

    log "User setup: creating default 'asm' user & autologin"
    if ! id asm >/dev/null 2>&1; then
        useradd -m -s /bin/bash -G sudo,audio,video,netdev,plugdev,users asm
    fi
    passwd -d asm
    echo "asm ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-asm-nopasswd
    chmod 0440 /etc/sudoers.d/90-asm-nopasswd

    # Live-config settings so live boot always creates/uses 'asm' cleanly
    mkdir -p /etc/live/config.conf.d
    cat > /etc/live/config.conf.d/10-asm-user.conf <<'EOF'
LIVE_USERNAME="asm"
LIVE_USER_FULLNAME="ASM OS User"
LIVE_USER_DEFAULT_GROUPS="audio cdrom dip floppy video plugdev netdev powerdev scanner bluetooth sudo"
EOF

    # LightDM autologin for 'asm'
    if [[ -d /etc/lightdm ]]; then
        mkdir -p /etc/lightdm/lightdm.conf.d
        cat > /etc/lightdm/lightdm.conf.d/50-asm-autologin.conf <<'EOF'
[Seat:*]
autologin-user=asm
autologin-user-timeout=0
user-session=openbox
EOF
    fi

    # TTY1 autologin fallback
    mkdir -p /etc/systemd/system/getty@tty1.service.d
    cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin asm --noclear %I $TERM
EOF

    log "Low-RAM (1.5GB) Kernel & Memory Optimization"
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-asm-lowram.conf <<'EOF'
vm.swappiness = 100
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.page-cluster = 0
EOF

    # Configure ZRAM service cleanly without systemd ordering cycles (150% of RAM with zstd)
    cat > /usr/local/sbin/asm-zram-setup <<'EOF'
#!/bin/bash
modprobe zram num_devices=1 2>/dev/null || exit 0
if [[ -b /dev/zram0 ]]; then
    swapoff /dev/zram0 2>/dev/null || true
    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    ZRAM_BYTES=$(( MEM_KB * 1024 * 3 / 2 ))
    echo "$ZRAM_BYTES" > /sys/block/zram0/disksize
    mkswap /dev/zram0 >/dev/null
    swapon -p 100 /dev/zram0
fi
EOF
    chmod 0755 /usr/local/sbin/asm-zram-setup

    cat > /etc/systemd/system/asm-zram.service <<'EOF'
[Unit]
Description=ASM OS ZRAM Compressed Swap (Low-RAM Boost)
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/asm-zram-setup

[Install]
WantedBy=multi-user.target
EOF

    # Tune earlyoom so the desktop never freezes when RAM gets full
    if [[ -f /etc/default/earlyoom ]]; then
        cat > /etc/default/earlyoom <<'EOF'
EARLYOOM_ARGS="-m 5 -s 10 -r 60 --avoid '(^|/)(init|systemd|Xorg|openbox|lightdm)$'"
EOF
    fi

    # Limit systemd journal size in RAM to 32MB max
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/00-lowram.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=32M
EOF

    log "Permissions & Skel"
    chmod 0755 /usr/local/bin/* /usr/local/sbin/* /etc/skel/.config/openbox/autostart 2>/dev/null || true
    if [[ -d /etc/skel ]]; then
        cp -rn /etc/skel/. /home/asm/ 2>/dev/null || true
        chown -R asm:asm /home/asm
    fi

    # Calamares Installer Desktop shortcut
    if command -v calamares >/dev/null 2>&1; then
        mkdir -p /home/asm/Desktop /etc/skel/Desktop
        if [[ -f /usr/share/applications/calamares.desktop ]]; then
            cp /usr/share/applications/calamares.desktop /home/asm/Desktop/
            cp /usr/share/applications/calamares.desktop /etc/skel/Desktop/
            sed -i 's/^Name=.*/Name=Install ASM OS/' /home/asm/Desktop/calamares.desktop /etc/skel/Desktop/calamares.desktop
            chmod +x /home/asm/Desktop/calamares.desktop /etc/skel/Desktop/calamares.desktop
            chown -R asm:asm /home/asm/Desktop
        fi
    fi

    log "Services: enable the essentials, disable/mask the rest"
    systemctl daemon-reload || true
    local u
    for u in NetworkManager asm-zram earlyoom lightdm; do
        systemctl enable "$u.service" || warn "could not enable $u.service"
    done
    systemctl set-default graphical.target || true
    echo /usr/sbin/lightdm > /etc/X11/default-display-manager

    # Disable heavy/unnecessary background services to save RAM on low-end PCs
    systemctl disable ssh.service NetworkManager-wait-online.service 2>/dev/null || true
    systemctl mask apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service \
                   man-db.timer e2scrub_all.timer dpkg-db-backup.timer \
                   ModemManager.service bluetooth.service cups.service avahi-daemon.service \
                   tracker-miner-fs-3.service 2>/dev/null || true

    log "Default applications"
    update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/local/bin/asm-browser 200 || true
    update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/local/bin/asm-browser 200 || true
    rm -f /etc/xdg/autostart/nm-applet.desktop /etc/xdg/autostart/lxpolkit.desktop
    update-desktop-database /usr/share/applications 2>/dev/null || true
    gtk-update-icon-cache -f -q /usr/share/icons/Papirus-Dark 2>/dev/null || true

    if [[ ${WITH_PLYMOUTH:-0} == 1 ]] && command -v plymouth-set-default-theme >/dev/null; then
        log "Plymouth theme: asm"
        plymouth-set-default-theme asm || warn "plymouth theme could not be set"
    fi

    log "Rebuilding initramfs (zstd, live-boot hooks)"
    update-initramfs -u -k all

    log "Cleaning the image"
    rm -f /etc/ssh/ssh_host_*
    : > /etc/machine-id
    rm -f /var/lib/dbus/machine-id
    ln -s /etc/machine-id /var/lib/dbus/machine-id
    apt-get clean
    rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /tmp/* /var/tmp/* /root/.cache /root/.bash_history
    find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
}

case "${1:-}" in
    packages) phase_packages ;;
    finalize) phase_finalize ;;
    *) echo "usage: $0 packages|finalize" >&2; exit 2 ;;
esac
