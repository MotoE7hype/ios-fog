#!/bin/bash
# Collect the live-device facts the fog port still guesses at, without
# changing anything on the phone. Read-only: meminfo, cmdline, the live FDT,
# SPI/panel/backlight sysfs and the bootloader's own view of the partitions.
# Output goes to probe/ (git-ignored: the live FDT and cmdline hold the serial).
#
#   tools/fog-probe.sh [outdir]
#
# Run it on the phone's normal Android boot, USB debugging authorized, before
# building any fog image. Send back the printed summary plus the directory.
# Almost every file below is root-only on a release build, so root ADB (or
# Magisk `su`) is effectively required; without it the script still runs and
# reports what it could not read.
set -u

out=${1:-probe/fog-$(date +%Y%m%d-%H%M%S)}
command -v adb >/dev/null || { echo 'adb not found' >&2; exit 1; }
adb get-state >/dev/null 2>&1 || { echo 'no adb device; enable USB debugging and authorize it' >&2; exit 1; }
mkdir -p "$out"

root=0
use_su=0
if [ "$(adb shell id -u 2>/dev/null | tr -d '\r')" = 0 ]; then
    root=1
elif adb shell su -c id >/dev/null 2>&1; then
    root=1
    use_su=1
fi
run() { # remote command, as root when possible
    if [ "$use_su" = 1 ]; then
        adb exec-out su -c "$1"
    else
        adb exec-out sh -c "$1"
    fi
}
# Text capture; adb shell translates LF to CRLF, so strip CR afterwards.
text() { run "$2" 2>/dev/null | tr -d '\r' > "$out/$1" || echo "FAILED $1" >&2; }
# Binary capture: adb shell would corrupt it, and a failed `cat` must not be
# left behind as a plausible-looking file.
blob() { # name, device path
    if ! run "test -s $2" >/dev/null 2>&1; then
        echo "skip $1 (missing or empty: $2)" >&2
        return 0
    fi
    run "cat $2" > "$out/$1" 2>/dev/null || { echo "FAILED $1" >&2; rm -f "$out/$1"; }
}

echo "== identity (root=$root)"
text getprop.txt getprop
text cmdline.txt 'cat /proc/cmdline'
text meminfo.txt 'cat /proc/meminfo'
text iomem.txt 'cat /proc/iomem'
text mounts.txt mount
text partitions.txt 'ls -l /dev/block/by-name'
text partition-sizes.txt 'for p in /dev/block/by-name/*; do printf "%s %s\n" "$(basename $p)" "$(blockdev --getsize64 $p 2>/dev/null)"; done'
text spi-devices.txt 'for d in /sys/bus/spi/devices/*; do echo "== $d $(cat $d/modalias 2>/dev/null) driver=$(basename $(readlink -f $d/driver 2>/dev/null))"; ls $d | tr "\n" " "; echo; done'
text spi-drivers.txt 'ls /sys/bus/spi/drivers'
text input-devices.txt 'cat /proc/bus/input/devices'
text drm.txt 'for d in /sys/class/drm/*; do echo "== $d"; for f in status enabled modes; do [ -f $d/$f ] && { echo "-- $f"; cat $d/$f; }; done; done'
text backlight.txt 'for b in /sys/class/backlight/*; do echo "== $b"; for f in max_brightness actual_brightness brightness type; do [ -f $b/$f ] && echo "$f=$(cat $b/$f)"; done; done'
text panel-props.txt 'getprop | grep -iE "panel|lcd|density|resolution|display|fpsensor"'

echo "== root-only"
text dmesg.txt dmesg
text dmesg-grep.txt "dmesg | grep -iE 'memory:|reserved|splash|novatek|focaltech|NVT|touch|dsi|panel|ufs|board-id|khaje'"
text device-tree.txt 'for f in model compatible qcom,board-id qcom,msm-id; do echo "== $f"; tr "\0" "\n" < /proc/device-tree/$f 2>/dev/null; done'
blob fog-live.dtb /sys/firmware/fdt
# The active slot's dtbo carries the panel/touch overlays; keep it beside the
# FDT for the patched kernel's DT work. Read-only, stays in the ignored dir.
slot=$(adb shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r')
blob "dtbo${slot:-_a}.img" "/dev/block/by-name/dtbo${slot:-_a}"

echo
echo "== summary"
for p in ro.product.device ro.product.model ro.boot.hardware ro.board.platform \
         ro.soc.model ro.build.fingerprint ro.boot.dtbo_idx ro.boot.hwlevel; do
    printf '%-24s %s\n' "$p" "$(adb shell getprop $p 2>/dev/null | tr -d '\r')"
done
awk '/MemTotal|MemAvailable/ {printf "%-16s %s %s\n", $1, $2, $3}' "$out/meminfo.txt" 2>/dev/null
echo "slot:     ${slot:-_a}"
echo "fdt:      $(wc -c < "$out/fog-live.dtb" 2>/dev/null || echo 0) bytes"
echo "dtbo:     $(wc -c < "$out/dtbo${slot:-_a}.img" 2>/dev/null || echo 0) bytes"
echo "touch:    $(grep -oiE 'novatek[a-z0-9,_-]*|focaltech[a-z0-9,_-]*|synaptics[a-z0-9,_-]*' "$out/dmesg-grep.txt" 2>/dev/null | sort -u | tr '\n' ' ')"
echo "panel:    $(grep -oiE 'lcmtype=[a-z0-9_]+|dsi_display[0-9]+=[a-z0-9,._-]+' "$out/cmdline.txt" 2>/dev/null | tr '\n' ' ')"
echo "written:  $out"
echo
echo 'Next, on the build host (needs the dtb package for mkadt):'
echo "  python3 tools/mkadt.py shim/out/fog.adt --device fog --memory-dtb $out/fog-live.dtb"
