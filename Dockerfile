FROM docker.io/library/elixir:1.19-slim AS builder

ENV MIX_ENV=prod
WORKDIR /app
ARG MIX_RELEASE_NAME=yellow_dog_worker
ARG RELEASE_VERSION=1.2.0

RUN case "${MIX_RELEASE_NAME}" in \
      yellow_dog_management|yellow_dog_worker) ;; \
      *) echo "invalid MIX_RELEASE_NAME: ${MIX_RELEASE_NAME}" >&2; exit 1 ;; \
    esac

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential ca-certificates cargo git rustc && \
    rm -rf /var/lib/apt/lists/* && \
    mix local.hex --force && mix local.rebar --force

COPY . .
RUN mix deps.get --only prod && \
    mix compile --warnings-as-errors && \
    mix release "${MIX_RELEASE_NAME}" --version "${RELEASE_VERSION}" --overwrite

FROM docker.io/library/debian:trixie-slim
ARG MIX_RELEASE_NAME=yellow_dog_worker
ARG RELEASE_VERSION=1.2.0
ENV MIX_RELEASE_NAME="${MIX_RELEASE_NAME}"
ENV LANG=C.UTF-8
ENV RELEASE_DISTRIBUTION=none
WORKDIR /app

LABEL org.opencontainers.image.source="https://github.com/gsmlg-dev/yellow-dog"
LABEL org.opencontainers.image.version="${RELEASE_VERSION}"
LABEL org.opencontainers.image.title="${MIX_RELEASE_NAME}"

RUN case "${MIX_RELEASE_NAME}" in \
      yellow_dog_management|yellow_dog_worker) ;; \
      *) echo "invalid MIX_RELEASE_NAME: ${MIX_RELEASE_NAME}" >&2; exit 1 ;; \
    esac && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates coreutils libatomic1 libncursesw6 libstdc++6 openssl util-linux && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/_build/prod/rel/${MIX_RELEASE_NAME} /app
RUN ln -s "/app/bin/${MIX_RELEASE_NAME}" /usr/local/bin/yellow_dog_release
EXPOSE 53/tcp 53/udp 4280/tcp
CMD ["/usr/local/bin/yellow_dog_release", "start"]
