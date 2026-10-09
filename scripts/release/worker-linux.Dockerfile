# Build on the oldest supported runtime, independent of the host's Nix paths.
FROM docker.io/library/rust:1.85.1-slim-bookworm AS rust
FROM docker.io/hexpm/elixir:1.19.6-erlang-28.3.3-debian-bookworm-20261005-slim AS builder

COPY --from=rust /usr/local/cargo /usr/local/cargo
COPY --from=rust /usr/local/rustup /usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo RUSTUP_HOME=/usr/local/rustup
ENV PATH=/usr/local/cargo/bin:$PATH
ENV MIX_ENV=prod LANG=C.UTF-8 ERL_FLAGS="+S 2:2 +A 2"
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates git && rm -rf /var/lib/apt/lists/* && \
    mix local.hex --force && mix local.rebar --force

COPY . .
ARG RELEASE_VERSION
RUN mix deps.get --only prod && mix compile --warnings-as-errors && \
    mix release yellow_dog_worker --version "$RELEASE_VERSION" --overwrite
ARG SOURCE_COMMIT
RUN mkdir -p /package/examples /out && \
    cp -a _build/prod/rel/yellow_dog_worker/. /package/ && \
    cp apps/yellow_dog_worker/examples/*.toml /package/examples/ && \
    cp scripts/release/worker-linux-README.md /package/README.md && \
    cp LICENSE /package/LICENSE && \
    printf 'version=%s\nsource_commit=%s\nplatform=linux-x86_64\nbaseline=debian-12-glibc-2.36\n' \
      "$RELEASE_VERSION" "$SOURCE_COMMIT" > /package/BUILD.txt && \
    cd /out && \
    tar -czf "yellow-dog-worker-v${RELEASE_VERSION}-linux-x86_64.tar.gz" -C /package . && \
    sha256sum "yellow-dog-worker-v${RELEASE_VERSION}-linux-x86_64.tar.gz" > \
      "yellow-dog-worker-v${RELEASE_VERSION}-linux-x86_64.tar.gz.sha256"

FROM scratch AS artifact
COPY --from=builder /out/ /
