#!/bin/sh
# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: MIT
#
# Builds dist/ThruRNDIS-Wi-Fi.app (ad-hoc signed; it needs no restricted entitlement
# because USB passthrough stays inside the officially signed ThruRNDIS).
#   ./app/build_app.sh [--install]     --install copies it to /Applications

set -eu

APP_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$APP_DIR/.." && pwd)
DIST=$ROOT/dist
ASSETS=$DIST/vm_assets
BUNDLE=$DIST/ThruRNDIS-Wi-Fi.app
VERSION=${THRURNDIS_WIFI_VERSION:-0.1.0}

if [ ! -f "$ASSETS/initramfs-thrurndis-wifi" ]; then
    "$ROOT/vm/build.sh" "$ASSETS"
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
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>ThruRNDIS VM 안의 무선랜 제어 API(192.168.64.x)에 접속합니다.</string>
</dict>
</plist>
EOF

codesign --force --sign - --timestamp=none "$BUNDLE"
codesign --verify --strict "$BUNDLE"
echo "built $BUNDLE"

if [ "${1:-}" = "--install" ]; then
    pkill -x ThruRNDISWiFi 2>/dev/null || true
    # The app's former name.
    pkill -x VmWifi 2>/dev/null || true
    rm -rf /Applications/VmWifi.app
    rm -rf /Applications/ThruRNDIS-Wi-Fi.app
    cp -R "$BUNDLE" /Applications/ThruRNDIS-Wi-Fi.app
    echo "installed /Applications/ThruRNDIS-Wi-Fi.app"
fi
