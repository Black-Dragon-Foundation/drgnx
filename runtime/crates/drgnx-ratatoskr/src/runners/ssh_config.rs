//! The ssh config the hub writes for each runner, passed to ssh with `-F` (docs/develop/hub.md, "Runners: the
//! transport").
//!
//! ssh keeps the first value it reads for an option, so the file starts with the options the hub forces: no agent,
//! X11 or port forwarding, no local command, no prompt, strict host keys, the keep-alive, the master's persistence,
//! and our command with no terminal whatever the user's config says. A cloud runner's own agent, its key's public
//! half, its certificate and its pinned host keys follow; an SSH runner's file then includes the user's `~/.ssh/config`, so the host, user, proxy and
//! keys stay the user's.

use super::RunnerCfg;
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

/// The forced options, in order: the first lines of every runner's file.
pub const FORCED: [&str; 13] = [
    "ForwardAgent no",
    "ForwardX11 no",
    "ClearAllForwardings yes",
    "PermitLocalCommand no",
    "BatchMode yes",
    "StrictHostKeyChecking yes",
    "UpdateHostKeys no",
    "ServerAliveInterval 15",
    "ServerAliveCountMax 4",
    "Compression yes",
    "ControlPersist 10m",
    "RemoteCommand none",
    "RequestTTY no",
];

/// The user's own config, after the forced options, for an SSH runner.
pub const USER_CONFIG: &str = "Include ~/.ssh/config";

/// The file's text for R, which has passed [`RunnerCfg::check`].
pub fn render(r: &RunnerCfg) -> String {
    debug_assert_eq!(r.check(), Ok(()));
    let mut s = String::new();
    for l in FORCED {
        s.push_str(l);
        s.push('\n');
    }
    match &r.cloud {
        Some(c) => {
            // the key's public half as IdentityFile: without it ssh finds no private key for the certificate (the agent's
            // key matches only a named identity under IdentitiesOnly) and offers the user's default keys instead
            for (k, p) in [
                ("IdentityAgent", &c.identity_agent),
                ("IdentityFile", &c.identity_file),
                ("CertificateFile", &c.certificate),
            ] {
                s.push_str(&format!("{k} \"{}\"\n", p.display()));
            }
            s.push_str("IdentitiesOnly yes\n");
            s.push_str(&format!(
                "UserKnownHostsFile \"{}\"\n",
                c.known_hosts.display()
            ));
        }
        None => {
            s.push_str(USER_CONFIG);
            s.push('\n');
        }
    }
    s
}

/// The runner's own folder: `RUNTIME_DIR/drgnx-runners/NAME`, which holds its ssh config and its master's socket.
pub fn dir(runtime_dir: &Path, name: &str) -> PathBuf {
    runtime_dir.join("drgnx-runners").join(name)
}

/// The longest path a Unix socket may have: `sun_path` (104 bytes on macOS, 108 on Linux) less its NUL.
const SOCKET_PATH_MAX: usize = if cfg!(target_os = "macos") { 103 } else { 107 };
/// What goes after the master's folder in its socket's path: the `openssh` crate's `/.ssh-connectionXXXXXX/master`,
/// and the temporary suffix ssh binds it under first (`.XXXXXXXXXXXXXXXX`).
const SOCKET_TAIL: usize = "/.ssh-connectionXXXXXX/master".len() + ".XXXXXXXXXXXXXXXX".len();

/// The folder for the runner NAME's master socket, made private: the runner's own folder ([`dir`]) when the socket's
/// path fits there, else a short folder of its own under ROOT, named by a hash of the runner's folder (so the same
/// runner gets the same one, which a later hub resumes). That is the case on macOS, whose per-user temporary folder is
/// long, with a long name. ROOT is made private too then; a link or another user's folder is refused.
pub fn control_dir_at(runtime_dir: &Path, name: &str, root: &Path) -> io::Result<PathBuf> {
    let d = dir(runtime_dir, name);
    if d.as_os_str().len() + SOCKET_TAIL <= SOCKET_PATH_MAX {
        private_dir(&d)?;
        return Ok(d);
    }
    use sha2::Digest;
    use std::os::unix::ffi::OsStrExt;
    let hash = sha2::Sha256::digest(d.as_os_str().as_bytes());
    let short = root.join(
        hash[..8]
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>(),
    );
    private_dir(root)?;
    private_dir(&short)?;
    Ok(short)
}

/// [`control_dir_at`] under `/tmp/drgnx-ssh-<uid>`.
pub fn control_dir(runtime_dir: &Path, name: &str) -> io::Result<PathBuf> {
    let root = PathBuf::from(format!(
        "/tmp/drgnx-ssh-{}",
        rustix::process::getuid().as_raw()
    ));
    control_dir_at(runtime_dir, name, &root)
}

/// The runner's ssh config: `RUNTIME_DIR/drgnx-runners/NAME/ssh_config`.
pub fn path(runtime_dir: &Path, name: &str) -> PathBuf {
    dir(runtime_dir, name).join("ssh_config")
}

/// Writes TEXT as the runner NAME's ssh config and returns its path, `RUNTIME_DIR/drgnx-runners/NAME/ssh_config`. The
/// file is mode 0600 and its folders 0700, owned by the hub's user; a folder that is a link, or someone else's, is
/// refused. The text replaces the old file in one rename.
pub fn write(runtime_dir: &Path, name: &str, text: &str) -> io::Result<PathBuf> {
    write_in(runtime_dir, name, "ssh_config", text)
}

/// TEXT as the file FILE in the runner NAME's folder, as [`write`] writes the config: 0600 in 0700 folders, replaced in
/// one rename. A cloud runner's public files go here: its certificate, its key's public half, its pinned host keys.
pub fn write_in(runtime_dir: &Path, name: &str, file: &str, text: &str) -> io::Result<PathBuf> {
    private_dir(&runtime_dir.join("drgnx-runners"))?;
    let d = dir(runtime_dir, name);
    private_dir(&d)?;
    let tmp = d.join(format!(".{file}.new"));
    match std::fs::remove_file(&tmp) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&tmp)?;
    f.write_all(text.as_bytes())?;
    f.sync_all()?;
    drop(f);
    let p = d.join(file);
    std::fs::rename(&tmp, &p)?;
    Ok(p)
}

/// D exists as a folder of the hub's user, mode 0700: made if missing, narrowed if wider; a link or someone else's
/// folder is refused.
pub(crate) fn private_dir(d: &Path) -> io::Result<()> {
    match std::fs::symlink_metadata(d) {
        Ok(m) => {
            if !m.file_type().is_dir() {
                return Err(io::Error::other(format!(
                    "{} is not a folder (a link is never followed)",
                    d.display()
                )));
            }
            if m.uid() != rustix::process::getuid().as_raw() {
                return Err(io::Error::other(format!(
                    "{} belongs to another user",
                    d.display()
                )));
            }
            if m.mode() & 0o7777 != 0o700 {
                std::fs::set_permissions(d, std::fs::Permissions::from_mode(0o700))?;
            }
            Ok(())
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            std::fs::DirBuilder::new().mode(0o700).create(d)?;
            // the umask may narrow it, never widen it; set it exactly
            std::fs::set_permissions(d, std::fs::Permissions::from_mode(0o700))
        }
        Err(e) => Err(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runners::CloudSsh;
    use crate::runners::tests::ssh_runner;
    use std::os::unix::fs::PermissionsExt;

    /// [D] A master's socket path fits a Unix socket's `sun_path` (104 bytes on macOS) whatever the run dir and the
    /// runner's name: under a long run dir (macOS's per-user temporary folder) and a long name the socket's folder is
    /// a short one of its own under the root, private, the same for the same runner and another for another; under a
    /// short run dir it stays the runner's folder. A root that is a link is refused.
    #[test]
    fn a_long_runner_name_gets_a_short_control_folder() {
        let t = tempfile::Builder::new().tempdir_in("/tmp").unwrap();
        let root = t.path().join("s");
        let long_run = Path::new("/var/folders/6m/g3m822tx5754yy400ffqz8km0000gp/T/.tmpAbCdEf/run");
        // the long run dir has to exist for the runner's own folder to be made; the short folder doesn't need it
        let name = "a-runner-with-a-name-as-long-as-a-host-label-may-be-0123456789ab";
        let socket_len =
            |d: &Path| d.as_os_str().len() + "/.ssh-connectionXXXXXX/master.XXXXXXXXXXXXXXXX".len();
        let d = control_dir_at(long_run, name, &root).unwrap();
        assert!(
            socket_len(&d) <= 103,
            "{} ({} bytes)",
            d.display(),
            socket_len(&d)
        );
        assert!(d.starts_with(&root), "{}", d.display());
        for p in [&root, &d] {
            assert_eq!(
                std::fs::metadata(p).unwrap().permissions().mode() & 0o777,
                0o700
            );
        }
        assert_eq!(control_dir_at(long_run, name, &root).unwrap(), d);
        assert_ne!(control_dir_at(long_run, "other", &root).unwrap(), d);
        // a short run dir keeps the runner's own folder
        let short_run = t.path().join("r");
        std::fs::create_dir(&short_run).unwrap();
        write(&short_run, "mini", "x").unwrap();
        assert_eq!(
            control_dir_at(&short_run, "mini", &root).unwrap(),
            dir(&short_run, "mini")
        );
        // a root that is a link is never followed
        let linked = t.path().join("l");
        std::os::unix::fs::symlink(t.path().join("elsewhere"), &linked).unwrap();
        assert!(control_dir_at(long_run, name, &linked).is_err());
    }

    // [D] pure
    #[test]
    fn forced_options_come_first_and_exactly() {
        let text = render(&ssh_runner("desktop", "desktop"));
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines[..FORCED.len()], FORCED);
        assert_eq!(lines[FORCED.len()..], [USER_CONFIG]);
        assert!(text.ends_with('\n'));

        let mut cloud = ssh_runner("c1", "10.0.0.9");
        cloud.cloud = Some(CloudSsh {
            identity_agent: "/run/user/1000/drgnx-runners/c1/agent.sock".into(),
            identity_file: "/run/user/1000/drgnx-runners/c1/id.pub".into(),
            certificate: "/run/user/1000/drgnx-runners/c1/id-cert.pub".into(),
            known_hosts: "/run/user/1000/drgnx runners/c1/known_hosts".into(),
        });
        let text = render(&cloud);
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines[..FORCED.len()], FORCED);
        assert_eq!(
            lines[FORCED.len()..],
            [
                "IdentityAgent \"/run/user/1000/drgnx-runners/c1/agent.sock\"",
                "IdentityFile \"/run/user/1000/drgnx-runners/c1/id.pub\"",
                "CertificateFile \"/run/user/1000/drgnx-runners/c1/id-cert.pub\"",
                "IdentitiesOnly yes",
                "UserKnownHostsFile \"/run/user/1000/drgnx runners/c1/known_hosts\"",
            ]
        );
        assert!(
            !text.contains("Include"),
            "a cloud runner never reads the user's config"
        );
    }

    // [D] pure
    #[test]
    fn the_file_is_0600() {
        let t = tempfile::tempdir().unwrap();
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o7777;
        let p = write(t.path(), "desktop", "ForwardAgent no\n").unwrap();
        assert_eq!(p, t.path().join("drgnx-runners/desktop/ssh_config"));
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "ForwardAgent no\n");
        assert_eq!(mode(&p), 0o600);
        assert_eq!(mode(&t.path().join("drgnx-runners")), 0o700);
        assert_eq!(mode(&t.path().join("drgnx-runners/desktop")), 0o700);

        // a file someone widened is replaced by a 0600 one; a widened folder is narrowed
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o644)).unwrap();
        let d = t.path().join("drgnx-runners/desktop");
        std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o755)).unwrap();
        write(t.path(), "desktop", "BatchMode yes\n").unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "BatchMode yes\n");
        assert_eq!(mode(&p), 0o600);
        assert_eq!(mode(&d), 0o700);

        // a runner folder that is a link is never written through
        let elsewhere = t.path().join("elsewhere");
        std::fs::create_dir(&elsewhere).unwrap();
        std::os::unix::fs::symlink(&elsewhere, t.path().join("drgnx-runners/linked")).unwrap();
        assert!(write(t.path(), "linked", "x\n").is_err());
        assert!(!elsewhere.join("ssh_config").exists());
    }
}
