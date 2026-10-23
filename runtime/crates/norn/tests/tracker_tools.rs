//! The tracker and graph tools (Urdr Task 14): `task_read`, `task_write`, `note_add`, `graph_read`,
//! `access_request`, `hello`'s brief and `record_decision`'s `about`, against a schema-7 store.

mod tools {
    use std::path::{Path, PathBuf};
    use std::sync::atomic::AtomicUsize;
    use std::sync::{Arc, RwLock};

    use mimir::{BoxFuture, ToolResult};
    use norn::deny::DenyList;
    use norn::grants::{self, Access, What, Who};
    use norn::project::ProjectRef;
    use norn::store::CoordDb;
    use norn::tools::{Coord, GraphStore, Hub, Identity, SessionRow, ToolSets, tools, tools_for};
    use serde_json::{Value, json};
    use urdr::Connection;
    use urdr::graph::entity::{self, EntityNew, Origin};
    use urdr::graph::{Class, ReadPool, TxMeta, link};

    #[derive(Default)]
    struct QuietHub {
        told: AtomicUsize,
    }

    impl Hub for QuietHub {
        fn sessions(&self) -> BoxFuture<'_, Option<Vec<SessionRow>>> {
            Box::pin(async { None::<Vec<SessionRow>> })
        }
        fn notify(&self) {
            self.told.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }
    }

    struct World {
        dir: tempfile::TempDir,
        file: PathBuf,
        db: CoordDb,
        coord: Arc<Coord>,
    }

    struct Out {
        err: bool,
        text: String,
        structured: Value,
        meta: Value,
        content: Vec<Value>,
    }

    impl World {
        async fn new() -> World {
            let dir = tempfile::tempdir().unwrap();
            let file = dir.path().join("work.db");
            let db = CoordDb::spawn(&file);
            // the writer makes the file at its first request
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
            let coord =
                Arc::new(Coord::new(db.clone(), Arc::new(QuietHub::default())).with_graph(graph));
            World {
                dir,
                file,
                db,
                coord,
            }
        }

        /// A folder that is a project of its own (a made-up root commit, no git needed).
        fn place(&self, slug: &str) -> PathBuf {
            let root = self.dir.path().join(slug);
            std::fs::create_dir_all(&root).unwrap();
            let sha = format!(
                "{:040x}",
                slug.bytes().fold(7u128, |a, b| a * 131 + u128::from(b))
            );
            self.coord.projects().lock().unwrap().insert(
                root.clone(),
                Some(ProjectRef {
                    id: format!("project:{}", &sha[28..]),
                    root: root.clone(),
                    slug: slug.into(),
                    root_commit: Some(sha.clone()),
                    roots: vec![sha],
                }),
            );
            root
        }

        fn agent(&self, sid: &str, home: &Path) -> Identity {
            Identity::Session {
                agent: sid.into(),
                sid: sid.into(),
                profile: None,
                job: None,
                task: None,
                home: home.to_path_buf(),
            }
        }

        async fn call(&self, who: &Identity, name: &str, args: Value) -> Out {
            call_in(&tools(), &self.coord, who, name, args).await
        }

        /// The entity `n` of the project at HOME (after one of its tools ran).
        fn project_n(&self, home: &Path) -> i64 {
            self.coord
                .projects()
                .lock()
                .unwrap()
                .project_n(home)
                .unwrap()
        }

        fn conn(&self) -> Connection {
            Connection::open(&self.file).unwrap()
        }

        fn count(&self, sql: &str) -> i64 {
            self.conn().query_row(sql, [], |r| r.get(0)).unwrap()
        }

        async fn user_write<R: Send + 'static>(
            &self,
            f: impl FnOnce(&mut norn::store::WTx<'_>) -> Result<R, norn::store::CoordError>
            + Send
            + 'static,
        ) -> R {
            self.db
                .write(TxMeta::new("user", Class::User, "test"), f)
                .await
                .unwrap()
        }

        async fn grant_read(&self, who: i64, what: i64) {
            self.user_write(move |tx| {
                grants::create(
                    tx,
                    Who::Project(who),
                    What::Project(what),
                    Access::Read,
                    None,
                )?;
                Ok(())
            })
            .await;
        }
    }

    async fn call_in(
        list: &[Box<dyn mimir::Tool<norn::tools::Ctx>>],
        coord: &Arc<Coord>,
        who: &Identity,
        name: &str,
        args: Value,
    ) -> Out {
        let tool = list.iter().find(|t| t.name() == name).unwrap();
        if let Err(e) = tool.check(&args) {
            return Out {
                err: true,
                text: e.to_string(),
                structured: Value::Null,
                meta: Value::Null,
                content: vec![],
            };
        }
        match tool.call(&(coord.clone(), who.clone()), args).await {
            ToolResult::Ok { text, structured } => Out {
                err: false,
                text,
                structured: structured.unwrap_or(Value::Null),
                meta: Value::Null,
                content: vec![],
            },
            ToolResult::Rich {
                text,
                structured,
                content,
                meta,
            } => Out {
                err: false,
                text,
                structured: structured.unwrap_or(Value::Null),
                meta: meta.unwrap_or(Value::Null),
                content,
            },
            ToolResult::Err(text) => Out {
                err: true,
                text,
                structured: Value::Null,
                meta: Value::Null,
                content: vec![],
            },
        }
    }

    fn id_of(o: &Out) -> String {
        assert!(!o.err, "{}", o.text);
        o.structured["done"]["id"].as_str().unwrap().to_owned()
    }

    fn ver_of(o: &Out) -> i64 {
        o.structured["done"]["ver"].as_i64().unwrap()
    }

    async fn create(w: &World, who: &Identity, title: &str) -> Out {
        w.call(who, "task_write", json!({"op": "create", "title": title}))
            .await
    }

    fn is_authored(v: &Value) -> bool {
        ["text", "by", "class", "tx", "trust"]
            .iter()
            .all(|k| v.get(*k).is_some())
    }

    #[tokio::test]
    async fn scope_matrix() {
        let w = World::new().await;
        let (ha, hb) = (w.place("pa"), w.place("pb"));
        let (a, b) = (w.agent("a1", &ha), w.agent("b1", &hb));
        let ta = id_of(&create(&w, &a, "alpha task").await);
        let tb = id_of(&create(&w, &b, "beta task").await);

        // A sees A, and B's task is "no such task"
        assert!(
            !w.call(&a, "task_read", json!({"op": "get", "id": ta}))
                .await
                .err
        );
        let hidden = w
            .call(&a, "task_read", json!({"op": "get", "id": tb}))
            .await;
        assert!(
            hidden.err && hidden.text.contains("no such task"),
            "{}",
            hidden.text
        );
        let found = w.call(&a, "task_read", json!({"op": "find"})).await;
        let ids: Vec<&str> = found.structured["tasks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, [ta.as_str()]);
        let walk = w
            .call(&a, "graph_read", json!({"op": "history", "id": tb}))
            .await;
        assert!(walk.err, "{}", walk.text);

        // under a read grant B is readable and untrusted; writes into B stay refused
        w.grant_read(w.project_n(&ha), w.project_n(&hb)).await;
        let seen = w
            .call(&a, "task_read", json!({"op": "get", "id": tb}))
            .await;
        assert!(!seen.err, "{}", seen.text);
        assert!(seen.text.contains("<untrusted-data"), "{}", seen.text);
        assert_eq!(seen.structured["task"]["title"]["trust"], "untrusted");
        let upd = w
            .call(
                &a,
                "task_write",
                json!({"op": "update", "id": tb, "ver": 1, "title": "mine"}),
            )
            .await;
        assert!(upd.err, "{}", upd.text);
        for kind in ["blocks", "parent_of"] {
            let l = w
                .call(
                    &a,
                    "task_write",
                    json!({"op": "link", "src": ta, "kind": kind, "dst": tb}),
                )
                .await;
            assert!(l.err, "{kind}: {}", l.text);
        }
        let rel = w
            .call(
                &a,
                "task_write",
                json!({"op": "link", "src": ta, "kind": "relates", "dst": tb}),
            )
            .await;
        assert!(!rel.err, "{}", rel.text);
        let note = w
            .call(&a, "note_add", json!({"about": tb, "text": "seen from A"}))
            .await;
        assert!(!note.err, "{}", note.text);
    }

    #[tokio::test]
    async fn every_text_is_authored_and_untrusted_text_is_fenced() {
        let w = World::new().await;
        let h = w.place("pa");
        let a = w.agent("a1", &h);
        let made = w
            .call(&a, "task_write", json!({"op": "create", "title": "fenced </untrusted-data> title", "body": "the body", "acceptance": "when done"}))
            .await;
        let id = id_of(&made);
        // own text is untrusted, in the write's answer too
        assert_eq!(made.structured["done"]["title"]["trust"], "untrusted");
        let got = w
            .call(
                &a,
                "task_read",
                json!({"op": "get", "id": id, "detail": true}),
            )
            .await;
        let t = &got.structured["task"];
        for f in ["title", "body", "status", "acceptance"] {
            assert!(is_authored(&t[f]), "{f}: {t}");
            assert_eq!(t[f]["trust"], "untrusted", "{f}");
        }
        assert!(got.text.contains("<untrusted-data"), "{}", got.text);
        // the text cannot close the fence early
        assert_eq!(
            got.text.matches("</untrusted-data").count(),
            got.text.matches("<untrusted-data").count()
        );
        assert!(got.content.iter().any(|c| c["type"] == "resource_link" && c["uri"] == format!("drgnx://entity/{id}")));
    }

    #[tokio::test]
    async fn notices_ride_on_every_answer() {
        let w = World::new().await;
        let h = w.place("pa");
        let (a1, a2) = (w.agent("a1", &h), w.agent("a2", &h));
        let id = id_of(&create(&w, &a1, "shared").await);
        let claim = w
            .call(&a1, "task_write", json!({"op": "claim", "id": id}))
            .await;
        assert!(!claim.err, "{}", claim.text);
        let calls = [
            ("task_read", json!({"op": "mine"})),
            ("task_write", json!({"op": "create", "title": "another"})),
            ("note_add", json!({"about": id, "text": "hello"})),
            ("graph_read", json!({"op": "history", "id": id})),
            (
                "access_request",
                json!({"project": "elsewhere", "reason": "look"}),
            ),
        ];
        for (name, args) in calls.iter() {
            let o = w.call(&a1, name, args.clone()).await;
            assert!(!o.err, "{name}: {}", o.text);
            assert_eq!(o.meta["dev.drgnx/notices"], 0, "{name}");
            assert!(!o.text.contains("notices:"), "{name}: {}", o.text);
        }
        // another agent changes a1's task: a1 has a notice on its next answer
        let up = w
            .call(
                &a2,
                "task_write",
                json!({"op": "update", "id": id, "ver": ver_of(&claim), "title": "renamed"}),
            )
            .await;
        assert!(!up.err, "{}", up.text);
        let mine = w.call(&a1, "task_read", json!({"op": "mine"})).await;
        assert!(
            mine.meta["dev.drgnx/notices"].as_i64().unwrap() >= 1,
            "{:?}",
            mine.meta
        );
        assert!(
            mine.text.lines().last().unwrap().starts_with("notices: "),
            "{}",
            mine.text
        );
    }

    #[tokio::test]
    async fn a_conflict_or_a_lost_lease_commits_no_tx_row() {
        let w = World::new().await;
        let h = w.place("pa");
        let (a1, a2) = (w.agent("a1", &h), w.agent("a2", &h));
        let made = create(&w, &a1, "first").await;
        let id = id_of(&made);
        let claim = w
            .call(&a1, "task_write", json!({"op": "claim", "id": id}))
            .await;
        assert!(!claim.err, "{}", claim.text);
        let lease = claim.structured["done"]["lease"].as_i64().unwrap();
        let txs = w.count("select count(*) from tx");
        let stale = w
            .call(
                &a2,
                "task_write",
                json!({"op": "update", "id": id, "ver": ver_of(&made), "title": "stale"}),
            )
            .await;
        assert!(stale.structured.get("conflict").is_some(), "{}", stale.text);
        let lost = w
            .call(
                &a2,
                "task_write",
                json!({"op": "heartbeat", "id": id, "lease": lease}),
            )
            .await;
        assert!(lost.structured.get("lease_lost").is_some(), "{}", lost.text);
        assert_eq!(w.count("select count(*) from tx"), txs);
        // and the holder's own heartbeat still writes
        let beat = w
            .call(
                &a1,
                "task_write",
                json!({"op": "heartbeat", "id": id, "lease": lease}),
            )
            .await;
        assert!(
            !beat.err && beat.structured.get("done").is_some(),
            "{}",
            beat.text
        );
        assert_eq!(w.count("select count(*) from tx"), txs + 1);
    }

    #[tokio::test]
    async fn lists_cap_at_50_with_a_cursor() {
        let w = World::new().await;
        let h = w.place("pa");
        let a = w.agent("a1", &h);
        for i in 0..55 {
            create(&w, &a, &format!("task {i}")).await;
        }
        let first = w.call(&a, "task_read", json!({"op": "find"})).await;
        assert_eq!(first.structured["tasks"].as_array().unwrap().len(), 50);
        let cursor = first.structured["next_cursor"].as_str().unwrap().to_owned();
        let second = w
            .call(&a, "task_read", json!({"op": "find", "cursor": cursor}))
            .await;
        assert_eq!(second.structured["tasks"].as_array().unwrap().len(), 5);
        assert!(second.structured.get("next_cursor").is_none());
        let bad = w
            .call(&a, "task_read", json!({"op": "find", "cursor": "zz"}))
            .await;
        assert!(bad.err);
    }

    #[tokio::test]
    async fn find_says_when_vectors_lag() {
        let w = World::new().await;
        let h = w.place("pa");
        let a = w.agent("a1", &h);
        create(&w, &a, "tracker words here").await;
        let o = w
            .call(&a, "task_read", json!({"op": "find", "query": "tracker"}))
            .await;
        assert_eq!(o.structured["tasks"].as_array().unwrap().len(), 1);
        assert!(
            o.structured["vectors"]
                .as_str()
                .unwrap()
                .starts_with("behind "),
            "{}",
            o.structured
        );
        assert!(o.text.contains("vectors: behind"));
    }

    /// Review finding 11: `vectors: behind N` counts the caller's scope only; another project's texts are not its lag
    /// (nor its business: the count would tell how much another project writes).
    #[tokio::test]
    async fn vectors_behind_counts_the_callers_scope_only() {
        let w = World::new().await;
        let (ha, hb) = (w.place("pa"), w.place("pb"));
        let (a, b) = (w.agent("a1", &ha), w.agent("b1", &hb));
        create(&w, &a, "tracker words here").await;
        for i in 0..3 {
            create(&w, &b, &format!("beta task {i}")).await;
        }
        let o = w
            .call(&a, "task_read", json!({"op": "find", "query": "tracker"}))
            .await;
        let pa = w.project_n(&ha);
        let mine = w.count(&format!(
            "select count(*) from entity where project = {pa} and (title is not null or body is not null)"
        ));
        assert_eq!(
            o.structured["vectors"],
            format!("behind {mine}"),
            "{}",
            o.structured
        );
        // under a read grant of B, B's texts are in A's scope and count
        w.grant_read(pa, w.project_n(&hb)).await;
        let o = w
            .call(&a, "task_read", json!({"op": "find", "query": "tracker"}))
            .await;
        let pb = w.project_n(&hb);
        let both = w.count(&format!(
            "select count(*) from entity where project in ({pa}, {pb}) and (title is not null or body is not null)"
        ));
        assert!(both > mine);
        assert_eq!(o.structured["vectors"], format!("behind {both}"));
    }

    /// Review finding 8 (Task 10: "a caller with no project … writes nothing"): `note_add` from a folder that is no
    /// project is refused, as `create` is, and writes no note (one would be a stub every agent sees).
    #[tokio::test]
    async fn note_add_without_a_project_writes_nothing() {
        let w = World::new().await;
        let nowhere = w.dir.path().join("nowhere");
        std::fs::create_dir_all(&nowhere).unwrap();
        w.coord
            .projects()
            .lock()
            .unwrap()
            .insert(nowhere.clone(), None);
        let homeless = w.agent("h1", &nowhere);
        let stub = w
            .user_write(|tx| {
                Ok(entity::create(
                    tx,
                    EntityNew {
                        id: "task:stub".into(),
                        kind: "task".into(),
                        project: None,
                        title: Some("a task of no project".into()),
                        status: Some("open".into()),
                        body: None,
                        priority: None,
                        assignee: None,
                        data: json!({}),
                        origin: Origin::Recorded,
                        source: None,
                    },
                )?
                .id)
            })
            .await;
        let txs = w.count("select count(*) from tx");
        let o = w
            .call(
                &homeless,
                "note_add",
                json!({"about": stub, "text": "a note of no project"}),
            )
            .await;
        assert!(o.err && o.text.contains("no project"), "{}", o.text);
        assert_eq!(
            w.count("select count(*) from entity where kind = 'note'"),
            0
        );
        assert_eq!(w.count("select count(*) from tx"), txs, "no tx was written");
    }

    #[tokio::test]
    async fn access_request_never_blocks_and_merges() {
        let w = World::new().await;
        let (ha, _hb) = (w.place("pa"), w.place("pb"));
        let a = w.agent("a1", &ha);
        let first = w
            .call(
                &a,
                "access_request",
                json!({"project": "pb", "reason": "need its api"}),
            )
            .await;
        let again = w
            .call(
                &a,
                "access_request",
                json!({"project": "pb", "reason": "still"}),
            )
            .await;
        assert!(!first.err && !again.err);
        assert_eq!(first.structured, again.structured);
        assert_eq!(
            w.count("select count(*) from card where kind = 'access' and state = 'open'"),
            1
        );
        let title: String = w
            .conn()
            .query_row("select title from card where kind = 'access'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert!(
            title.contains("a1") && title.contains("asks to read pb"),
            "{title}"
        );
        let secret = w
            .call(
                &a,
                "access_request",
                json!({"project": "pb", "reason": format!("key AKIA{}", "ABCDEFGHIJKLMNOP")}),
            )
            .await;
        assert!(secret.err, "{}", secret.text);
    }

    #[tokio::test]
    async fn access_request_answers_alike_for_known_and_unknown() {
        let w = World::new().await;
        let (ha, _hb) = (w.place("pa"), w.place("pb"));
        let a = w.agent("a1", &ha);
        let known = w
            .call(
                &a,
                "access_request",
                json!({"project": "pb", "reason": "r"}),
            )
            .await;
        let unknown = w
            .call(
                &a,
                "access_request",
                json!({"project": "no-such-project", "reason": "r"}),
            )
            .await;
        let shape = |o: &Out| {
            (
                o.err,
                o.structured
                    .as_object()
                    .unwrap()
                    .keys()
                    .cloned()
                    .collect::<Vec<_>>(),
                o.structured["requested"].is_i64(),
                o.text.split(':').next().unwrap().to_owned(),
            )
        };
        assert_eq!(shape(&known), shape(&unknown));
        let t: String = w
            .conn()
            .query_row(
                "select title from card where json_extract(data, '$.target') = 'no-such-project'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(t.contains("unknown project"), "{t}");
    }

    #[tokio::test]
    async fn access_card_has_no_job() {
        let w = World::new().await;
        let ha = w.place("pa");
        let job = Identity::Session {
            agent: "j1".into(),
            sid: "j1".into(),
            profile: Some("p".into()),
            job: Some("JOB1".into()),
            task: None,
            home: ha,
        };
        let o = w
            .call(
                &job,
                "access_request",
                json!({"project": "pb", "reason": "r"}),
            )
            .await;
        assert!(!o.err, "{}", o.text);
        assert_eq!(
            w.count("select count(*) from card where kind = 'access' and job is not null"),
            0
        );
        assert_eq!(
            w.count("select count(*) from card where kind = 'access'"),
            1
        );
    }

    #[tokio::test]
    async fn req_retry_returns_the_first_answer() {
        let w = World::new().await;
        let h = w.place("pa");
        let a = w.agent("a1", &h);
        let args = json!({"op": "create", "title": "once", "req": "r-1"});
        let first = w.call(&a, "task_write", args.clone()).await;
        let second = w.call(&a, "task_write", args).await;
        assert_eq!(id_of(&first), id_of(&second));
        assert_eq!(
            w.count("select count(*) from entity where kind = 'task'"),
            1
        );
        let bad = w
            .call(
                &a,
                "task_write",
                json!({"op": "create", "title": "x", "req": "has space"}),
            )
            .await;
        assert!(bad.err);
        let n1 = w
            .call(
                &a,
                "note_add",
                json!({"about": id_of(&first), "text": "n", "req": "n-1"}),
            )
            .await;
        let n2 = w
            .call(
                &a,
                "note_add",
                json!({"about": id_of(&first), "text": "n", "req": "n-1"}),
            )
            .await;
        assert_eq!(n1.structured, n2.structured);
        assert_eq!(
            w.count("select count(*) from entity where kind = 'note'"),
            1
        );
    }

    #[tokio::test]
    async fn hello_brief_keeps_the_first_item() {
        let w = World::new().await;
        let h = w.place("pa");
        let a = w.agent("a1", &h);
        let id = id_of(&create(&w, &a, "ready one").await);
        let on = w.call(&a, "hello", json!({})).await;
        let off_tools = tools_for(ToolSets { tracker: false });
        let off = call_in(&off_tools, &w.coord, &a, "hello", json!({})).await;
        assert!(!on.err && !off.err, "{} / {}", on.text, off.text);
        assert_eq!(on.text, off.text, "the first item is the same");
        assert!(on.structured["brief"]["project"].is_string());
        assert!(
            on.structured["brief"]["ready"]
                .as_array()
                .unwrap()
                .iter()
                .any(|t| t["id"] == id)
        );
        assert!(off.structured["brief"].get("ready").is_none());
        assert!(
            !serde_json::to_string(&off.structured)
                .unwrap()
                .contains("task_read")
        );
        assert!(
            on.content[0]["text"]
                .as_str()
                .unwrap()
                .contains("task_read")
        );
    }

    #[tokio::test]
    async fn record_decision_about_links() {
        let w = World::new().await;
        let h = w.place("pa");
        let a = w.agent("a1", &h);
        let id = id_of(&create(&w, &a, "subject").await);
        let o = w
            .call(&a, "record_decision", json!({"kind": "build", "subject": "use x", "reason": "because", "seen_version": 0, "about": [id]}))
            .await;
        assert!(!o.err, "{}", o.text);
        assert_eq!(
            w.count("select count(*) from link l join entity s on s.n = l.src where l.kind = 'about' and s.kind = 'decision'"),
            1
        );
        let bad = w
            .call(&a, "record_decision", json!({"kind": "build", "subject": "use y", "reason": "because", "seen_version": 1, "about": ["task:nope-00000"]}))
            .await;
        assert!(
            bad.err && bad.text.contains("no such entity"),
            "{}",
            bad.text
        );
    }

    #[tokio::test]
    async fn who_touched_resolves_moved_and_gone() {
        let w = World::new().await;
        let h = w.place("pa");
        let a = w.agent("a1", &h);
        create(&w, &a, "registers the project").await;
        let p = w.project_n(&h);
        w.user_write(move |tx| {
            let mk = |tx: &mut norn::store::WTx<'_>, id: &str, kind: &str| {
                entity::create(
                    tx,
                    EntityNew {
                        id: id.into(),
                        kind: kind.into(),
                        project: Some(p),
                        title: Some(id.into()),
                        status: None,
                        body: None,
                        priority: None,
                        assignee: None,
                        data: json!({}),
                        origin: Origin::Inferred,
                        source: None,
                    },
                )
            };
            let (old, new, s, ag) = (
                mk(tx, "file:old.rs", "file")?,
                mk(tx, "file:new.rs", "file")?,
                mk(tx, "session:s9", "session")?,
                mk(tx, "agent:x", "agent")?,
            );
            link::add(tx, old.n, "renamed_to", new.n, None, Origin::Inferred, None)?;
            link::add(tx, s.n, "touched", new.n, None, Origin::Inferred, None)?;
            link::add(tx, s.n, "run_by", ag.n, None, Origin::Inferred, None)?;
            Ok(())
        })
        .await;
        let moved = w
            .call(
                &a,
                "graph_read",
                json!({"op": "who_touched", "path": "old.rs"}),
            )
            .await;
        assert_eq!(moved.structured["state"], "moved");
        assert_eq!(moved.structured["moved_to"], "file:new.rs");
        let current = w
            .call(
                &a,
                "graph_read",
                json!({"op": "who_touched", "path": "new.rs"}),
            )
            .await;
        assert_eq!(current.structured["state"], "current");
        assert_eq!(current.structured["touched"][0]["session"], "session:s9");
        assert_eq!(current.structured["touched"][0]["agent"], "agent:x");
        let gone = w
            .call(
                &a,
                "graph_read",
                json!({"op": "who_touched", "path": "never.rs"}),
            )
            .await;
        assert_eq!(gone.structured["state"], "gone");
        assert!(
            gone.structured.get("hidden").is_some() && gone.structured.get("truncated").is_some()
        );
    }

    #[tokio::test]
    async fn neighbors_and_path_say_truncated_and_hidden() {
        let w = World::new().await;
        let h = w.place("pa");
        let a = w.agent("a1", &h);
        let t1 = id_of(&create(&w, &a, "one").await);
        let t2 = id_of(&create(&w, &a, "two").await);
        let l = w
            .call(
                &a,
                "task_write",
                json!({"op": "link", "src": t1, "kind": "blocks", "dst": t2}),
            )
            .await;
        assert!(!l.err, "{}", l.text);
        let n = w
            .call(
                &a,
                "graph_read",
                json!({"op": "neighbors", "id": t1, "depth": 2}),
            )
            .await;
        assert!(!n.err, "{}", n.text);
        assert!(
            n.structured["nodes"]
                .as_array()
                .unwrap()
                .iter()
                .any(|x| x["id"] == t2)
        );
        assert!(n.structured.get("hidden").is_some() && n.structured.get("truncated").is_some());
        let p = w
            .call(
                &a,
                "graph_read",
                json!({"op": "path", "start": t1, "end": t2}),
            )
            .await;
        assert!(!p.err, "{}", p.text);
        assert_eq!(p.structured["links"][0]["kind"], "blocks");
        let deep = w
            .call(
                &a,
                "graph_read",
                json!({"op": "neighbors", "id": t1, "depth": 5}),
            )
            .await;
        assert!(deep.err);
    }

    #[tokio::test]
    async fn the_agent_reaches_no_grant_through_the_tools() {
        let w = World::new().await;
        let h = w.place("pa");
        let a = w.agent("a1", &h);
        create(&w, &a, "registers the project").await;
        let (p, q) = (w.project_n(&h), w.place("pq"));
        let _ = q;
        let g = w
            .user_write(move |tx| {
                Ok(grants::create(tx, Who::Project(p), What::All, Access::Read, None)?.id)
            })
            .await;
        for args in [
            json!({"op": "update", "id": g, "ver": 1, "title": "x"}),
            json!({"op": "label", "id": g, "add": ["x"]}),
            json!({"op": "claim", "id": g}),
        ] {
            let o = w.call(&a, "task_write", args).await;
            assert!(o.err, "{}", o.text);
        }
    }

    #[test]
    fn default_session_lists_21() {
        assert_eq!(tools_for(ToolSets::default()).len(), 21);
        assert_eq!(tools().len(), 21);
    }

    #[test]
    fn tracker_off_lists_16() {
        let off = tools_for(ToolSets { tracker: false });
        assert_eq!(off.len(), 16);
        for t in &off {
            assert!(
                ![
                    "task_read",
                    "task_write",
                    "note_add",
                    "graph_read",
                    "access_request"
                ]
                .contains(&t.name())
            );
        }
    }
}
