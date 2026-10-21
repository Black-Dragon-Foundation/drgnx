//! The spec: what a sandboxed program may see, as plain data (docs/develop/gleipnir.md, "The spec").
//!
//! Nothing here checks anything. [`crate::validate`] turns a [`Spec`] into a [`ValidSpec`] for one [`Target`], and
//! only a `ValidSpec` reaches a backend. Sources are the caller's true names; a bind's `dest` is its path inside.
//!
//! Serde refuses unknown fields at every level, so a misspelt key is an error and never a silently dropped rule. A
//! missing list is empty; `chdir`, `net` and `layers` are required.

use crate::validate::Checked;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Where the inner helper (the `ratatoskr` binary) is bound read-only inside bwrap. Gleipnir binds it itself, last,
/// and never through `validate`.
pub const HELPER_INSIDE: &str = "/run/gleipnir/helper";

/// Destinations no `binds`, `home` or `hide` entry may equal, lie above or lie under (validation rule 11), so that
/// nothing can cover the helper.
pub const RESERVED_DESTS: &[&str] = &["/run/gleipnir"];

/// Environment names no spec may set. The caller adds its own in `validate::Context::env_deny`.
pub const BASE_ENV_DENY: &[&str] = &[
    "SSH_AUTH_SOCK",
    "DBUS_SESSION_BUS_ADDRESS",
    "XDG_RUNTIME_DIR",
    "DISPLAY",
    "WAYLAND_DISPLAY",
    "XAUTHORITY",
    "GPG_AGENT_INFO",
];

/// Credential directories and files, relative to the home, on every target (SB-T4-2). No source may lie inside one.
pub const SECRET_DIRS: &[&str] = &[
    ".ssh",
    ".gnupg",
    ".aws",
    ".azure",
    ".config/gcloud",
    ".config/gh",
    ".config/rclone",
    ".kube",
    ".docker",
    ".netrc",
    ".git-credentials",
    ".password-store",
    ".local/share/keyrings",
    ".mozilla",
    ".config/google-chrome",
    ".config/chromium",
    ".config/BraveSoftware",
    ".terraform.d",
    ".pki",
];

/// What a macOS home adds to [`SECRET_DIRS`], relative to the home. Chosen by the spec's [`Target`], not by the
/// host, so the macOS rules are tested on Linux too.
pub const SECRET_DIRS_MACOS: &[&str] = &[
    "Library/Keychains",
    "Library/Cookies",
    "Library/Mail",
    "Library/Messages",
    "Library/Safari",
    "Library/Accounts",
    "Library/Containers",
    "Library/Group Containers",
    "Library/Application Support",
];

/// System paths no source may be, contain or lie inside, whatever the caller's context says.
pub const SYSTEM_CLOSED: &[&str] = &[
    "/proc",
    "/sys",
    "/dev",
    "/run/user",
    "/tmp/.X11-unix",
    "/tmp/.ICE-unix",
];

/// The full (bwrap) tier's Landlock floor: a kernel without Landlock is refused (the user's ruling, 2026-10-21).
pub const LANDLOCK_FLOOR_FULL: u8 = 1;

/// The reduced tier's Landlock floor. Only ABI 9 controls connecting to pathname Unix sockets; without a mount
/// namespace, ABI 6–8 would leave the user's sockets reachable (the user's ruling on review B1, 2026-10-21).
pub const LANDLOCK_FLOOR_REDUCED: u8 = 9;

/// The full tier's Landlock floor under `Net::Shared` (review S3). The sandbox then shares the host's network
/// namespace, where abstract Unix sockets live (X11's `@/tmp/.X11-unix/X0`, a `unix:abstract=` D-Bus bus): only ABI 6
/// scopes them. `Net::Isolated` has a namespace of its own and keeps [`LANDLOCK_FLOOR_FULL`].
pub const LANDLOCK_FLOOR_SHARED_NET: u8 = 6;

/// The highest Landlock ABI a spec may require: the last one the `landlock` crate knows. A newer kernel runs the
/// ABI-9 rule set.
pub const LANDLOCK_ABI_MAX: u8 = 9;

/// What a sandboxed program may see and do.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Spec {
    /// Read-only, at the same path inside. One that does not exist is dropped by validation, not refused.
    #[serde(default)]
    pub read: Vec<PathBuf>,
    /// Read-write, at the same path inside.
    #[serde(default)]
    pub write: Vec<PathBuf>,
    /// Hidden inside: a file reads as empty, a directory as an empty one. One that does not exist is dropped.
    #[serde(default)]
    pub hide: Vec<PathBuf>,
    /// The Unix sockets the program may connect to. Each lies inside `run`'s source.
    #[serde(default)]
    pub sockets: Vec<PathBuf>,
    /// Binds whose inside path may differ from the source (only where there is a mount namespace).
    #[serde(default)]
    pub binds: Vec<Bind>,
    /// The program's home, bound with its own mode: usually `rw`; a home asked `ro` is bound read-only, never widened.
    pub home: Option<Bind>,
    /// The session dir: a direct child of one of the caller's run parents, holding the session's sockets. Always
    /// read-only (bwrap `--ro-bind-fd`): its mode must be `ro` (validation refuses `rw`). Its dest is the caller's
    /// choice under bwrap, and its source elsewhere.
    pub run: Option<Bind>,
    /// The program's whole environment, in order. It travels in the inner spec over a sealed memfd, never in argv.
    #[serde(default)]
    pub env: Vec<(String, String)>,
    /// The working directory, as a path inside.
    pub chdir: PathBuf,
    /// The network.
    pub net: Net,
    /// The temporary directory. Required for the reduced tier, which has no private `/tmp`.
    pub tmp: Option<PathBuf>,
    /// The layers the run requires.
    pub layers: Layers,
    /// TCP ports the program may connect to besides the relay's, under `Net::Isolated` (Landlock's port rule).
    #[serde(default)]
    pub extra_tcp_ports: Vec<u16>,
}

/// A path seen inside at `dest`, from `source` outside.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Bind {
    pub mode: Mode,
    pub source: PathBuf,
    pub dest: PathBuf,
}

/// A bind's access: `"ro"` or `"rw"`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Ro,
    Rw,
}

/// The network: `"shared"`, or `{"isolated": {"relay": [...], "mac_tcp_ports": [...]}}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum Net {
    /// The host's network (bwrap `--share-net`; Seatbelt allows any remote address).
    Shared,
    /// No network of its own. Linux: a new network namespace, and the relay forwards loopback ports inside to Unix
    /// sockets outside (`relay` must not be empty). macOS: only `localhost` on `mac_tcp_ports`.
    Isolated {
        #[serde(default)]
        relay: Vec<RelayPort>,
        #[serde(default)]
        mac_tcp_ports: Vec<u16>,
    },
}

/// A loopback port inside, forwarded to a Unix socket; `socket` is the socket's path inside.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RelayPort {
    pub port: u16,
    pub socket: PathBuf,
}

/// The layers a run requires beyond its backend. seccomp is not a field: it is always on, in both Linux tiers, and
/// no spec can turn it off (review S5).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Layers {
    /// The lowest Landlock ABI the run accepts; below it the run is refused before anything is exec'd. Validation
    /// keeps it between the target's floor ([`Target::landlock_floor`]) and [`LANDLOCK_ABI_MAX`].
    pub landlock_min_abi: u8,
}

impl Layers {
    /// The default for a target: its floor.
    pub const fn for_target(target: Target) -> Layers {
        Layers {
            landlock_min_abi: target.landlock_floor(),
        }
    }
}

/// The backend a spec is validated for. The rules differ: without a mount namespace (`LinuxReduced`, `Macos`) a
/// dest must equal its source.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    /// bubblewrap, then the inner helper: Landlock and seccomp.
    LinuxBwrap,
    /// The inner helper alone: Landlock ABI ≥ 9 and seccomp, no namespaces.
    LinuxReduced,
    /// Seatbelt.
    Macos,
}

impl Target {
    /// The lowest `layers.landlock_min_abi` a spec for this target may ask for. The floors are gleipnir's, not the
    /// caller's. macOS has no Landlock: 0.
    pub const fn landlock_floor(self) -> u8 {
        match self {
            Target::LinuxBwrap => LANDLOCK_FLOOR_FULL,
            Target::LinuxReduced => LANDLOCK_FLOOR_REDUCED,
            Target::Macos => 0,
        }
    }

    /// The secret dirs of a home for this target: [`SECRET_DIRS`], and on macOS [`SECRET_DIRS_MACOS`] too.
    pub fn secret_dirs(self) -> impl Iterator<Item = &'static str> {
        let mac: &'static [&'static str] = match self {
            Target::Macos => SECRET_DIRS_MACOS,
            Target::LinuxBwrap | Target::LinuxReduced => &[],
        };
        SECRET_DIRS.iter().chain(mac).copied()
    }
}

/// A spec that passed validation for one target. Opaque: only `validate::validate` makes one (tests:
/// [`ValidSpec::assume_valid`]). It is not `Deserialize` and has no mutable access, so nothing skips validation.
#[derive(Debug, Clone)]
pub struct ValidSpec {
    spec: Spec,
    target: Target,
}

impl ValidSpec {
    pub fn spec(&self) -> &Spec {
        &self.spec
    }

    pub fn target(&self) -> Target {
        self.target
    }

    /// Only `validate` can call this: no other module can make a [`Checked`].
    pub(crate) fn new(spec: Spec, target: Target, _checked: Checked) -> ValidSpec {
        ValidSpec { spec, target }
    }

    /// A `ValidSpec` without validation, for other modules' test fixtures.
    #[cfg(test)]
    pub(crate) fn assume_valid(spec: Spec, target: Target) -> ValidSpec {
        ValidSpec::new(spec, target, Checked::for_tests())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    /// A spec with every field set, in its JSON form.
    fn full() -> Value {
        json!({
            "read": ["/usr/share/doc"],
            "write": ["/work/task"],
            "hide": ["/work/task/.env"],
            "sockets": ["/rt/drgnx/s/S1/proxy.sock"],
            "binds": [{"mode": "ro", "source": "/work/other", "dest": "/mnt/other"}],
            "home": {"mode": "rw", "source": "/state/home-1", "dest": "/home/agent"},
            "run": {"mode": "ro", "source": "/rt/drgnx/s/S1", "dest": "/run/drgnx"},
            "env": [["PATH", "/usr/bin"], ["LANG", "C.UTF-8"]],
            "chdir": "/work/task",
            "net": {"isolated": {"relay": [{"port": 3128, "socket": "/run/drgnx/proxy.sock"}],
                                 "mac_tcp_ports": []}},
            "tmp": "/state/tmp-1",
            "layers": {"landlock_min_abi": 1},
            "extra_tcp_ports": [8080]
        })
    }

    fn decode(v: Value) -> Result<Spec, serde_json::Error> {
        serde_json::from_value(v)
    }

    /// `full()` with one change at a JSON pointer: `Some(v)` sets (or adds) it, `None` removes it.
    fn with(pointer: &str, value: Option<Value>) -> Value {
        let mut v = full();
        let (parent, key) = pointer.rsplit_once('/').unwrap();
        let obj = v.pointer_mut(parent).unwrap();
        match (obj, value) {
            (Value::Object(m), Some(x)) => {
                m.insert(key.to_owned(), x);
            }
            (Value::Object(m), None) => {
                m.remove(key);
            }
            (Value::Array(a), Some(x)) => a[key.parse::<usize>().unwrap()] = x,
            _ => panic!("bad pointer {pointer}"),
        }
        v
    }

    #[test]
    fn a_full_spec_round_trips_in_its_wire_form() {
        let spec = decode(full()).unwrap();
        assert_eq!(spec.binds[0].mode, Mode::Ro);
        assert_eq!(spec.home.as_ref().unwrap().mode, Mode::Rw);
        assert_eq!(
            spec.net,
            Net::Isolated {
                relay: vec![RelayPort {
                    port: 3128,
                    socket: "/run/drgnx/proxy.sock".into()
                }],
                mac_tcp_ports: vec![]
            }
        );
        assert_eq!(spec.env[1], ("LANG".to_owned(), "C.UTF-8".to_owned()));
        assert_eq!(serde_json::to_value(&spec).unwrap(), full());
        let shared = decode(with("/net", Some(json!("shared")))).unwrap();
        assert_eq!(shared.net, Net::Shared);
        assert_eq!(serde_json::to_value(&shared.net).unwrap(), json!("shared"));
    }

    /// Every unknown key, at every level, is an error: a misspelt `hide` must never become "nothing hidden", and
    /// seccomp cannot be switched off by a field the type does not have (review S5).
    #[test]
    fn unknown_fields_are_refused_at_every_level() {
        decode(full()).expect("the base row decodes, so each refusal below is the change's");
        let rows = [
            ("top level", with("/hidee", Some(json!(["/x"])))),
            ("bind", with("/binds/0/writable", Some(json!(true)))),
            ("home", with("/home/mode2", Some(json!("ro")))),
            ("run", with("/run/extra", Some(json!(1)))),
            (
                "relay port",
                with("/net/isolated/relay/0/host", Some(json!("x"))),
            ),
            (
                "isolated",
                with("/net/isolated/allow_all", Some(json!(true))),
            ),
            ("seccomp off", with("/layers/seccomp", Some(json!(false)))),
        ];
        for (name, v) in rows {
            let err = decode(v).expect_err(name);
            assert!(err.to_string().contains("unknown field"), "{name}: {err}");
        }
    }

    #[test]
    fn spellings_outside_the_wire_form_are_refused() {
        decode(full()).expect("the base row decodes, so each refusal below is the change's");
        let rows = [
            ("mode RO", with("/binds/0/mode", Some(json!("RO")))),
            (
                "mode readonly",
                with("/binds/0/mode", Some(json!("readonly"))),
            ),
            ("net bare isolated", with("/net", Some(json!("isolated")))),
            ("net Shared", with("/net", Some(json!("Shared")))),
            ("net two variants", with("/net/shared", Some(json!(null)))),
            (
                "abi 256",
                with("/layers/landlock_min_abi", Some(json!(256))),
            ),
            ("abi -1", with("/layers/landlock_min_abi", Some(json!(-1)))),
            ("port 65536", with("/extra_tcp_ports/0", Some(json!(65536)))),
            (
                "env pair of 3",
                with("/env/0", Some(json!(["A", "b", "c"]))),
            ),
            ("env not a string", with("/env/0", Some(json!(["A", 1])))),
        ];
        for (name, v) in rows {
            assert!(decode(v).is_err(), "{name} was accepted");
        }
    }

    #[test]
    fn chdir_net_and_layers_are_required_and_lists_default_empty() {
        decode(full()).expect("the base row decodes, so each refusal below is the change's");
        for key in ["chdir", "net", "layers"] {
            let err = decode(with(&format!("/{key}"), None)).expect_err(key);
            assert!(err.to_string().contains("missing field"), "{key}: {err}");
        }
        let minimal = decode(json!({
            "chdir": "/w", "net": {"isolated": {}}, "layers": {"landlock_min_abi": 9}
        }))
        .unwrap();
        assert!(minimal.read.is_empty() && minimal.write.is_empty() && minimal.hide.is_empty());
        assert!(minimal.sockets.is_empty() && minimal.binds.is_empty() && minimal.env.is_empty());
        assert!(minimal.extra_tcp_ports.is_empty());
        assert_eq!(minimal.home, None);
        assert_eq!(minimal.run, None);
        assert_eq!(minimal.tmp, None);
        assert_eq!(
            minimal.net,
            Net::Isolated {
                relay: vec![],
                mac_tcp_ports: vec![]
            }
        );
        let err = decode(json!({"chdir": "/w", "net": "shared", "layers": {}})).unwrap_err();
        assert!(err.to_string().contains("landlock_min_abi"), "{err}");
    }

    /// The user's rulings, 2026-10-21: full tier ≥ 1, reduced tier ≥ 9; the crate stops at 9.
    #[test]
    fn floors_are_the_users_rulings() {
        assert_eq!(Target::LinuxBwrap.landlock_floor(), 1);
        assert_eq!(Target::LinuxReduced.landlock_floor(), 9);
        assert_eq!(Target::Macos.landlock_floor(), 0);
        assert_eq!(LANDLOCK_ABI_MAX, 9);
        for t in [Target::LinuxBwrap, Target::LinuxReduced, Target::Macos] {
            assert_eq!(Layers::for_target(t).landlock_min_abi, t.landlock_floor());
            assert!(t.landlock_floor() <= LANDLOCK_ABI_MAX);
        }
    }

    #[test]
    fn the_helper_lies_under_a_reserved_dest() {
        assert!(
            RESERVED_DESTS
                .iter()
                .any(|r| HELPER_INSIDE.starts_with(&format!("{r}/")))
        );
    }

    /// The lists are the plan's, entry for entry; a change here is a change of the sandbox's rules.
    #[test]
    fn constant_lists_are_the_plans() {
        assert_eq!(
            BASE_ENV_DENY.join(" "),
            "SSH_AUTH_SOCK DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR DISPLAY WAYLAND_DISPLAY XAUTHORITY GPG_AGENT_INFO"
        );
        assert_eq!(
            SECRET_DIRS.join(" "),
            ".ssh .gnupg .aws .azure .config/gcloud .config/gh .config/rclone .kube .docker .netrc \
             .git-credentials .password-store .local/share/keyrings .mozilla .config/google-chrome \
             .config/chromium .config/BraveSoftware .terraform.d .pki"
        );
        assert_eq!(
            SECRET_DIRS_MACOS.join("|"),
            "Library/Keychains|Library/Cookies|Library/Mail|Library/Messages|Library/Safari|Library/Accounts|\
             Library/Containers|Library/Group Containers|Library/Application Support"
        );
        assert_eq!(
            SYSTEM_CLOSED.join(" "),
            "/proc /sys /dev /run/user /tmp/.X11-unix /tmp/.ICE-unix"
        );
        for d in SECRET_DIRS.iter().chain(SECRET_DIRS_MACOS) {
            assert!(!d.starts_with('/') && !d.ends_with('/'), "{d}");
            assert!(
                d.split('/').all(|c| !c.is_empty() && c != "." && c != ".."),
                "{d}"
            );
        }
    }

    #[test]
    fn secret_dirs_follow_the_target() {
        let linux: Vec<_> = Target::LinuxBwrap.secret_dirs().collect();
        assert_eq!(linux, SECRET_DIRS);
        assert_eq!(
            Target::LinuxReduced.secret_dirs().collect::<Vec<_>>(),
            linux
        );
        let mac: Vec<_> = Target::Macos.secret_dirs().collect();
        assert_eq!(mac.len(), SECRET_DIRS.len() + SECRET_DIRS_MACOS.len());
        assert!(mac.contains(&".ssh") && mac.contains(&"Library/Keychains"));
    }

    #[test]
    fn assume_valid_keeps_the_spec_and_the_target() {
        let spec = decode(full()).unwrap();
        let valid = ValidSpec::assume_valid(spec.clone(), Target::LinuxReduced);
        assert_eq!(valid.spec(), &spec);
        assert_eq!(valid.target(), Target::LinuxReduced);
    }
}
