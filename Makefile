# Everything builds and tests inside Docker: no local Rust or Java 25 install needed.
RUST_IMAGE := rust:1.98.1-slim-trixie
JDK_IMAGE  := eclipse-temurin:25-jdk-noble
RUST_CRATES := upstream gateway-rust

.PHONY: lock test build up down smoke

lock: ## Regenerate Cargo.lock files
	@for c in $(RUST_CRATES); do docker run --rm -v "$(CURDIR)/$$c":/app -w /app $(RUST_IMAGE) cargo generate-lockfile; done

test: ## Run unit tests for all services
	@for c in $(RUST_CRATES); do docker run --rm -v "$(CURDIR)/$$c":/app -w /app $(RUST_IMAGE) cargo test --locked -q; done
	docker run --rm -v "$(CURDIR)/gateway-java":/app -v gateway-bench-m2:/root/.m2 -w /app $(JDK_IMAGE) ./mvnw -q -B test

build: ## Build all images
	docker compose build

up: ## Start the local stack
	docker compose up -d --build

down:
	docker compose down

smoke: ## Check every service answers its health endpoint
	curl -fsS localhost:9000/healthz && echo " upstream"
	curl -fsS localhost:8081/healthz && echo " gateway-rust"
	curl -fsS localhost:8082/actuator/health/readiness && echo " gateway-java"
