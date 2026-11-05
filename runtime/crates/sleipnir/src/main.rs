//! `sleipnir`: the runner binary. Its modes:
//!
//! ```text
//! sleipnir serve --root DIR --prefix P --hub-id H --profile dedicated|workstation
//!                                             the hub's control channel, on stdin and stdout
//! sleipnir job-exec <attempt folder>          runs the folder's job.json, writes its result.json
//! sleipnir bench --root DIR --image DIGEST    this runner's speed, as JSON on stdout
//! sleipnir git-receive --root ROOT REPO       the hub's `git push --receive-pack`: receive-pack on a mirror, hardened
//! sleipnir credential-helper SOCKET OP        git's credential helper for an origin fetch: the token from SOCKET
//! ```

use std::process::ExitCode;

const USAGE: &str = "usage: sleipnir serve --root DIR --prefix P --hub-id H --profile dedicated|workstation\n       \
                     sleipnir job-exec <attempt folder>\n       \
                     sleipnir bench --root DIR --image DIGEST\n       \
                     sleipnir git-receive --root ROOT REPO\n       \
                     sleipnir credential-helper SOCKET OP";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
        ["job-exec", dir] => job_exec(std::path::Path::new(dir)),
        ["serve", ref rest @ ..] => serve(rest),
        ["bench", "--root", root, "--image", image] => bench(root, image),
        #[cfg(feature = "sync")]
        ["git-receive", "--root", root, repo] => sync::git_receive(root, repo),
        #[cfg(feature = "sync")]
        ["credential-helper", sock, op] => sync::credential_helper(sock, op),
        #[cfg(all(feature = "sync", feature = "test-hooks"))]
        [
            "sync-bundle",
            "--root",
            root,
            "--repo",
            repo,
            "--sha256",
            sha,
            "--size",
            size,
        ] => sync::bundle(root, repo, sha, size),
        _ => {
            eprintln!("{USAGE}");
            ExitCode::from(2)
        }
    }
}

#[cfg(all(feature = "runner", target_os = "linux"))]
fn serve(args: &[&str]) -> ExitCode {
    match sleipnir::serve::Config::parse(args) {
        Ok(cfg) => ExitCode::from(
            sleipnir::serve::run(cfg, std::io::stdin(), std::io::stdout()).clamp(0, 255) as u8,
        ),
        Err(e) => {
            eprintln!("sleipnir serve: {e}\n{USAGE}");
            ExitCode::from(2)
        }
    }
}

/// A runner serves only where it can run jobs: Linux with a systemd user manager, built with the `runner` feature.
#[cfg(not(all(feature = "runner", target_os = "linux")))]
fn serve(_args: &[&str]) -> ExitCode {
    eprintln!("sleipnir serve: runners serve only on Linux with a systemd user manager");
    ExitCode::from(2)
}

/// The result as JSON on stdout; the caps the workload ran under on stderr.
#[cfg(all(feature = "runner", target_os = "linux"))]
fn bench(root: &str, image: &str) -> ExitCode {
    let root = std::path::Path::new(root);
    if !root.is_absolute() {
        eprintln!("sleipnir bench: --root must be absolute");
        return ExitCode::from(2);
    }
    match sleipnir::bench::run(root, image) {
        Ok((result, t)) => {
            eprintln!(
                "sleipnir bench: cpu {:.2} s, io {:.2} s, inside memory.max={} cpu.max={}",
                t.cpu_s, t.io_s, t.memory_max, t.cpu_max
            );
            match serde_json::to_string(&result) {
                Ok(json) => {
                    println!("{json}");
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("sleipnir bench: {e}");
                    ExitCode::FAILURE
                }
            }
        }
        Err(e) => {
            eprintln!("sleipnir bench: {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(not(all(feature = "runner", target_os = "linux")))]
fn bench(_root: &str, _image: &str) -> ExitCode {
    eprintln!("sleipnir bench: runners run only on Linux with a systemd user manager");
    ExitCode::from(2)
}

#[cfg(target_os = "linux")]
fn job_exec(dir: &std::path::Path) -> ExitCode {
    match sleipnir::linux::jobexec::JobExec::read(dir) {
        Ok(spec) => {
            sleipnir::linux::jobexec::run(dir, &spec);
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("sleipnir job-exec: {}: {e}", dir.display());
            ExitCode::from(2)
        }
    }
}

/// Jobs run under a systemd user manager and cgroup v2: anywhere else every job is refused, never run unconfined.
#[cfg(not(target_os = "linux"))]
fn job_exec(_dir: &std::path::Path) -> ExitCode {
    eprintln!("sleipnir job-exec: jobs run only on Linux with a systemd user manager");
    ExitCode::from(2)
}

#[cfg(feature = "sync")]
mod sync {
    use std::path::Path;
    use std::process::ExitCode;

    use sleipnir::sync::{cred, mirror};

    pub fn git_receive(root: &str, repo: &str) -> ExitCode {
        use std::os::unix::process::CommandExt;
        match mirror::git_receive(Path::new(root), repo) {
            // exec only returns on failure
            Ok(mut c) => {
                let e = c.exec();
                eprintln!("sleipnir git-receive: {e}");
                ExitCode::from(2)
            }
            Err(e) => {
                eprintln!("sleipnir git-receive: {e}");
                ExitCode::from(2)
            }
        }
    }

    pub fn credential_helper(sock: &str, op: &str) -> ExitCode {
        match cred::helper(Path::new(sock), op) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("sleipnir credential-helper: {e}");
                ExitCode::from(2)
            }
        }
    }

    /// Test-only: receives one bundle on stdin as the `bundle` frames would carry it, printing `at OFFSET` at the
    /// start and after every chunk, and `done` once it is in the mirror. At EOF before the end the partial file
    /// stays, for the next connection to resume.
    #[cfg(feature = "test-hooks")]
    pub fn bundle(root: &str, repo: &str, sha: &str, size: &str) -> ExitCode {
        use sleipnir::sync::bundle::{BundleRef, CHUNK, Receiver};
        use std::io::{Read, Write};
        let run = || -> Result<bool, Box<dyn std::error::Error>> {
            let want = BundleRef {
                sha256: sleipnir::sync::unhex32(sha).ok_or("--sha256: 64 hex digits")?,
                size: size.parse()?,
            };
            let mut r = Receiver::open(Path::new(root), repo, want)?;
            let mut out = std::io::stdout().lock();
            writeln!(out, "at {}", r.offset())?;
            out.flush()?;
            let mut buf = vec![0; CHUNK];
            let mut input = std::io::stdin().lock();
            while r.offset() < want.size {
                let n = input.read(&mut buf)?;
                if n == 0 {
                    return Ok(false);
                }
                r.append(&buf[..n])?;
                writeln!(out, "at {}", r.offset())?;
                out.flush()?;
            }
            r.finish()?;
            writeln!(out, "done")?;
            Ok(true)
        };
        match run() {
            Ok(_) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("sleipnir sync-bundle: {e}");
                ExitCode::from(2)
            }
        }
    }
}
