#!/bin/bash
# Build an entirely RAM-backed XNU/PID-1 diagnostic image for the fog base
# (fog / rain / wind). Never flashes a phone: boot it with `fastboot boot`.
#
#   tools/build-fog-diagnostic.sh KERNEL LIVE_FDT
#   FOG_MEMORY=0x100000000:0x40000000 tools/build-fog-diagnostic.sh KERNEL
#   FOG_CPUS=4 ... (default 1; the ADT declares the four Gold cores)
#
# The second form is for CI, where the live FDT cannot be committed (it holds
# the serial): FOG_MEMORY must be the range select_memory() picked on the
# handset, and the resulting image is only valid for that unit.
set -euo pipefail
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: $0 KERNEL LIVE_FDT   (FOG_DEVICE=fog|rain|wind, default fog)" >&2
    echo "   or: FOG_MEMORY=BASE:SIZE $0 KERNEL" >&2
    echo "  (FOG_TOUCH=1 enables the fog QUPv3 SE0 SPI digitizer, see docs/FOG-PORT.md)" >&2
    exit 2
fi
device=${FOG_DEVICE:-fog}
cpus=${FOG_CPUS:-1}
case $cpus in
    1|2|3|4) ;;
    *) echo "FOG_CPUS must be 1-4 (the ADT lists the four Gold cores)" >&2; exit 2 ;;
esac
# Panel pixels; matches the SHIM_FB_* geometry below (720x1650 on khaje).
panel_w=${FOG_PANEL_W:-720}
panel_h=${FOG_PANEL_H:-1650}
# The shim has no GUI to drive, so the diagnostic run proves the driver by its
# console prints: delay keeps the log readable, diag=3 prints frames/contacts.
case ${FOG_TOUCH:-0} in
    1|true|yes)
        touch_args="sweettouch=1 sweettouchdelay=${FOG_TOUCH_DELAY:-5}"
        touch_args="$touch_args sweettouchdiag=${FOG_TOUCH_DIAG:-3}"
        touch_args="$touch_args sweetfb_panel_w=$panel_w sweetfb_panel_h=$panel_h" ;;
    0|false|no) touch_args="sweettouch=0" ;;
    *) echo "FOG_TOUCH must be 0 or 1" >&2; exit 2 ;;
esac
name=$device-diagnostic
kernel=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1")
[ -f "$kernel" ] || { echo "Kernel missing: $1" >&2; exit 1; }
if [ -n "${2:-}" ] && [ "$2" != - ]; then
    live_fdt=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$2")
    [ -f "$live_fdt" ] || { echo "live FDT missing: $2" >&2; exit 1; }
    memory_args="--memory-dtb $live_fdt"
elif [ -n "${FOG_MEMORY:-}" ]; then
    memory_args="--memory-range $FOG_MEMORY"
else
    echo 'Pass LIVE_FDT, or set FOG_MEMORY=BASE:SIZE from the verified live map' >&2
    exit 2
fi
cd "$(dirname "$0")/.."
mkdir -p shim/out
python3 tools/mkadt.py "shim/out/$name.adt" --device "$device" $memory_args
clang -target arm64-apple-ios16.0 -mcpu=cortex-a53 -c tools/sweet-init.S -o shim/out/fog-init.o
python3 tools/mkinit.py shim/out/fog-init.o shim/out/fog-init
python3 tools/mkpayload.py "$kernel" "shim/out/$name.adt" "shim/out/$name.payload" \
    --ramdisk shim/out/fog-init \
    --cmdline "debug=0xc serial=3 cpus=$cpus keepsyms=1 -enable_kprintf_spam -noprogress rd=md0 ufsrw=0 rootrw=0 sweetlog=0 $touch_args sweetkeys=0 sweethw=0 sweetfb_stayon=1"
# The shim console and the boot_args Video use the 720x1650 splash geometry.
SHIM_FB_W=$panel_w SHIM_FB_H=$panel_h BOOT_HEADER_VERSION=3 shim/build.sh "out/$name.payload"
cp shim/out/shim-boot.img "shim/out/$name.img"
if command -v shasum >/dev/null; then
    shasum -a 256 "shim/out/$name.img" > "shim/out/$name.img.sha256"
else
    sha256sum "shim/out/$name.img" > "shim/out/$name.img.sha256"
fi
printf '%s\n' "Built shim/out/$name.img; nothing sent to the phone."
