//! The tests' setup: the real editor behind the API, on the standards' crates, shared by the hosts.

use std::sync::{Arc, Mutex};

use bod::{ArgSpec, Command, CommandId, Exposure, Origin, SourceLoc, handler};
use sattr::Limits;
use sattr::editor::Editor;
use serde_json::json;

pub const LIMITS: Limits = Limits {
    steps: 1_000_000,
    memory_bytes: 8 << 20,
    ticks: 2_000,
    table_elements: 10_000,
    max_list: 256,
};

/// An editor with a few settings and commands, behind the lock the hosts share.
pub fn editor() -> (Arc<Mutex<Editor>>, Arc<saman::Executor>) {
    let ex = Arc::new(saman::Executor::new(1).expect("a pool"));
    let mut e = Editor::new(Arc::clone(&ex), None);
    e.settings
        .define("editor.theme", skipan::Kind::Str, json!("light"))
        .expect("defines");
    for (id, exposure) in [
        ("buffer.save", Exposure::Palette),
        ("agent.echo", Exposure::Agent),
        ("ext.ping", Exposure::Extension),
    ] {
        e.registry
            .register(
                Command {
                    id: CommandId::from(id),
                    title: "A title".to_string(),
                    doc: "A doc.".to_string(),
                    args: ArgSpec::NONE,
                    source: SourceLoc {
                        file: file!().to_string(),
                        line: line!(),
                    },
                    exposure,
                },
                handler(|_, _| Ok(json!("ran"))),
            )
            .expect("registers");
    }
    (Arc::new(Mutex::new(e)), ex)
}

pub fn user() -> Origin {
    Origin::User
}
