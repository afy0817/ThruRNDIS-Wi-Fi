# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Cached build environment: the kernel, firmware and regdb packages are the
# slow downloads, so they live in this image instead of every build run.
# linux-stable, not linux-lts: 6.18 LTS lacks the rtw89 USB TX flow control
# fix, and its dongles stop transmitting under a sustained upload.
ARG ALPINE_IMAGE=alpine:edge
FROM ${ALPINE_IMAGE}
# Set by vm/build.sh from the pkg= fields of vm/drivers.conf.
ARG FIRMWARE_PACKAGES="linux-firmware-rtw89"
RUN apk add --no-progress --quiet python3 kmod linux-stable wireless-regdb ${FIRMWARE_PACKAGES}
