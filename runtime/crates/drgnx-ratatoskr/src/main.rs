//! `ratatoskr`: drgnx's agent runtime (docs/develop/hub.md).  The tokio runtime is built by hand, after the command
//! line is read (the commands that only talk to a hub never build one): multi-thread, two workers.  The same binary
//! answers to any name (`rtsk`), with one exception: started as `gleipnir-trace` (the link Gleipnir puts beside the
//! inner helper for per-step tracing, `gleipnir::TRACE_INSIDE`) it is that wrapper and nothing else.

use drgnx_ratatoskr::cli::{self, Command, Supervisor};
use drgnx_ratatoskr::{Exit, doctor, idle, server, supervise, version};
use runstav::paths::Env;
use std::os::unix::process::CommandExt;
use std::process::ExitCode;
use std::time::Duration;

fn code(c: i32) -> ExitCode {
    ExitCode::from(u8::try_from(c).unwrap_or(1))
}

fn main() -> ExitCode {
    // the per-step wrapper of a traced shell step: before anything else, with no runtime and no thread
    let argv0 = std::env::args_os().next().unwrap_or_default();
    if std::path::Path::new(&argv0).file_name()
        == Some(std::ffi::OsStr::new(gleipnir::trace::WRAPPER_NAME))
    {
        return code(gleipnir::trace::wrapper_main(std::env::args_os().collect()));
    }
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
        Command::Methods { markdown: false } => {
            print!("{}", runstav::registry::methods_json_text())
        }
        Command::Methods { markdown: true } => {
            print!("{}", runstav::registry::markdown_table())
        }
        Command::Ensure { timeout } => return code(supervise::ensure(&Env::process(), timeout)),
        Command::Stop { timeout } => return code(supervise::stop(&Env::process(), timeout)),
        Command::Status { json } => return code(doctor::status(&Env::process(), json)),
        Command::Doctor { json } => return code(doctor::doctor(&Env::process(), json)),
        Command::SandboxCheck(args) => return code(drgnx_ratatoskr::sandbox::check_command(args)),
        Command::Restart => return code(doctor::restart(&Env::process())),
        // Before any thread or runtime exists: the helper asserts it is single-threaded. Not Linux: it exits 125 with
        // "the inner helper is Linux only" (Android: no backend; apps get no user namespaces; fails closed).
        Command::SandboxInner { args } => {
            return code(gleipnir::inner::inner_main(args.into_iter()));
        }
        // The relay builds its own single-threaded runtime; it refuses to start under another parent than its
        // `--parent-pid`.
        Command::Relay { args } => return code(gleipnir::net::relay::main(args.into_iter())),
        // Its own single-threaded runtime; it reads no environment variable but, outside, the data dir's.
        Command::McpBridge(args) => return ExitCode::from(drgnx_ratatoskr::bridge::main(args)),
        // No runtime: the migration and the copy run on this thread, and refuse while a hub holds the store.
        Command::Store(cli::StoreCommand::MigrateCheck { db, scratch, json }) => {
            return code(drgnx_ratatoskr::store_cli::migrate_check(
                &Env::process(),
                &db,
                &scratch,
                json,
            ));
        }
        Command::Store(cli::StoreCommand::RestorePre7 { yes }) => {
            return code(drgnx_ratatoskr::store_cli::restore_pre7(
                &Env::process(),
                yes,
            ));
        }
        // No runtime: a blocking client of the running hub (started first when none runs).
        Command::Graph(g) => return code(drgnx_ratatoskr::graph_cli::run(&Env::process(), g)),
        // No runtime either: the job commands are one call each to the running hub.
        Command::Job(j) => return code(drgnx_ratatoskr::job_cli::run(&Env::process(), j)),
        Command::Machines(m) => {
            return code(drgnx_ratatoskr::machines_cli::run(&Env::process(), &m));
        }
        Command::Runner(r) => return code(drgnx_ratatoskr::runner_cli::run(&Env::process(), r)),
        // Hrafn from a terminal (and `search mcp`, which builds a runtime of its own).
        Command::Search(s) => return code(drgnx_ratatoskr::search_cli::run(&Env::process(), s)),
        // Hrafn's embed worker: threads of its own (stdin, the CPU path's pool), never a tokio runtime.
        Command::EmbedWorker(args) => return code(drgnx_ratatoskr::search::worker::run(args)),
        // Test builds only: one command under the sandbox, judged by its --result file.
        #[cfg(feature = "test-hooks")]
        Command::SandboxRun(args) => return code(drgnx_ratatoskr::sandbox::run(args)),
        Command::Serve(args) => {
            let supervisor = args.supervisor;
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
            return match (exit, supervisor) {
                // nothing supervises this hub: run the binary at the path resolved at start again
                (Exit::Restart, Supervisor::SelfDetached) => reexec(),
                // launchd restarts on every non-zero exit, so only 75 and a crash may reach it
                (Exit::CannotStart | Exit::Usage | Exit::AnotherHub, Supervisor::Launchd) => {
                    eprintln!(
                        "ratatoskr: exit {} mapped to 0 for launchd (the reason is in the hub's log)",
                        exit as u8
                    );
                    ExitCode::SUCCESS
                }
                _ => ExitCode::from(exit as u8),
            };
        }
    }
    ExitCode::SUCCESS
}

/// Replace this process with the binary at the path resolved at start, the same arguments.  The lock was kept open
/// across this call and goes with the exec (every descriptor is close-on-exec); only a failed exec returns.
fn reexec() -> ExitCode {
    let Some(exe) = idle::start_exe() else {
        eprintln!("ratatoskr: cannot restart: no resolved executable path");
        return ExitCode::from(Exit::CannotStart as u8);
    };
    let err = std::process::Command::new(exe)
        .args(std::env::args_os().skip(1))
        .exec();
    eprintln!("ratatoskr: cannot execute {} again: {err}", exe.display());
    ExitCode::from(Exit::CannotStart as u8)
}
