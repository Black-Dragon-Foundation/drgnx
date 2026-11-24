//! `vor-mock SCRIPT.json`: the mock debug adapter on stdio (`vor::mock`), for ERT. Exits 1 with the reason on stderr
//! when the script fails.
use vor::mock::{Mock, Script};

/// LINE on stderr, then exit with CODE. A stderr that is gone leaves nobody to tell.
fn die(code: i32, line: &str) -> ! {
    drop(annall::cli_err(line));
    std::process::exit(code)
}

fn main() {
    match saman::Executor::new(1) {
        Ok(rt) => rt.block_on(run()),
        Err(e) => die(1, &format!("vor-mock: {e}")),
    }
}

async fn run() {
    let Some(path) = std::env::args().nth(1) else {
        die(2, "usage: vor-mock SCRIPT.json");
    };
    let script: Script = match std::fs::read(&path)
        .map_err(|e| e.to_string())
        .and_then(|b| serde_json::from_slice(&b).map_err(|e| e.to_string()))
    {
        Ok(s) => s,
        Err(e) => {
            die(2, &format!("vor-mock: {path}: {e}"));
        }
    };
    if let Err(e) = Mock::start(script, tokio::io::stdin(), tokio::io::stdout())
        .finish()
        .await
    {
        die(1, &format!("vor-mock: {e}"));
    }
}
