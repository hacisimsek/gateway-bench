//! JWT validation middleware: RS256 signature, `exp` and `iss` on every proxied request.
//! Same rules as Spring Security's resource server, including 60 s clock skew.

use std::sync::Arc;

use axum::{
    extract::{Request, State},
    http::{HeaderValue, StatusCode, header},
    middleware::Next,
    response::{IntoResponse, Response},
};
use jsonwebtoken::{Algorithm, DecodingKey, Validation, decode};

pub struct JwtVerifier {
    key: DecodingKey,
    validation: Validation,
}

impl JwtVerifier {
    pub fn load(public_key_file: &str, issuer: &str) -> Self {
        let pem = std::fs::read(public_key_file).unwrap_or_else(|e| panic!("cannot read {public_key_file}: {e}"));
        let key = DecodingKey::from_rsa_pem(&pem).unwrap_or_else(|e| panic!("invalid key {public_key_file}: {e}"));
        let mut validation = Validation::new(Algorithm::RS256); // also rejects any other alg, e.g. "none"
        validation.set_issuer(&[issuer]);
        validation.leeway = 60;
        Self { key, validation }
    }

    fn verify(&self, authorization: Option<&HeaderValue>) -> bool {
        bearer_token(authorization)
            .is_some_and(|t| decode::<serde_json::Value>(t, &self.key, &self.validation).is_ok())
    }
}

fn bearer_token(authorization: Option<&HeaderValue>) -> Option<&str> {
    authorization?.to_str().ok()?.strip_prefix("Bearer ")
}

pub async fn require_jwt(State(verifier): State<Arc<JwtVerifier>>, req: Request, next: Next) -> Response {
    if verifier.verify(req.headers().get(header::AUTHORIZATION)) {
        next.run(req).await
    } else {
        (StatusCode::UNAUTHORIZED, [(header::WWW_AUTHENTICATE, "Bearer")]).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_bearer_scheme_is_accepted() {
        let v = |s: &'static str| HeaderValue::from_static(s);
        assert_eq!(bearer_token(Some(&v("Bearer abc"))), Some("abc"));
        assert_eq!(bearer_token(Some(&v("Basic abc"))), None);
        assert_eq!(bearer_token(Some(&v("bearerabc"))), None);
        assert_eq!(bearer_token(None), None);
    }
}
