# Build stage
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.4.2
ARG ALPINE_VERSION=3.21.6

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

# Tailscale binaries — pinned to 1.96.5 (latest stable Docker Hub image;
# tailscale/tailscale container tags lag the static-binary releases, so
# there is no v1.98.x image — v1.96.5 is current stable and clears the
# security advisory that flagged the old v1.82.5).
FROM tailscale/tailscale:v1.96.5 AS tailscale

# Runtime stage
FROM alpine:${ALPINE_VERSION} AS runtime

RUN apk add --no-cache libstdc++ libgcc openssl ncurses-libs sqlite-libs

WORKDIR /app

ENV MIX_ENV=prod
ENV PORT=8080
ENV DATABASE_PATH=/data/audit.db

# Create data directory for volume mount point
RUN mkdir -p /data

# Create Tailscale state directory
RUN mkdir -p /var/lib/tailscale

# Copy Tailscale binaries
COPY --from=tailscale /usr/local/bin/tailscale /usr/local/bin/tailscale
COPY --from=tailscale /usr/local/bin/tailscaled /usr/local/bin/tailscaled

# Copy release from build stage
COPY --from=build /app/_build/prod/rel/ex_code_remote ./

# Copy entrypoint script
COPY rel/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 8080

# Entrypoint runs as root so tailscaled can bind sockets, then the
# Elixir release drops to nobody via the exec. In practice on Fly,
# the single-process-per-machine model makes this acceptable.
# tailscaled requires root for userspace networking socket operations.
ENTRYPOINT ["/app/entrypoint.sh"]
