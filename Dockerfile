FROM docker.io/library/elixir:1.17-alpine AS builder

COPY . /app
WORKDIR /app

ARG MIX_ENV=prod
ARG RELEASE_VERSION=1.1.1

RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get && \
    mix release yellow_dog --version "${RELEASE_VERSION}"

FROM docker.io/library/alpine:3.20

ARG RELEASE_VERSION=1.1.1
ENV RELEASE_VERSION="${RELEASE_VERSION}"

LABEL org.opencontainers.image.source="https://github.com/gsmlg-dev/YellowDogDNS"
LABEL org.opencontainers.image.version="${RELEASE_VERSION}"
LABEL org.opencontainers.image.title="YellowDogDNS"
LABEL org.opencontainers.image.description="A DNS Server write in Elixir"
LABEL volume.config="/etc/yellowdog.toml"
LABEL maintainer="Jonathan Gao <gsmlg.com@gmail.com>"
LABEL RELEASE_VERSION="${RELEASE_VERSION}"

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

ENV TZ=Asia/Shanghai

# VOLUME ["/etc/yellowdog.toml"]

RUN apk add --update --no-cache libncursesw libstdc++ \
    musl musl-utils musl-locales tzdata

COPY --from=builder /app/_build/prod/rel/yellow_dog /app
COPY priv/yellowdogdns_default_config.toml /etc/yellowdog.toml

EXPOSE 53

CMD ["/app/bin/yellow_dog", "start"]
