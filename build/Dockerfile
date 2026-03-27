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
    && rm -rf /tmp/genimage \
    && adduser -D build \
    && addgroup build abuild

COPY config/*.conf /build/config/

VOLUME ["/var/cache/distfiles", "/var/cache/apkcache", "/output"]

CMD ["/bin/sh"]