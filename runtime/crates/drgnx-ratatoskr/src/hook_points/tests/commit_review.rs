//! The before-commit point over a real fixture plugin (a WASM component built at test time) on the real clock. Each
//! test is pattern C (handshake): the point's own outcome is the only wait.

use std::path::PathBuf;
use std::sync::Arc;

use serde_json::json;

use super::after_edit::{NoIo, rig};
use crate::hook_points::*;

fn commit(message: &str) -> serde_json::Value {
    json!({"commit": {"branch": "job/j7-3", "message": message, "diff_stat": "", "paths": ["a.rs"]}})
}

// [C] handshake: hooks/before-commit-change-rewrites-the-message
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_change_rewrites_the_merge_message() {
    let r = rig(&["rewrite-commit-msg"]).await;
    let out = ask_job_point(
        &r.plugins,
        None,
        Ok(Arc::new(NoIo)),
        norn::hooks::Point::BeforeCommit,
        vec![PathBuf::from("a.rs")],
        commit("Merge job/j7-3"),
        true,
    )
    .await
    .expect("the hook is subscribed");
    assert_eq!(
        commit_message(&out).as_deref(),
        Some("Merge job/j7-3 [checked]")
    );
    assert_eq!(hook_failure(&out, "commit"), None);
}

// [C] handshake: a point nobody subscribed to is not asked, and a hook that cannot run is told apart from a refusal
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nothing_subscribed_is_not_asked_and_a_failure_is_not_a_refusal() {
    let r = rig(&["rewrite-commit-msg"]).await;
    let at_review = ask_job_point(
        &r.plugins,
        None,
        Ok(Arc::new(NoIo)),
        norn::hooks::Point::AtReview,
        Vec::new(),
        json!({"review": {"summary": "s", "report": "", "diff_stat": ""}}),
        false,
    )
    .await;
    assert!(at_review.is_none(), "the plugin only hooks before-commit");
    // no cell for the job's I/O: the plugin cannot run, fail closed, and it is an error, not a refusal
    let out = ask_job_point(
        &r.plugins,
        None,
        Err("no plugin host".into()),
        norn::hooks::Point::BeforeCommit,
        Vec::new(),
        commit("Merge job/j7-3"),
        true,
    )
    .await
    .unwrap();
    assert!(matches!(out.decision, norn::hooks::Decision::Deny(_)));
    assert_eq!(
        hook_failure(&out, "commit").as_deref(),
        Some("hook rewrite-commit-msg failed at commit: no plugin host")
    );
}

// [C] handshake: hooks/before-commit-http-uses-the-jobs-cell. A commit hook has no session: its HTTP is judged under
// the job (`IoCtx::Job`) and the job's network cell, so a host the `plugin` tier does not list is refused with the
// tier's words (not "no session and no job") and the denial is recorded under the job.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_commit_hooks_http_is_judged_under_the_job() {
    use crate::agents::launch::NetCell;
    use crate::plugins::hub_io::{HubIo, HubParts, Net};
    use crate::plugins::io::IoCtx;
    use std::sync::RwLock;

    let r = rig(&["http-commit-hook"]).await;
    let store_dir = r.dir.path().join("db");
    std::fs::create_dir_all(&store_dir).unwrap();
    let (store, db) = crate::runtime_db::open(&store_dir).unwrap();
    let settings = Arc::new(crate::settings::Settings::new());
    settings.open(store_dir.clone(), db.clone());
    settings.refresh().await;
    let writer = crate::coord::Writer {
        db: norn::store::CoordDb::spawn(r.dir.path().join("work.db")),
        signals: Arc::new(crate::coord::Signals::default()),
    };
    let manifests: Vec<_> = r
        .plugins
        .enabled_for(None)
        .iter()
        .map(|p| p.manifest.clone())
        .collect();
    let refs: Vec<&brokkr::Manifest> = manifests.iter().collect();
    let io = Arc::new(HubIo::new(
        Some((IoCtx::Job("j7".into()), NetCell::ProviderOnly)),
        &refs,
        HubParts {
            db,
            settings,
            host_addrs: Arc::new(RwLock::new(gleipnir::net::policy::HostAddrs::default())),
            writer: writer.clone(),
            net: Arc::new(Net::system()),
        },
    ));
    let out = ask_job_point(
        &r.plugins,
        None,
        Ok(io),
        norn::hooks::Point::BeforeCommit,
        Vec::new(),
        commit("Merge job/j7-3"),
        true,
    )
    .await
    .unwrap();
    let norn::hooks::Decision::Deny(why) = &out.decision else {
        panic!("not refused: {:?}", out.decision);
    };
    assert!(why.contains("`plugin` tier"), "{why}");
    assert_eq!(
        hook_failure(&out, "commit"),
        None,
        "a refusal is the hook's deny"
    );
    let rows: Vec<(Option<String>, Option<String>)> = writer
        .write(&crate::runner::service(), "test/read", |tx| {
            let mut q = tx.sql().prepare(
                "select agent, job from event where data like '%proxy-denied%' order by id",
            )?;
            let it = q.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
            Ok(it.collect::<Result<Vec<_>, _>>()?)
        })
        .await
        .unwrap();
    assert_eq!(rows, [(None, Some("j7".to_owned()))]);
    drop(store);
}
