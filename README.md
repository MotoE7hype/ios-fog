# ios-fog — Redmi 10C / 10 Power bring-up

Fork of [AdyaGMD/ios-spes](https://github.com/AdyaGMD/ios-spes) for the Redmi 10
family: **`fog`** (Redmi 10C), **`rain`** (Redmi 10 Power) and **`wind`** all
fall under the fog base (SM6225 / Snapdragon 680, 720x1650, 4 GB). The work
lives on the `fog` branch, which is this fork's default branch; `main`, `spes`
and `topaz` are kept from upstream.

Upstream port, for reference: [MakrSas/ios-topaz](https://github.com/MakrSas/ios-topaz/tree/topaz)
to **Redmi Note 11 (`spes`, SM6225 / Snapdragon 680)**, 6 GB physical RAM.
The Android “+2 GB” expansion is not RAM available to this kernel.

**This fork (`fog`): boots to the lock screen on the live handset.** The test
handset reports `rain_global` (model 220333QNY) with Android 15 / HyperOS 2;
the live FDT gives 720x1650, Novatek SPI touch and 1 GiB of RAM above 4 GiB.
A Mac-built boot image boots from `fastboot boot` to the lock/home screen with
a live clock (display scaling patched in `0100`, but still reported as not
fitted), and stays up without panicking. Touch transport (Novatek SPI on QUPv3
SE0) is still pending: the current touch-enabled build (`0101`) kernel-panics.
See [docs/FOG-PORT.md](docs/FOG-PORT.md) for the measured facts.

**Upstream status (2026-10-21): iOS 16.7.16 boots to its interface on spes.**
The UI, touchscreen and volume buttons were confirmed on the spes handset.
Startup and interaction are very slow. The current build uses one Gold CPU;
GPU acceleration and Wi-Fi are not working. Additional CPUs and the power
button remain unverified. This is an experimental port, not a daily-use ROM.

The iOS HFS+ root is installed in the existing `userdata` partition after
explicit approval to erase Android data. Boot images are still loaded with
`fastboot boot`; bootloaders, recovery, modem and persist are preserved.
Apple filesystem images and device-specific dumps are not distributed here.

## Redmi 10C (`fog`) — verified hardware, boots to the lock screen

Branch `fog` adds a device profile for the Redmi 10C (SM6225, 4 GB, 720x1650).
The hardware facts are now measured on a live unit (`rain_global` / 220333QNY,
the Redmi 10 Power; fog ROMs are rain ROMs, so `--device rain` is also
accepted): 720x1650@60 BOE panel, Novatek `NVT-ts` touch on QUPv3 SE0 SPI
(`spi0.0`), 1 GiB of usable RAM above 4 GiB, splash at `0x5c000000`, A/B
partitions without a `recovery` split. It **boots to the lock screen with a
running clock**, but touch is not ported (fog's digitizer is SPI, not spes'
I²C part) and the current touch-enabled build panics. The
branch contains `--device fog|rain` ADT generation, a shared 4 GB-capable khaje
memory selector, 720x1650 shim console overrides, RAM-only/full image
builders, a read-only live-data probe and a slot-aware partition backup
script. Start with [docs/FOG-PORT.md](docs/FOG-PORT.md); tests use
`python3 -m unittest tests.test_fog`.

## Changes

- `tools/mkadt.py --device spes --memory-dtb LIVE.dtb`: spes identity, four Gold
  cores, nominal 2.4 GHz, and a kernel platform marker. RAM comes from a live
  bootloader-populated FDT, never from topaz's hard-coded upper bank.
- `tools/spes_memory.py`: selects an aligned contiguous RAM range above 4 GiB;
  excludes explicit reservations and rejects unresolved high-memory pools,
  missing memory maps, and stock zero-filled memory placeholders.
- Patch **0088**: FocalTech AVDD on **GPIO98 / SOUTH tile**, reset 86, IRQ 80;
  integer 1080×2400 coordinates instead of topaz's fractional 1350×3000 input.
  Touch defaults off on spes; opt in with `sweettouch=1` after initial diagnostics.
  Patch **0096** enables PMIC keys with `sweetkeys=1`; volume buttons are
  user-confirmed working. The inherited USB driver remains disabled on spes.
- The shim accepts `BOOT_HEADER_VERSION=3`, matching the supplied stock firmware.
  Version 4 remains the upstream default. Embedded payload packaging is retained;
  temporary bootloader acceptance and RAM-only userspace execution are verified.

## Evidence

Inspected the user's `spes_global_images_OS1.0.8.0.TGCMIXM_13.0` firmware:

| Item | Observed |
| --- | --- |
| boot / vendor_boot headers | Both version 3 |
| Khaje base DTB | vendor_boot DTB index 8 |
| SPES board overlays | DTBO indices 6 and 15; active board revision still unknown |
| Continuous splash | `0x5c000000`, reservation `0xf00000` |
| Memory | `/memory/reg` is all zero; ABL fills it at boot |
| Touch | FocalTech I²C `0x38`, AVDD GPIO98, display coordinates 1080×2400 |

Source reference: [Jabiyeff/kernel_xiaomi_sm6225 at
6c2b3e7](https://github.com/Jabiyeff/kernel_xiaomi_sm6225/tree/6c2b3e7528a0778cd80c95eabb490746b5422f8c),
`arch/arm64/boot/dts/vendor/qcom/{khaje,khaje-idp,spes}.dtsi`,
`drivers/pinctrl/qcom/pinctrl-khaje.c`, and
`drivers/input/touchscreen/ft3418_i2c/focaltech_core.c`.
The GPIO98 SOUTH tile and integer touch decoding come from that source;
hardware testing identified FocalTech `54:52` and confirmed touch events after
patch **0093** enabled the AVDD GPIO output correctly.

## Verified temporary recovery / live memory capture

On 2026-10-18 the official OrangeFox R11.1_2 MIUI recovery booted temporarily
via `fastboot boot` on this handset, with root ADB. No recovery installer or
flash command was run. The live FDT is saved locally in ignored
`dtb/spes-live.dtb`; it is not published because it can contain device identifiers.
The selected XNU RAM range is **0x100000000 + 0xc0000000 (3 GiB)**. The live
DT also confirms AVDD GPIO98, IRQ80 and 1080×2400 touch coordinates.
`shim/out/spes.adt` was generated successfully. This was the initial recovery and memory-map milestone; subsequent tests
reached XNU userspace and then the iOS interface.

## Capturing the live memory map again

Connect the phone with USB debugging enabled and authorize the computer.
Reading `/sys/firmware/fdt` generally needs root or a compatible recovery:

```sh
mkdir -p dtb
adb exec-out su -c 'cat /sys/firmware/fdt' > dtb/spes-live.dtb
```

In an already-running recovery with root ADB, omit `su -c`.
Do not substitute the stock vendor_boot DTB: it has no usable memory map.
The tool intentionally refuses it. No recovery image is supplied in this repository.

## Build preparation

Build XNU with `.github/workflows/xnu.yml` in your own fork (manual dispatch).
It retains the SWEET machine name and applies patches 0001–0099. Download the
`xnu-kernel` artifact into `xnu/out`. The [first corrected kernel build passed](https://github.com/AdyaGMD/ios-spes/actions/runs/39273597179) at source commit `7f915db`.

The shim needs an AArch64 GNU toolchain and an executable AOSP `mkbootimg`.
For full iOS, obtain the iPhone X D22AP tree/root separately; Apple artifacts
are not included. See [upstream background](docs/TOPAZ-UPSTREAM.md) for the
root construction process; its topaz memory and flashing instructions are not
spes validation results.

```sh
mkdir -p shim/out
python3 tools/mkadt.py shim/out/spes.adt --device spes --memory-dtb dtb/spes-live.dtb
python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/spes.adt shim/out/payload.bin \
  --cmdline 'debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam rd=ufsroot0 ufsrw=0 rootrw=0 sweetlog=0 sweettouch=0 sweetkeys=0 sweethw=0 sweetfb_stayon=1'
BOOT_HEADER_VERSION=3 MKBOOTIMG=/absolute/path/to/mkbootimg shim/build.sh out/payload.bin
```

The command line is for **read-only kernel diagnostics**. An Android userdata
partition cannot serve as an iOS HFS+ root, so this will not reach SpringBoard.
An independently prepared RAM root can instead be supplied via `mkpayload.py
--ramdisk IMAGE` and `rd=md0`; its size must fit the selected memory range.
Do not enable UFS writes or persistent logs against Android userdata.

Only after reviewing the generated image and memory map should a temporary
`fastboot boot shim/out/shim-boot.img` be attempted. The test handset now has an iOS root in
userdata. On another handset, installing that root erases Android data and
requires a separate, explicitly confirmed step.

## RAM-only first-boot diagnostic

Once the kernel artifact is available, build a small diagnostic that runs the
project's static test program as PID 1 from RAM. It needs no iOS filesystem
and requests no storage writes:

```sh
CROSS_COMPILE=aarch64-elf- MKBOOTIMG="$PWD/research/mkbootimg/mkbootimg.py" \
  tools/build-spes-diagnostic.sh xnu/out/kernel.development.sweet dtb/spes-live.dtb
```

Output: `shim/out/spes-diagnostic.img` and its SHA-256 file. This tests XNU boot,
userspace execution and the console, not SpringBoard. No phone action is
performed by the script. Hardware execution was confirmed by photos showing
PID 1 and repeated heartbeat messages on 2026-10-19.

## Read-only storage diagnostic

With a kernel including patch 0090, append `storage` to the diagnostic builder:

```sh
CROSS_COMPILE=aarch64-elf- MKBOOTIMG="$PWD/research/mkbootimg/mkbootimg.py" \
  tools/build-spes-diagnostic.sh xnu/out/kernel.development.sweet dtb/spes-live.dtb storage
```

This produces `shim/out/spes-storage-probe.img`. It keeps `rd=md0`, enables
`spesufsprobe=1`, reads the UFS partition table and prints the result before
starting the RAM test program. The probe blocks SCSI commands other than
TEST UNIT READY and READ(10), forces a read-only disk device, and skips
persistent logging and input drivers. It does not mount Android userdata.
On 2026-10-20 the user reported `result=0` and continued PID 1 heartbeats.
This confirms UFS takeover and userdata partition lookup, not filesystem
mounting or disk writes.

## Touch diagnostic

With patch 0091, the builder's `touch` profile produces
`shim/out/spes-touch-probe.img`. It runs touch independently of storage from
RAM, with `spestouchprobe=1 sweettouch=1 sweettouchdelay=5 sweettouchdiag=3`.
It prints input counters and coordinates roughly every five seconds; tap and
drag to test them. Failures print the stage and stop the touch thread.
The first hardware test reached the I²C probe but got NACKs and no chip ID;
the touch thread stopped while PID 1 remained alive. The separate touch I/O
power supply is under investigation. No partition flash or iOS GUI is involved.

## Checks

```sh
python3 -m unittest discover -s tests -v
bash -n shim/build.sh
```

Host tests cover memory selection, reserved regions, malformed input,
stock-map rejection, spes/fog ADT contents, the fog 4 GB map and preservation
of the topaz profile. All shim C/assembly translation units cross-compile with
Clang for Cortex-A53.
All 99 port patches apply to the pinned XNU tree and the full kernel builds in CI.
The RAM-only phone boot reached PID 1 and repeated heartbeat messages;
this does not establish a working iOS interface or full hardware support.

On 2026-10-20, patch 0093 enabled the advertised extended-GPIO feature on
GPIO98. A photo confirms chip ID 54:52 and changing HID touch events and
coordinates. Six report errors were recorded, stable across the visible
samples; further reliability testing remains. No RPM voltage request was
needed for that boot.

## Prepare an iOS root on macOS

`tools/mkiosroot-macos.sh` builds a local 16 GiB raw case-sensitive journaled
HFS+ image from the three iPhone X 16.7.16/20H392 filesystem components. It
mounts source images read-only, preserves numeric owners and hard links,
merges cryptex content, applies the existing bring-up tweaks and runs fsck.
It refuses to overwrite an existing output. Administrator access is required
for file ownership. It never connects to or flashes the phone.

```sh
sudo tools/mkiosroot-macos.sh \
  research/ipsw-x/087-86698-044.dmg \
  research/ipsw-x/087-86593-047.dmg \
  research/ipsw-x/087-86715-047.dmg \
  research/spes-ios-root.img
```

The raw image is published only after successful assembly and filesystem
validation. The temporary workspace is retained for diagnosis; source mounts
are detached on exit. This host preparation does not authorize installation
or validate that SpringBoard will boot on spes.
