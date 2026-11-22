//! Which device embeds: chosen by measuring, never by asking.
//!
//! 1. A cached [`Choice`] whose key matches is used. The key names the model, [`ENGINE_VERSION`] and each adapter
//!    with its driver, so a driver update or a kernel change measures again.
//! 2. On battery with no cached choice: the CPU path, nothing probed and nothing to cache (a figure taken on battery
//!    would be wrong on AC).
//! 3. Otherwise the first adapter of [`order`] that passes its self-check, and the CPU path, are probed, and the
//!    faster one is taken: a slow iGPU loses to a few CPU cores.
//! 4. A device whose vector misses the stored one (cosine under [`SELF_CHECK`]) is out, and the next adapter takes its
//!    place. When the CPU path misses too, nothing is usable and only keyword and symbol results remain.
//!
//! The caller writes the choice to its cache file; no adapter at all (no loader, a container without `/dev/dri`)
//! means the CPU path, and nothing asks.

use crate::gpu::{AdapterFacts, AdapterKind};
use crate::local::{Device, EmbedFail, LocalEmbedder};
use crate::models::{LoadError, ModelSpec};
use serde_json::{Value, json};
use std::path::Path;
use std::time::Instant;

/// Raised on a kernel change, so every cached choice measures again.
pub const ENGINE_VERSION: u32 = 1;

/// The least cosine to the stored self-check vector a device must reach.
pub const SELF_CHECK: f32 = 0.999;

/// One device's probe: its speed on the self-check text and how close it came to the stored vector.
#[derive(Debug, Clone, PartialEq)]
pub struct Candidate {
    pub device: Device,
    pub tokens_per_s: f64,
    pub cosine: f32,
}

/// The device to embed with, the key it was chosen under, and why. `usable` is false when no device passed its
/// self-check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Choice {
    pub device: Device,
    pub key: String,
    pub why: String,
    pub usable: bool,
}

impl Choice {
    /// The cache file's content.
    pub fn to_json(&self) -> String {
        let device = match &self.device {
            Device::Cpu { threads } => json!({ "cpu": threads }),
            Device::Gpu { adapter } => json!({ "gpu": adapter }),
        };
        json!({"device": device, "key": self.key, "why": self.why, "usable": self.usable})
            .to_string()
    }

    /// A cache file's content back; none when it is not one.
    pub fn parse(text: &str) -> Option<Choice> {
        let v: Value = serde_json::from_str(text).ok()?;
        let d = &v["device"];
        let device = if let Some(threads) = d["cpu"].as_u64() {
            Device::Cpu {
                threads: usize::try_from(threads).ok()?.max(1),
            }
        } else {
            Device::Gpu {
                adapter: d["gpu"].as_str()?.to_string(),
            }
        };
        Some(Choice {
            device,
            key: v["key"].as_str()?.to_string(),
            why: v["why"].as_str()?.to_string(),
            usable: v["usable"].as_bool()?,
        })
    }
}

fn rank(a: &AdapterFacts) -> u8 {
    match a.kind {
        _ if a.metal => 0, // Apple GPUs: unified memory, so they count as discrete
        AdapterKind::Discrete => 0,
        AdapterKind::Integrated => 1,
        AdapterKind::Other | AdapterKind::Software => 2,
    }
}

/// The adapters worth probing, best first: software ones dropped, then discrete (and Metal), then integrated.
pub fn order(adapters: &[AdapterFacts]) -> Vec<AdapterFacts> {
    let mut out: Vec<AdapterFacts> = adapters
        .iter()
        .filter(|a| a.kind != AdapterKind::Software)
        .cloned()
        .collect();
    out.sort_by_key(rank);
    out
}

/// The key a choice is cached under.
pub fn key(model: &str, order: &[AdapterFacts]) -> String {
    let mut k = format!("{model}; engine {ENGINE_VERSION}");
    for a in order {
        k.push_str(&format!("; {} ({})", a.name, a.driver));
    }
    k
}

fn name(d: &Device) -> String {
    match d {
        Device::Cpu { threads } => format!("the CPU path ({threads} threads)"),
        Device::Gpu { adapter } => adapter.clone(),
    }
}

/// The rule in this module's header. `probe` measures one device (the real one is [`probe`]).
pub fn choose(
    model: &str,
    on_battery: bool,
    order: &[AdapterFacts],
    cached: Option<&Choice>,
    probe: &mut dyn FnMut(&Device) -> Result<Candidate, LoadError>,
    threads: usize,
) -> Choice {
    let key = key(model, order);
    if let Some(c) = cached
        && c.key == key
    {
        return c.clone();
    }
    let cpu = Device::Cpu { threads };
    if on_battery {
        return Choice {
            device: cpu,
            key,
            why: "on battery: the CPU path, nothing measured".into(),
            usable: true,
        };
    }
    let mut misses = Vec::new();
    let mut passed = |d: &Device, misses: &mut Vec<String>| match probe(d) {
        Ok(c) if c.cosine >= SELF_CHECK => Some(c),
        Ok(c) => {
            misses.push(format!(
                "{} missed its self-check (cosine {:.4})",
                name(d),
                c.cosine
            ));
            None
        }
        Err(e) => {
            misses.push(format!("{}: {e}", name(d)));
            None
        }
    };
    let mut gpu = None;
    for a in order {
        let d = Device::Gpu {
            adapter: a.name.clone(),
        };
        if let Some(c) = passed(&d, &mut misses) {
            gpu = Some(c);
            break;
        }
    }
    let on_cpu = passed(&cpu, &mut misses);
    let with_misses = |why: String| {
        if misses.is_empty() {
            why
        } else {
            format!("{why}; {}", misses.join("; "))
        }
    };
    let (device, why, usable) = match (gpu, on_cpu) {
        (Some(g), Some(c)) if g.tokens_per_s >= c.tokens_per_s => (
            g.device.clone(),
            format!(
                "{} is faster: {:.0} tokens/s against the CPU path's {:.0}",
                name(&g.device),
                g.tokens_per_s,
                c.tokens_per_s
            ),
            true,
        ),
        (Some(g), Some(c)) => (
            c.device,
            format!(
                "the CPU path is faster: {:.0} tokens/s against {}'s {:.0}",
                c.tokens_per_s,
                name(&g.device),
                g.tokens_per_s
            ),
            true,
        ),
        (Some(g), None) => (
            g.device.clone(),
            format!("{}: the only device that passed", name(&g.device)),
            true,
        ),
        (None, Some(c)) if order.is_empty() => {
            (c.device, "no GPU adapter: the CPU path".to_string(), true)
        }
        (None, Some(c)) => (c.device, "no GPU passed: the CPU path".to_string(), true),
        (None, None) => (
            cpu,
            "no device passed its self-check: keyword and symbol results only".to_string(),
            false,
        ),
    };
    Choice {
        device,
        key,
        why: with_misses(why),
        usable,
    }
}

/// A model's self-check: one fixed text, longer than the local attention span, and its reference vector.
struct SelfCheck {
    text: String,
    vector: Vec<f32>,
}

fn self_check(id: &str) -> Option<SelfCheck> {
    let text = match id {
        "gte-modernbert-base" => include_str!("../data/gte-modernbert-base.selfcheck.json"),
        "granite-embedding-small-english-r2" => {
            include_str!("../data/granite-embedding-small-english-r2.selfcheck.json")
        }
        _ => return None,
    };
    let v: Value = serde_json::from_str(text).ok()?;
    Some(SelfCheck {
        text: v["text"].as_str()?.to_string(),
        vector: v["vector"]
            .as_array()?
            .iter()
            .map(|x| x.as_f64().map(|f| f as f32))
            .collect::<Option<Vec<f32>>>()?,
    })
}

fn failed(e: EmbedFail) -> LoadError {
    match e {
        EmbedFail::DeviceLost(m) | EmbedFail::Other(m) => LoadError::Device(m),
    }
}

/// One embedding of the self-check text on DEVICE: its speed (the second of two runs, so shader builds and caches
/// don't count) and its cosine to the stored vector.
pub fn probe(
    spec: &'static ModelSpec,
    dir: &Path,
    device: &Device,
) -> Result<Candidate, LoadError> {
    let check = self_check(spec.id)
        .ok_or_else(|| LoadError::Format(format!("{}: no self-check", spec.id)))?;
    let mut embedder = LocalEmbedder::load(spec, dir, device)?;
    let batch = [embedder.encode_doc(&check.text)];
    embedder.embed_ids(&batch).map_err(failed)?;
    let start = Instant::now();
    let forward = embedder.embed_ids(&batch).map_err(failed)?;
    let secs = start.elapsed().as_secs_f64().max(1e-9);
    let vector = forward
        .vectors
        .first()
        .ok_or_else(|| LoadError::Device("no vector".into()))?;
    let cosine = vector.iter().zip(&check.vector).map(|(a, b)| a * b).sum();
    Ok(Candidate {
        device: device.clone(),
        tokens_per_s: batch[0].len() as f64 / secs,
        cosine,
    })
}
