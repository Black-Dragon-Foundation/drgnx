//! Grants (Task 10; storage §5.5, §12.2 answers 1–2): only the user writes them, checked in urdr's write path
//! ([`register`] puts norn's rules into the [`Guard`]: kind `grant` and `kv` keys `setting:*` need `Class::User`).
//!
//! A grant is an entity of kind `grant` (id `grant:<8 base36>`, no project), `status` `active` or `revoked`, `data`
//! `{"who": {"project": N} | {"profile": NAME} | {"session": SID}, "what": {"project": N} | "*" | {"task": N},
//! "access": "read" | "edit-user-tasks", "expires"?: unix seconds}`. A row that does not parse as one is ignored
//! (it opens nothing).

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
}

impl What {
    /// `project:N`, `*` or `task:N`.
    pub fn parse(text: &str) -> Option<What> {
        if text == "*" {
            return Some(What::All);
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
        }
    }

    fn from_json(v: &Value) -> Option<What> {
        if v.as_str() == Some("*") {
            return Some(What::All);
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
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Access {
    Read,
    EditUserTasks,
}

impl Access {
    /// `read` or `edit-user-tasks`.
    pub fn as_str(self) -> &'static str {
        match self {
            Access::Read => "read",
            Access::EditUserTasks => "edit-user-tasks",
        }
    }

    pub fn parse(text: &str) -> Option<Access> {
        match text {
            "read" => Some(Access::Read),
            "edit-user-tasks" => Some(Access::EditUserTasks),
            _ => None,
        }
    }
}

/// A grant entity.
#[derive(Clone, Debug, PartialEq)]
pub struct Grant {
    pub n: i64,
    pub id: String,
    pub who: Who,
    pub what: What,
    pub access: Access,
    pub expires: Option<f64>,
    /// `active` or `revoked`.
    pub status: String,
}

impl Grant {
    /// `active` and not expired at NOW.
    pub fn active(&self, now: f64) -> bool {
        self.status == "active" && self.expires.is_none_or(|t| t > now)
    }
}

/// Which grants [`list`] answers.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Filter {
    pub who: Option<Who>,
    pub active: Option<bool>,
}

/// Put norn's class rules into GUARD: entities of kind `grant` and `kv` keys `setting:*` and `privacy:*` are the
/// user's.
pub fn register(guard: &mut Guard) {
    guard::register(guard, "grant", Class::User, GRANTS_ARE_THE_USERS);
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
    Some(Grant {
        n,
        id,
        who: Who::from_json(data.get("who")?)?,
        what: What::from_json(data.get("what")?)?,
        access: Access::parse(data.get("access")?.as_str()?)?,
        expires,
        status: status?,
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
    guard::check(tx.guard(), tx.meta(), "grant")?;
    if access == Access::Read && matches!(what, What::Task(_)) {
        return Err(refused("a read grant opens a project or every project (*)"));
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
        What::All => {}
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
            title: Some(format!("{who} may {} {what}", access.as_str())),
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
        expires,
        status: "active".into(),
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
            }
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scope::testkit::{db, project, task, user, write};
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
