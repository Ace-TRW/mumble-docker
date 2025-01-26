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
ENV MUMBLE_CONFIG_WELCOMETEXT="<h1>Welcome to The Real World's Chat Server!</h1>" \
    MUMBLE_CONFIG_USERS=100 \
    MUMBLE_CONFIG_BANDWIDTH=128000 \
    MUMBLE_CONFIG_SERVERPASSWORD="TRWMasterChat%99" \
    MUMBLE_CONFIG_ALLOWPING=true \
    MUMBLE_CONFIG_CERTREQUIRED=false \
    MUMBLE_CONFIG_REMEMBERCHANNEL=true \
    MUMBLE_CONFIG_ALLOWHTML=true \
    MUMBLE_CONFIG_DEFAULTCHANNEL=1 \
    MUMBLE_CONFIG_ROOT="TRW" \
    PUID=10000 \
    PGID=10000 \
    TZ=UTC

EXPOSE 64738/tcp 64738/udp
COPY entrypoint.sh /entrypoint.sh

VOLUME ["/data"]
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/mumble-server", "-fg"]

