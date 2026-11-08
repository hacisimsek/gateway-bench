# Everything builds and tests inside Docker: no local Rust or Java 25 install needed.
RUST_IMAGE := rust:1.98.1-slim-trixie
JDK_IMAGE  := eclipse-temurin:25-jdk-noble
RUST_CRATES := upstream gateway-rust

.PHONY: lock test build keys up down smoke smoke-auth smoke-ratelimit smoke-shutdown cold-start bench-jwt bench-s2 tools seal-secrets cluster cluster-down promote smoke-cluster

lock: ## Regenerate Cargo.lock files
	@for c in $(RUST_CRATES); do docker run --rm -v "$(CURDIR)/$$c":/app -w /app $(RUST_IMAGE) cargo generate-lockfile; done

test: ## Run unit tests for all services
	@for c in $(RUST_CRATES); do docker run --rm -v "$(CURDIR)/$$c":/app -w /app $(RUST_IMAGE) cargo test --locked -q; done
	docker run --rm -v "$(CURDIR)":/app -v gateway-bench-m2:/root/.m2 -w /app/gateway-java $(JDK_IMAGE) ./mvnw -q -B test

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
	curl -fsS localhost:9091/healthz && echo " gateway-rust"
	curl -fsS localhost:9092/actuator/health/readiness && echo " gateway-java"

smoke-auth: .keys/public.pem ## Same JWT cases against both gateways
	scripts/smoke-auth.sh

smoke-ratelimit: .keys/public.pem ## 429s, shared bucket and fail open, both gateways (stops Redis briefly)
	scripts/smoke-ratelimit.sh

smoke-shutdown: .keys/public.pem ## SIGTERM during a slow request: it must still finish (restarts both gateways)
	scripts/smoke-shutdown.sh

cold-start: ## Image size and time from docker start to ready, both gateways
	bench/cold-start.sh 5

# Gateways require a JWT since phase 2, so every gateway benchmark sends one.
# Phase 1's no-auth numbers stay in bench/results/s1/20261107-164406.
bench-jwt: .keys/public.pem ## Passthrough with a valid JWT on every request (rust, java), ~16 min
	ONLY="rust java" LABEL=jwt TOKEN=$$(scripts/mint-jwt.sh 7200) bench/run-s1.sh 3

# S2, full chain: JWT + rate limit (raised so nothing gets a 429) + metrics + 10% tracing.
# Phase 3's run without telemetry is bench/results/s1/20261108-100810-jwt-rl.
LABEL ?= s2
bench-s2: .keys/public.pem ## Full chain on every request (rust, java), ~16 min
	RATE_LIMIT_PER_SECOND=1000000 RATE_LIMIT_BURST=1000000 docker compose up -d gateway-rust gateway-java
	ONLY="rust java" LABEL=$(LABEL) TOKEN=$$(scripts/mint-jwt.sh 7200) bench/run-s1.sh 3; \
	  rc=$$?; docker compose up -d gateway-rust gateway-java; exit $$rc

# --- Kubernetes (phase 6): kind + Argo CD, environments synced from git -------------------
tools: ## kind and kubeseal into .bin/ (pinned, checksums verified)
	scripts/tools.sh

seal-secrets: tools ## Per-env JWT keys and sealed Redis passwords into deploy/overlays (private parts stay in .keys/)
	scripts/seal-secrets.sh

cluster: tools ## Create the kind cluster, install Argo CD, hand over to git
	scripts/cluster.sh up

cluster-down: ## Delete the kind cluster (keys in .keys/ survive, so sealed secrets stay valid)
	scripts/cluster.sh down

promote: ## Open a PR moving an image tag up: make promote FROM=test TO=preprod
	scripts/promote.sh $(FROM) $(TO)

ENV ?= test
smoke-cluster: ## Auth parity against a kind environment: make smoke-cluster ENV=prod
	RUST_URL=http://rust.$(ENV).localhost:8000 JAVA_URL=http://java.$(ENV).localhost:8000 \
	  JWT_KEY=.keys/$(ENV)/private.pem scripts/smoke-auth.sh
