# Build stage
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.4.2
ARG ALPINE_VERSION=3.21

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-alpine-${ALPINE_VERSION} AS build

RUN apk add --no-cache build-base git sqlite-dev

WORKDIR /app

ENV MIX_ENV=prod

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

# Install deps first for layer caching
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy application source
COPY config config
COPY lib lib
COPY priv priv

# Compile and build release
RUN mix compile
RUN mix release

# Runtime stage
FROM alpine:${ALPINE_VERSION} AS runtime

RUN apk add --no-cache libstdc++ libgcc openssl ncurses-libs sqlite-libs

# Create non-root user
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

ENV MIX_ENV=prod
ENV PORT=8080
ENV DATABASE_PATH=/data/audit.db

# Create data directory for volume mount point, owned by appuser
RUN mkdir -p /data && chown appuser:appgroup /data

# Copy release from build stage
COPY --from=build /app/_build/prod/rel/ex_code_remote ./

# Copy entrypoint script
COPY rel/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Own the app directory
RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 8080

ENTRYPOINT ["/app/entrypoint.sh"]
