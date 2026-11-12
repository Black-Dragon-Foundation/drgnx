//! Probe markers as D2's forks use them: a private copy of D1's `debug/probes.rs` with the same names, deleted at
//! D1's merge (the coordinator's ruling, 2026-11-12).

/// What starts a probe's output, wherever it is in the line (delve prefixes logpoint output with `> [Go 1]: `).
pub const MARK: &str = "\u{1e}drgnx:";

/// The `logMessage` of probe PROBE: the thread expression's value and the expression's, each in braces.
pub fn marker(probe: &str, thread_expr: &str, expr: &str) -> String {
    format!("{MARK}{probe}:{{{thread_expr}}}:{{{expr}}}")
}

/// A probe's output: (probe, thread, value); none for other output.
pub fn parse(output: &str) -> Option<(String, String, String)> {
    let at = output.find(MARK)?;
    let rest = &output[at + MARK.len()..];
    let (probe, rest) = rest.split_once(':')?;
    let (thread, value) = rest.split_once(':')?;
    let value = value.strip_suffix('\n').unwrap_or(value);
    let value = value.strip_suffix('\r').unwrap_or(value);
    Some((probe.to_owned(), thread.to_owned(), value.to_owned()))
}

/// The expression for the current thread in ADAPTER's language (an `output` event has no thread).
pub fn thread_expr(adapter: &str) -> &'static str {
    match adapter {
        "debugpy" | "python" => "__import__('threading').get_ident()",
        "pwa-node" | "node" | "node-terminal" | "js-debug" => "process.pid",
        _ => "0",
    }
}
