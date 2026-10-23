//! The personal-notes canary over the Rust-only doors (Urdr Task 19; storage §5.6): `graph/put-parsed` with crafted
//! payloads (door 1, without the Lisp scan in front of it), the 6 → 7 migration (door 2,
//! `test/fixtures/work-db-6-canary.sql`), `graph/import` of a tampered export (door 2) and `graph/export` (door 5).
//! The entity embedder (door 4) is Task 12b's: `needs: 12b`, Task 21 adds it here. The Lisp scan and indexer are the
//! row `privacy/personal-notes-canary`'s.
//!
//! Everything lives under a temp HOME. The canaries are random bytes generated here, written only into fixture files
//! under that HOME's `org/`; nothing reads the real `~`.

use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};
use std::time::SystemTime;

use mimir::{BoxFuture, ToolResult};
use norn::deny::{DenyList, may_export, may_import};
use norn::parsed::{self, DENIED, PutAnswer, PutParsed};
use norn::store::CoordDb;
use norn::tools::{Coord, GraphStore, Hub, Identity, SessionRow, tools};
use serde_json::{Value, json};
use urdr::Connection;
use urdr::graph::entity::{self, Ent, EntityNew, Origin};
use urdr::graph::export::{self, Allow, Opts};
use urdr::graph::{Class, ReadPool, TxMeta};

/// 32 random bytes as hex: a canary no fixture, code or test text holds.
fn canary() -> String {
    use std::io::Read;
    let mut bytes = [0u8; 32];
    fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .expect("random bytes");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

struct Fx {
    _dir: tempfile::TempDir,
    /// The temp dir: `work.db`, `home/`, `config/`, `backup/` (`CoordDb::spawn`'s layout).
    root: PathBuf,
    home: PathBuf,
    /// In `org/notes.org` (hard tier) and `org/other.md` (soft tier).
    notes: String,
    other: String,
}

impl Fx {
    fn new() -> Fx {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let home = root.join("home");
        let (notes, other) = (canary(), canary());
        let fx = Fx {
            _dir: dir,
            home,
            root,
            notes,
            other,
        };
        fx.write("org/notes.org", &format!("* {}\n", fx.notes));
        fx.write("org/other.md", &format!("# {}\n", fx.other));
        fx.write("org/board.org", "* TODO a board task\n");
        fx.write(
            "proj/plans/old.md",
            "# An old plan\n### Task 1: An old task\n",
        );
        fx.write("proj/plans/p.md", "# P\n### Task 1: one\n");
        symlink(fx.home.join("org/notes.org"), fx.home.join("proj/n.org")).unwrap();
        fs::create_dir_all(fx.root.join("config")).unwrap();
        fx
    }

    fn write(&self, rel: &str, text: &str) {
        let path = self.home.join(rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    fn at(&self, rel: &str) -> String {
        self.home.join(rel).to_string_lossy().into_owned()
    }

    fn db(&self) -> PathBuf {
        self.root.join("work.db")
    }

    fn deny(&self) -> Arc<DenyList> {
        Arc::new(DenyList::load(&self.home, &self.root.join("config")))
    }

    /// A schema-6 `work.db` holding canary nodes from `org/` (the fixture, with this HOME and these canaries).
    fn schema_6(&self) {
        let fixtures = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../test/fixtures");
        let canaries = fs::read_to_string(fixtures.join("work-db-6-canary.sql"))
            .unwrap()
            .replace("@HOME@", &self.home.to_string_lossy())
            .replace("@NOTES@", &self.notes)
            .replace("@OTHER@", &self.other);
        let c = Connection::open(self.db()).unwrap();
        c.execute_batch(&fs::read_to_string(fixtures.join("work-db-6.sql")).unwrap())
            .unwrap();
        c.execute_batch(&canaries).unwrap();
    }

    /// Every file under `HOME/org` with its bytes and time: the hub writes none of them.
    fn org_snapshot(&self) -> Vec<(PathBuf, Vec<u8>, SystemTime, u32)> {
        let mut out = Vec::new();
        for f in files_under(&self.home.join("org")) {
            let meta = fs::symlink_metadata(&f).unwrap();
            out.push((
                f.clone(),
                fs::read(&f).unwrap(),
                meta.modified().unwrap(),
                meta.permissions().mode(),
            ));
        }
        out
    }
}

fn files_under(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for e in fs::read_dir(dir).into_iter().flatten().flatten() {
        let p = e.path();
        if p.is_dir() && !p.is_symlink() {
            out.extend(files_under(&p));
        } else {
            out.push(p);
        }
    }
    out.sort();
    out
}

/// Whether the file at PATH (absent: no) holds NEEDLE's bytes.
fn holds(path: &Path, needle: &str) -> bool {
    fs::read(path).is_ok_and(|b| b.windows(needle.len()).any(|w| w == needle.as_bytes()))
}

struct QuietHub;

impl Hub for QuietHub {
    fn sessions(&self) -> BoxFuture<'_, Option<Vec<SessionRow>>> {
        Box::pin(async { None::<Vec<SessionRow>> })
    }
    fn notify(&self) {}
}

/// The store after every Rust door ran, and what the doors answered.
struct Ran {
    /// The hub's tools over the store (it holds the store open).
    coord: Arc<Coord>,
    /// Door 1's answers to the crafted payloads (each must refuse its source), then the allowed plan's and the
    /// board's.
    refused: Vec<PutAnswer>,
    allowed: PutAnswer,
    imported: export::Report,
    exported: export::Report,
    export_dir: PathBuf,
}

async fn put(db: &CoordDb, deny: &Arc<DenyList>, req: Value) -> PutAnswer {
    let req: PutParsed = serde_json::from_value(req).unwrap();
    let deny = Arc::clone(deny);
    db.graph_writer()
        .unwrap()
        .write(TxMeta::new("scan:/w", Class::System, "scan"), move |tx| {
            parsed::put(tx, &deny, req)
        })
        .await
        .unwrap()
        .value
}

/// A file or spec source holding ENTITIES.
fn source(kind: &str, path: &str, entities: Value) -> Value {
    json!({"sources": [{"source": {"kind": kind, "path": path}, "mtime": 1.0, "entities": entities}]})
}

/// One `entities.jsonl` line, as an export writes it.
fn line(id: &str, kind: &str, title: &str, data: Value, source: Option<&str>) -> String {
    json!({"id": id, "kind": kind, "project": null, "title": title, "status": null, "body": null,
           "priority": null, "assignee": null, "data": data, "origin": "imported", "source": source, "ver": 1})
    .to_string()
}

async fn run_doors(fx: &Fx) -> Ran {
    // Door 2, the migration: the hub opens a schema-6 file holding canary nodes.
    fx.schema_6();
    let db = CoordDb::spawn(fx.db());
    db.write(TxMeta::new("hub", Class::System, "test"), |_| Ok(()))
        .await
        .unwrap();
    let deny = fx.deny();

    // Door 1, put-parsed with what a scan without its own door (or a forged one) could send.
    let (notes, other, link) = (
        fx.at("org/notes.org"),
        fx.at("org/other.md"),
        fx.at("proj/n.org"),
    );
    let plan = fx.at("proj/plans/p.md");
    let dotted = format!("{}/../org/notes.org", fx.at("proj"));
    let crafted = [
        // the notes as a file source
        source(
            "file",
            &notes,
            json!([{"id": format!("todo:{notes}#1"), "kind": "todo", "title": fx.notes, "data": {"path": notes}}]),
        ),
        // the "spec /path" form, the path given as written, through `..`, and through a link in the project
        source(
            "spec",
            &notes,
            json!([{"id": format!("spec:{notes}"), "kind": "spec", "title": fx.notes, "data": {"path": notes}}]),
        ),
        source(
            "spec",
            &dotted,
            json!([{"id": format!("spec:{dotted}"), "kind": "spec", "title": fx.notes}]),
        ),
        source(
            "spec",
            &link,
            json!([{"id": format!("spec:{link}"), "kind": "spec", "title": fx.notes, "data": {"path": link}}]),
        ),
        // the second file under org/
        source(
            "file",
            &other,
            json!([{"id": format!("todo:{other}#1"), "kind": "todo", "title": fx.other}]),
        ),
        // an allowed source whose entity names org/: as its parent, or as its worktree
        source(
            "file",
            &plan,
            json!([{"id": format!("plan:{plan}"), "kind": "plan", "title": "P"},
                   {"id": format!("task:{plan}#1"), "kind": "task", "title": fx.notes,
                    "data": {"parent": format!("spec:{notes}")}}]),
        ),
        source(
            "file",
            &plan,
            json!([{"id": format!("plan:{plan}"), "kind": "plan", "title": "P"},
                   {"id": format!("task:{plan}#2"), "kind": "task", "title": fx.other,
                    "data": {"worktree": fx.at("org")}}]),
        ),
        // a link from the plan to the notes' spec
        json!({"sources": [{"source": {"kind": "file", "path": plan}, "mtime": 1.0,
                            "entities": [{"id": format!("plan:{plan}"), "kind": "plan", "title": "P"}],
                            "links": [{"src": format!("plan:{plan}"), "kind": "derives", "dst": format!("spec:{notes}")}]}]}),
    ];
    let mut refused = Vec::new();
    for req in crafted {
        refused.push(put(&db, &deny, req).await);
    }
    // the allowed plan, and the board's TODO under it
    let board = fx.at("org/board.org");
    let allowed = put(
        &db,
        &deny,
        json!({"sources": [
            {"source": {"kind": "file", "path": plan}, "mtime": 2.0,
             "entities": [{"id": format!("plan:{plan}"), "kind": "plan", "title": "P", "status": "open",
                           "data": {"path": plan, "line": 1}}]},
            {"source": {"kind": "file", "path": board}, "mtime": 2.0,
             "entities": [{"id": format!("todo:{board}#1"), "kind": "todo", "title": "a board task", "status": "open",
                           "data": {"path": board, "line": 1, "parent": format!("plan:{plan}")}}]}]}),
    )
    .await;

    // Door 2, import: an export a fixture tampered with to carry the notes, beside one plain record.
    let tampered = fx.root.join("tampered");
    fs::create_dir_all(&tampered).unwrap();
    let lines = [
        line(
            "note:from-notes",
            "note",
            &fx.notes,
            json!({"path": notes}),
            None,
        ),
        line(
            &format!("spec:{other}"),
            "spec",
            &fx.other,
            json!({}),
            Some(&format!("spec {other}")),
        ),
        line(
            "note:through-a-link",
            "note",
            &fx.notes,
            json!({"path": link}),
            None,
        ),
        line(
            "note:an-unknown-source",
            "note",
            &fx.other,
            json!({}),
            Some("notes"),
        ),
        line(
            "note:plain",
            "note",
            "a plain imported note",
            json!({}),
            None,
        ),
    ];
    fs::write(tampered.join("entities.jsonl"), lines.join("\n") + "\n").unwrap();
    let writer = db.graph_writer().unwrap().clone();
    let import_deny = Arc::clone(&deny);
    let allow: Allow =
        Arc::new(move |e: &Ent| may_import(&import_deny, e.source.as_deref(), &e.id, &e.data));
    let imported = export::import(&writer, tampered, allow).await;

    // Door 5, export: a record stored before the user kept its folder out (a new entry in the deny file) must not
    // leave; its own canary is in the store by design, so only the export is searched for it.
    let kept_out = canary();
    let private = fx.at("docs/private.txt");
    fx.write("docs/private.txt", "a private file\n");
    let title = kept_out.clone();
    writer
        .write(TxMeta::new("user", Class::User, "test"), move |tx| {
            for (id, title, data) in [
                ("note:kept-out", title, json!({"path": private})),
                ("note:recorded", "a recorded note".to_string(), json!({})),
            ] {
                entity::create(
                    tx,
                    EntityNew {
                        id: id.into(),
                        kind: "note".into(),
                        project: None,
                        title: Some(title),
                        status: None,
                        body: None,
                        priority: None,
                        assignee: None,
                        data,
                        origin: Origin::Recorded,
                        source: None,
                    },
                )?;
            }
            Ok(())
        })
        .await
        .unwrap();
    let config = fx.root.join("config/personal-notes-deny.json");
    fs::write(
        &config,
        json!({"version": 1, "entries": [{"kind": "folder", "path": "~/docs"}]}).to_string(),
    )
    .unwrap();
    fs::set_permissions(&config, fs::Permissions::from_mode(0o600)).unwrap();
    let now_deny = fx.deny();
    let export_dir = fx.root.join("export").join("all");
    let pool = ReadPool::open(fx.db(), 2);
    let allow: Allow =
        Arc::new(move |e: &Ent| may_export(&now_deny, e.source.as_deref(), &e.id, &e.data));
    let exported = export::export(&pool, export_dir.clone(), Opts::default(), allow).await;
    assert!(
        !files_under(&export_dir).iter().any(|f| holds(f, &kept_out)),
        "door 5: a record the deny-list now refuses left the store"
    );

    let graph = GraphStore {
        writer,
        pool,
        deny: Arc::new(RwLock::new(Arc::clone(&deny))),
    };
    let coord = Arc::new(Coord::new(db, Arc::new(QuietHub)).with_graph(graph));
    Ran {
        coord,
        refused,
        allowed,
        imported,
        exported,
        export_dir,
    }
}

fn count(db: &Path, sql: &str, args: [String; 2]) -> i64 {
    Connection::open(db)
        .unwrap()
        .query_row(sql, args, |r| r.get(0))
        .unwrap()
}

#[tokio::test]
async fn rust_doors_never_store_the_canary() {
    let fx = Fx::new();
    let ran = run_doors(&fx).await;
    let db = fx.db();

    // The doors refused what they had to, and let the rest through (so the absence below means something).
    for (i, a) in ran.refused.iter().enumerate() {
        assert_eq!(
            a.refused.iter().map(|r| r.why.as_str()).collect::<Vec<_>>(),
            vec![DENIED],
            "crafted payload {i} was not refused by the deny-list: {a:?}"
        );
        assert_eq!(a.changed, 0, "crafted payload {i} changed the store");
    }
    assert!(ran.allowed.refused.is_empty(), "{:?}", ran.allowed);
    assert!(ran.allowed.changed >= 2);
    assert_eq!(
        (
            ran.imported.entities,
            ran.imported.skipped,
            ran.imported.error.as_deref()
        ),
        (1, 4, None),
        "import: {:?}",
        ran.imported
    );
    assert_eq!(ran.exported.error, None);
    assert_eq!(
        count(
            &db,
            "select count(*) from entity where id in (?1, ?2, 'note:plain', 'note:recorded')",
            [
                format!("plan:{}", fx.at("proj/plans/old.md")),
                format!("task:{}#1", fx.at("proj/plans/old.md")),
            ],
        ),
        4,
        "the migrated plan and task, the imported note and the recorded note are kept"
    );
    let exported = fs::read_to_string(ran.export_dir.join("entities.jsonl")).unwrap();
    assert!(exported.contains("note:recorded") && exported.contains("note:plain"));
    assert!(!exported.contains("note:kept-out"));

    // The canaries are nowhere: not in work.db, its WAL, or the export.
    let mut places = vec![db.clone(), fx.root.join("work.db-wal")];
    places.extend(files_under(&ran.export_dir));
    for place in &places {
        for (name, c) in [("notes.org", &fx.notes), ("org/other.md", &fx.other)] {
            assert!(
                !holds(place, c),
                "the canary of {name} is in {}",
                place.display()
            );
        }
    }
    // …nor any path into org/ but the board's.
    assert_eq!(
        count(
            &db,
            "select count(*) from entity where instr(id || ' ' || coalesce(source, '') || ' ' || data, ?1) > 0 \
             and instr(id, ?2) = 0",
            [fx.at("org/"), fx.at("org/board.org")],
        ),
        0,
        "an entity names a path into org/"
    );
    // The migration's own copy (`backup/`) still holds them by design: the doctor lists it, nothing reads it.
}

#[tokio::test]
async fn the_hub_never_writes_org() {
    let fx = Fx::new();
    let before = fx.org_snapshot();
    let ran = run_doors(&fx).await;
    let todo = format!("todo:{}#1", fx.at("org/board.org"));
    let row = || {
        Connection::open(fx.db())
            .unwrap()
            .query_row(
                "select kind, coalesce(status, ''), coalesce(assignee, ''), ver from entity where id = ?1",
                [&todo],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, i64>(3)?)),
            )
            .unwrap()
    };
    let read = row();
    assert_eq!(read.0, "todo", "the board is read");
    // An agent's task_write on the board's TODO is refused (parsed entities are read-only, call 6).
    let agent = Identity::Session {
        agent: "s1".into(),
        sid: "s1".into(),
        profile: None,
        job: None,
        task: None,
        home: fx.home.join("proj"),
    };
    let list = tools();
    let task_write = list.iter().find(|t| t.name() == "task_write").unwrap();
    for args in [
        json!({"op": "claim", "id": todo}),
        json!({"op": "update", "id": todo, "ver": read.3, "status": "done"}),
    ] {
        let answer = match task_write.check(&args) {
            Err(e) => ToolResult::Err(e.to_string()),
            Ok(()) => {
                task_write
                    .call(&(Arc::clone(&ran.coord), agent.clone()), args.clone())
                    .await
            }
        };
        assert!(
            matches!(answer, ToolResult::Err(_)),
            "task_write {args} was not refused"
        );
    }
    assert_eq!(row(), read, "the board's TODO is as the scan left it");
    // No file under HOME/org changed: the same files, bytes, times and modes.
    assert_eq!(fx.org_snapshot(), before);
}
