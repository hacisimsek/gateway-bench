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
use serde::Deserialize;

/// The verified token's `sub` claim, handed to the rate limiter via request extensions.
#[derive(Clone)]
pub struct Subject(pub String);

#[derive(Deserialize)]
struct Claims {
    #[serde(default)]
    sub: String,
}

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

    fn verify(&self, authorization: Option<&HeaderValue>) -> Option<Subject> {
        let token = bearer_token(authorization)?;
        decode::<Claims>(token, &self.key, &self.validation).ok().map(|t| Subject(t.claims.sub))
    }
}

fn bearer_token(authorization: Option<&HeaderValue>) -> Option<&str> {
    authorization?.to_str().ok()?.strip_prefix("Bearer ")
}

pub async fn require_jwt(State(verifier): State<Arc<JwtVerifier>>, mut req: Request, next: Next) -> Response {
    match verifier.verify(req.headers().get(header::AUTHORIZATION)) {
        Some(subject) => {
            req.extensions_mut().insert(subject);
            next.run(req).await
        }
        None => (StatusCode::UNAUTHORIZED, [(header::WWW_AUTHENTICATE, "Bearer")]).into_response(),
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
