//! Repository tasks, run as `cargo xtask <task>` (alias in `.cargo/config.toml`).

mod measure;
mod sandbox;
mod standards;
mod wit;

use std::process::ExitCode;

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let result = match args.next().as_deref() {
        Some("measure") => measure::run(args.collect()),
        Some("standards") => standards::run(args.collect()),
        Some("test-sandbox") => sandbox::run(args.collect()),
        Some("wit-check") => wit::run(args.collect()),
        Some(other) => Err(format!("unknown task `{other}`\n{USAGE}")),
        None => Err(USAGE.to_string()),
    };
    match result {
        Ok(code) => code,
        Err(message) => {
            eprintln!("xtask: {message}");
            ExitCode::from(2)
        }
    }
}

const USAGE: &str = "usage:
  cargo xtask measure <scenario> --out FILE [--base FILE] (--pid PID | --spawn CMD [ARGS])
  cargo xtask standards [--write] [--changed FILE…] [--commit-msg MSGFILE FILE…]
  cargo xtask test-sandbox [NEXTEST ARGS…]
  cargo xtask wit-check [--root DIR] [--base REF]";
