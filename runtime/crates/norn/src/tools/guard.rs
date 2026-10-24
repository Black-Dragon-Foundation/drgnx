//! The guard, the report rate limit and the text rules for what an agent sends (Task 7; `core/drgnx-coord-mcp.el`).
//!
//! - **The guard** (`drgnx-coord-mcp--guard`): every tool refuses an argument that names an identity
//!   ([`IDENTITY_ARGS`]), and every call of a caller whose identity is the user ([`Identity::check`]).  The tools'
//!   schemas leave those names out, so `mimir`'s typed check would refuse them as unknown keys; the guard is the
//!   second layer, run in [`Tool::check`] before the typed check and again in [`Tool::call`] with the Lisp text.
//!   Every coordination tool is a [`CoordTool`] wrapped by [`guarded`], so no tool can skip it.
//! - **The report limit** (`drgnx-coord-mcp--reporting`, `--held-report`, `--tell-held`): [`REPORT_RATE`] reports a
//!   minute per identity; more are held (nothing written) and a `rate` card tells the user, at most once an hour.
//! - **Text** (`drgnx-coord-mcp--line`, `--text-cut`): [`line`] and [`text_cut`].

use std::collections::{HashMap, VecDeque};

use mimir::{ArgsError, BoxFuture, Tool, ToolResult, typed};
use schemars::JsonSchema;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use super::{Coord, Ctx, Identity};
use crate::write::cards::{NewCard, card_create};
use crate::write::meta::{get_text, put_text};
use urdr::graph::{Class, TxMeta};

/// The arguments that would name who calls (`drgnx-coord-mcp--identity-args`).
pub const IDENTITY_ARGS: [&str; 5] = ["agent", "from", "sender", "as", "identity"];

/// The first identity name among ARGS' keys (present even with a null value, as `plist-member` sees it).
pub fn identity_arg(args: &Value) -> Option<&'static str> {
    let keys = args.as_object()?;
    IDENTITY_ARGS.into_iter().find(|k| keys.contains_key(*k))
}

/// The guard's refusal of ARGS for WHO, with the Lisp text.
pub fn refuse_identity_args(args: &Value, who: &Identity) -> Result<(), String> {
    match identity_arg(args) {
        Some(k) => Err(format!(
            "No tool takes `{k}': you are {}, from the process that started this server",
            who.id().unwrap_or("nobody (this server only reads)")
        )),
        None => Ok(()),
    }
}

/// A coordination tool's body: its typed arguments and what it does with them.  [`guarded`] makes it a `mimir`
/// tool.
pub trait CoordTool: Send + Sync + 'static {
    type Args: DeserializeOwned + JsonSchema + Send + 'static;
    /// The Lisp tool's name.
    const NAME: &'static str;
    /// The Lisp tool's description.
    const DESCRIPTION: &'static str;
    /// The tool's answer as text (JSON, or the Lisp's plain text), or its error's text.
    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: Self::Args,
    ) -> BoxFuture<'a, Result<String, String>>;
}

struct Guarded<T>(T);

/// TOOL behind the guard, as a `mimir` tool of the coordination server.
pub fn guarded<T: CoordTool>(tool: T) -> Box<dyn Tool<Ctx>> {
    Box::new(Guarded(tool))
}

/// The text of the check's refusal of an identity name (the call's refusal is [`refuse_identity_args`]'s).
pub const NO_IDENTITY_ARG: &str = "tools never take an identity";

/// What `tools/list` carries once per tool, trimmed without losing a meaning: the root's own description (the tool's
/// description says it), a scalar type's description (it restates the `pattern` / `maxLength` next to it) and an empty
/// `default` list (an absent list is empty).  Only the advertised schema changes; [`Tool::check`] uses the type.
fn compact_schema(schema: &mut Value) {
    fn scalar_with_limits(def: &Value) -> bool {
        def.get("type").is_some_and(Value::is_string)
            && (def.get("pattern").is_some() || def.get("maxLength").is_some())
    }
    fn drop_empty_defaults(v: &mut Value) {
        match v {
            Value::Object(m) => {
                if m.get("default")
                    .is_some_and(|d| d.as_array().is_some_and(Vec::is_empty))
                {
                    m.remove("default");
                }
                m.values_mut().for_each(drop_empty_defaults);
            }
            Value::Array(a) => a.iter_mut().for_each(drop_empty_defaults),
            _ => {}
        }
    }
    if let Some(root) = schema.as_object_mut() {
        root.remove("description");
        if let Some(Value::Object(defs)) = root.get_mut("$defs") {
            for def in defs.values_mut() {
                if scalar_with_limits(def) {
                    def.as_object_mut().map(|d| d.remove("description"));
                }
            }
        }
    }
    drop_empty_defaults(schema);
}

impl<T: CoordTool> Tool<Ctx> for Guarded<T> {
    fn name(&self) -> &'static str {
        T::NAME
    }

    fn description(&self) -> &'static str {
        T::DESCRIPTION
    }

    fn input_schema(&self) -> Value {
        let mut schema = typed::<T::Args>().schema();
        compact_schema(&mut schema);
        schema
    }

    fn check(&self, args: &Value) -> Result<(), ArgsError> {
        if let Some(k) = identity_arg(args) {
            return Err(ArgsError {
                path: k.into(),
                message: NO_IDENTITY_ARG.into(),
            });
        }
        typed::<T::Args>().check(args)
    }

    fn call<'a>(&'a self, ctx: &'a Ctx, args: Value) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            match guarded_call(&self.0, &ctx.0, &ctx.1, args).await {
                Ok(text) => ToolResult::Ok {
                    text,
                    structured: None,
                },
                Err(text) => ToolResult::Err(text),
            }
        })
    }
}

/// The guard, then the tool: the identity first, then the arguments (`drgnx-coord-mcp--guard`'s order).
async fn guarded_call<T: CoordTool>(
    tool: &T,
    coord: &Coord,
    who: &Identity,
    args: Value,
) -> Result<String, String> {
    who.check()?;
    refuse_identity_args(&args, who)?;
    let args = typed::<T::Args>()
        .decode(&args)
        .map_err(|e| e.to_string())?;
    tool.run(coord, who, args).await
}

// ---- the report limit ----

/// Reports one identity may make a minute (`drgnx-coord-report-rate`).
pub const REPORT_RATE: usize = 20;
/// The user is told of held reports at most this often per identity, in seconds.
const TELL_EVERY: f64 = 3600.0;

/// The report limit's memory (`drgnx-coord-mcp--reports`, `--told`), per identity.  One per hub, so it counts an
/// agent's reports across its connections; a hub started again starts counting again, and the store's
/// `rate-told:ID` keeps the card to one an hour.
#[derive(Default)]
pub struct Rates {
    /// When each identity's recent reports came, newest first.
    reports: HashMap<String, VecDeque<f64>>,
    /// When the user was last told an identity's reports were held.
    told: HashMap<String, f64>,
}

/// The answer of a held report.
fn held_text() -> String {
    format!(
        "HELD: more than {REPORT_RATE} reports a minute ({REPORT_RATE} a minute is the limit) — this one was not recorded.  Report less often: one report_edit names many paths."
    )
}

/// `string-to-number`: text that is not a number reads as 0.
fn lisp_number(s: &str) -> f64 {
    s.trim().parse().unwrap_or(0.0)
}

impl Coord {
    /// `None` when ME may report now (the report is counted); else the answer of a held report, nothing written
    /// (`drgnx-coord-mcp--held-report`).  JOB is the job a `rate` card belongs to.
    pub async fn held_report(&self, me: &str, job: Option<&str>) -> Option<String> {
        let now = self.now();
        let tell = {
            let mut rates = self.rates.lock().unwrap();
            let recent = rates.reports.entry(me.to_owned()).or_default();
            let keep = recent.iter().take_while(|&&at| at > now - 60.0).count();
            recent.truncate(keep);
            if recent.len() < REPORT_RATE {
                recent.push_front(now);
                return None;
            }
            match rates.told.get(me) {
                Some(&told) if now - told < TELL_EVERY => false,
                _ => {
                    rates.told.insert(me.to_owned(), now);
                    true
                }
            }
        };
        if tell {
            self.tell_held(me, job, now).await;
        }
        Some(held_text())
    }

    /// Tell the user (a `rate` card) that ME's reports are held, unless the store says it was told within the hour
    /// (`drgnx-coord-mcp--tell-held`).  Best effort: a failed write tells nobody and fails nothing.
    async fn tell_held(&self, me: &str, job: Option<&str>, now: f64) {
        let (who, job) = (me.to_owned(), job.map(str::to_owned));
        // the card is the hub's note to the user, not the agent's own write
        let meta = TxMeta::new("hub", Class::System, "mcp:rate-card");
        let told = self
            .db
            .write(meta, move |tx| {
                let key = format!("rate-told:{who}");
                let stamp = get_text(tx.sql(), &key)?;
                if let Some(last) = stamp.as_deref().map(lisp_number)
                    && now - last < TELL_EVERY
                {
                    return Ok(Some(last));
                }
                put_text(tx, &key, &now.to_string())?;
                card_create(
                    tx,
                    NewCard {
                        job,
                        task: None,
                        kind: Some("rate".into()),
                        title: Some(format!(
                            "{who} reports too fast: more than {REPORT_RATE} a minute are held, not recorded"
                        )),
                        data: Some(json!({"agent": who, "rate": REPORT_RATE})),
                    },
                    now,
                )?;
                Ok(None)
            })
            .await;
        match told {
            Ok(Some(last)) => {
                self.rates.lock().unwrap().told.insert(me.to_owned(), last);
            }
            Ok(None) => self.hub.notify(),
            Err(e) => tracing::debug!("the rate card for {me} was not written: {e}"),
        }
    }
}

// ---- text ----

fn is_control(c: char) -> bool {
    runstav::text::CONTROL.iter().any(|r| r.contains(&c))
}

/// `string-trim`'s default: spaces, tabs, newlines and returns at both ends.
pub fn lisp_trim(s: &str) -> &str {
    s.trim_matches([' ', '\t', '\n', '\r'])
}

/// TEXT as one line of at most MAX characters (`drgnx-coord-mcp--line`): each run of control characters (newline
/// and tab among them) one space, trimmed, cut with no `…`; `None` when absent or blank.  For names (80), branches,
/// plans, commands, options and task labels (200).
pub fn line(text: Option<&str>, max: usize) -> Option<String> {
    let text = text?;
    let mut out = String::with_capacity(text.len());
    let mut run = false;
    for c in text.chars() {
        if is_control(c) {
            if !run {
                out.push(' ');
            }
            run = true;
        } else {
            out.push(c);
            run = false;
        }
    }
    let line = lisp_trim(&out);
    (!line.is_empty()).then(|| line.chars().take(max).collect())
}

/// The longest question or message text an agent sends, in characters (`drgnx-coord-mcp--text-max`).
pub const TEXT_MAX: usize = 2000;

/// TEXT (WHAT names it in the error) cleaned for the user to read and how many characters were cut off
/// (`drgnx-coord-mcp--text-cut`): control characters other than newline and tab become spaces, trimmed, at most
/// [`TEXT_MAX`] characters.  An error when it is absent or blank.
pub fn text_cut(text: Option<&str>, what: &str) -> Result<(String, usize), String> {
    let clean: String = text
        .unwrap_or("")
        .chars()
        .map(|c| {
            if is_control(c) && !matches!(c, '\n' | '\t') {
                ' '
            } else {
                c
            }
        })
        .collect();
    let clean = lisp_trim(&clean);
    if clean.is_empty() {
        return Err(format!("{what} is required"));
    }
    let n = clean.chars().count();
    Ok((
        clean.chars().take(TEXT_MAX).collect(),
        n.saturating_sub(TEXT_MAX),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::CoordDb;
    use crate::tools::{Hub, SessionRow};
    use serde::Deserialize;
    use std::path::PathBuf;
    use std::sync::Arc;

    struct NoHub;

    impl Hub for NoHub {
        fn sessions(&self) -> BoxFuture<'_, Option<Vec<SessionRow>>> {
            Box::pin(async { None::<Vec<SessionRow>> })
        }
        fn notify(&self) {}
    }

    /// A tool whose schema lists `agent` (no coordination tool's does): only the guard stands in the way.
    #[derive(Deserialize, JsonSchema)]
    struct Loose {
        #[allow(dead_code)]
        agent: Option<String>,
    }

    struct Ran;

    impl CoordTool for Ran {
        type Args = Loose;
        const NAME: &'static str = "loose";
        const DESCRIPTION: &'static str = "a tool that would take an identity";
        fn run<'a>(
            &'a self,
            _: &'a Coord,
            _: &'a Identity,
            _: Loose,
        ) -> BoxFuture<'a, Result<String, String>> {
            Box::pin(async { Ok::<String, String>("ran".to_string()) })
        }
    }

    #[tokio::test]
    async fn refuses_identity_names_even_if_a_schema_allowed_them() {
        let dir = tempfile::tempdir().unwrap();
        let coord = Coord::new(CoordDb::spawn(dir.path().join("work.db")), Arc::new(NoHub));
        let tool = guarded(Ran);
        let who = Identity::Session {
            agent: "s-1".into(),
            sid: "s1".into(),
            profile: None,
            job: None,
            task: None,
            home: PathBuf::from("/w"),
        };
        let ctx = (Arc::new(coord), who);
        // the schema takes `agent`, so the typed check alone would let it through
        assert!(typed::<Loose>().check(&json!({"agent": "s-2"})).is_ok());
        let e = tool.check(&json!({"agent": "s-2"})).unwrap_err();
        assert_eq!(
            (e.path.as_str(), e.message.as_str()),
            ("agent", NO_IDENTITY_ARG)
        );
        match tool.call(&ctx, json!({"agent": "s-2"})).await {
            ToolResult::Err(text) => assert_eq!(
                text,
                "No tool takes `agent': you are s-1, from the process that started this server"
            ),
            ToolResult::Ok { text, .. } | ToolResult::Rich { text, .. } => {
                panic!("the guard let it run: {text}")
            }
        }
        for k in IDENTITY_ARGS {
            let mut args = serde_json::Map::new();
            args.insert(k.into(), Value::Null);
            assert!(tool.check(&Value::Object(args)).is_err(), "{k}");
        }
        // without an identity name the tool runs
        assert!(tool.check(&json!({})).is_ok());
        assert!(matches!(
            tool.call(&ctx, json!({})).await,
            ToolResult::Ok { .. }
        ));
    }

    #[test]
    fn line_is_the_lisp_line() {
        assert_eq!(line(None, 200), None);
        assert_eq!(line(Some(" \n\t "), 200), None);
        assert_eq!(
            line(Some("  a\n\n\tb\u{202e}c  "), 200).as_deref(),
            Some("a b c")
        );
        assert_eq!(line(Some("abcdef"), 3).as_deref(), Some("abc"), "no …");
    }

    #[test]
    fn text_cut_keeps_newlines_and_counts_the_cut() {
        assert_eq!(
            text_cut(Some("  a\nb\u{7}c\t "), "text"),
            Ok(("a\nb c".to_string(), 0))
        );
        assert_eq!(
            text_cut(Some("   "), "question").unwrap_err(),
            "question is required"
        );
        let (t, cut) = text_cut(Some(&"é".repeat(2005)), "text").unwrap();
        assert_eq!((t.chars().count(), cut), (TEXT_MAX, 5));
    }
}
