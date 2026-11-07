//! The sidecar's image: a scratch image holding `/px` and a passwd file, built from the binary alone.
//!
//! The tar is a pure function of the binary (fixed order, mtime 0, uid/gid 0), so the tag
//! `localhost/drgnx-px:<16 hex of sha256(tar)>` names the content: a new binary is a new image, an old one is never
//! reused by accident. `podman import` makes the image from the tar on stdin; a host that has it already imports nothing.

use std::ffi::OsString;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};

/// The passwd file the image carries: the sidecar runs as `nobody` (65534) and needs a name for it.
pub const PASSWD: &str = "nobody:x:65534:65534::/:/px\n";

/// The tar of the image: `etc/`, `etc/passwd` and `px` (0755), in that order.
pub fn image_tar(px: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(px.len() + 4096);
    entry(&mut out, "etc/", b'5', 0o755, &[]);
    entry(&mut out, "etc/passwd", b'0', 0o644, PASSWD.as_bytes());
    entry(&mut out, "px", b'0', 0o755, px);
    out.resize(out.len() + 1024, 0);
    out
}

/// One ustar entry: the header, then the body padded to a block.
fn entry(out: &mut Vec<u8>, name: &str, kind: u8, mode: u32, body: &[u8]) {
    let mut h = [0u8; 512];
    h[..name.len()].copy_from_slice(name.as_bytes());
    h[100..108].copy_from_slice(format!("{mode:07o}\0").as_bytes());
    h[108..116].copy_from_slice(b"0000000\0");
    h[116..124].copy_from_slice(b"0000000\0");
    h[124..136].copy_from_slice(format!("{:011o}\0", body.len()).as_bytes());
    h[136..148].copy_from_slice(b"00000000000\0");
    h[148..156].fill(b' ');
    h[156] = kind;
    h[257..263].copy_from_slice(b"ustar\0");
    h[263..265].copy_from_slice(b"00");
    let sum: u32 = h.iter().map(|b| u32::from(*b)).sum();
    h[148..156].copy_from_slice(format!("{sum:06o}\0 ").as_bytes());
    out.extend_from_slice(&h);
    out.extend_from_slice(body);
    out.resize(out.len().next_multiple_of(512), 0);
}

/// `localhost/drgnx-px:<first 16 hex of sha256(TAR)>`.
pub fn image_ref(tar: &[u8]) -> String {
    let digest = Sha256::digest(tar);
    let hex: String = digest.iter().take(8).map(|b| format!("{b:02x}")).collect();
    format!("localhost/drgnx-px:{hex}")
}

/// The sidecar binary for a podman architecture (`amd64`, `arm64`): `drgnx-px-<arch>-linux-musl` in DIR.
pub fn binary_for(dir: &Path, podman_arch: &str) -> PathBuf {
    let arch = if podman_arch == "arm64" {
        "aarch64"
    } else {
        "x86_64"
    };
    dir.join(format!("drgnx-px-{arch}-linux-musl"))
}

/// Makes sure the image for TAR exists and returns its reference: `podman image exists`, else `podman import`
/// from stdin with the entrypoint `/px`. PODMAN runs with exactly ENV and is killed when it outlives LIMIT.
pub fn ensure_image(
    podman: &Path,
    env: &[(OsString, OsString)],
    tar: &[u8],
    limit: Duration,
) -> Result<String, String> {
    let image = image_ref(tar);
    let start = Instant::now();
    let exists = podman_run(podman, env, &["image", "exists", &image], &[], limit)?;
    if exists.0 {
        return Ok(image);
    }
    let left = limit.saturating_sub(start.elapsed());
    let args = ["import", "--change", "ENTRYPOINT [\"/px\"]", "-", &image];
    let (ok, stderr) = podman_run(podman, env, &args, tar, left)?;
    if ok {
        Ok(image)
    } else {
        Err(format!(
            "podman import of the relay's image failed: {}",
            stderr.trim()
        ))
    }
}

/// Runs `podman ARGS` with exactly ENV and STDIN; (success, stderr). Killed when it outlives LIMIT.
fn podman_run(
    podman: &Path,
    env: &[(OsString, OsString)],
    args: &[&str],
    stdin: &[u8],
    limit: Duration,
) -> Result<(bool, String), String> {
    let mut child = Command::new(podman)
        .args(args)
        .env_clear()
        .envs(env.iter().map(|(k, v)| (k, v)))
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("podman: {e}"))?;
    // stdin and stderr move on threads: a full pipe on either side must not stall the clock below
    let mut pipe = child.stdin.take().expect("piped");
    let body = stdin.to_vec();
    let feed = std::thread::spawn(move || {
        let _ = pipe.write_all(&body);
    });
    let mut err = child.stderr.take().expect("piped");
    let drain = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = err.by_ref().take(4096).read_to_string(&mut text);
        let _ = std::io::copy(&mut err, &mut std::io::sink());
        text
    });
    let start = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(st)) => break Ok(st),
            Ok(None) if start.elapsed() < limit => std::thread::sleep(Duration::from_millis(10)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                break Err(format!(
                    "podman {} took longer than {}s",
                    args.first().copied().unwrap_or(""),
                    limit.as_secs().max(1)
                ));
            }
            Err(e) => break Err(format!("podman: {e}")),
        }
    };
    let _ = feed.join();
    let text = drain.join().unwrap_or_default();
    status.map(|st| (st.success(), text))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// A podman that logs its argv (one line per call) and stdin length, and exists-or-not by a marker file.
    ///
    /// Tests that write a script and run it take this lock: a script's write fd inherited by another test's fork
    /// makes the exec fail with ETXTBSY.
    static EXEC: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn fake_podman(dir: &Path, body: &str) -> PathBuf {
        let p = dir.join("podman");
        std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        p
    }

    fn entries(tar: &[u8]) -> Vec<(String, u32, u64, usize, u32, u32)> {
        // (name, mode, mtime, size, uid, gid)
        let oct = |b: &[u8]| {
            let s: String = b
                .iter()
                .take_while(|c| **c != 0 && **c != b' ')
                .map(|c| *c as char)
                .collect();
            u64::from_str_radix(&s, 8).unwrap()
        };
        let mut out = vec![];
        let mut at = 0;
        while at + 512 <= tar.len() && tar[at] != 0 {
            let h = &tar[at..at + 512];
            let name: String = h[..100]
                .iter()
                .take_while(|c| **c != 0)
                .map(|c| *c as char)
                .collect();
            let size = oct(&h[124..136]) as usize;
            out.push((
                name,
                oct(&h[100..108]) as u32,
                oct(&h[136..148]),
                size,
                oct(&h[108..116]) as u32,
                oct(&h[116..124]) as u32,
            ));
            at += 512 + size.div_ceil(512) * 512;
        }
        out
    }

    #[test]
    fn the_tar_is_byte_identical_for_one_binary() {
        let px = b"\x7fELF not really".to_vec();
        let a = image_tar(&px);
        assert_eq!(a, image_tar(&px));
        assert_eq!(a.len() % 512, 0);
        let e = entries(&a);
        let names: Vec<&str> = e.iter().map(|e| e.0.as_str()).collect();
        assert_eq!(names, ["etc/", "etc/passwd", "px"]);
        assert_eq!(e[1].1, 0o644);
        assert_eq!(e[2].1, 0o755);
        assert_eq!(e[2].3, px.len());
        assert_eq!(e[1].3, PASSWD.len());
        for x in &e {
            assert_eq!((x.2, x.4, x.5), (0, 0, 0), "mtime, uid, gid of {}", x.0);
        }
        // the binary's bytes sit right after its header, and the passwd line is the one the sidecar's user needs
        let at = a.windows(px.len()).position(|w| w == px).unwrap();
        assert_eq!(at % 512, 0);
        assert!(a.windows(PASSWD.len()).any(|w| w == PASSWD.as_bytes()));
        // the archive ends with two zero blocks
        assert!(a[a.len() - 1024..].iter().all(|b| *b == 0));
        // each header's checksum is the sum of its bytes with the field as spaces
        let mut at = 0;
        for x in &e {
            let h = &a[at..at + 512];
            let mut sum: u32 = h.iter().map(|b| *b as u32).sum();
            sum -= h[148..156].iter().map(|b| *b as u32).sum::<u32>();
            sum += 8 * 32;
            let want = std::str::from_utf8(&h[148..154]).unwrap();
            assert_eq!(
                u32::from_str_radix(want, 8).unwrap(),
                sum,
                "checksum of {}",
                x.0
            );
            at += 512 + x.3.div_ceil(512) * 512;
        }
    }

    #[test]
    fn the_ref_changes_with_the_binary() {
        let a = image_ref(&image_tar(b"one"));
        let b = image_ref(&image_tar(b"two"));
        assert_ne!(a, b);
        assert_eq!(a, image_ref(&image_tar(b"one")));
        let tag = a.strip_prefix("localhost/drgnx-px:").unwrap();
        assert_eq!(tag.len(), 16);
        assert!(
            tag.bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        );
    }

    #[test]
    fn arm64_picks_the_aarch64_binary() {
        let d = Path::new("/bundle");
        assert_eq!(
            binary_for(d, "arm64"),
            d.join("drgnx-px-aarch64-linux-musl")
        );
        assert_eq!(binary_for(d, "amd64"), d.join("drgnx-px-x86_64-linux-musl"));
    }

    #[test]
    fn a_missing_image_is_imported_from_stdin_with_the_entrypoint() {
        let _lock = EXEC.lock().unwrap_or_else(|e| e.into_inner());
        let t = tempfile::tempdir().unwrap();
        let log = t.path().join("log");
        let p = fake_podman(
            t.path(),
            &format!(
                "echo \"$@\" >> {l}\n[ \"$1 $2\" = \"image exists\" ] && exit 1\n[ \"$1\" = import ] && wc -c >> {l}\nexit 0",
                l = log.display()
            ),
        );
        let tar = image_tar(b"px");
        let got = ensure_image(&p, &[], &tar, Duration::from_secs(20)).unwrap();
        assert_eq!(got, image_ref(&tar));
        let lines: Vec<String> = std::fs::read_to_string(&log)
            .unwrap()
            .lines()
            .map(String::from)
            .collect();
        assert_eq!(lines[0], format!("image exists {got}"));
        assert_eq!(
            lines[1],
            format!("import --change ENTRYPOINT [\"/px\"] - {got}")
        );
        assert_eq!(lines[2].trim(), tar.len().to_string());
    }

    #[test]
    fn an_existing_image_is_not_imported_again() {
        let _lock = EXEC.lock().unwrap_or_else(|e| e.into_inner());
        let t = tempfile::tempdir().unwrap();
        let log = t.path().join("log");
        let p = fake_podman(
            t.path(),
            &format!("echo \"$@\" >> {}\nexit 0", log.display()),
        );
        let tar = image_tar(b"px");
        ensure_image(&p, &[], &tar, Duration::from_secs(20)).unwrap();
        assert_eq!(std::fs::read_to_string(&log).unwrap().lines().count(), 1);
    }

    #[test]
    fn a_failed_import_says_what_podman_said_and_a_slow_one_is_killed() {
        let _lock = EXEC.lock().unwrap_or_else(|e| e.into_inner());
        let t = tempfile::tempdir().unwrap();
        let p = fake_podman(
            t.path(),
            "[ \"$1 $2\" = \"image exists\" ] && exit 1\necho 'no space left' >&2\nexit 125",
        );
        let e = ensure_image(&p, &[], &image_tar(b"px"), Duration::from_secs(20)).unwrap_err();
        assert!(e.contains("no space left"), "{e}");
        let t2 = tempfile::tempdir().unwrap();
        let p = fake_podman(
            t2.path(),
            "[ \"$1 $2\" = \"image exists\" ] && exit 1\nexec sleep 30",
        );
        let e = ensure_image(&p, &[], &image_tar(b"px"), Duration::from_millis(300)).unwrap_err();
        assert!(e.contains("longer than"), "{e}");
    }

    /// Needs rootless podman: the imported image runs the relay.
    #[test]
    #[ignore = "podman-host"]
    fn an_imported_image_runs_px() {
        let dir = std::env::var_os("DRGNX_TEST_PX_DIR")
            .map(PathBuf::from)
            .expect("DRGNX_TEST_PX_DIR: the folder of drgnx-px-<arch>-linux-musl");
        let arch = if cfg!(target_arch = "aarch64") {
            "arm64"
        } else {
            "amd64"
        };
        let px = std::fs::read(binary_for(&dir, arch)).unwrap();
        let tar = image_tar(&px);
        let env: Vec<(OsString, OsString)> = ["PATH", "HOME", "XDG_RUNTIME_DIR"]
            .iter()
            .filter_map(|k| std::env::var_os(k).map(|v| (OsString::from(k), v)))
            .collect();
        let r = ensure_image(Path::new("podman"), &env, &tar, Duration::from_secs(120)).unwrap();
        let out = Command::new("podman")
            .args(["run", "--rm", "--pull=never", &r, "--version"])
            .envs(env.iter().map(|(k, v)| (k, v)))
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(
            String::from_utf8_lossy(&out.stdout).contains("drgnx-px"),
            "{}",
            String::from_utf8_lossy(&out.stdout)
        );
        let _ = Command::new("podman")
            .args(["rmi", &r])
            .envs(env.iter().map(|(k, v)| (k, v)))
            .output();
    }
}
