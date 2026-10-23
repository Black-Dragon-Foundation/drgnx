//! The class guard (Task 2 implements the check; norn registers its rules, Task 10): an entity kind, or a `kv` key
//! prefix, that only one class may write. [`super::entity::create`] and [`super::entity::update`] check it on every
//! path (proposed txs and imports included); norn's `kv` writer checks keys (Task 12). Generic: it knows no kind.
#![allow(unused_variables, unused_imports, dead_code)] // Task 0's skeleton: Task 2 removes this line.

use std::collections::BTreeMap;

use super::tx::{Class, TxMeta};
use super::writer::WriteError;

/// The registered rules: kind → (class, refusal text), and key prefix → (class, refusal text).
#[derive(Clone, Debug, Default)]
pub struct Guard {
    kinds: BTreeMap<String, (Class, &'static str)>,
    keys: Vec<(String, Class, &'static str)>,
}

/// Writes of entities of KIND need CLASS; any other class is `Refused(REFUSAL)` (e.g. "grants are the user's").
pub fn register(guard: &mut Guard, kind: &str, class: Class, refusal: &'static str) {
    todo!("Task 2")
}

/// Writes of `kv` keys starting with PREFIX need CLASS; any other class is `Refused(REFUSAL)`.
pub fn register_key_prefix(guard: &mut Guard, prefix: &str, class: Class, refusal: &'static str) {
    todo!("Task 2")
}

/// Whether META's class may write an entity of KIND. An unregistered kind passes.
pub fn check(guard: &Guard, meta: &TxMeta, kind: &str) -> Result<(), WriteError> {
    todo!("Task 2")
}

/// Whether META's class may write the `kv` key KEY. A key no prefix matches passes.
pub fn check_key(guard: &Guard, meta: &TxMeta, key: &str) -> Result<(), WriteError> {
    todo!("Task 2")
}
