//! `host:port` targets in strict ASCII, and which addresses count as public (Task 10).
//!
//! There is no `idna` stack: a name is ASCII LDH (A-labels allowed) and an address is a plain literal. Everything else
//! is refused, so no target that a resolver or another parser could read differently gets through (`127.1`,
//! `0x7f.0.0.1`, a NUL, a U-label).

use std::fmt;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// The host of a [`Target`], in its normal form: a name in lower case without a trailing dot, or an address.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Host {
    Name(String),
    V4(Ipv4Addr),
    V6(Ipv6Addr),
}

/// A `host:port` the proxy compares and connects to. `Display` is the normal form (`[v6]:port` for IPv6).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Target {
    pub host: Host,
    pub port: u16,
}

impl fmt::Display for Target {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.host {
            Host::Name(n) => write!(f, "{n}:{}", self.port),
            Host::V4(a) => write!(f, "{a}:{}", self.port),
            Host::V6(a) => write!(f, "[{a}]:{}", self.port),
        }
    }
}

/// Why [`parse_target`] refused a string.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetError {
    /// A NUL, a space, a control character or a byte outside ASCII.
    NotAscii,
    /// A `*` anywhere: entries and requests are exact.
    Wildcard,
    /// No `:PORT`, or a port that is 0, over 65535, not decimal or written with a leading zero.
    BadPort,
    /// A name that is not ASCII LDH: `_`, an empty or over-long label, a hyphen at a label's edge, a last label that
    /// does not start with a letter, over 253 characters.
    BadName,
    /// An address in a form other than four decimal octets, or an IPv6 address outside brackets or with a zone.
    BadAddress,
}

impl fmt::Display for TargetError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            TargetError::NotAscii => "not printable ASCII",
            TargetError::Wildcard => "a wildcard",
            TargetError::BadPort => "no port, or not a port in 1-65535",
            TargetError::BadName => "not an ASCII host name",
            TargetError::BadAddress => "not an address in its plain form",
        })
    }
}

impl std::error::Error for TargetError {}

/// `s` as a [`Target`]: `NAME:PORT`, `A.B.C.D:PORT` or `[V6]:PORT`.
pub fn parse_target(s: &str) -> Result<Target, TargetError> {
    if s.bytes().any(|c| !(0x21..=0x7e).contains(&c)) {
        return Err(TargetError::NotAscii);
    }
    if s.contains('*') {
        return Err(TargetError::Wildcard);
    }
    let (host, port) = if let Some(rest) = s.strip_prefix('[') {
        let (inner, after) = rest.split_once(']').ok_or(TargetError::BadAddress)?;
        let port = after.strip_prefix(':').ok_or(TargetError::BadPort)?;
        (Host::V6(parse_v6(inner)?), port)
    } else {
        let (host, port) = s.rsplit_once(':').ok_or(TargetError::BadPort)?;
        if host.contains([':', '[', ']']) {
            return Err(TargetError::BadAddress);
        }
        (parse_host(host)?, port)
    };
    Ok(Target {
        host,
        port: parse_port(port)?,
    })
}

/// A port in decimal, 1-65535, with no sign and no leading zero.
fn parse_port(s: &str) -> Result<u16, TargetError> {
    let plain =
        (1..=5).contains(&s.len()) && s.bytes().all(|c| c.is_ascii_digit()) && !s.starts_with('0');
    match s.parse::<u16>() {
        Ok(p) if plain => Ok(p),
        _ => Err(TargetError::BadPort),
    }
}

/// An IPv6 address as written inside brackets: hex digits, colons and an embedded dotted IPv4 tail; no zone.
fn parse_v6(s: &str) -> Result<Ipv6Addr, TargetError> {
    if s.len() > 45
        || !s
            .bytes()
            .all(|c| c.is_ascii_hexdigit() || c == b':' || c == b'.')
    {
        return Err(TargetError::BadAddress);
    }
    s.parse().map_err(|_| TargetError::BadAddress)
}

/// A host outside brackets: digits and dots only make an IPv4 address (or nothing); anything else is a name.
fn parse_host(s: &str) -> Result<Host, TargetError> {
    if !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit() || c == b'.') {
        return parse_v4(s).map(Host::V4).ok_or(TargetError::BadAddress);
    }
    parse_name(s).map(Host::Name)
}

/// Exactly four decimal octets, each 0-255 without a leading zero: no `127.1`, `2130706433` or `010.0.0.1`.
fn parse_v4(s: &str) -> Option<Ipv4Addr> {
    let mut octets = [0u8; 4];
    let mut parts = s.split('.');
    for o in &mut octets {
        let p = parts.next()?;
        if p.is_empty() || p.len() > 3 || (p.len() > 1 && p.starts_with('0')) {
            return None;
        }
        *o = p.parse().ok()?;
    }
    parts.next().is_none().then_some(Ipv4Addr::from(octets))
}

/// An ASCII LDH name in lower case, one trailing dot dropped: labels of 1-63 letters, digits and inner hyphens
/// (A-labels are such labels), at most 253 in all, the last label starting with a letter so that no name reads as an
/// address.
fn parse_name(s: &str) -> Result<String, TargetError> {
    let name = s.strip_suffix('.').unwrap_or(s).to_ascii_lowercase();
    if name.is_empty() || name.len() > 253 {
        return Err(TargetError::BadName);
    }
    let label_ok = |l: &str| {
        (1..=63).contains(&l.len())
            && l.bytes()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
            && !l.starts_with('-')
            && !l.ends_with('-')
    };
    let last = name.rsplit('.').next().unwrap_or_default();
    if name.split('.').all(label_ok) && last.starts_with(|c: char| c.is_ascii_lowercase()) {
        Ok(name)
    } else {
        Err(TargetError::BadName)
    }
}

/// Whether `ip` is a public address: not private, shared, loopback, link-local, documentation, benchmarking,
/// multicast or reserved. An IPv6 address that carries an IPv4 one (mapped, IPv4-compatible, NAT64, 6to4) is judged
/// by the IPv4 address inside it.
pub fn is_public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(a) => public_v4(a),
        IpAddr::V6(a) => public_v6(a),
    }
}

fn public_v4(a: Ipv4Addr) -> bool {
    let [a0, a1, a2, _] = a.octets();
    let not_public = a0 == 0 // this network
        || a0 == 10 // private
        || (a0 == 100 && (64..=127).contains(&a1)) // shared (CGNAT)
        || a0 == 127 // loopback
        || (a0 == 169 && a1 == 254) // link-local, the cloud metadata address
        || (a0 == 172 && (16..=31).contains(&a1)) // private
        || (a0 == 192 && a1 == 0 && a2 == 0) // IETF protocol assignments
        || (a0 == 192 && a1 == 0 && a2 == 2) // documentation
        || (a0 == 192 && a1 == 168) // private
        || (a0 == 198 && (a1 == 18 || a1 == 19)) // benchmarking
        || (a0 == 198 && a1 == 51 && a2 == 100) // documentation
        || (a0 == 203 && a1 == 0 && a2 == 113) // documentation
        || a0 >= 224; // multicast, reserved, broadcast
    !not_public
}

fn public_v6(a: Ipv6Addr) -> bool {
    let w = a.segments();
    let inner = |hi: u16, lo: u16| Ipv4Addr::from((u32::from(hi) << 16) | u32::from(lo));
    if a.is_unspecified() || a.is_loopback() {
        return false;
    }
    // ::ffff:0:0/96 (mapped) and ::/96 (IPv4-compatible)
    if w[..5] == [0; 5] && (w[5] == 0xffff || w[5] == 0) {
        return public_v4(inner(w[6], w[7]));
    }
    // 64:ff9b::/96 (NAT64)
    if w[0] == 0x64 && w[1] == 0xff9b && w[2..6] == [0; 4] {
        return public_v4(inner(w[6], w[7]));
    }
    // 2002::/16 (6to4): the IPv4 address is the next 32 bits
    if w[0] == 0x2002 {
        return public_v4(inner(w[1], w[2]));
    }
    let not_public = (w[0] & 0xfe00) == 0xfc00 // fc00::/7 unique local
        || (w[0] & 0xffc0) == 0xfe80 // fe80::/10 link-local
        || (w[0] & 0xffc0) == 0xfec0 // fec0::/10 site-local
        || (w[0] & 0xff00) == 0xff00 // ff00::/8 multicast
        || (w[0] == 0x2001 && w[1] == 0xdb8) // documentation
        || (w[0] == 0x2001 && w[1] == 0) // Teredo
        || (w[0] == 0x64 && w[1] == 0xff9b && w[2] == 1) // 64:ff9b:1::/48 local NAT64
        || (w[0] == 0x100 && w[1..4] == [0; 3]); // 100::/64 discard
    !not_public
}

#[cfg(test)]
mod tests {
    use super::*;

    fn name(n: &str, port: u16) -> Target {
        Target {
            host: Host::Name(n.to_owned()),
            port,
        }
    }

    #[test]
    fn names_table() {
        let l63 = "a".repeat(63);
        let l64 = "a".repeat(64);
        // 4 labels of 61 + 4 dots + "abcde" (5) = 253; one longer is 254
        let n253 = format!("{0}.{0}.{0}.{0}.abcde", "a".repeat(61));
        let n254 = format!("{0}.{0}.{0}.{0}.abcdef", "a".repeat(61));
        assert_eq!(n253.len(), 253);
        assert_eq!(n254.len(), 254);
        let ok: Vec<(String, Target, &str)> = vec![
            (
                "Example.COM:443".into(),
                name("example.com", 443),
                "example.com:443",
            ),
            (
                "example.com.:443".into(),
                name("example.com", 443),
                "example.com:443",
            ),
            (
                "xn--bcher-kva.de:443".into(),
                name("xn--bcher-kva.de", 443),
                "xn--bcher-kva.de:443",
            ),
            ("a-b.c:1".into(), name("a-b.c", 1), "a-b.c:1"),
            (
                "localhost:65535".into(),
                name("localhost", 65535),
                "localhost:65535",
            ),
            ("9a.b2:80".into(), name("9a.b2", 80), "9a.b2:80"),
            (format!("{l63}.com:80"), name(&format!("{l63}.com"), 80), ""),
            (format!("{n253}:80"), name(&n253, 80), ""),
            (format!("{n253}.:80"), name(&n253, 80), ""),
            (
                "1.2.3.4:80".into(),
                Target {
                    host: Host::V4(Ipv4Addr::new(1, 2, 3, 4)),
                    port: 80,
                },
                "1.2.3.4:80",
            ),
            (
                "0.0.0.0:1".into(),
                Target {
                    host: Host::V4(Ipv4Addr::UNSPECIFIED),
                    port: 1,
                },
                "0.0.0.0:1",
            ),
            (
                "[2001:DB8::1]:443".into(),
                Target {
                    host: Host::V6("2001:db8::1".parse().unwrap()),
                    port: 443,
                },
                "[2001:db8::1]:443",
            ),
            (
                "[::ffff:7f00:1]:80".into(),
                Target {
                    host: Host::V6("::ffff:127.0.0.1".parse().unwrap()),
                    port: 80,
                },
                "[::ffff:127.0.0.1]:80",
            ),
            // the longest IPv6 text (45 characters) is still an address
            (
                "[0000:0000:0000:0000:0000:ffff:255.255.255.255]:80".into(),
                Target {
                    host: Host::V6("::ffff:255.255.255.255".parse().unwrap()),
                    port: 80,
                },
                "[::ffff:255.255.255.255]:80",
            ),
        ];
        for (input, want, shown) in ok {
            let got = parse_target(&input).unwrap_or_else(|e| panic!("{input:?}: {e}"));
            assert_eq!(got, want, "{input:?}");
            if !shown.is_empty() {
                assert_eq!(got.to_string(), shown, "{input:?}");
            }
            // the normal form parses back to itself
            assert_eq!(parse_target(&got.to_string()), Ok(got), "{input:?}");
        }

        use TargetError::*;
        let bad: Vec<(String, TargetError)> = vec![
            (format!("{l64}.com:80"), BadName),
            (format!("{n254}:80"), BadName),
            ("-a.com:1".into(), BadName),
            ("a-.com:1".into(), BadName),
            ("a..b:1".into(), BadName),
            (".a.com:1".into(), BadName),
            ("a.com..:1".into(), BadName),
            (":443".into(), BadName),
            ("foo_bar.com:443".into(), BadName),
            ("_dmarc.example.com:443".into(), BadName),
            ("example.123:80".into(), BadName),
            ("example.1a:80".into(), BadName),
            ("a%2e.com:80".into(), BadName),
            ("a/b.com:80".into(), BadName),
            ("user@example.com:80".into(), BadName),
            ("example.com".into(), BadPort),
            ("example.com:".into(), BadPort),
            ("example.com:0".into(), BadPort),
            ("example.com:00".into(), BadPort),
            ("example.com:0443".into(), BadPort),
            ("example.com:65536".into(), BadPort),
            ("example.com:999999".into(), BadPort),
            ("example.com:+443".into(), BadPort),
            ("example.com:-1".into(), BadPort),
            ("example.com:44a".into(), BadPort),
            ("[::1]".into(), BadPort),
            ("[::1]80".into(), BadPort),
            ("::1:80".into(), BadAddress),
            ("[::1:80".into(), BadAddress),
            ("::1]:80".into(), BadAddress),
            ("[example.com]:80".into(), BadAddress),
            ("[1.2.3.4]:80".into(), BadAddress),
            ("1.2.3.256:80".into(), BadAddress),
            ("1.2.3:80".into(), BadAddress),
            ("1.2.3.4.5:80".into(), BadAddress),
            ("1.2.3.4.:80".into(), BadAddress),
            ("a b.com:80".into(), NotAscii),
            ("a\tb.com:80".into(), NotAscii),
            ("a\u{7f}b.com:80".into(), NotAscii),
            ("".into(), BadPort),
            ("*:443".into(), Wildcard),
            ("*.example.com:443".into(), Wildcard),
            ("a.*.com:443".into(), Wildcard),
        ];
        for (input, want) in bad {
            assert_eq!(parse_target(&input), Err(want), "{input:?}");
        }
    }

    #[test]
    fn odd_literals_refused() {
        // Each is refused by the parser, or parses to an address that is not public: never a name a resolver could
        // read as an address, never a public one.
        let rows: &[(&str, Option<TargetError>)] = &[
            ("127.1:80", Some(TargetError::BadAddress)),
            ("2130706433:80", Some(TargetError::BadAddress)),
            ("0x7f.0.0.1:80", Some(TargetError::BadName)),
            ("0x7f000001:80", Some(TargetError::BadName)),
            ("010.0.0.1:80", Some(TargetError::BadAddress)),
            ("0177.0.0.1:80", Some(TargetError::BadAddress)),
            ("127.0.0.01:80", Some(TargetError::BadAddress)),
            ("[fe80::1%eth0]:80", Some(TargetError::BadAddress)),
            ("[fe80::1%25eth0]:80", Some(TargetError::BadAddress)),
            ("a\0b.com:443", Some(TargetError::NotAscii)),
            ("bücher.de:443", Some(TargetError::NotAscii)),
            ("*.example.com:443", Some(TargetError::Wildcard)),
            ("[::ffff:127.0.0.1]:80", None),
            ("[::ffff:7f00:1]:80", None),
            ("[::127.0.0.1]:80", None),
            ("[64:ff9b::a9fe:a9fe]:80", None),
            ("[64:ff9b::169.254.169.254]:80", None),
            ("[2002:a9fe:a9fe::]:80", None),
            ("[::]:80", None),
            ("[::1]:80", None),
            ("169.254.169.254:80", None),
            ("0.0.0.0:80", None),
            ("127.0.0.1:80", None),
        ];
        for (input, err) in rows {
            match (parse_target(input), err) {
                (Err(got), Some(want)) => assert_eq!(got, *want, "{input:?}"),
                (Ok(t), None) => {
                    let ip = match t.host {
                        Host::V4(a) => IpAddr::V4(a),
                        Host::V6(a) => IpAddr::V6(a),
                        Host::Name(n) => panic!("{input:?} parsed as the name {n:?}"),
                    };
                    assert!(!is_public(ip), "{input:?} counted as public");
                }
                (got, want) => panic!("{input:?}: got {got:?}, want {want:?}"),
            }
        }
    }

    fn v4(s: &str) -> IpAddr {
        IpAddr::V4(s.parse().unwrap())
    }
    fn v6(s: &str) -> IpAddr {
        IpAddr::V6(s.parse().unwrap())
    }

    #[test]
    fn ranges_table() {
        // Each range: its first and last address are not public, the addresses just outside it are.
        let not_public = [
            "0.0.0.0",
            "0.255.255.255",
            "10.0.0.0",
            "10.255.255.255",
            "100.64.0.0",
            "100.127.255.255",
            "127.0.0.1",
            "127.255.255.255",
            "169.254.0.0",
            "169.254.169.254",
            "169.254.255.255",
            "172.16.0.0",
            "172.31.255.255",
            "192.0.0.0",
            "192.0.0.255",
            "192.0.2.0",
            "192.0.2.255",
            "192.168.0.0",
            "192.168.255.255",
            "198.18.0.0",
            "198.19.255.255",
            "198.51.100.0",
            "198.51.100.255",
            "203.0.113.0",
            "203.0.113.255",
            "224.0.0.0",
            "239.255.255.255",
            "240.0.0.0",
            "255.255.255.254",
            "255.255.255.255",
        ];
        for a in not_public {
            assert!(!is_public(v4(a)), "{a} counted as public");
        }
        let public = [
            "1.0.0.0",
            "9.255.255.255",
            "11.0.0.0",
            "100.63.255.255",
            "100.128.0.0",
            "126.255.255.255",
            "128.0.0.0",
            "169.253.255.255",
            "169.255.0.0",
            "172.15.255.255",
            "172.32.0.0",
            "192.0.1.0",
            "192.0.3.0",
            "192.167.255.255",
            "192.169.0.0",
            "198.17.255.255",
            "198.20.0.0",
            "198.51.99.255",
            "198.51.101.0",
            "203.0.112.255",
            "203.0.114.0",
            "223.255.255.255",
            "8.8.8.8",
        ];
        for a in public {
            assert!(is_public(v4(a)), "{a} counted as not public");
        }
        let not_public6 = [
            "::",
            "::1",
            "fc00::",
            "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
            "fe80::1",
            "febf:ffff::",
            "fec0::1",
            "feff::1",
            "ff00::",
            "ff02::1",
            "2001:db8::1",
            "2001:db8:ffff::",
            "2001::1",
            "2001:0:ffff::1",
            "64:ff9b:1::1",
            "64:ff9b:1:ffff::1",
            "100::1",
            "100::ffff:ffff:ffff:ffff",
        ];
        for a in not_public6 {
            assert!(!is_public(v6(a)), "{a} counted as public");
        }
        let public6 = [
            "2606:4700::1111",
            "2001:4860:4860::8888",
            "2001:1::1",
            "2001:db9::1",
            "fbff::1",
            "fe00::1",
            "64:ff9b:2::1",
            "100:0:0:1::1",
            "2a00:1450::1",
        ];
        for a in public6 {
            assert!(is_public(v6(a)), "{a} counted as not public");
        }
    }

    #[test]
    fn errors_say_what_is_wrong() {
        use TargetError::*;
        let all = [NotAscii, Wildcard, BadPort, BadName, BadAddress];
        let said: std::collections::HashSet<String> = all.iter().map(|e| e.to_string()).collect();
        assert_eq!(
            said.len(),
            all.len(),
            "each error has its own text: {said:?}"
        );
        assert!(said.iter().all(|s| !s.is_empty()));
    }

    #[test]
    fn mapped_nat64_6to4_judged_by_v4() {
        let rows = [
            // IPv4-mapped ::ffff:0:0/96
            ("::ffff:127.0.0.1", false),
            ("::ffff:10.1.2.3", false),
            ("::ffff:169.254.169.254", false),
            ("::ffff:8.8.8.8", true),
            // IPv4-compatible ::/96
            ("::127.0.0.1", false),
            ("::192.168.1.1", false),
            ("::8.8.8.8", true),
            // NAT64 64:ff9b::/96
            ("64:ff9b::a9fe:a9fe", false),
            ("64:ff9b::7f00:1", false),
            ("64:ff9b::808:808", true),
            // 6to4 2002::/16: the IPv4 address is the next 32 bits
            ("2002:7f00:1::", false),
            ("2002:a9fe:a9fe::1", false),
            ("2002:c0a8:101::", false),
            ("2002:808:808::1", true),
        ];
        for (a, public) in rows {
            assert_eq!(is_public(v6(a)), public, "{a}");
        }
    }
}
