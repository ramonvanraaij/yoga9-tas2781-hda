# TAS2781 HDA Codec Fix — Lenovo Yoga Pro 9 16IMH9

Out-of-tree DKMS kernel module that fixes the built-in speaker volume on the
**Lenovo Yoga Pro 9 16IMH9** under Linux kernel 7.x (zen).

## The Problem

After booting into Linux, the built-in speakers produce very low volume —
roughly 10–15% of the expected output even at 100% system volume. The TI
TAS2781 smart amplifiers are powered but their DSP firmware is never loaded.

### Hardware

| Component | Details |
|---|---|
| Machine | Lenovo Yoga Pro 9 16IMH9 |
| Board SSID | `83DN` |
| Audio codec | Realtek ALC287 |
| Codec subsystem ID | `17aa:38d6` |
| PCI audio device subsystem ID | `17aa:3811` |
| Smart amplifiers | 4× TI TAS2781 (ACPI HID: `TIAS2781`) |
| Driver stack | SOF (Sound Open Firmware) → snd-hda-codec-alc269 → snd-hda-scodec-tas2781-i2c |

## Root Cause Analysis

The Linux HDA codec driver (`snd-hda-codec-alc269`) uses two independent
quirk lookup mechanisms to select the hardware-specific fixup:

1. **`SND_PCI_QUIRK`** — matches the *PCI device* subsystem vendor:device ID
   (read from `lspci -v`).
2. **`HDA_CODEC_QUIRK`** — matches the *codec's own* subsystem ID
   (read from `/proc/asound/card0/codec#0`). This is checked *after* the PCI
   lookup and overrides it.

### The Collision

The Yoga Pro 9 16IMH9's PCI audio device subsystem ID (`17aa:3811`) is shared
with the **Legion S7 15IMH05** gaming laptop. In kernel ≥ 7.0, the quirk table
contains:

```c
SND_PCI_QUIRK(0x17aa, 0x3811, "Legion S7 15IMH05",
              ALC287_FIXUP_LEGION_15IMHG05_SPEAKERS),
```

This makes the driver apply the Legion speakers fixup on the Yoga Pro 9, which
does not bind the TAS2781 amplifiers at all.

The codec subsystem ID (`17aa:38d6`) is unique to the Yoga Pro 9 16IMH9 and
has **no `HDA_CODEC_QUIRK` entry** — so nothing overrides the wrong PCI match.

### What the fixup needs to do

The correct fixup for this machine is `ALC287_FIXUP_TAS2781_I2C`, which calls
`tas2781_fixup_tias_i2c`. That function registers the four TAS2781 amplifiers
via the HDA component framework using ACPI HID `TIAS2781`:

```c
comp_generic_fixup(cdc, action, "i2c", "TIAS2781", "-%s:00", 1);
```

When the HDA component handshake completes, the TAS2781 I2C driver loads the
DSP firmware from `/lib/firmware/ti/audio/tas2781/TAS2XXX38D6.bin` and the
speakers produce correct output.

### Confirming the diagnosis

```bash
# Codec subsystem ID — should be 17aa:38d6
grep -i "subsystem id" /proc/asound/card0/codec#0

# TAS2781 I2C device — driver link should exist
ls -la /sys/bus/i2c/devices/i2c-TIAS2781:00/driver

# Firmware file must exist
ls /lib/firmware/ti/audio/tas2781/TAS2XXX38D6.bin*

# After boot WITHOUT the fix: fixup name is blank (no match)
dmesg | grep -i "picked fixup.*38d6"
# Output: "picked fixup  for codec SSID 17aa:38d6"  ← empty fixup name = wrong match

# After boot WITH the fix:
dmesg | grep -i "tas2781\|38d6"
# Should show TAS2781 component binding and firmware load
```

## The Fix

A single `HDA_CODEC_QUIRK` entry added to the ALC287 quirk table in
`sound/hda/codecs/realtek/alc269.c`, immediately before the conflicting Legion
PCI quirk. Codec quirks are evaluated after PCI quirks and win:

```c
/* Yoga Pro 9 16IMH9 shares PCI SSID 17aa:3811 with Legion S7 15IMH05;
 * use codec SSID to distinguish them
 */
HDA_CODEC_QUIRK(0x17aa, 0x38d6, "Lenovo Yoga Pro 9 16IMH9",
                ALC287_FIXUP_TAS2781_I2C),
SND_PCI_QUIRK(0x17aa, 0x3811, "Legion S7 15IMH05",
              ALC287_FIXUP_LEGION_15IMHG05_SPEAKERS),
```

The patch (`yoga9-16imh9.patch`) is a standard unified diff against zen-kernel
commit `d36eb0562b3bf60c8272ef486d001a07e85486fc` (branch `7.0/main`, which
merged tag `v7.0.2`). It applies cleanly to the full Linus tree at v7.0.2 as
well, since the realtek codec files were not modified between v7.0.2 and the
zen merge commit.

## Implementation as a DKMS Module

Because `snd-hda-codec-alc269` is an in-tree module, the simplest permanent
fix is a DKMS out-of-tree replacement. DKMS automatically rebuilds the module
against each new kernel install.

The module compiles a single source file (`alc269.c`) and requires internal
HDA headers that are not shipped with the standard kernel-headers package.
`pre_build.sh` — a DKMS `PRE_BUILD` hook — fetches everything from zen-kernel
via a git sparse checkout before each compile. This runs automatically on
initial install and on every subsequent kernel upgrade.

### Directory layout inside the DKMS source tree

```
/usr/src/snd-hda-codec-alc269-fix-1.0/
├── Makefile
├── dkms.conf
├── pre_build.sh          ← DKMS PRE_BUILD hook; fetches sources before each build
├── yoga9-16imh9.patch    ← the codec quirk fix applied by pre_build.sh
├── codecs/               ← populated by pre_build.sh at build time
│   ├── realtek/
│   │   ├── alc269.c        ← patched compilation unit
│   │   └── realtek.h       ← includes generic.h, hda_component.h, hda_common headers
│   ├── generic.h           ← realtek.h: #include "../generic.h"
│   ├── side-codecs/
│   │   └── hda_component.h ← realtek.h: #include "../side-codecs/hda_component.h"
│   └── helpers/            ← alc269.c: #include "../helpers/<file>.c"
│       ├── thinkpad.c
│       ├── ideapad_hotkey_led.c
│       ├── hp_x360.c
│       └── ideapad_s740.c
└── hda_common/           ← populated by pre_build.sh at build time
    ├── hda_local.h         ← added to ccflags so realtek.h finds these
    ├── hda_auto_parser.h
    ├── hda_beep.h
    └── hda_jack.h
```

### Why the module is larger than the in-tree version

The in-tree module is compiled with Link Time Optimization (LTO) as part of the
full kernel build. The out-of-tree DKMS build does not use LTO, so the binary
is roughly 30% larger than the original. This has no functional impact.

## Prerequisites

| Package | Purpose |
|---|---|
| `dkms` | Build and manage the out-of-tree module |
| `linux-zen-headers` | Kernel build tree for module compilation |
| `git` | Sparse-clone the zen-kernel source (used by `pre_build.sh`) |
| `zstd` | Kernel module compression |
| `patch` | Apply the unified diff (used by `pre_build.sh`) |
| `base-devel` | GCC, make, etc. |

Internet access is required at build time: `pre_build.sh` fetches sources
from the zen-kernel GitHub repository during `dkms build`.

Install on Arch Linux:
```bash
sudo pacman -S dkms linux-zen-headers git zstd patch base-devel
```

## Quick Start (Automated)

Requires internet access — `pre_build.sh` fetches zen-kernel sources during
the build step.

```bash
git clone https://github.com/ramonvanraaij/yoga9-tas2781-hda.git
cd yoga9-tas2781-hda
./build.sh
sudo reboot
```

After reboot, test the speakers at full volume.

## Manual Build Steps

If you prefer to run each step individually:

### 1. Set up the DKMS source tree

Copy the build scaffolding from the cloned repo into the DKMS source directory:

```bash
sudo mkdir -p /usr/src/snd-hda-codec-alc269-fix-1.0
sudo cp Makefile dkms.conf pre_build.sh yoga9-16imh9.patch \
    /usr/src/snd-hda-codec-alc269-fix-1.0/
sudo chmod +x /usr/src/snd-hda-codec-alc269-fix-1.0/pre_build.sh
```

### 2. Register, build, and install via DKMS

```bash
sudo dkms add snd-hda-codec-alc269-fix/1.0
sudo dkms build snd-hda-codec-alc269-fix/1.0
sudo dkms install snd-hda-codec-alc269-fix/1.0
```

`dkms build` calls `pre_build.sh`, which derives the zen-kernel branch from
the running kernel version (e.g. `7.0.2-zen1-1-zen` → `7.0/main`), fetches
the required source files via git sparse checkout, applies the patch, and
places the results in the DKMS source tree for compilation. Internet access
is required.

If the build fails, check the log:
```bash
sudo cat /var/lib/dkms/snd-hda-codec-alc269-fix/1.0/$(uname -r)/x86_64/log/make.log
```

### 3. Reboot

The running audio subsystem holds the module; a live reload is not possible:
```bash
sudo reboot
```

## Verification

After reboot, run the following checks:

```bash
# 1. Confirm the patched module is loaded
modinfo snd-hda-codec-alc269 | grep filename
# Expected: /lib/modules/<kver>/updates/dkms/snd-hda-codec-alc269.ko.zst

# 2. Confirm the TAS2781 fixup was selected (no blank fixup name)
dmesg | grep -i "picked fixup"
# Expected: something containing "TAS2781" or no blank name for 17aa:38d6

# 3. Confirm the TAS2781 driver bound successfully
ls -la /sys/bus/i2c/devices/i2c-TIAS2781:00/driver
# Expected: symlink to ../../../../bus/i2c/drivers/tas2781-hda

# 4. Confirm firmware was loaded
dmesg | grep -i "TAS2XXX38D6\|tas2781"

# 5. Confirm ALSA sees the codec and amplifier channels
aplay -l
amixer -c sofhdadsp scontrols | grep -i speaker
```

## Kernel Updates

DKMS rebuilds the module automatically when a new kernel is installed.
`pre_build.sh` derives the correct zen-kernel branch from the new kernel
version and fetches fresh sources at build time, so each rebuild uses the
right `alc269.c` for its kernel without any manual intervention.

If audio stops working after a kernel upgrade, check whether the DKMS build
succeeded:
```bash
sudo dkms status
sudo cat /var/lib/dkms/snd-hda-codec-alc269-fix/1.0/$(uname -r)/x86_64/log/make.log
```

The most likely failure cause is the patch no longer applying cleanly because
the upstream quirk table was reorganised. In that case, update the patch
context in `yoga9-16imh9.patch` to match the new upstream file, then
reinstall:
```bash
./build.sh --uninstall
./build.sh
```

## Rollback / Uninstall

```bash
# Using the build script
./build.sh --uninstall

# Or manually
sudo dkms remove snd-hda-codec-alc269-fix/1.0 --all
sudo rm -rf /usr/src/snd-hda-codec-alc269-fix-1.0
sudo reboot
```

DKMS restores the archived original module on `dkms remove`.

## Additional Notes

### udev PM keepalive rule

Even with the correct fixup, the TAS2781 I2C device defaults to
runtime-PM `auto` with a 3-second autosuspend. On resume after audio
inactivity the amp loses its DSP state. Pin the device to always-on:

```bash
sudo tee /etc/udev/rules.d/99-tas2781-keepalive.rules <<'EOF'
# Keep TI TAS2781 smart amplifier always powered; it loses DSP state on runtime-suspend.
ACTION=="add|bind", SUBSYSTEM=="i2c", KERNELS=="TIAS2781:00", \
    ATTR{power/control}="on"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=i2c
```

Confirm it stuck:
```bash
cat /sys/bus/i2c/devices/i2c-TIAS2781:00/power/control
# Expected: on
```

### Note on the TXNW2781 variant

Some other Lenovo machines use a different TAS2781 variant with ACPI HID
`TXNW2781`. The corresponding fixup is `ALC287_FIXUP_TXNW2781_I2C`. Do **not**
use that fixup for the Yoga Pro 9 16IMH9 — the ACPI HID here is `TIAS2781`
(confirmed via `/sys/bus/i2c/devices/i2c-TIAS2781:00/modalias`).

### Upstream status

Submitted to `linux-sound@vger.kernel.org` on 30 April 2026
(Cc: `alsa-devel@alsa-project.org`, Takashi Iwai).
Message-Id: `<20260430191224.patch1-ramon@vanraaij.eu>`

The patch is a minimal, self-contained addition following the same pattern
already used for other Lenovo models that share PCI SSIDs (e.g. `17aa:3847`
shared between Yoga Pro 7 14IMH9 and Legion 7 16ACHG6, resolved via
`HDA_CODEC_QUIRK` for codec SSID `17aa:38cf`).

## Tested Environment

| Item | Value |
|---|---|
| Machine | Lenovo Yoga Pro 9 16IMH9 |
| OS | Arch Linux |
| Kernel | `7.0.2-zen1-1-zen` (linux-zen) |
| zen-kernel commit | `d36eb0562b3bf60c8272ef486d001a07e85486fc` |
| DKMS | 3.4.0 |
| Firmware | `/lib/firmware/ti/audio/tas2781/TAS2XXX38D6.bin.zst` |
