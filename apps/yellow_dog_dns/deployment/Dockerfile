# Yellow Dog DNS - Production Dockerfile
# Multi-stage build for minimal production image

# Stage 1: Build
FROM hexpm/elixir:1.18.1-erlang-27.2.1-alpine-3.21.2 AS builder

# Install build dependencies
RUN apk add --no-cache \
    git \
    build-base \
    npm

# Set build environment
ENV MIX_ENV=prod

# Create app directory
WORKDIR /app

# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files
COPY mix.exs mix.lock ./
COPY config config

# Copy umbrella apps (if needed)
COPY apps/yellow_dog/mix.exs apps/yellow_dog/
COPY apps/yellow_dog_dns/mix.exs apps/yellow_dog_dns/
COPY apps/yellow_dog_telemetry/mix.exs apps/yellow_dog_telemetry/
COPY apps/abyss/mix.exs apps/abyss/
COPY apps/ex_dns/mix.exs apps/ex_dns/

# Install dependencies
RUN mix deps.get --only prod && \
    mix deps.compile

# Copy application source
COPY apps/yellow_dog apps/yellow_dog
COPY apps/yellow_dog_dns apps/yellow_dog_dns
COPY apps/yellow_dog_telemetry apps/yellow_dog_telemetry
COPY apps/abyss apps/abyss
COPY apps/ex_dns apps/ex_dns

# Compile application
RUN mix compile

# Build release
RUN mix release yellow_dog

# Stage 2: Runtime
FROM alpine:3.21.2 AS runtime

# Install runtime dependencies
RUN apk add --no-cache \
    ncurses-libs \
    libstdc++ \
    libgcc \
    openssl

# Create user and group
RUN addgroup -g 1000 yellow-dog && \
    adduser -D -u 1000 -G yellow-dog yellow-dog

# Create directories
RUN mkdir -p /opt/yellow-dog/config \
             /opt/yellow-dog/zones \
             /opt/yellow-dog/data \
             /opt/yellow-dog/logs && \
    chown -R yellow-dog:yellow-dog /opt/yellow-dog

# Set working directory
WORKDIR /opt/yellow-dog

# Copy release from builder
COPY --from=builder --chown=yellow-dog:yellow-dog /app/_build/prod/rel/yellow_dog ./

# Copy example configuration
COPY --chown=yellow-dog:yellow-dog apps/yellow_dog_dns/config/prod.toml.example ./config/
COPY --chown=yellow-dog:yellow-dog apps/yellow_dog_dns/config/views.toml.example ./config/

# Switch to non-root user
USER yellow-dog

# Expose ports
# DNS
EXPOSE 53/udp 53/tcp
# DHCPv4
EXPOSE 67/udp
# DHCPv6
EXPOSE 547/udp
# Metrics (Prometheus)
EXPOSE 9090/tcp

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD bin/yellow_dog rpc "YellowDog.Dns.status()" || exit 1

# Set environment
ENV MIX_ENV=prod \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# Volume mounts for persistent data
VOLUME ["/opt/yellow-dog/config", "/opt/yellow-dog/zones", "/opt/yellow-dog/data", "/opt/yellow-dog/logs"]

# Start the application
CMD ["bin/yellow_dog", "start"]
