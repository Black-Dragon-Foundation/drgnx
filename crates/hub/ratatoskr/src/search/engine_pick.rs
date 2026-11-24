//! Which llama.cpp build and which GPUs the local engine runs on (MP-20, revised 2026-11-23: "use ROCm for AMD, CUDA for
//! NVIDIA").
//!
//! Two steps, both pure over values a test states:
//!
//! 1. [`vendor_picks`]: from the machine's GPUs (what sysfs and `nvidia-smi` say, [`Machine::read`]) and the visible-device
//!    variables, the pinned asset of each vendor: CUDA for NVIDIA (the newest build the driver runs), ROCm for AMD on
//!    x64 when `/dev/kfd` is there and the card's gfx target is on [`ROCM_TARGETS`], Metal on macOS, Vulkan for Intel
//!    and for any GPU the vendor build cannot drive (the reason is kept, `doctor` names it). This decides what is
//!    downloaded, before any engine runs.
//! 2. [`plan`]: from the devices each installed engine lists (`--list-devices`, [`parse_devices`]) and the user's
//!    settings, the engines to run: the fastest GPU by default, more when the user said so, none silently on the CPU.
//!    A machine with no usable GPU waits for the user's choice ([`NoGpu`]); it never indexes on the CPU unasked.

use hrafn_embed::{EngineAsset, engine_for, engine_of};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::Path;

/// The AMD gfx targets the ROCm build of the pinned release carries device code for. Source: the code objects
/// (`amdgcn-amd-amdhsa--gfxNNNN`) inside `libggml-hip.so` of `llama-b12200-bin-ubuntu-rocm-10.0-x64.tar.gz`, read with
/// `strings` on the desktop (2026-11-24; `gfx1250` appears in the file as text only, with no code object). The asset
/// bundles no rocBLAS or HIP runtime: those come from the system's ROCm, so a card may still be refused by its own
/// libraries (`doctor` runs `--list-devices` to see). A card outside the list runs on Vulkan, with the reason.
pub const ROCM_TARGETS: &[&str] = &[
    "gfx908", "gfx90a", "gfx942", "gfx950", "gfx1010", "gfx1011", "gfx1012", "gfx1030", "gfx1031",
    "gfx1032", "gfx1033", "gfx1034", "gfx1035", "gfx1036", "gfx1100", "gfx1101", "gfx1102",
    "gfx1103", "gfx1150", "gfx1151", "gfx1152", "gfx1200", "gfx1201",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Vendor {
    Nvidia,
    Amd,
    Intel,
    Apple,
    Other,
}

impl Vendor {
    pub fn name(self) -> &'static str {
        match self {
            Vendor::Nvidia => "NVIDIA",
            Vendor::Amd => "AMD",
            Vendor::Intel => "Intel",
            Vendor::Apple => "Apple",
            Vendor::Other => "other",
        }
    }

    /// The vendor a device name (`NVIDIA GeForce RTX 4090`, `AMD Radeon RX 7900 XTX`) belongs to.
    pub fn of_name(name: &str) -> Vendor {
        let l = name.to_ascii_lowercase();
        let has = |keys: &[&str]| keys.iter().any(|k| l.contains(k));
        if has(&["nvidia", "geforce", "rtx", "quadro", "tesla", "gb10"]) {
            Vendor::Nvidia
        } else if has(&["amd", "radeon", "ryzen", "instinct"]) {
            Vendor::Amd
        } else if has(&["intel", "arc ", "iris", "uhd"]) {
            Vendor::Intel
        } else if has(&["apple"]) {
            Vendor::Apple
        } else {
            Vendor::Other
        }
    }
}

/// One GPU the host has, before any engine runs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostGpu {
    pub vendor: Vendor,
    pub name: String,
    pub vram_mib: Option<u64>,
    pub integrated: bool,
    /// An AMD card's gfx target (`gfx1100`), when `/dev/kfd` names it.
    pub gfx: Option<String>,
}

/// What the machine offers.
#[derive(Clone, Debug, Default)]
pub struct Machine {
    pub os: String,
    pub arch: String,
    pub gpus: Vec<HostGpu>,
    /// The NVIDIA driver's major version (`580`), when `nvidia-smi` says.
    pub nvidia_driver: Option<u32>,
    /// `/dev/kfd` exists.
    pub kfd: bool,
}

/// `CUDA_VISIBLE_DEVICES`, `ROCR_VISIBLE_DEVICES` and `HIP_VISIBLE_DEVICES` as the hub's environment has them.
#[derive(Clone, Debug, Default)]
pub struct Visible {
    pub cuda: Option<String>,
    pub rocr: Option<String>,
    pub hip: Option<String>,
}

impl Visible {
    pub fn from_env() -> Visible {
        let get = |k: &str| std::env::var(k).ok();
        Visible {
            cuda: get("CUDA_VISIBLE_DEVICES"),
            rocr: get("ROCR_VISIBLE_DEVICES"),
            hip: get("HIP_VISIBLE_DEVICES"),
        }
    }
}

/// The indices of N devices a visible-devices value SPEC leaves: unset keeps all, an empty value or one starting with
/// `-1` keeps none, a list of numbers keeps those (an id that is no number, a UUID, cannot be told apart here and keeps
/// all: the engine applies it itself).
pub fn visible(spec: Option<&str>, n: usize) -> Vec<usize> {
    let Some(spec) = spec else {
        return (0..n).collect();
    };
    let mut keep = Vec::new();
    for tok in spec.split(',').map(str::trim).filter(|t| !t.is_empty()) {
        match tok.parse::<i64>() {
            Ok(i) if i < 0 => break,
            Ok(i) if (i as usize) < n && !keep.contains(&(i as usize)) => keep.push(i as usize),
            Ok(_) => {}
            Err(_) => return (0..n).collect(),
        }
    }
    keep
}

/// The assets one vendor's GPUs run on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VendorPick {
    pub vendor: Vendor,
    /// How many of the vendor's GPUs are visible.
    pub gpus: usize,
    pub asset: &'static EngineAsset,
    /// Why this is the portable build and not the vendor's own (none when it is the vendor's).
    pub fallback: Option<String>,
    /// The best of the vendor's GPUs by [`speed_rank`].
    pub best: (bool, u64),
}

/// A rough speed order before anything is measured: a discrete GPU over an integrated one, then more memory.
pub fn speed_rank(g: &HostGpu) -> (bool, u64) {
    (!g.integrated, g.vram_mib.unwrap_or(0))
}

/// The gfx name of a `gfx_target_version` (`110000` is `gfx1100`, `90010` is `gfx90a`).
pub fn gfx_name(version: u64) -> String {
    format!(
        "gfx{}{}{:x}",
        version / 10000,
        (version / 100) % 100,
        version % 100
    )
}

/// The vendors of MACHINE's visible GPUs with their assets, the best vendor first.
pub fn vendor_picks(m: &Machine, vis: &Visible) -> Vec<VendorPick> {
    let mut picks = Vec::new();
    for vendor in [
        Vendor::Nvidia,
        Vendor::Amd,
        Vendor::Intel,
        Vendor::Apple,
        Vendor::Other,
    ] {
        let all: Vec<&HostGpu> = m.gpus.iter().filter(|g| g.vendor == vendor).collect();
        let keep: Vec<usize> = match vendor {
            Vendor::Nvidia => visible(vis.cuda.as_deref(), all.len()),
            Vendor::Amd => {
                let rocr = visible(vis.rocr.as_deref(), all.len());
                visible(vis.hip.as_deref(), rocr.len())
                    .into_iter()
                    .map(|p| rocr[p])
                    .collect()
            }
            _ => (0..all.len()).collect(),
        };
        let mine: Vec<&HostGpu> = keep.into_iter().map(|i| all[i]).collect();
        let Some(best) = mine.iter().map(|g| speed_rank(g)).max() else {
            continue;
        };
        let portable = engine_for(&m.os, &m.arch);
        let (asset, fallback) = match vendor {
            Vendor::Apple => (engine_of(&m.os, &m.arch, "metal", 0), None),
            Vendor::Nvidia => nvidia_asset(m),
            Vendor::Amd => amd_asset(m, &mine),
            _ => (portable, None),
        };
        let Some(asset) = asset.or(portable) else {
            continue;
        };
        picks.push(VendorPick {
            vendor,
            gpus: mine.len(),
            asset,
            fallback,
            best,
        });
    }
    picks.sort_by_key(|p| std::cmp::Reverse(p.best));
    picks
}

fn nvidia_asset(m: &Machine) -> (Option<&'static EngineAsset>, Option<String>) {
    let vulkan = |why: String| (engine_for(&m.os, &m.arch), Some(why));
    if m.os != "linux" {
        return vulkan(format!("drgnx pins no CUDA build for {}", m.os));
    }
    let Some(driver) = m.nvidia_driver else {
        return vulkan("no NVIDIA driver answers (nvidia-smi): the CUDA build needs one".into());
    };
    match engine_of(&m.os, &m.arch, "cuda", driver) {
        Some(a) => (Some(a), None),
        None => {
            let floor = hrafn_embed::engines_for(&m.os, &m.arch)
                .filter(|a| a.backend == "cuda")
                .map(|a| a.min_driver)
                .min();
            match floor {
                Some(f) => vulkan(format!(
                    "the NVIDIA driver {driver} is too old for the CUDA build (it needs {f} or newer): update the driver"
                )),
                None => vulkan(format!("drgnx pins no CUDA build for linux {}", m.arch)),
            }
        }
    }
}

fn amd_asset(m: &Machine, gpus: &[&HostGpu]) -> (Option<&'static EngineAsset>, Option<String>) {
    let vulkan = |why: String| (engine_for(&m.os, &m.arch), Some(why));
    if m.os != "linux" || m.arch != "x86_64" {
        return vulkan(format!("drgnx pins no ROCm build for {} {}", m.os, m.arch));
    }
    if !m.kfd {
        return vulkan("there is no /dev/kfd (the ROCm driver's compute node)".into());
    }
    let best = gpus.iter().max_by_key(|g| speed_rank(g));
    match best.and_then(|g| g.gfx.as_deref().map(|x| (x, g))) {
        Some((gfx, _)) if ROCM_TARGETS.contains(&gfx) => {
            (engine_of(&m.os, &m.arch, "rocm", 0), None)
        }
        Some((gfx, _)) => vulkan(format!(
            "{gfx} is not a target of the ROCm build ({}): it runs on Vulkan",
            ROCM_TARGETS.join(", ")
        )),
        None => vulkan("ROCm does not name the card (no gfx target in /sys/class/kfd)".into()),
    }
}

impl Machine {
    /// This machine: the GPUs sysfs lists (vendor ids), their memory, `nvidia-smi` for NVIDIA, `/sys/class/kfd` for the
    /// AMD cards' gfx targets.
    pub fn read() -> Machine {
        let mut m = Machine {
            os: std::env::consts::OS.into(),
            arch: std::env::consts::ARCH.into(),
            kfd: Path::new("/dev/kfd").exists(),
            ..Machine::default()
        };
        if m.os == "macos" {
            m.gpus.push(HostGpu {
                vendor: Vendor::Apple,
                name: "Apple GPU".into(),
                vram_mib: None,
                integrated: false,
                gfx: None,
            });
            return m;
        }
        let mut cards: Vec<_> = std::fs::read_dir("/sys/class/drm")
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| {
                let n = e.file_name().to_string_lossy().into_owned();
                n.strip_prefix("card")
                    .is_some_and(|d| !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit()))
            })
            .map(|e| e.path())
            .collect();
        cards.sort();
        let read = |p: &Path| std::fs::read_to_string(p).ok().map(|s| s.trim().to_owned());
        let smi = nvidia_smi();
        m.nvidia_driver = smi.first().and_then(|r| r.driver);
        let (mut nv, mut amd) = (0, 0);
        let gfx = kfd_gfx();
        for c in cards {
            let id = read(&c.join("device/vendor")).unwrap_or_default();
            let vram = read(&c.join("device/mem_info_vram_total"))
                .and_then(|s| s.parse::<u64>().ok())
                .map(|b| b / (1 << 20));
            match id.as_str() {
                "0x10de" => {
                    let row = smi.get(nv);
                    nv += 1;
                    m.gpus.push(HostGpu {
                        vendor: Vendor::Nvidia,
                        name: row.map_or_else(|| "NVIDIA GPU".into(), |r| r.name.clone()),
                        vram_mib: row.and_then(|r| r.vram_mib),
                        integrated: false,
                        gfx: None,
                    });
                }
                "0x1002" => {
                    let g = gfx.get(amd).cloned();
                    amd += 1;
                    m.gpus.push(HostGpu {
                        vendor: Vendor::Amd,
                        name: "AMD GPU".into(),
                        vram_mib: vram,
                        // an APU's carve-out is small
                        integrated: vram.is_some_and(|v| v < 2048),
                        gfx: g,
                    });
                }
                "0x8086" => m.gpus.push(HostGpu {
                    vendor: Vendor::Intel,
                    name: "Intel GPU".into(),
                    vram_mib: vram,
                    integrated: vram.is_none(),
                    gfx: None,
                }),
                _ => {}
            }
        }
        m
    }
}

struct SmiRow {
    name: String,
    vram_mib: Option<u64>,
    driver: Option<u32>,
}

fn nvidia_smi() -> Vec<SmiRow> {
    let out = std::process::Command::new("nvidia-smi")
        .args([
            "--query-gpu=name,memory.total,driver_version",
            "--format=csv,noheader,nounits",
        ])
        .stdin(std::process::Stdio::null())
        .output();
    let Ok(out) = out else { return Vec::new() };
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split(',').map(str::trim).collect();
            (f.len() == 3).then(|| SmiRow {
                name: f[0].to_owned(),
                vram_mib: f[1].parse().ok(),
                driver: f[2].split('.').next().and_then(|d| d.parse().ok()),
            })
        })
        .collect()
}

/// The gfx name of each GPU node of `/sys/class/kfd/kfd/topology/nodes`, in node order (a CPU node says 0).
fn kfd_gfx() -> Vec<String> {
    let mut nodes: Vec<_> = std::fs::read_dir("/sys/class/kfd/kfd/topology/nodes")
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .collect();
    nodes.sort_by_key(|p| {
        p.file_name()
            .and_then(|n| n.to_str())
            .and_then(|n| n.parse::<u32>().ok())
    });
    nodes
        .iter()
        .filter_map(|n| std::fs::read_to_string(n.join("properties")).ok())
        .filter_map(|props| {
            props.lines().find_map(|l| {
                l.strip_prefix("gfx_target_version ")
                    .and_then(|v| v.trim().parse::<u64>().ok())
            })
        })
        .filter(|&v| v > 0)
        .map(gfx_name)
        .collect()
}

/// One device an engine lists (`--list-devices`).
#[derive(Clone, Debug, PartialEq)]
pub struct EngineDevice {
    /// What `--device` takes: `ROCm0`, `CUDA1`, `Vulkan0`, `MTL0`.
    pub id: String,
    pub name: String,
    pub total_mib: u64,
    pub free_mib: Option<u64>,
}

impl EngineDevice {
    pub fn vendor(&self) -> Vendor {
        Vendor::of_name(&self.name)
    }

    /// A software rasteriser is no GPU.
    pub fn software(&self) -> bool {
        let l = self.name.to_ascii_lowercase();
        ["llvmpipe", "lavapipe", "swiftshader", "software"]
            .iter()
            .any(|s| l.contains(s))
    }

    /// An integrated GPU, by what its name says (`Ryzen`, `Radeon Graphics`, Intel's UHD and Iris, not Arc).
    pub fn integrated(&self) -> bool {
        let l = self.name.to_ascii_lowercase();
        if l.contains("arc ") || l.contains("arc(") {
            return false;
        }
        [
            "ryzen",
            "radeon graphics",
            "intel(r)",
            "uhd",
            "iris",
            "integrated",
        ]
        .iter()
        .any(|s| l.contains(s))
    }

    /// Its rank before anything is measured.
    pub fn rank(&self) -> (bool, u64) {
        (!self.integrated(), self.total_mib)
    }
}

/// The GPU devices in the text of `llama-server --list-devices`:
/// `  ROCm0: AMD Radeon RX 7900 XTX (24560 MiB, 22212 MiB free)` or `  Vulkan0: ... (RADV NAVI31) (24560 MiB)`.
/// The `CPU` line is no GPU and is left out.
pub fn parse_devices(text: &str) -> Vec<EngineDevice> {
    text.lines()
        .filter_map(|l| {
            let (id, rest) = l.trim().split_once(": ")?;
            let name_part = id.trim_end_matches(|c: char| c.is_ascii_digit());
            if id == name_part
                || name_part == "CPU"
                || !id.bytes().all(|b| b.is_ascii_alphanumeric())
            {
                return None;
            }
            let (name, mem) = rest.trim_end().strip_suffix(')')?.rsplit_once(" (")?;
            let mut nums = mem.split(',').map(|p| {
                p.split_whitespace()
                    .next()
                    .and_then(|n| n.parse::<u64>().ok())
            });
            let total = nums.next()??;
            let free = nums.next().flatten();
            Some(EngineDevice {
                id: id.to_owned(),
                name: name.trim().to_owned(),
                total_mib: total,
                free_mib: free,
            })
        })
        .collect()
}

/// `drgnx-search-gpus`: which of the usable GPUs the engine pool uses.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub enum GpuSet {
    /// The fastest one (the default; the user is asked once whether to add the others).
    #[default]
    Fastest,
    All,
    /// The fastest N.
    Count(usize),
    /// These devices by id (`CUDA0`, `ROCm1`).
    Ids(Vec<String>),
}

/// `all`, `top:N` or `ids:ROCm0,CUDA1`; unset is the fastest only.
pub fn parse_gpu_set(v: Option<&str>) -> Result<GpuSet, String> {
    let Some(v) = v.map(str::trim).filter(|v| !v.is_empty()) else {
        return Ok(GpuSet::Fastest);
    };
    if v == "all" {
        return Ok(GpuSet::All);
    }
    if let Some(n) = v.strip_prefix("top:") {
        return n
            .parse::<usize>()
            .ok()
            .filter(|n| *n > 0)
            .map(GpuSet::Count)
            .ok_or_else(|| format!("drgnx-search-gpus: top:N needs a number over 0, not {n:?}"));
    }
    if let Some(ids) = v.strip_prefix("ids:") {
        let ids: Vec<String> = ids
            .split(',')
            .map(|s| s.trim().to_owned())
            .filter(|s| !s.is_empty())
            .collect();
        if !ids.is_empty() {
            return Ok(GpuSet::Ids(ids));
        }
    }
    Err(format!(
        "drgnx-search-gpus: {v:?} is none of \"all\", \"top:N\", \"ids:DEVICE,DEVICE\""
    ))
}

/// `drgnx-search-battery-gpu`: what the engine does on battery.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum BatteryGpu {
    /// Bulk indexing waits for AC (the default).
    #[default]
    Pause,
    /// Only the integrated GPU runs.
    Integrated,
    /// The chosen GPUs run as on AC.
    Discrete,
}

pub fn parse_battery_gpu(v: Option<&str>) -> Result<BatteryGpu, String> {
    match v.map(str::trim).filter(|v| !v.is_empty()) {
        None | Some("pause") => Ok(BatteryGpu::Pause),
        Some("igpu") => Ok(BatteryGpu::Integrated),
        Some("dgpu") => Ok(BatteryGpu::Discrete),
        Some(o) => Err(format!(
            "drgnx-search-battery-gpu: {o:?} is none of \"pause\", \"igpu\", \"dgpu\""
        )),
    }
}

/// `drgnx-search-no-gpu`: what a machine with no usable GPU does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum NoGpu {
    /// Not chosen yet: bulk indexing waits and `doctor` offers the options.
    #[default]
    Ask,
    /// Index on the CPU, within the CPU limit.
    Cpu,
    /// Index on the CPU only while the machine is idle.
    CpuIdle,
    /// No local engine: a pack or a remote GPU supplies the vectors.
    Pack,
}

pub fn parse_no_gpu(v: Option<&str>) -> Result<NoGpu, String> {
    match v.map(str::trim).filter(|v| !v.is_empty()) {
        None => Ok(NoGpu::Ask),
        Some("cpu") => Ok(NoGpu::Cpu),
        Some("cpu-idle") => Ok(NoGpu::CpuIdle),
        Some("pack") => Ok(NoGpu::Pack),
        Some(o) => Err(format!(
            "drgnx-search-no-gpu: {o:?} is none of \"cpu\", \"cpu-idle\", \"pack\""
        )),
    }
}

/// The user's choices that decide the engines.
#[derive(Clone, Debug, Default)]
pub struct Config {
    pub gpus: GpuSet,
    pub battery: BatteryGpu,
    pub no_gpu: NoGpu,
}

/// The measured rates of the devices, vectors per second, by device id; kept with the pin.
pub type Rates = BTreeMap<String, f64>;

/// One engine of the pool: a device of an installed asset.
#[derive(Clone, Debug)]
pub struct Member {
    pub asset: &'static EngineAsset,
    pub device: EngineDevice,
}

/// What the hub runs.
#[derive(Clone, Debug)]
pub enum Plan {
    /// One engine per member, each `--device ID --split-mode none`.
    Gpu {
        members: Vec<Member>,
        /// Usable GPUs beyond the members, when the user was not asked yet (the card's question).
        ask_more: Vec<EngineDevice>,
        notes: Vec<String>,
    },
    /// The CPU engine, by the user's choice.
    Cpu {
        asset: &'static EngineAsset,
        idle_only: bool,
        notes: Vec<String>,
    },
    /// Nothing runs: bulk indexing waits, and why.
    Wait { why: String, options: Vec<String> },
}

impl Plan {
    /// The doctor's JSON section.
    pub fn json(&self) -> Value {
        match self {
            Plan::Gpu {
                members,
                ask_more,
                notes,
            } => json!({
                "mode": "gpu",
                "members": members.iter().map(|m| json!({
                    "asset": m.asset.id(), "device": m.device.id, "name": m.device.name,
                    "vram_mib": m.device.total_mib,
                })).collect::<Vec<_>>(),
                "ask_more": ask_more.iter().map(|d| format!("{}: {}", d.id, d.name)).collect::<Vec<_>>(),
                "notes": notes,
            }),
            Plan::Cpu {
                asset,
                idle_only,
                notes,
            } => json!({
                "mode": if *idle_only { "cpu-idle" } else { "cpu" },
                "asset": asset.id(), "notes": notes,
            }),
            Plan::Wait { why, options } => json!({"mode": "wait", "why": why, "options": options}),
        }
    }
}

/// The options a machine with no usable GPU is offered, as the doctor and the status word them.
pub fn no_gpu_options() -> Vec<String> {
    vec![
        "a pack or a remote GPU: `ratatoskr search import PACK`, or a `vectors` provider (the desktop's service); set drgnx-search-no-gpu to \"pack\"".into(),
        "CPU indexing within a CPU limit: set drgnx-search-no-gpu to \"cpu\" and drgnx-search-cpu-limit to the share of the CPUs".into(),
        "CPU indexing only while the machine is idle: set drgnx-search-no-gpu to \"cpu-idle\"".into(),
    ]
}

fn usable(d: &EngineDevice) -> bool {
    !d.software()
}

/// The engines to run. `LISTED` gives the devices an installed asset lists (none: it is not installed or does not
/// answer). `PICKS` are [`vendor_picks`]'s; RATES the measured speeds (they order the devices once every usable device
/// has one).
pub fn plan(
    picks: &[VendorPick],
    cfg: &Config,
    listed: &dyn Fn(&EngineAsset) -> Option<Vec<EngineDevice>>,
    rates: &Rates,
    on_battery: bool,
) -> Plan {
    let mut notes: Vec<String> = picks
        .iter()
        .filter_map(|p| {
            p.fallback.as_ref().map(|f| {
                format!(
                    "{}: Vulkan instead of the vendor build: {f}",
                    p.vendor.name()
                )
            })
        })
        .collect();
    let mut all: Vec<Member> = Vec::new();
    let mut missing: Vec<String> = Vec::new();
    for p in picks {
        match listed(p.asset) {
            None => missing.push(p.asset.id()),
            Some(devs) => all.extend(
                devs.into_iter()
                    .filter(|d| usable(d) && d.vendor() == p.vendor)
                    .map(|d| Member {
                        asset: p.asset,
                        device: d,
                    }),
            ),
        }
    }
    if all.is_empty() {
        if !missing.is_empty() {
            return Plan::Wait {
                why: format!(
                    "the engine is not installed or does not answer: {}",
                    missing.join(", ")
                ),
                options: Vec::new(),
            };
        }
        return no_gpu_plan(cfg, notes);
    }
    let measured = all
        .iter()
        .all(|m| rates.contains_key(&m.device.id) && rates[&m.device.id] > 0.0);
    all.sort_by(|a, b| {
        let order = if measured {
            rates[&b.device.id].total_cmp(&rates[&a.device.id])
        } else {
            b.device.rank().cmp(&a.device.rank())
        };
        order.then_with(|| a.device.id.cmp(&b.device.id))
    });
    let mut chosen: Vec<Member> = match &cfg.gpus {
        GpuSet::Fastest => all.iter().take(1).cloned().collect(),
        GpuSet::All => all.clone(),
        GpuSet::Count(n) => all.iter().take(*n).cloned().collect(),
        GpuSet::Ids(ids) => {
            let got: Vec<Member> = all
                .iter()
                .filter(|m| ids.contains(&m.device.id))
                .cloned()
                .collect();
            for id in ids
                .iter()
                .filter(|i| !got.iter().any(|m| &m.device.id == *i))
            {
                notes.push(format!(
                    "drgnx-search-gpus names {id}, which no engine lists"
                ));
            }
            got
        }
    };
    if chosen.is_empty() {
        chosen = all.iter().take(1).cloned().collect();
        notes.push("none of the GPUs drgnx-search-gpus names is there: the fastest runs".into());
    }
    if on_battery {
        match cfg.battery {
            BatteryGpu::Pause => {
                return Plan::Wait {
                    why: "on battery: bulk indexing waits for AC (drgnx-search-battery-gpu: \"igpu\" or \"dgpu\" runs on battery)".into(),
                    options: Vec::new(),
                };
            }
            BatteryGpu::Integrated => {
                chosen = all
                    .iter()
                    .filter(|m| m.device.integrated())
                    .take(1)
                    .cloned()
                    .collect();
                if chosen.is_empty() {
                    return Plan::Wait {
                        why: "on battery with no integrated GPU: bulk indexing waits for AC".into(),
                        options: Vec::new(),
                    };
                }
            }
            BatteryGpu::Discrete => {}
        }
    }
    let ask_more = if cfg.gpus == GpuSet::Fastest {
        all.iter()
            .filter(|m| !chosen.iter().any(|c| c.device.id == m.device.id))
            .map(|m| m.device.clone())
            .collect()
    } else {
        Vec::new()
    };
    Plan::Gpu {
        members: chosen,
        ask_more,
        notes,
    }
}

fn no_gpu_plan(cfg: &Config, mut notes: Vec<String>) -> Plan {
    match (cfg.no_gpu, engine_for(std::env::consts::OS, std::env::consts::ARCH)) {
        (NoGpu::Cpu | NoGpu::CpuIdle, Some(asset)) => {
            notes.push("no usable GPU: the CPU engine runs, as the user chose".into());
            Plan::Cpu {
                asset,
                idle_only: cfg.no_gpu == NoGpu::CpuIdle,
                notes,
            }
        }
        (NoGpu::Pack, _) => Plan::Wait {
            why: "no usable GPU: vectors come from a pack or a remote GPU (drgnx-search-no-gpu is \"pack\")".into(),
            options: Vec::new(),
        },
        _ => Plan::Wait {
            why: "no usable GPU: bulk indexing waits for your choice".into(),
            options: no_gpu_options(),
        },
    }
}

/// The pin: the devices the engine ran on and their measured rates, valid while the device list, the driver and the
/// engine tag are what they were. Another list measures again.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Pin {
    pub key: String,
    pub rates: Rates,
}

/// The key of a device list: change a device, a driver or the engine release and the rates are measured again.
pub fn pin_key(devices: &[EngineDevice], driver: Option<u32>, tag: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(tag.as_bytes());
    h.update(format!("{driver:?}").as_bytes());
    for d in devices {
        h.update(format!("\n{}|{}|{}", d.id, d.name, d.total_mib).as_bytes());
    }
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

impl Pin {
    /// The pin at PATH when its key is KEY; otherwise an empty one of that key.
    pub fn load(path: &Path, key: &str) -> Pin {
        let read = || -> Option<Pin> {
            let v: Value = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
            (v["key"] == key).then(|| Pin {
                key: key.to_owned(),
                rates: v["rates"]
                    .as_object()
                    .into_iter()
                    .flatten()
                    .filter_map(|(k, r)| Some((k.clone(), r.as_f64()?)))
                    .collect(),
            })
        };
        read().unwrap_or_else(|| Pin {
            key: key.to_owned(),
            rates: Rates::new(),
        })
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        let tmp = path.with_extension("json.new");
        std::fs::write(
            &tmp,
            json!({"key": self.key, "rates": self.rates}).to_string(),
        )?;
        std::fs::rename(tmp, path)
    }
}

/// The assets a download must fetch for the plan's vendors under CFG: the fastest vendor's only (the default), or
/// every vendor's when more than the fastest GPU may run.
pub fn assets_to_install(picks: &[VendorPick], cfg: &Config) -> Vec<&'static EngineAsset> {
    let take = match cfg.gpus {
        GpuSet::Fastest => 1,
        _ => picks.len(),
    };
    let mut out: Vec<&'static EngineAsset> = Vec::new();
    for p in picks.iter().take(take) {
        if !out.contains(&p.asset) {
            out.push(p.asset);
        }
    }
    out
}
