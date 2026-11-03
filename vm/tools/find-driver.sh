#!/bin/sh
# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Which module of the VM kernel drives a USB device, and whether
# vm/drivers.conf already includes it. Uses the cached builder image
# (vm/build.sh creates it).
#   ./vm/tools/find-driver.sh 0bda:b812
# The USB ID is in macOS System Information (USB) or `ioreg -p IOUSB -l`.

set -eu

VM_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ID=${1:?usage: find-driver.sh <vendor:product>  e.g. 0bda:b812}
case "$ID" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
    *) echo "expected a USB ID like 0bda:b812" >&2; exit 2 ;;
esac
VENDOR=$(printf '%s' "${ID%%:*}" | tr 'a-f' 'A-F')
PRODUCT=$(printf '%s' "${ID##*:}" | tr 'a-f' 'A-F')

MODULES=$(docker run --rm --platform linux/arm64 thrurndis-wifi-builder sh -c \
    "grep -h 'usb:v${VENDOR}p${PRODUCT}d' /lib/modules/*/modules.alias | awk '{ print \$3 }' | sort -u")

if [ -z "$MODULES" ]; then
    echo "$ID: no module of the VM kernel lists this ID."
    echo "If the chip is supported under another ID, add newid=$ID/<that ID> to its line in vm/drivers.conf."
    exit 1
fi
for module in $MODULES; do
    if grep -q "^$module[[:space:]]*\($\|pkg=\|files=\|newid=\)" "$VM_DIR/drivers.conf"; then
        echo "$ID: $module (already in vm/drivers.conf)"
    else
        echo "$ID: $module (not in vm/drivers.conf yet: add a line for it)"
    fi
done
