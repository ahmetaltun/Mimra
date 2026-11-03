// ==============================================================================
// Mimra Core — URL Canonicalization & Recognition (F-006, T-TYPE-04)
// ==============================================================================

use crate::error::CoreError;
use serde::{Deserialize, Serialize};

/// Represents a validated and canonicalized URL.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct CanonicalUrl {
    /// Scheme in lower case (e.g. "https", "http")
    pub scheme: String,
    /// Hostname in lower case (e.g. "github.com", "example.com")
    pub host: String,
    /// Explicit port if non-default
    pub port: Option<u16>,
    /// Normalized path starting with '/'
    pub path: String,
    /// Query string if present (excluding '?')
    pub query: Option<String>,
    /// Fragment if present (excluding '#')
    pub fragment: Option<String>,
    /// Full normalized URL string
    pub normalized_url: String,
    /// Clean display domain (e.g. "github.com", without "www." prefix)
    pub domain: String,
}

impl CanonicalUrl {
    /// Parses and canonicalizes a raw URL string.
    ///
    /// Rules:
    /// - Scheme and host are converted to lower case.
    /// - Default ports (80 for http, 443 for https, 21 for ftp) are stripped.
    /// - Duplicate consecutive slashes in the path are collapsed.
    /// - Empty path for http/https is normalized to "/".
    /// - Domain is extracted by stripping leading "www.".
    pub fn parse(raw_url: &str) -> Result<Self, CoreError> {
        let trimmed = raw_url.trim();
        if trimmed.is_empty() {
            return Err(CoreError::InvalidInput {
                details: "URL string cannot be empty".to_string(),
            });
        }

        // Must have scheme separator
        let scheme_end = trimmed.find("://").ok_or_else(|| CoreError::InvalidInput {
            details: format!("Missing scheme separator '://' in URL: '{trimmed}'"),
        })?;

        let scheme = trimmed[..scheme_end].to_ascii_lowercase();
        if scheme != "http" && scheme != "https" && scheme != "ftp" {
            return Err(CoreError::InvalidInput {
                details: format!(
                    "Unsupported URL scheme '{scheme}'. Expected http, https, or ftp."
                ),
            });
        }

        let rest = &trimmed[scheme_end + 3..];
        if rest.is_empty() {
            return Err(CoreError::InvalidInput {
                details: "Missing host in URL".to_string(),
            });
        }

        // Split host/port from path/query/fragment
        let host_port_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
        let host_port = &rest[..host_port_end];
        let after_host = &rest[host_port_end..];

        if host_port.is_empty() {
            return Err(CoreError::InvalidInput {
                details: "Empty host in URL".to_string(),
            });
        }

        // Parse host and optional port
        let (raw_host, explicit_port) = if let Some(colon_idx) = host_port.rfind(':') {
            let host_part = &host_port[..colon_idx];
            let port_str = &host_port[colon_idx + 1..];
            let port = port_str
                .parse::<u16>()
                .map_err(|_| CoreError::InvalidInput {
                    details: format!("Invalid port number '{port_str}' in URL"),
                })?;
            (host_part, Some(port))
        } else {
            (host_port, None)
        };

        if raw_host.is_empty() || raw_host.contains(' ') {
            return Err(CoreError::InvalidInput {
                details: format!("Invalid host '{raw_host}' in URL"),
            });
        }

        let host = raw_host.to_ascii_lowercase();

        // Omit default ports
        let normalized_port = match (scheme.as_str(), explicit_port) {
            ("http", Some(80)) => None,
            ("https", Some(443)) => None,
            ("ftp", Some(21)) => None,
            (_, other) => other,
        };

        // Parse path, query, and fragment from after_host
        let (raw_path_and_query, fragment) = if let Some(hash_idx) = after_host.find('#') {
            (
                &after_host[..hash_idx],
                Some(after_host[hash_idx + 1..].to_string()),
            )
        } else {
            (after_host, None)
        };

        let (raw_path, query) = if let Some(query_idx) = raw_path_and_query.find('?') {
            (
                &raw_path_and_query[..query_idx],
                Some(raw_path_and_query[query_idx + 1..].to_string()),
            )
        } else {
            (raw_path_and_query, None)
        };

        // Normalize path: collapse multiple slashes, ensure starts with '/' for http/https
        let normalized_path = if raw_path.is_empty() {
            "/".to_string()
        } else {
            let mut collapsed = String::with_capacity(raw_path.len());
            let mut last_was_slash = false;
            for c in raw_path.chars() {
                if c == '/' {
                    if !last_was_slash {
                        collapsed.push(c);
                        last_was_slash = true;
                    }
                } else {
                    collapsed.push(c);
                    last_was_slash = false;
                }
            }
            if !collapsed.starts_with('/') {
                format!("/{collapsed}")
            } else {
                collapsed
            }
        };

        // Construct normalized URL string
        let mut normalized_url = format!("{scheme}://{host}");
        if let Some(p) = normalized_port {
            normalized_url.push_str(&format!(":{p}"));
        }
        if normalized_path != "/" || query.is_some() || fragment.is_some() {
            normalized_url.push_str(&normalized_path);
        } else {
            normalized_url.push('/');
        }
        if let Some(ref q) = query {
            normalized_url.push('?');
            normalized_url.push_str(q);
        }
        if let Some(ref f) = fragment {
            normalized_url.push('#');
            normalized_url.push_str(f);
        }

        // Domain: host with "www." stripped if present
        let domain = host.strip_prefix("www.").unwrap_or(&host).to_string();

        Ok(Self {
            scheme,
            host,
            port: normalized_port,
            path: normalized_path,
            query,
            fragment,
            normalized_url,
            domain,
        })
    }

    /// Checks if a string is a valid HTTP/HTTPS/FTP URL without error details.
    pub fn is_valid(raw: &str) -> bool {
        Self::parse(raw).is_ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_canonicalize_standard_url() {
        let parsed = CanonicalUrl::parse("HTTPS://WWW.EXAMPLE.COM/path/to/page")
            .expect("Should parse standard URL");
        assert_eq!(parsed.scheme, "https");
        assert_eq!(parsed.host, "www.example.com");
        assert_eq!(parsed.domain, "example.com");
        assert_eq!(
            parsed.normalized_url,
            "https://www.example.com/path/to/page"
        );
    }

    #[test]
    fn test_strip_default_ports() {
        let http = CanonicalUrl::parse("http://example.com:80/").expect("Should strip port 80");
        assert_eq!(http.port, None);
        assert_eq!(http.normalized_url, "http://example.com/");

        let https = CanonicalUrl::parse("https://example.com:443/").expect("Should strip port 443");
        assert_eq!(https.port, None);
        assert_eq!(https.normalized_url, "https://example.com/");

        let custom =
            CanonicalUrl::parse("http://localhost:8080/api").expect("Should retain custom port");
        assert_eq!(custom.port, Some(8080));
        assert_eq!(custom.normalized_url, "http://localhost:8080/api");
    }

    #[test]
    fn test_collapse_consecutive_slashes() {
        let parsed = CanonicalUrl::parse("https://github.com//rust-lang///rust")
            .expect("Should collapse duplicate slashes");
        assert_eq!(parsed.path, "/rust-lang/rust");
        assert_eq!(parsed.normalized_url, "https://github.com/rust-lang/rust");
    }

    #[test]
    fn test_preserve_query_and_fragment() {
        let parsed = CanonicalUrl::parse("https://example.com/search?q=mimra&sort=new#section-1")
            .expect("Should preserve query and fragment");
        assert_eq!(parsed.query.as_deref(), Some("q=mimra&sort=new"));
        assert_eq!(parsed.fragment.as_deref(), Some("section-1"));
        assert_eq!(
            parsed.normalized_url,
            "https://example.com/search?q=mimra&sort=new#section-1"
        );
    }

    #[test]
    fn test_invalid_urls() {
        assert!(CanonicalUrl::parse("").is_err());
        assert!(CanonicalUrl::parse("not a url").is_err());
        assert!(CanonicalUrl::parse("http://").is_err());
        assert!(CanonicalUrl::parse("http:// space in host.com").is_err());
        assert!(CanonicalUrl::parse("gopher://old.protocol/").is_err());
    }
}
