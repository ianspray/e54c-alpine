# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ian Spray
FROM arm64v8/alpine:latest

RUN apk add --no-cache \
    alpine-sdk \
    alpine-conf \
    build-base \
    git \
    wget \
    curl \
    zstd \
    xz \
    gzip \
    dosfstools \
    e2fsprogs \
    parted \
    sfdisk \
    kmod \
    linux-headers \
    u-boot-tools \
    py3-yaml \
    python3 \
    autoconf \
    automake \
    libtool \
    pkgconf \
    confuse \
    confuse-dev \
    openssh \
    openssl \
    && rm -rf /var/cache/apk/*

WORKDIR /build

RUN mkdir -p /var/cache/distfiles /var/cache/apkcache /build/config \
    && git clone --depth 1 https://github.com/pengutronix/genimage /tmp/genimage \
    && cd /tmp/genimage \
    && ./autogen.sh \
    && ./configure \
    && make -j$(nproc) \
    && make install \
    && rm -rf /tmp/genimage

RUN adduser -D build && addgroup build abuild \
    && mkdir -p /var/log/abuild /home/build/.abuild \
    && chown -R build:build /var/log/abuild /home/build \
    && chmod 755 /var/log/abuild

COPY config/*.conf /build/config/
COPY scripts/ /build/scripts/
RUN chmod +x /build/scripts/apk/*.sh /build/scripts/fetch/*.sh /build/scripts/uboot/*.sh /build/scripts/kernel/*.sh /build/scripts/root/*.sh /build/scripts/image/*.sh

VOLUME ["/var/cache/distfiles", "/var/cache/apkcache", "/output"]

CMD ["/bin/sh"]