//! The tools a server serves (Task 2 fills this module; the trait's signature is fixed at Task 0).

use std::future::Future;
use std::pin::Pin;

use serde_json::Value;

/// A boxed, sendable future (no `futures` crate in the workspace).
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// One MCP tool, called with the server's context.
pub trait Tool<Ctx>: Send + Sync {
    /// 1–128 characters of `A-Za-z0-9_-.` (MCP tool-name guidance).
    fn name(&self) -> &'static str;
    fn description(&self) -> &'static str;
    /// From schemars; unknown keys denied.
    fn input_schema(&self) -> Value;
    fn output_schema(&self) -> Option<Value> {
        None
    }
    fn call<'a>(&'a self, ctx: &'a Ctx, args: Value) -> BoxFuture<'a, ToolResult>;
}

/// What a tool's call ends with.
pub enum ToolResult {
    Ok {
        text: String,
        structured: Option<Value>,
    },
    Err(String),
}
