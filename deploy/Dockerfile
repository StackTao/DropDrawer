FROM rust:1.93-slim-bookworm AS builder

WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev ca-certificates && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock ./
COPY crates/protocol ./crates/protocol
COPY crates/p2p-core ./crates/p2p-core
COPY crates/p2p-cli ./crates/p2p-cli
COPY crates/server ./crates/server

ARG CARGO_BUILD_JOBS=2
RUN CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS} cargo build --release --locked --bin dropdrawer-server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --create-home --shell /usr/sbin/nologin dropdrawer \
    && mkdir -p /data/blobs && chown -R 10001:10001 /data

COPY --from=builder /app/target/release/dropdrawer-server /usr/local/bin/dropdrawer-server

USER 10001:10001
ENV DROPDRAWER_BIND=0.0.0.0:8080
ENV DROPDRAWER_DB_PATH=/data/dropdrawer.db
ENV DROPDRAWER_LOCAL_STORAGE=/data/blobs
EXPOSE 8080

CMD ["dropdrawer-server"]
