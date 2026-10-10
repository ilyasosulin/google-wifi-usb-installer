#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Build an OpenWrt image for Google WiFi with the USB installer, using the
# official OpenWrt ImageBuilder (Linux x86_64 or WSL).
#
#   ./build.sh [-v VERSION] [--no-setup-code] [-p "extra packages"]
#
#   -v VERSION        OpenWrt release (default: 25.12.5)
#   --no-setup-code   leave out 99-google-wifi-setup-code (stock behaviour:
#                     no root password, Wi-Fi disabled)
#   -p PACKAGES       additional packages, e.g. "luci-ssl"
#
# Result: out/<VERSION>/*-google_wifi-squashfs-factory.bin (write it to a USB
# stick) and *-sysupgrade.bin (for routers already running OpenWrt).

set -eu

VERSION="25.12.5"
SETUP_CODE=1
EXTRA=""

while [ $# -gt 0 ]; do
	case "$1" in
	-v) VERSION="$2"; shift 2 ;;
	--no-setup-code) SETUP_CODE=0; shift ;;
	-p) EXTRA="$2"; shift 2 ;;
	-h|--help) sed -n '3,16p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

REPO="$(cd "$(dirname "$0")" && pwd)"
BASE="https://downloads.openwrt.org/releases/$VERSION/targets/ipq40xx/chromium"
WORK="$REPO/build/$VERSION"
OUT="$REPO/out/$VERSION"
mkdir -p "$WORK" "$OUT"
cd "$WORK"

echo "== ImageBuilder for OpenWrt $VERSION"
curl -fsSL "$BASE/sha256sums" -o sha256sums
IB="$(grep -o 'openwrt-imagebuilder-[^ ]*\.tar\.[a-z]*' sha256sums | head -n 1)"
[ -n "$IB" ] || { echo "no ImageBuilder in $BASE/sha256sums" >&2; exit 1; }
[ -f "$IB" ] || curl -fL -o "$IB" "$BASE/$IB"
grep " \*$IB\$" sha256sums | sha256sum -c -

IBDIR="${IB%.tar.*}"
if [ ! -d "$IBDIR" ]; then
	case "$IB" in
	*.tar.zst) tar --zstd -xf "$IB" ;;
	*.tar.xz) tar -xJf "$IB" ;;
	*) echo "unknown archive type: $IB" >&2; exit 1 ;;
	esac
fi

echo "== files"
rm -rf files
cp -a "$REPO/files" files
[ "$SETUP_CODE" = 1 ] || rm -f files/etc/uci-defaults/99-google-wifi-setup-code
find files -type f -exec sed -i 's/\r$//' {} \;
chmod 755 files/usr/sbin/usb-installer files/etc/init.d/usb-installer files/etc/rc.button/reset
[ ! -f files/etc/uci-defaults/99-google-wifi-setup-code ] || chmod 755 files/etc/uci-defaults/99-google-wifi-setup-code

echo "== image"
# sfdisk: needed by the installer to write the GPT
make -C "$IBDIR" image PROFILE=google_wifi \
	PACKAGES="sfdisk $EXTRA" \
	FILES="$WORK/files" \
	BIN_DIR="$OUT"

echo
ls -l "$OUT"/*google_wifi*
