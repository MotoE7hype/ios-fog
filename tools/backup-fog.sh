#!/bin/bash
# Back up the fog partitions that a bad boot/flash could otherwise destroy.
# Reads only; writes to backup/ (git-ignored because modem/persist hold IMEI
# and calibration data). Requires root ADB (`adb root`, `su`, or a recovery).
set -euo pipefail
out=${1:-backup/fog-$(date +%Y%m%d-%H%M%S)}
parts=${FOG_PARTITIONS:-boot vendor_boot dtbo vbmeta vbmeta_system vbmeta_vendor recovery misc modem fsg modemst1 modemst2 persist}
command -v adb >/dev/null || { echo 'adb not found' >&2; exit 1; }
adb get-state >/dev/null 2>&1 || { echo 'no adb device; enable USB debugging and authorize it' >&2; exit 1; }
# Root ADB (adb root/userdebug) needs no su; otherwise use su -c. exec-out is
# required because adb shell would translate LF to CRLF in the dump.
if [ "$(adb shell id -u 2>/dev/null | tr -d '\r')" = 0 ]; then
    as_root() { adb exec-out sh -c "$1"; }
else
    as_root() { adb exec-out su -c "$1"; }
fi
mkdir -p "$out"
adb shell getprop > "$out/getprop.txt" 2>&1 || true
adb shell 'ls -l /dev/block/by-name' > "$out/by-name.txt" 2>&1 || true
echo "device: $(adb shell getprop ro.product.device | tr -d '\r')  soc: $(adb shell getprop ro.soc.model | tr -d '\r')"
echo "writing $out"
for p in $parts; do
    if ! adb shell "test -e /dev/block/by-name/$p" 2>/dev/null; then
        echo "skip $p (no such partition)"
        continue
    fi
    echo "read $p"
    if ! as_root "dd if=/dev/block/by-name/$p bs=1M 2>/dev/null" > "$out/$p.img"; then
        echo "FAILED $p" >&2
        rm -f "$out/$p.img"
        continue
    fi
    [ -s "$out/$p.img" ] || { echo "empty $p" >&2; rm -f "$out/$p.img"; }
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
cat > "$out/README.txt" <<'EOF'
fog partition backup. Contains IMEI/calibration (modemst*, fsg, persist) and
personal files. Do not commit or upload. Restore only the specific partition
you are repairing, with the same firmware version (anti-rollback).
EOF
ls -lh "$out"
