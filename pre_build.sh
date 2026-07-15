#!/usr/bin/env bash
# pre_build.sh
# =================================================================
# DKMS Pre-Build Hook — zen-kernel Source Fetcher
# Lenovo Yoga Pro 9 16IMH9 (snd-hda-codec-alc269-fix)
#
# Copyright (c) 2026 Rámon van Raaij
# License: BSD 3-Clause
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
# 3. Applies the patch series to alc269.c (yoga9-16imh9.patch +
#    yoga9-16imh9-38d5.patch), skipping any patch whose quirk is already
#    present in the source (e.g. after the fix reaches zen via stable backport).
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
readonly ZEN_REPO="https://github.com/zen-kernel/zen-kernel.git"

# Patches are applied in this order. The base patch is the upstream-accepted
# fix for codec SSID 0x38d6 (commit 56722cfb in tiwai/sound for-linus). The
# 38d5 patch is a follow-up adding the same fixup for the variant SSID
# (reported via GitHub issue #1) and is not yet upstream.
#
# Invariant: each entry must add exactly one HDA_CODEC_QUIRK line and nothing
# else functional. The skip-if-already-present logic in apply_patches keys off
# those quirk lines; a patch that also carried other edits would be skipped
# wholesale (dropping the other edits) once its quirk landed upstream.
readonly PATCH_FILES=(
    "${SCRIPT_DIR}/yoga9-16imh9.patch"
    "${SCRIPT_DIR}/yoga9-16imh9-38d5.patch"
)

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

# quirk_already_present: returns 0 if every HDA_CODEC_QUIRK line that the given
# patch would add is already present in the fetched alc269.c.
#
# This lets apply_patches skip a patch whose quirk has since been merged
# upstream - e.g. once the codec SSID quirk reaches zen 7.0.x via the stable
# backport, the fetched source already contains it and the patch would no
# longer apply. The check matches on the functional HDA_CODEC_QUIRK line only,
# so it tolerates cosmetic differences such as a reworded surrounding comment.
quirk_already_present() {
    local workdir="${1}"
    local patch_file="${2}"
    local target="${workdir}/sound/hda/codecs/realtek/alc269.c"
    [[ -f "${target}" ]] || return 1

    # Whitespace-squeezed view of the target for tolerant substring matching
    # (newlines collapse to spaces, so each quirk line is matched in isolation).
    local squeezed_target
    squeezed_target=$(tr -s '[:space:]' ' ' < "${target}")

    local line norm found=0
    while IFS= read -r line; do
        found=1
        norm=$(printf '%s' "${line}" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
        case "${squeezed_target}" in
            *"${norm}"*) ;;   # this quirk line is present; keep checking
            *) return 1 ;;    # at least one quirk line missing -> not fully present
        esac
    done < <(grep -E '^\+[[:space:]]*HDA_CODEC_QUIRK' "${patch_file}" | sed 's/^\+//')

    # Only report "already present" when the patch actually adds quirk lines.
    [[ "${found}" -eq 1 ]]
}

# Apply the patch series to the fetched alc269.c, in declared order. A patch
# whose quirk is already in the source (merged upstream) is skipped rather than
# failing the build; a genuine context mismatch still aborts.
#
# GNU patch is assumed (DKMS on Arch); -N makes an already-applied patch a
# silent non-interactive skip, and -F0 forbids fuzz so a genuinely drifted hunk
# fails the dry-run and routes to the abort branch instead of applying offset.
apply_patches() {
    local workdir="${1}"
    local patch_file name
    for patch_file in "${PATCH_FILES[@]}"; do
        name=$(basename "${patch_file}")
        if patch -p1 -N -F0 --dry-run -d "${workdir}" < "${patch_file}" >/dev/null 2>&1; then
            log "Applying ${name} ..."
            patch -p1 -N -F0 -d "${workdir}" < "${patch_file}"
        elif quirk_already_present "${workdir}" "${patch_file}"; then
            log "Skipping ${name} - quirk already present in source (merged upstream)."
        else
            err "Patch ${name} did not apply and its quirk is absent from the source."
            err "The upstream quirk table likely changed; update the patch hunk context."
            exit 1
        fi
    done
    log "Patch series processed."
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
apply_patches "${WORKDIR}"
populate_dkms_tree "${WORKDIR}"

log "Sources ready."
