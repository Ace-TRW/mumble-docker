FROM ubuntu:24.04 AS base

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD netstat -tuln | grep -q 64738 || exit 1

ADD ./scripts/* /mumble/scripts/
WORKDIR /mumble/scripts

ARG DEBIAN_FRONTEND=noninteractive
ARG MUMBLE_VERSION=latest

# Consolidate RUN commands and clean up in the same layer
RUN apt-get update && apt-get install --no-install-recommends -y \
    libcap2 \
    libcap2-bin \
    libzeroc-ice3.7t64 \
    '^libprotobuf[0-9]+$' \
    libavahi-compat-libdnssd1 \
    ca-certificates \
    iproute2 \
    net-tools \
    && export QT_VERSION="$( /mumble/scripts/choose_qt_version.sh )" \
    && /mumble/scripts/install_qt.sh \
    && find /lib* /usr/lib* -name 'libQt?Core.so.*' -exec strip --remove-section=.note.ABI-tag {} \; \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /data

FROM base AS build
ARG DEBIAN_FRONTEND=noninteractive

ADD ./scripts/* /mumble/scripts/
WORKDIR /mumble/repo

RUN apt-get update && apt-get install --no-install-recommends -y \
    git cmake build-essential ca-certificates pkg-config \
    libssl-dev \
    libboost-dev \
    libprotobuf-dev \
    protobuf-compiler \
    libprotoc-dev \
    libcap-dev \
    libxi-dev \
    libavahi-compat-libdnssd-dev \
    libzeroc-ice-dev \
    python3 \
    git \
    && export QT_VERSION="$( /mumble/scripts/choose_qt_version.sh )" \
    && /mumble/scripts/install_qt_dev.sh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ARG MUMBLE_VERSION=latest
ARG MUMBLE_BUILD_NUMBER=""
ARG MUMBLE_CMAKE_ARGS=""

# Clone the repo, build it and finally copy the default server ini file. Since this file may be at different locations and Docker
# doesn't support conditional copies, we have to ensure that regardless of where the file is located in the repo, it will end
# up at a unique path in our build container to be copied further down.
RUN /mumble/scripts/clone.sh \
    && /mumble/scripts/build.sh \
    && /mumble/scripts/copy_one_of.sh ./scripts/murmur.ini ./auxiliary_files/mumble-server.ini default_config.ini

RUN git clone https://github.com/ncopa/su-exec.git /mumble/repo/su-exec \
    && cd /mumble/repo/su-exec && make

# Final stage
FROM base

COPY --from=build /mumble/repo/build/mumble-server /usr/bin/mumble-server
COPY --from=build /mumble/repo/default_config.ini /etc/mumble/bare_config.ini
COPY --from=build --chmod=755 /mumble/repo/su-exec/su-exec /usr/local/bin/su-exec

# Create required directories
RUN mkdir -p /data /run/secrets

# Set default environment variables
ENV PUID=10000 \
    PGID=10000 \
    TZ=UTC

# Create mumble user and set permissions
RUN groupadd -g 10000 mumble && \
    useradd -u 10000 -g mumble -d /data -s /sbin/nologin mumble && \
    chown -R mumble:mumble /data

# Copy config file from project root
COPY mumble_server_config.ini /mumble_server_config.ini
RUN chown mumble:mumble /mumble_server_config.ini

# Set capabilities on the binary
RUN setcap 'cap_net_bind_service=+ep' /usr/bin/mumble-server

EXPOSE 64738/tcp 64738/udp
COPY entrypoint.sh /entrypoint.sh

VOLUME ["/data"]

# Use su-exec to drop privileges
CMD ["su-exec", "mumble:mumble", "/usr/bin/mumble-server", "-fg", "-ini", "/mumble_server_config.ini"]

