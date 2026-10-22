#!/bin/bash
# Host-only full iOS boot image builder for Xiaomi Redmi 10C (fog).
# Requires an iOS userdata root already present on the phone; never flashes.
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "usage: $0 KERNEL LIVE_FDT [OUTPUT_NAME]   (FOG_DEVICE=fog|rain|wind, default fog)" >&2
    exit 2
fi
device=${FOG_DEVICE:-fog}
name=${3:-$device-ios}
kernel=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1")
fdt=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$2")
cd "$(dirname "$0")/.."
[[ -f "$kernel" && -f "$fdt" ]] || { echo 'Kernel or live FDT missing' >&2; exit 1; }
mkdir -p shim/out
python3 tools/mkadt.py "shim/out/$name.adt" --device "$device" --memory-dtb "$fdt"
# First bring-up uses one Gold CPU. Touch is not ported to fog yet (SPI
# Novatek/FocalTech, not spes' I2C part), so it stays off until the diagnostic
# boot confirms the display and the input controller.
python3 tools/mkpayload.py "$kernel" "shim/out/$name.adt" "shim/out/$name.payload" \
    --cmdline 'debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 ufsroot=userdata unentitled_ios_sim_launch=1 ignition_level=1 launchd_unsecure_cache=1 wdt_test=no_user_checkin wdt=-1 ufsrw=1 rootrw=1 sweetlog=1 ufslogsecs=10 sweettouch=0 sweetkeys=0 sweethw=0 sweetfb_stayon=1 sweetfb_noconsole=1'
SHIM_FB_W=720 SHIM_FB_H=1650 BOOT_HEADER_VERSION=3 shim/build.sh "out/$name.payload"
cp shim/out/shim-boot.img "shim/out/$name.img"
shasum -a 256 "shim/out/$name.img" > "shim/out/$name.img.sha256"
echo "Built shim/out/$name.img (1x Gold CPU, UFS root); nothing sent to phone."
