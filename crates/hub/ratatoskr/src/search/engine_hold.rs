//! "A game or training job holds the GPU": the engine's hold (the manager's ruling, 2026-11-24).
//!
//! Two signals, either of which pauses the engine after the batch it is on, with the reason in `search status`; the
//! engine goes on when both clear:
//!
//! 1. **Another process works on the device.** NVIDIA: `nvidia-smi pmon` (NVML's process list: compute and graphics
//!    contexts with their SM share). AMD and Intel: the DRM `fdinfo` of every process (`drm-pdev`, `drm-client-id`
//!    and the `drm-engine-gfx` / `drm-engine-compute` nanoseconds), two samples apart. Our own engine processes never
//!    count. A context that sits idle (a compositor's, a browser's) does not hold the device: the process must use at
//!    least [`BUSY_PCT`] percent of an engine over the sample.
//! 2. **The device's free video memory is under what the engine needs** ([`super::engine_limits::vram_need_mib`]): a
//!    program took the memory the next start of the engine would use.
//!
//! The parsing is pure over text, so tests state the lists; [`Probe`] reads this machine.

use std::collections::BTreeMap;
use std::time::Duration;

/// The share of one GPU engine a foreign process uses at least for the device to count as held, in percent.
pub const BUSY_PCT: f64 = 10.0;
/// How often the engine looks again while it is held (and at most between two looks while it works).
pub const HOLD_POLL: Duration = Duration::from_secs(5);

/// One process's DRM client: what `fdinfo` says of one open GPU file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Client {
    pub pid: i32,
    pub name: String,
    /// The client id the driver gave this open file.
    pub id: u64,
    /// The PCI address (`drm-pdev`).
    pub pdev: String,
    /// The nanoseconds its gfx and compute engines have run, summed.
    pub busy_ns: u64,
}

/// A process's `fdinfo` file as a DRM client, when it is one (`drm-driver:`, `drm-pdev:` and `drm-client-id:` are
/// there; the engine lines are the driver's).
pub fn parse_fdinfo(pid: i32, name: &str, text: &str) -> Option<Client> {
    let mut driver = None;
    let (mut pdev, mut id) = (None, None);
    let mut busy = 0u64;
    for line in text.lines() {
        let Some((k, v)) = line.split_once(':') else {
            continue;
        };
        let v = v.trim();
        match k {
            "drm-driver" => driver = Some(v.to_owned()),
            "drm-pdev" => pdev = Some(v.to_owned()),
            "drm-client-id" => id = v.parse().ok(),
            "drm-engine-gfx" | "drm-engine-compute" | "drm-engine-render" => {
                busy += v
                    .split_whitespace()
                    .next()
                    .and_then(|n| n.parse::<u64>().ok())
                    .unwrap_or(0);
            }
            _ => {}
        }
    }
    driver?;
    Some(Client {
        pid,
        name: name.to_owned(),
        id: id?,
        pdev: pdev?,
        busy_ns: busy,
    })
}

/// The processes (name and pid) that used at least [`BUSY_PCT`] percent of an engine of the device at PDEV between the
/// samples BEFORE and AFTER, ELAPSED apart; OWN are our engines' pids, which never count.
pub fn busy_clients(
    before: &[Client],
    after: &[Client],
    elapsed: Duration,
    pdev: &str,
    own: &[i32],
) -> Vec<String> {
    let secs_ns = elapsed.as_secs_f64() * 1e9;
    if secs_ns <= 0.0 {
        return Vec::new();
    }
    let was: BTreeMap<(i32, u64), u64> =
        before.iter().map(|c| ((c.pid, c.id), c.busy_ns)).collect();
    // one process may hold several clients: its busy time is the sum
    let mut per_pid: BTreeMap<i32, (String, f64)> = BTreeMap::new();
    for c in after
        .iter()
        .filter(|c| c.pdev == pdev && !own.contains(&c.pid))
    {
        let Some(&b) = was.get(&(c.pid, c.id)) else {
            continue;
        };
        let used = c.busy_ns.saturating_sub(b) as f64 / secs_ns * 100.0;
        per_pid.entry(c.pid).or_insert((c.name.clone(), 0.0)).1 += used;
    }
    per_pid
        .into_iter()
        .filter(|(_, (_, pct))| *pct >= BUSY_PCT)
        .map(|(pid, (name, _))| format!("{name} (pid {pid})"))
        .collect()
}

/// The processes of GPU number GPU in `nvidia-smi pmon -c 1 -s u` output that use at least [`BUSY_PCT`] percent of the
/// SM (compute and graphics contexts alike), but not OWN pids.
pub fn busy_nvidia(pmon: &str, gpu: u32, own: &[i32]) -> Vec<String> {
    pmon.lines()
        .filter(|l| !l.trim_start().starts_with('#'))
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            // gpu pid type sm mem enc dec jpg ofa command
            let (g, pid, sm) = (f.first()?, f.get(1)?, f.get(3)?);
            let (g, pid): (u32, i32) = (g.parse().ok()?, pid.parse().ok()?);
            let sm: f64 = sm.parse().ok()?;
            (g == gpu && !own.contains(&pid) && sm >= BUSY_PCT)
                .then(|| format!("{} (pid {pid})", f.get(9).copied().unwrap_or("?")))
        })
        .collect()
}

/// The video memory signal: the device's FREE MiB under NEED MiB (unknown free: no signal).
pub fn vram_short(need: u64, free: Option<u64>) -> Option<String> {
    let f = free?;
    (f < need).then(|| {
        format!("only {f} MiB of video memory is free and the engine needs {need} MiB: another program took it")
    })
}

/// Why the device is held, from the busy processes.
pub fn busy_reason(names: &[String]) -> Option<String> {
    (!names.is_empty()).then(|| {
        format!(
            "{} uses the GPU (a game or a job): indexing waits until it stops",
            names.join(", ")
        )
    })
}

/// This machine's look at the device: what a [`super::engine::EngineSpec`]'s `hold` runs.
pub struct Probe {
    last: std::sync::Mutex<Option<(std::time::Instant, Vec<Client>)>>,
    /// The last answer and when: a look within [`LOOK_EVERY`] of it returns it (`nvidia-smi pmon` samples for a second).
    said: std::sync::Mutex<Option<(std::time::Instant, Option<String>)>>,
}

/// The least time between two real looks at the machine.
const LOOK_EVERY: Duration = Duration::from_secs(2);

impl Default for Probe {
    fn default() -> Self {
        Probe::new()
    }
}

impl Probe {
    pub fn new() -> Probe {
        Probe {
            last: std::sync::Mutex::new(None),
            said: std::sync::Mutex::new(None),
        }
    }

    /// The processes other than OWN that work on DEVICE (a llama.cpp device id: `CUDA0`, `ROCm0`, `Vulkan1`), as a
    /// reason; none when none does or when this machine cannot tell. Blocking.
    pub fn foreign(&self, device: &str, own: &[i32]) -> Option<String> {
        let mut said = self.said.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((t, r)) = said.as_ref()
            && t.elapsed() < LOOK_EVERY
        {
            return r.clone();
        }
        let r = self.look(device, own);
        *said = Some((crate::clock::real_now(), r.clone()));
        r
    }

    fn look(&self, device: &str, own: &[i32]) -> Option<String> {
        let index: u32 = device
            .trim_start_matches(|c: char| !c.is_ascii_digit())
            .parse()
            .ok()?;
        if device.starts_with("CUDA") {
            let out = std::process::Command::new("nvidia-smi")
                .args(["pmon", "-c", "1", "-s", "u"])
                .output()
                .ok()?;
            return busy_reason(&busy_nvidia(
                &String::from_utf8_lossy(&out.stdout),
                index,
                own,
            ));
        }
        let pdev = drm_pdev(index)?;
        let now = crate::clock::real_now();
        let after = read_clients();
        let mut last = self.last.lock().unwrap_or_else(|e| e.into_inner());
        let reason = match last.as_ref() {
            Some((t, before)) => busy_reason(&busy_clients(
                before,
                &after,
                now.saturating_duration_since(*t),
                &pdev,
                own,
            )),
            None => None,
        };
        *last = Some((now, after));
        reason
    }
}

/// The PCI address of the INDEXth DRM GPU (by address), the order llama.cpp's AMD and Vulkan devices follow.
fn drm_pdev(index: u32) -> Option<String> {
    let mut v: Vec<String> = std::fs::read_dir("/sys/class/drm")
        .ok()?
        .flatten()
        .filter(|e| {
            let n = e.file_name();
            let n = n.to_string_lossy();
            n.starts_with("card") && !n.contains('-')
        })
        .filter_map(|e| std::fs::read_link(e.path().join("device")).ok())
        .filter_map(|p| p.file_name().map(|f| f.to_string_lossy().into_owned()))
        .collect();
    v.sort();
    v.into_iter().nth(index as usize)
}

/// Every DRM client of every process this user may read.
fn read_clients() -> Vec<Client> {
    let mut out = Vec::new();
    let Ok(procs) = std::fs::read_dir("/proc") else {
        return out;
    };
    for p in procs.flatten() {
        let Some(pid) = p.file_name().to_str().and_then(|n| n.parse::<i32>().ok()) else {
            continue;
        };
        let name = std::fs::read_to_string(p.path().join("comm")).unwrap_or_default();
        let Ok(fds) = std::fs::read_dir(p.path().join("fdinfo")) else {
            continue;
        };
        for fd in fds.flatten() {
            if let Ok(text) = std::fs::read_to_string(fd.path())
                && let Some(c) = parse_fdinfo(pid, name.trim(), &text)
            {
                out.push(c);
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fdinfo(id: u64, ns: u64) -> String {
        format!(
            "pos:\t0\ndrm-driver:\tamdgpu\ndrm-client-id:\t{id}\ndrm-pdev:\t0000:03:00.0\n\
             drm-engine-gfx:\t{ns} ns\ndrm-engine-compute:\t0 ns\n"
        )
    }

    #[test]
    fn a_busy_foreign_client_holds_and_an_idle_one_or_our_own_does_not() {
        let c = |pid, name: &str, id, ns| parse_fdinfo(pid, name, &fdinfo(id, ns)).unwrap();
        let before = [
            c(10, "game", 1, 0),
            c(11, "kwin", 2, 0),
            c(12, "ours", 3, 0),
        ];
        let after = [
            c(10, "game", 1, 800_000_000),
            c(11, "kwin", 2, 20_000_000),
            c(12, "ours", 3, 900_000_000),
        ];
        let held = busy_clients(
            &before,
            &after,
            Duration::from_secs(1),
            "0000:03:00.0",
            &[12],
        );
        assert_eq!(held, ["game (pid 10)"]);
        let other = busy_clients(
            &before,
            &after,
            Duration::from_secs(1),
            "0000:09:00.0",
            &[12],
        );
        assert!(
            other.is_empty(),
            "another device's clients do not hold this one"
        );
    }

    #[test]
    fn nvidia_pmon_names_the_busy_process_of_the_chosen_gpu() {
        let pmon = "# gpu pid type sm mem enc dec jpg ofa command\n# Idx # C/G % % % % % % name\n\
                    0 4242 C 87 12 - - - - train.py\n0 900 G 2 1 - - - - Xorg\n1 77 C 99 1 - - - - other\n\
                    0 55 C 60 1 - - - - ours\n";
        assert_eq!(busy_nvidia(pmon, 0, &[55]), ["train.py (pid 4242)"]);
    }

    #[test]
    fn video_memory_under_the_need_holds() {
        assert!(vram_short(2000, Some(1500)).is_some());
        assert!(vram_short(2000, Some(2000)).is_none());
        assert!(vram_short(2000, None).is_none());
    }
}
