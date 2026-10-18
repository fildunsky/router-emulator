#!/bin/bash
# Build the Linux package dist/Router-Emulator-<version>-linux-<arch>.tar.gz
# from an existing QEMU build (./build.sh):
#   - qemu/qemu-system-aarch64 and qemu-system-mipsel (MT7621 boards; the
#     same directory as the first binary), stripped, with the shared
#     libraries they need
#     in qemu/lib/ (all but the C library itself), found through
#     RUNPATH=$ORIGIN, so the package runs on other distributions with the
#     same or a newer glibc
#   - emulator.sh, presets, tools (prepare-nand.sh, mknand.py, host-bridge.sh),
#     tests/quick.py, docs
# No flash folders: they are built with tools/prepare-nand.sh.
#
# aarch64 (ARCH=aarch64, the default on an aarch64 host) packages the C
# library and its loader too: emulator.sh starts QEMU through
# qemu/lib/ld-linux-aarch64.so.1, so it runs on any aarch64 kernel, also
# under a 32-bit userland (TV boxes with CoreELEC, Raspberry Pi OS 32-bit).
# BASH_STATIC=FILE adds a static bash as ./bash for systems without one.
# Cross builds: LDD="<target ld.so> --list" (runs through binfmt/qemu-user),
# STRIP=aarch64-linux-gnu-strip.
#
#   tools/package-linux.sh [QEMU_BINARY]     (default src/qemu/build/...)
#
# Needs patchelf.  For a small dependency set configure QEMU without UI and
# audio, e.g.
#   CONFIGURE_ARGS="--disable-gtk --disable-sdl --disable-opengl --disable-vnc
#     --disable-spice --disable-curl --audio-drv-list=" ./build.sh
set -e
cd "$(dirname "$(readlink -f "$0")")/.."
ROOT=$PWD
BIN=${1:-src/qemu/build/qemu-system-aarch64}
[ -x "$BIN" ] || { echo "no QEMU binary $BIN: run ./build.sh" >&2; exit 1; }
command -v patchelf >/dev/null || { echo "patchelf is needed" >&2; exit 1; }
EMU_VERSION=$(cat VERSION)
APP=Router-Emulator
ARCH=${ARCH:-$(uname -m)}
LDD=${LDD:-ldd}
STRIP=${STRIP:-strip}
BUNDLE_LIBC=0
[ "$ARCH" = aarch64 ] && BUNDLE_LIBC=1
TGZ=$APP-$EMU_VERSION-linux-$ARCH.tar.gz
PKG=$ROOT/work/linuxpkg/$APP
rm -rf "$PKG" && mkdir -p "$PKG/qemu/lib" "$PKG/usb" "$PKG/tools" "$PKG/tests"

MIPS=$(dirname "$BIN")/qemu-system-mipsel
[ -x "$MIPS" ] || { echo "no $MIPS: run ./build.sh" >&2; exit 1; }
install -m 755 "$BIN" "$PKG/qemu/qemu-system-aarch64"
install -m 755 "$MIPS" "$PKG/qemu/qemu-system-mipsel"
$STRIP --strip-all "$PKG/qemu/qemu-system-aarch64" "$PKG/qemu/qemu-system-mipsel"
# shared libraries; the parts of glibc only with BUNDLE_LIBC (otherwise
# they must match the system)
{ $LDD "$BIN"; $LDD "$MIPS"; } | awk '/=> \// { print $1, $3 } /^\t\/[^ ]*ld-linux/ { print $1, $1 }' |
sort -u | while read -r name path; do
    name=$(basename "$name")
    glibc=0
    case $name in
    ld-linux*|libc.so*|libm.so*|libmvec.so*|libpthread.so*|libdl.so*|\
    librt.so*|libresolv.so*|libutil.so*|libgcc_s.so*) glibc=1 ;;
    esac
    [ $glibc = 1 ] && [ $BUNDLE_LIBC = 0 ] && continue
    cp -L "$path" "$PKG/qemu/lib/$name"
    chmod 644 "$PKG/qemu/lib/$name"
    case $name in ld-linux*) chmod 755 "$PKG/qemu/lib/$name" ;; esac
    [ $glibc = 1 ] && continue
    $STRIP --strip-unneeded "$PKG/qemu/lib/$name"
    patchelf --set-rpath '$ORIGIN' "$PKG/qemu/lib/$name"
done
# glibc loads libgcc_s with dlopen (thread exit / cancellation)
if [ $BUNDLE_LIBC = 1 ] && [ ! -f "$PKG/qemu/lib/libgcc_s.so.1" ]; then
    libc=$($LDD "$BIN" | awk '$1 == "libc.so.6" { print $3 }')
    cp -L "$(dirname "$libc")/libgcc_s.so.1" "$PKG/qemu/lib/"
    chmod 644 "$PKG/qemu/lib/libgcc_s.so.1"
fi
patchelf --set-rpath '$ORIGIN/lib' "$PKG/qemu/qemu-system-aarch64" "$PKG/qemu/qemu-system-mipsel"
[ -n "$BASH_STATIC" ] && install -m 755 "$BASH_STATIC" "$PKG/bash"

cp emulator.sh VERSION LICENSE README.md README.ru.md \
   README.build.linux.md README.build.linux.ru.md "$PKG/"
cp -r presets "$PKG/"
cp tools/prepare-nand.sh tools/mknand.py tools/mkemmc.py tools/host-bridge.sh "$PKG/tools/"
# the RUTC50 bootloader (prepare-nand.sh --nor-nand rutc50)
mkdir -p "$PKG/tools/uboot-rutc50"
cp tools/uboot-rutc50/*.fip "$PKG/tools/uboot-rutc50/"
cp tests/quick.py "$PKG/tests/"
cp usb/README.txt "$PKG/usb/"

# the packaged binary must start without the build tree and without the
# libraries of this machine's QEMU build directory
QRUN=("$PKG/qemu/qemu-system-aarch64")
[ $BUNDLE_LIBC = 1 ] && QRUN=("$PKG/qemu/lib/ld-linux-aarch64.so.1" --library-path "$PKG/qemu/lib" "${QRUN[@]}")
(cd / && env -i PATH=/usr/bin:/bin "${QRUN[@]}" -M help |
    grep -q mt7981-router) || { echo "packaged QEMU does not start" >&2; exit 1; }
QRUN[${#QRUN[@]}-1]=$PKG/qemu/qemu-system-mipsel
(cd / && env -i PATH=/usr/bin:/bin "${QRUN[@]}" -M help |
    grep -q mt7621-router) || { echo "packaged qemu-system-mipsel does not start" >&2; exit 1; }

mkdir -p dist && rm -f "dist/$APP"-*-linux-"$ARCH".tar.gz
tar -C work/linuxpkg -czf "dist/$TGZ" --owner=0 --group=0 "$APP"
ls -la "dist/$TGZ"
