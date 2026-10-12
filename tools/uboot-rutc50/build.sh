#!/bin/bash
# Bootloader of the Teltonika RUTC50 preset: OpenWrt has no own bootloader
# for the RUTC50 (the Teltonika one passes ubi.mtd=rutos-a), and the OpenWrt
# MT7981 SPI-NOR U-Boot builds lack the "ubi" command (RFB) or boot only
# the NOR (OpenWrt One).  This builds OpenWrt's U-Boot (src/u-boot +
# OpenWrt's uboot-mediatek patches) with mt7981_teltonika_rutc50_defconfig
# (the RFB SPI-NOR config + UBI, the RUTC50 flash layout, an environment
# that boots rutos-a) and puts it into the BL31 + U-Boot FIP of the OpenWrt
# mt7981-rfb SPI-NAND build (the BL31 does not depend on the boot media).
#
#   tools/uboot-rutc50/build.sh [OUT.fip]
#
#   default OUT: tools/uboot-rutc50/teltonika_rutc50-nor-bl31-uboot.fip
#   CROSS_COMPILE (default aarch64-linux-gnu-), OPENWRT (default 25.12.5:
#   release of the BL31)
set -e
cd "$(dirname "$(readlink -f "$0")")/../.."
ROOT=$PWD
HERE=$ROOT/tools/uboot-rutc50
OUT=$(readlink -f "${1:-$HERE/teltonika_rutc50-nor-bl31-uboot.fip}")
OPENWRT=${OPENWRT:-25.12.5}
export CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
VER=$(sed -n 's/^PKG_VERSION:=//p' src/openwrt/package/boot/uboot-mediatek/Makefile)
SRC=$ROOT/work/uboot-rutc50
BL31FIP=$ROOT/work/rfb-spim-nand-bl31-uboot-$OPENWRT.fip

if [ ! -d "$SRC" ]; then
    git -C src/u-boot worktree add --detach "$SRC" "v$VER"
    for p in src/openwrt/package/boot/uboot-mediatek/patches/*.patch; do
        patch -d "$SRC" -p1 -s --no-backup-if-mismatch < "$p"
    done
fi
cp "$HERE/mt7981-teltonika-rutc50.dts" "$SRC/arch/arm/dts/"
cp "$HERE/mt7981_teltonika_rutc50_defconfig" "$SRC/configs/"
mkdir -p "$SRC/defenvs"
cp "$HERE/teltonika_rutc50_env" "$SRC/defenvs/"
grep -q mt7981-teltonika-rutc50.dtb "$SRC/arch/arm/dts/Makefile" ||
    sed -i 's/^\tmt7981-rfb.dtb \\/&\n\tmt7981-teltonika-rutc50.dtb \\/' \
        "$SRC/arch/arm/dts/Makefile"
make -C "$SRC" -s mt7981_teltonika_rutc50_defconfig
make -C "$SRC" -s -j"$(nproc)" u-boot.bin

[ -s "$BL31FIP" ] || wget -q -O "$BL31FIP" \
    "https://downloads.openwrt.org/releases/$OPENWRT/targets/mediatek/filogic/openwrt-$OPENWRT-mediatek-filogic-mediatek_mt7981-rfb-spim-nand-bl31-uboot.fip"
python3 - "$BL31FIP" "$SRC/u-boot.bin" "$OUT" <<'EOF'
# FIP (TF-A firmware image package): keep the BL31, U-Boot as BL33
import struct, sys, uuid
fip = open(sys.argv[1], "rb").read()
BL31 = uuid.UUID("47d4086d-4cfe-9846-9b95-2950cbbd5a00").bytes
BL33 = uuid.UUID("d6d0eea7-fcea-d54b-9782-9934f234b6e4").bytes
if struct.unpack_from("<I", fip)[0] != 0xAA640001:
    sys.exit("not a FIP: " + sys.argv[1])
ents, o = {}, 16
while fip[o:o + 16] != bytes(16):
    off, size, flags = struct.unpack_from("<QQQ", fip, o + 16)
    ents[fip[o:o + 16]] = fip[off:off + size]
    o += 40
if BL31 not in ents:
    sys.exit("no BL31 in " + sys.argv[1])
imgs = [(BL31, ents[BL31]), (BL33, open(sys.argv[2], "rb").read())]
hdr = fip[:16]
off = 16 + 40 * (len(imgs) + 1)
body = b""
for u, d in imgs:
    hdr += u + struct.pack("<QQQ", off + len(body), len(d), 0)
    body += d + bytes(-len(d) % 16)
hdr += bytes(16) + struct.pack("<QQQ", off + len(body), 0, 0)
open(sys.argv[3], "wb").write(hdr + body)
print("wrote %s (%d bytes)" % (sys.argv[3], len(hdr + body)))
EOF
