use super::*;
use proptest::prelude::*;

const GATEWAY: u16 = 7341;
const NOW: f64 = 1_000_000.0;

fn t(s: &str) -> Target {
    parse_target(s).unwrap_or_else(|e| panic!("{s}: {e}"))
}
fn sa(s: &str) -> SocketAddr {
    s.parse().unwrap_or_else(|e| panic!("{s}: {e}"))
}
fn ip(s: &str) -> IpAddr {
    s.parse().unwrap_or_else(|e| panic!("{s}: {e}"))
}
fn hp(s: &str) -> PrivateGrant {
    PrivateGrant {
        target: PrivateTarget::HostPort(t(s)),
        expires: None,
    }
}
fn cidr(net: &str, prefix: u8, lo: u16, hi: u16) -> PrivateGrant {
    PrivateGrant {
        target: PrivateTarget::Cidr {
            net: ip(net),
            prefix,
            ports: (lo, hi),
        },
        expires: None,
    }
}
fn all() -> PrivateGrant {
    PrivateGrant {
        target: PrivateTarget::AllPrivate,
        expires: None,
    }
}

/// The host this table runs on: a LAN address, a podman bridge, a public IPv6 address.
fn host_addrs() -> HostAddrs {
    ["192.168.1.10", "10.88.0.1", "2a01:4f8::10"]
        .into_iter()
        .map(ip)
        .collect()
}
fn never() -> NeverSet {
    NeverSet {
        loopback_ports: [GATEWAY].into_iter().collect(),
    }
}

struct Case {
    what: &'static str,
    target: &'static str,
    answer: Vec<&'static str>,
    web: bool,
    grants: Vec<PrivateGrant>,
    deny: Vec<String>,
    want: Judgement,
}

fn case(what: &'static str, target: &'static str, want: Judgement) -> Case {
    Case {
        what,
        target,
        answer: Vec::new(),
        web: true,
        grants: Vec::new(),
        deny: Vec::new(),
        want,
    }
}

impl Case {
    fn dns(mut self, a: &[&'static str]) -> Self {
        self.answer = a.to_vec();
        self
    }
    fn web_off(mut self) -> Self {
        self.web = false;
        self
    }
    fn grants(mut self, g: Vec<PrivateGrant>) -> Self {
        self.grants = g;
        self
    }
    fn deny(mut self, d: &[&str]) -> Self {
        self.deny = d.iter().map(|s| (*s).to_owned()).collect();
        self
    }
}

fn connect(addrs: &[&str]) -> Judgement {
    Judgement::Connect(addrs.iter().map(|a| sa(a)).collect())
}
fn private(addr: &str, class: Class) -> Judgement {
    Judgement::Private {
        addr: sa(addr),
        class,
    }
}
fn refuse(why: RefuseWhy) -> Judgement {
    Judgement::Refuse(why)
}

#[test]
fn judge_table() {
    use Class::{Cgnat, Lan, LinkLocal};
    use RefuseWhy::*;
    let mut expired = hp("192.168.1.20:8080");
    expired.expires = Some(NOW - 1.0);
    let mut fresh = hp("192.168.1.21:8080");
    fresh.expires = Some(NOW + 600.0);
    let gw = Box::leak(format!("host.drgnx.internal:{GATEWAY}").into_boxed_str());
    let cases = vec![
        // §6.4: public-any on 80 and 443 once browser.web is granted
        case(
            "public name on 443",
            "example.com:443",
            connect(&["93.184.215.14:443"]),
        )
        .dns(&["93.184.215.14:0"]),
        case(
            "public name on 80",
            "example.com:80",
            connect(&["93.184.215.14:80"]),
        )
        .dns(&["93.184.215.14:0"]),
        case("public literal", "8.8.8.8:443", connect(&["8.8.8.8:443"])),
        case(
            "public v6 literal",
            "[2606:4700::1111]:80",
            connect(&["[2606:4700::1111]:80"]),
        ),
        case(
            "mapped public literal",
            "[::ffff:8.8.8.8]:443",
            connect(&["[::ffff:8.8.8.8]:443"]),
        ),
        case(
            "web off: the card's question",
            "example.com:443",
            Judgement::WebOff,
        )
        .dns(&["93.184.215.14:443"])
        .web_off(),
        case("web off, a literal", "8.8.8.8:80", Judgement::WebOff).web_off(),
        case("port 8443 public", "example.com:8443", refuse(Port)).dns(&["93.184.215.14:8443"]),
        case("port 8443 public, web off", "8.8.8.8:8443", refuse(Port)).web_off(),
        case("port 22 public", "8.8.8.8:22", refuse(Port)),
        case(
            "mixed answer: the public ones only",
            "mixed.example:443",
            connect(&["93.184.215.14:443", "[2606:4700::1]:443"]),
        )
        .dns(&[
            "127.0.0.1:443",
            "93.184.215.14:443",
            "10.0.0.1:443",
            "[2606:4700::1]:443",
        ])
        .grants(vec![all()]),
        case(
            "mixed with a never: dropped",
            "m.example:443",
            connect(&["93.184.215.14:443"]),
        )
        .dns(&["169.254.169.254:443", "93.184.215.14:443"]),
        case("answer all nevers", "meta.example:80", refuse(Never))
            .dns(&["169.254.169.254:80", "[fd00:ec2::254]:80"]),
        case("answer 0.0.0.0", "zero.example:80", refuse(Never)).dns(&["0.0.0.0:80"]),
        case(
            "empty answer: nothing to connect to",
            "none.example:443",
            connect(&[]),
        ),
        case(
            "deny list, a name and the names under it",
            "www.example.com:443",
            refuse(DenyListed),
        )
        .dns(&["93.184.215.14:443"])
        .deny(&["Example.COM."]),
        case(
            "deny list, not a suffix of a label",
            "badexample.com:443",
            connect(&["93.184.215.14:443"]),
        )
        .dns(&["93.184.215.14:443"])
        .deny(&["example.com"]),
        case("deny list, an address", "8.8.8.8:443", refuse(DenyListed)).deny(&["8.8.8.8"]),
        case(
            "deny list, a v6 address",
            "[2606:4700::1111]:443",
            refuse(DenyListed),
        )
        .deny(&["[2606:4700::1111]"]),
        // §6.4.1: private targets
        case(
            "LAN literal, no grant",
            "192.168.1.20:8080",
            private("192.168.1.20:8080", Lan),
        ),
        case(
            "LAN literal, granted",
            "192.168.1.20:8080",
            connect(&["192.168.1.20:8080"]),
        )
        .grants(vec![hp("192.168.1.20:8080")]),
        case(
            "LAN literal, the neighbour port",
            "192.168.1.20:8081",
            private("192.168.1.20:8081", Lan),
        )
        .grants(vec![hp("192.168.1.20:8080")]),
        case(
            "LAN literal, the neighbour address",
            "192.168.1.21:8080",
            private("192.168.1.21:8080", Lan),
        )
        .grants(vec![hp("192.168.1.20:8080")]),
        case(
            "an expired grant",
            "192.168.1.20:8080",
            private("192.168.1.20:8080", Lan),
        )
        .grants(vec![expired.clone()]),
        case(
            "a live once grant",
            "192.168.1.21:8080",
            connect(&["192.168.1.21:8080"]),
        )
        .grants(vec![fresh]),
        case(
            "CIDR, in range",
            "192.168.1.5:443",
            connect(&["192.168.1.5:443"]),
        )
        .grants(vec![cidr("192.168.1.0", 24, 80, 443)]),
        case(
            "CIDR, port out of range",
            "192.168.1.5:8080",
            private("192.168.1.5:8080", Lan),
        )
        .grants(vec![cidr("192.168.1.0", 24, 80, 443)]),
        case(
            "CIDR, address out of range",
            "192.168.2.5:80",
            private("192.168.2.5:80", Lan),
        )
        .grants(vec![cidr("192.168.1.0", 24, 80, 443)]),
        case(
            "ULA CIDR",
            "[fd12:3456::5]:8080",
            connect(&["[fd12:3456::5]:8080"]),
        )
        .grants(vec![cidr("fd12:3456::", 48, 8080, 8080)]),
        case(
            "all private over the LAN",
            "10.1.2.3:22",
            connect(&["10.1.2.3:22"]),
        )
        .grants(vec![all()]),
        case(
            "all private over ULA",
            "[fd12::5]:80",
            connect(&["[fd12::5]:80"]),
        )
        .grants(vec![all()]),
        case(
            "all private over 100.64.0.1",
            "100.64.0.1:80",
            private("100.64.0.1:80", Cgnat),
        )
        .grants(vec![all()]),
        case(
            "CGNAT by CIDR",
            "100.64.0.1:80",
            connect(&["100.64.0.1:80"]),
        )
        .grants(vec![cidr("100.64.0.0", 10, 1, 65535)]),
        case(
            "all private over link-local",
            "169.254.1.1:80",
            private("169.254.1.1:80", LinkLocal),
        )
        .grants(vec![all()]),
        case(
            "link-local by CIDR",
            "169.254.1.1:80",
            private("169.254.1.1:80", LinkLocal),
        )
        .grants(vec![cidr("169.254.0.0", 16, 1, 65535)]),
        case(
            "v6 link-local by CIDR",
            "[fe80::1]:80",
            private("[fe80::1]:80", LinkLocal),
        )
        .grants(vec![cidr("fe80::", 10, 1, 65535)]),
        case(
            "link-local, one host:port",
            "169.254.1.1:80",
            connect(&["169.254.1.1:80"]),
        )
        .grants(vec![hp("169.254.1.1:80")]),
        // names: a grant must name that very name
        case(
            "a granted name",
            "nas.lan:5000",
            connect(&["192.168.1.30:5000"]),
        )
        .dns(&["192.168.1.30:0"])
        .grants(vec![hp("nas.lan:5000")]),
        case(
            "a granted .local name",
            "printer.local:631",
            connect(&["192.168.1.20:631"]),
        )
        .dns(&["192.168.1.20:631"])
        .grants(vec![hp("printer.local:631")]),
        case(
            "a granted name, another port",
            "nas.lan:5001",
            private("192.168.1.30:5001", Lan),
        )
        .dns(&["192.168.1.30:0"])
        .grants(vec![hp("nas.lan:5000")]),
        case(
            "a private name, no grant",
            "nas.lan:5000",
            private("192.168.1.30:5000", Lan),
        )
        .dns(&["192.168.1.30:0"]),
        case(
            "rebinding onto a granted literal",
            "evil.example:8080",
            refuse(Rebound),
        )
        .dns(&["192.168.1.20:8080"])
        .grants(vec![hp("192.168.1.20:8080")]),
        case(
            "rebinding under all private",
            "evil.example:80",
            refuse(Rebound),
        )
        .dns(&["10.0.0.7:80"])
        .grants(vec![all()]),
        case("rebinding under a CIDR", "evil.example:80", refuse(Rebound))
            .dns(&["192.168.1.7:80"])
            .grants(vec![cidr("192.168.1.0", 24, 80, 80)]),
        case(
            "rebinding with web on, no public address",
            "evil.example:443",
            refuse(Rebound),
        )
        .dns(&["192.168.1.20:443"])
        .grants(vec![cidr("192.168.0.0", 16, 443, 443)]),
        case(
            "an mDNS answer of loopback",
            "printer.local:631",
            refuse(Loopback),
        )
        .dns(&["127.0.0.1:631"])
        .grants(vec![hp("printer.local:631")]),
        case(
            "an mDNS answer of the host's LAN address",
            "printer.local:631",
            refuse(Loopback),
        )
        .dns(&["192.168.1.10:631"])
        .grants(vec![hp("printer.local:631")]),
        case("localhost", "localhost:5173", refuse(Loopback))
            .dns(&["127.0.0.1:5173", "[::1]:5173"]),
        case(
            "a name answering mapped private",
            "nas.lan:80",
            refuse(Embedded),
        )
        .dns(&["[::ffff:192.168.1.30]:80"])
        .grants(vec![hp("nas.lan:80")]),
        // embedded IPv4 is unwrapped and refused for private matching
        case(
            "[::ffff:192.168.1.20]:80",
            "[::ffff:192.168.1.20]:80",
            refuse(Embedded),
        )
        .grants(vec![all(), hp("192.168.1.20:80")]),
        case("NAT64 private", "[64:ff9b::c0a8:114]:80", refuse(Embedded)).grants(vec![all()]),
        case("6to4 private", "[2002:c0a8:114::]:80", refuse(Embedded)).grants(vec![all()]),
        case(
            "Teredo",
            "[2001:0:4136:e378:8000:63bf:3fff:fdd2]:80",
            refuse(Embedded),
        ),
        case("compatible loopback", "[::127.0.0.1]:80", refuse(Embedded)),
        // hard nevers
        case(
            "168.63.129.16 with web on",
            "168.63.129.16:80",
            refuse(Never),
        ),
        case(
            "169.254.169.254 under grants",
            "169.254.169.254:80",
            refuse(Never),
        )
        .grants(vec![hp("169.254.169.254:80"), all()]),
        case("ECS", "169.254.170.2:80", refuse(Never)).grants(vec![hp("169.254.170.2:80")]),
        case("EKS v6", "[fd00:ec2::23]:80", refuse(Never)).grants(vec![all()]),
        case("Alibaba", "100.100.100.200:80", refuse(Never)),
        case(
            "metadata.google.internal",
            "metadata.google.internal:80",
            refuse(Never),
        )
        .grants(vec![hp("metadata.google.internal:80")]),
        case(
            "under metadata.azure.com",
            "x.metadata.azure.com:443",
            refuse(Never),
        ),
        case("0.0.0.0", "0.0.0.0:80", refuse(Never)).grants(vec![all()]),
        case("0/8", "0.1.2.3:80", refuse(Never)),
        case("::", "[::]:80", refuse(Never)),
        case("multicast", "224.0.0.251:5353", refuse(Never)),
        case("v6 multicast", "[ff02::fb]:5353", refuse(Never)),
        case("broadcast", "255.255.255.255:80", refuse(Never)),
        case("240/4", "240.0.0.1:80", refuse(Never)),
        case("documentation", "192.0.2.1:80", refuse(Never))
            .grants(vec![cidr("0.0.0.0", 0, 1, 65535)]),
        // loopback and the host's own: only through host.drgnx.internal, one port at a time
        case(
            "host.drgnx.internal under its grant",
            "host.drgnx.internal:5173",
            connect(&["127.0.0.1:5173", "[::1]:5173"]),
        )
        .grants(vec![hp("host.drgnx.internal:5173")]),
        case(
            "host.drgnx.internal, no grant",
            "host.drgnx.internal:5173",
            private("127.0.0.1:5173", Class::Loopback),
        ),
        case(
            "host.drgnx.internal, another port",
            "host.drgnx.internal:5174",
            private("127.0.0.1:5174", Class::Loopback),
        )
        .grants(vec![hp("host.drgnx.internal:5173")]),
        case(
            "host.drgnx.internal:GATEWAY under a grant",
            gw,
            refuse(Never),
        )
        .grants(vec![hp(gw)]),
        case(
            "host.drgnx.internal, an expired grant",
            "host.drgnx.internal:5173",
            private("127.0.0.1:5173", Class::Loopback),
        )
        .grants(vec![{
            let mut g = hp("host.drgnx.internal:5173");
            g.expires = Some(NOW);
            g
        }]),
        case(
            "127.0.0.1 under a grant for it",
            "127.0.0.1:5173",
            refuse(Loopback),
        )
        .grants(vec![hp("127.0.0.1:5173")]),
        case("127.0.0.2", "127.0.0.2:80", refuse(Loopback)),
        case("[::1]", "[::1]:80", refuse(Loopback)).grants(vec![all()]),
        case(
            "a host's own LAN address",
            "192.168.1.10:8080",
            refuse(Loopback),
        )
        .grants(vec![
            all(),
            hp("192.168.1.10:8080"),
            cidr("192.168.1.0", 24, 1, 65535),
        ]),
        case("the host's podman bridge", "10.88.0.1:80", refuse(Loopback)).grants(vec![all()]),
        case(
            "the host's public v6 address",
            "[2a01:4f8::10]:443",
            refuse(Loopback),
        ),
        case(
            "a public name answering the host's address",
            "me.example:443",
            refuse(Loopback),
        )
        .dns(&["[2a01:4f8::10]:443"]),
    ];
    let (h, n) = (host_addrs(), never());
    for c in cases {
        let target = t(c.target);
        let answer: Vec<SocketAddr> = c.answer.iter().map(|a| sa(a)).collect();
        let ctx = WebCtx {
            web: c.web,
            deny_hosts: &c.deny,
            grants: &c.grants,
            now: NOW,
            host_addrs: &h,
            never: &n,
        };
        assert_eq!(
            judge(&target, &answer, &ctx),
            c.want,
            "{}: {}",
            c.what,
            c.target
        );
        // pre_resolve agrees: what it refuses, judge refuses for the same reason, and what it fixes judge is asked about
        match pre_resolve(&target, &ctx) {
            Pre::Refuse(why) => {
                assert_eq!(c.want, Judgement::Refuse(why), "{}: pre_resolve", c.what)
            }
            Pre::Resolve => assert!(matches!(target.host, Host::Name(_)), "{}", c.what),
            Pre::Fixed(addrs) => {
                assert!(
                    !matches!(&target.host, Host::Name(n) if n != RESERVED_HOST),
                    "{}",
                    c.what
                );
                assert!(!addrs.is_empty());
                assert_eq!(
                    judge(&target, &addrs, &ctx),
                    c.want,
                    "{}: judged on its fixed answer",
                    c.what
                );
            }
        }
    }
}

/// Every hard never in every spelling the parser takes, as a literal and as a name's answer, under every kind of
/// grant for it, with `browser.web` on.
#[test]
fn every_never_in_every_form() {
    let mut v4s: Vec<Ipv4Addr> = METADATA_NEVER
        .iter()
        .filter_map(|a| match a {
            IpAddr::V4(a) => Some(*a),
            IpAddr::V6(_) => None,
        })
        .collect();
    v4s.extend(
        [
            "0.0.0.0",
            "0.0.0.1",
            "224.0.0.1",
            "239.255.255.250",
            "240.0.0.1",
            "255.255.255.255",
        ]
        .map(|s| s.parse::<Ipv4Addr>().unwrap()),
    );
    let mut forms: Vec<IpAddr> = Vec::new();
    for a in &v4s {
        let [o0, o1, o2, o3] = a.octets();
        let (hi, lo) = (u16::from_be_bytes([o0, o1]), u16::from_be_bytes([o2, o3]));
        forms.push(IpAddr::V4(*a));
        forms.push(IpAddr::V6(a.to_ipv6_mapped()));
        forms.push(IpAddr::V6(Ipv6Addr::new(0x64, 0xff9b, 0, 0, 0, 0, hi, lo)));
        forms.push(IpAddr::V6(Ipv6Addr::new(0x64, 0xff9b, 1, 0, 0, 0, hi, lo)));
        forms.push(IpAddr::V6(Ipv6Addr::new(0x2002, hi, lo, 0, 0, 0, 0, 1)));
        forms.push(IpAddr::V6(Ipv6Addr::new(0, 0, 0, 0, 0, 0, hi, lo)));
        forms.push(IpAddr::V6(Ipv6Addr::new(
            0x2001, 0, 0x4136, 0xe378, 0x8000, 0x63bf, !hi, !lo,
        )));
    }
    forms.extend(
        METADATA_NEVER
            .iter()
            .filter(|a| a.is_ipv6())
            .copied()
            .chain(["::", "ff02::1", "ff05::2"].map(ip)),
    );
    let (h, n) = (host_addrs(), never());
    for form in forms {
        for port in [80, 443] {
            let lit = Target {
                host: match form {
                    IpAddr::V4(a) => Host::V4(a),
                    IpAddr::V6(a) => Host::V6(a),
                },
                port,
            };
            let named = t(&format!("never.example:{port}"));
            let grants = vec![
                all(),
                PrivateGrant {
                    target: PrivateTarget::HostPort(lit.clone()),
                    expires: None,
                },
                hp(&named.to_string()),
                cidr("0.0.0.0", 0, 1, 65535),
                cidr("::", 0, 1, 65535),
            ];
            let ctx = WebCtx {
                web: true,
                deny_hosts: &[],
                grants: &grants,
                now: NOW,
                host_addrs: &h,
                never: &n,
            };
            let a = SocketAddr::new(form, port);
            assert!(
                matches!(judge(&lit, &[a], &ctx), Judgement::Refuse(_)),
                "{lit}: {:?}",
                judge(&lit, &[a], &ctx)
            );
            assert!(matches!(pre_resolve(&lit, &ctx), Pre::Refuse(_)), "{lit}");
            assert!(
                matches!(judge(&named, &[a], &ctx), Judgement::Refuse(_)),
                "{named} → {a}: {:?}",
                judge(&named, &[a], &ctx)
            );
        }
    }
    // the hub's own endpoints on the host's loopback
    let gw = t(&format!("host.drgnx.internal:{GATEWAY}"));
    let grants = vec![hp(&gw.to_string()), all()];
    let ctx = WebCtx {
        web: true,
        deny_hosts: &[],
        grants: &grants,
        now: NOW,
        host_addrs: &h,
        never: &n,
    };
    assert_eq!(
        pre_resolve(&gw, &ctx),
        Pre::Fixed(loopbacks(GATEWAY).to_vec())
    );
    assert_eq!(
        judge(&gw, &loopbacks(GATEWAY), &ctx),
        Judgement::Refuse(RefuseWhy::Never)
    );
}

#[test]
fn classify_table() {
    use Class::*;
    let h = host_addrs();
    let rows = [
        ("8.8.8.8", Public),
        ("10.0.0.1", Lan),
        ("172.16.0.1", Lan),
        ("172.31.255.255", Lan),
        ("172.32.0.1", Public),
        ("192.168.0.1", Lan),
        ("fc00::1", Ula),
        ("fdff::1", Ula),
        ("169.254.0.1", LinkLocal),
        ("fe80::1", LinkLocal),
        ("100.64.0.1", Cgnat),
        ("100.127.255.255", Cgnat),
        ("127.0.0.1", Loopback),
        ("127.255.255.254", Loopback),
        ("::1", Loopback),
        ("192.168.1.10", HostOwn),
        ("2a01:4f8::10", HostOwn),
        ("::ffff:192.168.1.10", HostOwn),
        ("::ffff:10.0.0.1", Lan),
        ("::ffff:8.8.8.8", Public),
        ("2002:808:808::1", Public),
        ("64:ff9b::808:808", Public),
        ("64:ff9b:1::808:808", Never),
        ("2001:0:4136:e378:8000:63bf:f7f7:f7f7", Never),
        ("168.63.129.16", Never),
        ("::ffff:168.63.129.16", Never),
        ("0.0.0.0", Never),
        ("::", Never),
        ("255.255.255.255", Never),
        ("2001:db8::1", Never),
        ("198.18.0.1", Never),
    ];
    for (a, want) in rows {
        assert_eq!(classify(ip(a), &h), want, "{a}");
    }
}

#[test]
fn private_target_serde() {
    let rows = [
        (
            r#"{"host_port":"printer.local:631"}"#,
            PrivateTarget::HostPort(t("printer.local:631")),
        ),
        (
            r#"{"host_port":"[fd12::5]:80"}"#,
            PrivateTarget::HostPort(t("[fd12::5]:80")),
        ),
        (
            r#"{"cidr":"192.168.1.0/24","ports":"80-443"}"#,
            PrivateTarget::Cidr {
                net: ip("192.168.1.0"),
                prefix: 24,
                ports: (80, 443),
            },
        ),
        (
            r#"{"cidr":"fd12:3456::/48","ports":"8080"}"#,
            PrivateTarget::Cidr {
                net: ip("fd12:3456::"),
                prefix: 48,
                ports: (8080, 8080),
            },
        ),
        (r#""all_private""#, PrivateTarget::AllPrivate),
    ];
    for (json, want) in rows {
        let got: PrivateTarget =
            serde_json::from_str(json).unwrap_or_else(|e| panic!("{json}: {e}"));
        assert_eq!(got, want, "{json}");
        assert_eq!(serde_json::to_string(&got).unwrap(), json);
    }
    for bad in [
        r#"{"host_port":"[::ffff:192.168.1.20]:80"}"#,
        r#"{"host_port":"*.local:80"}"#,
        r#"{"host_port":"printer.local"}"#,
        r#"{"cidr":"192.168.1.1/24","ports":"80"}"#,
        r#"{"cidr":"192.168.1.0/33","ports":"80"}"#,
        r#"{"cidr":"::ffff:0:0/96","ports":"80"}"#,
        r#"{"cidr":"192.168.1.0/24","ports":"443-80"}"#,
        r#"{"cidr":"192.168.1.0/24","ports":"0"}"#,
        r#"{"cidr":"192.168.1.0/24","ports":"80-"}"#,
        r#"{"cidr":"192.168.1.0","ports":"80"}"#,
        r#""all""#,
    ] {
        assert!(serde_json::from_str::<PrivateTarget>(bad).is_err(), "{bad}");
    }
    let g: PrivateGrant =
        serde_json::from_str(r#"{"target":"all_private","expires":12.5}"#).unwrap();
    assert_eq!(g.expires, Some(12.5));
    let g: PrivateGrant =
        serde_json::from_str(r#"{"target":{"host_port":"nas.lan:5000"}}"#).unwrap();
    assert_eq!(g.expires, None);
}

fn any_ip() -> impl Strategy<Value = IpAddr> {
    prop_oneof![
        any::<u32>().prop_map(|a| IpAddr::V4(Ipv4Addr::from(a))),
        any::<u128>().prop_map(|a| IpAddr::V6(Ipv6Addr::from(a))),
        // the special ranges, so the search reaches them
        (
            prop::sample::select(vec![0u32, 10, 100, 127, 169, 172, 192, 224, 240]),
            any::<u32>()
        )
            .prop_map(|(hi, lo)| IpAddr::V4(Ipv4Addr::from((hi << 24) | (lo >> 8)))),
        // a v6 prefix and where the 32 bits go: compatible, mapped, NAT64 (both), 6to4, Teredo, ULA, link-local,
        // multicast
        (
            prop::sample::select(vec![
                (0u128, 0u32),
                (0xffff << 32, 0),
                (0x64_ff9b << 96, 0),
                (0x64_ff9b_0001 << 80, 0),
                (0x2002 << 112, 80),
                (0x2001_0000 << 96, 0),
                (0xfc00 << 112, 0),
                (0xfe80 << 112, 0),
                (0xff00 << 112, 0),
            ]),
            any::<u32>()
        )
            .prop_map(|((base, shift), v4)| IpAddr::V6(Ipv6Addr::from(
                base | (u128::from(v4) << shift)
            ))),
    ]
}

fn any_target() -> impl Strategy<Value = Target> {
    let host = prop_oneof![
        any_ip().prop_map(|a| match a {
            IpAddr::V4(a) => Host::V4(a),
            IpAddr::V6(a) => Host::V6(a),
        }),
        prop::sample::select(vec![
            "a.example",
            "printer.local",
            RESERVED_HOST,
            "localhost",
            "nas.lan"
        ])
        .prop_map(|n| Host::Name(n.to_owned())),
    ];
    (
        host,
        prop::sample::select(vec![22u16, 80, 443, 631, 5173, GATEWAY, 8080]),
    )
        .prop_map(|(host, port)| Target { host, port })
}

proptest! {
    /// With no grant, nothing that is not public is ever connected, whatever is asked and whatever DNS says.
    #[test]
    fn no_grant_no_private_connect(
        target in any_target(),
        answer in prop::collection::vec(any_ip(), 0..4),
        web in any::<bool>(),
        own in prop::collection::btree_set(any_ip(), 0..3),
    ) {
        let h = HostAddrs(own);
        let n = never();
        let ctx = WebCtx { web, deny_hosts: &[], grants: &[], now: NOW, host_addrs: &h, never: &n };
        let answer: Vec<SocketAddr> = answer.into_iter().map(|a| SocketAddr::new(a, target.port)).collect();
        if let Judgement::Connect(addrs) = judge(&target, &answer, &ctx) {
            for a in addrs {
                prop_assert_eq!(classify(a.ip(), &h), Class::Public, "{} → {}", target, a);
                prop_assert!(a.port() == 80 || a.port() == 443);
                prop_assert!(web);
            }
        }
    }
}
