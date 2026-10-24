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

fn graph_stub() -> urdr::Connection {
    let c = urdr::Connection::open_in_memory().unwrap();
    c.execute_batch(
        "create table tx (id integer primary key, session text);
         create table entity (n integer primary key, id text, kind text, title text, status text, updated_tx integer);
         create table card (id integer primary key, kind text, title text, state text, tx integer);",
    )
    .unwrap();
    c
}

#[test]
fn a_digest_is_at_most_4_kib_and_says_what_it_left_out() {
    let c = graph_stub();
    c.execute(
        "insert into tx (id, session) values (1, 'session:other')",
        [],
    )
    .unwrap();
    for n in 0..400 {
        c.execute(
            "insert into entity (id, kind, title, status, updated_tx) values (?1, 'report', ?2, 'done', 1)",
            (format!("report:{n}"), "x".repeat(300)),
        )
        .unwrap();
    }
    let (text, upto) = digest(&c, 0, "mgr", &[]).unwrap();
    assert!(text.len() <= DIGEST_MAX, "{} bytes", text.len());
    assert!(text.contains("and "), "{text}");
    assert_eq!(upto, 1);
    // nothing after the last look: nothing to say
    assert_eq!(digest(&c, 1, "mgr", &[]).unwrap().0, "");
}

#[test]
fn a_digest_leaves_out_what_the_manager_wrote_itself() {
    let c = graph_stub();
    c.execute("insert into tx (id, session) values (1, 'session:mgr')", [])
        .unwrap();
    c.execute("insert into tx (id, session) values (2, 'session:w1')", [])
        .unwrap();
    c.execute(
        "insert into entity (id, kind, title, status, updated_tx) values ('task:a', 'task', 'mine', 'open', 1), ('report:b', 'report', 'theirs', 'done', 2)",
        [],
    )
    .unwrap();
    c.execute(
        "insert into card (id, kind, title, state, tx) values (7, 'matrix', 'push', 'open', 2)",
        [],
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
