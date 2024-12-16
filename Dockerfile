FROM docker.io/library/elixir:1.17-alpine as builder

COPY . /app
WORKDIR /app

ARG MIX_ENV=prod
ARG RELEASE_VERSION=0.1.0

RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get && \
    mix release yellow_dog --version "${RELEASE_VERSION}"

FROM docker.io/library/alpine:3.20

ARG RELEASE_VERSION=1.0.0
ENV RELEASE_VERSION="${RELEASE_VERSION}"

LABEL org.opencontainers.image.source https://github.com/gsmlg-dev/YellowDogDNS
LABEL maintainer="Jonathan Gao <gsmlg.com@gmail.com>"
LABEL RELEASE_VERSION="${RELEASE_VERSION}"

ENV YD_PORT=53 \
    YD_FORWARDER="8.8.8.8" \
    YD_FORWARDER_PORT=53

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

ENV TZ=Asia/Shanghai

RUN apk add --update --no-cache libncursesw libstdc++ \
    musl musl-utils musl-locales tzdata

COPY --from=builder /app/_build/prod/rel/yellow_dog /app

EXPOSE 53

CMD ["/app/bin/yellow_dog", "start"]
