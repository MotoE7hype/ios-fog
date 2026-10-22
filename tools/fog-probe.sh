#!/bin/bash
# Collect the live-device facts the fog port still guesses at, without
# changing anything on the phone. Read-only: meminfo, cmdline, the live FDT,
# SPI/panel/backlight sysfs and the bootloader's own view of the partitions.
# Output goes to probe/ (git-ignored: the live FDT contains the serial).
#
#   tools/fog-probe.sh [outdir]
#
# Run it on the phone's normal Android boot, USB debugging authorized, before
# building any fog image. Send back the printed summary plus the directory.
set -u

out=${1:-probe/fog-$(date +%Y%m%d-%H%M%S)}
command -v adb >/dev/null || { echo 'adb not found' >&2; exit 1; }
adb get-state >/dev/null 2>&1 || { echo 'no adb device; enable USB debugging and authorize it' >&2; exit 1; }

# Root is needed for the FDT and for dmesg on a user build.
if [ "$(adb shell id -u 2>/dev/null | tr -d '\r')" = 0 ]; then
    as_root() { adb exec-out sh -c "$1"; }
else
    as_root() { adb exec-out su -c "$1"; }
fi
mkdir -p "$out"

# Text capture. adb shell translates LF to CRLF, so strip CR afterwards.
text() { # name, remote command
    adb shell "$2" 2>/dev/null | tr -d '\r' > "$out/$1" || echo "FAILED $1" >&2
}
root_text() {
    as_root "$2" 2>/dev/null | tr -d '\r' > "$out/$1" || echo "FAILED $1" >&2
}
# Binary capture; adb shell would corrupt it.
blob() {
    as_root "cat $2" > "$out/$1" 2>/dev/null || { echo "FAILED $1" >&2; rm -f "$out/$1"; }
}

echo "== identity"
text getprop.txt getprop
text cmdline.txt 'cat /proc/cmdline'
text meminfo.txt 'cat /proc/meminfo'
text iomem.txt 'cat /proc/iomem'
text mounts.txt 'mount'
text partitions.txt 'ls -l /dev/block/by-name'
text partition-sizes.txt 'for p in /dev/block/by-name/*; do printf "%s %s\n" "$(basename $p)" "$(blockdev --getsize64 $p 2>/dev/null)"; done'
text spi-devices.txt 'for d in /sys/bus/spi/devices/*; do echo "$d $(cat $d/modalias 2>/dev/null)"; done'
text spi-drivers.txt 'ls /sys/bus/spi/drivers'
text input-devices.txt 'cat /proc/bus/input/devices'
text drm.txt 'for d in /sys/class/drm/*; do echo "== $d"; cat $d/status 2>/dev/null; cat $d/modes 2>/dev/null; done'
text backlight.txt 'for b in /sys/class/backlight/*; do echo "== $b"; cat $b/max_brightness 2>/dev/null; cat $b/actual_brightness 2>/dev/null; done'
text fb.txt 'cat /sys/class/graphics/fb0/virtual_size /sys/class/graphics/fb0/stride /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null'

echo "== root-only"
root_text dmesg.txt 'dmesg'
root_text dmesg-grep.txt "dmesg | grep -iE 'memory|reserved|splash|cont_splash|novatek|focaltech|NVT|touch|dsi|panel|ufs|qcom,board|khaje'"
root_text device-tree.txt 'ls -l /proc/device-tree; for f in model compatible serial-number qcom,board-id qcom,msm-id; do echo "== $f"; tr "\0" "\n" < /proc/device-tree/$f 2>/dev/null; done'
blob fog-live.dtb /sys/firmware/fdt
# dtbo carries the panel/touch overlays; keep it beside the FDT for the
# patched kernel's DT work. Read-only and stays in the ignored probe/ dir.
blob dtbo.img /dev/block/by-name/dtbo

echo
echo "== summary"
for p in ro.product.device ro.product.model ro.boot.hardware ro.board.platform \
         ro.soc.model ro.build.fingerprint ro.boot.dtbo_idx ro.boot.hwlevel; do
    printf '%-24s %s\n' "$p" "$(adb shell getprop $p 2>/dev/null | tr -d '\r')"
done
awk '/MemTotal|MemAvailable/ {printf "%-16s %s %s\n", $1, $2, $3}' "$out/meminfo.txt" 2>/dev/null
echo "fdt:      $(wc -c < "$out/fog-live.dtb" 2>/dev/null || echo missing) bytes"
echo "dtbo:     $(wc -c < "$out/dtbo.img" 2>/dev/null || echo missing) bytes"
echo "touch:    $(grep -oiE 'novatek[a-z0-9,_-]*|focaltech[a-z0-9,_-]*|synaptics[a-z0-9,_-]*' "$out/dmesg-grep.txt" 2>/dev/null | sort -u | tr '\n' ' ')"
echo "written:  $out"
echo
echo 'Next, on the build host (needs the dtb package for mkadt):'
echo "  python3 tools/mkadt.py shim/out/fog.adt --device fog --memory-dtb $out/fog-live.dtb"
