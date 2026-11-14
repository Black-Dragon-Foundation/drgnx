//! `vor-mock SCRIPT.json`: the mock debug adapter on stdio (`vor::mock`), for ERT. Exits 1 with the reason on stderr
//! when the script fails.
use vor::mock::{Mock, Script};

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let Some(path) = std::env::args().nth(1) else {
        eprintln!("usage: vor-mock SCRIPT.json");
        std::process::exit(2);
    };
    let script: Script = match std::fs::read(&path)
        .map_err(|e| e.to_string())
        .and_then(|b| serde_json::from_slice(&b).map_err(|e| e.to_string()))
    {
        Ok(s) => s,
        Err(e) => {
            eprintln!("vor-mock: {path}: {e}");
            std::process::exit(2);
        }
    };
    if let Err(e) = Mock::start(script, tokio::io::stdin(), tokio::io::stdout())
        .finish()
        .await
    {
        eprintln!("vor-mock: {e}");
        std::process::exit(1);
    }
}
