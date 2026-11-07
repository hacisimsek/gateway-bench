//! Forwards a request to the matching route's upstream over a pooled hyper client.

use std::sync::Arc;

use axum::{
    body::Body,
    extract::{Request, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
};
use hyper_util::client::legacy::{Client, connect::HttpConnector};

use crate::config::Config;

pub type HttpClient = Client<HttpConnector, Body>;

pub struct AppState {
    pub config: Config,
    pub client: HttpClient,
}

/// Headers that describe one TCP hop and must not be forwarded (RFC 9110 §7.6.1).
const HOP_BY_HOP: [header::HeaderName; 7] = [
    header::CONNECTION,
    header::PROXY_AUTHENTICATE,
    header::PROXY_AUTHORIZATION,
    header::TE,
    header::TRAILER,
    header::TRANSFER_ENCODING,
    header::UPGRADE,
];

pub async fn proxy(State(state): State<Arc<AppState>>, mut req: Request) -> Response {
    let Some(route) = state.config.find(req.uri().path()) else {
        return StatusCode::NOT_FOUND.into_response();
    };

    let path_and_query = req.uri().path_and_query().map_or("/", |p| p.as_str());
    let Ok(uri) = format!("{}{}", route.uri, path_and_query).parse() else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    *req.uri_mut() = uri;
    strip_hop_by_hop(req.headers_mut());
    // Let the client set Host from the upstream URI instead of forwarding the gateway's.
    req.headers_mut().remove(header::HOST);

    match state.client.request(req).await {
        Ok(res) => {
            let (mut parts, body) = res.into_parts();
            strip_hop_by_hop(&mut parts.headers);
            Response::from_parts(parts, Body::new(body))
        }
        Err(e) => {
            eprintln!("route {}: upstream error: {e}", route.id);
            StatusCode::BAD_GATEWAY.into_response()
        }
    }
}

fn strip_hop_by_hop(headers: &mut HeaderMap) {
    for name in HOP_BY_HOP {
        headers.remove(name);
    }
    headers.remove("keep-alive");
}
