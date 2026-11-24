//! IO control on Linux (Task 10b): which controller acts on a job's `IOWeight` on the runner's device, and the files
//! the live cap and `sleipnir setup io` write.
//!
//! An `IOWeight` only acts under the `io.cost` controller (per device, `io.cost.qos` in the cgroup root) or the BFQ
//! scheduler. [`probe`] reads which the device has, [`report`] says so in words, and a device with neither is said to
//! have none (never a silent no-op). The reading is of files, so the tests give it a folder of fixtures.

use std::path::{Path, PathBuf};

/// Where the facts are read from: `/proc/self/mountinfo`'s text, `/sys` and the cgroup root.
pub struct Sys<'a> {
    pub mountinfo: &'a str,
    pub sysfs: &'a Path,
    pub cgroup: &'a Path,
}

/// A whole disk: its name (`nvme0n1`) and `MAJ:MIN`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Device {
    pub name: String,
    pub majmin: String,
}

/// What acts on a job's IO weight on the device.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IoControl {
    /// `io.cost` is on for the device (`enable=1` in `io.cost.qos`).
    Cost,
    /// The device's scheduler is BFQ.
    Bfq,
    /// Neither: weights are set but nothing acts on them.
    None,
}

/// The whole disk under the filesystem that holds PATH, from the mount table and sysfs; none when it is not a block
/// device (tmpfs, a network filesystem).
pub fn device_of(sys: &Sys, path: &Path) -> Option<Device> {
    // the longest mount point that holds PATH: `ID PARENT MAJ:MIN ROOT POINT OPTS… - FSTYPE SOURCE …`
    let mut best: Option<(usize, &str)> = None;
    for line in sys.mountinfo.lines() {
        let (head, tail) = line.split_once(" - ")?;
        let point = head.split(' ').nth(4)?;
        let mut t = tail.split(' ');
        let (_fstype, source) = (t.next()?, t.next()?);
        if path.starts_with(point) && best.is_none_or(|(n, _)| point.len() >= n) {
            best = Some((point.len(), source));
        }
    }
    let node = Path::new(best?.1).file_name()?.to_str()?;
    let block = sys.sysfs.join("class/block").join(node);
    // a partition's disk is its parent directory; a disk is itself
    let real = std::fs::canonicalize(&block).ok()?;
    let disk = if real.join("partition").exists() {
        real.parent()?.to_path_buf()
    } else {
        real
    };
    let majmin = crate::fsio::read_to_string(disk.join("dev"))
        .ok()?
        .trim()
        .to_string();
    Some(Device {
        name: disk.file_name()?.to_str()?.to_string(),
        majmin,
    })
}

/// Which controller acts on DEV's IO weights.
pub fn probe(sys: &Sys, dev: &Device) -> IoControl {
    let qos = crate::fsio::read_to_string(sys.cgroup.join("io.cost.qos")).unwrap_or_default();
    let on = qos.lines().any(|l| {
        let mut w = l.split_whitespace();
        w.next() == Some(dev.majmin.as_str()) && w.any(|f| f == "enable=1")
    });
    if on {
        return IoControl::Cost;
    }
    // /sys/class/block/NAME is a link into the device tree, which a plain read does not follow
    let sched = std::fs::canonicalize(sys.sysfs.join("class/block").join(&dev.name))
        .and_then(|d| crate::fsio::read_to_string(d.join("queue/scheduler")))
        .unwrap_or_default();
    if sched.contains("[bfq]") {
        IoControl::Bfq
    } else {
        IoControl::None
    }
}

/// The control in words, for the machine's state and `jobs why`: what acts, or that nothing does and what to do.
pub fn report(c: IoControl) -> String {
    match c {
        IoControl::Cost => "IO weights act: io.cost is on for the runner's disk".into(),
        IoControl::Bfq => "IO weights act: the runner's disk uses the BFQ scheduler".into(),
        IoControl::None => {
            "no IO controller acts on the runner's disk: IO weights are set but do nothing; \
            turn on io.cost (as root: sleipnir setup io) or use the BFQ scheduler"
                .into()
        }
    }
}

/// Turns `io.cost` on for DEV with the kernel's default model: `MAJ:MIN enable=1` into the cgroup root's
/// `io.cost.qos`. Root's step (`sleipnir setup io`).
pub fn enable_cost(cgroup: &Path, dev: &Device) -> villa::Result<()> {
    let p = cgroup.join("io.cost.qos");
    crate::fsio::write_in_place(&p, format!("{} enable=1", dev.majmin))
        .map_err(|e| villa::Error::io(format!("{}: {e}", p.display())))
}

/// The line that writes a cap on DEV into a job's `io.max`: `MAJ:MIN rbps=B wbps=B`, B bytes per second from MBPS MiB/s.
pub fn max_line(dev: &Device, mbps: f64) -> String {
    let b = (mbps * 1_048_576.0).round() as u64;
    format!("{} rbps={b} wbps={b}", dev.majmin)
}

/// The line that lifts a cap: `MAJ:MIN rbps=max wbps=max`.
pub fn lift_line(dev: &Device) -> String {
    format!("{} rbps=max wbps=max", dev.majmin)
}

/// `sleipnir setup io` on this machine (root's step): finds the disk under ROOT, turns `io.cost` on for it unless a
/// controller already acts, and returns what [`report`] says after. A disk it can't find is an error, never a no-op.
pub fn setup_system(root: &Path) -> villa::Result<String> {
    let mountinfo = crate::fsio::read_to_string("/proc/self/mountinfo")
        .map_err(|e| villa::Error::io(format!("/proc/self/mountinfo: {e}")))?;
    let sys = Sys {
        mountinfo: &mountinfo,
        sysfs: Path::new("/sys"),
        cgroup: Path::new("/sys/fs/cgroup"),
    };
    let dev = device_of(&sys, root).ok_or_else(|| {
        villa::Error::unavailable(format!("{} is on no block device", root.display()))
    })?;
    if probe(&sys, &dev) == IoControl::None {
        enable_cost(sys.cgroup, &dev)?;
    }
    Ok(format!("{}: {}", dev.name, report(probe(&sys, &dev))))
}

/// A job's cgroup directory's `io.max` and `io.weight` files, the live cap's and the weight's places.
pub fn files(cgroup_dir: &Path) -> (PathBuf, PathBuf) {
    (cgroup_dir.join("io.max"), cgroup_dir.join("io.weight"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::symlink;

    /// A folder holding what the reading needs: a disk `nvme0n1` (259:0) with partition `nvme0n1p3` (259:3), the
    /// scheduler line, and a cgroup root; `qos` is the text of `io.cost.qos`, `scheduler` the disk's.
    fn fixture(t: &Path, qos: &str, scheduler: &str) -> (PathBuf, PathBuf) {
        let sys = t.join("sys");
        let disk = sys.join("devices/pci/nvme0n1");
        let part = disk.join("nvme0n1p3");
        fs::create_dir_all(part.clone()).unwrap();
        fs::create_dir_all(disk.join("queue")).unwrap();
        fs::create_dir_all(sys.join("class/block")).unwrap();
        crate::fsio::write(disk.join("dev"), b"259:0\n").unwrap();
        crate::fsio::write(part.join("dev"), b"259:3\n").unwrap();
        crate::fsio::write(part.join("partition"), b"3\n").unwrap();
        crate::fsio::write(disk.join("queue/scheduler"), scheduler).unwrap();
        symlink(&disk, sys.join("class/block/nvme0n1")).unwrap();
        symlink(&part, sys.join("class/block/nvme0n1p3")).unwrap();
        let cg = t.join("cgroup");
        fs::create_dir_all(&cg).unwrap();
        crate::fsio::write(cg.join("io.cost.qos"), qos).unwrap();
        (sys, cg)
    }

    const MOUNTS: &str = "\
24 1 0:21 / /run rw,nosuid shared:1 - tmpfs tmpfs rw,mode=755\n\
36 1 0:31 / / rw,relatime shared:2 - btrfs /dev/nvme0n1p3 rw,ssd,subvolid=256\n\
40 36 0:35 /data /data rw,relatime shared:3 - btrfs /dev/nvme0n1p3 rw,ssd,subvolid=257\n";

    fn dev() -> Device {
        Device {
            name: "nvme0n1".into(),
            majmin: "259:0".into(),
        }
    }

    /// [D] pure (fixture files) (Task 10b): the disk under a path is found through the mount table (the longest mount
    /// point) and the partition's parent; a tmpfs has none.
    #[test]
    fn the_disk_under_a_path_is_found_through_its_partition() {
        let t = tempfile::tempdir().unwrap();
        let (sys, cg) = fixture(t.path(), "", "none [mq-deadline] bfq\n");
        let s = Sys {
            mountinfo: MOUNTS,
            sysfs: &sys,
            cgroup: &cg,
        };
        assert_eq!(device_of(&s, Path::new("/data/runner")), Some(dev()));
        assert_eq!(device_of(&s, Path::new("/var/lib")), Some(dev()));
        assert_eq!(
            device_of(&s, Path::new("/run/user/1000")),
            None,
            "a tmpfs is no disk"
        );
    }

    /// [D] pure (fixture files) (Task 10b): a device with neither io.cost nor BFQ is reported as having none, with
    /// what to do; weights are never silently a no-op.
    #[test]
    fn a_device_without_io_cost_is_reported() {
        let t = tempfile::tempdir().unwrap();
        let (sys, cg) = fixture(
            t.path(),
            "259:0 enable=0 ctrl=auto rpct=0.00\n8:0 enable=1 ctrl=auto\n",
            "none [mq-deadline] kyber\n",
        );
        let s = Sys {
            mountinfo: MOUNTS,
            sysfs: &sys,
            cgroup: &cg,
        };
        let c = probe(&s, &dev());
        assert_eq!(
            c,
            IoControl::None,
            "another disk's enable=1 is not this one's"
        );
        let words = report(c);
        for must in ["no IO controller", "io.cost", "BFQ", "sleipnir setup io"] {
            assert!(words.contains(must), "{must}: {words}");
        }
    }

    /// [D] pure (fixture files) (Task 10b): io.cost enabled for the device, or BFQ its scheduler, is found and said.
    #[test]
    fn io_cost_and_bfq_are_found() {
        let t = tempfile::tempdir().unwrap();
        let (sys, cg) = fixture(
            t.path(),
            "259:0 enable=1 ctrl=auto\n",
            "none [mq-deadline]\n",
        );
        let s = Sys {
            mountinfo: MOUNTS,
            sysfs: &sys,
            cgroup: &cg,
        };
        assert_eq!(probe(&s, &dev()), IoControl::Cost);
        assert!(report(IoControl::Cost).contains("io.cost"));
        let t2 = tempfile::tempdir().unwrap();
        let (sys, cg) = fixture(t2.path(), "", "none mq-deadline [bfq]\n");
        let s = Sys {
            mountinfo: MOUNTS,
            sysfs: &sys,
            cgroup: &cg,
        };
        assert_eq!(probe(&s, &dev()), IoControl::Bfq);
        assert!(report(IoControl::Bfq).contains("BFQ"));
    }

    /// [D] pure (a folder) (Task 10b): `setup io` writes the device's enable line in the cgroup root, in place (a
    /// cgroup file is never replaced by a rename); the cap's lines name the device and bytes per second.
    #[test]
    fn the_setup_and_cap_lines_name_the_device() {
        let t = tempfile::tempdir().unwrap();
        let (_, cg) = fixture(t.path(), "", "none\n");
        enable_cost(&cg, &dev()).unwrap();
        assert_eq!(
            crate::fsio::read_to_string(cg.join("io.cost.qos"))
                .unwrap()
                .trim(),
            "259:0 enable=1"
        );
        assert_eq!(
            max_line(&dev(), 150.0),
            "259:0 rbps=157286400 wbps=157286400"
        );
        assert_eq!(lift_line(&dev()), "259:0 rbps=max wbps=max");
    }
}
