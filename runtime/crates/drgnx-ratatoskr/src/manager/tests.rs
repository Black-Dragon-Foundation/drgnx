use super::*;
use crate::matrix_gate::MatrixGate;
use norn::matrix::Widening;
use runstav::methods::matrix::Verdict;

fn mgr() -> Who {
    Who {
        role: Some(Role::Manager),
        agent: Some("m".into()),
        provider: None,
    }
}

fn asking(action: Action, verdict: Verdict) -> Effective {
    Effective {
        cells: [(
            action,
            Cell {
                verdict,
                limit: None,
            },
        )]
        .into_iter()
        .collect(),
    }
}

#[test]
fn delegate_refuses_a_grant_wider_than_the_managers_own() {
    let conn = urdr::Connection::open_in_memory().unwrap();
    let g = MatrixGate::default();
    let ctx = ActionCtx::default();
    // push.main asks for a manager (Balanced): allowing it is wider
    let wider = g.delegate(
        &conn,
        &mgr(),
        &ctx,
        "w1",
        asking(Action::PushMain, Verdict::Allow),
        0.0,
    );
    assert_eq!(
        wider,
        Err(Widening {
            action: Action::PushMain
        })
    );
    // never is narrower than anything
    assert!(
        g.delegate(
            &conn,
            &mgr(),
            &ctx,
            "w1",
            asking(Action::PushMain, Verdict::Never),
            0.0
        )
        .is_ok()
    );
    // what the manager may do alone it may hand on
    assert!(
        g.delegate(
            &conn,
            &mgr(),
            &ctx,
            "w2",
            asking(Action::CodeEdit, Verdict::Allow),
            0.0
        )
        .is_ok()
    );
}

#[test]
fn no_grant_ever_opens_what_is_never_for_everyone() {
    let conn = urdr::Connection::open_in_memory().unwrap();
    let g = MatrixGate::default();
    let r = g.delegate(
        &conn,
        &mgr(),
        &ActionCtx::default(),
        "w1",
        asking(Action::Unsandboxed, Verdict::Allow),
        0.0,
    );
    assert_eq!(
        r,
        Err(Widening {
            action: Action::Unsandboxed
        })
    );
}

/// A graph file with urdr's real tables, written through urdr's primitives ([`urdr::graph::Tx::for_test`] and
/// `entity::create`), and the one table the digest also reads that urdr does not own: norn's `card`.
fn graph_stub() -> urdr::Connection {
    let c = urdr::Connection::open_in_memory().unwrap();
    c.execute_batch(urdr::graph::schema::GRAPH_DDL).unwrap();
    c.execute_batch("create table card (id integer primary key, kind text, title text, state text, tx integer);")
        .unwrap();
    c
}

/// A tx of SESSION that creates the entities (id, kind, title, status); answers its id.
fn write_entities(
    c: &mut urdr::Connection,
    session: &str,
    rows: &[(String, &str, String, &str)],
) -> i64 {
    use urdr::graph::{Class, Tx, TxMeta, entity, guard::Guard};
    let mut meta = TxMeta::new(format!("agent:{session}"), Class::Agent, "test");
    meta.session = Some(format!("session:{session}"));
    let mut tx = Tx::for_test(c, meta, std::sync::Arc::new(Guard::default()));
    for (id, kind, title, status) in rows {
        entity::create(
            &mut tx,
            entity::EntityNew {
                id: id.clone(),
                kind: (*kind).to_owned(),
                project: None,
                title: Some(title.clone()),
                status: Some((*status).to_owned()),
                body: None,
                priority: None,
                assignee: None,
                data: json!({}),
                origin: entity::Origin::Recorded,
                source: None,
            },
        )
        .unwrap();
    }
    let id = tx.id();
    tx.commit_for_test().unwrap();
    id
}

#[test]
fn a_digest_is_at_most_4_kib_and_says_what_it_left_out() {
    let mut c = graph_stub();
    let rows: Vec<_> = (0..400)
        .map(|n| (format!("report:{n}"), "report", "x".repeat(300), "done"))
        .collect();
    let tx = write_entities(&mut c, "other", &rows);
    let (text, upto) = digest(&c, 0, "mgr", &[]).unwrap();
    assert!(text.len() <= DIGEST_MAX, "{} bytes", text.len());
    assert!(text.contains("and "), "{text}");
    assert_eq!(upto, tx);
    // nothing after the last look: nothing to say
    assert_eq!(digest(&c, tx, "mgr", &[]).unwrap().0, "");
}

#[test]
fn a_digest_leaves_out_what_the_manager_wrote_itself() {
    let mut c = graph_stub();
    write_entities(
        &mut c,
        "mgr",
        &[("task:a".into(), "task", "mine".into(), "open")],
    );
    let theirs = write_entities(
        &mut c,
        "w1",
        &[("report:b".into(), "report", "theirs".into(), "done")],
    );
    c.execute(
        "insert into card (id, kind, title, state, tx) values (7, 'matrix', 'push', 'open', ?1)",
        [theirs],
    )
    .unwrap();
    let (text, _) = digest(&c, 0, "mgr", &["job j1 Done".into()]).unwrap();
    assert!(!text.contains("mine"), "{text}");
    assert!(
        text.contains("report report:b") && text.contains("card 7") && text.contains("job j1"),
        "{text}"
    );
}

#[test]
fn agent_start_args_carry_a_role_the_hub_refuses() {
    // the role is the user's: nothing a message says is read as a role
    assert_eq!(
        serde_json::from_value::<norn::tools::manager::AgentStartArgs>(
            json!({"profile": "p", "role": "manager"})
        )
        .unwrap()
        .role,
        Some(Role::Manager)
    );
}

#[test]
fn delegated_cells_round_trip_through_the_store() {
    let e = Effective {
        cells: [
            (
                Action::CodeEdit,
                Cell {
                    verdict: Verdict::Never,
                    limit: None,
                },
            ),
            (
                Action::Spend,
                Cell {
                    verdict: Verdict::Allow,
                    limit: Some(runstav::methods::matrix::Limit {
                        amount: 2.0,
                        unit: Unit::Usd,
                    }),
                },
            ),
        ]
        .into_iter()
        .collect(),
    };
    let d = Delegation {
        cells: e,
        manager: Some(Manager {
            who: mgr(),
            project: Some("project:q".into()),
            plan: None,
        }),
    };
    assert_eq!(cells_from(&cells_json(&d)), Some(d));
    // a lost one stays lost
    assert_eq!(
        cells_from(&cells_json(&Delegation::default())),
        Some(Delegation::default())
    );
    // unreadable (or the old form without its manager): nothing, and the caller gives the worker nothing
    assert_eq!(cells_from("not json"), None);
    assert_eq!(cells_from("[]"), None);
    assert_eq!(
        Effective::default().cell(Action::CodeEdit).verdict,
        Verdict::Never
    );
}
