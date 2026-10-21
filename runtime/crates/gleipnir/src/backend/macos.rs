//! Seatbelt (Task 9; docs/develop/gleipnir.md, "macOS: Seatbelt"): the profile from [`crate::sbpl::profile`], run as
//! `/usr/bin/sandbox-exec -f FILE CMD…` or `-p TEXT CMD…` from a root-owned `sandbox-exec`.
//!
//! The profile is never written where the program can write, and never into its `tmp` (review S8). With a `run` (a
//! session dir: the sandbox reads it and cannot write it) it goes to `<run.source>/profile.sb`; without one (the check,
//! short steps) it travels in argv (`-p`, CI3-SB-1). There is no status fd on macOS: Task 13 reports the layers as
//! `seatbelt: true` once `sandbox-exec` is spawned, and a profile `sandbox-exec` refuses ends the run with its error
//! before the command starts.

use crate::sbpl::{self, MacContext};
use crate::spec::{Mode, Spec, ValidSpec};
use crate::validate::{Refusal, Rule};
use eitri::TrustedProgram;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

/// The only `sandbox-exec` gleipnir runs: never one found through `PATH`.
pub const SANDBOX_EXEC: &str = "/usr/bin/sandbox-exec";

/// The profile's name in the session dir.
pub const PROFILE_FILE: &str = "profile.sb";

/// The largest profile passed with `-p`. argv and the environment share `ARG_MAX` (1 MiB on macOS); a larger profile
/// is refused here with a reason instead of failing the exec with `E2BIG`.
pub const MAX_INLINE: usize = 256 * 1024;

/// What to spawn: `program` with `args`, exactly `env`, in `cwd`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Run {
    pub program: PathBuf,
    pub args: Vec<OsString>,
    pub env: Vec<(OsString, OsString)>,
    pub cwd: PathBuf,
    /// Where the profile was written (with a `run`), or `None` when it travels in `args` (`-p`).
    pub profile_file: Option<PathBuf>,
}

/// `/usr/bin/sandbox-exec`, when only root can change it (`eitri::trusted_program`).
pub fn find() -> Result<TrustedProgram, Refusal> {
    eitri::trusted_program(&[Path::new(SANDBOX_EXEC)]).map_err(|e| Refusal {
        rule: Rule::Missing,
        path: Some(PathBuf::from(SANDBOX_EXEC)),
        message: format!("seatbelt: {e}"),
    })
}

/// The invocation of `command` under `spec`'s profile, through `sandbox_exec` (from [`find`]). With a `run`, the
/// profile is written to `<run.source>/profile.sb` (a stale file there is removed first; then 0600, `O_EXCL`, no
/// link followed); without one it is passed with `-p`. Refused: an empty command or one whose program starts with
/// `-` (`sandbox-exec` would read it as an option), a profile file that would lie under a writable root or `tmp`, a
/// profile `sbpl::profile` refuses, and a `-p` profile over [`MAX_INLINE`].
pub fn prepare(
    spec: &ValidSpec,
    mac: &MacContext,
    sandbox_exec: &TrustedProgram,
    command: &[String],
) -> Result<Run, Refusal> {
    match command.first() {
        None => return Err(malformed("seatbelt: no command".into(), None)),
        Some(p) if p.is_empty() || p.starts_with('-') => {
            let msg =
                format!("seatbelt: the program {p:?} would be read as an option of sandbox-exec");
            return Err(malformed(msg, None));
        }
        Some(_) => {}
    }
    let s = spec.spec();
    let text = sbpl::profile(spec, mac)?;
    let (mode, profile, file) = match &s.run {
        Some(run) => {
            let file = run.source.join(PROFILE_FILE);
            if let Some(root) = writable_roots(s).find(|r| within(&file, r)) {
                let msg = format!(
                    "seatbelt: the profile {} would lie under {}, which the sandbox can write",
                    file.display(),
                    root.display()
                );
                return Err(malformed(msg, Some(&file)));
            }
            write_profile(&file, &text).map_err(|e| {
                let msg = format!("seatbelt: cannot write the profile {}: {e}", file.display());
                malformed(msg, Some(&file))
            })?;
            ("-f", file.clone().into_os_string(), Some(file))
        }
        None if text.len() > MAX_INLINE => {
            let msg = format!(
                "seatbelt: the profile is {} bytes, more than {MAX_INLINE} can pass in argv without a session dir",
                text.len()
            );
            return Err(malformed(msg, None));
        }
        None => ("-p", OsString::from(text), None),
    };
    let args = [OsString::from(mode), profile]
        .into_iter()
        .chain(command.iter().map(OsString::from))
        .collect();
    Ok(Run {
        program: sandbox_exec.path.clone(),
        args,
        env: s
            .env
            .iter()
            .map(|(k, v)| (OsString::from(k), OsString::from(v)))
            .collect(),
        cwd: s.chdir.clone(),
        profile_file: file,
    })
}

/// Every path the sandbox can write: `write`, `tmp`, a `rw` home and the `rw` binds.
fn writable_roots(s: &Spec) -> impl Iterator<Item = &Path> {
    let home = s.home.iter().filter(|h| h.mode == Mode::Rw);
    let binds = s.binds.iter().filter(|b| b.mode == Mode::Rw);
    s.write
        .iter()
        .map(PathBuf::as_path)
        .chain(s.tmp.as_deref())
        .chain(home.chain(binds).map(|b| b.source.as_path()))
}

/// Is `p` `dir` or inside it, ignoring case (macOS)?
fn within(p: &Path, dir: &Path) -> bool {
    let low = |p: &Path| PathBuf::from(p.to_string_lossy().to_lowercase());
    low(p).starts_with(low(dir))
}

/// `text` to `file`: a stale file (or link) there is removed, never followed; then a new file, 0600, `O_EXCL`.
fn write_profile(file: &Path, text: &str) -> io::Result<()> {
    match fs::remove_file(file) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
        _ => {}
    }
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(file)?;
    f.write_all(text.as_bytes())?;
    f.sync_all()
}

fn malformed(message: String, path: Option<&Path>) -> Refusal {
    Refusal {
        rule: Rule::Malformed,
        path: path.map(Path::to_path_buf),
        message,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::{Bind, Layers, Net, Target};
    use std::os::unix::fs::PermissionsExt;

    fn bind(mode: Mode, p: &Path) -> Bind {
        Bind {
            mode,
            source: p.into(),
            dest: p.into(),
        }
    }

    /// A Mac spec over a fixture `/tmp/glp-XXXXXX/{task,home,tmp,run/s/S1}`.
    fn fixture() -> (tempfile::TempDir, Spec) {
        let top = tempfile::Builder::new()
            .prefix("glp-")
            .tempdir_in("/tmp")
            .unwrap();
        let root = fs::canonicalize(top.path()).unwrap();
        for d in ["task", "home", "tmp", "objects", "run/s/S1"] {
            fs::create_dir_all(root.join(d)).unwrap();
        }
        let spec = Spec {
            read: vec![],
            write: vec![root.join("task")],
            hide: vec![],
            sockets: vec![root.join("run/s/S1/gw.sock")],
            binds: vec![bind(Mode::Rw, &root.join("objects"))],
            home: Some(bind(Mode::Rw, &root.join("home"))),
            run: Some(bind(Mode::Ro, &root.join("run/s/S1"))),
            env: vec![
                ("PATH".into(), "/usr/bin:/bin".into()),
                ("CANARY".into(), "x y".into()),
            ],
            chdir: root.join("task"),
            net: Net::Shared,
            tmp: Some(root.join("tmp")),
            layers: Layers::for_target(Target::Macos),
            extra_tcp_ports: vec![],
        };
        (top, spec)
    }

    fn fake_sandbox_exec() -> TrustedProgram {
        TrustedProgram {
            path: SANDBOX_EXEC.into(),
            dev: 1,
            ino: 2,
        }
    }

    fn entries(d: &Path) -> Vec<PathBuf> {
        let mut v: Vec<PathBuf> = fs::read_dir(d)
            .unwrap()
            .map(|e| e.unwrap().path())
            .collect();
        v.sort();
        v
    }

    #[test]
    fn profile_goes_to_the_session_dir_or_argv() {
        let (_top, s) = fixture();
        let run_dir = s.run.as_ref().unwrap().source.clone();
        let writable: Vec<PathBuf> = [
            s.write[0].clone(),
            s.tmp.clone().unwrap(),
            s.binds[0].source.clone(),
        ]
        .into_iter()
        .chain(s.home.iter().map(|h| h.source.clone()))
        .collect();
        let cmd = vec!["/bin/ls".to_owned(), "-l".to_owned()];
        let mac = MacContext::default();

        // With a run: the session dir, 0600, the profile's own text; a stale file and a planted link are replaced,
        // and the link's target is untouched.
        let target = s.write[0].join("victim");
        fs::write(&target, "keep").unwrap();
        std::os::unix::fs::symlink(&target, run_dir.join(PROFILE_FILE)).unwrap();
        let valid = ValidSpec::assume_valid(s.clone(), Target::Macos);
        let r = prepare(&valid, &mac, &fake_sandbox_exec(), &cmd).unwrap();
        let file = run_dir.join(PROFILE_FILE);
        assert_eq!(r.profile_file.as_deref(), Some(file.as_path()));
        assert_eq!(r.program, Path::new(SANDBOX_EXEC));
        assert_eq!(
            r.args,
            [
                OsString::from("-f"),
                file.clone().into_os_string(),
                "/bin/ls".into(),
                "-l".into()
            ]
        );
        assert_eq!(r.cwd, s.chdir);
        assert_eq!(
            r.env,
            [
                ("PATH".into(), "/usr/bin:/bin".into()),
                ("CANARY".into(), "x y".into())
            ]
        );
        let meta = fs::symlink_metadata(&file).unwrap();
        assert!(meta.is_file());
        assert_eq!(meta.permissions().mode() & 0o7777, 0o600);
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            sbpl::profile(&valid, &mac).unwrap()
        );
        assert_eq!(fs::read_to_string(&target).unwrap(), "keep");
        // A second prepare replaces the first file.
        prepare(&valid, &mac, &fake_sandbox_exec(), &cmd).unwrap();
        assert_eq!(entries(&run_dir), std::slice::from_ref(&file));
        for w in &writable {
            assert!(!file.starts_with(w));
        }

        // Without a run: `-p`, and no file anywhere the program can write.
        let mut norun = s.clone();
        norun.run = None;
        norun.sockets = vec![];
        let before: Vec<Vec<PathBuf>> = writable.iter().map(|w| entries(w)).collect();
        let v2 = ValidSpec::assume_valid(norun, Target::Macos);
        let r = prepare(&v2, &mac, &fake_sandbox_exec(), &cmd).unwrap();
        assert_eq!(r.profile_file, None);
        let text = sbpl::profile(&v2, &mac).unwrap();
        assert_eq!(
            r.args,
            [
                OsString::from("-p"),
                text.into(),
                "/bin/ls".into(),
                "-l".into()
            ]
        );
        let after: Vec<Vec<PathBuf>> = writable.iter().map(|w| entries(w)).collect();
        assert_eq!(before, after);

        // A session dir under a writable root (validation refuses it; refused here too) is never written to.
        let mut under = s.clone();
        let inside = s.write[0].join("run");
        fs::create_dir(&inside).unwrap();
        under.run = Some(bind(Mode::Ro, &inside));
        under.sockets = vec![];
        let v3 = ValidSpec::assume_valid(under, Target::Macos);
        assert!(prepare(&v3, &mac, &fake_sandbox_exec(), &cmd).is_err());
        assert!(entries(&inside).is_empty());
        let mut in_tmp = s.clone();
        let t = s.tmp.clone().unwrap().join("S1");
        fs::create_dir(&t).unwrap();
        in_tmp.run = Some(bind(Mode::Ro, &t));
        in_tmp.sockets = vec![];
        let v4 = ValidSpec::assume_valid(in_tmp, Target::Macos);
        assert!(prepare(&v4, &mac, &fake_sandbox_exec(), &cmd).is_err());
        assert!(entries(&t).is_empty());
        // Under the rw home or the rw bind: refused. Under the same dirs read-only: they are no write roots.
        for (home_mode, bind_mode) in [
            (Mode::Rw, Mode::Ro),
            (Mode::Ro, Mode::Rw),
            (Mode::Ro, Mode::Ro),
        ] {
            for dir in [
                s.home.as_ref().unwrap().source.clone(),
                s.binds[0].source.clone(),
            ] {
                let sub = dir.join(format!("run-{home_mode:?}-{bind_mode:?}"));
                fs::create_dir(&sub).unwrap();
                let mut x = s.clone();
                x.home.as_mut().unwrap().mode = home_mode;
                x.binds[0].mode = bind_mode;
                x.run = Some(bind(Mode::Ro, &sub));
                x.sockets = vec![];
                let rw = (dir == s.binds[0].source && bind_mode == Mode::Rw)
                    || (dir != s.binds[0].source && home_mode == Mode::Rw);
                let v = ValidSpec::assume_valid(x, Target::Macos);
                let r = prepare(&v, &mac, &fake_sandbox_exec(), &cmd);
                assert_eq!(
                    r.is_ok(),
                    !rw,
                    "{} {home_mode:?} {bind_mode:?}",
                    sub.display()
                );
                assert_eq!(entries(&sub).is_empty(), rw);
            }
        }
    }

    #[test]
    fn commands_sandbox_exec_would_misread_are_refused() {
        let (_top, s) = fixture();
        let valid = ValidSpec::assume_valid(s, Target::Macos);
        let mac = MacContext::default();
        for cmd in [
            vec![],
            vec!["".to_owned()],
            vec!["-p".to_owned(), "(allow default)".to_owned()],
        ] {
            let e = prepare(&valid, &mac, &fake_sandbox_exec(), &cmd).unwrap_err();
            assert_eq!(e.rule, Rule::Malformed, "{cmd:?}");
        }
        prepare(&valid, &mac, &fake_sandbox_exec(), &["true".to_owned()]).unwrap();
    }

    #[test]
    fn a_huge_inline_profile_is_refused() {
        let (_top, mut s) = fixture();
        s.run = None;
        s.sockets = vec![];
        // Many reads of 900-byte paths: well over MAX_INLINE. The control: a few of them pass.
        s.read = (0..400)
            .map(|i| PathBuf::from(format!("/w/{i}/{}", "r".repeat(900))))
            .collect();
        let mut few = s.clone();
        few.read.truncate(10);
        let valid = ValidSpec::assume_valid(few, Target::Macos);
        prepare(
            &valid,
            &MacContext::default(),
            &fake_sandbox_exec(),
            &["/bin/true".into()],
        )
        .unwrap();
        let valid = ValidSpec::assume_valid(s, Target::Macos);
        let e = prepare(
            &valid,
            &MacContext::default(),
            &fake_sandbox_exec(),
            &["/bin/true".into()],
        )
        .unwrap_err();
        assert_eq!(e.rule, Rule::Malformed);
    }

    #[test]
    fn sandbox_exec_is_never_looked_up_through_path() {
        // Off macOS there is none at the fixed path (or it is not root's): refused, never searched for elsewhere.
        if cfg!(target_os = "macos") {
            assert_eq!(find().unwrap().path, Path::new(SANDBOX_EXEC));
        } else {
            let e = find().unwrap_err();
            assert_eq!(e.path.as_deref(), Some(Path::new(SANDBOX_EXEC)));
        }
    }
}
