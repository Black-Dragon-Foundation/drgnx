//! The local engine's setup from the user's settings and the machine: which assets to fetch, which are installed, which
//! devices they list, and the [`Plan`] that follows. One function ([`resolve`]) serves the engine's start, `doctor` and
//! the download's consent, so they never disagree about the pinned device.

use super::engine_install::{dir_for, installed};
use super::engine_limits::Limits;
use super::engine_pick::{
    self, BatteryGpu, Config, EngineDevice, GpuSet, Machine, NoGpu, Pin, Plan, VendorPick, Visible,
};
use crate::settings::RuntimeValues as Values;
use hrafn_embed::EngineAsset;
use std::path::{Path, PathBuf};

/// The engine's part of the user's settings, read.
#[derive(Clone, Debug, Default)]
pub struct EngineSettings {
    pub cfg: Config,
    pub limits: Limits,
    /// A setting whose value is refused: it is named in `doctor`, and its default holds.
    pub errors: Vec<String>,
}

impl EngineSettings {
    pub fn from_values(v: &Values) -> EngineSettings {
        let mut s = EngineSettings::default();
        let mut keep = |r: villa::Result<()>| {
            if let Err(e) = r {
                s.errors.push(e.to_string());
            }
        };
        let mut cfg = Config::default();
        keep(engine_pick::parse_gpu_set(v.search_gpus.as_deref()).map(|g| cfg.gpus = g));
        keep(
            engine_pick::parse_battery_gpu(v.search_battery_gpu.as_deref())
                .map(|b| cfg.battery = b),
        );
        keep(engine_pick::parse_no_gpu(v.search_no_gpu.as_deref()).map(|n| cfg.no_gpu = n));
        let limits = Limits {
            cpu_percent: v.search_cpu_limit,
            memory_mib: v.search_memory_limit,
            vram_mib: v.search_vram_limit,
            gpu_busy: v.search_gpu_busy,
        };
        let limits = match limits.check() {
            Ok(()) => limits,
            Err(e) => {
                s.errors.push(e.to_string());
                Limits::default()
            }
        };
        s.cfg = cfg;
        s.limits = limits;
        s
    }

    /// What the engine's choice depends on, as a key: a different one builds the pool again.
    pub fn key(&self, on_battery: bool) -> String {
        format!("{:?}|{:?}|{on_battery}", self.cfg, self.limits)
    }
}

/// An asset of the plan and where it stands.
#[derive(Clone, Debug)]
pub struct AssetState {
    pub asset: &'static EngineAsset,
    /// Its `llama-server`, once installed whole.
    pub exe: Option<PathBuf>,
    /// The devices it lists (none: not installed, or it does not answer).
    pub devices: Option<Vec<EngineDevice>>,
}

pub struct Resolved {
    pub picks: Vec<VendorPick>,
    /// The assets a download must hold for these settings, with their state.
    pub assets: Vec<AssetState>,
    pub plan: Plan,
    pub pin: Pin,
    pub pin_path: PathBuf,
}

/// Resolves the engine for CACHE (the hub's cache folder). It runs each installed asset's `--list-devices`.
pub fn resolve(
    cache: &Path,
    machine: &Machine,
    vis: &Visible,
    st: &EngineSettings,
    on_battery: bool,
) -> Resolved {
    let picks = engine_pick::vendor_picks(machine, vis);
    // every vendor's asset is listed (a settings change to "all" needs no second look), the download takes the chosen ones
    let mut states: Vec<AssetState> = Vec::new();
    let mut wanted = engine_pick::assets_to_install(&picks, &st.cfg);
    if wanted.is_empty()
        && matches!(st.cfg.no_gpu, NoGpu::Cpu | NoGpu::CpuIdle)
        && let Some(a) = hrafn_embed::engine_for(&machine.os, &machine.arch)
    {
        wanted.push(a);
    }
    for asset in wanted {
        let exe = installed(asset, &dir_for(cache, asset));
        let devices = exe
            .as_deref()
            .map(|e| engine_pick::parse_devices(&super::engine_doctor::list_devices(e)));
        states.push(AssetState {
            asset,
            exe,
            devices,
        });
    }
    let listed_all: Vec<EngineDevice> = states
        .iter()
        .flat_map(|s| s.devices.iter().flatten().cloned())
        .collect();
    let driver = machine.nvidia_driver;
    let key = engine_pick::pin_key(&listed_all, driver, hrafn_embed::models::ENGINE_TAG);
    let pin_path = cache.join("engines").join("pin.json");
    let pin = Pin::load(&pin_path, &key);
    let listed = |a: &EngineAsset| {
        states
            .iter()
            .find(|s| s.asset == a)
            .and_then(|s| s.devices.clone())
    };
    let plan = if picks.is_empty() {
        // no GPU at all: the plan's no-GPU branch (its CPU asset is listed when the user chose the CPU)
        match (st.cfg.no_gpu, states.first()) {
            (NoGpu::Cpu | NoGpu::CpuIdle, Some(s)) if s.exe.is_none() => Plan::Wait {
                why: format!("the CPU engine is not installed: {}", s.asset.id()),
                options: Vec::new(),
            },
            _ => engine_pick::plan(&picks, &st.cfg, &listed, &pin.rates, on_battery),
        }
    } else {
        engine_pick::plan(&picks, &st.cfg, &listed, &pin.rates, on_battery)
    };
    Resolved {
        picks,
        assets: states,
        plan,
        pin,
        pin_path,
    }
}

impl Resolved {
    /// The assets not installed yet, their archives and runtimes: what the download's consent names.
    pub fn to_download(&self) -> Vec<&'static EngineAsset> {
        self.assets
            .iter()
            .filter(|s| s.exe.is_none())
            .map(|s| s.asset)
            .collect()
    }
}

/// `drgnx-search-gpus` as the card offers it once: the usable GPUs beyond the fastest.
pub fn more_gpus(plan: &Plan, cfg: &Config) -> Vec<EngineDevice> {
    match plan {
        Plan::Gpu { ask_more, .. }
            if cfg.gpus == GpuSet::Fastest && cfg.battery != BatteryGpu::Integrated =>
        {
            ask_more.clone()
        }
        _ => Vec::new(),
    }
}

/// The consent a download needs: its total over ITEMS (name, bytes), and the text that names every item, the total and
/// the command to run. GIVEN is what the user's consent said (0: none); the text is the refusal when it is not the total.
pub fn consent_text(model: &str, given: u64, items: &[(String, u64)]) -> (u64, String) {
    let total: u64 = items.iter().map(|(_, b)| b).sum();
    let mut text = if given == 0 {
        String::from("this download needs your consent. It fetches:")
    } else {
        format!("the consent names {given} bytes, but this download is {total} bytes. It fetches:")
    };
    for (name, bytes) in items {
        text.push_str(&format!(
            "\n  {name}: {bytes} bytes ({} MiB)",
            bytes.div_ceil(1 << 20)
        ));
    }
    text.push_str(&format!(
        "\nin all {total} bytes ({} MiB). To consent, run:\n  ratatoskr search download {model} --consent-bytes {total}",
        total.div_ceil(1 << 20)
    ));
    (total, text)
}
