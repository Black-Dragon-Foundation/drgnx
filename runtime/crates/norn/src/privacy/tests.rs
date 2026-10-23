//! The opt-in applied (Task 9b). Personal files are fixtures under a temp HOME; the store is a temp `work.db` with
//! its own graph writer. Nothing here reads `~`.

use super::*;
use crate::parsed::{self, PutParsed};
use crate::store::CoordDb;

const CANARY: &str = "CANARY-9b-reading-4k2q";

struct Fx {
    dir: tempfile::TempDir,
    home: PathBuf,
    config: PathBuf,
    _db: CoordDb,
    writer: WriterHandle,
    /// A plan outside `~/org` that names the reading list as its spec.
    plan: String,
}

impl Fx {
    fn reading(&self) -> PathBuf {
        std::fs::canonicalize(self.home.join("org/reading.org")).unwrap()
    }

    fn notes(&self) -> PathBuf {
        std::fs::canonicalize(self.home.join("org/notes.org")).unwrap()
    }

    /// A plain write of the opt-in file (not a command's), its size different each time.
    fn allow(&self, paths: &[&Path]) {
        let paths: Vec<String> = paths
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        std::fs::write(
            self.config.join(ALLOW_FILE),
            json!({"version": 1, "paths": paths}).to_string(),
        )
        .unwrap();
    }

    fn deny_entries(&self, entries: Value) {
        std::fs::write(
            self.config.join(DENY_FILE),
            json!({"version": 1, "entries": entries}).to_string(),
        )
        .unwrap();
    }

    fn list(&self) -> Arc<DenyList> {
        Arc::new(DenyList::load(&self.home, &self.config))
    }

    /// The scan's put: the reading list as a spec (its title the canary) and the plan that names it.
    async fn put_spec(&self) {
        let deny = self.list();
        let (r, p) = (
            self.reading().to_string_lossy().into_owned(),
            self.plan.clone(),
        );
        let req: PutParsed = serde_json::from_value(json!({"sources": [
            {"source": {"kind": "spec", "path": r}, "mtime": 1.0,
             "entities": [{"id": format!("spec:{r}"), "kind": "spec", "title": CANARY, "data": {"path": r, "line": 1}}]},
            {"source": {"kind": "file", "path": p}, "mtime": 2.0,
             "entities": [{"id": format!("plan:{p}"), "kind": "plan", "title": "P", "status": "open",
                           "data": {"path": p, "line": 1}}],
             "links": [{"src": format!("plan:{p}"), "kind": "derives", "dst": format!("spec:{r}")}]}
        ]}))
        .unwrap();
        let a = self
            .writer
            .write(TxMeta::new("scan:/w", Class::System, "scan"), move |tx| {
                parsed::put(tx, &deny, req)
            })
            .await
            .unwrap();
        assert!(a.value.refused.is_empty(), "{:?}", a.value.refused);
    }

    fn ro(&self) -> urdr::Connection {
        urdr::open_readonly(self.writer.path()).unwrap()
    }

    fn count(&self, sql: &str) -> i64 {
        self.ro().query_row(sql, [], |r| r.get(0)).unwrap()
    }

    /// No row, and no byte of `work.db` or its WAL, holds the canary.
    fn no_canary(&self) {
        let like = format!("%{CANARY}%");
        let n: i64 = self
            .ro()
            .query_row(
                "select (select count(*) from entity where coalesce(title, '') || coalesce(data, '') like ?1) \
                      + (select count(*) from entity_hist where coalesce(title, '') || coalesce(data, '') like ?1)",
                [&like],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 0, "a row holds the canary");
        for f in ["work.db", "work.db-wal"] {
            let bytes = std::fs::read(self.dir.path().join(f)).unwrap_or_default();
            assert!(
                !bytes.windows(CANARY.len()).any(|w| w == CANARY.as_bytes()),
                "{f} holds the canary"
            );
        }
    }

    fn applied(&self) -> Applied {
        applied_in(&self.ro()).unwrap()
    }

    /// A dated backup and an export that hold the canary, as copies made before the revoke would.
    fn plant_copies(&self) -> (PathBuf, PathBuf) {
        let backup = self.dir.path().join("backup/work-pre7-19990101.db");
        let export = self.dir.path().join("export/entities.jsonl");
        for f in [&backup, &export] {
            std::fs::create_dir_all(f.parent().unwrap()).unwrap();
            std::fs::write(f, format!("an old copy: {CANARY}")).unwrap();
        }
        (backup, export)
    }
}

async fn fx() -> Fx {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let config = dir.path().join("config");
    std::fs::create_dir_all(home.join("org")).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    std::fs::write(home.join("org/reading.org"), format!("* {CANARY}\n")).unwrap();
    std::fs::write(home.join("org/notes.org"), "* private\n").unwrap();
    let plans = dir.path().join("work/docs/plans");
    std::fs::create_dir_all(&plans).unwrap();
    let plan = std::fs::canonicalize(&plans).unwrap().join("p.md");
    std::fs::write(&plan, "# P\n").unwrap();
    let db = CoordDb::spawn(dir.path().join("work.db"));
    let writer = db.graph_writer().unwrap().clone();
    writer.tick().await;
    Fx {
        plan: plan.to_string_lossy().into_owned(),
        home,
        config,
        _db: db,
        writer,
        dir,
    }
}

/// The reading list opted in and applied, and the scan's put of it.
async fn opted_in(f: &Fx) {
    f.allow(&[&f.reading()]);
    let r = apply(&f.writer, f.list()).await.unwrap();
    assert_eq!(r.added, [f.reading()]);
    assert_eq!(r.excised, 0);
    f.put_spec().await;
    assert_eq!(
        f.count("select count(*) from entity where kind = 'spec' and retired_tx is null"),
        1
    );
}

#[tokio::test]
async fn revoke_excises_what_came_in() {
    let f = fx().await;
    opted_in(&f).await;
    let (backup, export) = f.plant_copies();
    f.allow(&[]);
    let r = apply(&f.writer, f.list()).await.unwrap();
    assert_eq!(r.removed, [f.reading()]);
    assert_eq!(r.excised, 1);
    assert_eq!(
        r.notice.as_deref(),
        Some("personal-file opt-ins changed: +0 / −1; 1 excised")
    );
    // the copies outside the store are listed, not touched
    assert_eq!(r.backups_holding, std::slice::from_ref(&backup));
    assert_eq!(r.exports_holding, std::slice::from_ref(&export));
    assert!(backup.exists() && export.exists());
    // the user's confirmed request deletes the backup; never the export, nor a file that is no copy
    let stray = f.dir.path().join("stray.db");
    std::fs::write(&stray, "x").unwrap();
    assert_eq!(
        delete_copies(
            f.writer.path(),
            &[backup.clone(), export.clone(), stray.clone()]
        ),
        std::slice::from_ref(&backup)
    );
    assert!(!backup.exists());
    assert!(export.exists() && stray.exists());
    // the spec retired and excised, its link from the plan retired, its file forgotten; the plan stays
    let spec = format!("spec:{}", f.reading().display());
    let retired: bool = f
        .ro()
        .query_row(
            "select retired_tx is not null from entity where id = ?1",
            [&spec],
            |r| r.get(0),
        )
        .unwrap();
    assert!(retired);
    assert_eq!(
        f.count(&format!(
            "select count(*) from link where tx_to = {SENTINEL} and kind = 'derives'"
        )),
        0
    );
    assert_eq!(
        f.count("select count(*) from parsed_file where path like '%reading.org'"),
        0
    );
    assert_eq!(
        f.count("select count(*) from entity where kind = 'plan' and retired_tx is null"),
        1
    );
    assert_eq!(
        f.count("select count(*) from excise_log where reason = 'personal-file opt-in revoked'"),
        1
    );
    f.no_canary();
    // applied again: nothing left to do, nothing written
    let tx_before = f.count("select max(id) from tx");
    let again = apply(&f.writer, f.list()).await.unwrap();
    assert_eq!(again.notice, None);
    assert_eq!(f.count("select max(id) from tx"), tx_before);
}

#[tokio::test]
async fn an_added_hard_tier_entry_is_ignored() {
    let f = fx().await;
    f.allow(&[&f.notes()]);
    let r = apply(&f.writer, f.list()).await.unwrap();
    assert!(r.added.is_empty(), "{:?}", r.added);
    assert!(
        r.ignored.iter().any(|w| w.contains("hard tier")),
        "{:?}",
        r.ignored
    );
    assert_eq!(
        r.notice.as_deref(),
        Some("personal-file opt-ins changed: +0 / −0; 1 ignored")
    );
    assert!(f.applied().opt_ins.is_empty());
    assert!(matches!(
        f.list().check(&f.notes()),
        Verdict::Denied {
            tier: deny::Tier::Hard,
            ..
        }
    ));
}

#[tokio::test]
async fn a_change_by_anything_raises_a_notice() {
    let f = fx().await;
    let deny: SharedDeny = Arc::new(std::sync::RwLock::new(f.list()));
    let mut watch = Watch::default();
    // the first tick: nothing to apply, nothing said
    assert_eq!(
        tick(&mut watch, &f.writer, &deny, &f.home, &f.config).await,
        None
    );
    assert!(watch.started);
    // a plain write of the file, as any process of the user's may make
    f.allow(&[&f.reading()]);
    let r = tick(&mut watch, &f.writer, &deny, &f.home, &f.config)
        .await
        .expect("a notice");
    assert_eq!(
        r.notice.as_deref(),
        Some("personal-file opt-ins changed: +1 / −0")
    );
    assert_eq!(
        deny.read().unwrap().check(&f.reading()),
        Verdict::OptedIn,
        "the new list is in force"
    );
    // unchanged file: no tick work
    assert_eq!(
        tick(&mut watch, &f.writer, &deny, &f.home, &f.config).await,
        None
    );
    f.put_spec().await;
    f.allow(&[]);
    let r = tick(&mut watch, &f.writer, &deny, &f.home, &f.config)
        .await
        .expect("a notice");
    assert_eq!(r.removed, [f.reading()]);
    assert_eq!(r.excised, 1);
    // each notice is an event row (counts only, never a path)
    let rows: Vec<(String, String)> = {
        let c = f.ro();
        let mut s = c
            .prepare(
                "select summary, coalesce(data, '') from event where kind = 'status' order by id",
            )
            .unwrap();
        s.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .map(Result::unwrap)
            .collect()
    };
    assert_eq!(
        rows.iter().map(|r| r.0.as_str()).collect::<Vec<_>>(),
        [
            "personal-file opt-ins changed: +1 / −0",
            "personal-file opt-ins changed: +0 / −1; 1 excised"
        ]
    );
    assert!(rows.iter().all(|r| !r.1.contains("reading")));
    f.no_canary();
}

#[tokio::test]
async fn a_change_while_the_hub_was_down_is_applied_at_start() {
    let f = fx().await;
    opted_in(&f).await;
    // the hub is down: the file changes, nobody sees it
    f.allow(&[]);
    let deny: SharedDeny = Arc::new(std::sync::RwLock::new(f.list()));
    let mut watch = Watch::default();
    let r = tick(&mut watch, &f.writer, &deny, &f.home, &f.config)
        .await
        .expect("applied at start");
    assert_eq!(r.removed, [f.reading()]);
    assert_eq!(r.excised, 1);
    f.no_canary();
    assert!(f.applied().opt_ins.is_empty());
}

#[tokio::test]
async fn delete_copies_refuses_names_that_leave_the_data_folder() {
    let f = fx().await;
    let (backup, _) = f.plant_copies();
    let elsewhere = tempfile::tempdir().unwrap();
    let outside = elsewhere.path().join("work-pre7-2.db");
    std::fs::write(&outside, "keep me").unwrap();
    // a link among the backups to a file outside, and the backup named through `..`
    let link = f.dir.path().join("backup/work-pre7-3.db");
    std::os::unix::fs::symlink(&outside, &link).unwrap();
    let dotted = f.dir.path().join("backup/../backup/work-pre7-19990101.db");
    let gone = delete_copies(
        f.writer.path(),
        &[
            dotted,
            outside.clone(),
            link.clone(),
            f.dir.path().join("work.db"),
        ],
    );
    assert!(gone.is_empty(), "{gone:?}");
    assert!(backup.exists() && outside.exists() && link.exists());
    assert!(f.dir.path().join("work.db").exists());
    // the plain name of the copy goes
    assert_eq!(
        delete_copies(f.writer.path(), std::slice::from_ref(&backup)),
        std::slice::from_ref(&backup)
    );
    assert!(!backup.exists() && outside.exists());
}

#[tokio::test]
async fn a_tick_driven_change_deletes_nothing() {
    let f = fx().await;
    opted_in(&f).await;
    let (backup, export) = f.plant_copies();
    // anything (an agent too) edits the file: the hub excises and lists, and deletes no copy
    f.allow(&[]);
    let deny: SharedDeny = Arc::new(std::sync::RwLock::new(f.list()));
    let r = tick(&mut Watch::default(), &f.writer, &deny, &f.home, &f.config)
        .await
        .expect("a notice");
    assert_eq!(r.excised, 1);
    assert_eq!(r.backups_holding, std::slice::from_ref(&backup));
    assert!(backup.exists() && export.exists());
}

#[tokio::test]
async fn an_added_deny_entry_excises_what_came_in() {
    let f = fx().await;
    opted_in(&f).await;
    let docs = std::path::Path::new(&f.plan)
        .parent()
        .unwrap()
        .to_path_buf();
    f.deny_entries(json!([{"kind": "folder", "path": docs}]));
    let r = apply(&f.writer, f.list()).await.unwrap();
    assert_eq!(r.denied_added.len(), 1);
    // the plan under the denied folder goes; the reading list stays opted in
    assert_eq!(r.excised, 1);
    assert_eq!(
        f.count("select count(*) from entity where kind = 'plan' and retired_tx is null"),
        0
    );
    // a deny file with a mistake keeps the built-ins and drops every opt-in: the reading list goes too
    std::fs::write(f.config.join(DENY_FILE), "{not json").unwrap();
    let r = apply(&f.writer, f.list()).await.unwrap();
    assert_eq!(r.removed, [f.reading()]);
    assert_eq!(r.excised, 1);
    f.no_canary();
}

#[test]
fn the_applied_list_is_only_written_here() {
    // no other source names the key
    let crates = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let here = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/privacy.rs");
    let mut stack = vec![crates.to_path_buf()];
    let mut others = Vec::new();
    while let Some(dir) = stack.pop() {
        for e in std::fs::read_dir(&dir).unwrap().flatten() {
            let p = e.path();
            if p.is_dir() && p.file_name().is_some_and(|n| n != "target") {
                stack.push(p);
            } else if p.extension().is_some_and(|x| x == "rs")
                && p != here
                && std::fs::read_to_string(&p).is_ok_and(|t| t.contains(APPLIED_KEY))
            {
                others.push(p);
            }
        }
    }
    assert!(others.is_empty(), "{others:?} name {APPLIED_KEY}");
    // and the store's guard keeps every class but the user's from the key
    let mut g = Guard::default();
    crate::grants::register(&mut g);
    for class in [Class::Agent, Class::Ext, Class::System] {
        assert_eq!(
            guard::check_key(&g, &TxMeta::new("x", class, "t"), APPLIED_KEY),
            Err(WriteError::Refused(PRIVACY_IS_THE_USERS.into()))
        );
    }
    assert_eq!(
        guard::check_key(&g, &meta(), APPLIED_KEY),
        Ok(()),
        "the user's"
    );
}
