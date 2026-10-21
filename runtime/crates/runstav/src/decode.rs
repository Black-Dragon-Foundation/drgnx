//! Typed decode of a method's params: unknown keys are dropped and listed, a failure says where it is.

use crate::wire::{Error, ErrorCode};
use serde::de::DeserializeOwned;
use serde_json::Value;

/// `v` as a `T`, and the dotted paths of the keys `T` has no field for (`env[0].x`).  A value that does not fit is
/// `invalid-params` with the path of the part that did not (none when it is the top).
pub fn typed<T: DeserializeOwned>(v: &Value) -> Result<(T, Vec<String>), Error> {
    let mut ignored = Vec::new();
    let mut note = |p: serde_ignored::Path| {
        let mut s = String::new();
        dotted(&p, &mut s);
        ignored.push(s);
    };
    let de = serde_ignored::Deserializer::new(v, &mut note);
    match serde_path_to_error::deserialize(de) {
        Ok(t) => Ok((t, ignored)),
        Err(e) => Err(Error {
            code: ErrorCode::InvalidParams,
            message: e.inner().to_string(),
            path: e.path().iter().next().map(|_| e.path().to_string()),
        }),
    }
}

/// serde_ignored's path in the form serde_path_to_error writes (`env[0].x`, not `env.0.x`); `Some` and newtypes
/// add nothing.
fn dotted(p: &serde_ignored::Path, out: &mut String) {
    use serde_ignored::Path;
    match p {
        Path::Root => {}
        Path::Seq { parent, index } => {
            dotted(parent, out);
            out.push_str(&format!("[{index}]"));
        }
        Path::Map { parent, key } => {
            dotted(parent, out);
            if !out.is_empty() {
                out.push('.');
            }
            out.push_str(key);
        }
        Path::Some { parent }
        | Path::NewtypeStruct { parent }
        | Path::NewtypeVariant { parent } => dotted(parent, out),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    use serde_json::json;

    #[derive(Debug, Deserialize)]
    #[allow(dead_code)]
    struct Var {
        name: String,
    }

    #[derive(Debug, Deserialize)]
    #[allow(dead_code)]
    struct Params {
        cwd: Option<String>,
        env: Vec<Var>,
        #[serde(default)]
        opt: Option<Inner>,
    }

    #[derive(Debug, Deserialize)]
    #[allow(dead_code)]
    struct Inner {
        n: u32,
    }

    #[test]
    fn unknown_keys_listed_with_paths() {
        let (p, ignored) = typed::<Params>(&json!({
            "cwd": "/w", "extra": 1,
            "env": [{"name": "A", "x": true}, {"name": "B"}, {"name": "C", "y": [1], "z": null}],
            "opt": {"n": 3, "deep": {"q": 1}}
        }))
        .unwrap();
        assert_eq!(p.env.len(), 3);
        let mut ignored = ignored;
        ignored.sort(); // the order of a JSON object's keys is serde_json's
        assert_eq!(
            ignored,
            vec!["env[0].x", "env[2].y", "env[2].z", "extra", "opt.deep"]
        );
        let (_, none) = typed::<Params>(&json!({"env": []})).unwrap();
        assert!(none.is_empty());
    }

    #[test]
    fn wrong_type_has_its_path() {
        let e = typed::<Params>(&json!({"env": [{"name": "A"}, {"name": 7}]})).unwrap_err();
        assert_eq!(e.code, ErrorCode::InvalidParams);
        assert_eq!(e.path.as_deref(), Some("env[1].name"));
        assert!(e.message.contains("invalid type"), "{e:?}");
        let e = typed::<Params>(&json!({"env": [], "opt": {"n": -1}})).unwrap_err();
        assert_eq!(e.path.as_deref(), Some("opt.n"));
        // a field missing at the top has no path below it
        let e = typed::<Params>(&json!({"cwd": "/w"})).unwrap_err();
        assert_eq!(e.path, None);
        assert!(e.message.contains("missing field `env`"), "{e:?}");
        let e = typed::<Params>(&json!([1])).unwrap_err();
        assert_eq!(e.code, ErrorCode::InvalidParams);
    }
}
