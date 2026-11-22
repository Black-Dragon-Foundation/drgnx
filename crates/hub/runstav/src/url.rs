//! The URL rule (contract Task 14) and the gateway's provider-base rule.  No URL crate: the rule is small and
//! this keeps `runstav` free of one.

/// A URL that passed [`check`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Url {
    /// The URL as given (a `user@host:path` form stays in that form).
    pub raw: String,
    /// Lower-case scheme: `ssh` for `user@host:path`, `file` for a local absolute path.
    pub scheme: String,
    /// The host; empty for `file`.
    pub host: String,
}

/// Why a URL was refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UrlRefusal {
    /// Any `NAME::` form.
    Transport,
    /// A scheme not in the allowed list (`user@host:path` counts as `ssh`, a local absolute path as `file`).
    Scheme,
    /// A control character, a leading `-`, userinfo in an http(s) URL, or no host.
    Malformed,
}

/// A provider's base URL: `https`, or `http` for any host; `clear_text` is `http` off loopback.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProviderBase {
    pub url: Url,
    pub clear_text: bool,
}

/// `host` of an authority (userinfo and port stripped), and whether userinfo was there.
fn authority_host(auth: &str) -> (&str, bool) {
    let (userinfo, hostport) = match auth.rfind('@') {
        Some(i) => (true, &auth[i + 1..]),
        None => (false, auth),
    };
    let host = if let Some(rest) = hostport.strip_prefix('[') {
        rest.split(']').next().unwrap_or("")
    } else {
        hostport.split(':').next().unwrap_or("")
    };
    (host, userinfo)
}

fn parts(url: &str) -> Result<(Url, bool), UrlRefusal> {
    if url.chars().any(|c| c.is_control()) || url.starts_with('-') {
        return Err(UrlRefusal::Malformed);
    }
    if url.is_empty() {
        return Err(UrlRefusal::Malformed);
    }
    if is_transport(url) {
        return Err(UrlRefusal::Transport);
    }
    if url.starts_with('/') {
        return Ok((
            Url {
                raw: url.to_string(),
                scheme: "file".into(),
                host: String::new(),
            },
            false,
        ));
    }
    if let Some((scheme, rest)) = url.split_once("://") {
        if scheme.is_empty()
            || !scheme
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c))
        {
            return Err(UrlRefusal::Malformed);
        }
        let scheme = scheme.to_ascii_lowercase();
        let auth = rest.split(['/', '?', '#']).next().unwrap_or("");
        let (host, userinfo) = authority_host(auth);
        if scheme == "file" {
            return Ok((
                Url {
                    raw: url.to_string(),
                    scheme,
                    host: host.to_string(),
                },
                userinfo,
            ));
        }
        if host.is_empty() {
            return Err(UrlRefusal::Malformed);
        }
        return Ok((
            Url {
                raw: url.to_string(),
                scheme,
                host: host.to_string(),
            },
            userinfo,
        ));
    }
    // scp form: user@host:path (or host:path)
    if let Some((left, path)) = url.split_once(':') {
        let host = left.rsplit('@').next().unwrap_or("");
        if host.is_empty() || host.contains('/') || path.is_empty() {
            return Err(UrlRefusal::Malformed);
        }
        return Ok((
            Url {
                raw: url.to_string(),
                scheme: "ssh".into(),
                host: host.to_string(),
            },
            false,
        ));
    }
    Err(UrlRefusal::Malformed)
}

/// `NAME::` where NAME is a remote-helper name (git's `ext::`, `fd::`, `transport::`).
fn is_transport(url: &str) -> bool {
    match url.find("::") {
        Some(i) => {
            let name = &url[..i];
            !name.is_empty() && !name.contains(['/', ':', '@'])
        }
        None => false,
    }
}

/// URL against the allowed SCHEMES.
pub fn check(url: &str, schemes: &[&str]) -> Result<Url, UrlRefusal> {
    let (u, userinfo) = parts(url)?;
    if !schemes.iter().any(|s| s.eq_ignore_ascii_case(&u.scheme)) {
        return Err(UrlRefusal::Scheme);
    }
    if userinfo && matches!(u.scheme.as_str(), "http" | "https") {
        return Err(UrlRefusal::Malformed);
    }
    Ok(u)
}

/// The gateway's rule for a provider's base URL.
pub fn provider_base(url: &str) -> Result<ProviderBase, UrlRefusal> {
    let (u, userinfo) = parts(url)?;
    if !matches!(u.scheme.as_str(), "http" | "https") {
        return Err(UrlRefusal::Scheme);
    }
    if userinfo || url.contains('#') {
        return Err(UrlRefusal::Malformed);
    }
    let loopback = u.host.eq_ignore_ascii_case("localhost")
        || u.host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback());
    let clear_text = u.scheme == "http" && !loopback;
    Ok(ProviderBase { url: u, clear_text })
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: &[&str] = &["https", "http", "ssh", "file", "git"];

    #[test]
    fn transports_refused() {
        for u in ["ext::sh -c id", "fd::3", "transport::x", "ext::https://a/b"] {
            assert_eq!(check(u, ALL), Err(UrlRefusal::Transport), "{u}");
        }
    }

    #[test]
    fn scp_form_is_ssh() {
        let u = check("git@host.example:me/repo.git", &["ssh"]).unwrap();
        assert_eq!(
            (u.scheme.as_str(), u.host.as_str()),
            ("ssh", "host.example")
        );
        assert_eq!(
            check("git@host.example:me/repo.git", &["https"]),
            Err(UrlRefusal::Scheme)
        );
        assert_eq!(check("/srv/repo", &["file"]).unwrap().scheme, "file");
        assert_eq!(check("/srv/repo", &["https"]), Err(UrlRefusal::Scheme));
        assert_eq!(check("ftp://h/x", &["https"]), Err(UrlRefusal::Scheme));
    }

    #[test]
    fn control_and_dash_refused() {
        for u in [
            "-oProxyCommand=x",
            "https://a/\nb",
            "https://a/\u{7}",
            "",
            "https:///x",
        ] {
            assert_eq!(check(u, ALL), Err(UrlRefusal::Malformed), "{u:?}");
        }
    }

    #[test]
    fn userinfo_refused() {
        assert_eq!(
            check("https://user:pw@h/x", ALL),
            Err(UrlRefusal::Malformed)
        );
        assert_eq!(check("http://user@h/x", ALL), Err(UrlRefusal::Malformed));
        assert!(check("ssh://git@h/x", ALL).is_ok());
    }

    #[test]
    fn provider_base_http_off_loopback_is_clear_text() {
        for (u, clear) in [
            ("https://api.example.com/v1", false),
            ("http://localhost:11434/v1", false),
            ("http://127.0.0.1:8080", false),
            ("http://[::1]:8080/v1", false),
            ("http://192.168.1.5:8080/v1", true),
            ("http://llm.lan/v1", true),
        ] {
            assert_eq!(provider_base(u).unwrap().clear_text, clear, "{u}");
        }
    }

    #[test]
    fn provider_base_refuses_other_schemes() {
        assert_eq!(provider_base("ftp://h/x"), Err(UrlRefusal::Scheme));
        assert_eq!(provider_base("/srv/x"), Err(UrlRefusal::Scheme));
        assert_eq!(provider_base("https://u:p@h/x"), Err(UrlRefusal::Malformed));
        assert_eq!(
            provider_base("https://h/x#frag"),
            Err(UrlRefusal::Malformed)
        );
        assert_eq!(provider_base("https:///x"), Err(UrlRefusal::Malformed));
    }
}
