//! Repository tasks, run as `cargo xtask <task>` (alias in `.cargo/config.toml`).

mod measure;

use std::process::ExitCode;

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let result = match args.next().as_deref() {
        Some("measure") => measure::run(args.collect()),
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

const USAGE: &str = "usage: cargo xtask measure <scenario> --out FILE [--base FILE] (--pid PID | --spawn CMD [ARGS])";
