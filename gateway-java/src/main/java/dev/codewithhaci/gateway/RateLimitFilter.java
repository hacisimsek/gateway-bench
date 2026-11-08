package dev.codewithhaci.gateway;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Objects;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.Resource;
import org.springframework.dao.DataAccessException;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.script.DefaultRedisScript;
import org.springframework.data.redis.core.script.RedisScript;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Distributed rate limiting: one token bucket per JWT subject, stored in Redis.
 * Runs the same ratelimit/token_bucket.lua as gateway-rust, so both share every user's bucket.
 *
 * Spring Cloud Gateway Server MVC ships a Bucket4j-based rate limiter; we skip it so the
 * algorithm is byte-for-byte the one gateway-rust runs.
 *
 * As a plain servlet Filter bean it runs after Spring Security's filter chain (order -100),
 * so the token is already verified and its subject is in the SecurityContext.
 */
@Component
class RateLimitFilter extends OncePerRequestFilter {

	private static final Logger log = LoggerFactory.getLogger(RateLimitFilter.class);

	private final StringRedisTemplate redis;
	private final RedisScript<List> script;
	private final String perSecond;
	private final String burst;

	RateLimitFilter(StringRedisTemplate redis,
			@Value("${gateway.rate-limit.script-location}") Resource script,
			@Value("${gateway.rate-limit.per-second}") int perSecond,
			@Value("${gateway.rate-limit.burst}") int burst) throws IOException {
		this.redis = redis;
		// Read once at startup; DefaultRedisScript sends EVALSHA and falls back to EVAL.
		this.script = new DefaultRedisScript<>(script.getContentAsString(StandardCharsets.UTF_8), List.class);
		this.perSecond = Integer.toString(perSecond);
		this.burst = Integer.toString(burst);
		log.info("rate limit: {}/s per subject, burst {}", perSecond, burst);
	}

	@Override
	protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
			throws ServletException, IOException {
		// Health checks and other unauthenticated paths are not rate limited.
		if (!(SecurityContextHolder.getContext().getAuthentication() instanceof JwtAuthenticationToken jwt)) {
			chain.doFilter(request, response);
			return;
		}
		List<?> result;
		try {
			result = redis.execute(script, List.of("rl:" + Objects.requireNonNullElse(jwt.getName(), "")), perSecond, burst);
		}
		catch (DataAccessException e) {
			log.warn("rate limit skipped, redis error: {}", e.getMessage());
			chain.doFilter(request, response);
			return;
		}
		// { allowed (1/0), tokens left, ms until the next token }
		long allowed = (Long) result.get(0);
		long left = (Long) result.get(1);
		long waitMs = (Long) result.get(2);
		if (allowed == 1) {
			response.setHeader("X-RateLimit-Remaining", Long.toString(left));
			chain.doFilter(request, response);
		}
		else {
			response.setStatus(HttpStatus.TOO_MANY_REQUESTS.value());
			response.setHeader("Retry-After", Long.toString((waitMs + 999) / 1000));
			response.setHeader("X-RateLimit-Remaining", "0");
		}
	}

}
