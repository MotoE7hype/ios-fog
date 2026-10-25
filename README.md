# ios-fog — Redmi 10C / 10 Power bring-up

Port of iOS 16 userland + XNU to the Redmi 10 family: **`fog`** (Redmi 10C),
**`rain`** (Redmi 10 Power) and **`wind`** all fall under the fog base
(SM6225 / Snapdragon 680, 720x1650, 4 GB). Work happens on the `fog` branch,
which is this fork's default branch.

Forked from `AdyaGMD/ios-spes`; the family is derived from the topaz work by
MakrSas (`MakrSas/ios-topaz`, `topaz` branch). The upstream device profiles are
kept unchanged in the code, but this README documents only the fog bring-up.

## Status

**Boots to the lock screen on the live handset.** The test unit reports
`rain_global` (model 220333QNY) with Android 15 / HyperOS 2 and gives a live
FDT with 720x1650, Novatek SPI touch and 1 GiB of RAM above 4 GiB. A Mac-built
boot image boots with `fastboot boot` to the lock/home screen, the clock keeps
advancing, and the system does not panic or crash.

Open issues:

| Item | State |
| --- | --- |
| Touch | Implemented in patch `0101`: Novatek `NVT-ts` on QUPv3 **SE0 GENI SPI**, FIFO mode, split TX/RX commands with CS held across a register read. The driver now reaches SE0 init properly on the handset; the panel has not produced a single contact yet. |
| Touch-enabled build | The first `0101` **kernel-panicked** because it voted the GCC clocks before mapping them; the rewrite maps first and boots. Two diagnostic findings fixed since: `rd=md0` never reached the driver (`4b5e4fd`), and `GENI_IF_DISABLE_RO` bit 0 was wrongly treated as fatal although it only means the SE prefers GPI DMA (`dbf85c0`). New images: diagnostic `40235763865`, iOS rebuilt on the Mac. |
| Display scaling | Patch `0100` fits the 1125x2436 canvas to the 720x1650 panel; confirmed on the handset. |
| Keys, UFS, GPU, Wi-Fi, SMP | Inherited, unverified here. Keep `sweetkeys=0 sweethw=0` until each is tested. |

This is an experimental port, not a daily-use ROM. Boot images are loaded with
`fastboot boot`; bootloaders, recovery, modem and persist are left alone. The
iOS HFSX root lives in the existing `userdata` partition (Android data was
erased with explicit approval). Apple filesystem images and device-specific
dumps are not distributed here.

## Hardware — verified on the handset (2026-10-22)

The unit used for bring-up reports `rain_global`, so `--device rain` is the
matching identity; fog ROMs are rain ROMs and the layout is shared.

| Fact | Value |
| --- | --- |
| SoC / board | SM6225, `ro.board.platform=bengal`, DT `qcom,khaje-idp` |
| DRAM banks | `0x40000000+0x3dd00000`, `0x80000000+0x40000000`, `0xc0000000+0x80000000` |
| RAM above 4 GiB | 1 GiB → `dram-base 0x100000000`, `dram-size 0x40000000` |
| Splash | `cont_splash_region@5c000000`, size `0xf00000` |
| Panel | `720x1650x60` DSI video, BOE `nt36525b` |
| Backlight | `panel0-backlight`, max 2047 |
| Touch | `spi0.0`, driver `NVT-ts`, QUPv3 SE0 `spi@4a80000` |
| Touch wiring | reset GPIO 86, IRQ GPIO 80, 9.6 MHz, 10 fingers, coords 720x1650 |
| Partitions | A/B (`boot_a/b`, `dtbo_a/b`, `modem_a/b`, ...), no `recovery`, plus `super` and `splash` |

The live FDT is ~596 KB and the active `dtbo_a` is 24 MB; neither is committed,
because the FDT carries the serial. Probe output lands in `probe/` (git-ignored).
See [docs/FOG-PORT.md](docs/FOG-PORT.md) for the measurements and the register
notes for the SPI work.

## What the branch adds

- `tools/mkadt.py --device fog|rain|wind` — identity `xiaomi,<device>`, a
  `/fog-platform` marker, four Gold cores at 2.4 GHz, framebuffer
  `0x5c000000` at 720x1650 stride 2880, and the iPhone X canvas (1125x2436 @3x)
  that UIKit needs.
- `tools/spes_memory.py` — khaje memory selector: an aligned contiguous range
  above 4 GiB, rejecting reservations, unresolved pools and stock zero-filled
  placeholders.
- `shim/build.sh` + `shim/console.h` — `SHIM_FB_BASE`, `SHIM_FB_W`, `SHIM_FB_H`
  overrides so the shim console and `boot_args` follow the panel.
- `tools/build-fog-diagnostic.sh` — RAM-only PID 1 diagnostic (`rd=md0`).
- `tools/build-fog-ios.sh` — full iOS image (UFS root), with `FOG_CPUS`,
  `FOG_TOUCH`, `FOG_PANEL_W/H` and `FOG_MEMORY` knobs.
- `tools/backup-fog.sh` — read-only, slot-aware partition + `/sdcard` backup.
- `tools/fog-probe.sh` — read-only capture of the live FDT, `dtbo`, dmesg,
  `/proc` data and the SPI/DRM/backlight sysfs.
- `xnu/patches/0100-sweet-fb-present-scale.patch` — present-path scaling and
  HID panel-size mapping, gated on `/fog-platform`.
- `xnu/patches/0101-fog-novatek-spi-touch.patch` — fog detection plus the SE0
  GENI SPI transport: clocks, SE init, Novatek page/FWINFO probe, report
  parser and 720x1650 coordinate scaling.
- `tests/test_fog.py` — ADT geometry, 4 GB memory selection, upstream-profile
  preservation.

## Get a kernel

`.github/workflows/xnu.yml` builds XNU on macOS runners (manual dispatch) and
applies the whole patch series. Download the `xnu-kernel` artifact into
`xnu/out`. The current `fog` tip built successfully in run `40235249291`.

No local toolchain is required for the boot images either:
`.github/workflows/fog-image.yml` builds a diagnostic on `ubuntu-latest` from a
kernel artifact and uploads `<device>-diagnostic.img` plus its `.sha256`.

## Build the RAM-only diagnostic

```sh
CROSS_COMPILE=aarch64-elf- MKBOOTIMG="$PWD/tools/vendor/mkbootimg/mkbootimg.py" \
  FOG_DEVICE=rain FOG_MEMORY=0x100000000:0x40000000 \
  tools/build-fog-diagnostic.sh xnu/out/kernel.development.sweet
```

`FOG_MEMORY` is the range measured on this unit; the resulting image is valid
only for it. With a live FDT you can pass it instead of `FOG_MEMORY`:

```sh
CROSS_COMPILE=aarch64-elf- MKBOOTIMG="$PWD/tools/vendor/mkbootimg/mkbootimg.py" \
  FOG_DEVICE=rain tools/build-fog-diagnostic.sh xnu/out/kernel.development.sweet probe/fog-live/fog-live.dtb
```

Output is `shim/out/<device>-diagnostic.img` + `.sha256`, using the 720x1650
shim console. `FOG_CPUS=N` (1-4, default 1) sets `cpus=N`; the ADT always lists
the four Gold cores with three stopped. Nothing is sent to the phone.

## Build the full iOS image

Needs the HFSX root already installed in `userdata`:

```sh
CROSS_COMPILE=aarch64-elf- MKBOOTIMG="$PWD/tools/vendor/mkbootimg/mkbootimg.py" \
  FOG_DEVICE=rain FOG_MEMORY=0x100000000:0x40000000 \
  tools/build-fog-ios.sh xnu/out/kernel.development.sweet
```

`FOG_TOUCH=1` adds `sweettouch=1 sweetfb_panel_w/h` and enables the `0101` SE0
SPI driver; `FOG_TOUCH_DELAY` and `FOG_TOUCH_DIAG` shorten the 45 s start delay
and add the periodic statistics print. Check the `SWEET TOUCH: fog ...` console
lines before trusting the panel. `/product` comes from
`research/ipsw-x/d22ap.adt` when present; otherwise the image boots without the
iPhone X identity.

## Back up before any write

`fastboot boot` is RAM-only and needs no backup. Back up first before
installing the iOS root into `userdata`, flashing `boot`/`vendor_boot`/`dtbo`/
`vbmeta`, changing slots or running `fastboot -w`:

```sh
tools/backup-fog.sh                 # writes backup/fog-YYYYmmdd-HHMMSS/
FOG_WITH_SDCARD=0 tools/backup-fog.sh   # partitions only
```

The critical set is `boot`, `vendor_boot`, `dtbo`, `vbmeta*`, `modem`, `fsg`,
`modemst1`, `modemst2`, `persist`, `misc`, `splash` and `/sdcard`. `persist`
and `modem*` hold calibration/IMEI data a factory ROM may not restore. A
missing partition makes the script exit 3, so a "successful" backup can never
silently omit `boot_a`. `backup/` is git-ignored.

## Capture the live memory map

Root ADB on the running phone, then one read-only pass:

```sh
tools/fog-probe.sh                  # writes probe/fog-YYYYmmdd-HHMMSS/
```

Or by hand:

```sh
mkdir -p dtb
adb exec-out su -c 'cat /sys/firmware/fdt' > dtb/fog-live.dtb
adb shell getprop ro.product.device          # rain or fog
adb shell 'cat /proc/meminfo | head -n 3'
```

Do not substitute the stock vendor_boot DTB: it has no usable memory map and
the selector refuses it. Keep `dtb/` and `probe/` out of git.

`select_memory` must return an address `>= 0x100000000`. If the live FDT has no
upper bank, stop and extend the selector with a verified low-memory layout
first — XNU must not map XPU carve-outs. If the splash base moves from
`0x5c000000`, rebuild with `SHIM_FB_BASE=0x...` and edit the `fog`/`rain` `fb`
tuple in `tools/mkadt.py`.

## Checks

```sh
python3 -m unittest discover -s tests -v
bash -n shim/build.sh
```

Host tests cover memory selection, reserved regions, malformed input,
stock-map rejection, fog ADT contents, the 4 GB map and preservation of the
upstream profiles. One test error is expected on Windows only (`os.chown` is
absent, unrelated). All shim C/assembly units cross-compile with Clang for
Cortex-A53, and the whole patch series applies to the pinned XNU tree and
builds in CI.

## Prepare an iOS root on macOS

`tools/mkiosroot-macos.sh` builds a local 16 GiB raw case-sensitive journaled
HFS+ image from the three iPhone X 16.7.16/20H392 filesystem components. It
mounts the source images read-only, preserves numeric owners and hard links,
merges cryptex content, applies the bring-up tweaks and runs `fsck`. It refuses
to overwrite an existing output, needs administrator access for ownership, and
never connects to or flashes the phone.

```sh
sudo tools/mkiosroot-macos.sh \
  research/ipsw-x/087-86698-044.dmg \
  research/ipsw-x/087-86593-047.dmg \
  research/ipsw-x/087-86715-047.dmg \
  research/fog-ios-root.img
```

Host preparation does not authorize installation. Installing the root erases
Android data and needs a separate, explicitly confirmed step.

## Flashing rules

Do not flash `boot`, `vendor_boot`, `dtbo`, `vbmeta`, `persist` or `modem` for
bring-up — `fastboot boot` is enough. Keep the partition backups and the
matching official HyperOS fastboot package; never flash older firmware
(anti-rollback). See [docs/FOG-PORT.md](docs/FOG-PORT.md) for the test order and
per-step expectations.
