//! Whether TEI (Hugging Face's text-embeddings-inference) runs on this machine's hardware (the user, 2026-11-24: "make TEI
//! an optional provider and also tell user if their hardware supports it").
//!
//! TEI is an optional provider kind (`tei`, `embed` capability): the user runs it, drgnx never installs, downloads or
//! starts it, and llama.cpp stays the only built-in engine. This module is a pinned table (below) and one pure function
//! over it: per device, supported / experimental / unsupported, the reason in a sentence, and the exact command that
//! runs TEI there (the podman form on Linux, brew on macOS). `doctor` prints it.
//!
//! The table is TEI's README at release [`VERSION`], read on [`CHECKED`] ([`SOURCE_URL`]):
//!
//! | Hardware | Support | Image tag |
//! |---|---|---|
//! | NVIDIA 7.5 Turing | experimental | `turing-1.9` |
//! | NVIDIA 8.0 | supported | `1.9` |
//! | NVIDIA 8.6 / 8.9 | supported | `86-1.9` / `89-1.9` |
//! | NVIDIA 9.0 Hopper | supported | `hopper-1.9` |
//! | NVIDIA Blackwell 10.0, 12.0, 12.1 (DGX Spark GB10) | experimental | `100-1.9`, `120-1.9`, `121-1.9` |
//! | NVIDIA below 7.5 (Volta, Pascal), or a driver below CUDA 12.2 | unsupported | none |
//! | AMD Instinct MI200 / MI300 | experimental | `rocm-latest` |
//! | AMD consumer Radeon (the RX 7900 included) | unsupported | none |
//! | Apple Silicon M1 to M4 | supported (Metal) | `brew install text-embeddings-inference` |
//! | Intel GPUs | unsupported (not in the README) | none |
//! | Linux CPU x86_64 / aarch64 | supported, but not for indexing | `cpu-1.9`, `cpu-arm64-1.9` |
//! | Windows, Android | no official build | none |

use super::engine_pick::{Machine, Vendor};
use serde_json::{Value, json};

/// The TEI release the table is from.
pub const VERSION: &str = "1.9";
/// The day the README was read.
pub const CHECKED: &str = "2026-11-24";
pub const SOURCE_URL: &str = "https://github.com/huggingface/text-embeddings-inference";

/// The model the printed commands serve (the one the engine indexes with, so the fingerprint is the same model's).
const MODEL: &str = "Qwen/Qwen3-Embedding-0.6B";
/// CUDA 12.2 needs an NVIDIA driver of at least this major version.
const MIN_DRIVER: u32 = 535;
const IMAGE: &str = "ghcr.io/huggingface/text-embeddings-inference";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Support {
    Supported,
    Experimental,
    Unsupported,
    /// No GPU: TEI runs on the CPU, which this product does not index on.
    CpuOnly,
}

impl Support {
    pub fn name(self) -> &'static str {
        match self {
            Support::Supported => "supported",
            Support::Experimental => "experimental",
            Support::Unsupported => "unsupported",
            Support::CpuOnly => "CPU only",
        }
    }
}

/// One device, as far as the table needs it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Device {
    pub vendor: Vendor,
    pub name: String,
    /// An NVIDIA card's compute capability (`(8, 9)`).
    pub compute_cap: Option<(u32, u32)>,
    /// The NVIDIA driver's major version.
    pub driver: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Verdict {
    /// The device's name, or `CPU` for a machine with no GPU.
    pub device: String,
    pub support: Support,
    pub reason: String,
    /// The command that runs TEI there; none when it does not.
    pub command: Option<String>,
}

impl Verdict {
    pub fn json(&self) -> Value {
        json!({
            "device": self.device, "support": self.support.name(), "reason": self.reason, "command": self.command,
        })
    }
}

fn podman(device_flags: &str, tag: &str) -> String {
    format!(
        "podman run --rm -p 8080:80 -v tei-data:/data {device_flags}{IMAGE}:{tag} --model-id {MODEL}"
    )
}

fn nvidia(d: &Device) -> Verdict {
    let (support, reason, tag) = match d.compute_cap {
        None => (
            Support::Unsupported,
            "the compute capability is unknown (nvidia-smi did not say), TEI needs 7.5 or newer"
                .to_owned(),
            None,
        ),
        Some((ma, mi)) if (ma, mi) < (7, 5) => (
            Support::Unsupported,
            format!(
                "compute capability {ma}.{mi} is below 7.5 (TEI needs Turing or newer; Volta and Pascal are out)"
            ),
            None,
        ),
        Some(_) if d.driver.is_some_and(|v| v < MIN_DRIVER) => (
            Support::Unsupported,
            format!(
                "driver {} is older than CUDA 12.2's ({MIN_DRIVER}), which TEI needs",
                d.driver.unwrap_or(0)
            ),
            None,
        ),
        Some((7, 5)) => (
            Support::Experimental,
            "Turing is experimental in TEI".into(),
            Some("turing"),
        ),
        Some((8, 0)) => (Support::Supported, "Ampere A100".into(), Some("")),
        Some((8, 6)) => (Support::Supported, "Ampere".into(), Some("86")),
        Some((8, 9)) => (Support::Supported, "Ada Lovelace".into(), Some("89")),
        Some((9, 0)) => (Support::Supported, "Hopper".into(), Some("hopper")),
        Some((10, 0)) => (
            Support::Experimental,
            "Blackwell is experimental in TEI".into(),
            Some("100"),
        ),
        Some((12, 0)) => (
            Support::Experimental,
            "Blackwell is experimental in TEI".into(),
            Some("120"),
        ),
        Some((12, 1)) => (
            Support::Experimental,
            "Blackwell GB10 (DGX Spark) is experimental in TEI".into(),
            Some("121"),
        ),
        Some((ma, mi)) => (
            Support::Unsupported,
            format!("compute capability {ma}.{mi} is not in TEI's README table"),
            None,
        ),
    };
    let command = tag.map(|t| {
        let tag = if t.is_empty() {
            VERSION.to_owned()
        } else {
            format!("{t}-{VERSION}")
        };
        podman("--device nvidia.com/gpu=all ", &tag)
    });
    Verdict {
        device: d.name.clone(),
        support,
        reason,
        command,
    }
}

fn amd(d: &Device) -> Verdict {
    let l = d.name.to_ascii_lowercase();
    let instinct = l.contains("instinct") && (l.contains("mi2") || l.contains("mi3"));
    if instinct {
        Verdict {
            device: d.name.clone(),
            support: Support::Experimental,
            reason: "AMD Instinct MI200 and MI300 are experimental in TEI (ROCm)".into(),
            command: Some(podman(
                "--device /dev/kfd --device /dev/dri ",
                "rocm-latest",
            )),
        }
    } else {
        Verdict {
            device: d.name.clone(),
            support: Support::Unsupported,
            reason: "TEI supports only AMD Instinct MI200 and MI300; consumer Radeon cards are unsupported".into(),
            command: None,
        }
    }
}

/// One verdict per device (a machine with no GPU gets one for the CPU), for OS (`linux`, `macos`, `windows`) and ARCH
/// (`x86_64`, `aarch64`).
pub fn verdicts(os: &str, arch: &str, devices: &[Device]) -> Vec<Verdict> {
    if os == "windows" {
        return vec![Verdict {
            device: "this machine".into(),
            support: Support::Unsupported,
            reason: "TEI has no official native Windows build".into(),
            command: None,
        }];
    }
    if os == "macos" {
        return devices
            .iter()
            .filter(|d| d.vendor == Vendor::Apple)
            .map(|d| Verdict {
                device: d.name.clone(),
                support: Support::Supported,
                reason: "Apple Silicon M1 to M4 runs TEI on Metal (Docker on macOS is CPU-only)"
                    .into(),
                command: Some("brew install text-embeddings-inference".into()),
            })
            .collect();
    }
    let mut out: Vec<Verdict> = devices
        .iter()
        .map(|d| match d.vendor {
            Vendor::Nvidia => nvidia(d),
            Vendor::Amd => amd(d),
            Vendor::Intel => Verdict {
                device: d.name.clone(),
                support: Support::Unsupported,
                reason: "Intel GPUs are not in TEI's README".into(),
                command: None,
            },
            Vendor::Apple | Vendor::Other => Verdict {
                device: d.name.clone(),
                support: Support::Unsupported,
                reason: "this GPU is not in TEI's README table".into(),
                command: None,
            },
        })
        .collect();
    if out.is_empty() {
        let tag = if arch == "aarch64" {
            format!("cpu-arm64-{VERSION}")
        } else {
            format!("cpu-{VERSION}")
        };
        out.push(Verdict {
            device: "CPU".into(),
            support: Support::CpuOnly,
            reason: "no GPU: TEI runs on the CPU, which is slow and not for indexing".into(),
            command: Some(podman("", &tag)),
        });
    }
    out
}

/// The text `doctor` prints: one block per device, then what TEI is to drgnx.
pub fn lines_of(v: &[Verdict]) -> String {
    section_lines(&json!({
        "version": VERSION, "checked": CHECKED, "source": SOURCE_URL,
        "verdicts": v.iter().map(Verdict::json).collect::<Vec<_>>(),
    }))
}

/// The devices of MACHINE for the table; CAPS are the NVIDIA cards' compute capabilities in `nvidia-smi` order. A
/// software or integrated GPU is not a candidate.
pub fn devices_of(m: &Machine, caps: &[(u32, u32)]) -> Vec<Device> {
    let mut nv = 0;
    m.gpus
        .iter()
        .filter(|g| !g.integrated)
        .map(|g| {
            let compute_cap = (g.vendor == Vendor::Nvidia).then(|| {
                nv += 1;
                caps.get(nv - 1).copied()
            });
            Device {
                vendor: g.vendor,
                name: g.name.clone(),
                compute_cap: compute_cap.flatten(),
                driver: (g.vendor == Vendor::Nvidia)
                    .then_some(m.nvidia_driver)
                    .flatten(),
            }
        })
        .collect()
}

/// The doctor's JSON section: the table's version and date, the verdicts.
pub fn section(m: &Machine, caps: &[(u32, u32)]) -> Value {
    let v = verdicts(&m.os, &m.arch, &devices_of(m, caps));
    json!({
        "version": VERSION, "checked": CHECKED, "source": SOURCE_URL,
        "verdicts": v.iter().map(Verdict::json).collect::<Vec<_>>(),
    })
}

/// [`lines_of`] for [`section`]'s JSON.
pub fn section_lines(v: &Value) -> String {
    let mut out = String::new();
    for x in v["verdicts"].as_array().into_iter().flatten() {
        out.push_str(&format!(
            "\nTEI on {}: {}: {}",
            x["device"].as_str().unwrap_or("?"),
            x["support"].as_str().unwrap_or("?"),
            x["reason"].as_str().unwrap_or("")
        ));
        if let Some(c) = x["command"].as_str() {
            out.push_str(&format!("\n  to run it: {c}"));
        }
    }
    out.push_str(&format!(
        "\nTEI is optional: llama.cpp is the built-in engine, and drgnx never installs or starts TEI; add a `tei` provider \
         that points at yours. Vectors from TEI and from llama.cpp are never mixed: another model or provider is another \
         fingerprint and a re-index. (TEI {}, README read {}: {})",
        v["version"].as_str().unwrap_or(VERSION),
        v["checked"].as_str().unwrap_or(CHECKED),
        v["source"].as_str().unwrap_or(SOURCE_URL)
    ));
    out
}
