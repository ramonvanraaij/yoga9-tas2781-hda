#!/usr/bin/env bash
# 2pa-byps.sh
# =================================================================
# TAS2781 Smart Amplifier Register Initialisation
# Lenovo Yoga Pro 9 16IMH9 (and related models)
#
# Copyright (c) 2026 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script directly programs the TAS2781 smart amplifier registers
# via I2C, bypassing the kernel's firmware-loading path. It restores
# full speaker volume without requiring a PCI power-cycle or a module
# reload, making it safe to run while PipeWire / WirePlumber are active.
#
# The I2C register sequence and multi-model bus detection were adapted from
# the work of Maxim Raznatovski - all credit for the register values goes to him:
#   https://github.com/maximmaxim345/yoga_pro_9i_gen9_linux
#
# It performs the following actions:
# 1. Loads the i2c-dev kernel module if not already present.
# 2. Detects the correct Synopsys DesignWare I2C bus for the model.
# 3. Writes initialisation registers to each TAS2781 amplifier.
#
# Usage:
#   sudo /usr/local/bin/2pa-byps.sh
#   (Also invoked by tas2781-amp-fix.service and the system-sleep hook.)
#
# **Note:**
#   i2c-tools must be installed (provides i2cset and i2cdetect).
#   Run as root (or via sudo).
# =================================================================

set -o errexit -o nounset -o pipefail

export TERM=linux

# --- Configuration ---

readonly ADAPTER_DESCRIPTION="Synopsys DesignWare I2C adapter"

# --- Logging ---

log() { echo -e "\033[1;34m[+]\033[0m $1"; }

# --- Prerequisites ---

modprobe i2c-dev

laptop_model=$(</sys/class/dmi/id/product_name)
log "Laptop model: ${laptop_model}"

# --- I2C bus detection ---

# find_i2c_bus: returns the bus number of the Nth DesignWare I2C adapter.
# The 16IAH10 (Gen 10, 83L0) uses the 2nd adapter; all other supported
# models use the 3rd adapter.
find_i2c_bus() {
    local bus_index=3
    [[ "${laptop_model}" == "83L0" ]] && bus_index=2

    local dw_count
    dw_count=$(i2cdetect -l | grep -c "${ADAPTER_DESCRIPTION}")
    if [[ "${dw_count}" -lt "${bus_index}" ]]; then
        echo "Error: fewer than ${bus_index} DesignWare I2C adapters found (got ${dw_count})." >&2
        return 1
    fi

    i2cdetect -l \
        | grep "${ADAPTER_DESCRIPTION}" \
        | awk '{print $1}' \
        | sed 's/i2c-//' \
        | sed -n "${bus_index}p"
}

i2c_bus=$(find_i2c_bus)
log "Using I2C bus: ${i2c_bus}"

# --- Pin I2C controller PCI device to always-on ---

# The TAS2781 bus sits behind a Synopsys DesignWare I2C controller whose PCI
# parent defaults to runtime-PM=auto. When the display goes off and the system
# enters a deep-idle state, the kernel can put the PCI controller into D3cold,
# which cuts the I2C bus power rail and erases all TAS2781 register state.
# Pinning the controller to "on" prevents this.
pci_ctrl=$(dirname "$(dirname "$(readlink -f "/sys/bus/i2c/devices/i2c-${i2c_bus}")")")
if [[ -w "${pci_ctrl}/power/control" ]]; then
    echo on > "${pci_ctrl}/power/control"
    log "Pinned PCI I2C controller (${pci_ctrl##*/}) to always-on."
fi

# --- I2C address selection ---

# 16IRP8 (Gen 8, 83BY) has four amplifiers at 0x39, 0x38, 0x3d, 0x3b.
# All other supported models have two amplifiers at 0x3f and 0x38.
if [[ "${laptop_model}" == "83BY" ]]; then
    i2c_addrs=(0x39 0x38 0x3d 0x3b)
else
    i2c_addrs=(0x3f 0x38)
fi

# --- Register initialisation ---

log "Programming ${#i2c_addrs[@]} TAS2781 amplifier(s) on bus ${i2c_bus} ..."

count=0
for addr in "${i2c_addrs[@]}"; do
    val=$((count % 2))

    # Page 0: global configuration
    i2cset -f -y "${i2c_bus}" "${addr}" 0x00 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x7f 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x01 0x01
    i2cset -f -y "${i2c_bus}" "${addr}" 0x0e 0xc4
    i2cset -f -y "${i2c_bus}" "${addr}" 0x0f 0x40
    i2cset -f -y "${i2c_bus}" "${addr}" 0x5c 0xd9
    i2cset -f -y "${i2c_bus}" "${addr}" 0x60 0x10

    # Slot offset differs between even- and odd-indexed amplifiers.
    if [[ "${val}" -eq 0 ]]; then
        i2cset -f -y "${i2c_bus}" "${addr}" 0x0a 0x1e
    else
        i2cset -f -y "${i2c_bus}" "${addr}" 0x0a 0x2e
    fi

    i2cset -f -y "${i2c_bus}" "${addr}" 0x0d 0x01
    i2cset -f -y "${i2c_bus}" "${addr}" 0x16 0x40
    i2cset -f -y "${i2c_bus}" "${addr}" 0x00 0x01
    i2cset -f -y "${i2c_bus}" "${addr}" 0x17 0xc8

    # Page 4: DSP coefficient region
    i2cset -f -y "${i2c_bus}" "${addr}" 0x00 0x04
    i2cset -f -y "${i2c_bus}" "${addr}" 0x30 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x31 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x32 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x33 0x01

    # Page 8: filter coefficient region
    i2cset -f -y "${i2c_bus}" "${addr}" 0x00 0x08
    i2cset -f -y "${i2c_bus}" "${addr}" 0x18 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x19 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x1a 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x1b 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x28 0x40
    i2cset -f -y "${i2c_bus}" "${addr}" 0x29 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x2a 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x2b 0x00

    # Page 10 (0x0a): additional coefficient region
    i2cset -f -y "${i2c_bus}" "${addr}" 0x00 0x0a
    i2cset -f -y "${i2c_bus}" "${addr}" 0x48 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x49 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x4a 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x4b 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x58 0x40
    i2cset -f -y "${i2c_bus}" "${addr}" 0x59 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x5a 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x5b 0x00

    # Return to page 0 and release power-down
    i2cset -f -y "${i2c_bus}" "${addr}" 0x00 0x00
    i2cset -f -y "${i2c_bus}" "${addr}" 0x02 0x00

    count=$((count + 1))
done

log "Done. TAS2781 amplifiers initialised."
