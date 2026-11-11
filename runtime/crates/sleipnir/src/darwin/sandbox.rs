//! A Mac job's sandbox: the Gleipnir spec its Seatbelt profile is made from. It reads the job's source, writes its
//! attempt folder (and the source, for a job that writes its tree), has its home and temporary folder in the attempt
//! folder, and no network. It runs Homebrew read-only (no update or cleanup; its cache, logs and temporary files in the
//! attempt's tmp). A job placed with `tool:` features reads the runner's toolchains and has them in its
//! environment ([`super::tools`]). Pure: the rows run on Linux.

use gleipnir::spec::{Bind, Layers, Mode, Net, Spec, Target};
use std::path::{Path, PathBuf};

pub use super::memwatch::MARKER;
/// The `PATH` a Mac job gets: Homebrew's, then the system's.
pub const PATH: &str = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";

/// What a Mac attempt's sandbox is made from.
pub struct Job<'a> {
    /// The attempt's folder (`<root>/jobs/<id>.<attempt>`).
    pub dir: &'a Path,
    /// The job's source (its slot or the attempt's own copy).
    pub src: &'a Path,
    /// Its working directory, relative to SRC (`.`: SRC).
    pub cwd: &'a Path,
    /// Whether the job writes its tree.
    pub writes_tree: bool,
    /// The attempt's marker value (`<hub>/<job>/<attempt>`).
    pub marker: &'a str,
    /// The runner's toolchains folder (`<root>/tools`) and the records of the job's `tool:` pins; read only when there
    /// are some.
    pub tools_dir: &'a Path,
    pub tools: &'a [super::tools::Record],
}

/// The Seatbelt context of a Mac runner's job: the developer dir by true name, and the build addition with the
/// account's per-user folder (DARWIN_USER_DIR, `/var/folders/xx/yyy/0/`: its parent, by true name). Every job a Mac
/// runner takes is a build or a test, so every one gets the addition; a per-user folder that can't be resolved refuses
/// the launch.
pub fn mac_context(
    developer_dir: &str,
    darwin_user_dir: &str,
) -> Result<gleipnir::sbpl::MacContext, String> {
    let u = Path::new(darwin_user_dir.trim());
    let user_dir = u
        .parent()
        .filter(|_| u.is_absolute())
        .and_then(|p| std::fs::canonicalize(p).ok())
        .ok_or_else(|| {
            format!("the account's per-user folder {darwin_user_dir:?} can't be resolved")
        })?;
    Ok(gleipnir::sbpl::MacContext {
        developer_dir: std::fs::canonicalize(developer_dir.trim()).ok(),
        build: Some(gleipnir::sbpl::MacBuild { user_dir }),
        ..Default::default()
    })
}

/// The attempt's home and temporary folder, inside its folder.
pub fn home_tmp(dir: &Path) -> (PathBuf, PathBuf) {
    (dir.join("home"), dir.join("tmp"))
}

/// The spec of JOB, for [`Target::Macos`].
pub fn spec(job: &Job) -> Spec {
    let (home, tmp) = home_tmp(job.dir);
    let mut write = vec![job.dir.to_path_buf()];
    if job.writes_tree {
        write.push(job.src.to_path_buf());
    }
    let chdir = if job.cwd == Path::new(".") || job.cwd.as_os_str().is_empty() {
        job.src.to_path_buf()
    } else {
        job.src.join(job.cwd)
    };
    let mut read = vec![job.src.to_path_buf()];
    if !job.tools.is_empty() {
        read.push(job.tools_dir.to_path_buf());
    }
    let env = vec![
        ("HOME".into(), home.display().to_string()),
        ("TMPDIR".into(), format!("{}/", tmp.display())),
        ("PATH".into(), PATH.into()),
        ("LANG".into(), "en_US.UTF-8".into()),
        (MARKER.into(), job.marker.into()),
        // Homebrew read-only: a configure asks `brew` where a package is, and the profile lets no job write Homebrew
        ("HOMEBREW_NO_AUTO_UPDATE".into(), "1".into()),
        ("HOMEBREW_NO_INSTALL_CLEANUP".into(), "1".into()),
        ("HOMEBREW_NO_ANALYTICS".into(), "1".into()),
        ("HOMEBREW_NO_ENV_HINTS".into(), "1".into()),
        // formulae from the installed kegs, never the JSON API: with an empty cache brew would fetch it (no network)
        // under a download lock in Homebrew's var (denied), and fail
        ("HOMEBREW_NO_INSTALL_FROM_API".into(), "1".into()),
        (
            "HOMEBREW_CACHE".into(),
            format!("{}/brew-cache", tmp.display()),
        ),
        (
            "HOMEBREW_LOGS".into(),
            format!("{}/brew-logs", tmp.display()),
        ),
        ("HOMEBREW_TEMP".into(), tmp.display().to_string()),
    ];
    Spec {
        read,
        write,
        hide: vec![],
        sockets: vec![],
        binds: vec![],
        home: Some(Bind {
            mode: Mode::Rw,
            source: home.clone(),
            dest: home.clone(),
        }),
        run: None,
        env: super::tools::job_env(env, job.tools),
        chdir,
        net: Net::Isolated {
            relay: vec![],
            mac_tcp_ports: vec![],
        },
        tmp: Some(tmp),
        layers: Layers::for_target(Target::Macos),
        extra_tcp_ports: vec![],
        trace: Default::default(),
        browser: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [D] A job reads its source and writes only its attempt folder (and its source when it writes its tree); its
    /// home and tmp are the attempt's; no network; every process carries the marker.
    #[test]
    fn a_mac_job_reads_its_source_and_writes_its_attempt() {
        let dir = Path::new("/runner/.drgnx-runner.noindex/jobs/j1.1");
        let src = Path::new("/runner/.drgnx-runner.noindex/slots/s1");
        let job = Job {
            dir,
            src,
            cwd: Path::new("sub"),
            writes_tree: false,
            marker: "hubA/j1/1",
            tools_dir: Path::new("/runner/.drgnx-runner.noindex/tools"),
            tools: &[],
        };
        let s = spec(&job);
        assert_eq!(s.read, vec![src.to_path_buf()]);
        assert_eq!(s.write, vec![dir.to_path_buf()]);
        assert_eq!(s.chdir, src.join("sub"));
        assert_eq!(s.tmp, Some(dir.join("tmp")));
        assert_eq!(s.home.as_ref().unwrap().source, dir.join("home"));
        assert!(
            matches!(&s.net, Net::Isolated { relay, mac_tcp_ports } if relay.is_empty() && mac_tcp_ports.is_empty())
        );
        assert!(
            s.env
                .contains(&(MARKER.to_string(), "hubA/j1/1".to_string()))
        );
        let w = spec(&Job {
            writes_tree: true,
            cwd: Path::new("."),
            ..job
        });
        assert_eq!(w.write, vec![dir.to_path_buf(), src.to_path_buf()]);
        assert_eq!(w.chdir, src.to_path_buf());
    }

    /// [D] A job with a pinned toolchain reads the runner's tools folder (never writes it) and finds the tool first on
    /// its PATH; without one it doesn't read the folder.
    #[test]
    fn a_job_with_a_toolchain_reads_the_tools_folder() {
        let dir = Path::new("/r/jobs/j1.1");
        let src = Path::new("/r/slots/s1");
        let tools_dir = Path::new("/r/tools");
        let rec = crate::darwin::tools::Record {
            path: vec!["/r/tools/cargo/bin".into()],
            env: vec![("RUSTUP_HOME".into(), "/r/tools/rustup".into())],
        };
        let job = Job {
            dir,
            src,
            cwd: Path::new("."),
            writes_tree: true,
            marker: "h/j1/1",
            tools_dir,
            tools: std::slice::from_ref(&rec),
        };
        let s = spec(&job);
        assert_eq!(s.read, vec![src.to_path_buf(), tools_dir.to_path_buf()]);
        assert!(!s.write.iter().any(|w| w.starts_with(tools_dir)));
        assert!(
            s.env
                .contains(&("PATH".into(), format!("/r/tools/cargo/bin:{PATH}")))
        );
        assert!(
            s.env
                .contains(&("RUSTUP_HOME".into(), "/r/tools/rustup".into()))
        );
        assert_eq!(
            spec(&Job { tools: &[], ..job }).read,
            vec![src.to_path_buf()]
        );
    }

    /// [D] A job's Seatbelt context: the build addition with the per-user folder (DARWIN_USER_DIR's parent) by true
    /// name; one that can't be resolved, or isn't absolute, refuses.
    #[test]
    fn a_jobs_context_has_the_build_addition() {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(d.path().join("0")).unwrap();
        let darwin = format!("{}/0/", d.path().display());
        let m = mac_context("/nowhere/Developer", &darwin).unwrap();
        assert_eq!(m.build.unwrap().user_dir, d.path().canonicalize().unwrap());
        assert_eq!(m.developer_dir, None);
        assert!(mac_context("", "").is_err());
        assert!(mac_context("", "var/folders/x/0/").is_err());
        assert!(mac_context("", "/nowhere/at/all/0/").is_err());
    }

    /// [D] A job runs Homebrew read-only: no update, cleanup, analytics or JSON API, and its cache, logs and temporary files in
    /// the attempt's tmp (a configure that asks `brew` where a package is, under a profile that can't write Homebrew).
    #[test]
    fn a_job_runs_homebrew_read_only() {
        let dir = Path::new("/r/jobs/j1.1");
        let s = spec(&Job {
            dir,
            src: Path::new("/r/slots/s1"),
            cwd: Path::new("."),
            writes_tree: false,
            marker: "h/j1/1",
            tools_dir: Path::new("/r/tools"),
            tools: &[],
        });
        let tmp = dir.join("tmp").display().to_string();
        for (k, v) in [
            ("HOMEBREW_NO_AUTO_UPDATE", "1".to_string()),
            ("HOMEBREW_NO_INSTALL_CLEANUP", "1".to_string()),
            ("HOMEBREW_NO_ANALYTICS", "1".to_string()),
            ("HOMEBREW_NO_ENV_HINTS", "1".to_string()),
            ("HOMEBREW_NO_INSTALL_FROM_API", "1".to_string()),
            ("HOMEBREW_CACHE", format!("{tmp}/brew-cache")),
            ("HOMEBREW_LOGS", format!("{tmp}/brew-logs")),
            ("HOMEBREW_TEMP", tmp.clone()),
        ] {
            assert!(
                s.env.contains(&(k.to_string(), v.clone())),
                "{k}={v}: {:?}",
                s.env
            );
        }
    }
}
