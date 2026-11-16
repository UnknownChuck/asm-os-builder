#!/bin/bash
# ============================================================================
#  ASM OS - in-chroot provisioning (copied into the rootfs by build.sh)
#     asm-setup.sh packages   install the package set
#     asm-setup.sh finalize   branding, services, plymouth, initramfs, cleanup
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

    log "Installing ${#OPT[@]} optional packages (one by one)"
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
   Lightweight engineering workstation. Type 'asm-sysinfo' for a memory/boot report.

EOF

    echo asm-os > /etc/hostname
    printf '127.0.0.1\tlocalhost\n127.0.1.1\tasm-os\n::1\tlocalhost ip6-localhost ip6-loopback\n' > /etc/hosts

    log "Locale"
    sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
    locale-gen
    update-locale LANG=en_US.UTF-8

    log "Permissions"
    chmod 0755 /usr/local/bin/* /usr/local/sbin/* /etc/skel/.config/openbox/autostart 2>/dev/null || true

    log "Services: enable the essentials, disable/mask the rest"
    local u
    for u in NetworkManager asm-zram earlyoom lightdm; do
        systemctl enable "$u.service" || warn "could not enable $u.service"
    done
    systemctl set-default graphical.target || true
    echo /usr/sbin/lightdm > /etc/X11/default-display-manager

    # Not needed on a fast-booting desktop; sshd is opt-in (known live password!).
    systemctl disable ssh.service NetworkManager-wait-online.service 2>/dev/null || true
    systemctl mask apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service \
                   man-db.timer e2scrub_all.timer dpkg-db-backup.timer \
                   ModemManager.service bluetooth.service cups.service avahi-daemon.service 2>/dev/null || true

    log "Default applications"
    update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/local/bin/asm-browser 200 || true
    update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/local/bin/asm-browser 200 || true
    # The session autostart script starts these itself; avoid double launches.
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
    rm -f /etc/ssh/ssh_host_*                 # live-config regenerates them at boot
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
