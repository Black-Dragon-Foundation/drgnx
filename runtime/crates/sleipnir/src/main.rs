//! `sleipnir`: the runner binary.
//!
//! ```text
//! sleipnir serve --root DIR --prefix P --hub-id H --profile dedicated|workstation
//!                                         the hub's control channel, on stdin and stdout
//! sleipnir job-exec <attempt folder>     runs the folder's job.json, writes its result.json
//! ```

use std::process::ExitCode;

const USAGE: &str = "usage: sleipnir serve --root DIR --prefix P --hub-id H --profile dedicated|workstation\n       sleipnir job-exec <attempt folder>";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
        ["job-exec", dir] => job_exec(std::path::Path::new(dir)),
        ["serve", ref rest @ ..] => serve(rest),
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
