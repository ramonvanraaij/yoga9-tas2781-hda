#!/usr/bin/env bash
# build.sh
# =================================================================
# TAS2781 HDA Codec Fix — DKMS Module Installer
# Lenovo Yoga Pro 9 16IMH9
#
# Copyright (c) 2026 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script installs a patched snd-hda-codec-alc269 kernel module as a
# DKMS module. The patch adds a HDA_CODEC_QUIRK entry for the TI TAS2781
# smart amplifiers on the Lenovo Yoga Pro 9 16IMH9 so the correct
# ALC287_FIXUP_TAS2781_I2C fixup fires at boot.
#
# Source files are fetched from zen-kernel at build time by pre_build.sh,
# which DKMS calls automatically before each compile — including automatic
# kernel-upgrade rebuilds. This ensures the correct alc269.c is used for
# every kernel version without manual intervention.
#
# It performs the following actions:
# 1. Validates prerequisites (dkms, git, zstd, sudo, kernel headers).
# 2. Creates the DKMS source tree at /usr/src/snd-hda-codec-alc269-fix-1.0/
#    and populates it with the build scaffolding (Makefile, dkms.conf,
#    pre_build.sh, and the patch file).
# 3. Registers, builds, and installs the DKMS module.
#
# Usage:
#   ./build.sh [--uninstall] [--dry-run]
#
#   --uninstall   Remove the DKMS module and restore the original.
#   --dry-run     Show what would be done without making changes.
#
# **Note:**
#   Run as a regular user with sudo access. The script will invoke sudo
#   where required. Internet access is required: pre_build.sh fetches
#   zen-kernel sources from GitHub during the build step.
#   A reboot is needed after installation for the new module to take
#   effect (the running audio subsystem holds the module).
# =================================================================

set -o errexit -o nounset -o pipefail

# --- Configuration ---

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MODULE_NAME="snd-hda-codec-alc269-fix"
readonly MODULE_VERSION="1.0"
readonly DKMS_SRC="/usr/src/${MODULE_NAME}-${MODULE_VERSION}"

# --- Logging ---

log()  { echo -e "\033[1;34m[+]\033[0m $1"; }
warn() { echo -e "\033[1;33m[!]\033[0m $1"; }
err()  { echo -e "\033[1;31m[x]\033[0m $1" >&2; }

# --- Helper Functions ---

# Print usage and exit.
usage() {
    cat >&2 <<'EOF'
Usage: ./build.sh [--uninstall] [--dry-run]

  --uninstall   Remove the DKMS module and restore the original.
  --dry-run     Show what would be done without making changes.
EOF
    exit 1
}

# Check that required tools are installed and kernel headers are present.
check_prereqs() {
    local kver="${1}"
    local missing=()
    for cmd in dkms git zstd sudo patch; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing required tools: ${missing[*]}"
        err "Install with: sudo pacman -S ${missing[*]}"
        exit 1
    fi

    if [[ ! -d "/lib/modules/${kver}/build" ]]; then
        err "Kernel headers not found at /lib/modules/${kver}/build"
        err "Install with: sudo pacman -S linux-zen-headers"
        exit 1
    fi

    log "Prerequisites OK."
}

# --- Main ---

DRY_RUN=""
UNINSTALL=0

for arg in "$@"; do
    case "${arg}" in
        --uninstall) UNINSTALL=1 ;;
        --dry-run)   DRY_RUN=1 ;;
        --help|-h)   usage ;;
        *) err "Unknown option: ${arg}"; usage ;;
    esac
done

# Must run as a regular user. The script invokes sudo internally where needed;
# running it under sudo would resolve $HOME / $USER to root and silently install
# the user service into /root/.config/systemd/user/, where it would never run.
if [[ "${EUID}" -eq 0 ]]; then
    err "Run as your regular user, not root."
    err "The script invokes sudo for system-level steps; running under sudo would"
    err "install the user service into /root/.config/systemd/user/."
    exit 1
fi

KVER="$(uname -r)"

# --- Uninstall path ---
if [[ "${UNINSTALL}" -eq 1 ]]; then
    log "Removing DKMS module ${MODULE_NAME}/${MODULE_VERSION} ..."
    if sudo dkms status 2>/dev/null | grep -q "^${MODULE_NAME}/${MODULE_VERSION}"; then
        sudo dkms remove "${MODULE_NAME}/${MODULE_VERSION}" --all
        sudo rm -rf "${DKMS_SRC}"
        log "Uninstalled. Reboot to restore the original module."
    else
        warn "Module not found in DKMS; nothing to remove."
    fi

    log "Removing boot firmware reload service ..."
    sudo systemctl disable --now tas2781-firmware-reload.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/tas2781-firmware-reload.service
    sudo rm -f /usr/lib/systemd/system-sleep/tas2781-firmware-resume
    sudo systemctl daemon-reload

    log "Removing runtime speaker fix ..."
    systemctl --user disable --now tas2781-amp-fix.service 2>/dev/null || true
    rm -f "${HOME}/.config/systemd/user/tas2781-amp-fix.service"
    systemctl --user daemon-reload 2>/dev/null || true
    sudo rm -f /usr/local/bin/2pa-byps.sh
    sudo rm -f /etc/sudoers.d/tas2781-speakers
    sudo rm -f /etc/udev/rules.d/99-tas2781-i2c-ctrl.rules
    sudo udevadm control --reload-rules
    sudo rm -f /etc/modprobe.d/tas2781-blacklist.conf
    sudo mkinitcpio -P
    exit 0
fi

# --- Install path ---
log "Running kernel: ${KVER}"

if [[ "${KVER}" != *zen* ]]; then
    warn "Kernel '${KVER}' does not appear to be a zen kernel."
    warn "This fix targets the zen-kernel source tree. Proceed at your own risk."
fi

if [[ -n "${DRY_RUN}" ]]; then
    local_branch="$(echo "${KVER}" | sed 's/^\([0-9]*\.[0-9]*\).*/\1/')/main"
    log "DRY RUN — no changes will be made."
    log "Would create DKMS tree at ${DKMS_SRC}"
    log "Would copy Makefile, dkms.conf, pre_build.sh, yoga9-16imh9.patch, yoga9-16imh9-38d5.patch"
    log "Would fetch zen-kernel sources from branch ${local_branch} during build"
    log "Would run: sudo dkms add/build/install ${MODULE_NAME}/${MODULE_VERSION}"
    log "Would install systemd/tas2781-firmware-reload.service → /etc/systemd/system/"
    log "Would install systemd/system-sleep/tas2781-firmware-resume → /usr/lib/systemd/system-sleep/"
    log "Would run: sudo systemctl enable --now tas2781-firmware-reload.service"
    log "Would install 2pa-byps.sh → /usr/local/bin/"
    log "Would install sudoers fragment → /etc/sudoers.d/tas2781-speakers"
    log "Would install udev rule → /etc/udev/rules.d/99-tas2781-i2c-ctrl.rules"
    log "Would install systemd/user/tas2781-amp-fix.service → ${HOME}/.config/systemd/user/"
    log "Would run: systemctl --user enable --now tas2781-amp-fix.service"
    exit 0
fi

check_prereqs "${KVER}"

# If already fully installed for this kernel, nothing to do.
if sudo dkms status 2>/dev/null | grep -q "^${MODULE_NAME}/${MODULE_VERSION}.*${KVER}.*installed"; then
    warn "Module ${MODULE_NAME}/${MODULE_VERSION} is already installed for ${KVER}."
    warn "Run with --uninstall first if you want to reinstall."
    exit 0
fi

# Clear any partial registration (e.g. added but not built) to start clean.
if sudo dkms status 2>/dev/null | grep -q "^${MODULE_NAME}/${MODULE_VERSION}"; then
    warn "Removing stale DKMS registration before reinstalling ..."
    sudo dkms remove "${MODULE_NAME}/${MODULE_VERSION}" --all 2>/dev/null || true
    sudo rm -rf "${DKMS_SRC}"
fi

log "Creating DKMS source tree at ${DKMS_SRC} ..."
sudo mkdir -p "${DKMS_SRC}"
sudo cp "${SCRIPT_DIR}/Makefile"                  "${DKMS_SRC}/"
sudo cp "${SCRIPT_DIR}/dkms.conf"                 "${DKMS_SRC}/"
sudo cp "${SCRIPT_DIR}/pre_build.sh"              "${DKMS_SRC}/"
sudo cp "${SCRIPT_DIR}/yoga9-16imh9.patch"        "${DKMS_SRC}/"
sudo cp "${SCRIPT_DIR}/yoga9-16imh9-38d5.patch"   "${DKMS_SRC}/"
sudo chmod +x "${DKMS_SRC}/pre_build.sh"

log "Registering DKMS module ..."
sudo dkms add "${MODULE_NAME}/${MODULE_VERSION}"

log "Building DKMS module (fetching zen-kernel sources, this may take a minute) ..."
sudo dkms build "${MODULE_NAME}/${MODULE_VERSION}"

log "Installing DKMS module ..."
sudo dkms install "${MODULE_NAME}/${MODULE_VERSION}"

log "Installing boot firmware reload service ..."
sudo install -m 644 "${SCRIPT_DIR}/systemd/tas2781-firmware-reload.service" \
    /etc/systemd/system/tas2781-firmware-reload.service
sudo install -m 755 "${SCRIPT_DIR}/systemd/system-sleep/tas2781-firmware-resume" \
    /usr/lib/systemd/system-sleep/tas2781-firmware-resume
sudo systemctl daemon-reload
sudo systemctl enable --now tas2781-firmware-reload.service

log "Installing runtime speaker fix (2pa-byps.sh) ..."
sudo install -m 755 "${SCRIPT_DIR}/2pa-byps.sh" /usr/local/bin/2pa-byps.sh

log "Installing sudoers fragment for user service ..."
echo "${USER} ALL=(root) NOPASSWD: /usr/local/bin/2pa-byps.sh" \
    | sudo tee /etc/sudoers.d/tas2781-speakers > /dev/null
sudo chmod 440 /etc/sudoers.d/tas2781-speakers
sudo visudo -cf /etc/sudoers.d/tas2781-speakers

log "Installing udev rule to pin PCI I2C controller to always-on ..."
sudo tee /etc/udev/rules.d/99-tas2781-i2c-ctrl.rules > /dev/null <<'EOF'
# Keep the Intel DesignWare I2C controller that hosts the TAS2781 amplifiers
# always powered. It defaults to runtime-PM=auto; when the display goes off
# and the system enters deep idle the controller can enter D3cold, which cuts
# the I2C bus power rail and erases all TAS2781 register state.
ACTION=="add", SUBSYSTEM=="pci", ENV{PCI_SLOT_NAME}=="0000:00:15.2", \
    ATTR{power/control}="on"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=pci --attr-match=vendor=0x8086 \
    --attr-match=device=0x7e7a 2>/dev/null || true

log "Installing modprobe blacklist for snd_hda_scodec_tas2781_i2c ..."
sudo install -m 644 "${SCRIPT_DIR}/tas2781-blacklist.conf" \
    /etc/modprobe.d/tas2781-blacklist.conf

log "Rebuilding initramfs (blacklist must be baked in to take effect at boot) ..."
sudo mkinitcpio -P

log "Installing WirePlumber companion user service ..."
install -d -m 755 "${HOME}/.config/systemd/user"
install -m 644 "${SCRIPT_DIR}/systemd/user/tas2781-amp-fix.service" \
    "${HOME}/.config/systemd/user/tas2781-amp-fix.service"
systemctl --user daemon-reload
systemctl --user enable --now tas2781-amp-fix.service

log ""
log "Done! Reboot to load the patched module with the firmware fix."
log "After reboot, verify with:"
log "  dmesg | grep -i 'tas2781\|alc287\|38d6'"
log "  aplay -l    (should show speakers)"
log ""
log "Optional — KDE Plasma autostart (Speaker Force Firmware Load):"
log "  sudo install -m 755 ${SCRIPT_DIR}/autostart/tas2781-force-load.sh /usr/local/bin/"
log "  cp ${SCRIPT_DIR}/autostart/tas2781-force-load.desktop ~/.config/autostart/"
