#!/bin/bash
# Back up the fog/rain partitions that a bad boot/flash could otherwise
# destroy. Reads only; writes to backup/ (git-ignored because modem/persist
# hold IMEI and calibration data). Requires root ADB (`adb root`, `su`, or a
# recovery).
#
# These phones are A/B: the real nodes are boot_a, dtbo_a, modem_a ... and
# there is no `recovery` partition. Pass bare names below; the script adds the
# active slot's suffix when by-name has no unsuffixed node.
set -euo pipefail
out=${1:-backup/fog-$(date +%Y%m%d-%H%M%S)}
parts=${FOG_PARTITIONS:-boot vendor_boot dtbo vbmeta vbmeta_system misc modem fsg modemst1 modemst2 persist splash}
command -v adb >/dev/null || { echo 'adb not found' >&2; exit 1; }
adb get-state >/dev/null 2>&1 || { echo 'no adb device; enable USB debugging and authorize it' >&2; exit 1; }
# Root ADB (adb root/userdebug) needs no su; otherwise use su -c. exec-out is
# required because adb shell would translate LF to CRLF in the dump.
if [ "$(adb shell id -u 2>/dev/null | tr -d '\r')" = 0 ]; then
    as_root() { adb exec-out sh -c "$1"; }
else
    as_root() { adb exec-out su -c "$1"; }
fi
slot=$(adb shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r')
mkdir -p "$out"
adb shell getprop > "$out/getprop.txt" 2>&1 || true
adb shell 'ls -l /dev/block/by-name' > "$out/by-name.txt" 2>&1 || true
echo "device: $(adb shell getprop ro.product.device | tr -d '\r')  soc: $(adb shell getprop ro.soc.model | tr -d '\r')  slot: ${slot:-none}"
echo "writing $out"
unresolved=
read_part() { # node
    echo "read $1"
    if ! as_root "dd if=/dev/block/by-name/$1 bs=1M 2>/dev/null" > "$out/$1.img"; then
        echo "FAILED $1" >&2
        rm -f "$out/$1.img"
        unresolved="$unresolved $1"
        return 1
    fi
    [ -s "$out/$1.img" ] || { echo "empty $1" >&2; rm -f "$out/$1.img"; unresolved="$unresolved $1"; }
}
exists() { adb shell "test -e /dev/block/by-name/$1" 2>/dev/null; }
other_slot=_b
[ "$slot" = _b ] && other_slot=_a
for p in $parts; do
    if exists "$p"; then
        read_part "$p" || true
    elif [ -n "$slot" ] && exists "$p$slot"; then
        # A/B partition: keep both slots' copies, not just the active one.
        read_part "$p$slot" || true
        if exists "$p$other_slot"; then read_part "$p$other_slot" || true; fi
    else
        echo "skip $p (not in /dev/block/by-name)"
        unresolved="$unresolved $p"
    fi
done
# Personal data, not the whole (usually mostly empty) userdata partition.
if [ "${FOG_WITH_SDCARD:-1}" = 1 ]; then
    echo 'read /sdcard (personal files; can be large)'
    adb pull /sdcard "$out/sdcard" >/dev/null 2>&1 || echo 'sdcard pull failed or denied'
fi
if command -v sha256sum >/dev/null; then
    (cd "$out" && sha256sum *.img > SHA256SUMS 2>/dev/null || true)
else
    (cd "$out" && shasum -a 256 *.img > SHA256SUMS 2>/dev/null || true)
fi
cat > "$out/README.txt" <<EOF
fog/rain partition backup (slot ${slot:-none}). Contains IMEI/calibration
(modemst*, fsg, persist) and personal files. Do not commit or upload. Restore
only the specific partition you are repairing, with the same firmware version
(anti-rollback).
Unresolved partitions:${unresolved:- none}
EOF
ls -lh "$out"
if [ -n "$unresolved" ]; then
    echo "warning: could not read:$unresolved" >&2
    echo 'check README.txt and by-name.txt before trusting this backup' >&2
    exit 3
fi
