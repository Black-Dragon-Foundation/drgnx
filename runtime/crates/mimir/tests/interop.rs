//! rmcp's client against mimir's server at every protocol version (design §10): the `initialize` handshake at each
//! legacy version, `server/discover` at 2026-07-28, and the client's automatic probe. Each lists the tools, calls
//! `echo`, gets a bad argument back as a tool error with its path, and an unknown tool as a protocol error.

#![cfg(unix)]

use std::sync::Arc;
use std::time::Duration;

use mimir::{ArgsError, BoxFuture, End, Limits, ServerInfo, Tool, ToolResult, typed};
use rmcp::model::{
    CallToolRequestParams, ClientCapabilities, ClientConfig, Implementation, ProtocolVersion,
};
use rmcp::{ClientLifecycleMode, ClientServiceExt};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize, JsonSchema)]
struct EchoArgs {
    text: String,
}

struct Echo;

impl Tool<()> for Echo {
    fn name(&self) -> &'static str {
        "echo"
    }
    fn description(&self) -> &'static str {
        "Say TEXT back."
    }
    fn input_schema(&self) -> Value {
        typed::<EchoArgs>().schema()
    }
    fn check(&self, args: &Value) -> Result<(), ArgsError> {
        typed::<EchoArgs>().check(args)
    }
    fn call<'a>(&'a self, _: &'a (), args: Value) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            match typed::<EchoArgs>().decode(&args) {
                Ok(a) => ToolResult::Ok {
                    text: a.text,
                    structured: None,
                },
                Err(e) => ToolResult::Err(e.to_string()),
            }
        })
    }
}

fn args(v: Value) -> serde_json::Map<String, Value> {
    v.as_object().expect("an object").clone()
}

/// One client over a Unix socket pair, started with LIFECYCLE (its `initialize` at VERSION); the server must agree
/// on EXPECT.
async fn one(lifecycle: ClientLifecycleMode, version: ProtocolVersion, expect: ProtocolVersion) {
    let case = format!("{lifecycle:?} at {version}");
    let (client, server) = tokio::net::UnixStream::pair().expect("a socket pair");
    let (sr, sw) = server.into_split();
    let tools: Vec<Box<dyn Tool<()>>> = vec![Box::new(Echo)];
    let serving = tokio::spawn(mimir::serve(
        Arc::new(()),
        Arc::from(tools),
        ServerInfo::default(),
        sr,
        sw,
        Limits::default(),
    ));

    let config = ClientConfig::new(
        ClientCapabilities::default(),
        Implementation::new("interop", "0"),
    )
    .with_protocol_version(version);
    let (cr, cw) = client.into_split();
    let client = config
        .serve_with_lifecycle((cr, cw), lifecycle)
        .await
        .unwrap_or_else(|e| panic!("{case}: the client starts: {e}"));
    let info = client.peer_info().expect("the server's info");
    assert_eq!(info.protocol_version, expect, "{case}");
    assert_eq!(
        info.server_info.as_ref().map(|i| i.name.as_str()),
        Some("drgnx"),
        "{case}"
    );

    let listed = client.list_all_tools().await.expect("tools/list");
    let names: Vec<&str> = listed.iter().map(|t| t.name.as_ref()).collect();
    assert_eq!(names, ["echo"], "{case}");

    let ok = client
        .call_tool(CallToolRequestParams::new("echo").with_arguments(args(json!({"text": "hi"}))))
        .await
        .expect("tools/call");
    assert_ne!(ok.is_error, Some(true), "{case}");
    assert_eq!(
        ok.content
            .first()
            .and_then(|c| c.as_text())
            .map(|t| t.text.as_str()),
        Some("hi"),
        "{case}"
    );

    let bad = client
        .call_tool(CallToolRequestParams::new("echo").with_arguments(args(json!({"text": 3}))))
        .await
        .expect("a bad argument is a result, not a protocol error");
    assert_eq!(bad.is_error, Some(true), "{case}");
    let text = bad
        .content
        .first()
        .and_then(|c| c.as_text())
        .map(|t| t.text.clone());
    assert!(
        text.as_deref().is_some_and(|t| t.starts_with("text: ")),
        "{case}: {text:?}"
    );
    let path = bad
        .meta
        .as_ref()
        .and_then(|m| m.get("dev.drgnx/error"))
        .and_then(|e| e.get("path"))
        .cloned();
    assert_eq!(path, Some(json!("text")), "{case}");

    let unknown = client
        .call_tool(CallToolRequestParams::new("nope").with_arguments(args(json!({}))))
        .await;
    assert!(unknown.is_err(), "{case}: an unknown tool is -32602");

    client.cancel().await.expect("the client stops");
    let end = tokio::time::timeout(Duration::from_secs(10), serving)
        .await
        .unwrap_or_else(|_| panic!("{case}: the server ends when the client goes"))
        .expect("the server does not panic");
    assert_eq!(end, End::ClientClosed, "{case}");
}

#[tokio::test]
async fn rmcp_client_per_version() {
    for v in [
        ProtocolVersion::V_2024_11_05,
        ProtocolVersion::V_2025_03_26,
        ProtocolVersion::V_2025_06_18,
        ProtocolVersion::V_2025_11_25,
    ] {
        // InitializeRequestParams defaults to LATEST (2026-07-28), so the legacy cases set their version
        one(ClientLifecycleMode::Initialize, v.clone(), v).await;
    }
    one(
        ClientLifecycleMode::Discover {
            preferred_versions: vec![ProtocolVersion::V_2026_07_28],
        },
        ProtocolVersion::V_2025_11_25,
        ProtocolVersion::V_2026_07_28,
    )
    .await;
    one(
        ClientLifecycleMode::Auto {
            preferred_versions: vec![ProtocolVersion::V_2026_07_28],
            legacy_version: Some(ProtocolVersion::V_2025_06_18),
        },
        ProtocolVersion::V_2025_06_18,
        ProtocolVersion::V_2026_07_28,
    )
    .await;
}
