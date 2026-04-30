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
    log "Would copy Makefile, dkms.conf, pre_build.sh, yoga9-16imh9.patch"
    log "Would fetch zen-kernel sources from branch ${local_branch} during build"
    log "Would run: sudo dkms add/build/install ${MODULE_NAME}/${MODULE_VERSION}"
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
sudo cp "${SCRIPT_DIR}/Makefile"            "${DKMS_SRC}/"
sudo cp "${SCRIPT_DIR}/dkms.conf"           "${DKMS_SRC}/"
sudo cp "${SCRIPT_DIR}/pre_build.sh"        "${DKMS_SRC}/"
sudo cp "${SCRIPT_DIR}/yoga9-16imh9.patch"  "${DKMS_SRC}/"
sudo chmod +x "${DKMS_SRC}/pre_build.sh"

log "Registering DKMS module ..."
sudo dkms add "${MODULE_NAME}/${MODULE_VERSION}"

log "Building DKMS module (fetching zen-kernel sources, this may take a minute) ..."
sudo dkms build "${MODULE_NAME}/${MODULE_VERSION}"

log "Installing DKMS module ..."
sudo dkms install "${MODULE_NAME}/${MODULE_VERSION}"

log ""
log "Done! Reboot to load the patched module."
log "After reboot, verify with:"
log "  dmesg | grep -i 'tas2781\|alc287\|38d6'"
log "  aplay -l    (should show speakers)"
