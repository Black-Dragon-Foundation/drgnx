//! No backend: every spec is refused with the reason, and nothing runs (Task 13).

use crate::validate::{Refusal, Rule};

/// Why nothing can run here: `why` names what is missing. Never an unconfined run instead.
pub fn refusal(why: &str) -> Refusal {
    Refusal {
        rule: Rule::Setup,
        path: None,
        message: format!("no sandbox backend: {why}; nothing is run without one"),
    }
}
