//! The DeepSeek Harness personality (`dsh --profile acp`): `list, resume, close` only (no load, fork or modes).  Every
//! `tool_call` is kind `other` with its snake-case tool name as the title, and a permission request carries the tool
//! call's id only.  Its `--patch FILE` is read as DeepSeek Harness 0.2.2 reads an overlay, or it does not boot
//! ([`check`]); its tools then obey the overlay as the drgnx ask plugin would: a tool of a kind the inserted plugin's
//! `kinds: [...]` names asks, when the approval policy is `ask`; any other tool runs without asking.

use serde_json::{Value, json};

pub fn session_caps() -> Value {
    json!({"list": {}, "resume": {}, "close": {}})
}

/// The ask plugin's package (`packages/acp/acp-drgnx-ask/package.json`).
const ASK_PLUGIN: &str = "@deepseek-ai/dsh-acp-drgnx-ask";

/// What the overlay and the base bundle make of the session: the approval policy, the sandbox mode and the kinds the
/// ask plugin asks about (none: not inserted).
struct Overlay {
    policy: String,
    sandbox: String,
    kinds: Vec<String>,
}

/// ARGV's `--patch FILE`, when given.
fn patch_file(argv: &[String]) -> Option<&String> {
    let i = argv.iter().position(|a| a == "--patch")?;
    argv.get(i + 1)
}

/// The top-level items of the patch list TEXT, each its lines (the first without its `- `), as
/// `packages/boot/app-boot/src/index.ts:571-589` (`parsePatchList`) takes them: anything but a top-level YAML array
/// (`:580-582`), or an item that is not a mapping (`:583-587`), is refused.  Only the YAML the hub writes is read:
/// `- key: value` items with indented lines under them.
fn entries(text: &str) -> Result<Vec<Vec<&str>>, String> {
    let mut items: Vec<Vec<&str>> = Vec::new();
    for line in text.lines().map(str::trim_end) {
        let bare = line.trim_start();
        if bare.is_empty() || bare.starts_with('#') {
            continue;
        }
        if let Some(first) = line.strip_prefix("- ") {
            items.push(vec![first.trim()]);
        } else if let (true, Some(item)) = (line.starts_with(' '), items.last_mut()) {
            item.push(bare);
        } else {
            return Err("must be a top-level YAML array of loader patch entries".into());
        }
    }
    if items.is_empty() {
        return Err("must be a top-level YAML array of loader patch entries".into());
    }
    if let Some(i) = items.iter().position(|it| !it[0].contains(':')) {
        return Err(format!(
            "entry {} must be a mapping (a loader patch entry)",
            i + 1
        ));
    }
    Ok(items)
}

/// The overlay of ARGV over the base bundle.  Without patches the base bundle's rows decide: the sandbox mode is
/// `$DSH_PERMISSION_MODE`, else `workspace-write` (`packages/bundle/base/cordis.patch.yml:243-246`), and the policy
/// `never` under `danger-full-access`, else `ask` (`:259-262`).  A patch to the `sandbox-policy` or `approval` row
/// replaces its value; a patch to a row the bundle lacks is only a Loader warning, and changes nothing.  A file that
/// cannot be read or is not a patch list stops the boot (`index.ts:536-545`).
fn read(argv: &[String]) -> Result<Overlay, String> {
    let sandbox = std::env::var("DSH_PERMISSION_MODE").unwrap_or_else(|_| "workspace-write".into());
    let policy = if sandbox == "danger-full-access" {
        "never"
    } else {
        "ask"
    };
    let mut o = Overlay {
        policy: policy.into(),
        sandbox,
        kinds: Vec::new(),
    };
    let Some(file) = patch_file(argv) else {
        return Ok(o);
    };
    let text =
        std::fs::read_to_string(file).map_err(|e| format!("failed to read overlay {file}: {e}"))?;
    let value = |item: &[&str], key: &str| {
        item.iter()
            .find_map(|l| l.strip_prefix(key)?.strip_prefix(':'))
            .map(|v| v.trim().trim_matches('\'').to_owned())
    };
    for item in entries(&text).map_err(|e| format!("overlay {file} {e}"))? {
        match item[0] {
            "id: sandbox-policy" => o.sandbox = value(&item, "mode").unwrap_or(o.sandbox),
            "id: approval" => o.policy = value(&item, "policy").unwrap_or(o.policy),
            "insert:" if value(&item, "name").as_deref() == Some(ASK_PLUGIN) => {
                o.kinds = value(&item, "kinds")
                    .and_then(|k| Some(k.strip_prefix('[')?.strip_suffix(']')?.to_owned()))
                    .map(|k| {
                        k.split(',')
                            .map(|k| k.trim().to_owned())
                            .filter(|k| !k.is_empty())
                            .collect()
                    })
                    .unwrap_or_default();
            }
            _ => {}
        }
    }
    Ok(o)
}

/// Why DeepSeek Harness would not boot on ARGV's overlay, if it would not.
pub fn check(argv: &[String]) -> Result<(), String> {
    read(argv).map(drop)
}

/// What `session/new` logs for DeepSeek Harness: the policy, sandbox mode and asked kinds it runs with.
pub fn note(argv: &[String]) -> Value {
    match read(argv) {
        Ok(o) => json!({"policy": o.policy, "sandbox": o.sandbox, "kinds": o.kinds}),
        Err(e) => json!({"error": e}),
    }
}

/// DeepSeek Harness's tool for WHAT (`provider:read|grep|write|bash|web-fetch ARG`), its `tool_call` fields, and
/// whether it asks.
pub fn tool(argv: &[String], what: &str, arg: &str) -> Option<(&'static str, Value, bool)> {
    let (name, kind) = match what {
        "read" => ("read", "read"),
        "grep" => ("grep", "search"),
        "write" => ("write", "edit"),
        "bash" => ("bash", "execute"),
        "web-fetch" => ("web_fetch", "fetch"),
        _ => return None,
    };
    let asks = read(argv).is_ok_and(|o| o.policy == "ask" && o.kinds.iter().any(|k| k == kind));
    let fields = json!({"title": name, "kind": "other", "rawInput": {"arg": arg}});
    Some((name, fields, asks))
}
