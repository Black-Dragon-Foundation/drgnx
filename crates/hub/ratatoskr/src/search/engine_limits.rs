//! The user's limits on the local engine (2026-11-23: "offer memory limits like CPU limits, also actually add GPU
//! limits as well"). Each is enforced, not advisory, and hitting one slows indexing; it never fails it or falls back
//! silently.
//!
//! - **CPU** (`drgnx-search-cpu-limit`, a percent of the machine's CPUs): the engine's `-t` threads, and `cpu.max` through
//!   a transient systemd scope (`systemd-run --user --scope -p CPUQuota=`) where the user's manager runs.
//! - **Memory** (`drgnx-search-memory-limit`, MiB): `memory.max` through the same scope (`-p MemoryMax=`), and no swap.
//! - **VRAM** (`drgnx-search-vram-limit`, MiB): the model, context and ubatch are sized to it ([`vram_need_mib`]) and the
//!   device's free memory is checked before a start ([`vram_check`]); a start that does not fit is refused with the
//!   numbers, never started over the ceiling. No hard partitioning.
//! - **GPU busy** (`drgnx-search-gpu-busy`, a percent): batches are paced ([`hrafn_embed::pace::rest_after`]).

use std::ffi::OsString;
use std::path::PathBuf;

/// The user's limits; none set is no limit.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Limits {
    pub cpu_percent: Option<u32>,
    pub memory_mib: Option<u64>,
    pub vram_mib: Option<u64>,
    pub gpu_busy: Option<u32>,
}

impl Limits {
    /// A percent is 1 to 100; anything else is an error naming the setting.
    pub fn check(&self) -> Result<(), String> {
        for (name, v) in [
            ("drgnx-search-cpu-limit", self.cpu_percent),
            ("drgnx-search-gpu-busy", self.gpu_busy),
        ] {
            if v.is_some_and(|p| !(1..=100).contains(&p)) {
                return Err(format!("{name}: a percent from 1 to 100"));
            }
        }
        for (name, v) in [
            ("drgnx-search-memory-limit", self.memory_mib),
            ("drgnx-search-vram-limit", self.vram_mib),
        ] {
            if v == Some(0) {
                return Err(format!("{name}: MiB over 0"));
            }
        }
        Ok(())
    }

    /// The engine's `-t` threads of a machine with NCPU CPUs: the share, rounded up, at least one.
    pub fn threads(&self, ncpu: u32) -> Option<u32> {
        self.cpu_percent
            .map(|p| (ncpu * p).div_ceil(100).clamp(1, ncpu.max(1)))
    }
}

/// How the limits are held for one start.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Enforced {
    /// `cpu.max` and `memory.max` are set by a scope.
    pub cgroup: bool,
    /// What is not enforced and why (`doctor` shows it).
    pub notes: Vec<String>,
}

/// PROGRAM and ARGS wrapped in a systemd user scope holding the CPU and memory limits, when there are any and the
/// user's manager is there (SYSTEMD). The scope makes the process its own, so its process group stays the one `draugr`
/// made.
pub fn wrap(
    limits: &Limits,
    ncpu: u32,
    systemd: Option<PathBuf>,
    program: PathBuf,
    args: Vec<OsString>,
) -> (PathBuf, Vec<OsString>, Enforced) {
    let mut props: Vec<String> = Vec::new();
    if let Some(p) = limits.cpu_percent {
        props.push(format!(
            "CPUQuota={}%",
            u64::from(p) * u64::from(ncpu.max(1))
        ));
    }
    if let Some(m) = limits.memory_mib {
        props.push(format!("MemoryMax={m}M"));
        props.push("MemorySwapMax=0".into());
    }
    if props.is_empty() {
        return (program, args, Enforced::default());
    }
    let Some(run) = systemd else {
        let mut e = Enforced::default();
        e.notes.push(
            "the CPU and memory limits are not held by a cgroup here (no systemd user manager): the engine's thread count is all that holds the CPU limit"
                .into(),
        );
        return (program, args, e);
    };
    let mut wrapped: Vec<OsString> = ["--user", "--scope", "--quiet"]
        .iter()
        .map(OsString::from)
        .collect();
    for p in props {
        wrapped.push("-p".into());
        wrapped.push(p.into());
    }
    wrapped.push("--".into());
    wrapped.push(program.into_os_string());
    wrapped.extend(args);
    (
        run,
        wrapped,
        Enforced {
            cgroup: true,
            notes: Vec::new(),
        },
    )
}

/// The VRAM a start of the engine needs, in MiB: the weights, the runtime's own, the KV cache and the compute buffer
/// (each a rough per-token figure of the 0.6B embedding model; the check after the start compares it with the device).
pub fn vram_need_mib(gguf_bytes: u64, ctx: u32) -> u64 {
    const RUNTIME: u64 = 300;
    gguf_bytes.div_ceil(1 << 20) + RUNTIME + u64::from(ctx) * 3 / 8
}

/// Whether NEED MiB may start on a device with FREE MiB (unknown: not checked) under the user's CEILING.
pub fn vram_check(need: u64, free: Option<u64>, ceiling: Option<u64>) -> Result<(), String> {
    if let Some(c) = ceiling
        && need > c
    {
        return Err(format!(
            "the engine needs about {need} MiB of video memory for this context and the limit is {c} MiB (drgnx-search-vram-limit): it is not started"
        ));
    }
    if let Some(f) = free
        && need > f
    {
        return Err(format!(
            "the engine needs about {need} MiB of video memory and the device has {f} MiB free: it is not started (another program holds the rest)"
        ));
    }
    Ok(())
}

/// The VRAM the engine took, given the device's free memory before its start and after: over the ceiling, it is
/// stopped.
pub fn vram_over(
    before_free: Option<u64>,
    after_free: Option<u64>,
    ceiling: Option<u64>,
) -> Option<String> {
    let (b, a, c) = (before_free?, after_free?, ceiling?);
    let used = b.saturating_sub(a);
    (used > c).then(|| {
        format!(
            "the engine took {used} MiB of video memory, over the limit of {c} MiB (drgnx-search-vram-limit): it is stopped"
        )
    })
}
