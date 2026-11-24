//! The one-time notice for GPUs beyond the chosen one (`search::engine_notice`; the user, 2026-11-24: a notice, never a
//! prompt; the answer is stored in settings and never asked again for the same set of GPUs).
//!
//! test-pattern: pure (D). Device lists and settings in, notice values and overrides out.

use ratatoskr::search::engine_notice::{
    Answer, DISMISS_COMMAND, NOTICE_ID, Offer, USE_COMMAND, answer_overrides, clear_notice,
    gpu_set_key,
};
use ratatoskr::search::engine_pick::{EngineDevice, GpuSet};
use ratatoskr::search::engine_setup::{EngineSettings, more_gpus};
use ratatoskr::settings::RuntimeValues;
use ratatoskr::settings::overrides::{Override, from_json};
use serde_json::json;

fn dev(id: &str, name: &str) -> EngineDevice {
    EngineDevice {
        id: id.into(),
        name: name.into(),
        total_mib: 8192,
        free_mib: Some(8000),
    }
}

fn two() -> Vec<EngineDevice> {
    vec![
        dev("CUDA1", "NVIDIA GeForce RTX 3060"),
        dev("Vulkan2", "Intel UHD"),
    ]
}

fn apply(list: &[Override]) -> RuntimeValues {
    let mut v = RuntimeValues::default();
    for o in list {
        from_json(&o.name, &o.value, &mut v).unwrap();
    }
    v
}

#[test]
fn one_gpu_is_no_notice() {
    assert_eq!(Offer::new().notice(&[], None), None);
}

#[test]
fn the_notice_names_the_extra_gpus_and_its_two_commands() {
    let n = Offer::new().notice(&two(), None).expect("a notice");
    assert_eq!(n["source"], "hub");
    assert_eq!(n["id"], NOTICE_ID);
    assert_eq!(n["life"], "condition", "it stays until answered");
    assert_eq!(n["severity"], "info");
    assert_eq!(n["command"], USE_COMMAND);
    assert_eq!(n["actions"], json!([DISMISS_COMMAND]));
    let text = n["text"].as_str().unwrap();
    assert!(
        text.contains("NVIDIA GeForce RTX 3060") && text.contains("Intel UHD"),
        "{text}"
    );
}

#[test]
fn it_is_shown_once_per_run() {
    let offer = Offer::new();
    assert!(offer.notice(&two(), None).is_some());
    assert_eq!(
        offer.notice(&two(), None),
        None,
        "never twice for the same set"
    );
}

#[test]
fn it_is_not_shown_again_after_use_or_dismiss() {
    let key = gpu_set_key(&two());
    for answer in [Answer::Use, Answer::Dismiss] {
        let v = apply(&answer_overrides(Vec::new(), answer, &key));
        assert_eq!(
            v.search_gpus_noticed.as_deref(),
            Some(key.as_str()),
            "{answer:?}"
        );
        // a fresh run reads the stored key
        assert_eq!(
            Offer::new().notice(&two(), v.search_gpus_noticed.as_deref()),
            None,
            "{answer:?}"
        );
    }
}

#[test]
fn use_turns_the_extra_gpu_setting_on_and_dismiss_leaves_it() {
    let key = gpu_set_key(&two());
    let used = apply(&answer_overrides(Vec::new(), Answer::Use, &key));
    assert_eq!(used.search_gpus.as_deref(), Some("all"));
    let st = EngineSettings::from_values(&used);
    assert_eq!(st.cfg.gpus, GpuSet::All);
    let dismissed = apply(&answer_overrides(Vec::new(), Answer::Dismiss, &key));
    assert_eq!(dismissed.search_gpus, None, "the setting stays as it was");
}

#[test]
fn an_answer_keeps_the_other_overrides_and_replaces_its_own() {
    let key = gpu_set_key(&two());
    let other = Override {
        name: "drgnx-search-cpu-limit".into(),
        value: json!(50),
        source: "editor".into(),
    };
    let first = answer_overrides(vec![other.clone()], Answer::Dismiss, &key);
    let second = answer_overrides(first, Answer::Use, &key);
    assert!(second.contains(&other));
    assert_eq!(
        second
            .iter()
            .filter(|o| o.name == "drgnx-search-gpus-noticed")
            .count(),
        1,
        "one value per setting"
    );
}

#[test]
fn a_different_set_of_gpus_may_show_it_once_more() {
    let old = gpu_set_key(&two());
    let more = vec![
        dev("CUDA1", "NVIDIA GeForce RTX 3060"),
        dev("CUDA2", "NVIDIA GeForce RTX 4090"),
    ];
    assert_ne!(old, gpu_set_key(&more));
    assert!(Offer::new().notice(&more, Some(&old)).is_some());
}

#[test]
fn clearing_names_the_notice_and_nothing_more() {
    let c = clear_notice();
    assert_eq!(c["id"], NOTICE_ID);
    assert_eq!(c["clear"], true);
}

#[test]
fn once_gpus_is_all_the_hub_has_no_extra_gpus_to_offer() {
    // the offer is made from `more_gpus`, which is empty for a set the user already chose
    let mut v = RuntimeValues::default();
    from_json("drgnx-search-gpus", &json!("all"), &mut v).unwrap();
    let st = EngineSettings::from_values(&v);
    let plan = ratatoskr::search::engine_pick::Plan::Wait {
        why: String::new(),
        options: Vec::new(),
    };
    assert!(more_gpus(&plan, &st.cfg).is_empty());
}
