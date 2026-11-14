//! The Ignition config a GCP machine boots with (design §6.7.2): Fedora CoreOS `stable`, set up by JSON written here
//! and passed as the instance's `user-data` metadata.
//!
//! Fedora CoreOS runs Ignition once, from the initramfs of a disk's first boot, so each machine gets its whole setup in
//! its own config instead of a baked image: the runner user (with linger and subordinate ids), the runner fetched from
//! the hub and checked by its SHA-256, the SSH CA's public key and the machine's one principal with sshd taking
//! certificates only, the watchdog in its GCP mode (it reports idleness and preemption; it never powers off: a stopped VM
//! bills its disk and loses its deadline), the host keys printed to the serial port for the hub to pin, and Zincati
//! (automatic updates and their reboots) off, so no reboot lands mid-job. Everything in it is public: any process on
//! the machine can read its metadata.

use super::CloudError;
use super::aws::pct;
use super::user_data::{Limits, WATCHDOG_UNIT};
use serde_json::{Value, json};

/// Zincati's drop-in that turns automatic updates off.
pub const ZINCATI_OFF: &str = "[updates]\nenabled = false\n";

/// The Ignition spec version written (Fedora CoreOS `stable` reads it).
pub const SPEC: &str = "3.4.0";

/// sshd: the hub's certificates for this machine's principal, nothing else (read before the distribution's drop-ins:
/// sshd keeps an option's first value).
const SSHD: &str = "TrustedUserCAKeys /etc/ssh/drgnx-ca.pub
AuthorizedPrincipalsFile /etc/ssh/drgnx-principals
AuthorizedKeysFile none
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
MaxAuthTries 2
";

/// Prints the host keys to the serial port in cloud-init's shape (`ca::pin::from_console` reads it).
const HOST_KEYS: &str = "#!/bin/bash
# drgnx: this machine's SSH host keys on the serial port, where the hub reads and pins them (no key is trusted on first
# use): the fingerprints, then the keys.
set -euo pipefail
echo '-----BEGIN SSH HOST KEY FINGERPRINTS-----'
for k in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -l -f \"$k\"; done
echo '-----END SSH HOST KEY FINGERPRINTS-----'
echo '-----BEGIN SSH HOST KEY KEYS-----'
cat /etc/ssh/ssh_host_*_key.pub
echo '-----END SSH HOST KEY KEYS-----'
";

/// Its unit: after the keys are made, before sshd takes logins, its output on the first serial port.
const HOST_KEYS_UNIT: &str = "[Unit]
Description=drgnx: the SSH host keys on the serial port, where the hub pins them
After=sshd-keygen.target
Wants=sshd-keygen.target
Before=sshd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/libexec/drgnx-host-keys
StandardOutput=tty
TTYPath=/dev/ttyS0

[Install]
WantedBy=multi-user.target
";

/// The runner user's subordinate ids, for rootless podman.
const SUBIDS: &str = "runner:524288:65536\n";

/// What one machine is given. Everything here is public.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Machine {
    /// The CA's public key line (`ssh-ed25519 AAAA… comment`).
    pub ca_public: String,
    /// The one principal this machine's certificates carry.
    pub principal: String,
    pub limits: Limits,
    /// Where the runner (`sleipnir` of this hub's version) is fetched from, and its SHA-256.
    pub bundle_url: String,
    pub bundle_sha256: String,
}

fn bad(why: impl Into<String>) -> CloudError {
    CloudError::Other(format!("the machine's Ignition config: {}", why.into()))
}

impl Machine {
    fn check(&self) -> Result<(), CloudError> {
        if !self.ca_public.starts_with("ssh-ed25519 ")
            || self.ca_public.contains(['\n', '\r'])
            || self.ca_public.contains("PRIVATE")
        {
            return Err(bad("the CA key is not one `ssh-ed25519` public key line"));
        }
        if self.principal.is_empty()
            || !self
                .principal
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err(bad(format!("the principal {:?}", self.principal)));
        }
        let u = &self.bundle_url;
        if !u.starts_with("https://") || u.contains(['\n', '\r', ' ', '@']) {
            return Err(bad(format!(
                "{u:?} is not an https:// URL without credentials"
            )));
        }
        if self.bundle_sha256.len() != 64
            || !self.bundle_sha256.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err(bad("the bundle's SHA-256 is not 64 hex digits"));
        }
        Ok(())
    }
}

/// TEXT as an Ignition source: a percent-encoded `data:` URL.
fn data(text: &str) -> Value {
    json!({"source": format!("data:,{}", pct(text))})
}

fn file(path: &str, mode: u32, text: &str) -> Value {
    json!({"path": path, "mode": mode, "overwrite": true, "contents": data(text)})
}

/// The image's watchdog unit as Fedora CoreOS runs it: the same `sleipnir watchdog` command line, its limits from the
/// file Ignition wrote before boot (there is no first-boot unit to wait for).
fn watchdog_unit() -> String {
    let mut out = String::new();
    for l in WATCHDOG_UNIT.lines() {
        if l.starts_with('#') || l.contains("drgnx-first-boot") {
            continue;
        }
        if l.starts_with("Description=") {
            out.push_str(
                "Description=drgnx watchdog: tells the hub when the machine is idle or preempted (the hub deletes it)\n",
            );
            continue;
        }
        out.push_str(l);
        out.push('\n');
    }
    out
}

/// The machine's Ignition config (JSON). An error names the input that is not allowed.
pub fn render(m: &Machine) -> Result<String, CloudError> {
    m.check()?;
    let l = m.limits;
    let env = format!(
        "DRGNX_WATCHDOG_PROVIDER=gcp\nDRGNX_WATCHDOG_IDLE={}\nDRGNX_WATCHDOG_LIFETIME={}\nDRGNX_WATCHDOG_UNATTENDED={}\n",
        l.idle, l.lifetime, l.unattended
    );
    let runner = json!({"name": "runner"});
    let cfg = json!({
        "ignition": {"version": SPEC},
        "passwd": {"users": [{"name": "runner"}]},
        "storage": {
            "directories": [
                {"path": "/var/lib/drgnx", "mode": 0o755},
                {"path": "/var/lib/drgnx/runner", "mode": 0o755, "user": runner, "group": runner},
            ],
            "files": [
                file("/etc/zincati/config.d/90-drgnx-no-updates.toml", 0o644, ZINCATI_OFF),
                file("/etc/ssh/drgnx-ca.pub", 0o644, &format!("{}\n", m.ca_public)),
                file("/etc/ssh/drgnx-principals", 0o644, &format!("{}\n", m.principal)),
                file("/etc/ssh/sshd_config.d/01-drgnx.conf", 0o644, SSHD),
                file("/etc/drgnx/watchdog.env", 0o644, &env),
                file("/usr/local/libexec/drgnx-host-keys", 0o755, HOST_KEYS),
                {"path": "/usr/local/bin/sleipnir", "mode": 0o755, "overwrite": true,
                 "contents": {"source": m.bundle_url,
                              "verification": {"hash": format!("sha256-{}", m.bundle_sha256.to_ascii_lowercase())}}},
                file("/var/lib/systemd/linger/runner", 0o644, ""),
                {"path": "/etc/subuid", "append": [data(SUBIDS)]},
                {"path": "/etc/subgid", "append": [data(SUBIDS)]},
            ],
        },
        "systemd": {"units": [
            {"name": "zincati.service", "mask": true},
            {"name": "drgnx-watchdog.service", "enabled": true, "contents": watchdog_unit()},
            {"name": "drgnx-host-keys.service", "enabled": true, "contents": HOST_KEYS_UNIT},
        ]},
    });
    Ok(cfg.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runners::cloud::ca::Ca;
    use secrecy::ExposeSecret;

    const LIMITS: Limits = Limits {
        idle: 900,
        lifetime: 28800,
        unattended: 7200,
    };

    fn machine(ca_public: String) -> Machine {
        Machine {
            ca_public,
            principal: "drgnx-c1".into(),
            limits: LIMITS,
            bundle_url: "https://hub.example/runner-bundle/6.0.0-1".into(),
            bundle_sha256: "ab".repeat(32),
        }
    }

    fn pct_decode(s: &str) -> String {
        let b = s.as_bytes();
        let mut out = Vec::new();
        let mut i = 0;
        while i < b.len() {
            if b[i] == b'%' && i + 2 < b.len() {
                out.push(u8::from_str_radix(&s[i + 1..i + 3], 16).unwrap());
                i += 3;
            } else {
                out.push(b[i]);
                i += 1;
            }
        }
        String::from_utf8(out).unwrap()
    }

    /// Every file Ignition writes, by path: its decoded text (an `append` is its one line), or its URL when fetched.
    fn files(cfg: &Value) -> Vec<(String, String)> {
        cfg["storage"]["files"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| {
                let src = f["contents"]["source"]
                    .as_str()
                    .or(f["append"][0]["source"].as_str())
                    .unwrap_or("data:,");
                let text = match src.strip_prefix("data:,") {
                    Some(d) => pct_decode(d),
                    None => src.to_string(),
                };
                (f["path"].as_str().unwrap().to_string(), text)
            })
            .collect()
    }

    fn file<'a>(all: &'a [(String, String)], path: &str) -> &'a str {
        &all.iter()
            .find(|(p, _)| p == path)
            .unwrap_or_else(|| panic!("no file {path}: {all:?}"))
            .1
    }

    fn unit<'a>(cfg: &'a Value, name: &str) -> &'a Value {
        cfg["systemd"]["units"]
            .as_array()
            .unwrap()
            .iter()
            .find(|u| u["name"] == name)
            .unwrap_or_else(|| panic!("no unit {name}"))
    }

    /// Every text the machine is given: the files, the units, and the JSON around them with the file sources left out.
    fn every_text(cfg: &Value) -> Vec<String> {
        let mut out: Vec<String> = files(cfg).into_iter().map(|(_, t)| t).collect();
        for u in cfg["systemd"]["units"].as_array().unwrap() {
            out.push(u["contents"].as_str().unwrap_or("").to_string());
        }
        let mut bare = cfg.clone();
        for f in bare["storage"]["files"].as_array_mut().unwrap() {
            f["contents"] = Value::Null;
            f["append"] = Value::Null;
        }
        // Ignition's own `"passwd": {…}` reads to the heuristic as an assignment; it holds the user's name only, which
        // the test asserts exactly
        bare.as_object_mut().unwrap().remove("passwd");
        out.push(bare.to_string());
        out
    }

    // [D] pure
    #[test]
    fn ignition_turns_zincati_off_and_holds_no_secret() {
        let (held, ca_pub) = Ca::new();
        let text = render(&machine(ca_pub.to_openssh("drgnx-ca"))).unwrap();
        let cfg: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(cfg["ignition"]["version"], "3.4.0");
        // Zincati off: no reboot lands mid-job (the image is rebuilt instead)
        assert_eq!(unit(&cfg, "zincati.service")["mask"], true);
        let all = files(&cfg);
        assert_eq!(
            file(&all, "/etc/zincati/config.d/90-drgnx-no-updates.toml"),
            ZINCATI_OFF
        );
        // SSH by the hub's certificates only, for this machine's one principal
        assert_eq!(
            file(&all, "/etc/ssh/drgnx-ca.pub"),
            format!("{}\n", ca_pub.to_openssh("drgnx-ca"))
        );
        assert_eq!(file(&all, "/etc/ssh/drgnx-principals"), "drgnx-c1\n");
        let sshd = file(&all, "/etc/ssh/sshd_config.d/01-drgnx.conf");
        for l in [
            "TrustedUserCAKeys /etc/ssh/drgnx-ca.pub",
            "AuthorizedPrincipalsFile /etc/ssh/drgnx-principals",
            "AuthorizedKeysFile none",
            "PasswordAuthentication no",
            "PermitRootLogin no",
        ] {
            assert!(sshd.lines().any(|x| x == l), "{l} in {sshd}");
        }
        // the runner fetched at boot, checked by its hash
        let bin = cfg["storage"]["files"]
            .as_array()
            .unwrap()
            .iter()
            .find(|f| f["path"] == "/usr/local/bin/sleipnir")
            .unwrap();
        assert_eq!(
            bin["contents"]["source"],
            "https://hub.example/runner-bundle/6.0.0-1"
        );
        assert_eq!(
            bin["contents"]["verification"]["hash"],
            format!("sha256-{}", "ab".repeat(32))
        );
        // the runner user: a name, no password and no key
        assert_eq!(cfg["passwd"], json!({"users": [{"name": "runner"}]}));
        // the host keys reach the serial port in the shape the hub pins
        let hk = unit(&cfg, "drgnx-host-keys.service");
        assert_eq!(hk["enabled"], true);
        let hk_unit = hk["contents"].as_str().unwrap();
        assert!(hk_unit.contains("TTYPath=/dev/ttyS0"), "{hk_unit}");
        let script = file(&all, "/usr/local/libexec/drgnx-host-keys");
        for marker in [
            "-----BEGIN SSH HOST KEY FINGERPRINTS-----",
            "-----END SSH HOST KEY FINGERPRINTS-----",
            "-----BEGIN SSH HOST KEY KEYS-----",
            "-----END SSH HOST KEY KEYS-----",
        ] {
            assert!(script.contains(marker), "{marker} in {script}");
        }
        // no secret anywhere: no line of the CA's private key, nothing that reads as a secret but the CA's public line
        let pem = held.to_secret();
        let body: Vec<&str> = pem
            .expose_secret()
            .lines()
            .filter(|l| !l.starts_with("-----") && l.len() > 8)
            .collect();
        assert!(!body.is_empty());
        for t in every_text(&cfg) {
            for line in &body {
                assert!(
                    !t.contains(line),
                    "a line of the held CA key is in the config"
                );
            }
            assert!(!t.contains("PRIVATE KEY"), "{t}");
            let rest: String = t
                .lines()
                .filter(|l| !l.contains("ssh-ed25519 "))
                .collect::<Vec<_>>()
                .join("\n");
            assert_eq!(runstav::secrets::looks_like_secret(&rest), None, "{rest}");
        }
        assert!(!text.contains(&body.concat()));
        // a private key handed in as the CA's is refused, not written; so is a URL with credentials
        let mut bad = machine(ca_pub.to_openssh("drgnx-ca"));
        bad.ca_public = pem.expose_secret().to_string();
        assert!(render(&bad).is_err());
        let mut bad = machine(ca_pub.to_openssh("drgnx-ca"));
        bad.bundle_url = "https://u:pw@hub.example/b".into();
        assert!(render(&bad).is_err());
        let mut bad = machine(ca_pub.to_openssh("drgnx-ca"));
        bad.principal = "drgnx-c1\nevil".into();
        assert!(render(&bad).is_err());
    }

    // [D] pure
    #[test]
    fn the_guest_never_powers_off_on_gcp() {
        let (_, ca_pub) = Ca::new();
        let cfg: Value =
            serde_json::from_str(&render(&machine(ca_pub.to_openssh("drgnx-ca"))).unwrap())
                .unwrap();
        let all = files(&cfg);
        // the watchdog runs in its GCP mode: it reports idleness and preemption, and the hub (or GCP's deadline) deletes
        let env = file(&all, "/etc/drgnx/watchdog.env");
        assert_eq!(
            env,
            "DRGNX_WATCHDOG_PROVIDER=gcp\nDRGNX_WATCHDOG_IDLE=900\nDRGNX_WATCHDOG_LIFETIME=28800\nDRGNX_WATCHDOG_UNATTENDED=7200\n"
        );
        let wd = unit(&cfg, "drgnx-watchdog.service");
        assert_eq!(wd["enabled"], true);
        let wd = wd["contents"].as_str().unwrap();
        assert!(wd.contains("--provider ${DRGNX_WATCHDOG_PROVIDER}"), "{wd}");
        assert!(
            wd.contains("--root /var/lib/drgnx/runner --dir /var/lib/drgnx/watchdog"),
            "{wd}"
        );
        assert!(
            wd.contains("EnvironmentFile=/etc/drgnx/watchdog.env"),
            "{wd}"
        );
        assert!(
            !wd.contains("drgnx-first-boot"),
            "Fedora CoreOS has no first-boot unit: Ignition wrote its files before boot: {wd}"
        );
        // nothing the machine is given stops it: a stopped VM bills its disk and loses its deadline
        for t in every_text(&cfg) {
            let lower = t.to_ascii_lowercase();
            for word in [
                "poweroff",
                "power-off",
                "halt",
                "shutdown",
                "systemctl stop",
                "powers the machine off",
            ] {
                assert!(!lower.contains(word), "{word:?} in {t}");
            }
        }
    }
}
