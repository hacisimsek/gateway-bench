FROM rust:1.98.1-slim-trixie AS build
WORKDIR /app
# Build dependencies first so they are cached until Cargo.toml/Cargo.lock change.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main() {}' > src/main.rs && cargo build --release --locked && rm -rf src
COPY src src
RUN touch src/main.rs && cargo build --release --locked

FROM debian:trixie-slim
COPY --from=build /app/target/release/gateway-rust /usr/local/bin/gateway-rust
USER 65534
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/gateway-rust"]
