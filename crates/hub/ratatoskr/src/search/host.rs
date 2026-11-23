//! The machine's load and the disk floor: two of tier 2's automatic pauses (Hrafn redesign §11A). Like the battery
//! gate ([`super::power`]), ROOT is the sysfs root: [`super::power::SYS`] means this machine, and any other ROOT is a
//! test's stand-in, read the same way on every platform (`loadavg` and `statvfs` files in it).
//!
//! - **Load:** busy while the 1-minute load average is above [`LOAD_PER_CPU`] per online CPU. The CPUs are the
//!   machine's (`devices/system/cpu/online`), not this process's share, so a container's quota does not make a quiet
//!   machine look busy.
//! - **Disk floor:** below it while the free space under the state directory is under [`DISK_FLOOR_BYTES`] or
//!   [`DISK_FLOOR_PCT`] of its filesystem, whichever is more: tier 2 writes vectors, so it waits for space.

use std::path::Path;

/// The load average per CPU above which the machine is busy.
pub const LOAD_PER_CPU: f64 = 2.0;
/// The free space tier 2 leaves on the state directory's filesystem: at least this much …
pub const DISK_FLOOR_BYTES: u64 = 2 << 30;
/// … and at least this share of it, in percent.
pub const DISK_FLOOR_PCT: u64 = 5;

/// The machine is busy, by ROOT.
pub fn busy(root: &Path) -> bool {
    load(root).is_some_and(|(load, cpus)| cpus > 0 && load > LOAD_PER_CPU * f64::from(cpus))
}

/// The free space under STATE is below the floor, by ROOT.
pub fn below_floor(root: &Path, state: &Path) -> bool {
    space(root, state).is_some_and(|(avail, total)| avail < floor(total))
}

/// The floor of a filesystem of TOTAL bytes.
pub fn floor(total: u64) -> u64 {
    DISK_FLOOR_BYTES.max(total / 100 * DISK_FLOOR_PCT)
}

/// The 1-minute load average and the online CPUs; none when unknown (never busy then).
fn load(root: &Path) -> Option<(f64, u32)> {
    #[cfg(target_os = "macos")]
    if root == Path::new(super::power::SYS) {
        let o = std::process::Command::new("sysctl")
            .args(["-n", "vm.loadavg", "hw.logicalcpu"])
            .output()
            .ok()?;
        return sysctl_load(&String::from_utf8_lossy(&o.stdout));
    }
    let avg = if root == Path::new(super::power::SYS) {
        std::fs::read_to_string("/proc/loadavg").ok()?
    } else {
        std::fs::read_to_string(root.join("loadavg")).ok()?
    };
    let online = std::fs::read_to_string(root.join("devices/system/cpu/online")).ok()?;
    Some((first_load(&avg)?, cpu_count(&online)?))
}

/// `/proc/loadavg`'s first field.
fn first_load(text: &str) -> Option<f64> {
    text.split_whitespace().next()?.parse().ok()
}

/// A CPU list (`0-3,8-11`): how many.
fn cpu_count(list: &str) -> Option<u32> {
    let mut n = 0;
    for part in list.trim().split(',').filter(|p| !p.is_empty()) {
        n += match part.split_once('-') {
            Some((a, b)) => b.parse::<u32>().ok()?.checked_sub(a.parse().ok()?)? + 1,
            None => part.parse::<u32>().map(|_| 1).ok()?,
        };
    }
    Some(n)
}

/// `sysctl -n vm.loadavg hw.logicalcpu`: `{ 1.23 1.10 1.00 }` then the CPUs.
#[cfg(target_os = "macos")]
fn sysctl_load(text: &str) -> Option<(f64, u32)> {
    let mut lines = text.lines();
    let avg = lines.next()?.trim().trim_start_matches('{');
    Some((first_load(avg)?, lines.next()?.trim().parse().ok()?))
}

/// Free (to this user) and total bytes of STATE's filesystem; a stand-in ROOT's `statvfs` file holds `AVAIL TOTAL`.
fn space(root: &Path, state: &Path) -> Option<(u64, u64)> {
    if root != Path::new(super::power::SYS) {
        let text = std::fs::read_to_string(root.join("statvfs")).ok()?;
        let mut f = text.split_whitespace().map(str::parse::<u64>);
        return Some((f.next()?.ok()?, f.next()?.ok()?));
    }
    let s = rustix::fs::statvfs(state).ok()?;
    Some((
        s.f_bavail.saturating_mul(s.f_frsize),
        s.f_blocks.saturating_mul(s.f_frsize),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pure (D). The CPU list's forms, the load's first field, and the floor's two parts.
    #[test]
    fn host_readings() {
        assert_eq!(cpu_count("0-3\n"), Some(4));
        assert_eq!(cpu_count("0-3,8-11"), Some(8));
        assert_eq!(cpu_count("0"), Some(1));
        assert_eq!(cpu_count("3-1"), None);
        assert_eq!(first_load("7.50 3.00 1.00 2/300 42\n"), Some(7.5));
        assert_eq!(floor(10 << 30), DISK_FLOOR_BYTES, "a small disk: the bytes");
        assert_eq!(floor(1000 << 30), 50 << 30, "a big one: the share");
    }
}
