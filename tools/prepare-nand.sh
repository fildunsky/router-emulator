#!/bin/bash
# Download official OpenWrt images for an MT7981 or MT7986 device and build a
# NAND folder for the emulator.
#
#   tools/prepare-nand.sh [--stock DIR] [--flash-mb 128|256|512] PROFILE [VERSION] [OUTDIR]
#
#     PROFILE  OpenWrt device profile, e.g. cudy_wr3000p-v1, netis_nx31
#              (see the target's profiles.json).  The OpenWrt BL2 + U-Boot
#              images are used: PROFILE-ubootmod-* if the profile has such a
#              variant, else PROFILE-* (preloader.bin or
#              spim-nand-preloader.bin, bl31-uboot.fip,
#              squashfs-sysupgrade.itb, initramfs-recovery.itb or
#              initramfs.itb).  UBI layout: BL2, u-boot-env, Factory,
#              bdinfo, FIP, ubi (see --no-bdinfo).
#     VERSION  snapshot (default) or a release, e.g. 25.12.5
#     OUTDIR   default: nand-NAME (nor-NAME with --nor), NAME = PROFILE
#              without the vendor prefix and the -v1 suffix
#              (cudy_wr3000p-v1 -> nand-wr3000p)
#
#     --stock DIR     keep the vendor bootloader: DIR holds dumps of the
#                     vendor BL2 (*mtd0*.bin) and FIP (*FIP*.bin or *mtd4*.bin), and may
#                     hold the OpenWrt *sysupgrade.bin to use
#     --flash-mb N    flash size (default 128; 256 for W25N02KV boards, 512
#                     for W25N04KV)
#     --no-bdinfo     layout without bdinfo (FIP 0x380000, ubi 0x580000;
#                     MACs in Factory), e.g. netis boards
#     --local DIR     use the images in DIR (own builds, same names as
#                     above) instead of downloading them
#     --nor           SPI-NOR board (with --stock): BL2, u-boot-env, Factory,
#                     bdinfo, FIP + OpenWrt sysupgrade.bin in "firmware"
#     --nor-mb N      NOR size (default 16)
#     --soc SOC       mt7981 (default) or mt7986: partition file prefix; an
#                     MT7986 Factory without a dump gets a minimal Wi-Fi
#                     EEPROM (OpenWrt has no default one for that chip)
#     --parts SPEC    own flash layout for mknand.py, "label:size,...",
#                     size "-" = rest (e.g. Xiaomi boards: BL2, Nvram, Bdata,
#                     Factory, FIP, ..., ubi); BL2, Factory, bdinfo, FIP and
#                     ubi are filled, other partitions stay erased
#     --ubi-fip       layout of "spim-nand-ubi" BL2s (e.g. bananapi_bpi-r4-lite):
#                     BL2 at 0, UBI from 0x200000 with the FIP as volume "fip"
#     --ubi-factory N Factory as UBI volume "factory" of N bytes (e.g. Asus
#                     ZenWiFi BT8: the MACs and Wi-Fi EEPROM are read from it)
#     --emmc          eMMC board (machine option flash=emmc, e.g.
#                     glinet_gl-mt6000): OUTDIR (default emmc-NAME) gets
#                     one image SOC.emmc.img built by tools/mkemmc.py from
#                     preloader.bin, bl31-uboot.fip, squashfs-factory.bin
#                     (or squashfs-sysupgrade.bin, a tar with kernel and
#                     root); with --stock: the vendor BL2 (*boot0*.bin), FIP
#                     (*fip*.bin) and, if there, Factory and boot1 dumps
#     --emmc-layout L eMMC GPT layout of tools/mkemmc.py (default
#                     gl-mt6000; wh3000-pro: Huasifei WH3000 Pro eMMC)
#     --uboot PROF    eMMC board without an OpenWrt U-Boot build: take
#                     preloader.bin + bl31-uboot.fip of the OpenWrt profile
#                     PROF (same SoC, eMMC, DRAM type) and write an
#                     environment that boots the "kernel" partition
#
# Factory (Wi-Fi EEPROM) and bdinfo (MAC) are taken from ./factory/ if
# present (*Factory*.bin whose EEPROM chip ID matches the SoC, *bdinfo*.bin),
# otherwise left erased/random.
set -e
cd "$(dirname "$(readlink -f "$0")")/.."
STOCK=
LOCAL=
MB=128
LAYOUT=
NOR=
NORMB=16
SOC=mt7981
EMMC=
UBIFIP=
ELAYOUT=gl-mt6000
UBOOT=
while [ $# -gt 0 ]; do
    case $1 in
    --stock) STOCK=$2; shift 2 ;;
    --flash-mb) MB=$2; shift 2 ;;
    --local) LOCAL=$2; shift 2 ;;
    --no-bdinfo) LAYOUT=--no-bdinfo; shift ;;
    --nor) NOR=1; shift ;;
    --nor-mb) NORMB=$2; shift 2 ;;
    --soc) SOC=$2; shift 2 ;;
    --emmc) EMMC=1; shift ;;
    --emmc-layout) ELAYOUT=$2; shift 2 ;;
    --uboot) UBOOT=$2; shift 2 ;;
    --ubi-fip) LAYOUT="--parts BL2:0x200000,ubi:-"; UBIFIP=--fip-in-ubi; shift ;;
    --ubi-factory) UBIFAC="--factory-volume $2"; shift 2 ;;
    --parts) LAYOUT="--parts $2"; shift 2 ;;
    -h|--help) sed -n '2,56p' "$0"; exit 0 ;;
    *) break ;;
    esac
done
P=${1:?usage: tools/prepare-nand.sh [--stock DIR] [--flash-mb N] PROFILE [VERSION] [OUTDIR]}
V=${2:-snapshot}
NAME=${P#*_}; NAME=${NAME%-v1}
OUT=${3:-$([ -n "$NOR" ] && echo nor || { [ -n "$EMMC" ] && echo emmc; } || echo nand)-$NAME}
if [ "$V" = snapshot ]; then
    URL=https://downloads.openwrt.org/snapshots/targets/mediatek/filogic
    BASE=openwrt-mediatek-filogic-$P
else
    URL=https://downloads.openwrt.org/releases/$V/targets/mediatek/filogic
    BASE=openwrt-$V-mediatek-filogic-$P
fi
DL=firmware/$V; mkdir -p "$DL"
# a Factory dump only for its own Wi-Fi chip: the EEPROM starts with the
# chip ID (81 79 = MT7981), another SoC's driver rejects it
FAC=
for f in factory/*Factory*.bin; do
    [ -f "$f" ] || continue
    [ "$(od -A n -t x2 -N 2 "$f" | tr -d ' ')" = "${SOC#mt}" ] && { FAC=$f; break; }
done
BDI=$(ls factory/*bdinfo*.bin 2>/dev/null | head -1 || true)
[ -z "$LAYOUT" ] || BDI=       # no bdinfo partition
[ -z "$UBIFIP" ] || FAC=       # no Factory partition either
MK=(python3 tools/mknand.py --prefix "$SOC")
EEP=()
[ "$SOC" = mt7986 ] && [ -z "$FAC" ] && EEP=(--wifi-eeprom 7986)

if [ -n "$NOR" ] && [ -z "$STOCK" ]; then
    echo "--nor needs --stock DIR (OpenWrt has no own bootloader images for NOR boards)" >&2
    exit 1
fi
if [ -n "$STOCK" ]; then
    # vendor BL2/FIP + OpenWrt sysupgrade.bin in UBI kernel/rootfs volumes
    # (eMMC: in the kernel/rootfs partitions)
    SPFX=$BASE-squashfs-sysupgrade.bin
    if [ -n "$EMMC" ]; then
        BL2=$(ls "$STOCK"/*boot0*.bin 2>/dev/null | head -1)
        BOOT1=$(ls "$STOCK"/*boot1*.bin 2>/dev/null | head -1)
        FIP=$(ls "$STOCK"/*[Ff][Ii][Pp]*.bin 2>/dev/null | head -1)
        F=$(ls "$STOCK"/*[Ff]actory*.bin 2>/dev/null | head -1)
        [ -z "$F" ] || FAC=$F
        [ -n "$BL2" ] && [ -n "$FIP" ] || { echo "need $STOCK/*boot0*.bin and $STOCK/*fip*.bin (vendor BL2/FIP dumps)" >&2; exit 1; }
    else
        BL2=$(ls "$STOCK"/*mtd0*.bin 2>/dev/null | head -1)
        # FIP: by name (mtd3 in layouts without bdinfo), else the mtd4 dump
        FIP=$(ls "$STOCK"/*FIP*.bin 2>/dev/null | head -1)
        [ -n "$FIP" ] || FIP=$(ls "$STOCK"/*mtd4*.bin 2>/dev/null | head -1)
        [ -n "$BL2" ] && [ -n "$FIP" ] || { echo "need $STOCK/*mtd0*.bin and $STOCK/*FIP*.bin or *mtd4*.bin (vendor BL2/FIP dumps)" >&2; exit 1; }
    fi
    # a local sysupgrade.bin (releases may not list every device) or download;
    # only an OpenWrt image (FIT, or a sysupgrade tar) counts: vendor
    # firmware named *sysupgrade*.bin (Cudy's own format, say) is skipped
    is_owrt() {
        [ "$(od -A n -t x1 -N 4 "$1" | tr -d ' ')" = d00dfeed ] ||
            [ "$(dd if="$1" bs=1 skip=257 count=5 2>/dev/null)" = ustar ]
    }
    SYS=
    while IFS= read -r f; do
        if is_owrt "$f"; then SYS=$f; break; fi
        echo "skip $f: not an OpenWrt image" >&2
    done < <(ls "$STOCK"/*sysupgrade*.bin 2>/dev/null | grep -- "$V" || true
             ls "$STOCK"/*sysupgrade*.bin 2>/dev/null | grep -v -- "$V" || true)
    if [ -z "$SYS" ]; then
        # a cached copy that matches the checksums is kept (no download)
        if ! [ -f "$DL/$SPFX" ] || ! (cd "$DL" && grep -s "$SPFX" sha256sums | sha256sum -c --quiet 2>/dev/null); then
            wget -q -O "$DL/sha256sums" "$URL/sha256sums"
            wget -q -O "$DL/$SPFX" "$URL/$SPFX" || { rm -f "$DL/$SPFX"; echo "no $SPFX on downloads.openwrt.org; put a sysupgrade.bin into $STOCK/" >&2; exit 1; }
            (cd "$DL" && grep "$SPFX" sha256sums | sha256sum -c --quiet)
        fi
        SYS=$DL/$SPFX
    fi
    echo "$P (vendor bootloader): $BL2 + $FIP + $SYS"
    if [ -n "$EMMC" ]; then
        python3 tools/mkemmc.py -o "$OUT/$SOC.emmc.img" --layout "$ELAYOUT" \
            --bl2 "$BL2" ${BOOT1:+--boot1 "$BOOT1"} --fip "$FIP" --sysupgrade "$SYS" \
            ${FAC:+--factory "$FAC"} --wifi-chip "${SOC#mt}"
        exit 0
    fi
    if [ -n "$NOR" ]; then
        "${MK[@]}" nor -o "$OUT/" --size-mb "$NORMB" --bl2 "$BL2" --fip "$FIP" \
            --sysupgrade "$SYS" ${FAC:+--factory "$FAC"} ${BDI:+--bdinfo "$BDI"}
        exit 0
    fi
    "${MK[@]}" --flash-mb "$MB" $LAYOUT create -o "$OUT/" --bl2 "$BL2" --fip "$FIP" \
        --sysupgrade "$SYS" ${FAC:+--factory "$FAC"} ${BDI:+--bdinfo "$BDI"} "${EEP[@]}" 2>&1 | grep -v '^ubinize'
    exit 0
fi
# image name variants, first match wins
PRE="ubootmod-preloader.bin preloader.bin spim-nand-preloader.bin snand-preloader.bin"
FIPS="ubootmod-bl31-uboot.fip bl31-uboot.fip spim-nand-bl31-uboot.fip snand-bl31-uboot.fip"
FITS="ubootmod-squashfs-sysupgrade.itb squashfs-sysupgrade.itb"
RECS="ubootmod-initramfs-recovery.itb initramfs-recovery.itb initramfs.itb"
if [ -n "$LOCAL" ]; then
    # own builds: file names may carry a version or not
    pick() {
        local s f
        for s in $1; do
            f=$(ls "$LOCAL"/*"${3:-$P}-$s" 2>/dev/null | head -1)
            [ -n "$f" ] && { echo "$f"; return; }
        done
        [ "$2" = optional ] || { echo "no *${3:-$P}-{${1// /,}} in $LOCAL/" >&2; exit 1; }
    }
    echo "$P: local images from $LOCAL/"
else
    wget -q -O "$DL/sha256sums" "$URL/sha256sums"
    # $3: another profile (--uboot)
    pick() {
        local s f b=$BASE
        [ -z "$3" ] || b=${BASE%"$P"}$3
        for s in $1; do
            f=$b-$s
            if grep -q -- " \*$f\$" "$DL/sha256sums"; then
                [ -f "$DL/$f" ] || wget -q -O "$DL/$f" "$URL/$f"
                (cd "$DL" && grep -- " \*$f\$" sha256sums | sha256sum -c --quiet)
                echo "$DL/$f"
                return
            fi
        done
        [ "$2" = optional ] || { echo "no $b-{${1// /,}} in $URL (wrong profile, or no OpenWrt U-Boot build for it)" >&2; exit 1; }
    }
fi
if [ -n "$EMMC" ]; then
    # boards with several boot media name the eMMC images emmc-*
    BL2=$(pick "emmc-preloader.bin $PRE" "" "$UBOOT")
    FIP=$(pick "emmc-bl31-uboot.fip $FIPS" "" "$UBOOT")
    # squashfs-factory.bin (kernel + rootfs in one), else the sysupgrade
    # tar, else the sysupgrade FIT (.itb, e.g. BPi-R4: "production")
    FW=$(pick "squashfs-factory.bin" optional); SYS=; FIT=; REC=
    [ -n "$FW" ] || SYS=$(pick "squashfs-sysupgrade.bin" optional)
    if [ -z "$FW$SYS" ]; then
        FIT=$(pick "$FITS"); REC=$(pick "$RECS" optional)
    fi
    [ -n "$BL2" ] && [ -n "$FIP" ] && [ -n "$FW$SYS$FIT" ] || exit 1
    echo "$P: $(basename "$BL2"), $(basename "$FIP"), $(basename "$FW$SYS$FIT")"
    python3 tools/mkemmc.py -o "$OUT/$SOC.emmc.img" --layout "$ELAYOUT" \
        --bl2 "$BL2" --fip "$FIP" ${FW:+--firmware "$FW"} ${SYS:+--sysupgrade "$SYS"} \
        ${FIT:+--fit "$FIT"} ${REC:+--recovery "$REC"} \
        ${UBOOT:+--boot-env} ${FAC:+--factory "$FAC"} --wifi-chip "${SOC#mt}"
    exit 0
fi
BL2=$(pick "$PRE"); FIP=$(pick "$FIPS"); FIT=$(pick "$FITS"); REC=$(pick "$RECS" optional)
[ -n "$BL2" ] && [ -n "$FIP" ] && [ -n "$FIT" ] || exit 1
echo "$P: $(basename "$BL2"), $(basename "$FIP"), $(basename "$FIT")${REC:+, $(basename "$REC")}"
"${MK[@]}" --flash-mb "$MB" $LAYOUT create -o "$OUT/" --bl2 "$BL2" --fip "$FIP" $UBIFIP \
    $UBIFAC --fit "$FIT" ${REC:+--recovery "$REC"} \
    ${FAC:+--factory "$FAC"} ${BDI:+--bdinfo "$BDI"} "${EEP[@]}" 2>&1 | grep -v '^ubinize'
