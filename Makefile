# Everything builds and tests inside Docker: no local Rust or Java 25 install needed.
RUST_IMAGE := rust:1.98.1-slim-trixie
JDK_IMAGE  := eclipse-temurin:25-jdk-noble
RUST_CRATES := upstream gateway-rust

.PHONY: lock test build keys up down smoke smoke-auth bench-jwt

lock: ## Regenerate Cargo.lock files
	@for c in $(RUST_CRATES); do docker run --rm -v "$(CURDIR)/$$c":/app -w /app $(RUST_IMAGE) cargo generate-lockfile; done

test: ## Run unit tests for all services
	@for c in $(RUST_CRATES); do docker run --rm -v "$(CURDIR)/$$c":/app -w /app $(RUST_IMAGE) cargo test --locked -q; done
	docker run --rm -v "$(CURDIR)/gateway-java":/app -v gateway-bench-m2:/root/.m2 -w /app $(JDK_IMAGE) ./mvnw -q -B test

build: ## Build all images
	docker compose build

keys: .keys/public.pem ## Dev RSA key pair for signing test JWTs (never committed)

.keys/public.pem:
	mkdir -p .keys
	openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out .keys/private.pem 2>/dev/null
	openssl pkey -in .keys/private.pem -pubout -out .keys/public.pem

up: .keys/public.pem ## Start the local stack
	docker compose up -d --build

down:
	docker compose down

smoke: ## Check every service answers its health endpoint
	curl -fsS localhost:9000/healthz && echo " upstream"
	curl -fsS localhost:8081/healthz && echo " gateway-rust"
	curl -fsS localhost:8082/actuator/health/readiness && echo " gateway-java"

smoke-auth: .keys/public.pem ## Same JWT cases against both gateways
	scripts/smoke-auth.sh

# Gateways require a JWT since phase 2, so every gateway benchmark sends one.
# Phase 1's no-auth numbers stay in bench/results/s1/20261107-164406.
bench-jwt: .keys/public.pem ## Passthrough with a valid JWT on every request (rust, java), ~16 min
	ONLY="rust java" LABEL=jwt TOKEN=$$(scripts/mint-jwt.sh 7200) bench/run-s1.sh 3
