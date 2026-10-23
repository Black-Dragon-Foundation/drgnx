//! `ratatoskr mcp-bridge` (docs/develop/hub.md, "The MCP bridge"): an agent's stdio MCP server, copied to the hub by
//! [`mimir::bridge::run`], which redials after a hub restart, replays the handshake and never resends a call.
//!
//! - **Inside** (`--socket PATH`): a session's `mcp.sock`, minted by `mcp/session` for one agent; whoever connects is
//!   that agent. No challenge: the first byte is MCP. It reads no environment variable (agents run it with an empty
//!   one), so `DRGNX_AGENT` and the like name nobody.
//! - **Outside** (`--outside --kind KIND [--cwd DIR]`): the hub's main socket, found from the environment the agent
//!   gave it (`runstav::paths::socket_path`, the Lisp client's rule). On each connect the socket's directory must be
//!   trusted (`paths::trusted_dir`: a refusal ends the bridge with status 1 and the Lisp client's text; a missing
//!   directory is no hub yet), the hub's challenge is read, `hello {proto: 1, nonce, client: "mcp-bridge", cwd}` goes
//!   **without a proof** (the bridge never reads the cap, so the connection stays `service`), then `mcp/attach
//!   {kind}`. The hub answers the identity, `ext:KIND:PID-HASH` of the bridge's parent (the agent), and the
//!   connection carries MCP from its next byte. `cwd` is `--cwd` or the bridge's own folder (left out when it is not
//!   an absolute local path).
//!
//! Exit status: 0 when the agent closes stdin, 1 when the hub refuses the bridge or none answers for 10 minutes, 2 for
//! a command line that does not parse.

use crate::cli::{BridgeArgs, BridgeTarget};
use mimir::BoxFuture;
use mimir::bridge::{BridgeEnd, BridgeOpts, Connector, Dial};
use runstav::paths::{self, Env};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};

/// How long an outside bridge's prelude (the challenge, `hello`, `mcp/attach`) may take on one connect.
pub const PRELUDE: Duration = Duration::from_secs(5);

/// The longest hub line the prelude reads.
const MAX_PRELUDE_LINE: u64 = 1 << 20;

/// A session's `mcp.sock`.
pub struct Inside {
    pub socket: PathBuf,
}

impl Connector for Inside {
    type R = OwnedReadHalf;
    type W = OwnedWriteHalf;

    fn connect(&self) -> BoxFuture<'static, Result<(OwnedReadHalf, OwnedWriteHalf), Dial>> {
        let socket = self.socket.clone();
        Box::pin(async move { Ok(UnixStream::connect(&socket).await?.into_split()) })
    }
}

/// The hub's main socket, as an outside agent's bridge.
pub struct Outside {
    pub socket: PathBuf,
    pub kind: String,
    pub cwd: Option<String>,
}

type Prelude = Result<(BufReader<OwnedReadHalf>, OwnedWriteHalf), Dial>;

impl Connector for Outside {
    type R = OwnedReadHalf;
    type W = OwnedWriteHalf;

    fn connect(&self) -> BoxFuture<'static, Result<(OwnedReadHalf, OwnedWriteHalf), Dial>> {
        let socket = self.socket.clone();
        Box::pin(async move {
            trusted(&socket)?;
            Ok(UnixStream::connect(&socket).await?.into_split())
        })
    }

    fn prelude(
        &self,
        r: BufReader<OwnedReadHalf>,
        w: OwnedWriteHalf,
    ) -> BoxFuture<'static, Prelude> {
        let (kind, cwd) = (self.kind.clone(), self.cwd.clone());
        Box::pin(async move {
            match tokio::time::timeout(PRELUDE, attach(r, w, kind, cwd)).await {
                Ok(done) => done,
                Err(_) => Err(Dial::Again(
                    "the hub did not answer the bridge's hello in time".into(),
                )),
            }
        })
    }
}

/// SOCKET's directory trusted and the socket this user's, before anything connects (`client::trusted`, as every
/// client path): not there is no hub yet (dial again); anything else is a refusal that ends the bridge.
fn trusted(socket: &Path) -> Result<(), Dial> {
    let refuse = |e: std::io::Error| {
        if e.kind() == std::io::ErrorKind::NotFound {
            Dial::Again(e.to_string())
        } else {
            Dial::Fatal(e.to_string())
        }
    };
    let dir = crate::client::trusted(socket).map_err(refuse)?;
    paths::owned_in_trusted(&dir, Path::new(socket.file_name().unwrap_or_default())).map_err(refuse)
}

/// The challenge read, `hello` without a proof, `mcp/attach {kind}`: what the reader holds after the answer is MCP.
async fn attach(
    mut r: BufReader<OwnedReadHalf>,
    mut w: OwnedWriteHalf,
    kind: String,
    cwd: Option<String>,
) -> Prelude {
    // the challenge is the first line; its nonce goes into no proof
    while line(&mut r).await?["event"] != "challenge" {}
    let mut hello = json!({"proto": 1, "nonce": runstav::proof::nonce()?, "client": "mcp-bridge"});
    if let Some(cwd) = cwd {
        hello["cwd"] = json!(cwd);
    }
    call(&mut r, &mut w, 1, "hello", hello).await?;
    call(&mut r, &mut w, 2, "mcp/attach", json!({"kind": kind})).await?;
    Ok((r, w))
}

async fn line(r: &mut BufReader<OwnedReadHalf>) -> Result<Value, Dial> {
    let mut text = String::new();
    if (&mut *r)
        .take(MAX_PRELUDE_LINE)
        .read_line(&mut text)
        .await?
        == 0
    {
        return Err(Dial::Again("the hub closed the connection".into()));
    }
    serde_json::from_str(&text)
        .map_err(|e| Dial::Again(format!("the hub sent a line that is not JSON: {e}")))
}

/// METHOD with PARAMS as ID; the hub's refusal ends the bridge (it would refuse the next dial too).
async fn call(
    r: &mut BufReader<OwnedReadHalf>,
    w: &mut OwnedWriteHalf,
    id: u64,
    method: &str,
    params: Value,
) -> Result<Value, Dial> {
    let mut text = json!({"id": id, "method": method, "params": params}).to_string();
    text.push('\n');
    w.write_all(text.as_bytes()).await?;
    loop {
        let v = line(r).await?;
        if v["id"] != id {
            continue;
        }
        if let Some(e) = v.get("error") {
            return Err(Dial::Fatal(format!(
                "the drgnx hub refused {method}: {}: {}",
                e["code"].as_str().unwrap_or("error"),
                e["message"].as_str().unwrap_or("")
            )));
        }
        return Ok(v["result"].clone());
    }
}

/// Is PATH a socket? Else why not.
fn is_socket(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::FileTypeExt;
    match std::fs::metadata(path) {
        Ok(m) if m.file_type().is_socket() => Ok(()),
        Ok(_) => Err(format!("{} is not a socket", path.display())),
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

/// `ratatoskr mcp-bridge`: the exit status.
pub fn main(args: BridgeArgs) -> u8 {
    let defaults = BridgeOpts::default();
    let opts = BridgeOpts {
        backoff: args
            .backoff_ms
            .map_or(defaults.backoff, Duration::from_millis),
        give_up: args
            .give_up_ms
            .map_or(defaults.give_up, Duration::from_millis),
        ..defaults
    };
    // warnings (the hub went away, came back) on stderr, which MCP stdio leaves to the server's log
    let _ = tracing_subscriber::fmt()
        .with_ansi(false)
        .without_time()
        .with_target(false)
        .with_writer(std::io::stderr)
        .with_max_level(tracing::Level::WARN)
        .try_init();
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("ratatoskr mcp-bridge: no async runtime: {e}");
            return 1;
        }
    };
    let (stdin, stdout) = (tokio::io::stdin(), tokio::io::stdout());
    let end = match args.target {
        BridgeTarget::Socket(socket) => {
            if let Err(why) = is_socket(&socket) {
                eprintln!("ratatoskr mcp-bridge: {why}");
                return 1;
            }
            runtime.block_on(mimir::bridge::run(Inside { socket }, stdin, stdout, opts))
        }
        BridgeTarget::Outside { kind, cwd } => {
            let socket = paths::socket_path(&Env::process());
            let cwd = cwd
                .or_else(|| std::env::current_dir().ok())
                .filter(|c| crate::cli::abs_path(c))
                .and_then(|c| c.to_str().map(str::to_owned));
            let conn = Outside { socket, kind, cwd };
            runtime.block_on(mimir::bridge::run(conn, stdin, stdout, opts))
        }
    };
    // stdin's read runs on a blocking thread that cannot be cancelled: never wait for it
    runtime.shutdown_background();
    if let BridgeEnd::GaveUp(why) | BridgeEnd::Fatal(why) = &end {
        eprintln!("ratatoskr mcp-bridge: {why}");
    }
    end.code()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;

    /// A stub hub on DIR/hub-x.sock for one connection: its challenge, then each line it reads is kept and answered
    /// (`hello` with the service class, `mcp/attach` with ANSWER), then `mcp` after the attach answer.
    fn stub(dir: &Path, answer: Value) -> (PathBuf, std::thread::JoinHandle<Vec<Value>>) {
        let socket = dir.join("hub-x.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let hub = std::thread::spawn(move || {
            let (s, _) = listener.accept().unwrap();
            let mut w = s.try_clone().unwrap();
            writeln!(
                w,
                "{}",
                json!({"event": "challenge", "data": {"nonce": "c".repeat(32)}})
            )
            .unwrap();
            let mut seen = Vec::new();
            for line in std::io::BufReader::new(s).lines().map_while(Result::ok) {
                let v: Value = serde_json::from_str(&line).unwrap();
                let reply = match v["method"].as_str() {
                    Some("hello") => json!({"id": v["id"], "result": {"class": "service"}}),
                    Some("mcp/attach") => {
                        let mut a = answer.clone();
                        a["id"] = v["id"].clone();
                        a
                    }
                    _ => json!({"jsonrpc": "2.0", "id": v["id"], "result": "mcp"}),
                };
                writeln!(w, "{reply}").unwrap();
                seen.push(v);
            }
            seen
        });
        (socket, hub)
    }

    fn private_dir() -> tempfile::TempDir {
        let root = tempfile::tempdir().unwrap();
        std::fs::set_permissions(root.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        root
    }

    fn outside(socket: PathBuf) -> Outside {
        Outside {
            socket,
            kind: "codex".into(),
            cwd: Some("/w/proj".into()),
        }
    }

    async fn dial(c: &Outside) -> Prelude {
        let (r, w) = c.connect().await?;
        c.prelude(BufReader::new(r), w).await
    }

    #[tokio::test]
    async fn outside_says_hello_without_a_proof_then_attaches() {
        let root = private_dir();
        let (socket, hub) = stub(
            root.path(),
            json!({"result": {"identity": "ext:codex:7-abcdef"}}),
        );
        let (mut r, mut w) = dial(&outside(socket)).await.expect("attached");
        // the connection is MCP's now
        w.write_all(b"{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"ping\"}\n")
            .await
            .unwrap();
        let mut text = String::new();
        r.read_line(&mut text).await.unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&text).unwrap()["result"],
            "mcp"
        );
        drop((r, w));
        let seen = hub.join().unwrap();
        assert_eq!(seen[0]["method"], "hello");
        let hello = &seen[0]["params"];
        assert_eq!(hello["proto"], 1);
        assert_eq!(hello["client"], "mcp-bridge");
        assert_eq!(hello["cwd"], "/w/proj");
        assert!(
            hello["nonce"].as_str().is_some_and(|n| n.len() == 32),
            "{hello}"
        );
        assert!(
            hello.get("proof").is_none(),
            "no proof: the bridge never reads the cap"
        );
        assert_eq!(seen[1]["method"], "mcp/attach");
        assert_eq!(seen[1]["params"], json!({"kind": "codex"}));
        assert_eq!(seen[2]["method"], "ping");
    }

    #[tokio::test]
    async fn a_refused_attach_ends_it_and_no_hub_dials_again() {
        let root = private_dir();
        let (socket, _hub) = stub(
            root.path(),
            json!({"error": {"code": "not-allowed", "message": "an outside agent needs a parent process"}}),
        );
        let e = dial(&outside(socket)).await.err().expect("refused");
        assert_eq!(
            e,
            Dial::Fatal(
                "the drgnx hub refused mcp/attach: not-allowed: an outside agent needs a parent process".into()
            )
        );
        // no directory yet, or no socket in it: no hub, try again later
        let gone = root.path().join("gone").join("hub-x.sock");
        assert!(matches!(dial(&outside(gone)).await, Err(Dial::Again(_))));
        let none = root.path().join("hub-y.sock");
        assert!(matches!(dial(&outside(none)).await, Err(Dial::Again(_))));
    }

    #[tokio::test]
    async fn an_untrusted_directory_ends_it_before_connecting() {
        let root = private_dir();
        let dir = root.path().join("run");
        std::fs::create_dir(&dir).unwrap();
        let socket = dir.join("hub-x.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        let e = dial(&outside(socket)).await.err().expect("refused");
        let Dial::Fatal(why) = e else {
            panic!("{e:?}");
        };
        assert!(why.contains("is open to other users (mode 755"), "{why}");
        assert!(listener.accept().is_err(), "nothing connected");
    }

    #[test]
    fn the_socket_must_be_a_socket() {
        let root = private_dir();
        let file = root.path().join("mcp.sock");
        std::fs::write(&file, "").unwrap();
        assert!(is_socket(&file).unwrap_err().ends_with("is not a socket"));
        assert!(is_socket(&root.path().join("none")).is_err());
        let socket = root.path().join("real.sock");
        let _l = UnixListener::bind(&socket).unwrap();
        assert_eq!(is_socket(&socket), Ok(()));
    }
}
