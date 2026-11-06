//! The mock's instances: their states against the virtual clock, their containers, their console text.

use super::{Out, State, b64};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::process::Command;

#[derive(Clone, Copy, PartialEq, Debug)]
pub(crate) enum Provider {
    Aws,
    Gcp,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub(crate) enum St {
    Pending,
    Running,
    /// Powered off and kept (GCE `stop`, or an AWS shutdown behaviour of `stop`).
    Stopped,
    /// AWS `shutting-down`, GCE `STOPPING` before the delete lands.
    Ending,
    /// AWS `terminated`; for GCE the instance no longer exists.
    Gone,
}

pub(crate) struct Instance {
    pub id: String,
    /// GCE's name; AWS has none (its Name tag, if any, is a tag).
    pub name: String,
    pub provider: Provider,
    pub zone: String,
    pub itype: String,
    pub image: String,
    /// AWS tags, GCE labels.
    pub tags: BTreeMap<String, String>,
    pub state: St,
    pub created: u64,
    pub ready_at: u64,
    pub spot: bool,
    pub shutdown_requested: String,
    pub termination_at: Option<u64>,
    pub termination_raw: Option<String>,
    pub termination_action: String,
    pub notice_at: Option<u64>,
    pub notice_secs: u64,
    pub stuck_start: bool,
    pub stuck_end: bool,
    pub end_at: Option<u64>,
    pub hostkey_gen: u32,
    pub client_token: Option<String>,
    /// GCE's `scheduling`, as sent.
    pub scheduling: Value,
    pub tokens_required: bool,
    pub hop_limit: u32,
    pub seeded: bool,
}

impl Instance {
    pub fn new(provider: Provider, id: &str, name: &str, zone: &str, now: u64) -> Instance {
        Instance {
            id: id.into(),
            name: name.into(),
            provider,
            zone: zone.into(),
            itype: String::new(),
            image: String::new(),
            tags: BTreeMap::new(),
            state: St::Pending,
            created: now,
            ready_at: now,
            spot: false,
            shutdown_requested: "stop".into(),
            termination_at: None,
            termination_raw: None,
            termination_action: "DELETE".into(),
            notice_at: None,
            notice_secs: 120,
            stuck_start: false,
            stuck_end: false,
            end_at: None,
            hostkey_gen: 0,
            client_token: None,
            scheduling: Value::Null,
            tokens_required: false,
            hop_limit: 1,
            seeded: false,
        }
    }

    /// The instance's own key for lookups: AWS id, GCE name.
    pub fn key(&self) -> &str {
        match self.provider {
            Provider::Aws => &self.id,
            Provider::Gcp => &self.name,
        }
    }

    pub fn region(&self) -> String {
        match self.provider {
            Provider::Aws => self.zone[..self.zone.len() - 1].to_string(),
            Provider::Gcp => self
                .zone
                .rsplit_once('-')
                .map(|x| x.0.to_string())
                .unwrap_or_default(),
        }
    }

    pub fn aws_state(&self) -> (u32, &'static str) {
        match self.state {
            St::Pending => (0, "pending"),
            St::Running => (16, "running"),
            St::Stopped => (80, "stopped"),
            St::Ending => (32, "shutting-down"),
            St::Gone => (48, "terminated"),
        }
    }

    pub fn gce_state(&self) -> &'static str {
        match self.state {
            St::Pending => "PROVISIONING",
            St::Running => "RUNNING",
            St::Stopped | St::Gone => "TERMINATED",
            St::Ending => "STOPPING",
        }
    }

    /// The instance powers itself off, as its own `shutdown -h` would.
    pub fn poweroff(&mut self, now: u64) {
        if self.shutdown_requested == "terminate" {
            self.state = St::Ending;
            self.end_at = Some(now);
        } else {
            self.state = St::Stopped;
        }
    }

    pub fn notice_active(&self, now: u64) -> bool {
        self.state == St::Running && self.notice_at.is_some_and(|n| now >= n)
    }

    pub fn fingerprint(&self, kind: &str) -> String {
        let d = Sha256::digest(format!("{}/{}/{kind}", self.key(), self.hostkey_gen));
        format!("SHA256:{}", b64(&d).trim_end_matches('='))
    }

    /// What the image prints at first boot: the host-key fingerprints. Empty until the instance runs.
    pub fn console_text(&self) -> String {
        if !matches!(self.state, St::Running | St::Ending) {
            return String::new();
        }
        let mut t = String::from("[    0.000000] Linux version mock\n");
        t += "-----BEGIN SSH HOST KEY FINGERPRINTS-----\n";
        t += &format!(
            "256 {} root@{} (ED25519)\n",
            self.fingerprint("ed25519"),
            self.key()
        );
        t += &format!(
            "256 {} root@{} (ECDSA)\n",
            self.fingerprint("ecdsa"),
            self.key()
        );
        t += "-----END SSH HOST KEY FINGERPRINTS-----\n";
        t
    }

    pub fn describe(&self) -> Value {
        json!({
            "provider": if self.provider == Provider::Aws { "aws" } else { "gcp" },
            "id": self.id, "name": self.name, "zone": self.zone, "type": self.itype, "image": self.image,
            "tags": self.tags, "state": if self.provider == Provider::Aws { self.aws_state().1 } else { self.gce_state() },
            "created": self.created, "ready_at": self.ready_at, "spot": self.spot,
            "shutdown_requested": self.shutdown_requested, "notice_at": self.notice_at,
            "termination_at": self.termination_at, "client_token": self.client_token,
            "stuck": {"start": self.stuck_start, "end": self.stuck_end}, "seeded": self.seeded,
        })
    }
}

impl State {
    /// A new instance with the boot delay and the one-shot knobs (`next`) applied.
    pub fn add_instance(&mut self, mut i: Instance) -> usize {
        i.created = self.now;
        i.ready_at = self.now + self.boot_delay;
        if let Some(n) = self.next.notice_at.take() {
            i.notice_at = Some(n);
        }
        i.stuck_start |= std::mem::take(&mut self.next.stuck_start);
        i.stuck_end |= std::mem::take(&mut self.next.stuck_end);
        self.instances.push(i);
        self.instances.len() - 1
    }

    pub fn find(&self, provider: Provider, key: &str) -> Option<usize> {
        self.instances.iter().position(|i| {
            i.provider == provider
                && i.key() == key
                && !(provider == Provider::Gcp && i.state == St::Gone)
        })
    }
}

/// `POST /__mock/seed`: an instance the hub did not make (or one with exactly the tags the test wants).
pub(crate) fn seed(st: &mut State, b: &Value) -> Out {
    let provider = match b["provider"].as_str() {
        Some("aws") => Provider::Aws,
        Some("gcp") => Provider::Gcp,
        _ => return Out::json(400, json!({"mock": "\"provider\" is aws or gcp"})),
    };
    let Some(id) = b["id"].as_str() else {
        return Out::json(400, json!({"mock": "\"id\" is needed"}));
    };
    let zone = b["zone"].as_str().unwrap_or(if provider == Provider::Aws {
        "us-east-1a"
    } else {
        "us-central1-a"
    });
    let mut i = Instance::new(provider, id, id, zone, st.now);
    i.itype = b["type"].as_str().unwrap_or("m7g.large").into();
    i.seeded = true;
    i.shutdown_requested = "terminate".into();
    for (k, v) in b["tags"].as_object().into_iter().flatten() {
        i.tags
            .insert(k.clone(), v.as_str().unwrap_or("").to_string());
    }
    // a seeded instance is already running and never stuck
    let n = st.add_instance(i);
    st.instances[n].ready_at = st.now;
    st.instances[n].state = St::Running;
    Out::json(200, json!({"ok": true}))
}

/// The fake-runner container behind an instance: `<prefix>-cloud-<id>`, labelled with the run. Only such names are
/// ever created or removed.
pub(crate) struct Podman {
    /// None: instances live in memory only.
    pub sock: Option<String>,
    pub bin: String,
    pub image: String,
    pub network: String,
    pub prefix: String,
    pub run: String,
}

impl Podman {
    pub fn container(&self, i: &Instance) -> String {
        format!("{}-cloud-{}", self.prefix, i.key())
    }

    fn cmd(&self, sock: &str) -> Command {
        let mut c = Command::new(&self.bin);
        c.args(["--remote", "--url", &format!("unix://{sock}")]);
        c
    }

    pub fn start(&self, i: &Instance) {
        let Some(sock) = &self.sock else { return };
        if i.seeded {
            return;
        }
        let name = self.container(i);
        let out = self
            .cmd(sock)
            .args(["run", "-d", "--name", &name])
            .args(["--label", &format!("drgnx.fleet={}", self.run)])
            .args(["--label", &format!("drgnx.cloud-instance={}", i.key())])
            .args(["--network", &self.network, &self.image])
            .output();
        match out {
            Ok(o) if o.status.success() => {}
            Ok(o) => eprintln!(
                "ratatoskr-mock cloud: starting {name} failed: {}",
                String::from_utf8_lossy(&o.stderr)
            ),
            Err(e) => eprintln!("ratatoskr-mock cloud: cannot run {}: {e}", self.bin),
        }
    }

    pub fn stop(&self, i: &Instance) {
        let Some(sock) = &self.sock else { return };
        let name = self.container(i);
        if i.seeded || !name.starts_with(&format!("{}-cloud-", self.prefix)) {
            return;
        }
        let _ = self.cmd(sock).args(["rm", "-f", "-t", "0", &name]).output();
    }
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + if m <= 2 { 1 } else { 0 }, m, d)
}

/// `2026-11-06T00:00:00Z`.
pub(crate) fn iso(secs: u64) -> String {
    let (y, m, d) = civil_from_days((secs / 86400) as i64);
    let r = secs % 86400;
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        r / 3600,
        r % 3600 / 60,
        r % 60
    )
}

/// Only the `Z` form, with optional fraction.
pub(crate) fn parse_iso(s: &str) -> Option<u64> {
    let s = s.strip_suffix('Z')?;
    let (date, time) = s.split_once('T')?;
    let mut d = date.split('-').map(|x| x.parse::<i64>().ok());
    let (y, m, day) = (d.next()??, d.next()??, d.next()??);
    let mut t = time.split(':');
    let h: i64 = t.next()?.parse().ok()?;
    let mi: i64 = t.next()?.parse().ok()?;
    let sec: i64 = t.next()?.split('.').next()?.parse().ok()?;
    u64::try_from(days_from_civil(y, m, day) * 86400 + h * 3600 + mi * 60 + sec).ok()
}
