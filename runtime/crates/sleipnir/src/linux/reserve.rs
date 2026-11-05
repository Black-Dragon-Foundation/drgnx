//! The reservation files: how two schedulers on one machine (jobq and a runner, two hubs) see each other's jobs.
//!
//! Each running job of each scheduler is one file in `$XDG_RUNTIME_DIR/forseti/reservations/`, a JSON
//! [`Reservation`] written by rename. An admission runs under `flock` on `forseti/admit.lock`
//! ([`Reservations::with_admit_lock`]): it reads the others, decides, and writes its own file before it lets go, so
//! two admissions in one second can't both fit. Counting is `forseti::reserve::count_others`; a file whose process is
//! gone ([`alive`]) or whose boot id differs counts for nothing.

pub use forseti::reserve::Reservation;
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

/// The reservation directory of one machine (one user's runtime dir).
#[derive(Clone, Debug)]
pub struct Reservations {
    dir: PathBuf,
}

/// A scheduler or job name that can be part of a file name: letters, digits, `-` and `_`, not empty.
fn plain(name: &str) -> bool {
    !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn invalid(what: String) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, what)
}

impl Reservations {
    /// The files under RUNTIME_DIR (`$XDG_RUNTIME_DIR`): `forseti/admit.lock` and `forseti/reservations/`.
    pub fn at(runtime_dir: &Path) -> Reservations {
        Reservations {
            dir: runtime_dir.join("forseti"),
        }
    }

    fn files(&self) -> PathBuf {
        self.dir.join("reservations")
    }

    fn file(&self, scheduler: &str, job: &str) -> io::Result<PathBuf> {
        if !plain(scheduler) || !plain(job) {
            return Err(invalid(format!(
                "a reservation's scheduler and job are plain names: {scheduler:?} {job:?}"
            )));
        }
        Ok(self.files().join(format!("{scheduler}.{job}.json")))
    }

    fn ensure(&self) -> io::Result<()> {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(self.files())
    }

    /// Runs F holding the machine's admission lock (blocking until it is free). F reads the others, decides and puts
    /// its own reservation; nobody else admits meanwhile.
    pub fn with_admit_lock<T>(&self, f: impl FnOnce() -> T) -> io::Result<T> {
        self.ensure()?;
        let lock = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .mode(0o600)
            .open(self.dir.join("admit.lock"))?;
        rustix::fs::flock(&lock, rustix::fs::FlockOperation::LockExclusive)?;
        let out = f();
        rustix::fs::flock(&lock, rustix::fs::FlockOperation::Unlock)?;
        Ok(out)
    }

    /// Writes R (replacing that scheduler's file for that job), by rename: a reader sees the old file or the new one.
    pub fn put(&self, r: &Reservation) -> io::Result<()> {
        self.ensure()?;
        let path = self.file(&r.scheduler, &r.job)?;
        let tmp = self.files().join(format!(
            ".{}.{}.{}.tmp",
            r.scheduler,
            r.job,
            std::process::id()
        ));
        let body = serde_json::to_vec(r).map_err(io::Error::other)?;
        let mut f = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(&body)?;
        drop(f);
        fs::rename(&tmp, &path)
    }

    /// Removes SCHEDULER's reservation for JOB; one that is not there is no error.
    pub fn remove(&self, scheduler: &str, job: &str) -> io::Result<()> {
        match fs::remove_file(self.file(scheduler, job)?) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
            other => other,
        }
    }

    /// Every reservation not written by OWN. A file that does not parse is skipped; liveness and the boot id are the
    /// counting rule's to judge.
    pub fn read_others(&self, own: &str) -> Vec<Reservation> {
        let Ok(dir) = fs::read_dir(self.files()) else {
            return vec![];
        };
        let mut out: Vec<Reservation> = dir
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().ends_with(".json"))
            .filter_map(|e| serde_json::from_slice::<Reservation>(&fs::read(e.path()).ok()?).ok())
            .filter(|r| r.scheduler != own)
            .collect();
        out.sort_by(|a, b| (&a.scheduler, &a.job).cmp(&(&b.scheduler, &b.job)));
        out
    }
}

/// Whether process PID is still the one that started at START_TIME (`/proc/<pid>/stat` field 22, clock ticks since
/// boot): a reused pid is not alive.
pub fn alive(pid: u32, start_time: u64) -> bool {
    alive_in(Path::new("/proc"), pid, start_time)
}

/// [`alive`] under the proc root PROC.
pub fn alive_in(proc_root: &Path, pid: u32, start_time: u64) -> bool {
    start_time_in(proc_root, pid).is_ok_and(|t| t == start_time)
}

/// The start time of process PID, as [`alive`] compares it.
pub fn start_time(pid: u32) -> io::Result<u64> {
    start_time_in(Path::new("/proc"), pid)
}

fn start_time_in(proc_root: &Path, pid: u32) -> io::Result<u64> {
    let stat = fs::read_to_string(proc_root.join(pid.to_string()).join("stat"))?;
    parse_start_time(&stat)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "an unreadable /proc stat"))
}

/// Field 22 of a `/proc/<pid>/stat` line. The command name (field 2) is in parentheses and may hold spaces and
/// parentheses itself, so the fields are counted after the last `)`.
pub fn parse_start_time(stat: &str) -> Option<u64> {
    let rest = &stat[stat.rfind(')')? + 1..];
    // after the name: field 3 (state) is the first, so field 22 is the 20th
    rest.split_whitespace().nth(19)?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn res(scheduler: &str, job: &str, pid: u32, start_time: u64) -> Reservation {
        Reservation {
            scheduler: scheduler.into(),
            pid,
            boot_id: "b1".into(),
            start_time,
            job: job.into(),
            reserve_mib: 2048,
            current_mib: 512,
            expires: 1_000_300,
        }
    }

    /// [D] A reservation written by one scheduler reads back whole for another, and never for itself; removing it
    /// leaves nothing; names that would leave the directory are refused.
    #[test]
    fn a_reservation_round_trips() {
        let d = tempfile::tempdir().unwrap();
        let rs = Reservations::at(d.path());
        let r = res("jobq", "a3f", 4242, 777);
        rs.put(&r).unwrap();
        assert_eq!(rs.read_others("drgnx-hub"), vec![r.clone()]);
        assert!(rs.read_others("jobq").is_empty());
        // a second put replaces it
        let r2 = Reservation {
            current_mib: 1024,
            ..r.clone()
        };
        rs.put(&r2).unwrap();
        assert_eq!(rs.read_others("drgnx-hub"), vec![r2]);
        // under the lock, too; and junk next to it is skipped
        fs::write(rs.files().join("junk.json"), b"{").unwrap();
        let seen = rs
            .with_admit_lock(|| rs.read_others("drgnx-hub").len())
            .unwrap();
        assert_eq!(seen, 1);
        rs.remove("jobq", "a3f").unwrap();
        rs.remove("jobq", "a3f").unwrap();
        assert!(rs.read_others("drgnx-hub").is_empty());
        for (s, j) in [("../x", "a"), ("jobq", "a/b"), ("", "a"), ("jobq", "a.b")] {
            assert!(rs.put(&res(s, j, 1, 1)).is_err(), "{s:?} {j:?}");
        }
        assert_eq!(
            fs::metadata(rs.files())
                .map(|m| std::os::unix::fs::PermissionsExt::mode(&m.permissions()) & 0o777)
                .unwrap(),
            0o700
        );
    }

    /// [D] `/proc/<pid>/stat` with a command name holding spaces and parentheses.
    #[test]
    fn the_start_time_is_field_22() {
        let stat = "4242 (a (b) c) S 1 4242 4242 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 1 0 987654 1000 10 0\n";
        assert_eq!(parse_start_time(stat), Some(987654));
        assert_eq!(parse_start_time("garbage"), None);
        // this process, read twice, is alive; with another start time it is not
        let me = std::process::id();
        let t = start_time(me).unwrap();
        assert!(alive(me, t));
        assert!(!alive(me, t + 1));
    }

    /// [D] The facts name another scheduler only while its reservation is live: this boot, its process alive.
    #[test]
    fn facts_report_another_scheduler() {
        let d = tempfile::tempdir().unwrap();
        let proc_root = d.path().join("proc");
        fs::create_dir_all(proc_root.join("sys/kernel/random")).unwrap();
        fs::write(proc_root.join("sys/kernel/random/boot_id"), "b1\n").unwrap();
        let stat = |pid: u32, start: u64| {
            let p = proc_root.join(pid.to_string());
            fs::create_dir_all(&p).unwrap();
            fs::write(
                p.join("stat"),
                format!("{pid} (jobq) S {} {start} 0\n", "0 ".repeat(18)),
            )
            .unwrap();
        };
        stat(100, 5000);
        stat(200, 6000);
        let probe = super::super::probe::Probe {
            name: "m".into(),
            proc_root: proc_root.clone(),
            sys_root: d.path().join("sys"),
            manager: d.path().join("mgr"),
            runtime_dir: d.path().join("run"),
            folder: d.path().to_path_buf(),
            slice_root: "t".into(),
            scheduler: "drgnx-hub".into(),
            profile: forseti::Profile::Dedicated,
        };
        let rs = probe.reservations();
        assert!(probe.others_present().is_empty());
        rs.put(&res("jobq", "a1", 100, 5000)).unwrap();
        rs.put(&res("jobq", "a2", 200, 6000)).unwrap();
        rs.put(&res("drgnx-hub", "x1", 100, 5000)).unwrap(); // our own
        assert_eq!(probe.others_present(), ["jobq"]);
        // its process gone (another start time at that pid), another boot: nobody else is here
        rs.put(&res("jobq", "a1", 100, 4999)).unwrap();
        rs.put(&Reservation {
            boot_id: "b0".into(),
            ..res("jobq", "a2", 200, 6000)
        })
        .unwrap();
        rs.put(&res("other-hub", "q", 300, 1)).unwrap();
        assert!(
            probe.others_present().is_empty(),
            "{:?}",
            probe.others_present()
        );
    }
}
