//! Grants (Task 10; storage §5.5, §12.2 answers 1–2): only the user writes them, checked in urdr's write path
//! ([`register`] puts norn's rules into the [`Guard`]: kind `grant` and `kv` keys `setting:*` need `Class::User`).
//!
//! A grant is an entity of kind `grant` (id `grant:<8 base36>`, no project), `status` `active` or `revoked`, `data`
//! `{"who": {"project": N} | {"profile": NAME} | {"session": SID}, "what": {"project": N} | "*" | {"task": N} |
//! "options:global" | "options:project", "access": "read" | "edit-user-tasks" | "options", "names"?: [GLOB],
//! "expires"?: unix seconds}`. An `options` grant (Urdr Task 10b; unified-settings design §13) lets agents write
//! settings history of kind `option` ([`crate::options`]): `what` is always one of the two `options:` forms, and only
//! it carries `names` (globs, `*` only, no `/`). A row that does not parse as one is ignored (it opens nothing).

use std::fmt;

use serde_json::{Value, json};
use sha1::{Digest, Sha1};
use urdr::Connection;
use urdr::graph::entity::{self, Changes, EntityNew, Origin};
use urdr::graph::guard::{self, Guard};
use urdr::graph::{Class, Tx, WriteError};

use crate::project::base36;
use crate::scope::{self, Caller};

/// The refusal of a grant write by any class but the user's.
pub const GRANTS_ARE_THE_USERS: &str = "grants are the user's";
/// The refusal of a `setting:*` key written by any class but the user's.
pub const SETTINGS_ARE_THE_USERS: &str = "settings are the user's";
/// The `kv` keys of store settings (`setting:only-user-closes`, call 17).
pub const SETTING_PREFIX: &str = "setting:";

/// Who a grant is for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Who {
    /// A project's entity `n`.
    Project(i64),
    Profile(String),
    Session(String),
}

impl Who {
    /// Whether CALLER is who this names: its project, its profile or its session.
    pub fn matches(&self, caller: &Caller) -> bool {
        match self {
            Who::Project(p) => caller.project == Some(*p),
            Who::Profile(name) => caller.profile.as_deref() == Some(name),
            Who::Session(sid) => caller.session.as_deref() == Some(sid),
        }
    }

    /// `project:N`, `profile:NAME` or `session:SID`.
    pub fn parse(text: &str) -> Option<Who> {
        let (kind, rest) = text.split_once(':')?;
        match kind {
            "project" => rest.parse().ok().map(Who::Project),
            "profile" if !rest.is_empty() => Some(Who::Profile(rest.into())),
            "session" if !rest.is_empty() => Some(Who::Session(rest.into())),
            _ => None,
        }
    }

    fn to_json(&self) -> Value {
        match self {
            Who::Project(n) => json!({ "project": n }),
            Who::Profile(name) => json!({ "profile": name }),
            Who::Session(sid) => json!({ "session": sid }),
        }
    }

    fn from_json(v: &Value) -> Option<Who> {
        let o = v.as_object().filter(|o| o.len() == 1)?;
        let (k, v) = o.iter().next()?;
        match k.as_str() {
            "project" => v.as_i64().map(Who::Project),
            "profile" => v.as_str().map(|s| Who::Profile(s.into())),
            "session" => v.as_str().map(|s| Who::Session(s.into())),
            _ => None,
        }
    }
}

impl fmt::Display for Who {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Who::Project(n) => write!(f, "project:{n}"),
            Who::Profile(name) => write!(f, "profile:{name}"),
            Who::Session(sid) => write!(f, "session:{sid}"),
        }
    }
}

/// What it opens.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum What {
    Project(i64),
    All,
    /// For `EditUserTasks`: one task's `n`.
    Task(i64),
    /// For `Options`: the global settings (`settings.el`).
    OptionsGlobal,
    /// For `Options`: the private and shared settings of the agent's own project.
    OptionsProject,
}

const OPTIONS_GLOBAL: &str = "options:global";
const OPTIONS_PROJECT: &str = "options:project";

impl What {
    /// `project:N`, `*`, `task:N`, `options:global` or `options:project`.
    pub fn parse(text: &str) -> Option<What> {
        match text {
            "*" => return Some(What::All),
            OPTIONS_GLOBAL => return Some(What::OptionsGlobal),
            OPTIONS_PROJECT => return Some(What::OptionsProject),
            _ => {}
        }
        match text.split_once(':')? {
            ("project", n) => n.parse().ok().map(What::Project),
            ("task", n) => n.parse().ok().map(What::Task),
            _ => None,
        }
    }

    fn to_json(&self) -> Value {
        match self {
            What::Project(n) => json!({ "project": n }),
            What::All => json!("*"),
            What::Task(n) => json!({ "task": n }),
            What::OptionsGlobal => json!(OPTIONS_GLOBAL),
            What::OptionsProject => json!(OPTIONS_PROJECT),
        }
    }

    fn from_json(v: &Value) -> Option<What> {
        match v.as_str() {
            Some("*") => return Some(What::All),
            Some(OPTIONS_GLOBAL) => return Some(What::OptionsGlobal),
            Some(OPTIONS_PROJECT) => return Some(What::OptionsProject),
            Some(_) => return None,
            None => {}
        }
        let o = v.as_object().filter(|o| o.len() == 1)?;
        let (k, v) = o.iter().next()?;
        match k.as_str() {
            "project" => v.as_i64().map(What::Project),
            "task" => v.as_i64().map(What::Task),
            _ => None,
        }
    }
}

impl fmt::Display for What {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            What::Project(n) => write!(f, "project:{n}"),
            What::All => f.write_str("*"),
            What::Task(n) => write!(f, "task:{n}"),
            What::OptionsGlobal => f.write_str(OPTIONS_GLOBAL),
            What::OptionsProject => f.write_str(OPTIONS_PROJECT),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Access {
    Read,
    EditUserTasks,
    /// Write settings history (kind `option`) in an `options:` scope.
    Options,
}

impl Access {
    /// `read`, `edit-user-tasks` or `options`.
    pub fn as_str(self) -> &'static str {
        match self {
            Access::Read => "read",
            Access::EditUserTasks => "edit-user-tasks",
            Access::Options => "options",
        }
    }

    pub fn parse(text: &str) -> Option<Access> {
        match text {
            "read" => Some(Access::Read),
            "edit-user-tasks" => Some(Access::EditUserTasks),
            "options" => Some(Access::Options),
            _ => None,
        }
    }
}

/// Whether WHAT is one an ACCESS grant opens: the `options:` forms for `Options` only; a task for `EditUserTasks`
/// only.
fn fits(access: Access, what: &What) -> bool {
    match what {
        What::OptionsGlobal | What::OptionsProject => access == Access::Options,
        What::Task(_) => access == Access::EditUserTasks,
        What::Project(_) | What::All => access != Access::Options,
    }
}

/// The most names one grant holds, and the longest name glob.
const MAX_NAMES: usize = 64;
const MAX_GLOB: usize = 256;

/// Whether GLOB is a name glob: not empty, no `/`, whitespace or control character (`*` is its only wildcard).
fn glob_ok(glob: &str) -> bool {
    !glob.is_empty()
        && glob.len() <= MAX_GLOB
        && !glob
            .chars()
            .any(|c| c == '/' || c.is_whitespace() || c.is_control())
}

/// Whether NAMES is a grant's name list: 1 to 64 globs.
fn names_ok(names: &[String]) -> bool {
    !names.is_empty() && names.len() <= MAX_NAMES && names.iter().all(|g| glob_ok(g))
}

/// A grant entity.
#[derive(Clone, Debug, PartialEq)]
pub struct Grant {
    pub n: i64,
    pub id: String,
    pub who: Who,
    pub what: What,
    pub access: Access,
    /// An `options` grant's name globs; `None`: every name (the deny-list still holds).
    pub names: Option<Vec<String>>,
    pub expires: Option<f64>,
    /// `active` or `revoked`.
    pub status: String,
    /// A settings card's "Allow once" ([`create_options_once`]): the card whose change alone it covers.
    pub card: Option<i64>,
}

impl Grant {
    /// `active` and not expired at NOW.
    pub fn active(&self, now: f64) -> bool {
        self.status == "active" && self.expires.is_none_or(|t| t > now)
    }

    /// Whether this grant's `names` cover the setting VAR (every name when it has none).
    pub fn names_match(&self, var: &str) -> bool {
        self.names
            .as_ref()
            .is_none_or(|globs| globs.iter().any(|g| crate::options::glob_match(g, var)))
    }
}

/// Which grants [`list`] answers.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Filter {
    pub who: Option<Who>,
    pub active: Option<bool>,
}

/// Put norn's class rules into GUARD: entities of kind `grant` and `kv` keys `setting:*` and `privacy:*` are the
/// user's; entities of kind `option` are the user's, or an agent's under a matching `options` grant
/// ([`crate::options::rule`]).
pub fn register(guard: &mut Guard) {
    guard::register(guard, "grant", Class::User, GRANTS_ARE_THE_USERS);
    guard::register_rule(guard, "option", crate::options::rule);
    guard::register_key_prefix(guard, SETTING_PREFIX, Class::User, SETTINGS_ARE_THE_USERS);
    crate::privacy::register(guard);
}

/// The grants' version: the highest `updated_tx` of a grant row (0 when none).
pub(crate) fn grants_tx(conn: &Connection) -> Result<i64, urdr::SqliteError> {
    conn.query_row(
        "select coalesce(max(updated_tx), 0) from entity where project is null and kind = 'grant'",
        [],
        |r| r.get(0),
    )
}

/// Every grant not retired that parses, by `n`.
pub(crate) fn live(conn: &Connection) -> Result<Vec<Grant>, urdr::SqliteError> {
    let mut stmt = conn.prepare(
        "select n, id, status, data from entity \
         where project is null and kind = 'grant' and retired_tx is null order by n",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, Option<String>>(2)?,
            r.get::<_, String>(3)?,
        ))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (n, id, status, data) = row?;
        out.extend(parse(n, id, status, &data));
    }
    Ok(out)
}

/// A grant row's columns as a [`Grant`]; `None` when they are not one.
fn parse(n: i64, id: String, status: Option<String>, data: &str) -> Option<Grant> {
    let data: Value = serde_json::from_str(data).ok()?;
    let expires = match data.get("expires") {
        None | Some(Value::Null) => None,
        Some(v) => Some(v.as_f64()?),
    };
    let what = What::from_json(data.get("what")?)?;
    let access = Access::parse(data.get("access")?.as_str()?)?;
    if !fits(access, &what) {
        return None;
    }
    let names = match data.get("names") {
        None | Some(Value::Null) => None,
        Some(v) => {
            let list: Vec<String> = v
                .as_array()?
                .iter()
                .map(|g| g.as_str().map(String::from))
                .collect::<Option<_>>()?;
            if access != Access::Options || !names_ok(&list) {
                return None;
            }
            Some(list)
        }
    };
    let card = match data.get("card") {
        None | Some(Value::Null) => None,
        Some(v) => Some(v.as_i64()?),
    };
    Some(Grant {
        n,
        id,
        who: Who::from_json(data.get("who")?)?,
        what,
        access,
        names,
        expires,
        status: status?,
        card,
    })
}

fn refused(text: &str) -> WriteError {
    WriteError::Refused(text.into())
}

/// Whether N is a live entity of KIND.
fn is_live(tx: &Tx<'_>, n: i64, kind: &str) -> Result<bool, WriteError> {
    Ok(entity::by_n(tx.sql(), n)?.is_some_and(|e| e.kind == kind && e.retired_tx.is_none()))
}

/// A new grant (the guard refuses it from any class but `User`). A `read` grant opens a project or `*`; an
/// `edit-user-tasks` grant a task, a project or `*`. The projects and the task must exist, a profile or session
/// name must not be empty, and EXPIRES must lie after the tx's time.
pub fn create(
    tx: &mut Tx<'_>,
    who: Who,
    what: What,
    access: Access,
    expires: Option<f64>,
) -> Result<Grant, WriteError> {
    create_with(tx, who, what, access, None, expires, None)
}

/// A new `options` grant (Urdr Task 10b; the guard refuses it from any class but `User`): WHAT is
/// `OptionsGlobal` or `OptionsProject`; NAMES, when given, 1 to 64 globs (`*` only, no `/`); `None` covers every
/// name the deny-list leaves.
pub fn create_options(
    tx: &mut Tx<'_>,
    who: Who,
    what: What,
    names: Option<Vec<String>>,
    expires: Option<f64>,
) -> Result<Grant, WriteError> {
    create_with(tx, who, what, Access::Options, names, expires, None)
}

/// A settings card's "Allow once": an `options` grant of NAME, as [`create_options`], that covers only the tx
/// whose request key is [`crate::options::card_req`] of CARD (the hub's proposal of the card's change), so the
/// agent's own next change, of any value, is not covered while it lives.
pub fn create_options_once(
    tx: &mut Tx<'_>,
    who: Who,
    what: What,
    name: String,
    card: i64,
    expires: Option<f64>,
) -> Result<Grant, WriteError> {
    create_with(
        tx,
        who,
        what,
        Access::Options,
        Some(vec![name]),
        expires,
        Some(card),
    )
}

fn create_with(
    tx: &mut Tx<'_>,
    who: Who,
    what: What,
    access: Access,
    names: Option<Vec<String>>,
    expires: Option<f64>,
    card: Option<i64>,
) -> Result<Grant, WriteError> {
    guard::check(tx.guard(), tx.meta(), "grant")?;
    if !fits(access, &what) {
        return Err(refused(match access {
            Access::Read => "a read grant opens a project or every project (*)",
            Access::EditUserTasks => {
                "an edit-user-tasks grant opens a task, a project or every project (*)"
            }
            Access::Options => "an options grant opens options:global or options:project",
        }));
    }
    if let Some(list) = &names
        && (access != Access::Options || !names_ok(list))
    {
        return Err(refused(
            "an options grant's names are 1 to 64 globs (* only, no /, no spaces)",
        ));
    }
    let mut ends: Vec<(i64, &str)> = Vec::new();
    match &who {
        Who::Project(p) => ends.push((*p, "project")),
        Who::Profile(s) | Who::Session(s) => {
            if s.trim().is_empty() {
                return Err(refused("a grant names its profile or session"));
            }
        }
    }
    match &what {
        What::Project(p) => ends.push((*p, "project")),
        What::Task(t) => ends.push((*t, "task")),
        What::All | What::OptionsGlobal | What::OptionsProject => {}
    }
    for (n, kind) in ends {
        if !is_live(tx, n, kind)? {
            return Err(refused(&format!("no {kind} {n}")));
        }
    }
    if expires.is_some_and(|t| !t.is_finite() || t <= tx.at()) {
        return Err(refused("a grant expires in the future"));
    }
    let mut data = json!({
        "who": who.to_json(),
        "what": what.to_json(),
        "access": access.as_str(),
    });
    if let Some(t) = expires {
        data["expires"] = json!(t);
    }
    if let Some(list) = &names {
        data["names"] = json!(list);
    }
    if let Some(c) = card {
        data["card"] = json!(c);
    }
    let title = match &names {
        Some(list) => format!("{who} may change settings {what} ({})", list.join(", ")),
        None if access == Access::Options => format!("{who} may change settings {what}"),
        None => format!("{who} may {} {what}", access.as_str()),
    };
    let mut id = None;
    for attempt in 0..16u32 {
        let seed = format!("{}\0{}\0{data}\0{attempt}", tx.id(), tx.at());
        let digest = Sha1::digest(seed.as_bytes());
        let v = digest
            .iter()
            .take(8)
            .fold(0u64, |v, b| (v << 8) | u64::from(*b));
        let candidate = format!("grant:{}", base36(v, 8));
        if entity::by_id(tx.sql(), &candidate)?.is_none() {
            id = Some(candidate);
            break;
        }
    }
    let id = id.ok_or_else(|| refused("no free grant id"))?;
    let ent = entity::create(
        tx,
        EntityNew {
            id: id.clone(),
            kind: "grant".into(),
            project: None,
            title: Some(title),
            status: Some("active".into()),
            body: None,
            priority: None,
            assignee: None,
            data,
            origin: Origin::Recorded,
            source: None,
        },
    )?;
    scope::grants_changed(tx.sql());
    Ok(Grant {
        n: ent.n,
        id,
        who,
        what,
        access,
        names,
        expires,
        status: "active".into(),
        card,
    })
}

/// Set grant ID `revoked`; false when there was no active one. The guard refuses any class but `User`, found or not.
pub fn revoke(tx: &mut Tx<'_>, id: &str) -> Result<bool, WriteError> {
    guard::check(tx.guard(), tx.meta(), "grant")?;
    let Some(e) = entity::by_id(tx.sql(), id)? else {
        return Ok(false);
    };
    if e.kind != "grant" || e.retired_tx.is_some() || e.status.as_deref() != Some("active") {
        return Ok(false);
    }
    entity::update(
        tx,
        e.n,
        None,
        Changes {
            status: Some(Some("revoked".into())),
            ..Changes::default()
        },
    )?;
    scope::grants_changed(tx.sql());
    Ok(true)
}

/// The grants CALLER may see that match FILTER (an agent or ext caller: only grants whose `who` is its own; the
/// others would name other projects and their grants).
pub fn list(
    conn: &Connection,
    caller: &Caller,
    filter: &Filter,
    now: f64,
) -> Result<Vec<Grant>, urdr::SqliteError> {
    let everything = matches!(caller.class, Class::User | Class::System);
    Ok(live(conn)?
        .into_iter()
        .filter(|g| everything || g.who.matches(caller))
        .filter(|g| filter.who.as_ref().is_none_or(|w| *w == g.who))
        .filter(|g| filter.active.is_none_or(|a| g.active(now) == a))
        .collect())
}

/// Whether CALLER holds an active `edit-user-tasks` grant for TASK (an entity `n`): one for the task, its project,
/// or `*`. The user always may. Never for a task outside the caller's own project: a grant does not open writes
/// across projects (storage §5.5).
pub fn may_edit_user_task(
    conn: &Connection,
    caller: &Caller,
    task: i64,
    now: f64,
) -> Result<bool, urdr::SqliteError> {
    if caller.class == Class::User {
        return Ok(true);
    }
    let Some(t) = entity::by_n(conn, task)? else {
        return Ok(false);
    };
    if t.kind != "task" || t.retired_tx.is_some() {
        return Ok(false);
    }
    let Some(project) = t.project.filter(|p| caller.project == Some(*p)) else {
        return Ok(false);
    };
    Ok(live(conn)?.iter().any(|g| {
        g.access == Access::EditUserTasks
            && g.active(now)
            && g.who.matches(caller)
            && match g.what {
                What::Task(n) => n == task,
                What::Project(p) => p == project,
                What::All => true,
                What::OptionsGlobal | What::OptionsProject => false,
            }
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::options;
    use crate::scope::testkit::{db, project, task, user, write};
    use urdr::graph::guard::Target;
    use urdr::graph::walk::{Scope as _, Seen};
    use urdr::graph::{TxMeta, TxState};

    const NOW: f64 = 2_000_000_000.0;

    fn agent(project: Option<i64>, sid: &str, profile: Option<&str>) -> Caller {
        Caller {
            class: Class::Agent,
            actor: format!("agent:{sid}"),
            session: Some(sid.into()),
            profile: profile.map(Into::into),
            job: None,
            project,
            backend: false,
        }
    }

    #[test]
    fn an_agent_lists_only_its_own_grants() {
        let (_d, _p, mut conn) = db();
        let (a, b, c) = (
            project(&mut conn, "a"),
            project(&mut conn, "b"),
            project(&mut conn, "c"),
        );
        let made: Vec<Grant> = [
            (Who::Project(a), What::Project(b)),
            (Who::Profile("review".into()), What::All),
            (Who::Session("s9".into()), What::Project(b)),
            (Who::Project(c), What::Project(a)),
        ]
        .into_iter()
        .map(|(who, what)| {
            write(&mut conn, user(), |tx| {
                create(tx, who, what, Access::Read, None)
            })
            .unwrap()
        })
        .collect();
        let me = agent(Some(a), "s1", Some("review"));
        let seen: Vec<String> = list(&conn, &me, &Filter::default(), NOW)
            .unwrap()
            .into_iter()
            .map(|g| g.id)
            .collect();
        assert_eq!(seen, [made[0].id.clone(), made[1].id.clone()]);
        // The user sees them all; a filter narrows.
        assert_eq!(
            list(&conn, &Caller::user(false), &Filter::default(), NOW)
                .unwrap()
                .len(),
            4
        );
        let only = Filter {
            who: Some(Who::Project(c)),
            active: Some(true),
        };
        assert_eq!(
            list(&conn, &Caller::user(false), &only, NOW).unwrap()[0].id,
            made[3].id
        );
        // An agent asking for another's grants by filter gets nothing.
        assert!(list(&conn, &me, &only, NOW).unwrap().is_empty());
        // Revoked ones are listed as inactive.
        write(&mut conn, user(), |tx| revoke(tx, &made[0].id)).unwrap();
        let inactive = Filter {
            who: None,
            active: Some(false),
        };
        let gone = list(&conn, &me, &inactive, NOW).unwrap();
        assert_eq!(gone.len(), 1);
        assert_eq!(gone[0].status, "revoked");
    }

    #[test]
    fn an_agent_cannot_write_a_setting() {
        let mut g = Guard::default();
        register(&mut g);
        for class in [Class::Agent, Class::Ext, Class::System] {
            let meta = TxMeta::new("x", class, "test");
            assert_eq!(
                guard::check_key(&g, &meta, "setting:only-user-closes"),
                Err(WriteError::Refused(SETTINGS_ARE_THE_USERS.into()))
            );
            assert_eq!(guard::check_key(&g, &meta, "seen:agent:s1"), Ok(()));
        }
        assert_eq!(
            guard::check_key(&g, &user(), "setting:only-user-closes"),
            Ok(())
        );
    }

    /// Every way a write of kind `grant` (or a `setting:` key) reaches the store, from every class: only `User`
    /// passes. Task 14 adds `task_write` and `note_add` with `kind: "grant"`; Task 15a the `put-parsed` row form.
    #[test]
    fn every_agent_reachable_write_is_refused() {
        let (_d, _p, mut conn) = db();
        let (a, b) = (project(&mut conn, "a"), project(&mut conn, "b"));
        let existing = write(&mut conn, user(), |tx| {
            create(tx, Who::Project(a), What::Project(b), Access::Read, None)
        })
        .unwrap();

        let proposed = |class| {
            let mut m = TxMeta::new("agent:s1", class, "mcp:task_write/create");
            m.state = TxState::Proposed;
            m
        };
        let metas: Vec<(&str, TxMeta, Origin)> = vec![
            (
                "agent",
                TxMeta::new("agent:s1", Class::Agent, "mcp:task_write/create"),
                Origin::Recorded,
            ),
            (
                "ext",
                TxMeta::new("ext:claude:1-ab", Class::Ext, "mcp:note_add"),
                Origin::Recorded,
            ),
            (
                "hub",
                TxMeta::new("hub", Class::System, "proto:coord/x"),
                Origin::Recorded,
            ),
            ("proposed agent", proposed(Class::Agent), Origin::Recorded),
            ("proposed ext", proposed(Class::Ext), Origin::Recorded),
            (
                "import",
                TxMeta::new("import", Class::System, "import"),
                Origin::Imported,
            ),
            (
                "put-parsed",
                TxMeta::new("scan:/w/a", Class::System, "scan"),
                Origin::Parsed,
            ),
            ("user", user(), Origin::Recorded),
            ("proposed user", proposed(Class::User), Origin::Recorded),
        ];
        let raw = move |origin: Origin, i: usize| EntityNew {
            id: format!("grant:forged{i}"),
            kind: "grant".into(),
            project: None,
            title: Some("forged".into()),
            status: Some("active".into()),
            body: None,
            priority: None,
            assignee: None,
            data: json!({"who": {"project": a}, "what": "*", "access": "read"}),
            origin,
            source: None,
        };
        type Op = Box<dyn Fn(&mut Tx<'_>, Origin, usize) -> Result<(), WriteError>>;
        let (gn, gid) = (existing.n, existing.id.clone());
        let ops: Vec<(&str, Op)> = vec![
            (
                "entity::create",
                Box::new(move |tx: &mut Tx<'_>, o: Origin, i: usize| {
                    entity::create(tx, raw(o, i)).map(drop)
                }),
            ),
            (
                "grants::create",
                Box::new(move |tx: &mut Tx<'_>, _: Origin, _: usize| {
                    create(tx, Who::Project(a), What::All, Access::Read, None).map(drop)
                }),
            ),
            (
                "grants::create_options",
                Box::new(move |tx: &mut Tx<'_>, _: Origin, _: usize| {
                    create_options(tx, Who::Project(a), What::OptionsGlobal, None, None).map(drop)
                }),
            ),
            (
                "entity::update",
                Box::new(move |tx: &mut Tx<'_>, _: Origin, _: usize| {
                    entity::update(
                        tx,
                        gn,
                        None,
                        Changes {
                            data_patch: Some(json!({"what": "*"})),
                            ..Changes::default()
                        },
                    )
                    .map(drop)
                }),
            ),
            (
                "grants::revoke",
                Box::new(move |tx: &mut Tx<'_>, _: Origin, _: usize| revoke(tx, &gid).map(drop)),
            ),
            (
                "entity::retire",
                Box::new(move |tx: &mut Tx<'_>, _: Origin, _: usize| entity::retire(tx, gn)),
            ),
            (
                "kv setting:",
                Box::new(|tx: &mut Tx<'_>, _: Origin, _: usize| {
                    guard::check_key(tx.guard(), tx.meta(), "setting:only-user-closes")
                }),
            ),
        ];
        let mut i = 0;
        for (who, meta, origin) in &metas {
            for (what, op) in &ops {
                i += 1;
                let got = {
                    let mut tx =
                        Tx::for_test(&mut conn, meta.clone(), crate::scope::testkit::guard());
                    op(&mut tx, *origin, i)
                    // Dropped: rolled back, so every case starts from the same rows.
                };
                if meta.class == Class::User {
                    assert_eq!(got, Ok(()), "{who}: {what}");
                } else {
                    let want = if *what == "kv setting:" {
                        SETTINGS_ARE_THE_USERS
                    } else {
                        GRANTS_ARE_THE_USERS
                    };
                    assert_eq!(got, Err(WriteError::Refused(want.into())), "{who}: {what}");
                }
            }
        }
        // Nothing forged reached the rows.
        assert_eq!(
            list(&conn, &Caller::user(false), &Filter::default(), NOW).unwrap(),
            [existing]
        );

        // Kind `option` (Urdr Task 10b): the user writes any well-formed id; an agent only under a matching
        // `options` grant, never a deny-listed name; every other class never.
        let (pa, pb) = (bare(&conn, a), bare(&conn, b));
        let ids = [
            "option:global:fill-column".to_string(),
            format!("option:private/{pa}:fill-column"),
        ];
        let mine = write(&mut conn, user(), |tx| {
            entity::create(
                tx,
                option(&format!("option:shared/{pa}:tab-width"), Some(a)),
            )
        })
        .unwrap()
        .n;
        // s1: a global grant for another name; s2: a global `*` grant; s3: a project grant (its project is a);
        // s4: a project grant to project b; s5: nothing; s6: a revoked global grant; s7: a read grant to `*`;
        // the outside agent: a global grant by session.
        let grant = |conn: &mut Connection, who: Who, what: What, names: Option<&[&str]>| {
            write(conn, user(), |tx| {
                create_options(
                    tx,
                    who,
                    what,
                    names.map(|n| n.iter().map(|s| s.to_string()).collect()),
                    None,
                )
            })
            .unwrap()
        };
        grant(
            &mut conn,
            sid("s1"),
            What::OptionsGlobal,
            Some(&["tab-width"]),
        );
        grant(&mut conn, sid("s2"), What::OptionsGlobal, Some(&["*"]));
        grant(&mut conn, sid("s3"), What::OptionsProject, None);
        grant(&mut conn, Who::Project(b), What::OptionsProject, None);
        let gone = grant(&mut conn, sid("s6"), What::OptionsGlobal, None);
        write(&mut conn, user(), |tx| revoke(tx, &gone.id)).unwrap();
        write(&mut conn, user(), |tx| {
            create(tx, sid("s7"), What::All, Access::Read, None)
        })
        .unwrap();
        grant(&mut conn, sid("ext:claude:1-ab"), What::OptionsGlobal, None);

        let agent_in = |s: &str, p: Option<i64>, proposed: bool| {
            let mut m = agent(p, s, None).tx_meta("mcp:settings_change");
            if proposed {
                m.state = TxState::Proposed;
            }
            m
        };
        let mut ext = TxMeta::new("ext:claude:1-ab", Class::Ext, "mcp:settings_change");
        ext.session = Some("ext:claude:1-ab".into());
        ext.project = Some(a);
        let new_at = |id: String, p: Option<i64>| -> Op {
            Box::new(move |tx: &mut Tx<'_>, _: Origin, _: usize| {
                entity::create(tx, option(&id, p)).map(drop)
            })
        };
        let origin_at = |id: String, p: Option<i64>, origin: Origin| -> Op {
            Box::new(move |tx: &mut Tx<'_>, _: Origin, _: usize| {
                let mut e = option(&id, p);
                e.origin = origin;
                entity::create(tx, e).map(drop)
            })
        };
        let parsed_at = |id: String, p: Option<i64>| origin_at(id, p, Origin::Parsed);
        let scan = || TxMeta::new("scan:/w/a", Class::System, options::SCAN_TOOL);
        let agent_tool = |s: &str, p: Option<i64>, tool: &str| agent(p, s, None).tx_meta(tool);
        let mut ext_scan = TxMeta::new("ext:claude:1-ab", Class::Ext, options::SCAN_TOOL);
        ext_scan.project = Some(a);
        // A global setting you recorded, a task (an `n` that is no project) and a retired project.
        let global = write(&mut conn, user(), |tx| {
            entity::create(tx, option("option:global:indent-tabs-mode", None))
        })
        .unwrap()
        .n;
        let not_a_project = crate::scope::testkit::task(&mut conn, user(), a, "t");
        let r = project(&mut conn, "r");
        let pr = bare(&conn, r);
        write(&mut conn, user(), |tx| entity::retire(tx, r)).unwrap();
        let rows: Vec<(&str, TxMeta, Op, Result<(), &str>)> = vec![
            (
                "no grant: global",
                agent_in("s5", Some(a), false),
                new_at(ids[0].clone(), None),
                Err(options::NO_GRANT),
            ),
            (
                "no grant: private",
                agent_in("s5", Some(a), false),
                new_at(ids[1].clone(), Some(a)),
                Err(options::NO_GRANT),
            ),
            (
                "no grant: update",
                agent_in("s5", Some(a), false),
                Box::new(move |tx: &mut Tx<'_>, _: Origin, _: usize| {
                    let patch = Changes {
                        data_patch: Some(json!({"value": "8"})),
                        ..Changes::default()
                    };
                    entity::update(tx, mine, None, patch).map(drop)
                }),
                Err(options::NO_GRANT),
            ),
            (
                "no grant: retire",
                agent_in("s5", Some(a), false),
                Box::new(move |tx: &mut Tx<'_>, _: Origin, _: usize| entity::retire(tx, mine)),
                Err(options::NO_GRANT),
            ),
            (
                "a grant for another name",
                agent_in("s1", Some(a), false),
                new_at(ids[0].clone(), None),
                Err(options::NO_GRANT),
            ),
            (
                "a global grant is not a project grant",
                agent_in("s1", Some(a), false),
                new_at(format!("option:private/{pa}:tab-width"), Some(a)),
                Err(options::NO_GRANT),
            ),
            (
                "a grant to another project",
                agent_in("s4", Some(a), false),
                new_at(ids[1].clone(), Some(a)),
                Err(options::NO_GRANT),
            ),
            (
                "another project's settings",
                agent_in("s3", Some(a), false),
                new_at(format!("option:shared/{pb}:fill-column"), Some(b)),
                Err(options::NOT_ITS_PROJECT),
            ),
            (
                "its id under another project",
                agent_in("s3", Some(a), false),
                new_at(ids[1].clone(), Some(b)),
                Err(options::NOT_ITS_PROJECT),
            ),
            (
                "another project's id under its own project",
                agent_in("s3", Some(a), false),
                new_at(format!("option:shared/{pb}:fill-column"), Some(a)),
                Err(options::NOT_ITS_PROJECT),
            ),
            (
                "a project grant, no project",
                agent_in("s3", None, false),
                new_at(ids[1].clone(), Some(a)),
                Err(options::NOT_ITS_PROJECT),
            ),
            (
                "a root- folder",
                agent_in("s3", Some(a), false),
                new_at("option:private/root-0123456789ab:fill-column".into(), None),
                Err(options::NOT_ITS_PROJECT),
            ),
            (
                "a project grant is not a global grant",
                agent_in("s3", Some(a), false),
                new_at(ids[0].clone(), None),
                Err(options::NO_GRANT),
            ),
            (
                "a global id with a project",
                agent_in("s2", Some(a), false),
                new_at(ids[0].clone(), Some(a)),
                Err(options::NOT_ITS_PROJECT),
            ),
            (
                "deny-listed under *",
                agent_in("s2", Some(a), false),
                new_at("option:global:drgnx-agents-allow-unsandboxed".into(), None),
                Err(options::DENIED),
            ),
            (
                "deny-listed by prefix under *",
                agent_in("s2", Some(a), false),
                new_at("option:global:safe-local-variable-values".into(), None),
                Err(options::DENIED),
            ),
            (
                "deny-listed by suffix under *",
                agent_in("s2", Some(a), false),
                new_at(
                    "option:global:mode/python-mode:python-shell-interpreter".into(),
                    None,
                ),
                Err(options::DENIED),
            ),
            (
                "deny-listed in its own project",
                agent_in("s3", Some(a), false),
                new_at(
                    format!("option:shared/{pa}:dir/src/:after-save-hook"),
                    Some(a),
                ),
                Err(options::DENIED),
            ),
            (
                "a revoked grant",
                agent_in("s6", Some(a), false),
                new_at(ids[0].clone(), None),
                Err(options::NO_GRANT),
            ),
            (
                "a read grant",
                agent_in("s7", Some(a), false),
                new_at(ids[0].clone(), None),
                Err(options::NO_GRANT),
            ),
            (
                "a proposed tx, no grant",
                agent_in("s5", Some(a), true),
                new_at(ids[0].clone(), None),
                Err(options::NO_GRANT),
            ),
            (
                "a proposed tx, deny-listed",
                agent_in("s2", Some(a), true),
                new_at("option:global:load-path".into(), None),
                Err(options::DENIED),
            ),
            (
                "an outside agent with a grant",
                ext,
                new_at(ids[0].clone(), None),
                Err(options::SETTINGS_ARE_THE_USERS),
            ),
            (
                "the hub",
                TxMeta::new("hub", Class::System, "proto:coord/x"),
                new_at(ids[0].clone(), None),
                Err(options::SETTINGS_ARE_THE_USERS),
            ),
            (
                "an import",
                TxMeta::new("import", Class::System, "import"),
                new_at(ids[0].clone(), None),
                Err(options::SETTINGS_ARE_THE_USERS),
            ),
            (
                "the hub, a repository's shared id made parsed",
                TxMeta::new("hub", Class::System, "proto:coord/x"),
                parsed_at(format!("option:shared/{pa}:fill-column"), Some(a)),
                Err(options::SETTINGS_ARE_THE_USERS),
            ),
            (
                "an import, a repository's shared id made parsed",
                TxMeta::new("import", Class::System, "import"),
                parsed_at(format!("option:shared/{pa}:fill-column"), Some(a)),
                Err(options::SETTINGS_ARE_THE_USERS),
            ),
            // The scan (Task 24, the manager's ruling): a repository's shared settings only, made parsed, in the
            // repository's own project; never your global or private settings.
            (
                "put-parsed: a global id",
                scan(),
                parsed_at("option:global:fill-column".into(), None),
                Err(options::SETTINGS_ARE_THE_USERS),
            ),
            (
                "put-parsed: a global mode id",
                scan(),
                parsed_at("option:global:mode/c-mode:fill-column".into(), None),
                Err(options::SETTINGS_ARE_THE_USERS),
            ),
            (
                "put-parsed: a private id",
                scan(),
                parsed_at(format!("option:private/{pa}:fill-column"), Some(a)),
                Err(options::SETTINGS_ARE_THE_USERS),
            ),
            (
                "put-parsed: a private root- id",
                scan(),
                parsed_at("option:private/root-0123456789ab:fill-column".into(), None),
                Err(options::SETTINGS_ARE_THE_USERS),
            ),
            (
                "put-parsed: a shared id made recorded",
                scan(),
                new_at(format!("option:shared/{pa}:fill-column"), Some(a)),
                Err(options::SETTINGS_ARE_THE_USERS),
            ),
            (
                "put-parsed: a shared id made imported",
                scan(),
                origin_at(
                    format!("option:shared/{pa}:fill-column"),
                    Some(a),
                    Origin::Imported,
                ),
                Err(options::SETTINGS_ARE_THE_USERS),
            ),
            (
                "put-parsed: another project's shared id",
                scan(),
                parsed_at(format!("option:shared/{pb}:fill-column"), Some(a)),
                Err(options::NOT_THE_REPOSITORYS),
            ),
            (
                "put-parsed: its shared id under another project",
                scan(),
                parsed_at(format!("option:shared/{pa}:fill-column"), Some(b)),
                Err(options::NOT_THE_REPOSITORYS),
            ),
            (
                "put-parsed: its shared id under no project",
                scan(),
                parsed_at(format!("option:shared/{pa}:fill-column"), None),
                Err(options::NOT_THE_REPOSITORYS),
            ),
            (
                "put-parsed: a root- shared id under a project",
                scan(),
                parsed_at(
                    "option:shared/root-0123456789ab:fill-column".into(),
                    Some(a),
                ),
                Err(options::NOT_THE_REPOSITORYS),
            ),
            (
                "put-parsed: a shared id under a task, not a project",
                scan(),
                parsed_at(
                    format!("option:shared/{pa}:fill-column"),
                    Some(not_a_project),
                ),
                Err(options::NOT_THE_REPOSITORYS),
            ),
            (
                "put-parsed: a shared id of a retired project",
                scan(),
                parsed_at(format!("option:shared/{pr}:fill-column"), Some(r)),
                Err(options::NOT_THE_REPOSITORYS),
            ),
            (
                "put-parsed: a new version of a global setting",
                scan(),
                Box::new(move |tx: &mut Tx<'_>, _: Origin, _: usize| {
                    let patch = Changes {
                        data_patch: Some(json!({"value": "8"})),
                        ..Changes::default()
                    };
                    entity::update(tx, global, None, patch).map(drop)
                }),
                Err(options::SETTINGS_ARE_THE_USERS),
            ),
            (
                "put-parsed: a global setting retired",
                scan(),
                Box::new(move |tx: &mut Tx<'_>, _: Origin, _: usize| entity::retire(tx, global)),
                Err(options::SETTINGS_ARE_THE_USERS),
            ),
            (
                "put-parsed: a malformed id",
                scan(),
                parsed_at("option:shared/:x".into(), Some(a)),
                Err(""),
            ),
            (
                "an agent's tx with the scan's tool",
                agent_tool("s5", Some(a), options::SCAN_TOOL),
                parsed_at(format!("option:shared/{pa}:fill-column"), Some(a)),
                Err(options::NO_GRANT),
            ),
            (
                "an outside agent's tx with the scan's tool",
                ext_scan,
                parsed_at(format!("option:shared/{pa}:fill-column"), Some(a)),
                Err(options::SETTINGS_ARE_THE_USERS),
            ),
            (
                "control: put-parsed, its shared id",
                scan(),
                parsed_at(
                    format!("option:shared/{pa}:dir/src/:mode/c-mode:c-basic-offset"),
                    Some(a),
                ),
                Ok(()),
            ),
            (
                "control: put-parsed, a root- folder's shared id",
                scan(),
                parsed_at("option:shared/root-0123456789ab:tab-width".into(), None),
                Ok(()),
            ),
            (
                "control: put-parsed, a new version of a shared setting you recorded",
                scan(),
                Box::new(move |tx: &mut Tx<'_>, _: Origin, _: usize| {
                    let patch = Changes {
                        data_patch: Some(json!({"value": "8"})),
                        ..Changes::default()
                    };
                    entity::update(tx, mine, None, patch).map(drop)
                }),
                Ok(()),
            ),
            (
                "a malformed id, even the user's",
                user(),
                new_at("option:global:".into(), None),
                Err(""),
            ),
            // The controls: what the grants do allow, so the rows above are not refused for another reason.
            (
                "control: its name",
                agent_in("s1", Some(a), false),
                new_at("option:global:tab-width".into(), None),
                Ok(()),
            ),
            (
                "control: a proposed tx under *",
                agent_in("s2", Some(a), true),
                new_at(ids[0].clone(), None),
                Ok(()),
            ),
            (
                "control: its own project",
                agent_in("s3", Some(a), false),
                new_at(ids[1].clone(), Some(a)),
                Ok(()),
            ),
            (
                "control: the user, deny-listed",
                user(),
                new_at("option:global:load-path".into(), None),
                Ok(()),
            ),
            (
                "control: the user, anywhere",
                user(),
                new_at(format!("option:shared/{pb}:x"), Some(b)),
                Ok(()),
            ),
        ];
        for (i, (what, meta, op, want)) in rows.iter().enumerate() {
            let got = {
                let mut tx = Tx::for_test(&mut conn, meta.clone(), crate::scope::testkit::guard());
                op(&mut tx, Origin::Recorded, i)
            };
            match want {
                Ok(()) => assert_eq!(got, Ok(()), "{what}"),
                Err("") => assert!(
                    matches!(&got, Err(WriteError::Refused(t)) if t.starts_with("not an option id")),
                    "{what}: {got:?}"
                ),
                Err(text) => assert_eq!(got, Err(WriteError::Refused((*text).into())), "{what}"),
            }
        }
        // put-parsed itself: a repository's `.drgnx/settings.el` brings its shared settings in as parsed entities of
        // the repository's project; a global or private id there, or an option of any other file, refuses its source.
        conn.execute_batch(
            "create table if not exists parsed_file (path text primary key, mtime real);
             create table if not exists kv (key text primary key, value text);",
        )
        .unwrap();
        let home = _d.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let deny = crate::deny::DenyList::load(&home, &_d.path().join("config"));
        let file = "/w/a/.drgnx/settings.el";
        let opt = |id: String| json!({"id": id, "kind": "option", "data": {"value": "80", "file": file, "line": 1}});
        let shared = format!("option:shared/{pa}:fill-column");
        let req: crate::parsed::PutParsed = serde_json::from_value(json!({"sources": [
            {"source": {"kind": "file", "path": file}, "mtime": 1.0, "entities": [opt(shared.clone())]},
            {"source": {"kind": "file", "path": "/w/a/.drgnx/global.el"},
             "entities": [opt("option:global:fill-column".into())]},
            {"source": {"kind": "file", "path": "/w/b/.drgnx/settings.el"},
             "entities": [opt("option:global:tab-width".into())]},
            {"source": {"kind": "file", "path": "/w/c/.drgnx/settings.el"},
             "entities": [opt(format!("option:private/{pa}:tab-width"))]},
        ]}))
        .unwrap();
        let mut projects = crate::project::ProjectCache::default();
        projects.insert(
            "/w/a/.drgnx".into(),
            Some(crate::scope::testkit::project_ref("a")),
        );
        let answer = write(&mut conn, scan(), |tx| {
            crate::parsed::put_with(tx, &deny, &mut projects, req)
        })
        .unwrap();
        assert_eq!((answer.changed, answer.refused.len()), (1, 3));
        let e = entity::by_id(&conn, &shared).unwrap().unwrap();
        assert_eq!(
            (e.origin, e.project, e.source.as_deref()),
            (Origin::Parsed, Some(a), Some(file))
        );
        let by: (String, String, String) = conn
            .query_row(
                "select actor, class, tool from tx where id = ?1",
                [e.created_tx],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(by, ("scan:/w/a".into(), "system".into(), "scan".into()));
        let stored: Vec<String> = conn
            .prepare("select id from entity where kind = 'option' order by id")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(
            stored,
            [
                "option:global:indent-tabs-mode".to_string(),
                shared,
                format!("option:shared/{pa}:tab-width"),
            ],
            "the user's two and the repository's one"
        );
    }

    /// The guard's target for a write to the stored option ID in PROJECT.
    fn at(id: &str, project: Option<i64>) -> Target<'_> {
        Target {
            id,
            project,
            origin: None,
        }
    }

    fn sid(s: &str) -> Who {
        Who::Session(s.into())
    }

    /// Project N's id without `project:`, as option ids carry it.
    fn bare(conn: &Connection, n: i64) -> String {
        let id = entity::by_n(conn, n).unwrap().unwrap().id;
        id.strip_prefix("project:").unwrap().to_string()
    }

    /// An option entity ID in PROJECT.
    fn option(id: &str, project: Option<i64>) -> EntityNew {
        EntityNew {
            id: id.into(),
            kind: "option".into(),
            project,
            title: None,
            status: None,
            body: None,
            priority: None,
            assignee: None,
            data: json!({"value": "100", "file": "settings.el", "line": 3}),
            origin: Origin::Recorded,
            source: None,
        }
    }

    #[test]
    fn an_options_grant_allows_its_names_only() {
        let (_d, _p, mut conn) = db();
        let a = project(&mut conn, "a");
        let g = write(&mut conn, user(), |tx| {
            create_options(
                tx,
                Who::Profile("review".into()),
                What::OptionsGlobal,
                Some(vec!["fill-column".into(), "python-*".into()]),
                None,
            )
        })
        .unwrap();
        assert_eq!(g.names.as_deref().unwrap().len(), 2);
        assert_eq!(
            list(&conn, &Caller::user(false), &Filter::default(), NOW).unwrap(),
            [g]
        );
        let me = agent(Some(a), "s1", Some("review"));
        let may = |conn: &Connection, caller: &Caller, var: &str| {
            let id = format!("option:global:{var}");
            options::may_write(conn, caller, at(&id, None), NOW)
        };
        for var in ["fill-column", "python-indent-offset", "python-"] {
            assert_eq!(may(&conn, &me, var), Ok(()), "{var}");
        }
        for var in ["fill-columns", "tab-width", "cython-x"] {
            assert_eq!(
                may(&conn, &me, var),
                Err(WriteError::Refused(options::NO_GRANT.into())),
                "{var}"
            );
        }
        // Its names match, but the deny-list wins.
        assert_eq!(
            may(&conn, &me, "python-mode-hook"),
            Err(WriteError::Refused(options::DENIED.into()))
        );
        // Another profile has nothing.
        let other = agent(Some(a), "s2", Some("build"));
        assert_eq!(
            may(&conn, &other, "fill-column"),
            Err(WriteError::Refused(options::NO_GRANT.into()))
        );
        // A mode section is still the global scope.
        let id = "option:global:mode/python-mode:python-indent-offset";
        assert_eq!(options::may_write(&conn, &me, at(id, None), NOW), Ok(()));
        // An expired grant is gone (NOW lies after it).
        let soon = write(&mut conn, user(), |tx| {
            let t = tx.at() + 60.0;
            create_options(tx, sid("s3"), What::OptionsGlobal, None, Some(t))
        })
        .unwrap();
        let later = soon.expires.unwrap() + 1.0;
        let s3 = agent(Some(a), "s3", None);
        let id = "option:global:tab-width";
        assert_eq!(
            options::may_write(&conn, &s3, at(id, None), later - 61.0),
            Ok(())
        );
        assert_eq!(
            options::may_write(&conn, &s3, at(id, None), later),
            Err(WriteError::Refused(options::NO_GRANT.into()))
        );
    }

    #[test]
    fn project_grant_covers_private_and_shared() {
        let (_d, _p, mut conn) = db();
        let (a, b) = (project(&mut conn, "a"), project(&mut conn, "b"));
        let (pa, pb) = (bare(&conn, a), bare(&conn, b));
        write(&mut conn, user(), |tx| {
            create_options(tx, Who::Project(a), What::OptionsProject, None, None)
        })
        .unwrap();
        // Every agent working in project a, in any session.
        for s in ["s1", "s2"] {
            let me = agent(Some(a), s, None);
            for id in [
                format!("option:private/{pa}:fill-column"),
                format!("option:shared/{pa}:fill-column"),
                format!("option:shared/{pa}:dir/src/:mode/c-mode:c-basic-offset"),
            ] {
                let t = at(&id, Some(a));
                assert_eq!(options::may_write(&conn, &me, t, NOW), Ok(()), "{id}");
            }
            // Not project b's, not the global file.
            for (id, p, why) in [
                (
                    format!("option:shared/{pb}:fill-column"),
                    Some(b),
                    options::NOT_ITS_PROJECT,
                ),
                (
                    "option:global:fill-column".to_string(),
                    None,
                    options::NO_GRANT,
                ),
            ] {
                let t = at(&id, p);
                assert_eq!(
                    options::may_write(&conn, &me, t, NOW),
                    Err(WriteError::Refused(why.into())),
                    "{id}"
                );
            }
        }
        // An agent of project b holds nothing from a's grant, even for b's own ids.
        let them = agent(Some(b), "s9", None);
        let id = format!("option:private/{pb}:fill-column");
        assert_eq!(
            options::may_write(&conn, &them, at(&id, Some(b)), NOW),
            Err(WriteError::Refused(options::NO_GRANT.into()))
        );
        // A retired project is no project: its agents' project grants cover nothing.
        let c = project(&mut conn, "c");
        let pc = bare(&conn, c);
        write(&mut conn, user(), |tx| {
            create_options(tx, sid("s8"), What::OptionsProject, None, None)
        })
        .unwrap();
        let old = agent(Some(c), "s8", None);
        let id = format!("option:private/{pc}:fill-column");
        let t = at(&id, Some(c));
        assert_eq!(options::may_write(&conn, &old, t, NOW), Ok(()));
        write(&mut conn, user(), |tx| entity::retire(tx, c)).unwrap();
        assert_eq!(
            options::may_write(&conn, &old, t, NOW),
            Err(WriteError::Refused(options::NOT_ITS_PROJECT.into()))
        );
    }

    #[test]
    fn options_grants_are_well_formed_and_open_no_reads() {
        let (_d, _p, mut conn) = db();
        let (a, b) = (project(&mut conn, "a"), project(&mut conn, "b"));
        let bad: Vec<(What, Access, Option<Vec<String>>)> = vec![
            (What::OptionsGlobal, Access::Read, None),
            (What::OptionsProject, Access::EditUserTasks, None),
            (What::All, Access::Options, None),
            (What::Project(b), Access::Options, None),
            (What::Project(b), Access::Read, Some(vec!["x".into()])),
            (What::OptionsGlobal, Access::Options, Some(vec![])),
            (
                What::OptionsGlobal,
                Access::Options,
                Some(vec!["a/b".into()]),
            ),
            (
                What::OptionsGlobal,
                Access::Options,
                Some(vec!["a b".into()]),
            ),
            (
                What::OptionsGlobal,
                Access::Options,
                Some(vec![String::new()]),
            ),
            (
                What::OptionsGlobal,
                Access::Options,
                Some(vec!["x".into(); 65]),
            ),
        ];
        for (what, access, names) in bad {
            let label = format!("{what} {} {names:?}", access.as_str());
            let got = write(&mut conn, user(), |tx| {
                create_with(tx, Who::Project(a), what, access, names, None, None)
            });
            assert!(matches!(got, Err(WriteError::Refused(_))), "{label}");
        }
        let g = write(&mut conn, user(), |tx| {
            create_options(
                tx,
                Who::Project(a),
                What::OptionsGlobal,
                Some(vec!["*".into()]),
                None,
            )
        })
        .unwrap();
        let h = write(&mut conn, user(), |tx| {
            create_options(tx, Who::Project(a), What::OptionsProject, None, None)
        })
        .unwrap();
        let r = write(&mut conn, user(), |tx| {
            create(tx, Who::Project(b), What::Project(a), Access::Read, None)
        })
        .unwrap();
        let title = |id: &str| entity::by_id(&conn, id).unwrap().unwrap().title.unwrap();
        assert_eq!(
            title(&g.id),
            format!("project:{a} may change settings options:global (*)")
        );
        assert_eq!(
            title(&h.id),
            format!("project:{a} may change settings options:project")
        );
        assert_eq!(title(&r.id), format!("project:{b} may read project:{a}"));
        // Ids take 8 base36 digits of a hash (a 1 in 36^6 chance per id of six leading zeros).
        for id in [&g.id, &h.id, &r.id] {
            assert!(!id.starts_with("grant:000000"), "{id}");
        }
        assert_eq!(What::parse(&g.what.to_string()), Some(What::OptionsGlobal));
        assert_eq!(What::parse("options:project"), Some(What::OptionsProject));
        assert_eq!(Access::parse("options"), Some(Access::Options));
        // A row that does not fit opens nothing: an options access on a project, names on a read grant.
        for (i, data) in [
            json!({"who": {"project": a}, "what": {"project": b}, "access": "options"}),
            json!({"who": {"project": a}, "what": {"project": b}, "access": "read", "names": ["x"]}),
            json!({"who": {"project": a}, "what": "options:global", "access": "options", "names": ["a/b"]}),
            json!({"who": {"project": a}, "what": "options:global", "access": "options", "names": "x"}),
        ]
        .into_iter()
        .enumerate()
        {
            assert_eq!(parse(i as i64, "grant:x".into(), Some("active".into()), &data.to_string()), None);
        }
        // An options grant reads nothing: the agent's scope is still its own project.
        let me = agent(Some(a), "s1", None);
        let scope = crate::scope::for_caller(&conn, &me, NOW).unwrap();
        assert_eq!(scope.allows(Some(b)), Seen::Hidden);
        assert_eq!(scope.allows(Some(a)), Seen::Full);
    }

    #[test]
    fn a_read_grant_names_a_project() {
        let (_d, _p, mut conn) = db();
        let a = project(&mut conn, "a");
        let t = task(&mut conn, user(), a, "one");
        let err = write(&mut conn, user(), |tx| {
            create(tx, Who::Project(a), What::Task(t), Access::Read, None)
        });
        assert!(matches!(err, Err(WriteError::Refused(_))));
        for (who, what) in [
            (Who::Project(a + 100), What::Project(a)),
            (Who::Project(a), What::Project(t)),
            (Who::Profile(" ".into()), What::All),
        ] {
            let err = write(&mut conn, user(), |tx| {
                create(tx, who, what, Access::Read, None)
            });
            assert!(matches!(err, Err(WriteError::Refused(_))));
        }
        let past = write(&mut conn, user(), |tx| {
            create(tx, Who::Project(a), What::All, Access::Read, Some(1.0))
        });
        assert!(matches!(past, Err(WriteError::Refused(_))));
        assert_eq!(
            Who::parse("profile:review"),
            Some(Who::Profile("review".into()))
        );
        assert_eq!(
            Who::parse(&Who::Project(4).to_string()),
            Some(Who::Project(4))
        );
        assert_eq!(What::parse("*"), Some(What::All));
        assert_eq!(What::parse("task:9"), Some(What::Task(9)));
        assert_eq!(Who::parse("everyone"), None);
    }

    #[test]
    fn edit_grants_open_a_task_or_a_project_never_another_project() {
        let (_d, _p, mut conn) = db();
        let (a, b) = (project(&mut conn, "a"), project(&mut conn, "b"));
        let t1 = task(&mut conn, user(), a, "one");
        let t2 = task(&mut conn, user(), a, "two");
        let tb = task(&mut conn, user(), b, "three");
        let me = agent(Some(a), "s1", None);
        assert!(!may_edit_user_task(&conn, &me, t1, NOW).unwrap());
        write(&mut conn, user(), |tx| {
            create(
                tx,
                Who::Session("s1".into()),
                What::Task(t1),
                Access::EditUserTasks,
                None,
            )
        })
        .unwrap();
        assert!(may_edit_user_task(&conn, &me, t1, NOW).unwrap());
        assert!(!may_edit_user_task(&conn, &me, t2, NOW).unwrap());
        // A read grant is not an edit grant.
        write(&mut conn, user(), |tx| {
            create(tx, Who::Project(a), What::Project(a), Access::Read, None)
        })
        .unwrap();
        assert!(!may_edit_user_task(&conn, &me, t2, NOW).unwrap());
        write(&mut conn, user(), |tx| {
            create(tx, Who::Project(a), What::All, Access::EditUserTasks, None)
        })
        .unwrap();
        assert!(may_edit_user_task(&conn, &me, t2, NOW).unwrap());
        // `*` still never reaches a task of another project.
        assert!(!may_edit_user_task(&conn, &me, tb, NOW).unwrap());
        assert!(may_edit_user_task(&conn, &Caller::user(false), tb, NOW).unwrap());
    }
}
