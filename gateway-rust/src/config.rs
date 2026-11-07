//! Route table loaded from YAML (a ConfigMap in Kubernetes), so routes change without a rebuild.

use axum::http::Uri;
use serde::Deserialize;

#[derive(Debug, Deserialize)]
pub struct Config {
    pub routes: Vec<Route>,
}

#[derive(Debug, Deserialize)]
pub struct Route {
    pub id: String,
    /// Path prefix: `/users` matches `/users` and `/users/42`, not `/usersx`.
    /// Same behaviour as Spring's `Path=/users/**`.
    pub path: String,
    /// Upstream base URI, e.g. `http://upstream:9000`.
    pub uri: String,
}

impl Config {
    pub fn load(file: &str) -> Self {
        let text = std::fs::read_to_string(file).unwrap_or_else(|e| panic!("cannot read {file}: {e}"));
        Self::parse(&text).unwrap_or_else(|e| panic!("invalid {file}: {e}"))
    }

    fn parse(text: &str) -> Result<Self, String> {
        let mut config: Config = serde_yaml_ng::from_str(text).map_err(|e| e.to_string())?;
        for r in &mut config.routes {
            r.uri.parse::<Uri>().map_err(|e| format!("route {}: bad uri {}: {e}", r.id, r.uri))?;
            r.uri = r.uri.trim_end_matches('/').to_string();
        }
        // Longest prefix first, so `/users/admin` wins over `/users`.
        config.routes.sort_by_key(|r| std::cmp::Reverse(r.path.len()));
        Ok(config)
    }

    pub fn find(&self, path: &str) -> Option<&Route> {
        self.routes.iter().find(|r| prefix_matches(&r.path, path))
    }
}

fn prefix_matches(prefix: &str, path: &str) -> bool {
    prefix == "/" || path.strip_prefix(prefix).is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
}

#[cfg(test)]
mod tests {
    use super::*;

    const YAML: &str = "
routes:
  - { id: users, path: /users, uri: http://users:9000/ }
  - { id: admin, path: /users/admin, uri: http://admin:9000 }
";

    #[test]
    fn longest_prefix_wins_and_respects_segment_boundary() {
        let c = Config::parse(YAML).unwrap();
        assert_eq!(c.find("/users").unwrap().id, "users");
        assert_eq!(c.find("/users/42").unwrap().id, "users");
        assert_eq!(c.find("/users/admin/1").unwrap().id, "admin");
        assert!(c.find("/usersx").is_none());
        assert!(c.find("/orders").is_none());
    }

    #[test]
    fn trailing_slash_is_trimmed_and_bad_uri_rejected() {
        assert_eq!(Config::parse(YAML).unwrap().find("/users").unwrap().uri, "http://users:9000");
        assert!(Config::parse("routes: [{ id: x, path: /x, uri: 'not a uri' }]").is_err());
    }
}
