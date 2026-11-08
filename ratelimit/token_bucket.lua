-- Token bucket rate limiter, shared by gateway-rust and gateway-java (same file, same Redis).
-- Runs atomically inside Redis, so concurrent requests from any number of gateway pods
-- can never take the same token twice.
--
-- KEYS[1] bucket key, "rl:" + the JWT subject
-- ARGV[1] refill rate, tokens per second
-- ARGV[2] capacity (burst)
-- Returns { allowed (1 or 0), tokens left (rounded down), ms until the next token (0 if allowed) }

local rate = tonumber(ARGV[1])
local capacity = tonumber(ARGV[2])

-- Redis' own clock, so gateways with skewed clocks still agree.
local time = redis.call('TIME')
local now = tonumber(time[1]) * 1000 + math.floor(tonumber(time[2]) / 1000)

local bucket = redis.call('HMGET', KEYS[1], 'tokens', 'ts')
local tokens = tonumber(bucket[1]) or capacity
local last = tonumber(bucket[2]) or now

tokens = math.min(capacity, tokens + math.max(0, now - last) * rate / 1000)

local allowed = 0
local wait_ms = 0
if tokens >= 1 then
  tokens = tokens - 1
  allowed = 1
else
  wait_ms = math.ceil((1 - tokens) * 1000 / rate)
end

redis.call('HSET', KEYS[1], 'tokens', tokens, 'ts', now)
-- A bucket left alone refills completely; after that it carries no information.
redis.call('PEXPIRE', KEYS[1], math.ceil(capacity * 1000 / rate) + 1000)

return { allowed, math.floor(tokens), wait_ms }
