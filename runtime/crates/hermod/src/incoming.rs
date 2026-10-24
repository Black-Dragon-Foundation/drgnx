//! The agent's requests to us, and the handle that answers one.  There is no `terminal/*`: we do not offer it.

use crate::conn::Shared;
use crate::schema::v1::{
    ReadTextFileRequest, ReadTextFileResponse, RequestPermissionRequest, RequestPermissionResponse,
    WriteTextFileRequest, WriteTextFileResponse,
};
use crate::types::Error;
use runstav::jsonrpc::Id;
use serde::Serialize;
use serde_json::json;
use std::marker::PhantomData;
use std::sync::Arc;
use tokio::sync::mpsc::WeakUnboundedSender;
use tokio::sync::watch;

#[allow(clippy::large_enum_variant)] // a short-lived event, handed on at once
pub enum Incoming {
    Permission(
        RequestPermissionRequest,
        Responder<RequestPermissionResponse>,
    ),
    ReadFile(ReadTextFileRequest, Responder<ReadTextFileResponse>),
    WriteFile(WriteTextFileRequest, Responder<WriteTextFileResponse>),
}

/// The answer to one request.  Dropped unanswered while the child lives, it answers "cancelled" (-32800); once
/// the child has exited, [`Responder::respond`] fails with [`Error::Closed`] and [`Responder::is_cancelled`] is true.
pub struct Responder<T> {
    id: Id,
    tx: WeakUnboundedSender<String>,
    closed: watch::Receiver<bool>,
    answered: bool,
    _t: PhantomData<fn(T)>,
}

impl<T: Serialize> Responder<T> {
    pub(crate) fn new(id: Id, tx: WeakUnboundedSender<String>, shared: &Arc<Shared>) -> Self {
        Responder {
            id,
            tx,
            closed: shared.closed.subscribe(),
            answered: false,
            _t: PhantomData,
        }
    }

    /// True once the child has exited: nobody is waiting for an answer.
    pub fn is_cancelled(&self) -> bool {
        *self.closed.borrow()
    }

    /// Resolves when the child has exited.
    pub async fn cancelled(&mut self) {
        let _ = self.closed.wait_for(|c| *c).await;
    }

    pub fn respond(mut self, value: T) -> Result<(), Error> {
        let line = json!({"jsonrpc": "2.0", "id": self.id, "result": value});
        self.send(line.to_string())
    }

    /// Answer with a JSON-RPC error.
    pub fn fail(mut self, code: i64, message: &str) -> Result<(), Error> {
        let line =
            json!({"jsonrpc": "2.0", "id": self.id, "error": {"code": code, "message": message}});
        self.send(line.to_string())
    }

    fn send(&mut self, line: String) -> Result<(), Error> {
        self.answered = true;
        if self.is_cancelled() {
            return Err(Error::Closed);
        }
        self.tx
            .upgrade()
            .ok_or(Error::Closed)?
            .send(line)
            .map_err(|_| Error::Closed)
    }
}

impl<T> Drop for Responder<T> {
    fn drop(&mut self) {
        if self.answered || *self.closed.borrow() {
            return;
        }
        if let Some(tx) = self.tx.upgrade() {
            let line = json!({"jsonrpc": "2.0", "id": self.id, "error": {"code": -32800, "message": "cancelled"}});
            let _ = tx.send(line.to_string());
        }
    }
}
