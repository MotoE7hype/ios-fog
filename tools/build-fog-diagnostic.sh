#!/bin/bash
# Build an entirely RAM-backed XNU/PID-1 diagnostic image for Redmi 10C (fog).
# Never flashes a phone: boot it with `fastboot boot`.
set -euo pipefail
if [ "$#" -ne 2 ]; then
    echo "usage: $0 KERNEL LIVE_FDT   (FOG_DEVICE=fog|rain, default fog)" >&2
    echo "  (fog hardware probes are not implemented yet; touch is SPI, see docs/FOG-PORT.md)" >&2
    exit 2
fi
device=${FOG_DEVICE:-fog}
name=$device-diagnostic
kernel=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1")
live_fdt=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$2")
cd "$(dirname "$0")/.."
[ -f "$kernel" ] && [ -f "$live_fdt" ] || { echo 'Kernel or live FDT missing' >&2; exit 1; }
mkdir -p shim/out
python3 tools/mkadt.py "shim/out/$name.adt" --device "$device" --memory-dtb "$live_fdt"
clang -target arm64-apple-ios16.0 -mcpu=cortex-a53 -c tools/sweet-init.S -o shim/out/fog-init.o
python3 tools/mkinit.py shim/out/fog-init.o shim/out/fog-init
python3 tools/mkpayload.py "$kernel" "shim/out/$name.adt" "shim/out/$name.payload" \
    --ramdisk shim/out/fog-init \
    --cmdline "debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=md0 ufsrw=0 rootrw=0 sweetlog=0 sweettouch=0 sweetkeys=0 sweethw=0 sweetfb_stayon=1"
# The shim console and the boot_args Video use the fog 720x1650 splash geometry.
SHIM_FB_W=720 SHIM_FB_H=1650 BOOT_HEADER_VERSION=3 shim/build.sh "out/$name.payload"
cp shim/out/shim-boot.img "shim/out/$name.img"
shasum -a 256 "shim/out/$name.img" > "shim/out/$name.img.sha256"
printf '%s\n' "Built shim/out/$name.img; nothing sent to the phone."
