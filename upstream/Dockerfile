FROM rust:1.98.1-slim-trixie AS build
WORKDIR /app
# Build dependencies first so they are cached until Cargo.toml/Cargo.lock change.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main() {}' > src/main.rs && cargo build --release --locked && rm -rf src
COPY src src
RUN touch src/main.rs && cargo build --release --locked

# distroless: glibc and CA certs, no shell or package manager; runs as uid 65532 (nonroot).
FROM gcr.io/distroless/cc-debian13:nonroot
COPY --from=build /app/target/release/upstream /usr/local/bin/upstream
EXPOSE 9000
ENTRYPOINT ["/usr/local/bin/upstream"]
