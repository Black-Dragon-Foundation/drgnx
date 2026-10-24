//! Who reads what (Task 10, Opus: the scope's root of trust; storage §5.5). The class and the project come from the
//! connection's identity, never from an argument; an agent's scope is its project plus the user's active grants,
//! computed per call.

use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use urdr::Connection;
use urdr::graph::walk::{Scope, Seen};
use urdr::graph::{Class, TxMeta};

use crate::grants::{self, Access, What};
use crate::project::ProjectCache;
use crate::tools::Identity;

/// The caller of a store operation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Caller {
    pub class: Class,
    /// The `tx.actor` it writes as.
    pub actor: String,
    pub session: Option<String>,
    pub profile: Option<String>,
    pub job: Option<String>,
    /// The entity `n` of its project.
    pub project: Option<i64>,
    /// The Lisp backend's connection (`Caller.backend` of the dispatcher).
    pub backend: bool,
}

impl Caller {
    /// From a tool connection's identity, the project through CACHE (filled outside any write transaction, so this
    /// runs no git and reads no file):
    /// - a session drgnx runs (a job's agent included: its cwd is the job's worktree, which shares the repository's
    ///   project): class `agent`, actor `agent:<sid>`, its sid, profile and job, the project of its `home`;
    /// - an outside agent: class `ext`, actor and session its `ext:KIND:PID-HASH` name, the project of the cwd its
    ///   bridge reported, no profile (grants to it are by project or by session);
    /// - no identity: class `ext`, nothing else (an empty scope).
    ///
    /// A folder the cache has not resolved, or whose project is not registered yet, gives no project. Never the user
    /// class, never `backend`.
    pub fn from_identity(identity: &Identity, cache: &ProjectCache) -> Caller {
        match identity {
            Identity::Session {
                sid,
                profile,
                job,
                home,
                ..
            } => Caller {
                class: Class::Agent,
                actor: format!("agent:{sid}"),
                session: Some(sid.clone()),
                profile: profile.clone(),
                job: job.clone(),
                project: cache.project_n(home),
                backend: false,
            },
            Identity::Outside { id, home, .. } => Caller {
                class: Class::Ext,
                actor: id.clone(),
                session: Some(id.clone()),
                profile: None,
                job: None,
                project: home.as_deref().and_then(|h| cache.project_n(h)),
                backend: false,
            },
            Identity::None => Caller {
                class: Class::Ext,
                actor: "ext:unknown".into(),
                session: None,
                profile: None,
                job: None,
                project: None,
                backend: false,
            },
        }
    }

    /// A proven user connection (the editor, the CLI); BACKEND for the Lisp backend's connection, which may not
    /// settle what would create a grant or close a task (storage §5.5).
    pub fn user(backend: bool) -> Caller {
        Caller {
            class: Class::User,
            actor: "user".into(),
            session: None,
            profile: None,
            job: None,
            project: None,
            backend,
        }
    }

    /// The `tx` row of a write by this caller through TOOL.
    pub fn tx_meta(&self, tool: impl Into<String>) -> TxMeta {
        let mut meta = TxMeta::new(self.actor.clone(), self.class, tool);
        meta.session = self.session.clone();
        meta.profile = self.profile.clone();
        meta.job = self.job.clone();
        meta.project = self.project;
        meta
    }

    /// Whether this caller may write into PROJECT: the user (and the hub) anywhere; an agent only into its own
    /// project (a grant is read-only), and nowhere without one.
    pub fn may_write_into(&self, project: Option<i64>) -> bool {
        match self.class {
            Class::User | Class::System => true,
            Class::Agent | Class::Ext => self.project.is_some() && project == self.project,
        }
    }
}

/// Grant changes seen in one database: scopes computed before a change stop being [`Scope::valid`] without a read.
#[derive(Debug, Default)]
struct Watch {
    /// Bumped on every grant change seen.
    epoch: AtomicU64,
    /// The highest grants `updated_tx` a [`for_caller`] has read.
    seen_tx: AtomicI64,
}

/// The watch of CONN's database file (one per file, for the process's life).
fn watch_of(conn: &Connection) -> Arc<Watch> {
    static WATCHES: OnceLock<Mutex<HashMap<String, Arc<Watch>>>> = OnceLock::new();
    let key = conn.path().unwrap_or_default().to_string();
    let mut map = WATCHES
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    map.entry(key).or_default().clone()
}

/// A grant of CONN's database changed: every scope computed on it before now stops being valid, so a running walk
/// stops at its next level. `grants::{create, revoke}` call it inside their tx; any other writer of kind `grant`
/// should too. A change by a path that does not is still seen by the next [`for_caller`] on that database (it
/// compares the grants' `updated_tx`), and a new scope is always computed from the rows.
pub fn grants_changed(conn: &Connection) {
    watch_of(conn).epoch.fetch_add(1, Ordering::SeqCst);
}

/// What a scope reaches.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reach<'a> {
    /// The user's (and the hub's): every entity.
    Everything,
    /// A `*` grant: every project; entities without one are stubs.
    AnyProject,
    /// These projects (empty: none); entities without one are stubs.
    Projects(&'a [i64]),
}

/// A caller's scope at one moment.
#[derive(Clone, Debug)]
pub struct StoreScope {
    /// `None`: everything (user class).
    projects: Option<Vec<i64>>,
    /// The grant rows' max `updated_tx` when computed.
    grants_tx: i64,
    /// A `*` read grant is active.
    star: bool,
    /// The earliest expiry of the grants it holds.
    expires: Option<f64>,
    /// The watch's generation when computed (`None`: everything, valid until dropped).
    watch: Option<(Arc<Watch>, u64)>,
}

impl StoreScope {
    /// What it reaches, for queries that filter by project.
    pub fn reach(&self) -> Reach<'_> {
        match &self.projects {
            None => Reach::Everything,
            Some(_) if self.star => Reach::AnyProject,
            Some(p) => Reach::Projects(p),
        }
    }

    /// The grants' max `updated_tx` it was computed at.
    pub fn grants_tx(&self) -> i64 {
        self.grants_tx
    }
}

fn now_secs() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

impl Scope for StoreScope {
    fn allows(&self, project: Option<i64>) -> Seen {
        let Some(projects) = &self.projects else {
            return Seen::Full;
        };
        match project {
            None => Seen::Stub,
            Some(_) if self.star => Seen::Full,
            Some(p) if projects.contains(&p) => Seen::Full,
            Some(_) => Seen::Hidden,
        }
    }

    /// Cheap and never blocking (walks call it from async code): false once a grant changed since the scope was
    /// computed, or once a grant it holds expired.
    fn valid(&self) -> bool {
        let Some((watch, epoch)) = &self.watch else {
            return true;
        };
        if self.expires.is_some_and(|t| now_secs() >= t) {
            return false;
        }
        watch.epoch.load(Ordering::SeqCst) == *epoch
    }
}

/// CALLER's scope now: user class (and the hub) everything; agent and ext their project plus the projects of the
/// active `read` grants whose `who` is the caller's project, profile or session. Computed from the rows on every
/// call, never cached.
pub fn for_caller(
    conn: &Connection,
    caller: &Caller,
    now: f64,
) -> Result<StoreScope, urdr::SqliteError> {
    if matches!(caller.class, Class::User | Class::System) {
        return Ok(StoreScope {
            projects: None,
            grants_tx: grants::grants_tx(conn)?,
            star: false,
            expires: None,
            watch: None,
        });
    }
    // The grants' version first, then the grants: a change between the two makes the scope fresher, never stale.
    let watch = watch_of(conn);
    let grants_tx = grants::grants_tx(conn)?;
    if watch.seen_tx.fetch_max(grants_tx, Ordering::SeqCst) < grants_tx {
        watch.epoch.fetch_add(1, Ordering::SeqCst);
    }
    let epoch = watch.epoch.load(Ordering::SeqCst);
    let mut projects: Vec<i64> = caller.project.into_iter().collect();
    let mut star = false;
    let mut expires: Option<f64> = None;
    for g in grants::live(conn)? {
        if g.access != Access::Read || !g.active(now) || !g.who.matches(caller) {
            continue;
        }
        match g.what {
            What::Project(p) => {
                if !projects.contains(&p) {
                    projects.push(p);
                }
            }
            What::All => star = true,
            What::Task(_) | What::OptionsGlobal | What::OptionsProject => continue,
        }
        if let Some(t) = g.expires {
            expires = Some(expires.map_or(t, |e: f64| e.min(t)));
        }
    }
    projects.sort_unstable();
    Ok(StoreScope {
        projects: Some(projects),
        grants_tx,
        star,
        expires,
        watch: Some((watch, epoch)),
    })
}

#[cfg(test)]
pub(crate) mod testkit {
    //! Fixtures for the policy's tests: a schema-7 file in a temp folder, the guard with norn's rules, writes
    //! through the primitives with `Tx::for_test`.
    use std::path::PathBuf;
    use std::sync::Arc;

    use serde_json::json;
    use sha1::{Digest, Sha1};
    use urdr::Connection;
    use urdr::graph::entity::{self, EntityNew, Origin};
    use urdr::graph::guard::Guard;
    use urdr::graph::schema::GRAPH_DDL;
    use urdr::graph::{Class, Tx, TxMeta, WriteError};

    use crate::project::{self, ProjectRef};

    pub(crate) fn guard() -> Arc<Guard> {
        let mut g = Guard::default();
        crate::grants::register(&mut g);
        Arc::new(g)
    }

    /// A fresh schema-7 file (its folder, its path, a connection).
    pub(crate) fn db() -> (tempfile::TempDir, PathBuf, Connection) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("work.db");
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(GRAPH_DDL).unwrap();
        (dir, path, conn)
    }

    /// F in a tx of META, committed when it answers `Ok`.
    pub(crate) fn write<R>(
        conn: &mut Connection,
        meta: TxMeta,
        f: impl FnOnce(&mut Tx<'_>) -> Result<R, WriteError>,
    ) -> Result<R, WriteError> {
        let mut tx = Tx::for_test(conn, meta, guard());
        let r = f(&mut tx);
        if r.is_ok() {
            tx.commit_for_test().unwrap();
        }
        r
    }

    pub(crate) fn user() -> TxMeta {
        TxMeta::new("user", Class::User, "test")
    }

    /// The project SLUG (a made-up root commit), registered: its `n`.
    pub(crate) fn project(conn: &mut Connection, slug: &str) -> i64 {
        let sha: String = Sha1::digest(slug.as_bytes())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let root = ProjectRef {
            id: format!("project:{}", &sha[..12]),
            root: PathBuf::from("/nowhere").join(slug),
            slug: slug.into(),
            root_commit: Some(sha.clone()),
            roots: vec![sha],
        };
        write(conn, TxMeta::new("hub", Class::System, "test"), |tx| {
            project::register(tx, &root)
        })
        .unwrap()
    }

    /// A task TITLE in PROJECT written by META's class: its `n`.
    pub(crate) fn task(conn: &mut Connection, meta: TxMeta, project: i64, title: &str) -> i64 {
        write(conn, meta, |tx| {
            entity::create(
                tx,
                EntityNew {
                    id: format!("task:t-{title}"),
                    kind: "task".into(),
                    project: Some(project),
                    title: Some(title.into()),
                    status: Some("open".into()),
                    body: None,
                    priority: None,
                    assignee: None,
                    data: json!({}),
                    origin: Origin::Recorded,
                    source: None,
                },
            )
        })
        .unwrap()
        .n
    }
}

#[cfg(test)]
mod tests {
    use super::testkit::{db, project, user, write};
    use super::*;
    use crate::grants::{self, Who};
    use crate::project::ProjectRef;
    use std::path::PathBuf;

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

    fn grant(conn: &mut Connection, who: Who, what: What, expires: Option<f64>) -> String {
        write(conn, user(), |tx| {
            grants::create(tx, who, what, Access::Read, expires)
        })
        .unwrap()
        .id
    }

    #[test]
    fn own_project_only() {
        let (_d, _p, mut conn) = db();
        let (a, b) = (project(&mut conn, "a"), project(&mut conn, "b"));
        let s = for_caller(&conn, &agent(Some(a), "s1", None), NOW).unwrap();
        assert_eq!(s.allows(Some(a)), Seen::Full);
        assert_eq!(s.allows(Some(b)), Seen::Hidden);
        assert_eq!(s.allows(None), Seen::Stub);
        assert_eq!(s.reach(), Reach::Projects(&[a]));
        assert!(s.valid());
        // The user (and the hub) see everything.
        let u = for_caller(&conn, &Caller::user(false), NOW).unwrap();
        assert_eq!(u.allows(Some(b)), Seen::Full);
        assert_eq!(u.allows(None), Seen::Full);
        assert_eq!(u.reach(), Reach::Everything);
    }

    #[test]
    fn a_project_grant_adds_one() {
        let (_d, _p, mut conn) = db();
        let (a, b, c) = (
            project(&mut conn, "a"),
            project(&mut conn, "b"),
            project(&mut conn, "c"),
        );
        grant(&mut conn, Who::Project(a), What::Project(b), None);
        let s = for_caller(&conn, &agent(Some(a), "s1", None), NOW).unwrap();
        assert_eq!(s.allows(Some(b)), Seen::Full);
        assert_eq!(s.allows(Some(c)), Seen::Hidden);
        // Not the other way round.
        let s = for_caller(&conn, &agent(Some(b), "s2", None), NOW).unwrap();
        assert_eq!(s.allows(Some(a)), Seen::Hidden);
    }

    #[test]
    fn a_profile_grant_to_star_is_all() {
        let (_d, _p, mut conn) = db();
        let (a, c) = (project(&mut conn, "a"), project(&mut conn, "c"));
        grant(&mut conn, Who::Profile("review".into()), What::All, None);
        let s = for_caller(&conn, &agent(Some(a), "s1", Some("review")), NOW).unwrap();
        assert_eq!(s.allows(Some(c)), Seen::Full);
        assert_eq!(s.allows(Some(999)), Seen::Full, "future projects too");
        assert_eq!(s.allows(None), Seen::Stub);
        assert_eq!(s.reach(), Reach::AnyProject);
        let other = for_caller(&conn, &agent(Some(a), "s2", Some("build")), NOW).unwrap();
        assert_eq!(other.allows(Some(c)), Seen::Hidden);
        // A profile grant reaches a session without a project too.
        let s = for_caller(&conn, &agent(None, "s3", Some("review")), NOW).unwrap();
        assert_eq!(s.allows(Some(c)), Seen::Full);
    }

    #[test]
    fn a_session_grant_ends_with_the_session() {
        let (_d, _p, mut conn) = db();
        let (a, b) = (project(&mut conn, "a"), project(&mut conn, "b"));
        grant(&mut conn, Who::Session("s1".into()), What::Project(b), None);
        let s = for_caller(&conn, &agent(Some(a), "s1", None), NOW).unwrap();
        assert_eq!(s.allows(Some(b)), Seen::Full);
        // The next session in the same project and profile does not have it.
        let next = for_caller(&conn, &agent(Some(a), "s2", None), NOW).unwrap();
        assert_eq!(next.allows(Some(b)), Seen::Hidden);
    }

    #[test]
    fn an_expired_grant_is_gone() {
        let (_d, _p, mut conn) = db();
        let (a, b) = (project(&mut conn, "a"), project(&mut conn, "b"));
        let soon = now_secs() + 3600.0;
        grant(&mut conn, Who::Project(a), What::Project(b), Some(soon));
        let caller = agent(Some(a), "s1", None);
        let s = for_caller(&conn, &caller, soon - 1.0).unwrap();
        assert_eq!(s.allows(Some(b)), Seen::Full);
        assert!(s.valid());
        let s = for_caller(&conn, &caller, soon).unwrap();
        assert_eq!(s.allows(Some(b)), Seen::Hidden);
        // A scope holding a grant that has expired is no longer valid.
        let held = StoreScope {
            expires: Some(now_secs() - 1.0),
            ..for_caller(&conn, &caller, soon - 1.0).unwrap()
        };
        assert!(!held.valid());
    }

    /// A grant is gone at its exact expiry, whatever the time's digits (URDR-SCOPE-GRANT-FLAKE-1). The expiry
    /// round-trips through JSON text in the grant's data. serde_json's default parser reads a 17-digit number as
    /// `significand as f64 / 10^k`, rounding twice, and reads these three clock-shaped times back one ulp high, so a
    /// grant is still active at its expiry: `an_expired_grant_is_gone` saw Full when `now + 3600` was such a time. The
    /// workspace's `float_roundtrip` reads them back exactly. The grants are written as entities directly:
    /// `grants::create` takes only an expiry after the tx's (today's) time.
    #[test]
    fn a_grant_is_gone_at_its_exact_expiry() {
        use serde_json::json;
        use urdr::graph::entity::{self, EntityNew, Origin};
        let (_d, _p, mut conn) = db();
        let (a, b) = (project(&mut conn, "a"), project(&mut conn, "b"));
        let caller = agent(Some(a), "s1", None);
        // ascending: at each one's expiry the earlier grants have expired too
        let times = [
            1_792_798_094.123_477_5,
            1_792_798_094.123_534_7,
            1_792_798_094.123_560_7,
        ];
        for (i, t) in times.into_iter().enumerate() {
            write(&mut conn, user(), |tx| {
                entity::create(
                    tx,
                    EntityNew {
                        id: format!("grant:t{i}"),
                        kind: "grant".into(),
                        project: None,
                        title: None,
                        status: Some("active".into()),
                        body: None,
                        priority: None,
                        assignee: None,
                        data: json!({"who": {"project": a}, "what": {"project": b}, "access": "read",
                                     "expires": t}),
                        origin: Origin::Recorded,
                        source: None,
                    },
                )
            })
            .unwrap();
            let before = for_caller(&conn, &caller, t - 1.0).unwrap();
            assert_eq!(before.allows(Some(b)), Seen::Full, "{t}");
            let at = for_caller(&conn, &caller, t).unwrap();
            assert_eq!(at.allows(Some(b)), Seen::Hidden, "{t}");
        }
    }

    #[test]
    fn revoke_is_seen_on_the_next_call() {
        let (_d, _p, mut conn) = db();
        let (a, b) = (project(&mut conn, "a"), project(&mut conn, "b"));
        let id = grant(&mut conn, Who::Project(a), What::Project(b), None);
        let caller = agent(Some(a), "s1", None);
        assert_eq!(
            for_caller(&conn, &caller, NOW).unwrap().allows(Some(b)),
            Seen::Full
        );
        assert!(write(&mut conn, user(), |tx| grants::revoke(tx, &id)).unwrap());
        assert_eq!(
            for_caller(&conn, &caller, NOW).unwrap().allows(Some(b)),
            Seen::Hidden
        );
        // A second revoke finds no active grant.
        assert!(!write(&mut conn, user(), |tx| grants::revoke(tx, &id)).unwrap());
    }

    #[test]
    fn no_project_means_empty() {
        let (_d, _p, mut conn) = db();
        let a = project(&mut conn, "a");
        let caller = agent(None, "s1", None);
        let s = for_caller(&conn, &caller, NOW).unwrap();
        assert_eq!(s.reach(), Reach::Projects(&[]));
        assert_eq!(s.allows(Some(a)), Seen::Hidden);
        assert_eq!(s.allows(None), Seen::Stub);
        assert!(!caller.may_write_into(Some(a)));
        assert!(!caller.may_write_into(None));
        // With a project: its own only.
        let own = agent(Some(a), "s2", None);
        assert!(own.may_write_into(Some(a)));
        assert!(!own.may_write_into(Some(a + 1)));
        assert!(!own.may_write_into(None));
        assert!(Caller::user(false).may_write_into(Some(a)));
    }

    #[test]
    fn valid_turns_false_on_a_grant_change() {
        let (_d, _p, mut conn) = db();
        let (a, b, c) = (
            project(&mut conn, "a"),
            project(&mut conn, "b"),
            project(&mut conn, "c"),
        );
        let caller = agent(Some(a), "s1", None);
        let s = for_caller(&conn, &caller, NOW).unwrap();
        assert!(s.valid());
        // A grant to someone else changes the grant rows too.
        grant(&mut conn, Who::Project(c), What::Project(b), None);
        assert!(!s.valid());
        let s = for_caller(&conn, &caller, NOW).unwrap();
        assert!(s.valid());
        // A change through a path that does not call `grants_changed` (a user-class update of the row) is seen by
        // the next scope computed on the database, which ends the older ones.
        let n = grants::list(&conn, &Caller::user(false), &Default::default(), NOW).unwrap()[0].n;
        write(&mut conn, user(), |tx| {
            urdr::graph::entity::update(
                tx,
                n,
                None,
                urdr::graph::entity::Changes {
                    status: Some(Some("revoked".into())),
                    ..Default::default()
                },
            )
        })
        .unwrap();
        assert!(s.valid(), "not seen before anything reads the rows");
        let fresh = for_caller(&conn, &agent(Some(c), "s9", None), NOW).unwrap();
        assert!(!s.valid());
        assert!(fresh.valid());
        assert_eq!(fresh.allows(Some(b)), Seen::Hidden);
        // The user's scope does not depend on grants.
        let u = for_caller(&conn, &Caller::user(false), NOW).unwrap();
        grant(&mut conn, Who::Project(a), What::Project(c), None);
        assert!(u.valid());
    }

    fn cache_with(dir: &str, n: i64) -> ProjectCache {
        let mut cache = ProjectCache::default();
        let p = ProjectRef {
            id: "project:0123456789ab".into(),
            root: PathBuf::from(dir),
            slug: "proj".into(),
            root_commit: Some("0123456789ab0123456789ab0123456789ab0123".into()),
            roots: vec!["0123456789ab0123456789ab0123456789ab0123".into()],
        };
        cache.insert(PathBuf::from(dir), Some(p));
        cache.set_registered("project:0123456789ab", n);
        cache
    }

    #[test]
    fn caller_from_a_session_has_sid_and_profile() {
        let cache = cache_with("/w/proj", 42);
        let id = Identity::Session {
            agent: "claude".into(),
            sid: "s-81f2".into(),
            profile: Some("review".into()),
            job: Some("7".into()),
            task: Some("3".into()),
            home: PathBuf::from("/w/proj"),
        };
        let c = Caller::from_identity(&id, &cache);
        assert_eq!(
            c,
            Caller {
                class: Class::Agent,
                actor: "agent:s-81f2".into(),
                session: Some("s-81f2".into()),
                profile: Some("review".into()),
                job: Some("7".into()),
                project: Some(42),
                backend: false,
            }
        );
        let meta = c.tx_meta("mcp:task_write/claim");
        assert_eq!(
            (
                meta.actor.as_str(),
                meta.class,
                meta.session.as_deref(),
                meta.profile.as_deref(),
                meta.job.as_deref(),
                meta.project
            ),
            (
                "agent:s-81f2",
                Class::Agent,
                Some("s-81f2"),
                Some("review"),
                Some("7"),
                Some(42)
            )
        );
        // A folder the cache does not know, or knows unregistered: no project.
        let elsewhere = Identity::Session {
            agent: "claude".into(),
            sid: "s2".into(),
            profile: None,
            job: None,
            task: None,
            home: PathBuf::from("/w/other"),
        };
        assert_eq!(Caller::from_identity(&elsewhere, &cache).project, None);
        let mut unregistered = ProjectCache::default();
        unregistered.insert(
            PathBuf::from("/w/proj"),
            cache.get(&PathBuf::from("/w/proj")).cloned(),
        );
        assert_eq!(Caller::from_identity(&id, &unregistered).project, None);
    }

    #[test]
    fn caller_from_the_backend_is_marked() {
        let backend = Caller::user(true);
        assert!(backend.backend);
        assert_eq!(backend.class, Class::User);
        assert!(!Caller::user(false).backend);
        // No identity of a tool connection makes a user-class or backend caller.
        let cache = cache_with("/w/proj", 1);
        for id in [
            Identity::None,
            Identity::Outside {
                id: "ext:claude:1-ab".into(),
                kind: "claude".into(),
                home: Some(PathBuf::from("/w/proj")),
            },
            Identity::Session {
                agent: "a".into(),
                sid: "s".into(),
                profile: None,
                job: None,
                task: None,
                home: PathBuf::from("/w/proj"),
            },
        ] {
            let c = Caller::from_identity(&id, &cache);
            assert_ne!(c.class, Class::User);
            assert!(!c.backend);
        }
        let none = Caller::from_identity(&Identity::None, &cache);
        assert_eq!((none.project, none.session), (None, None));
    }

    #[test]
    fn an_outside_agent_takes_its_bridge_cwd() {
        let cache = cache_with("/w/proj", 9);
        let ext = |home: Option<&str>| Identity::Outside {
            id: "ext:claude:123-abcd".into(),
            kind: "claude".into(),
            home: home.map(PathBuf::from),
        };
        let c = Caller::from_identity(&ext(Some("/w/proj")), &cache);
        assert_eq!(c.class, Class::Ext);
        assert_eq!(c.actor, "ext:claude:123-abcd");
        assert_eq!(c.session.as_deref(), Some("ext:claude:123-abcd"));
        assert_eq!(c.profile, None);
        assert_eq!(c.project, Some(9));
        assert_eq!(Caller::from_identity(&ext(None), &cache).project, None);
        assert_eq!(
            Caller::from_identity(&ext(Some("/w/elsewhere")), &cache).project,
            None
        );
    }
}
