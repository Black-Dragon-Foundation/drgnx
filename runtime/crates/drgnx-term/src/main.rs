//! `drgnx-term --socket PATH [--cols N] [--rows N] [--cell W,H] [--window N] [--dir DIR] -- PROGRAM [ARGS...]`
//!
//! Runs PROGRAM on a new PTY with this process's environment and serves the hub on PATH (a Unix socket it creates).
//! The hub starts it (docs/develop/terminal.md, "The worker"); it is not meant to be run by hand. Logs go to stderr at
//! `DRGNX_TERM_LOG` (error, warn, info, debug or trace; default info) and never carry the program's bytes.

#[cfg(not(feature = "ghostty"))]
fn main() {
    eprintln!("drgnx-term: built without the terminal engine (feature `ghostty`)");
    std::process::exit(78);
}

#[cfg(feature = "ghostty")]
fn main() {
    match serve() {
        Ok((code, signal)) => std::process::exit(code.unwrap_or(128 + signal.unwrap_or(0))),
        Err(e) => {
            eprintln!("drgnx-term: {e}");
            std::process::exit(1);
        }
    }
}

#[cfg(feature = "ghostty")]
fn serve() -> Result<drgnx_term::run::Exit, String> {
    use drgnx_term::{pty, worker};

    let level = match std::env::var("DRGNX_TERM_LOG").as_deref() {
        Ok("error") => tracing::Level::ERROR,
        Ok("warn") => tracing::Level::WARN,
        Ok("debug") => tracing::Level::DEBUG,
        Ok("trace") => tracing::Level::TRACE,
        _ => tracing::Level::INFO,
    };
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_max_level(level)
        .init();
    ghostty_vt_sys::ghostty_vt_check()?;

    let mut args = std::env::args().skip(1);
    let mut opts = worker::Opts::default();
    let (mut socket, mut dir) = (None, ".".to_owned());
    let mut command = Vec::new();
    while let Some(a) = args.next() {
        let mut val = || args.next().ok_or_else(|| format!("{a} needs a value"));
        match a.as_str() {
            "--socket" => socket = Some(val()?),
            "--cols" => opts.cols = val()?.parse().map_err(|_| "--cols: a number")?,
            "--rows" => opts.rows = val()?.parse().map_err(|_| "--rows: a number")?,
            "--window" => {
                opts.window = val()?.parse().map_err(|_| "--window: a number")?;
                opts.scrollback = opts.window;
            }
            "--cell" => {
                let v = val()?;
                let (w, h) = v.split_once(',').ok_or("--cell: W,H")?;
                opts.cell_px = (
                    w.parse().map_err(|_| "--cell: W,H")?,
                    h.parse().map_err(|_| "--cell: W,H")?,
                );
            }
            "--dir" => dir = val()?,
            "--" => {
                command = args.by_ref().collect();
                break;
            }
            _ => return Err(format!("unknown argument {a}")),
        }
    }
    let socket = socket.ok_or("--socket is required")?;
    let (program, rest) = command.split_first().ok_or("no program after --")?;
    let listener = drgnx_term::run::listen(std::path::Path::new(&socket))
        .map_err(|e| format!("{socket}: {e}"))?;
    let env: Vec<(String, String)> = std::env::vars().collect();
    let size = pty::winsize(opts.cols, opts.rows, opts.cell_px);
    let pty =
        pty::Pty::spawn(program, rest, &dir, &env, size).map_err(|e| format!("{program}: {e}"))?;
    // the canvases beside the socket, in the user's own term directory: `<id>.img/`
    opts.img_dir = Some(std::path::Path::new(&socket).with_extension("img"));
    let worker = worker::Worker::new(&opts)?;
    let exit = drgnx_term::run::run(worker, pty, None, Some(listener)).map_err(|e| e.to_string());
    let _ = std::fs::remove_file(&socket);
    exit
}
