//! The placeholders of an argv or an environment, expanded on the runner, where the paths are.
//!
//! `{src}` (the source), `{out}` (an artifact build's output folder), `{build}` (the build folder), `{art:NAME}` (an
//! artifact the job uses), `{cache:NAME}` (a named cache), `{input.NAME}` (an input), `{jobs}` (the job's parallelism),
//! `{deadline}` (epoch seconds), `{island}` (the timing island's CPUs), `{gate:NAME}` (an author's read-only view of the
//! gate's partition of a cache) and `{key:NAME}` (a key, in an environment only).
//!
//! - An unknown or unset placeholder is an error that names it; nothing expands to an empty string.
//! - `{{` and `}}` are a literal brace. A brace pair that is not a lowercase word (`{}`, `${HOME}`, `{1,2}`) is literal
//!   text and stays.
//! - **A key's value never gets here.** `{key:NAME}` is the whole value of an environment entry, and what comes back is
//!   the key's name and the variable it goes to ([`Expanded::keys`], the pairs `drgnx-key exec NAME=VAR` takes): the
//!   value is read by `drgnx-key` inside the container, so it is in no argv, stamp, evidence or log.

use std::collections::{BTreeMap, BTreeSet};

/// What the placeholders stand for on this runner (paths as the job sees them, inside its container).
#[derive(Clone, Debug, Default)]
pub struct Ctx {
    pub src: String,
    /// The artifact build's output folder; none outside a build.
    pub out: Option<String>,
    pub build: String,
    pub arts: BTreeMap<String, String>,
    pub caches: BTreeMap<String, String>,
    /// An author's job: the gate's partition of each cache, read-only (`{gate:NAME}`).
    pub gates: BTreeMap<String, String>,
    pub inputs: BTreeMap<String, String>,
    pub jobs: u32,
    pub deadline: u64,
    /// The timing island's CPUs; none: the job has no island.
    pub island: Option<String>,
    /// The names of the keys the job may read.
    pub keys: BTreeSet<String>,
}

/// An environment, expanded: the variables, and the keys that fill the rest `(key name, variable)`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Expanded {
    pub vars: Vec<(String, String)>,
    pub keys: Vec<(String, String)>,
}

/// Which placeholder a brace pair is.
enum Part<'a> {
    Text(String),
    Name(&'a str),
}

/// A brace pair's content is a placeholder word: lowercase letters and `-`, then optionally `:` or `.` and a name.
fn is_word(s: &str) -> bool {
    let (head, tail) = match s.find([':', '.']) {
        Some(i) => (&s[..i], Some(&s[i + 1..])),
        None => (s, None),
    };
    !head.is_empty()
        && head.bytes().all(|b| b.is_ascii_lowercase() || b == b'-')
        && tail.is_none_or(|t| !t.is_empty())
}

fn parts(s: &str) -> Vec<Part<'_>> {
    let mut out: Vec<Part<'_>> = vec![];
    let mut text = String::new();
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'{' if b.get(i + 1) == Some(&b'{') => {
                text.push('{');
                i += 2;
            }
            b'}' if b.get(i + 1) == Some(&b'}') => {
                text.push('}');
                i += 2;
            }
            b'{' => match s[i + 1..].find('}') {
                Some(n) if is_word(&s[i + 1..i + 1 + n]) => {
                    if !text.is_empty() {
                        out.push(Part::Text(std::mem::take(&mut text)));
                    }
                    out.push(Part::Name(&s[i + 1..i + 1 + n]));
                    i += n + 2;
                }
                _ => {
                    text.push('{');
                    i += 1;
                }
            },
            _ => {
                let ch = s[i..].chars().next().unwrap_or_default();
                text.push(ch);
                i += ch.len_utf8();
            }
        }
    }
    if !text.is_empty() {
        out.push(Part::Text(text));
    }
    out
}

fn lookup(name: &str, ctx: &Ctx) -> Result<String, String> {
    let set = |v: &str, what: &str| {
        if v.is_empty() {
            Err(format!(
                "the placeholder {{{name}}} is not set here ({what})"
            ))
        } else {
            Ok(v.to_string())
        }
    };
    let named = |m: &BTreeMap<String, String>, n: &str, what: &str| {
        m.get(n)
            .ok_or_else(|| format!("the placeholder {{{name}}} names no {what} of this job"))
            .and_then(|v| set(v, what))
    };
    match name {
        "src" => set(&ctx.src, "the source"),
        "build" => set(&ctx.build, "the build folder"),
        "out" => set(
            ctx.out.as_deref().unwrap_or_default(),
            "only an artifact build has an output",
        ),
        "island" => set(
            ctx.island.as_deref().unwrap_or_default(),
            "the job has no island",
        ),
        "jobs" if ctx.jobs > 0 => Ok(ctx.jobs.to_string()),
        "jobs" => Err("the placeholder {jobs} is not set here (no parallelism was granted)".into()),
        "deadline" if ctx.deadline > 0 => Ok(ctx.deadline.to_string()),
        "deadline" => {
            Err("the placeholder {deadline} is not set here (the job has no deadline)".into())
        }
        _ => match name.split_once([':', '.']) {
            Some(("art", n)) if name.as_bytes()[3] == b':' => named(&ctx.arts, n, "artifact"),
            Some(("cache", n)) if name.as_bytes()[5] == b':' => named(&ctx.caches, n, "cache"),
            Some(("gate", n)) if name.as_bytes()[4] == b':' => {
                named(&ctx.gates, n, "gate partition")
            }
            Some(("input", n)) if name.as_bytes()[5] == b'.' => named(&ctx.inputs, n, "input"),
            Some(("key", _)) => Err(format!(
                "the placeholder {{{name}}} is a key: it is allowed only as the whole value of an environment variable"
            )),
            _ => Err(format!("the placeholder {{{name}}} is unknown")),
        },
    }
}

/// One string with its placeholders expanded.
fn expand_one(s: &str, ctx: &Ctx) -> Result<String, String> {
    let mut out = String::new();
    for p in parts(s) {
        match p {
            Part::Text(t) => out.push_str(&t),
            Part::Name(n) => out.push_str(&lookup(n, ctx)?),
        }
    }
    Ok(out)
}

/// ARGV with its placeholders expanded. A key placeholder is refused: a key reaches a job only through its environment.
pub fn expand(argv: &[String], ctx: &Ctx) -> villa::Result<Vec<String>> {
    argv.iter()
        .map(|a| {
            let e = expand_one(a, ctx)?;
            if e.is_empty() && !a.is_empty() {
                return Err(format!("{a:?} expands to an empty string"));
            }
            Ok(e)
        })
        .collect::<Result<Vec<_>, String>>()
        .map_err(villa::Error::invalid)
}

/// ENV (`(variable, value)`) with its placeholders expanded; a value that is exactly `{key:NAME}` becomes the key `NAME`
/// for that variable.
pub fn expand_env(env: &[(String, String)], ctx: &Ctx) -> villa::Result<Expanded> {
    expand_env_text(env, ctx).map_err(villa::Error::invalid)
}

fn expand_env_text(env: &[(String, String)], ctx: &Ctx) -> Result<Expanded, String> {
    let mut out = Expanded::default();
    for (var, value) in env {
        let ps = parts(value);
        let keyed: Vec<&&str> = ps
            .iter()
            .filter_map(|p| match p {
                Part::Name(n) if n.starts_with("key:") => Some(n),
                _ => None,
            })
            .collect();
        match (keyed.as_slice(), ps.as_slice()) {
            ([], _) => {
                let v = expand_one(value, ctx)?;
                if v.is_empty() && !value.is_empty() {
                    return Err(format!("{var}={value:?} expands to an empty string"));
                }
                out.vars.push((var.clone(), v));
            }
            ([_], [Part::Name(n)]) => {
                let name = &n["key:".len()..];
                if !ctx.keys.contains(name) {
                    return Err(format!("the key {name:?} is not one this job may read"));
                }
                out.keys.push((name.to_string(), var.clone()));
            }
            _ => {
                return Err(format!(
                    "{var}: a key placeholder is the whole value of a variable, nothing around it"
                ));
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx() -> Ctx {
        Ctx {
            src: "/work".into(),
            out: Some("/out".into()),
            build: "/target".into(),
            arts: [("hub-bin".to_string(), "/art/hub-bin".to_string())].into(),
            caches: [("ccache".to_string(), "/cache/ccache".to_string())].into(),
            gates: [("ccache".to_string(), "/cache-gate/ccache".to_string())].into(),
            inputs: [("nidhogg".to_string(), "/in/nidhogg".to_string())].into(),
            jobs: 6,
            deadline: 1_700_000_000,
            island: None,
            keys: ["T".to_string()].into(),
        }
    }

    fn v(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn every_placeholder_expands_where_it_stands() {
        let c = Ctx {
            island: Some("0-3".into()),
            ..ctx()
        };
        let got = expand(
            &v(&[
                "make",
                "-C{src}",
                "O={build}",
                "-j{jobs}",
                "{art:hub-bin}/bin/hub",
                "--cache={cache:ccache}",
                "--secondary={gate:ccache}",
                "--in={input.nidhogg}",
                "--until={deadline}",
                "--cpus={island}",
                "--out={out}",
            ]),
            &c,
        )
        .unwrap();
        assert_eq!(
            got,
            v(&[
                "make",
                "-C/work",
                "O=/target",
                "-j6",
                "/art/hub-bin/bin/hub",
                "--cache=/cache/ccache",
                "--secondary=/cache-gate/ccache",
                "--in=/in/nidhogg",
                "--until=1700000000",
                "--cpus=0-3",
                "--out=/out",
            ])
        );
    }

    #[test]
    fn an_unknown_placeholder_is_refused_by_name() {
        let e = expand(&v(&["{nope}"]), &ctx())
            .unwrap_err()
            .message()
            .to_string();
        assert!(e.contains("{nope}"), "{e}");
        let e = expand(&v(&["{art:missing}"]), &ctx())
            .unwrap_err()
            .message()
            .to_string();
        assert!(e.contains("{art:missing}"), "{e}");
        // an unset one is refused too, and nothing expands to an empty string
        let e = expand(&v(&["{island}"]), &ctx())
            .unwrap_err()
            .message()
            .to_string();
        assert!(e.contains("{island}"), "{e}");
        let c = Ctx { out: None, ..ctx() };
        assert!(
            expand(&v(&["{out}"]), &c)
                .unwrap_err()
                .message()
                .contains("{out}")
        );
        let c = Ctx {
            src: String::new(),
            ..ctx()
        };
        assert!(expand(&v(&["{src}"]), &c).is_err());
    }

    #[test]
    fn braces_that_are_not_placeholders_stay() {
        let got = expand(&v(&["${HOME}", "{}", "a{1,2}b", "{{src}}", "x}}"]), &ctx()).unwrap();
        assert_eq!(got, v(&["${HOME}", "{}", "a{1,2}b", "{src}", "x}"]));
    }

    #[test]
    fn a_key_placeholder_outside_env_is_refused() {
        let e = expand(&v(&["--token={key:T}"]), &ctx())
            .unwrap_err()
            .message()
            .to_string();
        assert!(e.contains("{key:T}") && e.contains("environment"), "{e}");
        // in an environment it is the whole value, and only a key the job may read
        let env = vec![
            ("TOKEN".to_string(), "{key:T}".to_string()),
            ("SRC".to_string(), "{src}".to_string()),
        ];
        let got = expand_env(&env, &ctx()).unwrap();
        assert_eq!(got.vars, [("SRC".to_string(), "/work".to_string())]);
        assert_eq!(got.keys, [("T".to_string(), "TOKEN".to_string())]);
        for bad in ["Bearer {key:T}", "{key:T}{key:T}", "{key:U}"] {
            let env = vec![("TOKEN".to_string(), bad.to_string())];
            assert!(expand_env(&env, &ctx()).is_err(), "{bad}");
        }
    }

    #[test]
    fn a_key_value_never_reaches_the_expansion() {
        // the expansion holds the key's name and its variable, never a value: there is no value in the context at all
        let env = vec![("TOKEN".to_string(), "{key:T}".to_string())];
        let got = expand_env(&env, &ctx()).unwrap();
        let text = format!("{got:?}");
        assert!(
            text.contains("\"T\"") && text.contains("\"TOKEN\""),
            "{text}"
        );
        assert!(got.vars.is_empty());
    }
}
