//! The one list of secret patterns (Urdr Task 9; storage §8.3): agent writes that look like a credential are refused
//! ("looks like a secret; do not store credentials"). Pure Rust, on the Android clippy list.
#![allow(unused_variables)] // Task 0's skeleton: Task 9 removes this line.

/// The name of the first rule TEXT matches, or `None`.
pub fn looks_like_secret(text: &str) -> Option<&'static str> {
    todo!("Task 9")
}
