//! The device rule: which adapters count and in what order, and how `choose` picks a device by measuring it, with the
//! self-check, the battery rule and the cached choice.
//!
//! test-pattern: pure (D). The adapters are values and the probe is the test's closure: nothing opens a device.

use hrafn_embed::device::{Candidate, Choice, choose, key, order};
use hrafn_embed::{AdapterFacts, AdapterKind, Device, LoadError};

const MODEL: &str = "gte-modernbert-base";

fn adapter(name: &str, kind: AdapterKind) -> AdapterFacts {
    AdapterFacts {
        name: name.into(),
        kind,
        driver: "radv Mesa 26.2.5".into(),
        metal: false,
        f16: true,
    }
}

fn gpu(name: &str) -> Device {
    Device::Gpu {
        adapter: name.into(),
    }
}

const CPU: Device = Device::Cpu { threads: 4 };

fn names(list: &[AdapterFacts]) -> Vec<&str> {
    list.iter().map(|a| a.name.as_str()).collect()
}

/// A device's probe result: tokens/s and cosine, or why it would not load.
type Row = (Device, Result<(f64, f32), String>);

/// A probe that answers from a table and records what it was asked.
fn table(
    rows: Vec<Row>,
    asked: &mut Vec<Device>,
) -> impl FnMut(&Device) -> Result<Candidate, LoadError> + '_ {
    move |d: &Device| {
        asked.push(d.clone());
        let (_, row) = rows
            .iter()
            .find(|(k, _)| k == d)
            .unwrap_or_else(|| panic!("no row for {d:?}"));
        match row {
            Ok((tokens_per_s, cosine)) => Ok(Candidate {
                device: d.clone(),
                tokens_per_s: *tokens_per_s,
                cosine: *cosine,
            }),
            Err(e) => Err(LoadError::Device(e.clone())),
        }
    }
}

/// Pattern D.
#[test]
fn skips_software_adapters() {
    let got = order(&[
        adapter("llvmpipe (LLVM 21.1.8, 256 bits)", AdapterKind::Software),
        adapter(
            "AMD Radeon RX 7900 XTX (RADV NAVI31)",
            AdapterKind::Discrete,
        ),
    ]);
    assert_eq!(names(&got), ["AMD Radeon RX 7900 XTX (RADV NAVI31)"]);
    assert!(order(&[adapter("llvmpipe", AdapterKind::Software)]).is_empty());
}

/// Pattern D.
#[test]
fn discrete_before_integrated() {
    let got = order(&[
        adapter(
            "AMD Radeon Graphics (RADV RAPHAEL_MENDOCINO)",
            AdapterKind::Integrated,
        ),
        adapter("Virtual", AdapterKind::Other),
        adapter(
            "AMD Radeon RX 7900 XTX (RADV NAVI31)",
            AdapterKind::Discrete,
        ),
    ]);
    assert_eq!(
        names(&got),
        [
            "AMD Radeon RX 7900 XTX (RADV NAVI31)",
            "AMD Radeon Graphics (RADV RAPHAEL_MENDOCINO)",
            "Virtual"
        ]
    );
}

/// Pattern D.
#[test]
fn metal_counts_as_discrete() {
    let mut apple = adapter("Apple M2", AdapterKind::Integrated);
    apple.metal = true;
    let got = order(&[
        adapter("Intel(R) UHD Graphics", AdapterKind::Integrated),
        apple,
    ]);
    assert_eq!(names(&got), ["Apple M2", "Intel(R) UHD Graphics"]);
}

/// Pattern D. The Raphael iGPU against four of the 7900X's cores (M, the judgement): 7× slower.
#[test]
fn slower_gpu_loses_to_cpu() {
    let igpu = "AMD Radeon Graphics (RADV RAPHAEL_MENDOCINO)";
    let order = order(&[adapter(igpu, AdapterKind::Integrated)]);
    let mut asked = Vec::new();
    let mut probe = table(
        vec![
            (gpu(igpu), Ok((185.0, 0.99999))),
            (CPU, Ok((1294.0, 0.99999))),
        ],
        &mut asked,
    );
    let c = choose(MODEL, false, &order, None, &mut probe, 4);
    assert_eq!(c.device, CPU, "{}", c.why);
    assert!(c.usable);
    assert!(c.why.contains("faster"), "{}", c.why);
    drop(probe);
    assert_eq!(asked, [gpu(igpu), CPU]);
}

/// Pattern D.
#[test]
fn failed_self_check_takes_next() {
    let order = order(&[
        adapter("Bad Discrete", AdapterKind::Discrete),
        adapter("Good Integrated", AdapterKind::Integrated),
    ]);
    let mut asked = Vec::new();
    let mut probe = table(
        vec![
            (gpu("Bad Discrete"), Ok((30_000.0, 0.41))),
            (gpu("Good Integrated"), Ok((5_000.0, 0.99995))),
            (CPU, Ok((1_200.0, 0.99999))),
        ],
        &mut asked,
    );
    let c = choose(MODEL, false, &order, None, &mut probe, 4);
    assert_eq!(c.device, gpu("Good Integrated"), "{}", c.why);
    assert!(c.usable);
    assert!(
        c.why.contains("Bad Discrete"),
        "the miss is named: {}",
        c.why
    );
    drop(probe);
    assert_eq!(asked, [gpu("Bad Discrete"), gpu("Good Integrated"), CPU]);

    // one that fails to load is out the same way; a miss on the CPU path too leaves nothing usable
    let mut asked = Vec::new();
    let mut probe = table(
        vec![
            (gpu("Bad Discrete"), Err("out of memory".into())),
            (gpu("Good Integrated"), Ok((5_000.0, 0.2))),
            (CPU, Ok((1_200.0, 0.3))),
        ],
        &mut asked,
    );
    let c = choose(MODEL, false, &order, None, &mut probe, 4);
    assert_eq!(c.device, CPU);
    assert!(!c.usable, "no device passed: {}", c.why);
}

/// Pattern D. The key holds each adapter's driver, the model and the engine's version.
#[test]
fn cached_choice_needs_the_same_driver() {
    let rx = "AMD Radeon RX 7900 XTX (RADV NAVI31)";
    let before = order(&[adapter(rx, AdapterKind::Discrete)]);
    let cached = Choice {
        device: gpu(rx),
        key: key(MODEL, &before),
        why: "measured".into(),
        usable: true,
    };
    let back = Choice::parse(&cached.to_json()).expect("the cache file reads back");
    assert_eq!(back, cached);

    let mut asked = Vec::new();
    let mut probe = table(vec![], &mut asked);
    let c = choose(MODEL, false, &before, Some(&back), &mut probe, 4);
    assert_eq!(c, cached);
    drop(probe);
    assert!(asked.is_empty(), "a matching key measures nothing");

    let mut updated = adapter(rx, AdapterKind::Discrete);
    updated.driver = "radv Mesa 26.3.0".into();
    let after = order(&[updated]);
    assert_ne!(key(MODEL, &after), cached.key);
    assert_ne!(
        key("granite-embedding-small-english-r2", &before),
        cached.key
    );
    let mut asked = Vec::new();
    let mut probe = table(
        vec![(gpu(rx), Ok((27_000.0, 1.0))), (CPU, Ok((1_300.0, 1.0)))],
        &mut asked,
    );
    let c = choose(MODEL, false, &after, Some(&back), &mut probe, 4);
    assert_eq!(c.device, gpu(rx));
    assert_eq!(c.key, key(MODEL, &after));
    drop(probe);
    assert_eq!(asked.len(), 2, "a driver update measures again");
}

/// Pattern D.
#[test]
fn no_adapter_takes_cpu() {
    let mut asked = Vec::new();
    let six = Device::Cpu { threads: 6 };
    let mut probe = table(vec![(six, Ok((1_300.0, 0.99999)))], &mut asked);
    let c = choose(MODEL, false, &[], None, &mut probe, 6);
    assert_eq!(c.device, Device::Cpu { threads: 6 });
    assert!(c.usable);
    assert!(c.why.contains("no GPU"), "{}", c.why);
}

/// Pattern D. A figure taken on battery would be wrong on AC.
#[test]
fn battery_skips_calibration() {
    let rx = "AMD Radeon RX 7900 XTX (RADV NAVI31)";
    let order = order(&[adapter(rx, AdapterKind::Discrete)]);
    let mut asked = Vec::new();
    let mut probe = table(vec![], &mut asked);
    let c = choose(MODEL, true, &order, None, &mut probe, 4);
    assert_eq!(c.device, CPU);
    assert!(c.why.contains("battery"), "{}", c.why);
    // a cached choice still counts on battery
    let cached = Choice {
        device: gpu(rx),
        key: key(MODEL, &order),
        why: "measured".into(),
        usable: true,
    };
    assert_eq!(
        choose(MODEL, true, &order, Some(&cached), &mut probe, 4),
        cached
    );
    drop(probe);
    assert!(asked.is_empty(), "nothing is probed on battery");
}
