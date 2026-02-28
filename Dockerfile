FROM docker.io/library/elixir:1.19-alpine AS builder

# Install git for fetching hex from GitHub, and Rust/Cargo for Rustler NIFs
RUN apk add --no-cache git rust cargo

WORKDIR /app

ARG MIX_ENV=prod
ARG RELEASE_VERSION=1.1.1

# Install hex and rebar (cached unless base image changes)
RUN mix archive.install github hexpm/hex branch latest --force && \
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
COPY apps/yellow_dog_telemetry/mix.exs apps/yellow_dog_telemetry/mix.exs
COPY config config

RUN mix deps.get

# Copy full source and build release
COPY . .
RUN mix release yellow_dog --version "${RELEASE_VERSION}"

FROM docker.io/library/alpine:3.23

ARG RELEASE_VERSION=1.1.1
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
ENV YELLOW_DOG_DATA_DIR=/data/yellowdog

VOLUME ["/etc/yellowdog", "/data/yellowdog"]

RUN apk add --update --no-cache libncursesw libstdc++ \
    musl musl-utils musl-locales tzdata inotify-tools && \
    mkdir -p /data/yellowdog/dns/zones \
             /data/yellowdog/dhcpv4 \
             /data/yellowdog/dhcpv6 \
             /data/yellowdog/mdns

COPY --from=builder /app/_build/prod/rel/yellow_dog /app
COPY priv/yellowdogdns_default_config.toml /etc/yellowdog/config.toml

EXPOSE 53 67/udp 547/udp 5353/udp 4270

CMD ["/app/bin/yellow_dog", "start"]
