//! Observability: Prometheus metrics, OpenTelemetry traces and JSON logs.
//! Configured like gateway-java, through the standard OTEL_* environment variables
//! (OTEL_SERVICE_NAME, OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_TRACES_SAMPLER, OTEL_TRACES_SAMPLER_ARG).

use std::time::{Duration, Instant};

use axum::{extract::Request, middleware::Next, response::Response};
use metrics_exporter_prometheus::{Matcher, PrometheusBuilder, PrometheusHandle};
use opentelemetry::{global, trace::TraceContextExt, trace::TracerProvider as _};
use opentelemetry_http::{HeaderExtractor, HeaderInjector};
use opentelemetry_otlp::SpanExporter;
use opentelemetry_sdk::{propagation::TraceContextPropagator, trace::SdkTracerProvider};
use tracing::{Instrument, Span, field::Empty, info_span};
use tracing_opentelemetry::OpenTelemetrySpanExt;
use tracing_subscriber::{EnvFilter, fmt, prelude::*};

/// Same name, unit and buckets as Micrometer's `http.server.requests` in gateway-java,
/// so one Grafana query works for both gateways.
const REQUESTS: &str = "http_server_requests_seconds";
const BUCKETS: [f64; 13] = [0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0];

pub fn init() -> (PrometheusHandle, SdkTracerProvider) {
    let prometheus = PrometheusBuilder::new()
        .set_buckets_for_metric(Matcher::Full(REQUESTS.into()), &BUCKETS)
        .and_then(PrometheusBuilder::install_recorder)
        .expect("prometheus recorder");
    // Batches spans on a background thread and sends them over OTLP/HTTP; sampling comes from env.
    let traces = SdkTracerProvider::builder()
        .with_batch_exporter(SpanExporter::builder().with_http().build().expect("otlp exporter"))
        .build();
    global::set_text_map_propagator(TraceContextPropagator::new());

    tracing_subscriber::registry()
        // The exporter's own HTTP client must not log into, and trace, itself.
        .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info,hyper=warn,reqwest=warn,opentelemetry=warn".into()))
        .with(fmt::layer().json().flatten_event(true).with_current_span(true).with_span_list(false))
        .with(tracing_opentelemetry::layer().with_tracer(traces.tracer("gateway-rust")))
        .init();
    (prometheus, traces)
}

/// Histograms are only folded into the rendered output on upkeep.
pub async fn run_upkeep(prometheus: PrometheusHandle) {
    loop {
        tokio::time::sleep(Duration::from_secs(5)).await;
        prometheus.run_upkeep();
    }
}

/// Outermost layer on proxied routes: one server span and one histogram sample per request,
/// including the ones auth (401) and the rate limiter (429) reject.
pub async fn observe(req: Request, next: Next) -> Response {
    let start = Instant::now();
    let method = req.method().clone();
    let span = info_span!("request",
        otel.name = %method, otel.kind = "server",
        http.request.method = %method, url.path = req.uri().path(),
        http.route = Empty, http.response.status_code = Empty, trace_id = Empty);
    // Continue the caller's trace if it sent a traceparent header.
    let _ = span.set_parent(global::get_text_map_propagator(|p| p.extract(&HeaderExtractor(req.headers()))));
    // Puts the trace id into every log line written while handling this request.
    span.record("trace_id", span.context().span().span_context().trace_id().to_string());

    let res = next.run(req).instrument(span.clone()).await;

    span.record("http.response.status_code", res.status().as_u16());
    metrics::histogram!(REQUESTS, "method" => method.to_string(), "status" => res.status().as_str().to_owned())
        .record(start.elapsed());
    res
}

/// Called by the proxy: names the route on the span and passes the trace on to the upstream.
pub fn propagate(route_id: &str, headers: &mut axum::http::HeaderMap) {
    let span = Span::current();
    span.record("http.route", route_id);
    global::get_text_map_propagator(|p| p.inject_context(&span.context(), &mut HeaderInjector(headers)));
}
