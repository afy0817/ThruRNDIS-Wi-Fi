# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Cached build environment: the kernel, firmware and regdb packages are the
# slow downloads, so they live in this image instead of every build run.
ARG ALPINE_IMAGE=alpine:3.24
FROM ${ALPINE_IMAGE}
# Set by vm/build.sh from the pkg= fields of vm/drivers.conf.
ARG FIRMWARE_PACKAGES="linux-firmware-rtw89"
RUN apk add --no-progress --quiet python3 kmod linux-lts wireless-regdb ${FIRMWARE_PACKAGES}
