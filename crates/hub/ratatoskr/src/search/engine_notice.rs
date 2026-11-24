//! The one-time notice for GPUs beyond the chosen one (the user, 2026-11-24).
//!
//! When the hub finds usable GPUs beyond the fastest, the editor shows one notice, once per set of GPUs: it names them
//! and offers two commands, [`USE_COMMAND`] (turns `drgnx-search-gpus` to `"all"`) and [`DISMISS_COMMAND`]. It is a
//! notice (`notice` event, tidindi's shape), never a prompt: nothing waits on it, and no daemon path asks a question.
//! The answer is stored in `drgnx-search-gpus-noticed` as the key of the set it was given for ([`gpu_set_key`]), so it
//! does not show again after either answer; a different set of GPUs shows it once more.
//!
//! The pure parts are here ([`Offer`], [`answer_overrides`]); the hub sends the notice and applies the answer.

use super::engine_pick::EngineDevice;
use crate::settings::overrides::Override;
use serde_json::{Value, json};
use std::sync::Mutex;

/// The notice's id: posting it again updates it in place.
pub const NOTICE_ID: &str = "search-extra-gpus";
/// The editor command that uses the extra GPUs (it calls `search/extra-gpus` with `answer: "use"`).
pub const USE_COMMAND: &str = "search-use-extra-gpus";
/// The editor command that dismisses the notice (`search/extra-gpus` with `answer: "dismiss"`).
pub const DISMISS_COMMAND: &str = "search-dismiss-extra-gpus";
/// The setting that holds the answered set's key.
pub const NOTICED: &str = "drgnx-search-gpus-noticed";
/// The setting the "use" answer turns on.
pub const GPUS: &str = "drgnx-search-gpus";

/// What the user answered.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Answer {
    Use,
    Dismiss,
}

/// The key of a set of GPUs: their ids and names, in order, so a new or replaced card makes a new key.
pub fn gpu_set_key(extra: &[EngineDevice]) -> String {
    let mut parts: Vec<String> = extra
        .iter()
        .map(|d| format!("{}={}", d.id, d.name))
        .collect();
    parts.sort();
    parts.join("|")
}

/// Which keys this run already sent the notice for.
#[derive(Default)]
pub struct Offer {
    shown: Mutex<Option<String>>,
}

impl Offer {
    pub fn new() -> Offer {
        Offer::default()
    }

    /// The notice for the EXTRA GPUs (the usable ones beyond the chosen), when there are some, ANSWERED (the stored
    /// key) is not their set's key and this run has not sent it yet.
    pub fn notice(&self, extra: &[EngineDevice], answered: Option<&str>) -> Option<Value> {
        if extra.is_empty() {
            return None;
        }
        let key = gpu_set_key(extra);
        if answered == Some(key.as_str()) {
            return None;
        }
        let mut shown = saman::lock(&self.shown);
        if shown.as_deref() == Some(key.as_str()) {
            return None;
        }
        *shown = Some(key);
        let names: Vec<String> = extra
            .iter()
            .map(|d| format!("{} ({} MiB)", d.name, d.total_mib))
            .collect();
        Some(json!({
            "source": "hub",
            "severity": "info",
            "id": NOTICE_ID,
            "life": "condition",
            "text": format!(
                "Search indexes on your fastest GPU. These GPUs can help too: {}. Use them, or dismiss this (it is not asked again).",
                names.join(", ")
            ),
            "command": USE_COMMAND,
            "actions": [DISMISS_COMMAND],
        }))
    }
}

/// The notice taken away once it is answered.
pub fn clear_notice() -> Value {
    json!({
        "source": "hub",
        "severity": "info",
        "id": NOTICE_ID,
        "life": "condition",
        "text": "",
        "clear": true,
    })
}

/// LIST (the global overrides) with the ANSWER for the set KEY: the noticed key always, and `drgnx-search-gpus` set to
/// `"all"` for a "use". A name appears once.
pub fn answer_overrides(mut list: Vec<Override>, answer: Answer, key: &str) -> Vec<Override> {
    let mut put = |name: &str, value: Value| {
        list.retain(|o| o.name != name);
        list.push(Override {
            name: name.to_owned(),
            value,
            source: "hub".into(),
        });
    };
    if answer == Answer::Use {
        put(GPUS, json!("all"));
    }
    put(NOTICED, json!(key));
    list
}
