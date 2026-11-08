package dev.codewithhaci.gateway;

import static org.assertj.core.api.Assertions.assertThat;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

import org.junit.jupiter.api.Test;
import org.springframework.boot.micrometer.metrics.test.autoconfigure.AutoConfigureMetrics;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalManagementPort;
import org.springframework.boot.test.web.server.LocalServerPort;

// Valid, expired and wrong-issuer tokens are covered end to end for both gateways by `make smoke-auth`.
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
		properties = { "gateway.jwt.public-key-location=classpath:test-public.pem",
				"gateway.rate-limit.script-location=file:../ratelimit/token_bucket.lua" })
@AutoConfigureMetrics // tests disable metrics export by default; we check the Prometheus endpoint
class GatewayJavaApplicationTests {

	@LocalServerPort
	int port;

	@LocalManagementPort
	int managementPort;

	final HttpClient http = HttpClient.newHttpClient();

	int status(String path, String authorization) throws Exception {
		return status(port, path, authorization);
	}

	int status(int port, String path, String authorization) throws Exception {
		var request = HttpRequest.newBuilder(URI.create("http://localhost:" + port + path));
		if (authorization != null) {
			request.header("Authorization", authorization);
		}
		return http.send(request.build(), HttpResponse.BodyHandlers.discarding()).statusCode();
	}

	@Test
	void probesAndMetricsAreOpenOnTheManagementPortOnly() throws Exception {
		assertThat(status(managementPort, "/actuator/health/readiness", null)).isEqualTo(200);
		assertThat(status(managementPort, "/actuator/prometheus", null)).isEqualTo(200);
		assertThat(status("/actuator/prometheus", null)).isEqualTo(401);
	}

	@Test
	void proxiedRoutesRequireAValidToken() throws Exception {
		assertThat(status("/users/1", null)).isEqualTo(401);
		assertThat(status("/users/1", "Bearer not-a-jwt")).isEqualTo(401);
		assertThat(status("/users/1", "Basic dXNlcjpwYXNz")).isEqualTo(401);
	}

}
