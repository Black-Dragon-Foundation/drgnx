//! The settings tools — `settings_get`, `settings_change` (unified-settings Task 32; design §13). Listed for every
//! agent (call 10): without a grant a change makes a card, which is the intended flow.
//!
//! - `settings_get {scope, names?}`: an `options` or `read` grant for the scope ([`options::may_read`]); the editor
//!   answers (`settings/explain`, [`Hub::explain`]); with no editor, the runtime settings the hub read itself
//!   ([`Hub::known_settings`]: `settings.el`, the shipped defaults, the editor's overrides) with `complete: false`.
//! - `settings_change {scope, name, value, reason}`: the value read as data by `huginn` (never evaluated), a secret
//!   refused, the deny-list ([`options::deny`]), then the store's own rule ([`options::may_write`]). Under a grant: a
//!   **proposed** tx of the agent's and `settings/proposed` to the editor ([`propose`]), whose `settings/confirm`
//!   accepts or undoes it; no editor: `{pending: TX}`. Without one: an `access` card (Allow once · Allow this setting
//!   for this session · Deny, [`CARD_CHOICES`]); the hub settles it ([`card_request`]). The editor writes the file;
//!   the hub never does.

use std::time::Duration;

use huginn::read::{Limits, read_all};
use mimir::{BoxFuture, Tool};
use runstav::methods::settings::{Proposed, SettingScope};
use runstav::secrets::looks_like_secret;
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{Value, json};
use urdr::Connection;
use urdr::graph::entity::{self, Changes, EntityNew, Origin, Update};
use urdr::graph::guard::Target;
use urdr::graph::{Class, TxState, WriteError};

use super::tracker::{Answer, RichTool, caller_of, err, rich};
use super::{Coord, Ctx, Identity};
use crate::options::{self, deny};
use crate::scope::Caller;
use crate::store::{CoordError, WTx};
use crate::tracker::opt;
use crate::write::cards::{NewCard, card_create};

/// The tool of an agent's proposed settings tx (what `settings/confirm` settles).
pub const PROPOSED_TOOL: &str = "mcp:settings_change";
/// How long `settings_change` waits for the editor's `settings/confirm`.
pub const CONFIRM_WAIT: Duration = Duration::from_secs(5);
/// How long `settings_get` waits for the editor's `settings/explained`.
pub const EXPLAIN_WAIT: Duration = Duration::from_secs(2);
/// What a `settings_get` answered without the editor says.
pub const NO_EDITOR: &str = "no editor: your Lisp and the workspace layers are not seen";
/// The tool's own refusal of a deny-listed name (the store's rule refuses it too, as [`options::DENIED`]).
pub const DENY_LISTED: &str = "is on the settings deny-list: no agent changes it, under any grant";
/// A settings access card's choices: allow once, allow this setting for this session, deny.
pub const CARD_CHOICES: [&str; 3] = ["once", "session", "refuse"];

/// The longest value and name taken.
const MAX_VALUE: usize = 16_384;
const MAX_NAME: usize = 256;
/// The most names one `settings_get` asks for.
const MAX_NAMES: usize = 64;

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![rich(SettingsGet), rich(SettingsChange)]
}

/// What the editor did with a proposed change ([`super::Hub::propose`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EditorAnswer {
    /// No editor is connected: the change stays proposed.
    NoEditor,
    /// The editor has it; no answer within the wait.
    Sent,
    /// The editor wrote it (`ok`), or refused it with its error (the tx is undone).
    Confirmed { ok: bool, error: Option<String> },
}

/// A change an agent asks for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub scope: SettingScope,
    pub name: String,
    /// Printed Lisp, read as data.
    pub value: String,
    pub reason: String,
    /// The session's folder (its job's task folder, or the checkout it started in).
    pub root: Option<String>,
}

// ---------------------------------------------------------------------------------------------------------- checks

fn scope_of(text: &str) -> Result<SettingScope, String> {
    SettingScope::parse(text)
        .ok_or_else(|| format!("scope: global, private or shared, not {text:?}"))
}

/// NAME as a setting's name: 1 to 256 characters, shaped as a variable's ([`deny::is_not_a_name`]: no keyword, `nil`
/// or `t`, no whitespace, control character or one of [`deny::CHARACTERS`]), as the editor checks it.
fn check_name(path: &str, name: &str) -> Result<(), String> {
    if name.is_empty() || name.len() > MAX_NAME || deny::is_not_a_name(name) {
        return Err(format!(
            "{path}: a variable's name, 1 to {MAX_NAME} characters: not a keyword, nil or t, no spaces or any of {}",
            deny::CHARACTERS
        ));
    }
    Ok(())
}

/// Whether TEXT looks like a secret, as it is or with the printed form's `\"` and `\\` read (`write::options`).
fn secret(text: &str) -> Option<&'static str> {
    looks_like_secret(text)
        .or_else(|| looks_like_secret(&text.replace("\\\"", "\"").replace("\\\\", "\\")))
}

/// C's name, value and reason as an agent may send them: the value one datum of Lisp data (`huginn`: no reader macro,
/// nothing evaluated), no secret in the value or the reason, and the name not on the deny-list. Each refusal starts
/// with the argument's path.
pub fn check_change(name: &str, value: &str, reason: &str) -> Result<(), String> {
    check_name("name", name)?;
    if value.len() > MAX_VALUE {
        return Err(format!("value: at most {MAX_VALUE} bytes"));
    }
    // the size is checked above; the reader's own limits (depth) hold too
    let nodes = read_all(value.as_bytes(), Limits::default())
        .map_err(|r| format!("value: not Lisp data ({r})"))?;
    if nodes.len() != 1 {
        return Err(format!(
            "value: one Lisp value (80, \"text\", (a b)), not {}",
            nodes.len()
        ));
    }
    if let Some(rule) = secret(value) {
        return Err(format!(
            "value: looks like a secret ({rule}): no secret goes through an agent's settings"
        ));
    }
    if let Some(rule) = looks_like_secret(reason) {
        return Err(format!(
            "reason: looks like a secret ({rule}); do not store credentials"
        ));
    }
    if deny::is_denied(name) {
        return Err(format!("name: {name} {DENY_LISTED}"));
    }
    Ok(())
}

/// The bare id (`project:` taken off) of the live project N.
fn bare_project(conn: &Connection, n: i64) -> Result<Option<String>, CoordError> {
    Ok(entity::by_n(conn, n)?
        .filter(|e| e.kind == "project" && e.retired_tx.is_none())
        .and_then(|e| e.id.strip_prefix("project:").map(str::to_owned)))
}

/// The option id of NAME in SCOPE for CALLER, and the entity's project (none for a global setting).
fn id_for(
    conn: &Connection,
    caller: &Caller,
    scope: SettingScope,
    name: &str,
) -> Result<(String, Option<i64>), CoordError> {
    let (bare, project) = match (scope, caller.project) {
        (SettingScope::Global, _) => (None, None),
        (_, Some(p)) => (bare_project(conn, p)?, Some(p)),
        (_, None) => (None, None),
    };
    let id = options::option_id(scope, bare.as_deref(), name)
        .map_err(|e| CoordError::Refused(e.to_string()))?;
    Ok((id, project))
}

/// VALUE into the option ID (made in PROJECT when new; a retired one comes back), in TX.
fn put_value(
    tx: &mut WTx<'_>,
    id: &str,
    project: Option<i64>,
    value: &str,
) -> Result<(), CoordError> {
    match entity::by_id(tx.sql(), id)? {
        None => {
            entity::create(
                tx,
                EntityNew {
                    id: id.into(),
                    kind: "option".into(),
                    project,
                    title: None,
                    status: None,
                    body: None,
                    priority: None,
                    assignee: None,
                    data: json!({ "value": value }),
                    origin: Origin::Recorded,
                    source: None,
                },
            )?;
        }
        Some(cur) if cur.kind != "option" => {
            return Err(CoordError::Refused(format!(
                "{id} is stored as a {}",
                cur.kind
            )));
        }
        Some(cur) => {
            entity::unretire(tx, cur.n)?;
            let changes = Changes {
                data_patch: Some(json!({ "value": value, "redacted": null })),
                ..Changes::default()
            };
            if let Update::Conflict { .. } = entity::update(tx, cur.n, None, changes)? {
                return Err(CoordError::Refused(format!("{id} changed meanwhile")));
            }
        }
    }
    Ok(())
}

/// CHANGE as CALLER's proposed tx (tool [`PROPOSED_TOOL`], the reason its note; the store's rule checks the grant
/// again), then `settings/proposed` to the editor, its answer waited for at most WAIT. The tx and the answer.
pub async fn propose(
    coord: &Coord,
    caller: &Caller,
    change: &Change,
    wait: Duration,
) -> Result<(i64, EditorAnswer), String> {
    let mut meta = caller.tx_meta(PROPOSED_TOOL);
    meta.state = TxState::Proposed;
    meta.note = Some(change.reason.clone());
    let (c, ch) = (caller.clone(), change.clone());
    let tx = coord
        .db()
        .write(meta, move |tx| {
            let (id, project) = id_for(tx.sql(), &c, ch.scope, &ch.name)?;
            put_value(tx, &id, project, &ch.value)?;
            Ok(tx.id())
        })
        .await
        .map_err(err)?;
    coord.hub().notify();
    let event = Proposed {
        tx,
        scope: change.scope,
        name: change.name.clone(),
        value: change.value.clone(),
        root: change.root.clone(),
        agent: caller.actor.clone(),
        reason: change.reason.clone(),
    };
    Ok((tx, coord.hub().propose(event, wait).await))
}

// ------------------------------------------------------------------------------------------------- the access card

/// The `data` of the access card CALLER's CHANGE makes (PROJECT: its project as the user knows it).
pub fn card_data(caller: &Caller, change: &Change, project: &str) -> Value {
    json!({
        "session": caller.session.clone().unwrap_or_else(|| caller.actor.clone()),
        "profile": caller.profile,
        "job": caller.job,
        "project": project,
        "project_n": caller.project,
        "setting": {
            "scope": change.scope,
            "name": change.name,
            "value": change.value,
            "reason": change.reason,
            "root": change.root,
        },
        "choices": CARD_CHOICES,
    })
}

/// A settings access card's DATA as the agent that asked and its change, checked again ([`check_change`]); `None`
/// when the card is not a settings card. The caller is always of class agent: an outside agent never gets a card.
pub fn card_request(data: &Value) -> Option<Result<(Caller, Change), String>> {
    let s = data.get("setting")?;
    Some((|| {
        let session = data["session"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or("the card names no session")?;
        let text = |v: &Value, key: &str| -> Result<String, String> {
            v[key]
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| format!("the card's setting has no {key}"))
        };
        let scope = scope_of(&text(s, "scope")?)?;
        let (name, value, reason) = (text(s, "name")?, text(s, "value")?, text(s, "reason")?);
        check_change(&name, &value, &reason)?;
        let caller = Caller {
            class: Class::Agent,
            actor: format!("agent:{session}"),
            session: Some(session.to_owned()),
            profile: data["profile"].as_str().map(str::to_owned),
            job: data["job"].as_str().map(str::to_owned),
            project: data["project_n"].as_i64(),
            backend: false,
        };
        let change = Change {
            scope,
            name,
            value,
            reason,
            root: s["root"].as_str().map(str::to_owned),
        };
        Ok((caller, change))
    })())
}

/// The access card for CALLER's CHANGE (an open one of the same session and change is the same card).
async fn card(coord: &Coord, caller: &Caller, change: &Change, now: f64) -> Result<Answer, String> {
    let (c, ch) = (caller.clone(), change.clone());
    let card = coord
        .db()
        .write(caller.tx_meta(PROPOSED_TOOL), move |tx| {
            let session = c.session.clone().unwrap_or_else(|| c.actor.clone());
            let open: Option<i64> = opt(tx.sql().query_row(
                "select id from card where kind = 'access' and state = 'open' \
                 and json_extract(data, '$.session') = ?1 and json_extract(data, '$.setting.scope') = ?2 \
                 and json_extract(data, '$.setting.name') = ?3 and json_extract(data, '$.setting.value') = ?4 \
                 order by id limit 1",
                (&session, ch.scope.as_str(), &ch.name, &ch.value),
                |r| r.get(0),
            ))?;
            if let Some(id) = open {
                return Ok(id);
            }
            let mine: String = match c.project {
                Some(p) => opt(tx.sql().query_row(
                    "select slug from project_alias where project = ?1 order by tx, slug limit 1",
                    [p],
                    |r| r.get(0),
                ))?
                .or(entity::by_n(tx.sql(), p)?.map(|e| e.id))
                .unwrap_or_else(|| "its project".into()),
                None => "no project".into(),
            };
            let profile = c.profile.clone().unwrap_or_else(|| "no profile".into());
            let shown = runstav::text::one_line(&ch.value, 80, false);
            card_create(
                tx,
                NewCard {
                    job: None,
                    task: None,
                    kind: Some("access".into()),
                    title: Some(format!(
                        "{session} ({profile}) in {mine} asks to set {} to {shown} ({})",
                        ch.name,
                        ch.scope.as_str()
                    )),
                    data: Some(card_data(&c, &ch, &mine)),
                },
                now,
            )
        })
        .await
        .map_err(err)?;
    coord.hub().notify();
    Ok(Answer {
        text: format!(
            "no grant covers {}: card {card} asks the user (allow once, for this session, or deny); the answer comes to your inbox",
            change.name
        ),
        structured: json!({ "card": card }),
        links: Vec::new(),
    })
}

// ------------------------------------------------------------------------------------------------- settings_change

#[derive(Deserialize, JsonSchema)]
struct ChangeArgs {
    /// global (settings.el), private (your workspace file) or shared (the repository's .drgnx/settings.el)
    scope: String,
    /// The variable
    name: String,
    /// Its new value as Lisp data: 80, "text", (a b); never evaluated
    value: String,
    /// Why (the user sees it)
    reason: String,
}

struct SettingsChange;

impl RichTool for SettingsChange {
    type Args = ChangeArgs;
    const NAME: &'static str = "settings_change";
    const DESCRIPTION: &'static str = "Change a setting under the user's grant: the editor writes it and the user can undo it. Without a grant the user decides on a card (your inbox has the answer). Security settings are never changed";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: ChangeArgs,
    ) -> BoxFuture<'a, Result<Answer, String>> {
        Box::pin(settings_change(coord, who, args))
    }
}

async fn settings_change(coord: &Coord, who: &Identity, a: ChangeArgs) -> Result<Answer, String> {
    who.me()?;
    let scope = scope_of(&a.scope)?;
    let value = a.value.trim().to_owned();
    // the tool's own checks first (the deny-list among them); the store's rule below holds whatever they say
    check_change(&a.name, &value, &a.reason)?;
    let caller = caller_of(coord, who, true).await?;
    let change = Change {
        scope,
        name: a.name,
        value,
        reason: runstav::text::cut(&a.reason, 500).0,
        root: who.home().map(|h| h.display().to_string()),
    };
    let now = coord.now();
    let (c, ch) = (caller.clone(), change.clone());
    let verdict = coord
        .db()
        .read(move |conn| {
            let (id, project) = id_for(conn, &c, ch.scope, &ch.name)?;
            let target = Target {
                id: &id,
                project,
                origin: Some(Origin::Recorded),
            };
            Ok(options::may_write(conn, &c, target, now))
        })
        .await
        .map_err(err)?;
    match verdict {
        Ok(()) => {}
        Err(WriteError::Refused(t)) if t == options::NO_GRANT => {
            return card(coord, &caller, &change, now).await;
        }
        Err(e) => return Err(CoordError::from(e).to_string()),
    }
    let (tx, answer) = propose(coord, &caller, &change, CONFIRM_WAIT).await?;
    let name = &change.name;
    Ok(match answer {
        EditorAnswer::Confirmed { ok: true, .. } => Answer {
            text: format!("changed: {name} = {} (tx {tx})", change.value),
            structured: json!({ "changed": tx }),
            links: Vec::new(),
        },
        EditorAnswer::Confirmed { ok: false, error } => {
            let why = error.unwrap_or_else(|| "no reason given".into());
            Answer {
                text: format!("the editor refused {name} (tx {tx}, undone): {why}"),
                structured: json!({ "refused": tx, "error": why }),
                links: Vec::new(),
            }
        }
        EditorAnswer::Sent => Answer {
            text: format!("proposed as tx {tx}: the editor has it; its answer comes to your inbox"),
            structured: json!({ "pending": tx }),
            links: Vec::new(),
        },
        EditorAnswer::NoEditor => Answer {
            text: format!(
                "proposed as tx {tx}: no editor is open, so it waits for the user as a proposed change"
            ),
            structured: json!({ "pending": tx }),
            links: Vec::new(),
        },
    })
}

// ---------------------------------------------------------------------------------------------------- settings_get

#[derive(Deserialize, JsonSchema)]
struct GetArgs {
    /// global, private or shared (your project's)
    scope: String,
    /// Only these settings (default: every one)
    names: Option<Vec<String>>,
}

struct SettingsGet;

impl RichTool for SettingsGet {
    type Args = GetArgs;
    const NAME: &'static str = "settings_get";
    const DESCRIPTION: &'static str = "Read settings and where each value comes from (needs an options or read grant). Without an editor the answer says complete false";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: GetArgs,
    ) -> BoxFuture<'a, Result<Answer, String>> {
        Box::pin(settings_get(coord, who, args))
    }
}

/// V with every string that looks like a secret replaced (an answer goes to an agent).
fn redact(v: Value) -> Value {
    match v {
        Value::String(s) if secret(&s).is_some() => Value::String("[redacted]".into()),
        Value::Array(a) => Value::Array(a.into_iter().map(redact).collect()),
        Value::Object(o) => Value::Object(o.into_iter().map(|(k, v)| (k, redact(v))).collect()),
        other => other,
    }
}

async fn settings_get(coord: &Coord, who: &Identity, a: GetArgs) -> Result<Answer, String> {
    let scope = scope_of(&a.scope)?;
    if let Some(names) = &a.names {
        if names.len() > MAX_NAMES {
            return Err(format!("names: at most {MAX_NAMES}"));
        }
        for (i, n) in names.iter().enumerate() {
            check_name(&format!("names[{i}]"), n)?;
        }
    }
    let caller = caller_of(coord, who, false).await?;
    let now = coord.now();
    coord
        .db()
        .read(move |c| Ok(options::may_read(c, &caller, scope, now)?))
        .await
        .map_err(err)?
        .map_err(str::to_owned)?;
    let root = who.home().map(|h| h.display().to_string());
    let (complete, rows) = match coord.hub().explain(scope, a.names.clone(), root).await {
        Some(rows) => (true, rows),
        None => (false, coord.hub().known_settings(a.names.as_deref())),
    };
    let rows: Vec<Value> = rows.into_iter().map(redact).collect();
    let mut text: Vec<String> = rows
        .iter()
        .map(|r| {
            let value = match &r["value"] {
                Value::String(s) => s.clone(),
                v => v.to_string(),
            };
            format!("{} = {value}", r["name"].as_str().unwrap_or("?"))
        })
        .collect();
    let mut structured = json!({ "complete": complete, "settings": rows });
    if !complete {
        text.push(format!("complete: no ({NO_EDITOR})"));
        structured["note"] = json!(NO_EDITOR);
    }
    Ok(Answer {
        text: text.join("\n"),
        structured,
        links: Vec::new(),
    })
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Mutex, RwLock};

    use mimir::ToolResult;
    use urdr::graph::{ReadPool, TxMeta};

    use super::*;
    use crate::deny::DenyList;
    use crate::grants::{self, Access, What, Who};
    use crate::project::ProjectRef;
    use crate::store::CoordDb;
    use crate::tools::{GraphStore, Hub, SessionRow};

    /// A hub whose editor answers as told.
    #[derive(Default)]
    struct EditorHub {
        /// `settings/confirm`'s answer; `None`: no editor.
        answer: Mutex<Option<EditorAnswer>>,
        proposed: Mutex<Vec<Proposed>>,
        /// `settings/explained`'s rows; `None`: no editor.
        explained: Mutex<Option<Vec<Value>>>,
        known: Vec<Value>,
    }

    impl Hub for EditorHub {
        fn sessions(&self) -> BoxFuture<'_, Option<Vec<SessionRow>>> {
            Box::pin(async { None::<Vec<SessionRow>> })
        }
        fn notify(&self) {}
        fn propose(&self, event: Proposed, _wait: Duration) -> BoxFuture<'_, EditorAnswer> {
            Box::pin(async move {
                let a = self.answer.lock().unwrap().clone();
                match a {
                    Some(a) => {
                        self.proposed.lock().unwrap().push(event);
                        a
                    }
                    None => EditorAnswer::NoEditor,
                }
            })
        }
        fn explain(
            &self,
            _scope: SettingScope,
            _names: Option<Vec<String>>,
            _root: Option<String>,
        ) -> BoxFuture<'_, Option<Vec<Value>>> {
            Box::pin(async move { self.explained.lock().unwrap().clone() })
        }
        fn known_settings(&self, names: Option<&[String]>) -> Vec<Value> {
            self.known
                .iter()
                .filter(|r| names.is_none_or(|l| l.iter().any(|n| r["name"] == n.as_str())))
                .cloned()
                .collect()
        }
    }

    struct World {
        _dir: tempfile::TempDir,
        file: PathBuf,
        db: CoordDb,
        coord: Arc<Coord>,
        hub: Arc<EditorHub>,
        home: PathBuf,
    }

    struct Out {
        err: bool,
        text: String,
        structured: Value,
    }

    impl World {
        async fn new(hub: EditorHub) -> World {
            let dir = tempfile::tempdir().unwrap();
            let file = dir.path().join("work.db");
            let db = CoordDb::spawn(&file);
            db.write(TxMeta::new("hub", Class::System, "test"), |_| Ok(()))
                .await
                .unwrap();
            let graph = GraphStore {
                writer: db.graph_writer().unwrap().clone(),
                pool: ReadPool::open(&file, 2),
                deny: Arc::new(RwLock::new(Arc::new(DenyList::load(
                    &dir.path().join("home"),
                    &dir.path().join("config"),
                )))),
            };
            let hub = Arc::new(hub);
            let coord = Arc::new(Coord::new(db.clone(), hub.clone()).with_graph(graph));
            let home = dir.path().join("alpha");
            std::fs::create_dir_all(&home).unwrap();
            let sha = format!("{:040x}", 0xa1fa_u128);
            coord.projects().lock().unwrap().insert(
                home.clone(),
                Some(ProjectRef {
                    id: format!("project:{}", &sha[28..]),
                    root: home.clone(),
                    slug: "alpha".into(),
                    root_commit: Some(sha.clone()),
                    roots: vec![sha],
                }),
            );
            World {
                _dir: dir,
                file,
                db,
                coord,
                hub,
                home,
            }
        }

        fn agent(&self, sid: &str) -> Identity {
            agent_at(sid, &self.home)
        }

        async fn call(&self, who: &Identity, name: &str, args: Value) -> Out {
            let list = tools();
            let tool = list.iter().find(|t| t.name() == name).unwrap();
            if let Err(e) = tool.check(&args) {
                return Out {
                    err: true,
                    text: e.to_string(),
                    structured: Value::Null,
                };
            }
            match tool.call(&(self.coord.clone(), who.clone()), args).await {
                ToolResult::Rich {
                    text, structured, ..
                } => Out {
                    err: false,
                    text,
                    structured: structured.unwrap_or(Value::Null),
                },
                ToolResult::Ok { text, structured } => Out {
                    err: false,
                    text,
                    structured: structured.unwrap_or(Value::Null),
                },
                ToolResult::Err(text) => Out {
                    err: true,
                    text,
                    structured: Value::Null,
                },
            }
        }

        async fn grant(&self, who: Who, what: What, access: Access, names: Option<&[&str]>) {
            let names: Option<Vec<String>> =
                names.map(|l| l.iter().map(|s| s.to_string()).collect());
            self.db
                .write(TxMeta::new("user", Class::User, "test"), move |tx| {
                    match access {
                        Access::Options => grants::create_options(tx, who, what, names, None)?,
                        a => grants::create(tx, who, what, a, None)?,
                    };
                    Ok(())
                })
                .await
                .unwrap();
        }

        fn conn(&self) -> Connection {
            Connection::open(&self.file).unwrap()
        }

        fn count(&self, sql: &str) -> i64 {
            self.conn().query_row(sql, [], |r| r.get(0)).unwrap()
        }

        /// The project `n` of the session's folder (after a tool registered it).
        fn project_n(&self) -> i64 {
            self.coord
                .projects()
                .lock()
                .unwrap()
                .project_n(&self.home)
                .unwrap()
        }
    }

    fn agent_at(sid: &str, home: &Path) -> Identity {
        Identity::Session {
            agent: sid.into(),
            sid: sid.into(),
            profile: Some("p".into()),
            job: None,
            task: None,
            home: home.to_path_buf(),
        }
    }

    fn change(scope: &str, name: &str, value: &str) -> Value {
        json!({"scope": scope, "name": name, "value": value, "reason": "the tests need it"})
    }

    fn editor(answer: Option<EditorAnswer>) -> EditorHub {
        EditorHub {
            answer: Mutex::new(answer),
            ..EditorHub::default()
        }
    }

    fn ok() -> Option<EditorAnswer> {
        Some(EditorAnswer::Confirmed {
            ok: true,
            error: None,
        })
    }

    /// Nothing reached the store or the editor: no proposed tx, no option, no card.
    fn untouched(w: &World) {
        assert_eq!(
            w.count("select count(*) from tx where tool = 'mcp:settings_change'"),
            0
        );
        assert_eq!(
            w.count("select count(*) from entity where kind = 'option'"),
            0
        );
        assert_eq!(w.count("select count(*) from card"), 0);
        assert!(w.hub.proposed.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_secret_is_refused() {
        let w = World::new(editor(ok())).await;
        w.grant(
            Who::Session("s1".into()),
            What::OptionsGlobal,
            Access::Options,
            None,
        )
        .await;
        let me = w.agent("s1");
        let key = concat!("\"sk-or-", "v1-0a1b2c3d4e5f60718293a4b5c6d7e8f9\"");
        let out = w
            .call(&me, "settings_change", change("global", "my-api-key", key))
            .await;
        assert!(
            out.err && out.text.starts_with("value: looks like a secret"),
            "{}",
            out.text
        );
        // inside a printed string too
        let quoted = concat!(
            "\"{\\\"api_key\\\": \\\"sk-ant-",
            "api03-Xy7Kp2Qm9Rt4Vw8Zb3Nc6Hd1Jf5Lg0Ps\\\"}\""
        );
        let out = w
            .call(&me, "settings_change", change("global", "my-json", quoted))
            .await;
        assert!(
            out.err && out.text.starts_with("value: looks like a secret"),
            "{}",
            out.text
        );
        // a secret as the reason
        let mut args = change("global", "fill-column", "80");
        args["reason"] = json!(concat!("ghp_", "aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3h"));
        let out = w.call(&me, "settings_change", args).await;
        assert!(
            out.err && out.text.starts_with("reason: looks like a secret"),
            "{}",
            out.text
        );
        untouched(&w);
    }

    #[tokio::test]
    async fn a_denied_name_is_refused() {
        let w = World::new(editor(ok())).await;
        w.grant(
            Who::Session("s1".into()),
            What::OptionsGlobal,
            Access::Options,
            Some(&["*"]),
        )
        .await;
        let me = w.agent("s1");
        for name in [
            "load-path",
            "drgnx-agents-allow-unsandboxed",
            "safe-local-variable-values",
            "after-save-hook",
            "python-shell-interpreter",
            "eval",
        ] {
            let out = w
                .call(&me, "settings_change", change("global", name, "nil"))
                .await;
            assert!(out.err, "{name}");
            assert_eq!(out.text, format!("name: {name} {DENY_LISTED}"), "{name}");
        }
        untouched(&w);
        // the store's rule refuses it too, whatever the tool says (the mutation check's other layer)
        let caller = Caller {
            class: Class::Agent,
            actor: "agent:s1".into(),
            session: Some("s1".into()),
            profile: None,
            job: None,
            project: None,
            backend: false,
        };
        let change = Change {
            scope: SettingScope::Global,
            name: "load-path".into(),
            value: "nil".into(),
            reason: "r".into(),
            root: None,
        };
        let e = propose(&w.coord, &caller, &change, Duration::ZERO)
            .await
            .unwrap_err();
        assert_eq!(e, options::DENIED);
        // a name no variable has (a keyword, nil, the editor's refused characters): the store's rule refuses it as
        // deny-listed too (the tool refuses it as no name: `value_is_parsed_as_data`), so no grant or card carries it
        for name in [
            ":eval",
            ":mode",
            ":dir",
            "nil",
            "t",
            "fill(column",
            "a;b",
            "a#b",
            "a[b",
        ] {
            assert!(
                check_change(name, "nil", "r")
                    .unwrap_err()
                    .starts_with("name: a variable's name"),
                "{name}"
            );
            let change = Change {
                name: name.into(),
                ..change.clone()
            };
            let e = propose(&w.coord, &caller, &change, Duration::ZERO)
                .await
                .unwrap_err();
            assert_eq!(e, options::DENIED, "{name}");
        }
        untouched(&w);
    }

    #[tokio::test]
    async fn without_a_grant_a_card() {
        let w = World::new(editor(ok())).await;
        let me = w.agent("s1");
        let out = w
            .call(
                &me,
                "settings_change",
                change("shared", "fill-column", "100"),
            )
            .await;
        assert!(!out.err, "{}", out.text);
        let card = out.structured["card"].as_i64().unwrap();
        let (kind, state, title, data): (String, String, String, String) = w
            .conn()
            .query_row(
                "select kind, state, title, data from card where id = ?1",
                [card],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap();
        assert_eq!((kind.as_str(), state.as_str()), ("access", "open"));
        assert_eq!(
            title,
            "s1 (p) in alpha asks to set fill-column to 100 (shared)"
        );
        let data: Value = serde_json::from_str(&data).unwrap();
        assert_eq!(data["choices"], json!(CARD_CHOICES));
        assert_eq!(data["project_n"], json!(w.project_n()));
        // the card names the request exactly: the hub settles it into this caller and change
        let (caller, ch) = card_request(&data).unwrap().unwrap();
        assert_eq!(
            (
                caller.class,
                caller.actor.as_str(),
                caller.session.as_deref(),
                caller.profile.as_deref()
            ),
            (Class::Agent, "agent:s1", Some("s1"), Some("p"))
        );
        assert_eq!(caller.project, Some(w.project_n()));
        assert_eq!(
            ch,
            Change {
                scope: SettingScope::Shared,
                name: "fill-column".into(),
                value: "100".into(),
                reason: "the tests need it".into(),
                root: Some(w.home.display().to_string()),
            }
        );
        // the same request again is the same card; another value is another card
        let again = w
            .call(
                &me,
                "settings_change",
                change("shared", "fill-column", "100"),
            )
            .await;
        assert_eq!(again.structured["card"].as_i64(), Some(card));
        let other = w
            .call(
                &me,
                "settings_change",
                change("shared", "fill-column", "90"),
            )
            .await;
        assert_ne!(other.structured["card"].as_i64(), Some(card));
        // a grant for another name, or a read grant, is no grant to change it
        w.grant(
            Who::Session("s1".into()),
            What::OptionsProject,
            Access::Options,
            Some(&["tab-*"]),
        )
        .await;
        w.grant(Who::Session("s1".into()), What::All, Access::Read, None)
            .await;
        let out = w
            .call(
                &me,
                "settings_change",
                change("shared", "fill-column", "70"),
            )
            .await;
        assert!(out.structured["card"].is_i64(), "{}", out.text);
        assert_eq!(
            w.count("select count(*) from entity where kind = 'option'"),
            0
        );
        assert!(w.hub.proposed.lock().unwrap().is_empty());
        // a card that is not a settings card, and one whose change does not check
        assert!(card_request(&json!({"session": "s1", "target": "beta"})).is_none());
        let mut bad = data.clone();
        bad["setting"]["name"] = json!("load-path");
        assert!(card_request(&bad).unwrap().is_err());
        let mut bad = data.clone();
        bad["session"] = json!("");
        assert!(card_request(&bad).unwrap().is_err());
        let mut bad = data;
        bad["setting"]["scope"] = json!("everywhere");
        assert!(card_request(&bad).unwrap().is_err());
    }

    #[tokio::test]
    async fn with_a_grant_a_proposed_tx() {
        let w = World::new(editor(ok())).await;
        w.grant(
            Who::Session("s1".into()),
            What::OptionsGlobal,
            Access::Options,
            Some(&["fill-*"]),
        )
        .await;
        let me = w.agent("s1");
        let out = w
            .call(
                &me,
                "settings_change",
                change("global", "fill-column", " 80 "),
            )
            .await;
        assert!(!out.err, "{}", out.text);
        let tx = out.structured["changed"].as_i64().unwrap();
        let row: (String, String, String, String, Option<String>) = w
            .conn()
            .query_row(
                "select actor, class, tool, state, note from tx where id = ?1",
                [tx],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .unwrap();
        assert_eq!(
            row,
            (
                "agent:s1".into(),
                "agent".into(),
                PROPOSED_TOOL.into(),
                "proposed".into(),
                Some("the tests need it".into())
            )
        );
        let (value, project): (String, Option<i64>) = w
            .conn()
            .query_row(
                "select json_extract(data, '$.value'), project from entity where id = 'option:global:fill-column'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!((value.as_str(), project), ("80", None));
        let sent = w.hub.proposed.lock().unwrap().clone();
        assert_eq!(
            sent,
            [Proposed {
                tx,
                scope: SettingScope::Global,
                name: "fill-column".into(),
                value: "80".into(),
                root: Some(w.home.display().to_string()),
                agent: "agent:s1".into(),
                reason: "the tests need it".into(),
            }]
        );
        // the project's settings under a project grant: the id is the project's, the entity in it
        w.grant(
            Who::Session("s1".into()),
            What::OptionsProject,
            Access::Options,
            None,
        )
        .await;
        let out = w
            .call(&me, "settings_change", change("private", "tab-width", "4"))
            .await;
        assert!(out.structured["changed"].is_i64(), "{}", out.text);
        let p = w.project_n();
        let bare: String = w
            .conn()
            .query_row("select id from entity where n = ?1", [p], |r| r.get(0))
            .unwrap();
        let id = format!(
            "option:private/{}:tab-width",
            bare.strip_prefix("project:").unwrap()
        );
        assert_eq!(
            w.count(&format!(
                "select count(*) from entity where id = '{id}' and project = {p}"
            )),
            1
        );
        // a second change of a setting is a new version of it
        let out = w
            .call(
                &me,
                "settings_change",
                change("global", "fill-column", "72"),
            )
            .await;
        assert!(out.structured["changed"].is_i64(), "{}", out.text);
        assert_eq!(
            w.count("select ver from entity where id = 'option:global:fill-column'"),
            2
        );
        // the editor's refusal is the agent's answer
        *w.hub.answer.lock().unwrap() = Some(EditorAnswer::Confirmed {
            ok: false,
            error: Some("not a number".into()),
        });
        let out = w
            .call(&me, "settings_change", change("global", "fill-column", "x"))
            .await;
        assert_eq!(out.structured["error"], "not a number");
        assert!(out.structured["refused"].is_i64());
        *w.hub.answer.lock().unwrap() = Some(EditorAnswer::Sent);
        let out = w
            .call(
                &me,
                "settings_change",
                change("global", "fill-column", "60"),
            )
            .await;
        assert!(out.structured["pending"].is_i64(), "{}", out.text);
        // an outside agent never changes a setting, grant or not
        w.grant(
            Who::Session("ext:claude:1-ab".into()),
            What::OptionsGlobal,
            Access::Options,
            None,
        )
        .await;
        let outside = Identity::Outside {
            id: "ext:claude:1-ab".into(),
            kind: "claude".into(),
            home: Some(w.home.clone()),
        };
        let out = w
            .call(
                &outside,
                "settings_change",
                change("global", "fill-column", "50"),
            )
            .await;
        assert!(out.err, "{}", out.text);
        assert_eq!(out.text, options::SETTINGS_ARE_THE_USERS);
        // no identity: read-only
        let out = w
            .call(
                &Identity::None,
                "settings_change",
                change("global", "fill-column", "50"),
            )
            .await;
        assert!(out.err);
    }

    /// The bounds of a name and a value: 1 to 256 characters, at most 16 KiB (the mutation check's misses).
    #[test]
    fn a_name_and_a_value_have_bounds() {
        let at = |n: usize| "a".repeat(n);
        assert!(check_change("", "1", "r").unwrap_err().starts_with("name:"));
        assert!(check_change(&at(MAX_NAME), "1", "r").is_ok());
        let e = check_change(&at(MAX_NAME + 1), "1", "r").unwrap_err();
        assert!(e.starts_with("name:"), "{e}");
        assert!(check_change("x", &at(MAX_VALUE), "r").is_ok());
        let e = check_change("x", &at(MAX_VALUE + 1), "r").unwrap_err();
        assert!(e.starts_with("value: at most"), "{e}");
        assert!(check_change("a\tb", "1", "r").is_err());
    }

    #[tokio::test]
    async fn no_editor_is_pending() {
        let w = World::new(editor(None)).await;
        w.grant(
            Who::Session("s1".into()),
            What::OptionsGlobal,
            Access::Options,
            None,
        )
        .await;
        let out = w
            .call(
                &w.agent("s1"),
                "settings_change",
                change("global", "fill-column", "80"),
            )
            .await;
        assert!(!out.err, "{}", out.text);
        let tx = out.structured["pending"].as_i64().unwrap();
        assert!(out.text.contains("no editor"), "{}", out.text);
        assert_eq!(
            w.count(&format!(
                "select count(*) from tx where id = {tx} and state = 'proposed'"
            )),
            1
        );
        // a project setting with no project: refused, nothing written
        let w = World::new(editor(None)).await;
        w.grant(
            Who::Session("s2".into()),
            What::OptionsProject,
            Access::Options,
            None,
        )
        .await;
        // `/`: no repository, so no project (a temp folder might sit inside a checkout)
        let nowhere = PathBuf::from("/");
        let out = w
            .call(
                &agent_at("s2", &nowhere),
                "settings_change",
                change("private", "fill-column", "80"),
            )
            .await;
        assert!(out.err);
        assert_eq!(out.text, options::NO_PROJECT);
        untouched(&w);
    }

    #[tokio::test]
    async fn get_without_editor_is_partial() {
        let hub = EditorHub {
            known: vec![
                json!({"name": "drgnx-agents-default", "value": "claude", "source": "hub"}),
                json!({"name": "drgnx-ai-providers", "value": [{"id": "x", "key": concat!("sk-or-", "v1-0a1b2c3d4e5f60718293a4b5c6d7e8f9")}], "source": "hub"}),
            ],
            ..EditorHub::default()
        };
        let w = World::new(hub).await;
        let me = w.agent("s1");
        // no grant: refused
        let out = w
            .call(&me, "settings_get", json!({"scope": "global"}))
            .await;
        assert!(out.err);
        assert_eq!(out.text, options::NO_READ_GRANT);
        // a read grant to `*` covers it
        w.grant(Who::Session("s1".into()), What::All, Access::Read, None)
            .await;
        let out = w
            .call(&me, "settings_get", json!({"scope": "global"}))
            .await;
        assert!(!out.err, "{}", out.text);
        assert_eq!(out.structured["complete"], false);
        assert_eq!(out.structured["note"], NO_EDITOR);
        assert_eq!(out.structured["settings"][0]["value"], "claude");
        // a secret never goes to an agent
        assert_eq!(
            out.structured["settings"][1]["value"][0]["key"],
            "[redacted]"
        );
        assert!(
            out.text.contains("drgnx-agents-default = claude"),
            "{}",
            out.text
        );
        assert!(out.text.contains(NO_EDITOR), "{}", out.text);
        let out = w
            .call(
                &me,
                "settings_get",
                json!({"scope": "global", "names": ["drgnx-agents-default"]}),
            )
            .await;
        assert_eq!(out.structured["settings"].as_array().unwrap().len(), 1);
        // with an editor: its rows, complete
        *w.hub.explained.lock().unwrap() = Some(vec![
            json!({"name": "fill-column", "value": "80", "file": "settings.el", "line": 3}),
        ]);
        let out = w
            .call(&me, "settings_get", json!({"scope": "shared"}))
            .await;
        assert_eq!(out.structured["complete"], true);
        assert!(out.structured.get("note").is_none());
        assert_eq!(out.structured["settings"][0]["line"], 3);
        // bad arguments
        let out = w.call(&me, "settings_get", json!({"scope": "local"})).await;
        assert!(out.err && out.text.starts_with("scope:"), "{}", out.text);
        let out = w
            .call(
                &me,
                "settings_get",
                json!({"scope": "global", "names": ["a b"]}),
            )
            .await;
        assert!(out.err && out.text.starts_with("names[0]:"), "{}", out.text);
        let many: Vec<String> = (0..=MAX_NAMES).map(|i| format!("v{i}")).collect();
        let out = w
            .call(
                &me,
                "settings_get",
                json!({"scope": "global", "names": many}),
            )
            .await;
        assert!(out.err && out.text.starts_with("names:"), "{}", out.text);
    }

    #[tokio::test]
    async fn value_is_parsed_as_data() {
        let w = World::new(editor(ok())).await;
        w.grant(
            Who::Session("s1".into()),
            What::OptionsGlobal,
            Access::Options,
            None,
        )
        .await;
        let me = w.agent("s1");
        for (value, want) in [
            ("#.(shell-command \"touch x\")", "value: not Lisp data"),
            ("`(a ,b)", "value: not Lisp data"),
            ("(a", "value: not Lisp data"),
            ("", "value: one Lisp value"),
            ("1 2", "value: one Lisp value"),
        ] {
            let out = w
                .call(
                    &me,
                    "settings_change",
                    change("global", "fill-column", value),
                )
                .await;
            assert!(
                out.err && out.text.starts_with(want),
                "{value:?}: {}",
                out.text
            );
        }
        let big = format!("\"{}\"", "x".repeat(MAX_VALUE));
        let out = w
            .call(
                &me,
                "settings_change",
                change("global", "fill-column", &big),
            )
            .await;
        assert!(
            out.err && out.text.starts_with("value: at most"),
            "{}",
            out.text
        );
        untouched(&w);
        // data is data, whatever it looks like: a list that would be code is still only a value
        for value in [
            "(a . 1)",
            "(shell-command \"touch x\")",
            "\"text\"",
            "?a",
            "[1 2]",
            "'x",
        ] {
            let out = w
                .call(
                    &me,
                    "settings_change",
                    change("global", "fill-column", value),
                )
                .await;
            assert!(out.structured["changed"].is_i64(), "{value}: {}", out.text);
            assert_eq!(w.hub.proposed.lock().unwrap().last().unwrap().value, value);
        }
        // a name that would read as a section, or is no name
        for name in [
            "mode/c-mode:fill-column",
            "dir/src/:x",
            "fill column",
            "",
            ":eval",
            "nil",
            "t",
            "a\"b",
            "a'b",
            "a`b",
            "a,b",
            "a)b",
            "a]b",
            "a\\b",
        ] {
            let out = w
                .call(&me, "settings_change", change("global", name, "1"))
                .await;
            assert!(out.err, "{name:?}");
        }
        // the shape refusals are the tool's own, before any grant or card
        for name in [":eval", "nil", "t", "a\"b", "a)b", "a]b", "a\\b"] {
            let out = w
                .call(&me, "settings_change", change("global", name, "1"))
                .await;
            assert!(
                out.text.starts_with("name: a variable's name"),
                "{name:?}: {}",
                out.text
            );
        }
        let out = w
            .call(&me, "settings_change", change("everywhere", "x", "1"))
            .await;
        assert!(out.err && out.text.starts_with("scope:"), "{}", out.text);
    }
}
