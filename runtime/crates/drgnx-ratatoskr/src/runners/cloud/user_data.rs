//! Cloud-init text (design 6.7.2): what the image build's machine runs, and what each instance is started with.
//!
//! - [`render_build`]: the build machine's user-data. It installs git, podman, the runner bundle, the watchdog unit, the
//!   SSH CA's public key (`TrustedUserCAKeys`), the runner user, the project images by digest, the git mirrors fetched
//!   from the hub, and a warm cargo registry; then it runs [`FINAL_STEPS`] (host keys removed, `cloud-init clean`,
//!   power off) so the stopped disk can be imaged.
//! - [`render`]: a started instance's user-data: public things only (the CA's public key, the machine's principal, the
//!   watchdog's limits). Any process on the machine can read it from the instance metadata, so it never holds a secret.
//!
//! The first-boot script and the two units are files under `image/`, baked into the image by the build and tested
//! locally by `test/runners/image-units.sh`.

use super::CloudError;
use sha2::{Digest, Sha256};

/// The script that reads the instance's user-data at every first boot (see its header).
pub const FIRST_BOOT: &str = include_str!("image/drgnx-first-boot");
/// Its unit.
pub const FIRST_BOOT_UNIT: &str = include_str!("image/drgnx-first-boot.service");
/// The watchdog's unit (`sleipnir watchdog`, with the limits `drgnx-first-boot` wrote).
pub const WATCHDOG_UNIT: &str = include_str!("image/drgnx-watchdog.service");

/// What the build machine does last, in this order: the images's host keys are removed (each instance makes its own at
/// first boot), cloud-init forgets this boot, the disk is flushed, and the machine powers itself off (`systemctl
/// poweroff`, never `halt`, which leaves the instance running).
pub const FINAL_STEPS: [&str; 4] = [
    "rm -f /etc/ssh/ssh_host_*",
    "cloud-init clean --logs",
    "sync",
    "systemctl poweroff",
];

/// The watchdog's limits in seconds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    pub idle: u64,
    pub lifetime: u64,
    pub unattended: u64,
}

/// Which provider's watchdog rules apply.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Flavor {
    Aws,
    Gcp,
}

/// What the image is built from. Everything here is public.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BuildInputs {
    pub drgnx_version: String,
    pub bundle_version: String,
    /// Where the runner bundle (the `sleipnir` binary of this hub's version) is fetched from, and its SHA-256.
    pub bundle_url: String,
    pub bundle_sha256: String,
    /// The CA's public key line (`ssh-ed25519 AAAA… comment`).
    pub ca_public: String,
    /// Project images, each `NAME@sha256:DIGEST`.
    pub images: Vec<String>,
    /// Git mirrors fetched from the hub: (name, URL).
    pub mirrors: Vec<(String, String)>,
    /// The hub's `packages` proxy tier, for the cargo registry warm-up; none skips it.
    pub packages_proxy: Option<String>,
}

fn bad(why: impl Into<String>) -> CloudError {
    CloudError::Other(format!("the image inputs: {}", why.into()))
}

/// SHELL-quoted: one word whatever it holds.
fn q(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

fn plain(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

impl BuildInputs {
    fn check(&self) -> Result<(), CloudError> {
        if !self.ca_public.starts_with("ssh-ed25519 ") || self.ca_public.contains(['\n', '\r']) {
            return Err(bad("the CA key is not one `ssh-ed25519` public key line"));
        }
        if self.ca_public.contains("PRIVATE") {
            return Err(bad("the CA key line holds a private key"));
        }
        if self.bundle_sha256.len() != 64
            || !self.bundle_sha256.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err(bad("the bundle's SHA-256 is not 64 hex digits"));
        }
        for u in std::iter::once(&self.bundle_url)
            .chain(self.mirrors.iter().map(|(_, u)| u))
            .chain(self.packages_proxy.iter())
        {
            if !u.starts_with("https://") || u.contains(['\n', '\r', ' ']) || u.contains('@') {
                return Err(bad(format!(
                    "{u:?} is not an https:// URL without credentials"
                )));
            }
        }
        for i in &self.images {
            let ok = i.split_once("@sha256:").is_some_and(|(n, d)| {
                !n.is_empty()
                    && !n.contains(char::is_whitespace)
                    && d.len() == 64
                    && d.bytes().all(|b| b.is_ascii_hexdigit())
            });
            if !ok {
                return Err(bad(format!("image {i:?} is not named by digest")));
            }
        }
        for (n, _) in &self.mirrors {
            if !plain(n) {
                return Err(bad(format!("mirror name {n:?}")));
            }
        }
        for v in [&self.drgnx_version, &self.bundle_version] {
            if !plain(v) {
                return Err(bad(format!("version {v:?}")));
            }
        }
        Ok(())
    }

    /// The commands the build machine runs, in order, ending with [`FINAL_STEPS`].
    pub fn steps(&self) -> Result<Vec<String>, CloudError> {
        self.check()?;
        let mut s: Vec<String> = vec![
            "install -d -m 0755 /usr/local/libexec /usr/local/bin /etc/drgnx /var/lib/drgnx/runner /var/lib/drgnx/mirrors /var/lib/drgnx/cache/cargo".into(),
            "id runner >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash runner".into(),
            "passwd -l runner".into(),
            "echo 'runner:20000:30000' > /etc/subuid; echo 'runner:20000:30000' > /etc/subgid".into(),
            "loginctl enable-linger runner".into(),
            "chown -R runner:runner /var/lib/drgnx".into(),
            format!("curl -fsS --max-time 600 -o /usr/local/bin/sleipnir {}", q(&self.bundle_url)),
            format!("echo {} | sha256sum -c -", q(&format!("{}  /usr/local/bin/sleipnir", self.bundle_sha256))),
            "chmod 0755 /usr/local/bin/sleipnir".into(),
            "chmod 0755 /usr/local/libexec/drgnx-first-boot".into(),
            "systemctl enable drgnx-first-boot.service drgnx-watchdog.service".into(),
        ];
        let as_runner = |c: String| format!("runuser -u runner -- bash -c {}", q(&c));
        for i in &self.images {
            s.push(as_runner(format!("podman pull {}", q(i))));
        }
        for (n, u) in &self.mirrors {
            s.push(as_runner(format!(
                "git clone --mirror {} /var/lib/drgnx/mirrors/{n}.git",
                q(u)
            )));
        }
        if let (Some(proxy), Some(image), false) = (
            &self.packages_proxy,
            self.images.first(),
            self.mirrors.is_empty(),
        ) {
            for (n, _) in &self.mirrors {
                s.push(as_runner(format!(
                    "git clone -q /var/lib/drgnx/mirrors/{n}.git /tmp/warm-{n} && podman run --rm --pull=never \
                     -e CARGO_HOME=/cargo -e CARGO_HTTP_PROXY={p} -v /var/lib/drgnx/cache/cargo:/cargo -v /tmp/warm-{n}:/src:ro \
                     {i} cargo fetch --manifest-path /src/Cargo.toml; rm -rf /tmp/warm-{n}",
                    p = q(proxy),
                    i = q(image),
                )));
            }
        }
        s.extend(FINAL_STEPS.iter().map(|c| c.to_string()));
        Ok(s)
    }
}

/// A block scalar's body: TEXT indented by INDENT spaces.
fn block(text: &str, indent: usize) -> String {
    let pad = " ".repeat(indent);
    text.lines()
        .map(|l| {
            if l.is_empty() {
                String::new()
            } else {
                format!("{pad}{l}")
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn file(path: &str, mode: &str, content: &str) -> String {
    format!(
        "  - path: {path}\n    permissions: '{mode}'\n    owner: root:root\n    content: |\n{}\n",
        block(content, 6)
    )
}

/// The build machine's user-data (cloud-config). An error names the input that is not allowed.
pub fn render_build(inputs: &BuildInputs) -> Result<String, CloudError> {
    let steps = inputs.steps()?;
    // one script with `set -e`: a failed step leaves the machine running, so the build times out and says so, instead
    // of imaging a half-installed disk
    let mut script = String::from("#!/bin/bash\nset -euo pipefail\n");
    for st in &steps {
        script.push_str(st);
        script.push('\n');
    }
    let mut out = String::from("#cloud-config\nssh_deletekeys: true\npackages:\n");
    for p in [
        "git",
        "podman",
        "openssh-server",
        "curl",
        "shadow-utils",
        "crun",
    ] {
        out.push_str(&format!("  - {p}\n"));
    }
    out.push_str("write_files:\n");
    out.push_str(&file(
        "/etc/cloud/cloud.cfg.d/99-drgnx.cfg",
        "0644",
        "ssh_deletekeys: true\n",
    ));
    out.push_str(&file(
        "/etc/ssh/drgnx-ca.pub",
        "0644",
        &format!("{}\n", inputs.ca_public),
    ));
    out.push_str(&file(
        "/usr/local/libexec/drgnx-first-boot",
        "0755",
        FIRST_BOOT,
    ));
    out.push_str(&file(
        "/etc/systemd/system/drgnx-first-boot.service",
        "0644",
        FIRST_BOOT_UNIT,
    ));
    out.push_str(&file(
        "/etc/systemd/system/drgnx-watchdog.service",
        "0644",
        WATCHDOG_UNIT,
    ));
    out.push_str(&file("/usr/local/libexec/drgnx-build", "0700", &script));
    out.push_str("runcmd:\n  - [bash, /usr/local/libexec/drgnx-build]\n");
    Ok(out)
}

/// A hash of what the image is made of: the same inputs and base give the same hash.
pub fn input_hash(inputs: &BuildInputs, base_id: &str) -> Result<String, CloudError> {
    let text = render_build(inputs)?;
    let d = Sha256::new()
        .chain_update(text.as_bytes())
        .chain_update(b"\0")
        .chain_update(base_id.as_bytes())
        // the versions are tags on the image: a new release is a new image even if the text is the same
        .chain_update(b"\0")
        .chain_update(inputs.drgnx_version.as_bytes())
        .chain_update(b"\0")
        .chain_update(inputs.bundle_version.as_bytes())
        .finalize();
    Ok(d.iter().map(|b| format!("{b:02x}")).collect())
}

/// A started instance's user-data: the CA's public key (when it is newer than the image's), the principal and the
/// watchdog's limits. Nothing else.
pub fn render(ca_public: Option<&str>, principal: &str, limits: Limits, flavor: Flavor) -> String {
    let clean = |s: &str| -> String { s.chars().filter(|c| !matches!(c, '\n' | '\r')).collect() };
    let mut out = String::from("#cloud-config\n");
    out.push_str(&format!(
        "drgnx-provider: {}\n",
        match flavor {
            Flavor::Aws => "aws",
            Flavor::Gcp => "gcp",
        }
    ));
    out.push_str(&format!("drgnx-principal: {}\n", clean(principal)));
    if let Some(ca) = ca_public {
        out.push_str(&format!("drgnx-ca: {}\n", clean(ca)));
    }
    out.push_str(&format!(
        "drgnx-watchdog-idle: {}\ndrgnx-watchdog-lifetime: {}\ndrgnx-watchdog-unattended: {}\n",
        limits.idle, limits.lifetime, limits.unattended
    ));
    out
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;
    use crate::runners::cloud::ca::{Ca, UserKey};
    use secrecy::ExposeSecret;

    pub(crate) fn inputs(ca_public: String) -> BuildInputs {
        BuildInputs {
            drgnx_version: "0.6.0".into(),
            bundle_version: "6.0.0-1".into(),
            bundle_url: "https://hub.example/runner-bundle/6.0.0-1".into(),
            bundle_sha256: "ab".repeat(32),
            ca_public,
            images: vec![format!(
                "registry.example/drgnx/rust@sha256:{}",
                "cd".repeat(32)
            )],
            mirrors: vec![(
                "drgnx".into(),
                "https://hub.example/mirrors/drgnx.git".into(),
            )],
            packages_proxy: Some("https://hub.example/packages".into()),
        }
    }

    const LIMITS: Limits = Limits {
        idle: 600,
        lifetime: 28800,
        unattended: 3600,
    };

    /// Every text a started instance or the build is given, with the files the build writes decoded as they are.
    fn every_text(held: &Ca, user: &UserKey) -> Vec<String> {
        let (ca_pub, principal) = (held.public().to_openssh("drgnx-ca"), "drgnx-c1");
        let b = inputs(ca_pub.clone());
        vec![
            render_build(&b).unwrap(),
            b.steps().unwrap().join("\n"),
            render(Some(&ca_pub), principal, LIMITS, Flavor::Aws),
            render(None, principal, LIMITS, Flavor::Gcp),
            user.public().to_openssh("drgnx"),
        ]
    }

    // [D] pure
    #[test]
    fn user_data_holds_no_secret() {
        let (held, _) = Ca::new();
        let user = UserKey::generate();
        let pem = held.to_secret();
        let pem = pem.expose_secret();
        // the key's body, line by line, and its base64 as one string: none of it may appear anywhere
        let body: Vec<&str> = pem
            .lines()
            .filter(|l| !l.starts_with("-----") && l.len() > 8)
            .collect();
        assert!(!body.is_empty());
        let joined: String = body.concat();
        for text in every_text(&held, &user) {
            for line in &body {
                assert!(
                    !text.contains(line),
                    "a line of the held CA key is in the text"
                );
            }
            assert!(!text.contains(&joined));
            assert!(!text.contains("PRIVATE KEY"), "{text}");
            // the CA's public key line is the one thing of the CA's that belongs here; its base64 is high-entropy
            let rest: String = text
                .lines()
                .filter(|l| !l.contains("ssh-ed25519 "))
                .collect::<Vec<_>>()
                .join("\n");
            assert_eq!(runstav::secrets::looks_like_secret(&rest), None, "{rest}");
        }
        // the public key is there, as the one thing from the CA that is
        assert!(
            render_build(&inputs(held.public().to_openssh("drgnx-ca")))
                .unwrap()
                .contains("ssh-ed25519 ")
        );
        // and a private key handed in as the CA's key is refused, not written
        let mut b = inputs(held.public().to_openssh("drgnx-ca"));
        b.ca_public = pem.to_string();
        assert!(render_build(&b).is_err());
    }

    // [D] pure
    #[test]
    fn host_keys_removed_before_the_snapshot() {
        let (held, _) = Ca::new();
        let steps = inputs(held.public().to_openssh("x")).steps().unwrap();
        let at = |needle: &str| {
            steps
                .iter()
                .position(|s| s.contains(needle))
                .unwrap_or_else(|| panic!("no step {needle}"))
        };
        let (rm, clean, off) = (
            at("rm -f /etc/ssh/ssh_host_*"),
            at("cloud-init clean --logs"),
            at("systemctl poweroff"),
        );
        assert!(rm < clean && clean < off, "{steps:?}");
        assert_eq!(off, steps.len() - 1, "the power-off is the last step");
        assert_eq!(
            &steps[steps.len() - FINAL_STEPS.len()..],
            FINAL_STEPS.map(String::from)
        );
        assert!(
            !steps.iter().any(|s| s.contains("halt")),
            "systemctl poweroff, never halt"
        );
        // each instance makes its own host keys: cloud-init is told to delete the baked ones
        let ud = render_build(&inputs(held.public().to_openssh("x"))).unwrap();
        assert!(ud.contains("ssh_deletekeys: true"));
        assert!(ud.contains("/etc/cloud/cloud.cfg.d/99-drgnx.cfg"));
    }

    // [D] pure
    #[test]
    fn the_build_takes_only_public_checked_inputs() {
        let (held, _) = Ca::new();
        let good = inputs(held.public().to_openssh("x"));
        let mut b = good.clone();
        b.images = vec!["registry.example/rust:latest".into()];
        assert!(
            render_build(&b)
                .unwrap_err()
                .to_string()
                .contains("by digest")
        );
        let mut b = good.clone();
        b.mirrors = vec![("a b".into(), "https://x/".into())];
        assert!(render_build(&b).is_err());
        let mut b = good.clone();
        b.bundle_url = "http://hub/x".into();
        assert!(render_build(&b).is_err());
        let mut b = good.clone();
        b.mirrors = vec![("m".into(), "https://user:pw@hub/x.git".into())];
        assert!(render_build(&b).is_err(), "no credentials in a URL");
        // a quote in an input stays one word
        let mut b = good;
        let img = format!("x'y@sha256:{}", "cd".repeat(32));
        b.images = vec![img.clone()];
        let steps = b.steps().unwrap();
        let want = format!(
            "runuser -u runner -- bash -c {}",
            q(&format!("podman pull {}", q(&img)))
        );
        assert!(steps.contains(&want), "{steps:?}");
    }

    // [D] pure
    #[test]
    fn an_instance_gets_the_principal_the_limits_and_nothing_more() {
        let t = render(
            Some("ssh-ed25519 AAAAC3Nza drgnx-ca"),
            "drgnx-c1\nevil: 1",
            LIMITS,
            Flavor::Gcp,
        );
        let keys: Vec<&str> = t
            .lines()
            .skip(1)
            .filter_map(|l| l.split_once(": ").map(|p| p.0))
            .collect();
        assert_eq!(
            keys,
            [
                "drgnx-provider",
                "drgnx-principal",
                "drgnx-ca",
                "drgnx-watchdog-idle",
                "drgnx-watchdog-lifetime",
                "drgnx-watchdog-unattended"
            ]
        );
        assert!(t.starts_with("#cloud-config\n"));
        assert!(
            t.contains("drgnx-principal: drgnx-c1evil: 1\n"),
            "a newline cannot start a second key: {t}"
        );
        assert!(t.contains("drgnx-watchdog-lifetime: 28800\n"));
    }

    // [D] pure
    #[test]
    fn the_same_inputs_and_base_hash_alike() {
        let (held, _) = Ca::new();
        let a = inputs(held.public().to_openssh("x"));
        let h = input_hash(&a, "ami-1").unwrap();
        assert_eq!(h, input_hash(&a, "ami-1").unwrap());
        assert_ne!(h, input_hash(&a, "ami-2").unwrap());
        let mut b = a.clone();
        b.bundle_version = "6.0.0-2".into();
        assert_ne!(h, input_hash(&b, "ami-1").unwrap());
        assert_eq!(h.len(), 64);
    }
}
