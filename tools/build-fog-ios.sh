#!/bin/bash
# Host-only full iOS boot image builder for Xiaomi Redmi 10C (fog).
# Requires an iOS userdata root already present on the phone; never flashes.
#
#   tools/build-fog-ios.sh KERNEL LIVE_FDT [OUTPUT_NAME]
#   FOG_MEMORY=0x100000000:0x40000000 tools/build-fog-ios.sh KERNEL [OUTPUT_NAME]
#
# The second form is for hosts without the live FDT (it holds the serial), for
# example a Mac that only has the IPSW and the kernel artifact.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 3 ]]; then
    echo "usage: $0 KERNEL [LIVE_FDT|-] [OUTPUT_NAME]" >&2
    echo "   or: FOG_MEMORY=BASE:SIZE $0 KERNEL [OUTPUT_NAME]" >&2
    echo "  (FOG_DEVICE=fog|rain|wind, default fog)" >&2
    echo "  (FOG_TOUCH=1 enables the touch digitizer; panel is 720x1650)" >&2
    exit 2
fi
device=${FOG_DEVICE:-fog}
cpus=${FOG_CPUS:-1}
case $cpus in
    1|2|3|4) ;;
    *) echo "FOG_CPUS must be 1-4 (the ADT lists the four Gold cores)" >&2; exit 2 ;;
esac
# Panel pixels the digitizer reports in, for the framebuffer scale and the
# HID mapping (SweetFramebuffer.cpp / SweetHID.cpp, patch 0100).
panel_w=${FOG_PANEL_W:-720}
panel_h=${FOG_PANEL_H:-1650}
case ${FOG_TOUCH:-0} in
    1|true|yes)
        touch_args="sweettouch=1 sweetfb_panel_w=$panel_w sweetfb_panel_h=$panel_h"
        # Optional: shorten the 45 s start delay, or add the periodic stats print.
        if [ -n "${FOG_TOUCH_DELAY:-}" ]; then
            touch_args="$touch_args sweettouchdelay=$FOG_TOUCH_DELAY"
        fi
        if [ -n "${FOG_TOUCH_DIAG:-}" ]; then
            touch_args="$touch_args sweettouchdiag=$FOG_TOUCH_DIAG"
        fi ;;
    0|false|no) touch_args="sweettouch=0" ;;
    *) echo "FOG_TOUCH must be 0 or 1" >&2; exit 2 ;;
esac
name=${3:-$device-ios}
kernel=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1")
[ -f "$kernel" ] || { echo "Kernel missing: $1" >&2; exit 1; }
if [ -n "${2:-}" ] && [ "$2" != - ]; then
    fdt=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$2")
    [ -f "$fdt" ] || { echo "live FDT missing: $2" >&2; exit 1; }
    memory_args="--memory-dtb $fdt"
elif [ -n "${FOG_MEMORY:-}" ]; then
    memory_args="--memory-range $FOG_MEMORY"
else
    echo 'Pass LIVE_FDT, or set FOG_MEMORY=BASE:SIZE from the verified live map' >&2
    exit 2
fi
cd "$(dirname "$0")/.."
mkdir -p shim/out
python3 tools/mkadt.py "shim/out/$name.adt" --device "$device" $memory_args
# The panel is 720x1650 but iOS renders into a 1125x2436 logical canvas, so
# the framebuffer resamples (sweetfb_scale default on /fog-platform) and the
# HID layer maps contacts through the same scale. sweettouch stays off unless
# FOG_TOUCH=1; the fog path drives the Novatek part over QUPv3 SE0 GENI SPI
# (patch 0101), not the inherited spes I2C code.
python3 tools/mkpayload.py "$kernel" "shim/out/$name.adt" "shim/out/$name.payload" \
    --cmdline 'debug=0xc serial=3 cpus='"$cpus"' keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 ufsroot=userdata unentitled_ios_sim_launch=1 ignition_level=1 launchd_unsecure_cache=1 wdt_test=no_user_checkin wdt=-1 ufsrw=1 rootrw=1 sweetlog=1 ufslogsecs=10 '"$touch_args"' sweetkeys=0 sweethw=0 sweetfb_stayon=1 sweetfb_noconsole=1'
SHIM_FB_W=$panel_w SHIM_FB_H=$panel_h BOOT_HEADER_VERSION=3 shim/build.sh "out/$name.payload"
cp shim/out/shim-boot.img "shim/out/$name.img"
if command -v shasum >/dev/null; then
    shasum -a 256 "shim/out/$name.img" > "shim/out/$name.img.sha256"
else
    sha256sum "shim/out/$name.img" > "shim/out/$name.img.sha256"
fi
echo "Built shim/out/$name.img (${cpus}x Gold CPU, UFS root, ${panel_w}x${panel_h} panel, touch ${FOG_TOUCH:-0}); nothing sent to phone."
