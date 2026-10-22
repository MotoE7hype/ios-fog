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
    exit 2
fi
device=${FOG_DEVICE:-fog}
cpus=${FOG_CPUS:-1}
case $cpus in
    1|2|3|4) ;;
    *) echo "FOG_CPUS must be 1-4 (the ADT lists the four Gold cores)" >&2; exit 2 ;;
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
# First bring-up uses one Gold CPU. Touch is not ported to fog yet (SPI
# Novatek/FocalTech, not spes' I2C part), so it stays off until the diagnostic
# boot confirms the display and the input controller.
python3 tools/mkpayload.py "$kernel" "shim/out/$name.adt" "shim/out/$name.payload" \
    --cmdline 'debug=0xc serial=3 cpus='"$cpus"' keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 ufsroot=userdata unentitled_ios_sim_launch=1 ignition_level=1 launchd_unsecure_cache=1 wdt_test=no_user_checkin wdt=-1 ufsrw=1 rootrw=1 sweetlog=1 ufslogsecs=10 sweettouch=0 sweetkeys=0 sweethw=0 sweetfb_stayon=1 sweetfb_noconsole=1'
SHIM_FB_W=720 SHIM_FB_H=1650 BOOT_HEADER_VERSION=3 shim/build.sh "out/$name.payload"
cp shim/out/shim-boot.img "shim/out/$name.img"
if command -v shasum >/dev/null; then
    shasum -a 256 "shim/out/$name.img" > "shim/out/$name.img.sha256"
else
    sha256sum "shim/out/$name.img" > "shim/out/$name.img.sha256"
fi
echo "Built shim/out/$name.img (${cpus}x Gold CPU, UFS root); nothing sent to phone."
