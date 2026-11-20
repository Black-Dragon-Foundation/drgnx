//! The Budgets page (`budgets/page/*`): the subscriptions' meters and the scope tree as hub-built kit rows
//! (docs/guide/agents.md, "Budgets"), read from `budget/tree` page by page and `pace/get` with history.

use super::method;
use super::view::check_ids;
use crate::registry::Method;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// `budgets/page/subscribe`: VIEW shows the Budgets page; its rows come as `view-patch` per display class.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Subscribe {
    pub view: String,
}

/// `budgets/page/set`: a change to VIEW: REFRESH reads the tree and the meters again.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Set {
    pub view: String,
    #[serde(default)]
    pub refresh: bool,
}

/// A view id: `budgets/page/close`.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ViewId {
    pub view: String,
}

pub(crate) fn methods() -> Vec<Method> {
    vec![
        method!(
            "budgets/page/subscribe", BudgetsPageSubscribe(Subscribe) -> bool,
            classes: [User], writes: false,
            doc: "a hub-fed view shows the Budgets page: the subscriptions' meters with their pace, then the scope tree (meter, spent per unit, an editable limit cell, forecast, burn, state; a run's share of its plan), read a page at a time",
            check: |p: &Subscribe| check_ids(&p.view, None),
        ),
        method!(
            "budgets/page/set", BudgetsPageSet(Set) -> bool,
            classes: [User], writes: false,
            doc: "a change to a Budgets page view: refresh reads the tree and the meters again",
            check: |p: &Set| check_ids(&p.view, None),
        ),
        method!(
            "budgets/page/close", BudgetsPageClose(ViewId) -> bool,
            classes: [User], writes: false,
            doc: "a Budgets page view is shown no more",
            check: |p: &ViewId| check_ids(&p.view, None),
        ),
    ]
}
