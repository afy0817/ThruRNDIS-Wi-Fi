#!/bin/sh
# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: GPL-2.0-or-later
#
# ThruRNDIS-Wi-Fi control API (busybox httpd CGI, installed as /cgi-bin/api).
#   GET  ?action=status&token=T
#   GET  ?action=results&token=T     cached scan results
#   GET  ?action=scan&token=T        trigger a scan, wait, return results
#   POST ?action=connect&token=T     body: ssid=<hex>&psk=<hex>&sae=<hex>&hidden=0|1
#                                    [&ip=<hex8>&prefix=<n>&gw=<hex8>&dns=<hex8...>&rt=<hex18...>]
#   GET  ?action=disconnect&token=T
# Parameters are restricted to [0-9A-Za-z_] so no URL decoding is needed.
# SSIDs are returned as hex because they are arbitrary bytes.

BB=/usr/bin/busybox
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

WLAN_IFACE=${THRURNDIS_WIFI_WLAN_IFACE:-wlan0}
WPA="wpa_cli -p /run/wpa_supplicant -i $WLAN_IFACE"
GATEWAY_SCRIPT=/usr/local/sbin/eth0-usb0-gateway

reply() {
    printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
    printf '%s\n' "$1"
}

fail() {
    reply "{\"ok\":false,\"error\":\"$1\"}"
    exit 0
}

param() {
    key=$1
    source=$2
    old_ifs=$IFS
    IFS='&'
    for pair in $source; do
        case "$pair" in
            "$key"=*)
                IFS=$old_ifs
                value=${pair#"$key"=}
                case "$value" in
                    *[!0-9A-Za-z_]*) return 1 ;;
                esac
                printf '%s' "$value"
                return 0
                ;;
        esac
    done
    IFS=$old_ifs
    return 1
}

cmdline_value() {
    key=$1
    for opt in $($BB cat /proc/cmdline); do
        case "$opt" in
            "$key"=*) printf '%s' "${opt#"$key"=}"; return 0 ;;
        esac
    done
    return 1
}

json_str() {
    printf '"%s"' "$(printf '%s' "$1" | $BB sed 's/\\/\\\\/g; s/"/\\"/g' | $BB tr -d '\000-\037')"
}

json_num() {
    case "$1" in
        ''|*[!0-9-]*) printf 'null' ;;
        *) printf '%s' "$1" ;;
    esac
}

# wpa_cli prints SSIDs with printf_encode escapes; turn them back into hex.
AWK_HEX='
function init_hex(   i) { for (i = 32; i < 127; i++) HEX[sprintf("%c", i)] = sprintf("%02x", i) }
function wpa_to_hex(s,   out, i, c, n) {
    out = ""; n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\" && i < n) {
            i++; c = substr(s, i, 1)
            if (c == "x" && i + 2 <= n) { out = out tolower(substr(s, i + 1, 2)); i += 2; continue }
            if (c == "n") { out = out "0a"; continue }
            if (c == "r") { out = out "0d"; continue }
            if (c == "t") { out = out "09"; continue }
            if (c == "e") { out = out "1b"; continue }
        }
        out = out HEX[c]
    }
    return out
}
BEGIN { init_hex() }
'

wpa_running() {
    [ -S "/run/wpa_supplicant/$WLAN_IFACE" ]
}

scan_results_json() {
    $WPA scan_results 2>/dev/null | $BB awk -F '\t' "$AWK_HEX"'
        NR == 1 { next }
        NF >= 4 {
            gsub(/"/, "", $4)
            printf "%s{\"bssid\":\"%s\",\"freq\":%d,\"signal\":%d,\"flags\":\"%s\",\"ssid_hex\":\"%s\"}", \
                (count++ ? "," : ""), $1, $2, $3, $4, wpa_to_hex($5)
        }
        END { if (!count) printf "" }'
}

current_uplink() {
    if [ -e /sys/class/net/usb0 ]; then
        echo usb0
    elif [ -e "/sys/class/net/$WLAN_IFACE" ]; then
        echo "$WLAN_IFACE"
    fi
}

route_ready() {
    uplink=$1
    [ -n "$uplink" ] || return 1
    if [ "$uplink" = usb0 ]; then
        THRURNDIS_RNDIS_IFACE=usb0 "$GATEWAY_SCRIPT" status >/dev/null 2>&1
    else
        THRURNDIS_RNDIS_IFACE=$uplink THRURNDIS_RNDIS_RESOLV_CONF=/run/thrurndis-wifi/resolv.conf \
            THRURNDIS_RNDIS_ALLOW_SUBNET_ONLY=1 "$GATEWAY_SCRIPT" status >/dev/null 2>&1
    fi
}

# A USB device that reached the VM but that no driver claimed, such as a
# dongle whose chip is not in vm/drivers.conf.
unsupported_usb() {
    for dev in /sys/bus/usb/devices/*; do
        [ -f "$dev/idVendor" ] || continue
        [ "$($BB cat "$dev/bDeviceClass" 2>/dev/null)" = 09 ] && continue
        claimed=no
        for intf in "$dev"/*:*; do
            [ -e "$intf/driver" ] && claimed=yes && break
        done
        if [ "$claimed" = no ]; then
            printf '%s:%s' "$($BB cat "$dev/idVendor")" "$($BB cat "$dev/idProduct")"
            return 0
        fi
    done
    return 1
}

action_status() {
    device=false
    [ -e "/sys/class/net/$WLAN_IFACE" ] && device=true

    wpa_state=""
    ssid_hex=""
    bssid=""
    freq=""
    key_mgmt=""
    rssi=""
    if wpa_running; then
        eval "$($WPA status 2>/dev/null | $BB awk -F '=' "$AWK_HEX"'
            $1 == "wpa_state" { printf "wpa_state=%s\n", $2 }
            $1 == "bssid" { printf "bssid=%s\n", $2 }
            $1 == "freq" { printf "freq=%s\n", $2 }
            $1 == "key_mgmt" { printf "key_mgmt=%s\n", $2 }
            $1 == "ssid" { sub(/^ssid=/, ""); printf "ssid_hex=%s\n", wpa_to_hex($0) }' |
            $BB grep -E '^(wpa_state|bssid|freq|key_mgmt|ssid_hex)=[0-9A-Za-z_:.-]*$')"
        rssi=$($WPA signal_poll 2>/dev/null | $BB awk -F '=' '$1 == "RSSI" { print $2 }')
    fi

    ipv4=""
    prefix=""
    gateway=""
    dns=""
    ip_source=""
    if [ -f /run/thrurndis-wifi/lease ]; then
        ipv4=$($BB awk -F '=' '$1 == "ip" { print $2 }' /run/thrurndis-wifi/lease)
        prefix=$($BB awk -F '=' '$1 == "prefix" { print $2 }' /run/thrurndis-wifi/lease)
        gateway=$($BB awk -F '=' '$1 == "gateway" { print $2 }' /run/thrurndis-wifi/lease)
        dns=$($BB awk -F '=' '$1 == "dns" { print $2 }' /run/thrurndis-wifi/lease)
        ip_source=$($BB awk -F '=' '$1 == "source" { print $2 }' /run/thrurndis-wifi/lease)
    fi
    # "conflict <mac>" when another host answered ARP for the static address.
    ip_error=""
    ip_conflict_mac=""
    if [ -f /run/thrurndis-wifi/ip-error ]; then
        read -r ip_error ip_conflict_mac </run/thrurndis-wifi/ip-error || true
    fi

    uplink=$(current_uplink)
    ready=false
    route_ready "$uplink" && ready=true

    configured=$($BB cat /run/thrurndis-wifi/network 2>/dev/null || true)

    # Latest wpa_supplicant verdict since the configuration last changed.
    auth_error=""
    if [ -n "$configured" ] && [ "$wpa_state" != COMPLETED ] && [ -f /run/thrurndis-wifi/messages ]; then
        last=$($BB awk '
            /thrurndis-wifi: configuration changed/ { last = ""; next }
            /CTRL-EVENT-(CONNECTED|SSID-TEMP-DISABLED|NETWORK-NOT-FOUND)/ { last = $0 }
            END { print last }' /run/thrurndis-wifi/messages)
        case "$last" in
            *reason=WRONG_KEY*) auth_error=wrong-key ;;
            *SSID-TEMP-DISABLED*) auth_error=auth-failed ;;
            *NETWORK-NOT-FOUND*) auth_error=not-found ;;
        esac
    fi
    usb_unsupported=""
    [ "$device" = false ] && usb_unsupported=$(unsupported_usb || true)
    usb_ids=$($BB cat /sys/class/net/"$WLAN_IFACE"/device/../idVendor 2>/dev/null || true)
    [ -n "$usb_ids" ] && usb_ids="$usb_ids:$($BB cat /sys/class/net/"$WLAN_IFACE"/device/../idProduct 2>/dev/null || true)"

    reply "{\"ok\":true,\"device\":$device,\"usb_id\":$(json_str "$usb_ids"),\"wpa_running\":$(wpa_running && echo true || echo false),\"wpa_state\":$(json_str "$wpa_state"),\"ssid_hex\":$(json_str "$ssid_hex"),\"bssid\":$(json_str "$bssid"),\"freq\":$(json_num "$freq"),\"rssi\":$(json_num "$rssi"),\"key_mgmt\":$(json_str "$key_mgmt"),\"ipv4\":$(json_str "$ipv4"),\"prefix\":$(json_num "$prefix"),\"gateway\":$(json_str "$gateway"),\"dns\":$(json_str "$dns"),\"uplink\":$(json_str "$uplink"),\"route_ready\":$ready,\"configured_ssid_hex\":$(json_str "$configured"),\"auth_error\":$(json_str "$auth_error"),\"ip_source\":$(json_str "$ip_source"),\"ip_error\":$(json_str "$ip_error"),\"ip_conflict_mac\":$(json_str "$ip_conflict_mac"),\"usb_unsupported\":$(json_str "$usb_unsupported"),\"boot_id\":$(json_str "$($BB cat /proc/sys/kernel/random/boot_id 2>/dev/null)")}"
}

action_results() {
    wpa_running || fail "no-wifi-device"
    reply "{\"ok\":true,\"results\":[$(scan_results_json)]}"
}

action_scan() {
    wpa_running || fail "no-wifi-device"
    $WPA scan >/dev/null 2>&1 || true
    $BB sleep 4
    action_results
}

action_connect() {
    [ "$REQUEST_METHOD" = POST ] || fail "post-required"
    length=${CONTENT_LENGTH:-0}
    case "$length" in
        ''|*[!0-9]*) fail "bad-length" ;;
    esac
    [ "$length" -le 2048 ] || fail "too-large"
    body=$($BB head -c "$length")

    ssid=$(param ssid "$body") || fail "bad-ssid"
    psk=$(param psk "$body" || true)
    sae=$(param sae "$body" || true)
    hidden=$(param hidden "$body" || echo 0)
    ip=$(param ip "$body" || true)
    prefix=$(param prefix "$body" || true)
    gw=$(param gw "$body" || true)
    dns=$(param dns "$body" || true)
    rt=$(param rt "$body" || true)

    /usr/local/sbin/thrurndis-wifi-config write "$ssid" "$psk" "$sae" "$hidden" "$ip" "$prefix" "$gw" "$dns" "$rt" \
        2>/dev/null || fail "invalid-network"
    /usr/local/sbin/thrurndis-wifi-config apply || true
    reply '{"ok":true}'
}

# Plain-text troubleshooting dump (kernel log, USB devices, Wi-Fi state).
action_diag() {
    printf 'Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
    echo "== release"; $BB cat /etc/thrurndis-wifi-release 2>/dev/null
    echo "== uname"; $BB uname -a
    echo "== usb devices"
    for dev in /sys/bus/usb/devices/*; do
        [ -f "$dev/idVendor" ] || continue
        echo "$(basename "$dev") $($BB cat "$dev/idVendor"):$($BB cat "$dev/idProduct") speed=$($BB cat "$dev/speed" 2>/dev/null) $($BB cat "$dev/product" 2>/dev/null)"
        for intf in "$dev"/*:*; do
            [ -d "$intf" ] || continue
            driver=$($BB readlink "$intf/driver" 2>/dev/null || true)
            echo "  $(basename "$intf") class=$($BB cat "$intf/bInterfaceClass" 2>/dev/null) driver=${driver##*/}"
        done
    done
    echo "== net"; ip -o link 2>&1
    echo "== addresses"; ip -4 -o addr 2>&1
    echo "== memory"; $BB free -m 2>&1
    echo "== drivers"; $BB cat /etc/thrurndis-wifi/drivers 2>&1
    echo "== modules"; $BB cat /proc/modules | $BB awk '{ print $1 }' | $BB tr '\n' ' '; echo
    echo "== wpa"; [ -S "/run/wpa_supplicant/$WLAN_IFACE" ] && $WPA status 2>&1
    echo "== iw link"; iw dev "$WLAN_IFACE" link 2>&1
    echo "== iw power_save"; iw dev "$WLAN_IFACE" get power_save 2>&1
    echo "== iw station"; iw dev "$WLAN_IFACE" station dump 2>&1 |
        $BB grep -E 'Station|signal|bitrate|tx retries|tx failed|rx drop|beacon loss|inactive'
    echo "== neighbours"; ip -4 neigh show dev "$WLAN_IFACE" 2>&1
    echo "== wpa_supplicant log"; $BB tail -n 20 /tmp/wpa_supplicant.log 2>/dev/null
    echo "== syslog"; $BB tail -n 80 /run/thrurndis-wifi/messages 2>/dev/null
    echo "== dmesg"; $BB dmesg 2>&1 | $BB tail -n 150
}

action_disconnect() {
    /usr/local/sbin/thrurndis-wifi-config clear 2>/dev/null || fail "clear-failed"
    /usr/local/sbin/thrurndis-wifi-config apply || true
    reply '{"ok":true}'
}

expected_token=$(cmdline_value thrurndis-wifi.token || true)
if [ -n "$expected_token" ]; then
    token=$(param token "${QUERY_STRING:-}" || true)
    [ "$token" = "$expected_token" ] || fail "unauthorized"
fi

case "$(param action "${QUERY_STRING:-}" || true)" in
    status) action_status ;;
    results) action_results ;;
    scan) action_scan ;;
    connect) action_connect ;;
    disconnect) action_disconnect ;;
    diag) action_diag ;;
    *) fail "unknown-action" ;;
esac
