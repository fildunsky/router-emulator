#!/bin/bash
# Build the Router Emulator: QEMU v10.1.0 + qemu-patches/*.patch
#
#   ./build.sh            clone QEMU into src/qemu, apply the patches, build
#                         src/qemu/build/qemu-system-aarch64 (Filogic boards)
#                         and qemu-system-mipsel (MT7621 boards)
#
# Environment:
#   JOBS=N                parallel build jobs (default: ninja's choice)
#   CONFIGURE_ARGS="..."  extra arguments for QEMU's configure
#
# libslirp and libfdt are taken from the system when their development
# files are installed; otherwise QEMU's own meson subprojects (libslirp,
# dtc) are downloaded and built, so the build works without root as long
# as a compiler, meson, ninja, glib, pixman and zlib are present.
set -e
cd "$(dirname "$(readlink -f "$0")")"
ROOT=$PWD

# --- required tools and libraries -------------------------------------
missing=()
for t in git cc make ninja meson python3 pkg-config; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
if command -v pkg-config >/dev/null 2>&1; then
    for p in glib-2.0 pixman-1 zlib; do
        pkg-config --exists "$p" || missing+=("$p (development files)")
    done
fi
if [ ${#missing[@]} -gt 0 ]; then
    echo "missing: ${missing[*]}" >&2
    echo "see README.build.linux.md for the packages of your distribution" >&2
    exit 1
fi
for p in slirp; do
    pkg-config --exists "$p" ||
        echo "note: no system lib$p, QEMU's subproject will be downloaded" >&2
done

if [ ! -d src/qemu/.git ]; then
    mkdir -p src
    git clone --depth 1 --branch v10.1.0 https://gitlab.com/qemu-project/qemu.git src/qemu
fi
cd src/qemu
if ! git rev-parse -q --verify mt7981 >/dev/null; then
    git checkout -b mt7981
fi
# apply the patches not yet on the branch: a checkout made before the
# repository got new patches receives them (the branch is expected to hold
# the series in order; after own commits in src/qemu, apply by hand)
patches=("$ROOT"/qemu-patches/*.patch)
have=$(git rev-list --count v10.1.0..mt7981)
if [ "$have" -lt ${#patches[@]} ]; then
    git checkout -q mt7981
    git -c user.name=build -c user.email=build@localhost am "${patches[@]:$have}"
fi
mkdir -p build && cd build
# --enable-fdt=enabled: system libfdt if found, else the bundled dtc;
# a build directory from before the MT7621 machine is configured again
grep -qs mipsel-softmmu build.ninja ||
    ../configure --target-list=aarch64-softmmu,mipsel-softmmu --enable-slirp \
        --enable-fdt=enabled --disable-docs --disable-werror $CONFIGURE_ARGS
ninja ${JOBS:+-j "$JOBS"} qemu-system-aarch64 qemu-system-mipsel
echo "built: $PWD/qemu-system-aarch64 $PWD/qemu-system-mipsel"
