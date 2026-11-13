//! Hot reload while paused (D8, Python first): the saved file's changed function bodies go into the stopped program.
//! DAP has no code-replace request, so this is per language; debugpy sessions get it through one `evaluate` of
//! `etc/debug-hot-reload.py` (its answer hex-encoded in a string, so no repr quoting reaches the hub), and the selected frame
//! restarts where the adapter can (`supportsRestartFrame`; else the change applies from the next call).

use serde_json::{Value, json};

use super::Debug;

/// The program run in the debuggee.
const PROGRAM: &str = include_str!("../../../../../etc/debug-hot-reload.py");

/// The adapter types that can take it.
const PYTHON: &[&str] = &["debugpy", "python"];

/// Session ID's program takes PATH's functions as saved: `{patched: [qualname], skipped: [{name, why}],
/// restarted}`. Refused while it runs and for adapters other than Python's.
pub async fn hot_reload(d: &Debug, id: &str, path: &str) -> Result<Value, String> {
    let adapter = d
        .adapter_of(id)
        .ok_or_else(|| format!("no debug session {id}"))?;
    if !PYTHON.contains(&adapter.as_str()) {
        return Err(
            "hot reload is for Python sessions (debugpy): this adapter has no way to replace code"
                .into(),
        );
    }
    let (h, caps) = d.handle_caps(id)?;
    let stop = d
        .stop_of(id)
        .ok_or("hot reload needs the program stopped")?;
    let expression = format!(
        "(lambda g: (exec(compile({program}, '<drgnx-hot-reload>', 'exec'), g), \
         __import__('json').dumps(g['OUT']).encode().hex())[1])({{'PATH': {path}}})",
        program = py_str(PROGRAM),
        path = py_str(path),
    );
    let b = h
        .request(
            "evaluate",
            json!({"expression": expression, "frameId": stop.frame, "context": "clipboard"}),
        )
        .await?;
    let answer = b.get("result").and_then(Value::as_str).unwrap_or_default();
    let mut out = decode(answer).ok_or_else(|| format!("hot reload failed: {answer}"))?;
    let restart = caps.get("supportsRestartFrame").and_then(Value::as_bool) == Some(true)
        && out["patched"].as_array().is_some_and(|p| !p.is_empty());
    if restart {
        h.request("restartFrame", json!({"frameId": stop.frame}))
            .await?;
    }
    out["restarted"] = json!(restart);
    Ok(out)
}

/// TEXT as a Python string literal: a JSON string is one (its escapes are Python's).
fn py_str(text: &str) -> String {
    Value::from(text).to_string()
}

/// The program's answer: the repr of a string of hex digits, the JSON it encodes.
fn decode(repr: &str) -> Option<Value> {
    let hex = repr.trim().trim_matches(|c| c == '\'' || c == '"');
    if hex.len() % 2 != 0 {
        return None;
    }
    let bytes: Option<Vec<u8>> = (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(hex.get(i..i + 2)?, 16).ok())
        .collect();
    serde_json::from_slice(&bytes?).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_answer_is_hex_json_in_a_repr_and_anything_else_is_none() {
        let v = json!({"patched": ["f"], "skipped": []});
        let hex: String = v.to_string().bytes().map(|b| format!("{b:02x}")).collect();
        assert_eq!(decode(&format!("'{hex}'")), Some(v));
        assert_eq!(decode("Traceback (most recent call last): ..."), None);
        assert_eq!(py_str("a'b\\c"), r#""a'b\\c""#);
    }
}
