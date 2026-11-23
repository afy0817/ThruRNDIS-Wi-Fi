#!/bin/sh
# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: MIT
#
# Builds dist/ThruRNDIS-Wi-Fi.app (ad-hoc signed; it needs no restricted entitlement
# because USB passthrough stays inside the officially signed ThruRNDIS).
#   ./app/build_app.sh [--install]     --install copies it to /Applications
#   ./app/build_app.sh --release       also dist/ThruRNDIS-Wi-Fi.zip and the VM image's
#                                      corresponding source, dist/vm_assets-sources.tar.gz:
#                                      a GitHub release of the app carries both
# The VM image is a GodseonDongle-VM release, pinned in vm-assets.env: vm_assets.zip is
# downloaded once into dist/cache and checked against its sha256. To bundle a local build
# instead (after ./build.sh in a GodseonDongle-VM checkout):
#   VM_ASSETS_DIR=../GodseonDongle-VM/dist/vm_assets ./app/build_app.sh

set -eu

APP_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$APP_DIR/.." && pwd)
DIST=$ROOT/dist
BUNDLE=$DIST/ThruRNDIS-Wi-Fi.app
# The version: THRURNDIS_WIFI_VERSION, else the newest v* tag of this checkout (v0.3.0 -> 0.3.0).
# The commit goes into Info.plist too; the menu shows both (BuildInfo.swift).
TAG=$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
VERSION=${THRURNDIS_WIFI_VERSION:-${TAG#v}}
VERSION=${VERSION:-0.0.0}
COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || true)
if [ -n "$COMMIT" ] && [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    COMMIT="$COMMIT-dirty"
fi

# shellcheck source=../vm-assets.env
. "$ROOT/vm-assets.env"
sha256() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
if [ "${1:-}" = --release ] && [ -n "${VM_ASSETS_DIR:-}" ]; then
    echo "--release bundles the pinned GodseonDongle-VM release; unset VM_ASSETS_DIR" >&2
    exit 1
fi
if [ -n "${VM_ASSETS_DIR:-}" ]; then
    ASSETS=$(CDPATH='' cd -- "$VM_ASSETS_DIR" && pwd)
else
    ASSETS=$DIST/vm_assets
    ZIP=$DIST/cache/vm_assets-$VM_ASSETS_VERSION.zip
    if [ ! -f "$ZIP" ] || [ "$(sha256 "$ZIP")" != "$VM_ASSETS_SHA256" ]; then
        mkdir -p "$DIST/cache"
        echo "downloading GodseonDongle-VM $VM_ASSETS_VERSION"
        curl -fL --retry 3 -o "$ZIP.part" "$VM_ASSETS_URL"
        if [ "$(sha256 "$ZIP.part")" != "$VM_ASSETS_SHA256" ]; then
            echo "vm_assets.zip of $VM_ASSETS_VERSION does not match VM_ASSETS_SHA256 in vm-assets.env" >&2
            rm -f "$ZIP.part"
            exit 1
        fi
        mv "$ZIP.part" "$ZIP"
    fi
    rm -rf "$ASSETS"
    ditto -x -k "$ZIP" "$DIST"
fi
if [ ! -f "$ASSETS/initramfs-thrurndis-wifi" ] || [ ! -f "$ASSETS/manifest.json" ]; then
    echo "$ASSETS is not a GodseonDongle-VM image" >&2
    exit 1
fi
if [ ! -f "$ASSETS/compliance/SOURCE.md" ]; then
    echo "warning: $ASSETS has no license notices (a ./build.sh --quick image); do not distribute this app" >&2
fi

swift build --package-path "$APP_DIR" -c release
BINARY=$(swift build --package-path "$APP_DIR" -c release --show-bin-path)/ThruRNDISWiFi

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/helper"
cp "$BINARY" "$BUNDLE/Contents/MacOS/ThruRNDISWiFi"
cp -R "$ASSETS" "$BUNDLE/Contents/Resources/vm_assets"
cp "$ROOT/helper/thrurndis-wifi-routed" "$ROOT/helper/install.sh" "$ROOT/helper/uninstall.sh" \
    "$BUNDLE/Contents/Resources/helper/"
clang -O2 -Wall -mmacosx-version-min=14.0 -o "$BUNDLE/Contents/Resources/helper/thrurndis-wifi-rank" \
    "$ROOT/helper/thrurndis-wifi-rank.c" -framework SystemConfiguration -framework CoreFoundation
chmod 755 "$BUNDLE/Contents/Resources/helper/"*

cat >"$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.afy0817.ThruRNDIS-Wi-Fi</string>
    <key>CFBundleName</key><string>ThruRNDIS-Wi-Fi</string>
    <key>CFBundleDisplayName</key><string>ThruRNDIS-Wi-Fi</string>
    <key>CFBundleExecutable</key><string>ThruRNDISWiFi</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>ThruRNDISWiFiCommit</key><string>$COMMIT</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>ThruRNDIS VM 안의 무선랜 제어 API(192.168.64.x)에 접속합니다.</string>
</dict>
</plist>
EOF

codesign --force --sign - --timestamp=none "$BUNDLE"
codesign --verify --strict "$BUNDLE"
echo "built $BUNDLE ($VERSION, ${COMMIT:-no git})"

if [ "${1:-}" = "--install" ]; then
    pkill -x ThruRNDISWiFi 2>/dev/null || true
    # The app's former name.
    pkill -x VmWifi 2>/dev/null || true
    rm -rf /Applications/VmWifi.app
    rm -rf /Applications/ThruRNDIS-Wi-Fi.app
    cp -R "$BUNDLE" /Applications/ThruRNDIS-Wi-Fi.app
    echo "installed /Applications/ThruRNDIS-Wi-Fi.app"
fi

if [ "${1:-}" = "--release" ]; then
    # The app zip ships the GPL binaries of the VM image, so its release also carries their
    # source: the same vm_assets-sources.tar.gz as the GodseonDongle-VM release (see
    # vm_assets/compliance/SOURCE.md inside the app).
    SOURCES=$DIST/vm_assets-sources.tar.gz
    if [ ! -f "$SOURCES" ] || [ "$(sha256 "$SOURCES")" != "$VM_SOURCES_SHA256" ]; then
        echo "downloading the corresponding source of GodseonDongle-VM $VM_ASSETS_VERSION"
        curl -fL --retry 3 -o "$SOURCES.part" "$VM_SOURCES_URL"
        if [ "$(sha256 "$SOURCES.part")" != "$VM_SOURCES_SHA256" ]; then
            echo "vm_assets-sources.tar.gz does not match VM_SOURCES_SHA256 in vm-assets.env" >&2
            rm -f "$SOURCES.part"
            exit 1
        fi
        mv "$SOURCES.part" "$SOURCES"
    fi
    rm -f "$DIST/ThruRNDIS-Wi-Fi.zip"
    ditto -c -k --keepParent "$BUNDLE" "$DIST/ThruRNDIS-Wi-Fi.zip"
    echo "release files: $DIST/ThruRNDIS-Wi-Fi.zip $SOURCES"
fi
