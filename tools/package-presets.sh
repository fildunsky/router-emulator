#!/bin/bash
# Build dist/Router-Emulator-<version>-presets.zip: the board presets
# (Router-Emulator/presets/*.ini); unpacked over a package they complete it.
# The packages do not contain presets; every release publishes this archive
# next to them.
#
#   tools/package-presets.sh
set -e
cd "$(dirname "$(readlink -f "$0")")/.."
ROOT=$PWD
APP=Router-Emulator
ZIP=$APP-$(cat VERSION)-presets.zip
rm -rf work/presetspkg && mkdir -p work/presetspkg/$APP
cp -r presets work/presetspkg/$APP/
mkdir -p dist && rm -f "dist/$APP"-*-presets.zip
(cd work/presetspkg && zip -qr9 "$ROOT/dist/$ZIP" $APP)
ls -la "dist/$ZIP"
