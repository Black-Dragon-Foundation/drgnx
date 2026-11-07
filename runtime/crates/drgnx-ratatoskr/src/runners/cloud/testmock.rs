//! `ratatoskr-mock cloud` for the cloud rows (test builds only): one mock with no containers, modelling the fixture
//! policy for hub `hub-1`, and AWS and GCP clients of it whose credentials come from a command that prints fake ones
//! (built in pieces).

use super::aws::{Aws, AwsCfg};
use super::creds::{Resolver, Source};
use super::gcp::{Gcp, GcpCfg};
use serde_json::Value;
use std::sync::Arc;

pub const HUB: &str = "hub-1";

pub struct Mock {
    child: std::process::Child,
    pub base: String,
}

impl Drop for Mock {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Mock {
    pub fn start() -> Mock {
        use std::io::BufRead;
        let mut child = std::process::Command::new(crate::embed::tests::mock_binary())
            .args([
                "cloud",
                "--listen",
                "127.0.0.1:0",
                "--podman-remote",
                "none",
            ])
            .args(["--prefix", "t", "--run", "r1", "--hub", HUB])
            .arg("--parent")
            .arg(std::process::id().to_string())
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        std::io::BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        let port: u16 = line
            .trim()
            .strip_prefix("MOCK-CLOUD-PORT ")
            .unwrap()
            .parse()
            .unwrap();
        Mock {
            child,
            base: format!("http://127.0.0.1:{port}/"),
        }
    }

    /// An AWS client of the mock in us-east-1 for hub `hub-1`.
    pub fn aws(&self) -> Aws {
        let id = ["AS", "IA", "FAKEFAKEFAKE0004"].concat();
        let secret = ["fake", "/secret", "0004"].concat();
        let json =
            format!("{{\"Version\":1,\"AccessKeyId\":\"{id}\",\"SecretAccessKey\":\"{secret}\"}}");
        let creds = Resolver::new(
            Source::Command(vec!["printf".into(), "%s".into(), json]),
            None,
        );
        let cfg = AwsCfg {
            region: "us-east-1".into(),
            hub_id: HUB.into(),
            probe: None,
        };
        Aws::with_endpoint(cfg, Arc::new(creds), &self.base).unwrap()
    }

    /// A GCP client of the mock in project `p1`, zone `us-central1-a`, for hub `hub-1`, with an 8 h lifetime; its token
    /// comes from a command that prints a fake one.
    pub fn gcp(&self) -> Gcp {
        let token = ["ya29", ".fake-token-0005"].concat();
        let creds = Resolver::new(
            Source::Command(vec!["printf".into(), "%s".into(), token]),
            None,
        );
        let cfg = GcpCfg {
            project: "p1".into(),
            zone: "us-central1-a".into(),
            hub_id: HUB.into(),
            lifetime: std::time::Duration::from_secs(8 * 3600),
        };
        Gcp::with_endpoint(cfg, Arc::new(creds), &self.base).unwrap()
    }

    async fn http(&self, method: &str, path: &str, body: &str) -> String {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let addr = self
            .base
            .trim_start_matches("http://")
            .trim_end_matches('/');
        let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
        let req = format!(
            "{method} {path} HTTP/1.1\r\nHost: mock\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        );
        s.write_all(req.as_bytes()).await.unwrap();
        let mut out = String::new();
        s.read_to_string(&mut out).await.unwrap();
        assert!(out.starts_with("HTTP/1.1 200"), "{method} {path}: {out}");
        out.split_once("\r\n\r\n")
            .map(|(_, b)| b.to_string())
            .unwrap_or_default()
    }

    /// A knob: `POST /__mock/NAME` with BODY.
    pub async fn knob(&self, name: &str, body: Value) {
        self.http("POST", &format!("/__mock/{name}"), &body.to_string())
            .await;
    }

    /// `GET /__mock/resources`: what the mock account holds (no credentials asked).
    pub async fn resources(&self) -> Value {
        serde_json::from_str(&self.http("GET", "/__mock/resources", "").await).unwrap()
    }

    /// The state the mock gives instance ID (`running`, `terminated`, …).
    pub async fn state_of(&self, id: &str) -> String {
        let r = self.resources().await;
        r["instances"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["id"] == id)
            .and_then(|i| i["state"].as_str())
            .unwrap_or("absent")
            .to_string()
    }
}
