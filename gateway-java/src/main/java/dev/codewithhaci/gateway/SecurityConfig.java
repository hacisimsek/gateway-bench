package dev.codewithhaci.gateway;

import java.security.interfaces.RSAPublicKey;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtValidators;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.web.SecurityFilterChain;

/**
 * Every proxied request needs a valid JWT; health checks stay open for Kubernetes probes.
 */
@Configuration
class SecurityConfig {

	/**
	 * Built by hand rather than via spring.security.oauth2.resourceserver.jwt.issuer-uri, which would
	 * try OIDC discovery at the issuer URL. Same rules as gateway-rust's JwtVerifier.
	 */
	@Bean
	JwtDecoder jwtDecoder(@Value("${gateway.jwt.public-key-location}") RSAPublicKey publicKey,
			@Value("${gateway.jwt.issuer}") String issuer) {
		NimbusJwtDecoder decoder = NimbusJwtDecoder.withPublicKey(publicKey).build(); // RS256 only
		decoder.setJwtValidator(JwtValidators.createDefaultWithIssuer(issuer)); // exp/nbf (60 s skew) + iss
		return decoder;
	}

	@Bean
	SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
		return http
				.authorizeHttpRequests(auth -> auth
						.requestMatchers("/actuator/health/**", "/actuator/prometheus").permitAll()
						.anyRequest().authenticated())
				.oauth2ResourceServer(oauth2 -> oauth2.jwt(Customizer.withDefaults()))
				// A gateway is stateless: no HTTP session, no CSRF token (no browser cookies involved).
				.sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
				.csrf(AbstractHttpConfigurer::disable)
				.build();
	}

}
