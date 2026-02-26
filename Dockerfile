FROM docker.io/library/elixir:1.19-alpine AS builder

RUN apk add --no-cache git

COPY . /app
WORKDIR /app

ARG MIX_ENV=prod
ARG RELEASE_VERSION=1.1.1

RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get && \
    mix release yellow_dog --version "${RELEASE_VERSION}"

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
             /data/yellowdog/mdns \
             /data/yellowdog/identity/hosts \
             /data/yellowdog/identity/tokens

COPY --from=builder /app/_build/prod/rel/yellow_dog /app
COPY priv/yellowdogdns_default_config.toml /etc/yellowdog/config.toml

EXPOSE 53 67/udp 547/udp 5353/udp 4270

CMD ["/app/bin/yellow_dog", "start"]

