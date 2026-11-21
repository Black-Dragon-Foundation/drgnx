//! `drgnx-px --listen <ip:port> --job-ip <ip>`: a networked container job's relay sidecar (docs/develop/drgnx-px.md).
//! Stdout carries frames only; logs and panics go to stderr, and a panic exits 101 at once.

fn main() {
    let report = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        report(info);
        std::process::exit(101);
    }));
    std::process::exit(drgnx_px::sidecar::main(
        std::env::args_os().skip(1).collect(),
    ));
}
