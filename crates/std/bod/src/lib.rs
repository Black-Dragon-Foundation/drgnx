//! bod (*boð*, a command, a bidding): the one command registry (docs/develop/standards/commands.md).
//!
//! Every action of the editor is a [`Command`]: an id, a title, a doc, its arguments, where it is defined and who may
//! run it ([`Exposure`]). Keys, the palette, the cheat sheet and the agents' tools are all read from the registry:
//! nothing keeps a second list. [`command!`] registers one at link time; [`Registry::register`] one at run time (an
//! extension). [`Registry::advise`] wraps a command's handler, and removes the wrapper again.
//!
//! Agents' tools are [`tool_specs`]: a plain description (name, text, input schema) that the agent runtime converts to
//! its own tool type, so this crate depends on no hub crate.

use std::collections::BTreeMap;
use std::fmt;
use std::sync::Arc;

use serde_json::{Value, json};

#[doc(hidden)]
pub use inventory;

/// A command's id, as keys, the palette and agents name it: `buffer.save`.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct CommandId(pub String);

impl From<&str> for CommandId {
    fn from(id: &str) -> CommandId {
        CommandId(id.to_string())
    }
}

impl fmt::Display for CommandId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// Who may run a command.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Exposure {
    /// The palette lists it; keys and a user may run it.
    Palette,
    /// An agent may run it too: it is an MCP tool.
    Agent,
    /// Only a key reaches it: the palette does not list it.
    KeyOnly,
    /// An extension may run it too, through the extension API (`commands.run`). Agents and the palette do not.
    Extension,
}

/// Who asks for a command (and, in spurn, who asks a question).
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Origin {
    User,
    Agent(String),
    Extension(String),
}

/// What kind of value an argument takes.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum ArgKind {
    #[default]
    String,
    Number,
    Bool,
    Path,
    /// one of a fixed set the argument's doc names
    Choice,
}

impl ArgKind {
    /// The JSON schema type of the argument.
    pub fn json_type(self) -> &'static str {
        match self {
            ArgKind::String | ArgKind::Path | ArgKind::Choice => "string",
            ArgKind::Number => "number",
            ArgKind::Bool => "boolean",
        }
    }
}

/// One argument of a command.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Arg {
    pub name: String,
    pub kind: ArgKind,
    pub required: bool,
    pub doc: String,
}

/// The arguments of a command. The values are JSON.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct ArgSpec {
    pub args: Vec<Arg>,
}

impl ArgSpec {
    pub const NONE: ArgSpec = ArgSpec { args: Vec::new() };

    /// An argument list from `(name, doc)` pairs: each a required string.
    pub fn of(args: &[(&str, &str)]) -> ArgSpec {
        ArgSpec {
            args: args
                .iter()
                .map(|(n, d)| Arg {
                    name: (*n).to_string(),
                    kind: ArgKind::String,
                    required: true,
                    doc: (*d).to_string(),
                })
                .collect(),
        }
    }
}

/// Where a command is defined: find-the-source.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct SourceLoc {
    pub file: String,
    pub line: u32,
}

/// One command's description.
#[derive(Clone, Debug)]
pub struct Command {
    pub id: CommandId,
    pub title: String,
    pub doc: String,
    pub args: ArgSpec,
    pub source: SourceLoc,
    pub exposure: Exposure,
}

/// What a command runs in: who is asking.
#[derive(Clone, Debug)]
pub struct Cx {
    /// Who started the call: the user, an agent, an extension.
    pub origin: Origin,
    /// The extension the call goes through, when it comes through one: the origin stays the one that started the
    /// chain (an agent that runs an extension that runs a command is still the agent's).
    pub via: Option<String>,
}

impl Cx {
    pub fn user() -> Cx {
        Cx {
            origin: Origin::User,
            via: None,
        }
    }

    pub fn agent(id: impl Into<String>) -> Cx {
        Cx {
            origin: Origin::Agent(id.into()),
            via: None,
        }
    }

    /// A call that an extension makes for ORIGIN (whoever started the chain).
    pub fn through_extension(origin: Origin, extension: impl Into<String>) -> Cx {
        Cx {
            origin,
            via: Some(extension.into()),
        }
    }
}

/// A command's code.
pub type Handler = Arc<dyn Fn(&mut Cx, Value) -> villa::Result<Value> + Send + Sync>;

/// What a piece of advice calls to continue: the rest of the chain.
pub type Next<'a> = &'a dyn Fn(&mut Cx, Value) -> villa::Result<Value>;

/// A wrapper around a command: it gets the arguments and the rest of the chain.
pub type Advice = Arc<dyn Fn(&mut Cx, Value, Next<'_>) -> villa::Result<Value> + Send + Sync>;

/// A handler made from a closure.
pub fn handler(
    f: impl Fn(&mut Cx, Value) -> villa::Result<Value> + Send + Sync + 'static,
) -> Handler {
    Arc::new(f)
}

/// A piece of advice made from a closure.
pub fn advice(
    f: impl Fn(&mut Cx, Value, Next<'_>) -> villa::Result<Value> + Send + Sync + 'static,
) -> Advice {
    Arc::new(f)
}

/// What [`command!`] submits: a link-time registration.
pub struct Registration {
    pub command: fn() -> Command,
    pub handler: fn() -> Handler,
}

inventory::collect!(Registration);

/// Register a command at link time:
///
/// ```ignore
/// bod::command! {
///     id: "buffer.save",
///     title: "Save buffer",
///     doc: "Write the buffer to its file.",
///     args: bod::ArgSpec::NONE,
///     exposure: bod::Exposure::Palette,
///     handler: |_cx, _args| Ok(serde_json::Value::Null),
/// }
/// ```
///
/// The doc must not be empty: the `command-has-doc` scan rule rejects an invocation without one.
#[macro_export]
macro_rules! command {
    (
        id: $id:literal,
        title: $title:literal,
        doc: $doc:literal,
        args: $args:expr,
        exposure: $exposure:expr,
        handler: $handler:expr $(,)?
    ) => {
        $crate::inventory::submit! {
            $crate::Registration {
                command: || $crate::Command {
                    id: $crate::CommandId::from($id),
                    title: $title.to_string(),
                    doc: $doc.to_string(),
                    args: $args,
                    source: $crate::SourceLoc { file: file!().to_string(), line: line!() },
                    exposure: $exposure,
                },
                handler: || $crate::handler($handler),
            }
        }
    };
}

struct Entry {
    command: Command,
    handler: Handler,
    advice: Vec<(u64, Advice)>,
}

/// The registry. Registering and advising need `&mut`; running does not.
#[derive(Default)]
pub struct Registry {
    entries: BTreeMap<String, Entry>,
    next_advice: u64,
}

/// A piece of advice, to take it off again.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct AdviceId(CommandId, u64);

impl Registry {
    pub fn new() -> Registry {
        Registry::default()
    }

    /// A registry holding every command [`command!`] registered in the program.
    pub fn linked() -> villa::Result<Registry> {
        let mut r = Registry::new();
        for reg in inventory::iter::<Registration> {
            r.register((reg.command)(), (reg.handler)())?;
        }
        Ok(r)
    }

    /// Add a command. A second command with the same id is a [`villa::Kind::Conflict`], naming where the first is.
    pub fn register(&mut self, command: Command, handler: Handler) -> villa::Result<()> {
        if command.title.trim().is_empty() || command.doc.trim().is_empty() {
            return Err(villa::Error::invalid("A command needs a title and a doc.")
                .with_detail(command.id.to_string()));
        }
        if let Some(old) = self.entries.get(&command.id.0) {
            return Err(villa::Error::conflict(format!(
                "The command `{}` already exists.",
                command.id
            ))
            .with_detail(format!(
                "first defined at {}:{}, again at {}:{}",
                old.command.source.file,
                old.command.source.line,
                command.source.file,
                command.source.line
            )));
        }
        self.entries.insert(
            command.id.0.clone(),
            Entry {
                command,
                handler,
                advice: Vec::new(),
            },
        );
        Ok(())
    }

    fn entry(&self, id: &str) -> villa::Result<&Entry> {
        self.entries
            .get(id)
            .ok_or_else(|| villa::Error::not_found(format!("There is no command `{id}`.")))
    }

    /// Run a command: the advice outermost first (the last added is the outermost), then the handler. An agent runs only
    /// a command exposed to agents.
    pub fn run(&self, id: &str, args: Value, cx: &mut Cx) -> villa::Result<Value> {
        let e = self.entry(id)?;
        if matches!(cx.origin, Origin::Agent(_)) && e.command.exposure != Exposure::Agent {
            return Err(villa::Error::refused(format!(
                "The command `{id}` is not open to agents."
            )));
        }
        // an extension runs only what is exposed to extensions, whoever started the chain: an agent that has an
        // extension run a command must pass both doors, and no exposure passes both
        if cx.via.is_some() && e.command.exposure != Exposure::Extension {
            return Err(villa::Error::refused(format!(
                "The command `{id}` is not open to extensions."
            )));
        }
        fn call(e: &Entry, upto: usize, cx: &mut Cx, args: Value) -> villa::Result<Value> {
            if upto == 0 {
                return (e.handler)(cx, args);
            }
            let (_, around) = &e.advice[upto - 1];
            around(cx, args, &|cx, args| call(e, upto - 1, cx, args))
        }
        call(e, e.advice.len(), cx, args)
    }

    /// Wrap command ID's handler. The wrapper is outside every earlier one.
    pub fn advise(&mut self, id: &str, around: Advice) -> villa::Result<AdviceId> {
        self.entry(id)?;
        self.next_advice += 1;
        let n = self.next_advice;
        let Some(e) = self.entries.get_mut(id) else {
            return Err(villa::Error::not_found(format!(
                "There is no command `{id}`."
            )));
        };
        e.advice.push((n, around));
        Ok(AdviceId(e.command.id.clone(), n))
    }

    /// Take a piece of advice off again; the command runs as before it.
    pub fn unadvise(&mut self, advice: AdviceId) -> villa::Result<()> {
        let Some(e) = self.entries.get_mut(&advice.0.0) else {
            return Err(villa::Error::not_found(format!(
                "There is no command `{}`.",
                advice.0
            )));
        };
        let before = e.advice.len();
        e.advice.retain(|(n, _)| *n != advice.1);
        if e.advice.len() == before {
            return Err(villa::Error::not_found(
                "That advice is not on the command.",
            ));
        }
        Ok(())
    }

    /// Where a command is defined.
    pub fn find_source(&self, id: &str) -> villa::Result<SourceLoc> {
        Ok(self.entry(id)?.command.source.clone())
    }

    pub fn get(&self, id: &str) -> Option<&Command> {
        self.entries.get(id).map(|e| &e.command)
    }

    /// Every command, by id.
    pub fn list(&self) -> impl Iterator<Item = &Command> {
        self.entries.values().map(|e| &e.command)
    }

    /// What the palette lists: the commands exposed to the palette or to agents (not the key-only or extension ones).
    pub fn palette(&self) -> Vec<&Command> {
        self.list()
            .filter(|c| !matches!(c.exposure, Exposure::KeyOnly | Exposure::Extension))
            .collect()
    }
}

/// An agent's tool, described without any runtime's type.
#[derive(Clone, PartialEq, Debug)]
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    /// A JSON schema: an object with one property per argument.
    pub input_schema: Value,
}

/// The tools for the commands exposed to agents.
pub fn tool_specs(registry: &Registry) -> Vec<ToolSpec> {
    registry
        .list()
        .filter(|c| c.exposure == Exposure::Agent)
        .map(|c| {
            let props: serde_json::Map<String, Value> = c
                .args
                .args
                .iter()
                .map(|a| {
                    (
                        a.name.clone(),
                        json!({ "type": a.kind.json_type(), "description": a.doc }),
                    )
                })
                .collect();
            ToolSpec {
                name: c.id.0.clone(),
                description: format!("{}: {}", c.title, c.doc),
                input_schema: json!({
                    "type": "object",
                    "properties": props,
                    "required": c.args.args.iter().filter(|a| a.required).map(|a| a.name.as_str()).collect::<Vec<_>>(),
                }),
            }
        })
        .collect()
}
