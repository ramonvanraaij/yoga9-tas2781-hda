#!/usr/bin/env bash
# pre_build.sh
# =================================================================
# DKMS Pre-Build Hook — zen-kernel Source Fetcher
# Lenovo Yoga Pro 9 16IMH9 (snd-hda-codec-alc269-fix)
#
# Copyright (c) 2026 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script is called by DKMS via PRE_BUILD="pre_build.sh" in dkms.conf
# before compiling the snd-hda-codec-alc269 module. It fetches alc269.c
# and all required headers from zen-kernel at the branch matching the
# target kernel, then applies the Yoga Pro 9 16IMH9 codec quirk patch.
#
# Running at each DKMS build — including automatic kernel-upgrade rebuilds —
# ensures the correct upstream source is used for every kernel version.
#
# It performs the following actions:
# 1. Derives the zen-kernel branch from the target kernel version
#    ($kernelver set by DKMS, e.g. "7.0.2-zen1-1-zen" → "7.0/main",
#    "7.1.3-zen2-1-zen" → "7.1/main").
# 2. Sparse-clones the zen-kernel repository to fetch only the required
#    source files (alc269.c, realtek.h, helpers, and common headers).
# 3. Applies yoga9-16imh9.patch to alc269.c.
# 4. Places all files in the DKMS source tree for compilation.
#
# Usage:
#   Called automatically by DKMS. Can be invoked manually for testing:
#   kernelver=$(uname -r) bash pre_build.sh
# =================================================================

set -o errexit -o nounset -o pipefail

# --- Configuration ---

# DKMS sets $kernelver to the target kernel; fall back to the running kernel
# when invoked manually.
KVER="${kernelver:-$(uname -r)}"

# When called by DKMS the working directory is the DKMS source tree
# (/usr/src/snd-hda-codec-alc269-fix-1.0/). BASH_SOURCE resolves there.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PATCH_FILE="${SCRIPT_DIR}/yoga9-16imh9.patch"
readonly ZEN_REPO="https://github.com/zen-kernel/zen-kernel.git"

# Source files to fetch from the zen-kernel tree.
readonly ZEN_PATHS=(
    "sound/hda/codecs/realtek/alc269.c"
    "sound/hda/codecs/realtek/realtek.h"
    "sound/hda/codecs/generic.h"
    "sound/hda/codecs/side-codecs/hda_component.h"
    "sound/hda/codecs/helpers/thinkpad.c"
    "sound/hda/codecs/helpers/ideapad_hotkey_led.c"
    "sound/hda/codecs/helpers/hp_x360.c"
    "sound/hda/codecs/helpers/ideapad_s740.c"
    "sound/hda/common/hda_local.h"
    "sound/hda/common/hda_auto_parser.h"
    "sound/hda/common/hda_beep.h"
    "sound/hda/common/hda_jack.h"
)

# --- Logging ---

log() { echo "[pre_build] $1"; }
err() { echo "[pre_build] ERROR: $1" >&2; }

# --- Core Functions ---

# Derive the zen-kernel branch from a kernel version string.
# e.g. "7.0.2-zen1-1-zen" → "7.0/main"
# e.g. "7.1.3-zen2-1-zen" → "7.1/main"
get_zen_branch() {
    local kver="${1}"
    local major_minor
    major_minor="$(echo "${kver}" | sed 's/^\([0-9]*\.[0-9]*\).*/\1/')"
    if [[ -z "${major_minor}" ]]; then
        err "Cannot parse kernel version '${kver}' to derive zen branch."
        exit 1
    fi
    echo "${major_minor}/main"
}

# Sparse-clone only the required source files from zen-kernel.
fetch_sources() {
    local branch="${1}"
    local workdir="${2}"

    log "Fetching sources from zen-kernel branch ${branch} ..."
    git -C "${workdir}" init -q
    git -C "${workdir}" remote add origin "${ZEN_REPO}"
    git -C "${workdir}" sparse-checkout init --cone
    git -C "${workdir}" sparse-checkout set \
        sound/hda/codecs/realtek \
        sound/hda/codecs/helpers \
        sound/hda/codecs/side-codecs \
        sound/hda/common
    git -C "${workdir}" fetch --depth=1 origin "${branch}"
    git -C "${workdir}" checkout FETCH_HEAD -- "${ZEN_PATHS[@]}"
    log "Fetched (branch ${branch}, commit $(git -C "${workdir}" rev-parse --short FETCH_HEAD))."
}

# Apply the patch to the fetched alc269.c.
apply_patch() {
    local workdir="${1}"
    log "Applying patch ..."
    patch -p1 -d "${workdir}" < "${PATCH_FILE}"
    log "Patch applied."
}

# Copy source files into the DKMS source tree with the layout the Makefile expects.
#
#   codecs/realtek/alc269.c       ← compilation unit
#   codecs/realtek/realtek.h
#   codecs/generic.h              ← realtek.h: #include "../generic.h"
#   codecs/side-codecs/hda_component.h  ← realtek.h: #include "../side-codecs/..."
#   codecs/helpers/*.c            ← alc269.c: #include "../helpers/..."
#   hda_common/*.h                ← on ccflags; realtek.h: #include "hda_local.h" etc.
populate_dkms_tree() {
    local workdir="${1}"

    mkdir -p "${SCRIPT_DIR}/codecs/realtek"
    mkdir -p "${SCRIPT_DIR}/codecs/side-codecs"
    mkdir -p "${SCRIPT_DIR}/codecs/helpers"
    mkdir -p "${SCRIPT_DIR}/hda_common"

    cp "${workdir}/sound/hda/codecs/realtek/alc269.c"             "${SCRIPT_DIR}/codecs/realtek/"
    cp "${workdir}/sound/hda/codecs/realtek/realtek.h"            "${SCRIPT_DIR}/codecs/realtek/"
    cp "${workdir}/sound/hda/codecs/generic.h"                    "${SCRIPT_DIR}/codecs/"
    cp "${workdir}/sound/hda/codecs/side-codecs/hda_component.h"  "${SCRIPT_DIR}/codecs/side-codecs/"
    cp "${workdir}/sound/hda/codecs/helpers/thinkpad.c"           "${SCRIPT_DIR}/codecs/helpers/"
    cp "${workdir}/sound/hda/codecs/helpers/ideapad_hotkey_led.c" "${SCRIPT_DIR}/codecs/helpers/"
    cp "${workdir}/sound/hda/codecs/helpers/hp_x360.c"            "${SCRIPT_DIR}/codecs/helpers/"
    cp "${workdir}/sound/hda/codecs/helpers/ideapad_s740.c"       "${SCRIPT_DIR}/codecs/helpers/"
    cp "${workdir}/sound/hda/common/hda_local.h"                  "${SCRIPT_DIR}/hda_common/"
    cp "${workdir}/sound/hda/common/hda_auto_parser.h"            "${SCRIPT_DIR}/hda_common/"
    cp "${workdir}/sound/hda/common/hda_beep.h"                   "${SCRIPT_DIR}/hda_common/"
    cp "${workdir}/sound/hda/common/hda_jack.h"                   "${SCRIPT_DIR}/hda_common/"
}

# --- Main ---

log "Target kernel: ${KVER}"

ZEN_BRANCH="$(get_zen_branch "${KVER}")"
log "zen-kernel branch: ${ZEN_BRANCH}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

fetch_sources "${ZEN_BRANCH}" "${WORKDIR}"
apply_patch "${WORKDIR}"
populate_dkms_tree "${WORKDIR}"

log "Sources ready."
