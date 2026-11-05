//! `sleipnir`: the runner binary. Its first mode is the one a job's unit runs:
//!
//! ```text
//! sleipnir job-exec <attempt folder>     runs the folder's job.json, writes its result.json
//! ```

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
        ["job-exec", dir] => job_exec(std::path::Path::new(dir)),
        _ => {
            eprintln!("usage: sleipnir job-exec <attempt folder>");
            ExitCode::from(2)
        }
    }
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
