#!/bin/bash
# The kernel's MediaTek device trees as OpenWrt builds them: the DTS of
# src/linux with the DTS parts of OpenWrt's target patches applied, in
# work/kdts/arch/arm64/boot/dts/mediatek.  tools/dts-leds.py reads boards
# whose DTS is in the kernel tree (DEVICE_DTS_DIR := $(DTS_DIR), e.g. the
# Bananapi BPi-R4) from there.
#
#   tools/kernel-dts.sh [KERNEL] [OPENWRT]   (default src/linux, src/openwrt)
set -e
cd "$(dirname "$(readlink -f "$0")")/.."
K=${1:-src/linux}; O=${2:-src/openwrt}
OUT=work/kdts
rm -rf "$OUT" && mkdir -p "$OUT/arch/arm64/boot/dts"
cp -r "$K/arch/arm64/boot/dts/mediatek" "$OUT/arch/arm64/boot/dts/"
ver=$(sed -n 's/^KERNEL_PATCHVER:=//p' "$O/target/linux/mediatek/Makefile")
ok=0; bad=0
for p in "$O"/target/linux/mediatek/patches-"$ver"/*.patch; do
    grep -q '^+++ b/arch/arm64/boot/dts/mediatek/' "$p" || continue
    # only the hunks of files under arch/arm64/boot/dts/mediatek
    python3 - "$p" > "$OUT/dts.patch" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read()
for part in re.split(r'(?m)^(?=--- (?:a/|/dev/null))', t):
    m = re.search(r'(?m)^\+\+\+ b/(\S+)', part)
    if m and m.group(1).startswith("arch/arm64/boot/dts/mediatek/"):
        sys.stdout.write(re.split(r'(?m)^(?=diff --git )', part)[0])
PY
    if (cd "$OUT" && patch -p1 -s -N --no-backup-if-mismatch < dts.patch >/dev/null 2>&1); then
        ok=$((ok + 1))
    else
        bad=$((bad + 1)); echo "not applied: $(basename "$p")" >&2
    fi
done
rm -f "$OUT/dts.patch"
echo "$OUT: kernel DTS + $ok OpenWrt patches ($bad not applied)"
