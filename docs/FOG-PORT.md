# Redmi 10C (`fog`) port

Status: **hardware verified; boots to the lock screen (2026-10-25)**. The iOS
image reaches SpringBoard and keeps a live clock without panicking; touch is
not ported and the touch-enabled build panics, and display scaling is still
reported as not fitted. The spes profile and its tests are unchanged.

Target: Redmi 10C `fog` (SM6225 / Snapdragon 680 "khaje", Adreno 610, 4 GB RAM,
720x1650 panel, HyperOS 2, unlocked bootloader, root ADB). `rain` (Redmi 10
Power) and `wind` (Redmi 10) fall under the fog base; all three share the same
profile and `/fog-platform` marker. This repository is the `ios-fog` fork of
`AdyaGMD/ios-spes`, with `fog` as its default branch. The handset used for
bring-up reports **`rain_global`, model 220333QNY**, so `--device rain` is the
matching identity for this unit.

## Verified on the handset (2026-10-22)

`tools/fog-probe.sh` on the running phone (Android 15, HyperOS
2.0.9.0.VJXCNXM, `verifiedbootstate=orange`, Magisk root, slot `_a`):

| Fact | Value |
| --- | --- |
| SoC / board | SM6225, `ro.board.platform=bengal`, DT `qcom,khaje-idp` |
| DRAM banks | `0x40000000+0x3dd00000`, `0x80000000+0x40000000`, `0xc0000000+0x80000000` (1 GiB → 5 GiB, 35 MiB hole) |
| RAM above 4 GiB | 1 GiB → `dram-base 0x100000000`, `dram-size 0x40000000` |
| Splash | `cont_splash_region@5c000000`, `0xf00000` (matches `FB_SIZE`) |
| Panel | `720x1650x60` DSI video, BOE `nt36525b`, `lcmtype=dsi_panel_c3q_35_02_0a_fhdp_video` |
| Backlight | `panel0-backlight`, max 2047 |
| Touch | `spi0.0`, driver `NVT-ts`, Novatek over QUPv3 SE0 `spi@4a80000` |
| Touch wiring | reset GPIO 86, IRQ GPIO 80, 9.6 MHz, 10 fingers, coords 720x1650 |
| Partitions | A/B (`boot_a/b`, `dtbo_a/b`, `modem_a/b`, ...), no `recovery`, `super`, `splash` |

The live FDT is 596 KB; the active `dtbo_a` is 24 MB. Neither is committed
(the FDT carries the serial). Probe output lives in `probe/` (git-ignored).

The handset runs a **rain** firmware image: Redmi 10C (`fog`) ROMs are rain
ROMs, and fog/rain/wind are one fog-base family, so `--device rain` is the
accurate identity for this unit. It builds the same layout with `xiaomi,rain`
and `rain-shim` identity strings; the `/fog-platform` marker is shared, so one
kernel patch covers the family. `wind` is included on the same assumption;
every panel node in the verified live FDT is 720x1650, but a wind unit should
still be probed before booting.

## Boot status on the handset (2026-10-25, user report)

| Result | Detail |
| --- | --- |
| Reaches the lock screen | iOS userland/SpringBoard up on the 720x1650 panel |
| Stays alive | the on-screen clock advances; no panic or crash during the run |
| Touch | dead — patch `0101` had no SPI transport (rewritten 2026-10-25) |
| Display scaling | still wrong — the 1125x2436 canvas is not fitted to the panel |
| Touch-enabled build (`0101`) | **kernel panic** before userspace; cause found and fixed 2026-10-25 |

The panic came from the first version of `0101`: it called `touch_clocks()`
from `sweet_touch_init()`, i.e. before the touch thread had mapped `st.gcc`, so
the GCC vote write dereferenced a NULL window. No panic text was ever captured,
so this is a reading of the patch, not a photographed backtrace. The rewrite
votes the clocks inside `touch_fog_run()`, after the mapping succeeds, and the
kernel now builds in CI. A new full iOS image with the rewritten driver exists
(`rain-ios-touch.img`, below), but neither it nor the diagnostic build has been
booted on the handset yet.

## Why this is not a copy of `spes`

| | spes (working) | fog (this port) |
| --- | --- | --- |
| Panel | 1080x2400 AMOLED | 720x1650 LCD |
| Touch bus | FocalTech I2C (`0x38`), QUP SE2 | Novatek **SPI** on `qupv3_se0_spi` (verified `spi0.0`/`NVT-ts`) |
| Touch reset / IRQ | GPIO 86 / GPIO 80 | GPIO 86 / GPIO 80 (same pins, different transport) |
| Touch power | AVDD GPIO 98 (SOUTH tile) | regulator, not the spes GPIO |
| RAM | 6 GB, 3 GiB selected above 4 GiB | 4 GB, **1 GiB** above 4 GiB (verified) |
| Splash | `0x5c000000`, `0xf00000` | `0x5c000000`, `0xf00000` (verified) |

The inherited `sweet_touch.c` is an I2C driver. Patch `0101` now adds a
separate fog path that drives the same file's novatek part over QUPv3 SE0 in
GENI **SPI** FIFO mode (below); the spes I2C path is untouched and
`st.fog` selects between them. Fog images still default to `sweettouch=0`,
and `FOG_TOUCH=1` (or the `touch` input of the `fog-image` workflow) turns the
SPI path on with `sweettouchdelay=5 sweettouchdiag=3`.

Stock and live DT facts for that work (`khaje-idp.dtsi`, included by
`fog.dtsi`; confirmed in the live FDT under `/soc/spi@4a80000/novatek@0`):

```
&qupv3_se0_spi {
    novatek@0 {
        compatible = "novatek,NVT-ts-spi", "focaltech,fts";
        spi-max-frequency = <0x927c00>;              /* 9.6 MHz */
        novatek,reset-gpio = <&tlmm 86 0>;
        novatek,irq-gpio = <&tlmm 80 8193>;          /* active low, rising */
        novatek,swrst-n8-addr = <0x3f0fe>;
        novatek,spi-rd-fast-addr = <0x3f310>;
        focaltech,max-touch-number = <10>;
        focaltech,display-coords = <0 0 0x2cf 0x671>; /* 720x1650 */
    };
};
```

`fog.dtsi` disables the I2C `synaptics_tcm@20` and `novatek@62` nodes on
`qupv3_se2_i2c`. The live digitizer is the SPI Novatek part, bound to the
`NVT-ts` driver (`/sys/bus/spi/devices/spi0.0`), so the new transport should
speak the Novatek SPI protocol (`swrst-n8` / fast-read registers above).

## Touch transport (implemented in `0101`, 2026-10-25)

`st.fog` (from `/fog-platform`) selects an SE0 path that never touches the
spes I2C code. The register and protocol facts below were checked against
Linux `spi-geni-qcom.c`, `qcom-geni-se.c`, `geni-se.h` and the vendor
`nt36xxx.c`, not recalled from memory.

- **Clocks**: GCC vote `0x7900c |= 0x7c0` (m_ahb, s_ahb, core, core_2x, SE0);
  SE0 RCG `0x1f148` with parent BI_TCXO (19.2 MHz) and CFG = 0 (mode 0, no
  divider); branch `0x1f144` bit 31 = halt. `SE_MCLK 0x48 = (2 << 4) | 1`
  divides that by 2 → **9.6 MHz** SPI, matching
  `spi-max-frequency = <0x927c00>`.
- **SE mode**: FIFO (`SE_DMA 0x258 = 0`), GSI events off (`0xe18 = 0`),
  `0xe1c = 0x4` (`GENI_M_IRQ_EN`), `SE_IRQ_EN 0x614` = done | errors |
  rx-wm | rx-last | tx-wm, CGC `0x28 |= 0x7f`, `0xe30 |= 0xf`, `0x24 = 0x7f`,
  `0x20 = 1`, `SE_CLK_SEL 0x7c = 0`. All status is polled; no GSI or DMA
  channel is allocated, so nothing else may own SE0 at the same time.
- **SPI framing**: `SE_SPI_TRANS_CFG 0x25c` clears `CS_TOGGLE`, so CS is
  driven per primary command; `SE_SPI_WORD_LEN 0x268 = 4`
  (bits_per_word − 4); 8-bit packing `0x260/0x264/0x284/0x288` =
  `0x0007f8fe`/`0x000ffefe`; byte granularity `0x254 = 0`. One FIFO entry
  carries four bytes, LSB first.
- **Read framing matches the vendor driver**: `CTP_SPI_READ` masks the
  address (`addr & 0x7f`), clocks `len + 1` bytes with a dummy byte after the
  address and copies `rbuf + 2` into `buf + 1`. The split-command version
  sends the masked address with `FRAGMENTATION` so CS stays asserted, then
  clocks `n + 1` bytes in an `RX_ONLY` command, making `rx[1]` the first
  valid byte. Page select is the vendor 3-byte write
  `0xFF, addr >> 15, addr >> 7`.
- **Page base**: `EVENT_BUF_ADDR` differs per NT36xxx variant, so
  `0x21c00` (NT36672A), `0x11a00`, `0x22d00` and `0x11e00` are probed by
  validating FWINFO at `+0x78` (`fw_ver + ~fw_ver == 0xFF`, plausible
  `abs_x_max`/`abs_y_max` in either byte order). Coordinates are scaled from
  the detected maxima to the 720x1650 panel before `sweet_hid_touch()`,
  which then applies the 1125x2436 logical scale itself.
- **Report frame**: 65 bytes of `EVENT_BUF_ADDR`; ten 6-byte records at
  `6*i`, `id = data[0] >> 3`, `type = data[0] & 7` (1 down, 2 move),
  `x = (data[1] << 4) | (data[3] >> 4)`,
  `y = (data[2] << 4) | (data[3] & 0xf)`.
- **Pins**: GPIO0-3 mux 1 (`qup0`), 6 mA, no pull; GPIO80 input, pull-up,
  8 mA, active low; GPIO86 output, pull-up, 8 mA, reset low 20 ms then a
  250 ms settle. Fog has no touch regulator node, unlike spes' AVDD GPIO.
- **Console**: `SWEET TOUCH: fog gcc ...`, `fog se0 fw/proto ...`,
  `fog pins ...`, `fog fwinfo page=... fw=...`, `fog novatek page=...`, then
  `fog frames=... errors=...` every 500 polls with `sweettouchdiag=3`;
  `sweettouchdiag=2` panics after ~30 s with the same counters plus raw
  bytes.

The driver stops instead of poking an unknown SE: it skips the probes when
`0x68` proto != 1 (no SPI firmware), `0x64` bit 0 is set (FIFO interface
disabled), or the SE reports busy / inherited FIFO data. Those prints are the
first thing to read on the handset.

## What is in this branch

- `tools/mkadt.py --device fog` (also `rain`, `wind` for this unit's image):
  - identity `xiaomi,fog`/`xiaomi,rain`/`xiaomi,wind` (+ `xiaomi,sweet`,
    `qcom,khaje`), synthetic chip ID, four Gold cores at 2.4 GHz,
    `/fog-platform` marker;
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
`modemst1`, `modemst2`, `persist`, `misc`, `splash` and your personal `/sdcard`
files. `persist` and `modem*` hold calibration/IMEI data that a factory ROM may
not restore. This board is A/B: the real nodes are `boot_a`/`boot_b`,
`dtbo_a`/`dtbo_b`, `modem_a`/`modem_b` and there is **no `recovery`**
partition, so the script adds the active slot suffix and keeps both slots of
every A/B partition. `super` is large; you can skip it if you keep the matching
official HyperOS fastboot package offline (anti-rollback: never flash older
firmware).

With root ADB on the running phone:

```sh
tools/backup-fog.sh                 # writes backup/fog-YYYYmmdd-HHMMSS/
tools/backup-fog.sh /path/to/backup
FOG_WITH_SDCARD=0 tools/backup-fog.sh   # partitions only
```

The script reads only, resolves slot suffixes, records `getprop`, the by-name
map and SHA-256 sums, and pulls `/sdcard`. `backup/` is git-ignored. A missing
partition is reported and makes the script exit 3, so a "successful" backup
can never silently omit `boot_a`. From a temporary recovery with root ADB the
same commands work (omit `su` if already root). Tested on the live rain unit
with `FOG_PARTITIONS="misc vbmeta modemst1 persist"`: it read `vbmeta_a` and
`vbmeta_b`, skipped an unknown name and exited 3.

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
adb shell getprop ro.product.device          # rain or fog
adb shell getprop ro.boot.hardware           # expect: qcom
adb shell 'cat /proc/meminfo | head -n 3'
adb shell 'dmesg | grep -i -E "cont_splash|memory@|reserved" | head -n 40'
```

Keep `dtb/` out of git. The FDT can contain the serial number.

The selection has already been verified on the 2026-10-22 dump: the live map
has one 1 GiB range above 4 GiB (`0x100000000`–`0x140000000`) with no
reservation inside it. Re-run this if the firmware changes:

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
layout (XNU must not map XPU carve-outs). If the splash base moves from
`0x5c000000`, build with `SHIM_FB_BASE=0x...` for the shim and edit the
`fog`/`rain` `fb` tuple in `tools/mkadt.py`.

## Build

XNU: run `.github/workflows/xnu.yml` on the `fog` branch (manual dispatch) or
download the `xnu-kernel` artifact from a `spes` run. The kernel patch set is
shared; no fog kernel patch exists yet, so any current spes kernel works for
the RAM-only diagnostic.

Shim: AArch64 GNU toolchain + AOSP `mkbootimg` (vendored in
`tools/vendor/mkbootimg`, Apache-2.0).

Easiest: dispatch **`fog-image`** and download the artifact. It runs on
`ubuntu-latest`, pulls the `xnu-kernel` artifact of the latest successful
`xnu` run on this branch (or the run ID you pass), builds the image and
uploads `<device>-diagnostic.img` + `.sha256`. No local toolchain needed.

```sh
# local build (Linux/macOS)
CROSS_COMPILE=aarch64-elf- MKBOOTIMG="$PWD/tools/vendor/mkbootimg/mkbootimg.py" \
  FOG_DEVICE=rain tools/build-fog-diagnostic.sh xnu/out/kernel.development.sweet probe/fog-live/fog-live.dtb
```

CI cannot read `probe/` (the live FDT holds the serial), so it passes the
verified range instead: `--memory-range 0x100000000:0x40000000`
(`FOG_MEMORY`). That produces byte-identical ADT output to the FDT path but is
only valid on the unit it was measured on.

Outputs `shim/out/<device>-diagnostic.img` + `.sha256`, using the 720x1650
shim console. Nothing is sent to the phone.

`FOG_CPUS=N` (1-4, default 1) sets the `cpus=N` boot arg. The ADT already
lists the four Gold cores (MPIDR `0x100`-`0x103`, three `stopped`), so N=4 only
changes the kernel side; the silver cluster stays parked either way.

For the full UI (only after a diagnostic success and a userdata iOS root):

```sh
# local build (Linux/macOS), live FDT path
CROSS_COMPILE=aarch64-elf- MKBOOTIMG="$PWD/tools/vendor/mkbootimg/mkbootimg.py" \
  FOG_DEVICE=rain tools/build-fog-ios.sh xnu/out/kernel.development.sweet probe/fog-live/fog-live.dtb

# without the live FDT (e.g. macOS with the IPSW and kernel artifact only)
CROSS_COMPILE=aarch64-elf- MKBOOTIMG="$PWD/tools/vendor/mkbootimg/mkbootimg.py" \
  FOG_DEVICE=rain FOG_MEMORY=0x100000000:0x40000000 \
  tools/build-fog-ios.sh xnu/out/kernel.development.sweet
```

`FOG_MEMORY` is the same verified range the CI diagnostic uses. The Mac
toolchain is `brew install messense/macos-cross-toolchains/aarch64-unknown-linux-gnu`
(`CROSS_COMPILE=aarch64-unknown-linux-gnu-`); `shim/build.sh` emulates
`truncate` when the host has none. `/product` comes from
`research/ipsw-x/d22ap.adt` when present; otherwise `mkadt` warns and the image
boots without the iPhone X identity.

## Test order (each step needs a user decision)

1. `fastboot boot shim/out/rain-diagnostic.img` — a temporary RAM boot. Expect
   the shim lines, then the kernel fbcon/PID 1 output on the 720x1650 panel.
   If the screen stays black, the splash base or panel geometry is wrong; the
   phone is still running Android and `fastboot reboot` recovers it. Nothing is
   written, so a full backup is only required before flashing.
2. Touch: `fastboot boot` the diagnostic image built with `touch=1`
   (`sweettouch=1 sweettouchdelay=5 sweettouchdiag=3`, panel 720x1650). Read
   the fog prints listed above. If `fog se0 fw` reports proto != 1 or
   `ifdis` bit 0, the bootloader left SE0 without SPI firmware — retry after
   one Android boot before considering a GSI/DMA rewrite.
3. Install the iOS root into `userdata` only with explicit approval and a
   verified backup. Then `build-fog-ios.sh`.
4. Display: patch `0100-sweet-fb-present-scale.patch` adds a resample in the
   present path (`sweetfb_scale=0|1|2`; the default on `/fog-platform` is fit)
   so the 1125x2436 logical canvas reaches all of the 720x1650 panel instead
   of a centre crop. It also makes `SweetHID` map contacts through the same
   scale using `sweetfb_panel_w/h`. Both are gated on `/fog-platform`, so
   spes/topaz behaviour is unchanged. `sweetfb_native=1` still hardcodes
   1080x2400 in `SweetHID` and must not be used on fog.

Do not flash `boot`, `vendor_boot`, `dtbo`, `vbmeta`, `persist` or `modem` for
bring-up. `fastboot boot` is enough.

## Open items

- Live FDT: RAM banks, reserved regions, real splash base, board revision.
- Touch: first handset boot of the SE0 GENI SPI path (rewrite of `0101`,
  2026-10-25); verify proto/FIFO/FWINFO prints, then coordinates and the
  720x1650 clamp, then multi-touch.
- Display: 720x1650 present/scaling and HID mapping (see step 4).
- Panel/backlight: ABL leaves the splash on; brightness control is untested.
- Keys/PMIC, UFS, GPU, Wi-Fi: inherited from spes patches but unverified on
  fog; keep `sweetkeys=0`, `sweethw=0` until each is tested.
- `wind`/`rain` differences (regulators, panel variant) are unconfirmed.
