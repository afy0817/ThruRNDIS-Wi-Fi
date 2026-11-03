#!/bin/sh
# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: MIT
#
# Removes the ThruRNDIS-Wi-Fi route daemon and the routes it added. Run as root.

LABEL=io.github.afy0817.thrurndis-wifi.routed
BIN=/usr/local/libexec/thrurndis-wifi-routed
RANK_BIN=/usr/local/libexec/thrurndis-wifi-rank
PLIST=/Library/LaunchDaemons/$LABEL.plist
STATE=/var/run/thrurndis-wifi-routed.state
RANK_PID=/var/run/thrurndis-wifi-rank.pid

launchctl bootout system "$PLIST" 2>/dev/null || true
# Ending the holder drops its never-primary assertion.
if [ -f "$RANK_PID" ]; then
    read -r pid held <"$RANK_PID" && kill "$pid" 2>/dev/null
fi
if [ -f "$STATE" ]; then
    for cidr in $(cat "$STATE"); do
        route -n delete -net "$cidr" 192.168.100.1 >/dev/null 2>&1 || true
    done
fi
rm -f "$PLIST" "$BIN" "$RANK_BIN" "$STATE" "$RANK_PID" /var/run/thrurndis-wifi-routed.status \
    /var/db/thrurndis-wifi-routed.bond

# The same helper installed under the app's former name, VmWifi.
LEGACY_PLIST=/Library/LaunchDaemons/io.github.afy0817.vmwifi.routed.plist
if [ -f "$LEGACY_PLIST" ]; then
    launchctl bootout system "$LEGACY_PLIST" 2>/dev/null || true
    if [ -f /var/run/vmwifi-rank.pid ]; then
        read -r pid held </var/run/vmwifi-rank.pid && kill "$pid" 2>/dev/null
    fi
    for cidr in $(cat /var/run/vmwifi-routed.state 2>/dev/null); do
        route -n delete -net "$cidr" 192.168.100.1 >/dev/null 2>&1 || true
    done
    rm -f "$LEGACY_PLIST" /usr/local/libexec/vmwifi-routed /usr/local/libexec/vmwifi-rank \
        /var/run/vmwifi-routed.state /var/run/vmwifi-routed.status /var/run/vmwifi-rank.pid \
        /var/db/vmwifi-routed.bond
fi
echo "removed $LABEL"
