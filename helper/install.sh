#!/bin/sh
# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: MIT
#
# Installs the ThruRNDIS-Wi-Fi route daemon and its thrurndis-wifi-rank tool (taken from the
# same directory). Run as root (the app uses an administrator prompt):
#   install.sh <thrurndis-wifi-routed source> <config-file>

set -eu

SOURCE=${1:?usage: install.sh <thrurndis-wifi-routed> <config-file>}
CONFIG=${2:?usage: install.sh <thrurndis-wifi-routed> <config-file>}
LABEL=io.github.afy0817.thrurndis-wifi.routed
BIN=/usr/local/libexec/thrurndis-wifi-routed
RANK_BIN=/usr/local/libexec/thrurndis-wifi-rank
RANK_SOURCE=$(dirname "$SOURCE")/thrurndis-wifi-rank
PLIST=/Library/LaunchDaemons/$LABEL.plist

case "$CONFIG" in
    /Users/*/Library/Application\ Support/ThruRNDIS-Wi-Fi/routes.conf) ;;
    *) echo "unexpected config path: $CONFIG" >&2; exit 1 ;;
esac

mkdir -p /usr/local/libexec
install -o root -g wheel -m 755 "$SOURCE" "$BIN"
install -o root -g wheel -m 755 "$RANK_SOURCE" "$RANK_BIN"

# The helper used to be installed as VmWifi's: take it down and hand its
# never-primary holder (it outlives its daemon) and its route list to the new
# daemon, which removes the routes no longer wanted.
LEGACY_PLIST=/Library/LaunchDaemons/io.github.afy0817.vmwifi.routed.plist
if [ -f "$LEGACY_PLIST" ]; then
    launchctl bootout system "$LEGACY_PLIST" 2>/dev/null || true
    [ -f /var/run/vmwifi-rank.pid ] && mv -f /var/run/vmwifi-rank.pid /var/run/thrurndis-wifi-rank.pid
    [ -f /var/db/vmwifi-routed.bond ] && mv -f /var/db/vmwifi-routed.bond /var/db/thrurndis-wifi-routed.bond
    [ -f /var/run/vmwifi-routed.state ] && mv -f /var/run/vmwifi-routed.state /var/run/thrurndis-wifi-routed.state
    rm -f "$LEGACY_PLIST" /usr/local/libexec/vmwifi-routed /usr/local/libexec/vmwifi-rank \
        /var/run/vmwifi-routed.status
fi

# The never-primary holder (thrurndis-wifi-rank) is left running across the
# restart: AbandonProcessGroup keeps launchd from ending it with the old
# daemon, and the new daemon adopts it through /var/run/thrurndis-wifi-rank.pid, so
# ThruRNDIS's Bond never gets a moment as the Mac's primary service.
launchctl bootout system "$PLIST" 2>/dev/null || true

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>$CONFIG</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>AbandonProcessGroup</key>
    <true/>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootstrap system "$PLIST"
echo "installed $LABEL"
