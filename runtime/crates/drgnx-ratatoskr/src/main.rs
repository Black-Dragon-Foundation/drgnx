//! `ratatoskr`: drgnx's agent runtime (docs/develop/hub.md).  The tokio runtime is built by hand, after the command
//! line is read (and, from the supervise task on, after any self-detach): multi-thread, two workers.

use drgnx_ratatoskr::cli::{self, Command};
use drgnx_ratatoskr::{Exit, server, version};
use std::process::ExitCode;
use std::time::Duration;

fn main() -> ExitCode {
    let command = match cli::parse(std::env::args_os().skip(1)) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("ratatoskr: {e}\n{}", cli::USAGE);
            return ExitCode::from(Exit::Usage as u8);
        }
    };
    match command {
        Command::Version { json: true } => println!("{}", version::json()),
        Command::Version { json: false } => println!("{}", version::text()),
        Command::Serve(args) => {
            let runtime = match tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
            {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("ratatoskr: cannot start: no async runtime: {e}");
                    return ExitCode::from(Exit::CannotStart as u8);
                }
            };
            let exit = runtime.block_on(server::run(args));
            runtime.shutdown_timeout(Duration::from_secs(1));
            return ExitCode::from(exit as u8);
        }
    }
    ExitCode::SUCCESS
}
