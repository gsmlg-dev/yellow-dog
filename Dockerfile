FROM docker.io/library/elixir:1.19-slim AS builder

# Install Rust/Cargo for Rustler NIFs (netlink_helper port binary)
# WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#71
# Use glibc until duskmoon_oxc publishes musl precompiled NIFs.
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:$PATH

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      git \
      nodejs \
      npm \
      perl && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
      sh -s -- -y --profile minimal --default-toolchain 1.91.1 && \
    rustc --version && \
    cargo --version && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

ARG MIX_ENV=prod
ARG RELEASE_VERSION=1.1.2
ARG MIX_RELEASE_NAME=yellow_dog_server
# WORKAROUND(upstream): gsmlg-dev/ex_turso#6
ENV MIX_ENV="${MIX_ENV}"
ENV MIX_RELEASE_NAME="${MIX_RELEASE_NAME}"
ENV EX_TURSO_BUILD=1

RUN case "${MIX_RELEASE_NAME}" in \
      yellow_dog_management_core|yellow_dog_server|yellow_dog_netman) ;; \
      *) echo "invalid MIX_RELEASE_NAME: ${MIX_RELEASE_NAME}" >&2; exit 1 ;; \
    esac

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
COPY apps/yellow_dog_config/mix.exs apps/yellow_dog_config/mix.exs
COPY apps/yellow_dog_console/mix.exs apps/yellow_dog_console/mix.exs
COPY apps/yellow_dog_dhcp_client/mix.exs apps/yellow_dog_dhcp_client/mix.exs
COPY apps/yellow_dog_dhcpv4/mix.exs apps/yellow_dog_dhcpv4/mix.exs
COPY apps/yellow_dog_dhcpv6/mix.exs apps/yellow_dog_dhcpv6/mix.exs
COPY apps/yellow_dog_dns/mix.exs apps/yellow_dog_dns/mix.exs
COPY apps/yellow_dog_dns_provider/mix.exs apps/yellow_dog_dns_provider/mix.exs
COPY apps/yellow_dog_fingerprint/mix.exs apps/yellow_dog_fingerprint/mix.exs
COPY apps/yellow_dog_identity/mix.exs apps/yellow_dog_identity/mix.exs
COPY apps/yellow_dog_management_core/mix.exs apps/yellow_dog_management_core/mix.exs
COPY apps/yellow_dog_mdns/mix.exs apps/yellow_dog_mdns/mix.exs
COPY apps/yellow_dog_netboot/mix.exs apps/yellow_dog_netboot/mix.exs
COPY apps/yellow_dog_netman/mix.exs apps/yellow_dog_netman/mix.exs
COPY apps/yellow_dog_netman_agent/mix.exs apps/yellow_dog_netman_agent/mix.exs
COPY apps/yellow_dog_resolved/mix.exs apps/yellow_dog_resolved/mix.exs
COPY apps/yellow_dog_server_agent/mix.exs apps/yellow_dog_server_agent/mix.exs
COPY apps/yellow_dog_store/mix.exs apps/yellow_dog_store/mix.exs
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

RUN if [ "${MIX_RELEASE_NAME}" = "yellow_dog_netman" ]; then \
      cd apps/yellow_dog_netman/native/netlink_helper && \
      cargo build --release --quiet && \
      mkdir -p ../../priv/native && \
      cp target/release/netlink_helper ../../priv/native/ && \
      chmod 755 ../../priv/native/netlink_helper; \
    fi

RUN if [ "${MIX_RELEASE_NAME}" = "yellow_dog_management_core" ] || [ "${MIX_RELEASE_NAME}" = "yellow_dog_server" ]; then \
      cd apps/yellow_dog_console && \
      mix assets.setup && \
      mix assets.deploy; \
    fi

RUN mix release "${MIX_RELEASE_NAME}" --version "${RELEASE_VERSION}" --overwrite

FROM docker.io/library/debian:trixie-slim

ARG RELEASE_VERSION=1.1.2
ARG MIX_RELEASE_NAME=yellow_dog_server
ENV RELEASE_VERSION="${RELEASE_VERSION}"
ENV MIX_RELEASE_NAME="${MIX_RELEASE_NAME}"

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

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      inotify-tools \
      iproute2 \
      libatomic1 \
      libncursesw6 \
      libstdc++6 \
      locales \
      openssl \
      tzdata && \
    sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    locale-gen && \
    mkdir -p /data/yellowdog/dns/zones \
             /data/yellowdog/dhcpv4 \
             /data/yellowdog/dhcpv6 \
             /data/yellowdog/mdns \
             /data/yellowdog/tasks \
             /etc/yellowdog/netman/profiles \
             /run/yellowdog && \
    rm -rf /var/lib/apt/lists/*

RUN case "${MIX_RELEASE_NAME}" in \
      yellow_dog_management_core|yellow_dog_server|yellow_dog_netman) ;; \
      *) echo "invalid MIX_RELEASE_NAME: ${MIX_RELEASE_NAME}" >&2; exit 1 ;; \
    esac

COPY --from=builder /app/_build/prod/rel/${MIX_RELEASE_NAME} /app
COPY priv/yellow_dog_default_config.toml /etc/yellowdog/config.toml
COPY priv/yellow_dog_tasks_config.toml /etc/yellowdog/tasks.toml

RUN ln -s "/app/bin/${MIX_RELEASE_NAME}" /usr/local/bin/yellow_dog_release

EXPOSE 53 67/udp 69/udp 547/udp 5353/udp 4270

CMD ["/usr/local/bin/yellow_dog_release", "start"]
