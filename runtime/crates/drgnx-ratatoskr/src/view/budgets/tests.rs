use super::*;
use drgnx_rows::kit::KitEnv;
use runstav::methods::timeline::{BudgetTree, Pace};
use serde_json::{Value, json};

fn kit() -> KitEnv<'static> {
    KitEnv {
        scale: 1.0,
        tty: false,
        glyphs: &[],
        ascii: false,
        density: Default::default(),
        icons: None,
    }
}

fn node(
    scope: Value,
    parent: Option<Value>,
    label: &str,
    limit: f64,
    spent: f64,
    share: Option<f64>,
) -> Value {
    json!({
        "scope": scope, "parent": parent, "label": label,
        "limits": [{"amount": limit, "unit": "usd-est"}],
        "spent": [{"amount": spent, "unit": "usd-est"}],
        "remaining": [{"amount": limit - spent, "unit": "usd-est"}],
        "state": "ok", "burn_per_hour": [], "share_of_parent": share
    })
}

fn tree() -> BudgetTree {
    serde_json::from_value(json!({
        "nodes": [
            node(json!({"plan": "p1"}), None, "Inbox drop-down", 40.0, 30.0, None),
            node(json!({"run": "j1"}), Some(json!({"plan": "p1"})), "run 1", 20.0, 18.0, Some(0.6)),
            node(json!({"run": "j2"}), Some(json!({"plan": "p1"})), "run 2", 20.0, 12.0, Some(0.4)),
        ],
        "next": null
    }))
    .expect("a tree")
}

fn pace(estimate: bool) -> Pace {
    serde_json::from_value(json!({
        "provider": "claude", "window": "week", "used_share": 0.42, "rate_per_hour": 0.01,
        "estimate": estimate
    }))
    .expect("a pace")
}

fn all_text(rows: &[drgnx_rows::Row]) -> String {
    rows.iter()
        .map(|r| r.text.as_str())
        .collect::<Vec<_>>()
        .join("\n")
}

/// The runs of a plan show their share of it, in the plan's binding unit.
#[test]
fn run_rows_show_their_share_of_the_plan() {
    let text = all_text(&rows(&tree(), &[], &kit()));
    assert!(text.contains("run 1") && text.contains("60 %"), "{text}");
    assert!(text.contains("run 2") && text.contains("40 %"), "{text}");
    // the plan itself has no share
    let plan = rows(&tree(), &[], &kit())
        .into_iter()
        .find(|r| r.text.contains("Inbox drop-down"))
        .expect("the plan row");
    assert!(!plan.text.contains(" %"), "{}", plan.text);
}

/// A limit cell is a kit text input that sets the scope's limit in place (`budget/set`): its row carries the action.
#[test]
fn a_limit_cell_is_an_input_that_sets_its_scope() {
    let rows = rows(&tree(), &[], &kit());
    let cell = rows
        .iter()
        .flat_map(|r| r.props.iter())
        .find(|p| p.2 == "drgnx-action" && p.3.get(0) == Some(&json!("budget-limit")))
        .expect("a limit cell with its action");
    // the action names the scope it sets: [kind, scope-kind, id, unit]
    assert_eq!(cell.3.get(1), Some(&json!("plan")));
    assert_eq!(cell.3.get(2), Some(&json!("p1")));
}

/// A subscription's meter says it is an estimate when the provider's pace is one; an exact one does not.
#[test]
fn subscriptions_are_labelled_estimates() {
    let est = all_text(&rows(&tree(), &[pace(true)], &kit()));
    assert!(est.contains("estimate"), "{est}");
    let exact = all_text(&rows(&tree(), &[pace(false)], &kit()));
    assert!(!exact.contains("estimate"), "{exact}");
}
