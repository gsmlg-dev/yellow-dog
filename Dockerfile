FROM docker.io/library/elixir:1.19-alpine AS builder

# Install Rust/Cargo for Rustler NIFs (netlink_helper port binary)
RUN apk add --no-cache rust cargo

WORKDIR /app

ARG MIX_ENV=prod
ARG RELEASE_VERSION=1.1.2

# Install hex and rebar (cached unless base image changes)
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy dependency manifests first for better layer caching
COPY mix.exs mix.lock ./
COPY apps/abyss/mix.exs apps/abyss/mix.exs
COPY apps/ex_dhcp/mix.exs apps/ex_dhcp/mix.exs
COPY apps/ex_dns/mix.exs apps/ex_dns/mix.exs
COPY apps/geo_ip_db/mix.exs apps/geo_ip_db/mix.exs
COPY apps/yellow_dog/mix.exs apps/yellow_dog/mix.exs
COPY apps/yellow_dog_dhcp_client/mix.exs apps/yellow_dog_dhcp_client/mix.exs
COPY apps/yellow_dog_dhcpv4/mix.exs apps/yellow_dog_dhcpv4/mix.exs
COPY apps/yellow_dog_dhcpv6/mix.exs apps/yellow_dog_dhcpv6/mix.exs
COPY apps/yellow_dog_dns/mix.exs apps/yellow_dog_dns/mix.exs
COPY apps/yellow_dog_fingerprint/mix.exs apps/yellow_dog_fingerprint/mix.exs
COPY apps/yellow_dog_identity/mix.exs apps/yellow_dog_identity/mix.exs
COPY apps/yellow_dog_mdns/mix.exs apps/yellow_dog_mdns/mix.exs
COPY apps/yellow_dog_netboot/mix.exs apps/yellow_dog_netboot/mix.exs
COPY apps/yellow_dog_netman/mix.exs apps/yellow_dog_netman/mix.exs
COPY apps/yellow_dog_console/mix.exs apps/yellow_dog_console/mix.exs
COPY apps/yellow_dog_tasks/mix.exs apps/yellow_dog_tasks/mix.exs
COPY apps/yellow_dog_telemetry/mix.exs apps/yellow_dog_telemetry/mix.exs
COPY config config

RUN mix deps.get

# Pre-fetch Rust dependencies for better layer caching
COPY apps/yellow_dog_netman/native/netlink_helper/Cargo.toml \
     apps/yellow_dog_netman/native/netlink_helper/Cargo.lock \
     apps/yellow_dog_netman/native/netlink_helper/
RUN cd apps/yellow_dog_netman/native/netlink_helper && \
    mkdir -p src && echo 'fn main() {}' > src/main.rs && \
    cargo build --release --quiet 2>/dev/null; \
    rm -rf src target/release/netlink_helper target/release/deps/netlink_helper*

# Copy full source
COPY . .

# Build Rust netlink_helper port binary for netman
RUN cd apps/yellow_dog_netman/native/netlink_helper && \
    cargo build --release --quiet && \
    mkdir -p ../../priv/native && \
    cp target/release/netlink_helper ../../priv/native/ && \
    chmod 755 ../../priv/native/netlink_helper

RUN mix release yellow_dog --version "${RELEASE_VERSION}"

FROM docker.io/library/alpine:3.23

ARG RELEASE_VERSION=1.1.2
ENV RELEASE_VERSION="${RELEASE_VERSION}"

LABEL org.opencontainers.image.source="https://github.com/gsmlg-dev/yellow-dog"
LABEL org.opencontainers.image.version="${RELEASE_VERSION}"
LABEL org.opencontainers.image.title="YellowDog"
LABEL org.opencontainers.image.description="A DNS, DHCPv4, DHCPv6 and mDNS Server write in Elixir"
LABEL volume.config="/etc/yellowdog"
LABEL volume.data="/data/yellowdog"
LABEL maintainer="Jonathan Gao <gsmlg.com@gmail.com>"
LABEL RELEASE_VERSION="${RELEASE_VERSION}"

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

ENV SECRET_KEY_BASE=boMQsJiXanFZ9e/eym1I/UdZClqxvfARylCaLgM9zutHBe7dgURD9kMW86fe//W2

ENV TZ=Asia/Shanghai

# Configuration paths
ENV YELLOW_DOG_CONFIG=/etc/yellowdog/config.toml
ENV YELLOW_DOG_TASKS_CONFIG=/etc/yellowdog/tasks.toml
ENV YELLOW_DOG_DATA_DIR=/data/yellowdog

VOLUME ["/etc/yellowdog", "/data/yellowdog"]

RUN apk add --update --no-cache libncursesw libstdc++ \
    musl musl-utils musl-locales tzdata inotify-tools iproute2 && \
    mkdir -p /data/yellowdog/dns/zones \
             /data/yellowdog/dhcpv4 \
             /data/yellowdog/dhcpv6 \
             /data/yellowdog/mdns \
             /data/yellowdog/tasks \
             /etc/yellowdog/netman/profiles \
             /run/yellowdog

COPY --from=builder /app/_build/prod/rel/yellow_dog /app
COPY priv/yellow_dog_default_config.toml /etc/yellowdog/config.toml
COPY priv/yellow_dog_tasks_config.toml /etc/yellowdog/tasks.toml

EXPOSE 53 67/udp 69/udp 547/udp 5353/udp 4270

CMD ["/app/bin/yellow_dog", "start"]
