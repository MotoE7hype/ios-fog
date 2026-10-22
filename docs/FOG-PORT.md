# Redmi 10C (`fog`) port

Status: **host-side scaffolding only (2026-10-22)**. No fog boot image has been
run on the handset yet. The spes profile and its tests are unchanged.

Target: Redmi 10C `fog` (SM6225 / Snapdragon 680 "khaje", Adreno 610, 4 GB RAM,
720x1650 panel, HyperOS 2, unlocked bootloader, root ADB). `rain` (Redmi 10
Power) and `wind` (Redmi 10) are the same khaje board family; this profile is
intended to cover them once the live FDT confirms the RAM/splash layout.

## Why this is not a copy of `spes`

| | spes (working) | fog (this port) |
| --- | --- | --- |
| Panel | 1080x2400 AMOLED | 720x1650 LCD |
| Touch bus | FocalTech I2C (`0x38`), QUP SE2 | Novatek/FocalTech **SPI** on `qupv3_se0_spi` |
| Touch reset / IRQ | GPIO 86 / GPIO 80 | GPIO 86 / GPIO 80 (same pins, different transport) |
| Touch power | AVDD GPIO 98 (SOUTH tile) | regulator, not the spes GPIO |
| RAM | 6 GB, 3 GiB selected above 4 GiB | 4 GB, expected ~2 GiB above 4 GiB |
| Splash | `0x5c000000`, `0xf00000` | khaje `0x5c000000`, `0xf00000` (verify live) |

The inherited `sweet_touch.c` is an I2C driver. It cannot drive fog's SPI
controller, and its coordinate clamp is 1080x2400. **Touch is intentionally
off in the fog images** (`sweettouch=0`) until an SPI transport is implemented
and tested.

Stock DT facts for that work (`khaje-idp.dtsi`, included by `fog.dtsi`):

```
&qupv3_se0_spi {
    novatek@0 {
        compatible = "novatek,NVT-ts-spi", "focaltech,fts";
        spi-max-frequency = <0x927c00>;              /* 9.6 MHz */
        novatek,reset-gpio = <&tlmm 86 0>;
        novatek,irq-gpio = <&tlmm 80 8193>;
        novatek,swrst-n8-addr = <0x3f0fe>;
        novatek,spi-rd-fast-addr = <0x3f310>;
        focaltech,max-touch-number = <10>;
        focaltech,display-coords = <0 0 0x2cf 0x671>; /* 720x1650 */
    };
};
```

`fog.dtsi` disables the I2C `synaptics_tcm@20` and `novatek@62` nodes on
`qupv3_se2_i2c`, so the live digitizer is the SPI node. The primary compatible
is Novatek; the FocalTech entries are the fallback/coordinate description.
Confirm the actual controller from the running phone
(`/sys/bus/spi/devices`, `dmesg | grep -i -E 'novatek|focaltech|NVT'`) before
writing the transport.

## What is in this branch

- `tools/mkadt.py --device fog`:
  - identity `xiaomi,fog` (+ `xiaomi,sweet`, `qcom,khaje`), synthetic chip ID,
    four Gold cores at 2.4 GHz, `/fog-platform` marker;
  - framebuffer `0x5c000000`, 720x1650, stride 2880;
  - still reports the iPhone X canvas (1125x2436 @3x) so UIKit has a supported
    screen class. Until a scaling path exists, the panel shows the centre crop
    of that canvas (the same mechanism spes uses for its 1080x2400 panel).
- `tools/spes_memory.py`: shared khaje selector. It now accepts `qcom,khaje`
  and `qcom,sm6225`, uses named alignment/minimum constants, and has a 4 GB
  test (2 GiB below + 2 GiB above 4 GiB). The upper bank is still the only
  accepted source: every khaje XPU carve-out is below 4 GiB.
- `shim/build.sh` + `shim/console.h`: `SHIM_FB_BASE`, `SHIM_FB_W`,
  `SHIM_FB_H` build overrides. Defaults remain 1080x2400 at `0x5c000000`, so
  topaz/spes images are byte-identical. The boot shim console and `boot_args`
  now follow the panel size.
- `tools/build-fog-diagnostic.sh`: RAM-only PID 1 diagnostic (`rd=md0`).
- `tools/build-fog-ios.sh`: full iOS image builder (UFS root, 1 Gold CPU).
- `tools/backup-fog.sh`: read-only partition backup (see below).
- `tools/fog-probe.sh`: read-only capture of the live FDT, `dtbo`, SPI/panel
  sysfs and `dmesg` (see below).
- `tests/test_fog.py`: fog ADT geometry, 4 GB memory selection, spes/topaz
  preservation.

## Back up before touching the phone

Testing uses `fastboot boot` (RAM only), which does **not** write flash, so a
backup is not required just to try a diagnostic. Back up **before** any of:

- installing the iOS HFS+ root into `userdata` (destroys Android data),
- flashing `boot`/`vendor_boot`/`dtbo`/`vbmeta`,
- changing the active slot or running `fastboot -w`.

The critical set is `boot`, `vendor_boot`, `dtbo`, `vbmeta*`, `modem`, `fsg`,
`modemst1`, `modemst2`, `persist`, `misc` and your personal `/sdcard` files.
`persist` and `modem*` hold calibration/IMEI data that a factory ROM may not
restore. `super` is large; you can skip it if you keep the matching official
HyperOS fastboot package offline (anti-rollback: never flash older firmware).

With root ADB on the running phone:

```sh
tools/backup-fog.sh                 # writes backup/fog-YYYYmmdd-HHMMSS/
tools/backup-fog.sh /path/to/backup
```

The script reads only, skips missing partitions, records `getprop`, the
by-name map and SHA-256 sums, and pulls `/sdcard`. `backup/` is git-ignored.
From a temporary recovery with root ADB, the same commands work (omit `su` if
already root). Verify at least that `boot.img`, `vendor_boot.img` and
`persist.img` are non-empty and have plausible sizes.

## Capture the live memory map

The stock DTBs contain zero-filled `/memory` nodes; ABL fills the real map at
boot. Boot the phone normally (root ADB) or temporarily boot a recovery, then
collect everything the port is still guessing at in one read-only pass:

```sh
tools/fog-probe.sh                  # writes probe/fog-YYYYmmdd-HHMMSS/
```

That writes the live FDT, `dtbo`, `dmesg`, `/proc/{meminfo,iomem,cmdline}`,
the SPI controller/driver list, DRM modes, backlight and by-name sizes, and
prints a summary (device, RAM, FDT/dtbo size, touch controller). `probe/` is
git-ignored. The individual commands, if you prefer to run them by hand:

```sh
mkdir -p dtb
adb exec-out su -c 'cat /sys/firmware/fdt' > dtb/fog-live.dtb
adb shell getprop ro.product.device          # expect: fog
adb shell getprop ro.boot.hardware           # expect: qcom
adb shell 'cat /proc/meminfo | head -n 3'
adb shell 'dmesg | grep -i -E "cont_splash|memory@|reserved" | head -n 40'
```

Keep `dtb/` out of git. The FDT can contain the serial number.

Then check the two assumptions the profile makes:

```sh
python3 - <<'PY'
import sys
sys.path.insert(0, 'tools')
from spes_memory import parse, select_memory
blob = open('dtb/fog-live.dtb','rb').read()
nodes, _ = parse(blob)
print('root compatible:', nodes[''].get('compatible'))
print('memory:', [k for k in nodes if k.startswith('/memory')])
print('selected:', hex(select_memory(blob)[0]), hex(select_memory(blob)[1]))
for p, props in nodes.items():
    if 'splash' in p and 'reg' in props:
        print('splash:', p, props['reg'].hex())
PY
```

`select_memory` must return an address `>= 0x100000000`. If the live FDT has
no upper bank, stop: the selector must be extended with a verified low-memory
layout (XNU must not map XPU carve-outs). If the splash base is not
`0x5c000000`, build with `SHIM_FB_BASE=0x...` for the shim and edit the
`fog` profile's `fb` tuple in `tools/mkadt.py`.

## Build

XNU: run `.github/workflows/xnu.yml` on the `fog` branch (manual dispatch) or
download the `xnu-kernel` artifact from a `spes` run. The kernel patch set is
shared; no fog kernel patch exists yet, so any current spes kernel works for
the RAM-only diagnostic.

Shim: AArch64 GNU toolchain + AOSP `mkbootimg`.

```sh
CROSS_COMPILE=aarch64-elf- MKBOOTIMG="$PWD/research/mkbootimg/mkbootimg.py" \
  tools/build-fog-diagnostic.sh xnu/out/kernel.development.sweet dtb/fog-live.dtb
```

Outputs `shim/out/fog-diagnostic.img` + `.sha256`, using the 720x1650 shim
console. Nothing is sent to the phone.

For the full UI (only after a diagnostic success and a userdata iOS root):

```sh
CROSS_COMPILE=aarch64-elf- MKBOOTIMG="$PWD/research/mkbootimg/mkbootimg.py" \
  tools/build-fog-ios.sh xnu/out/kernel.development.sweet dtb/fog-live.dtb
```

## Test order (each step needs a user decision)

1. `fastboot boot shim/out/fog-diagnostic.img` — a temporary RAM boot. Expect
   the shim lines, then the kernel fbcon/PID 1 output on the 720x1650 panel.
   If the screen stays black, the splash base or panel geometry is wrong; the
   phone is still running Android and a normal reboot recovers it.
2. Only after PID 1 output: port SPI touch and verify coordinates. Do not
   enable `sweettouch=1` before that; the I2C probe is meaningless on fog.
3. Install the iOS root into `userdata` only with explicit approval and a
   verified backup. Then `build-fog-ios.sh`.
4. Display: verify the centre-cropped iPhone X canvas is usable. A proper
   full-screen presentation needs a `present()` scaling path (logical
   1125x2436 -> 720x1650) and a `SweetHID` panel-size source; the current
   `sweetfb_native=1` path hardcodes 1080x2400 and must not be used on fog.

Do not flash `boot`, `vendor_boot`, `dtbo`, `vbmeta`, `persist` or `modem` for
bring-up. `fastboot boot` is enough.

## Open items

- Live FDT: RAM banks, reserved regions, real splash base, board revision.
- Touch: confirm controller (Novatek NT36xxx vs FocalTech FT3518) from
  `/sys/bus/spi/devices` / the stock DTBO, then implement QUPv3 SE0 SPI in
  `sweet_touch.c` (reset GPIO 86, IRQ 80) with a fog coordinate clamp.
- Display: 720x1650 present/scaling and HID mapping (see step 4).
- Panel/backlight: ABL leaves the splash on; brightness control is untested.
- Keys/PMIC, UFS, GPU, Wi-Fi: inherited from spes patches but unverified on
  fog; keep `sweetkeys=0`, `sweethw=0` until each is tested.
- `wind`/`rain` differences (regulators, panel variant) are unconfirmed.
