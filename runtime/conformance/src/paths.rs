//! Where a hub's data dir and socket are: the same rule as Lisp's `drgnx-paths-dir 'data` and `drgnx-hub-socket`
//! (`core/drgnx-paths.el`, `core/drgnx-hub.el`), oddities of Emacs's `expand-file-name` kept.  The shared fixture
//! `test/fixtures/hub-socket-cases.json` pins both sides.  A relative env value is out of scope (a DEFERRED row).

use sha1::{Digest, Sha1};
use std::collections::BTreeMap;
use std::path::PathBuf;

/// The environment a hub sees (only these variables matter to the rule) and the uid it runs as.
#[derive(Clone, Debug, Default)]
pub struct Env {
    pub vars: BTreeMap<String, String>,
    pub uid: u32,
}

// `new` and `process` are used by the tests (the harness test includes this file for its scripted hub)
#[allow(dead_code)]
impl Env {
    pub fn new(vars: &[(&str, &str)], uid: u32) -> Env {
        Env {
            vars: vars
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            uid,
        }
    }

    /// This process's own environment.
    pub fn process() -> Env {
        Env {
            vars: std::env::vars_os()
                .map(|(k, v)| {
                    (
                        k.to_string_lossy().into_owned(),
                        v.to_string_lossy().into_owned(),
                    )
                })
                .collect(),
            uid: unsafe { libc::geteuid() },
        }
    }

    fn get(&self, name: &str) -> Option<&str> {
        self.vars.get(name).map(String::as_str)
    }

    /// `drgnx-paths-env-dir`: the value when it begins with "/", else nothing (unset, empty, relative and "~/..." all mean the default).
    fn abs(&self, name: &str) -> Option<&str> {
        self.get(name).filter(|v| v.starts_with('/'))
    }
}

/// `expand-file-name` of an absolute name, as Emacs's C code canonicalises it (fileio.c): "/./" and "/x/../" go,
/// repeated "/" collapse except a leading "//", three or more leading "/" become one, and ".." at the root
/// stays when something follows it ("/../b") and goes when it is last ("/.." is kept, "/../.." is "/").
pub fn normalize(name: &str) -> String {
    let mut nm = name.as_bytes();
    if nm.starts_with(b"///") {
        while nm.starts_with(b"//") {
            nm = &nm[1..];
        }
    }
    let at = |i: usize| nm.get(i).copied().unwrap_or(0);
    let mut out: Vec<u8> = Vec::with_capacity(nm.len());
    let mut p = 0;
    while p < nm.len() {
        if nm[p] != b'/' {
            out.push(nm[p]);
            p += 1;
        } else if at(p + 1) == b'.' && (at(p + 2) == b'/' || p + 2 >= nm.len()) {
            // "/." : the whole name "/." keeps its "/", otherwise the "/." goes
            if out.is_empty() && p + 2 >= nm.len() {
                out.push(b'/');
            }
            p += 2;
        } else if at(p + 1) == b'.'
            && at(p + 2) == b'.'
            && !out.is_empty()
            && (at(p + 3) == b'/' || p + 3 >= nm.len())
        {
            // "/..": drop the last component, and its "/"
            while let Some(c) = out.pop() {
                if c == b'/' {
                    break;
                }
            }
            // keep an initial "/" only when this is the whole name
            if out.is_empty() && p + 3 >= nm.len() {
                out.push(b'/');
            }
            p += 3;
        } else if p > 0 && at(p + 1) == b'/' {
            p += 1; // collapse repeated "/" (a leading "//" stays: p == 0 copies the first)
        } else {
            out.push(b'/');
            p += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn as_directory(s: &str) -> String {
    if s.ends_with('/') {
        s.to_string()
    } else {
        format!("{s}/")
    }
}

/// `(expand-file-name NAME DIR)` for a relative NAME and an absolute DIR (not itself canonicalised first, as in Emacs).
fn expand_in(name: &str, dir: &str) -> String {
    normalize(&format!("{}{}", as_directory(dir), name))
}

/// `(expand-file-name "~/REST")` with the home from HOME.
fn in_home(env: &Env, rest: &str) -> String {
    expand_in(rest, env.get("HOME").unwrap_or("/"))
}

/// `(drgnx-paths-dir KIND)` for the kinds a hub needs: `own` is drgnx's variable, `xdg` the XDG one, `base` under "~".
fn dir(env: &Env, own: Option<&str>, xdg: &str, base: &str) -> String {
    let d = match own.and_then(|o| env.abs(o)) {
        Some(v) => normalize(v),
        None => match env.abs(xdg) {
            Some(x) => expand_in("drgnx", x),
            None => expand_in("drgnx", &in_home(env, base)),
        },
    };
    as_directory(&d)
}

/// `(drgnx-data-dir)`: a name ending in "/".
pub fn data_dir(env: &Env) -> PathBuf {
    PathBuf::from(dir(
        env,
        Some("DRGNX_DATA_DIR"),
        "XDG_DATA_HOME",
        ".local/share",
    ))
}

fn state_dir(env: &Env) -> String {
    dir(env, None, "XDG_STATE_HOME", ".local/state")
}

/// Emacs's `temporary-file-directory` on Linux and macOS: the first of TMPDIR, TMP, TEMP that is set, else /tmp (a relative one is out of scope).
fn temporary_file_directory(env: &Env) -> String {
    let t = ["TMPDIR", "TMP", "TEMP"]
        .iter()
        .find_map(|n| env.get(n))
        .unwrap_or("/tmp");
    if t.is_empty() {
        "./".to_string()
    } else {
        as_directory(&normalize_if_abs(t))
    }
}

fn normalize_if_abs(s: &str) -> String {
    if s.starts_with('/') {
        normalize(s)
    } else {
        s.to_string()
    }
}

/// `(drgnx-hub-socket)`: `$XDG_RUNTIME_DIR/drgnx/hub-HASH.sock` when that is a directory, else `<state>/hub/hub-HASH.sock`;
/// over 103 bytes, `<tmp>/drgnx-hub-UID/hub-HASH.sock`.  HASH is sha1 of the data dir (with its trailing "/") cut to 8 hex.
pub fn socket_path(env: &Env) -> PathBuf {
    let data = data_dir(env);
    let hex: String = Sha1::digest(data.to_string_lossy().as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let name = format!("hub-{}.sock", &hex[..8]);
    let path = match env
        .abs("XDG_RUNTIME_DIR")
        .filter(|r| std::fs::metadata(r).is_ok_and(|m| m.is_dir()))
    {
        Some(run) => expand_in(&name, &expand_in("drgnx", run)),
        None => expand_in(&name, &expand_in("hub", &state_dir(env))),
    };
    if path.len() <= 103 {
        return PathBuf::from(path);
    }
    let private = expand_in(
        &format!("drgnx-hub-{}", env.uid),
        &temporary_file_directory(env),
    );
    PathBuf::from(expand_in(&name, &private))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> serde_json::Value {
        let file = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../test/fixtures/hub-socket-cases.json"
        );
        serde_json::from_str(&std::fs::read_to_string(file).expect("fixture file"))
            .expect("fixture JSON")
    }

    #[test]
    fn socket_cases_fixture() {
        let cases = fixture();
        let cases = cases.as_array().expect("an array");
        assert!(cases.len() >= 13, "the fixture needs at least 13 cases");
        for c in cases {
            let vars: Vec<(&str, &str)> = c["env"]
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, v)| (k.as_str(), v.as_str().unwrap()))
                .collect();
            let env = Env::new(&vars, 4242);
            assert_eq!(
                data_dir(&env).to_str().unwrap(),
                c["data_dir"].as_str().unwrap(),
                "data_dir of {}",
                c["env"]
            );
            let want = c["socket"].as_str().unwrap().replace("$UID", "4242");
            assert_eq!(
                socket_path(&env).to_str().unwrap(),
                want,
                "socket of {}",
                c["env"]
            );
        }
    }

    #[test]
    fn emacs_oddities_are_kept() {
        assert_eq!(normalize("/a/../../b"), "/../b");
        assert_eq!(normalize("//a"), "//a");
        assert_eq!(normalize("///a"), "/a");
        assert_eq!(normalize("/.."), "/..");
        assert_eq!(normalize("/../.."), "/");
        assert_eq!(normalize("//a/.."), "/");
        assert_eq!(normalize("/a/b//"), "/a/b/");
    }
}
