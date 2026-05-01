#!/usr/bin/env bash
# tas2781-force-load.sh
# =================================================================
# TAS2781 DSP Firmware Force-Load at KDE Session Start
#
# Copyright (c) 2026 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# Install at /usr/local/bin/tas2781-force-load.sh (executable) and add
# the companion .desktop file to ~/.config/autostart/ for KDE Plasma.
#
# This script polls for the TAS2781 "Speaker Force Firmware Load" ALSA
# control to appear on the sofhdadsp card, then sets it to trigger a
# synchronous DSP calibration data reload. The control is only registered
# after a successful firmware load, so its presence confirms the driver
# is ready. Running at KDE session start ensures PipeWire has settled
# before the control is touched.
#
# It performs the following actions:
# 1. Polls for the "Speaker Force Firmware Load" ALSA control (up to 30 s)
# 2. Sets the control to "on" to trigger a synchronous DSP firmware load
#
# Usage:
# Executed automatically via KDE autostart (~/.config/autostart/).
# =================================================================
set -o nounset -o pipefail

# --- Configuration ---
readonly CARD="sofhdadsp"
readonly CONTROL="Speaker Force Firmware Load"
readonly MAX_WAIT=30

# --- Main ---

# Poll until the TAS2781 ALSA control appears. The control is registered
# only after a successful firmware load inside the HDA component bind
# callback, so it may take a few seconds after modprobe completes.
i=0
while ! amixer -c "${CARD}" cget name="${CONTROL}" &>/dev/null; do
    if [ "${i}" -ge "${MAX_WAIT}" ]; then
        # Control never appeared — firmware load failed at boot; nothing to do.
        exit 0
    fi
    sleep 1
    i=$((i + 1))
done

# Trigger a synchronous request_firmware() call to reliably load DSP
# calibration data even if the initial asynchronous load silently failed.
amixer -c "${CARD}" cset name="${CONTROL}" on >/dev/null
