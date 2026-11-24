//! The editor's side of the API: the generated `Api` implemented once, on the standards' crates. Both hosts call it,
//! and it decides on the [`Caller`] of each call:
//!
//! - commands: an extension's commands live in `bod::Registry` as `ext/<extension>/<id>`; an extension runs only
//!   commands exposed to extensions, and the origin that started the chain stays;
//! - keys: an extension binds no reserved key, shadows no prefix, and binds only its own commands or ones exposed to
//!   extensions;
//! - settings: an extension sets the scoped levels only, through `skipan::Settings::set_by_extension`, and is told the
//!   level of a value, never the file it came from;
//! - ask: a question has a timeout of at most five minutes, is never waited for, and its answer, or its failure, is
//!   delivered later;
//! - notices: keys and ids belong to the extension that posted them, and each extension may hold only a few.

use std::collections::BTreeMap;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use serde_json::Value;

use crate::Caller;
use crate::generated::drgnx_api_v0_1_0 as api;
use api::commands::{ArgKind, ArgSpec, CommandSpec, Exposure};
use api::entry::AnsweredHow;
use api::types::{Error, ErrorKind};

/// The longest an extension's question waits for the user.
pub const MAX_QUESTION_MS: u32 = 300_000;
/// How many notices and unanswered questions one extension may hold at once.
pub const MAX_PER_EXTENSION: usize = 20;

struct Pending {
    extension: String,
    id: u64,
    task: saman::Task<spurn::Answer>,
}

/// An answer to deliver to the extension that asked (through its `answered`).
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Delivery {
    pub extension: String,
    pub question: u64,
    pub choice: String,
    pub how: AnsweredHow,
}

/// An extension's command that something ran: the host calls the extension's `run` with `id`.
#[derive(Clone, PartialEq, Debug)]
pub struct Invocation {
    pub extension: String,
    pub id: String,
    pub args: Value,
}

/// The action of a key-clash notice.
pub const REBIND_ACTION: &str = "bind-another-key";

/// What asks the user for a chord (the UI's prompt): the command it is for; none when they decline.
pub trait ChordPrompt {
    fn chord(&self, command: &str) -> Option<String>;
}

pub struct Editor {
    pub settings: skipan::Settings,
    pub registry: bod::Registry,
    pub keymap: lykill::Keymap,
    pub notices: tidindi::Notices,
    ask: spurn::Ask,
    questions: Vec<Pending>,
    pub next_question: u64,
    owners: BTreeMap<u64, String>,
    /// The notices that offer to rebind a wanted binding: the notice, its extension's command and the chord it asked for.
    rebinds: BTreeMap<u64, (String, Vec<lykill::KeyEvent>)>,
    invocations: Arc<Mutex<Vec<Invocation>>>,
}

fn err(kind: ErrorKind, message: &str) -> Error {
    Error {
        kind,
        message: message.to_string(),
    }
}

fn kind(k: villa::Kind) -> ErrorKind {
    match k {
        villa::Kind::NotFound => ErrorKind::NotFound,
        villa::Kind::Conflict => ErrorKind::Conflict,
        villa::Kind::Unavailable | villa::Kind::Io | villa::Kind::Timeout => ErrorKind::Unavailable,
        villa::Kind::Refused => ErrorKind::Refused,
        villa::Kind::Invalid => ErrorKind::Invalid,
        villa::Kind::Cancelled => ErrorKind::Cancelled,
        _ => ErrorKind::Internal,
    }
}

/// A villa error as the API's: its kind, and the sentence the user would read (never its detail).
fn fail(e: villa::Error) -> Error {
    Error {
        kind: kind(e.kind()),
        message: e.message().to_string(),
    }
}

fn exposure_of(e: Exposure) -> bod::Exposure {
    match e {
        Exposure::Palette => bod::Exposure::Palette,
        Exposure::Agent => bod::Exposure::Agent,
        Exposure::Extension => bod::Exposure::Extension,
        Exposure::KeyOnly => bod::Exposure::KeyOnly,
    }
}

fn exposure_to(e: bod::Exposure) -> Exposure {
    match e {
        bod::Exposure::Palette => Exposure::Palette,
        bod::Exposure::Agent => Exposure::Agent,
        bod::Exposure::Extension => Exposure::Extension,
        bod::Exposure::KeyOnly => Exposure::KeyOnly,
    }
}

fn kind_of(k: ArgKind) -> bod::ArgKind {
    match k {
        ArgKind::String => bod::ArgKind::String,
        ArgKind::Number => bod::ArgKind::Number,
        ArgKind::Bool => bod::ArgKind::Bool,
        ArgKind::Path => bod::ArgKind::Path,
        ArgKind::Choice => bod::ArgKind::Choice,
    }
}

fn kind_to(k: bod::ArgKind) -> ArgKind {
    match k {
        bod::ArgKind::String => ArgKind::String,
        bod::ArgKind::Number => ArgKind::Number,
        bod::ArgKind::Bool => ArgKind::Bool,
        bod::ArgKind::Path => ArgKind::Path,
        bod::ArgKind::Choice => ArgKind::Choice,
    }
}

/// The arguments as the WIT spells them, as the registry holds them.
fn parse_args(specs: &[ArgSpec]) -> Result<bod::ArgSpec, Error> {
    let mut args = Vec::new();
    for a in specs {
        if a.name.trim().is_empty() {
            return Err(err(ErrorKind::Invalid, "An argument needs a name."));
        }
        args.push(bod::Arg {
            name: a.name.clone(),
            kind: kind_of(a.kind),
            required: a.required,
            doc: a.doc.clone(),
        });
    }
    Ok(bod::ArgSpec { args })
}

impl Editor {
    /// An editor whose questions are asked on EXECUTOR, answered by PRESENTER (none: a headless run, which answers every
    /// question's default at once).
    pub fn new(
        executor: Arc<saman::Executor>,
        presenter: Option<Arc<dyn spurn::Presenter>>,
    ) -> Editor {
        let ask = match presenter {
            Some(p) => spurn::Ask::interactive(executor, p),
            None => spurn::Ask::headless(executor),
        };
        Editor {
            settings: skipan::Settings::new(),
            registry: bod::Registry::new(),
            keymap: lykill::Keymap::new(),
            notices: tidindi::Notices::new(),
            ask,
            questions: Vec::new(),
            next_question: 0,
            owners: BTreeMap::new(),
            rebinds: BTreeMap::new(),
            invocations: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Lay a key profile over the keymap (the user's, a later one). An extension's binding that would now shadow a
    /// prefix is dropped, and the user is told in a notice that offers another key.
    pub fn layer_profile(&mut self, profile: &lykill::Profile) {
        for d in self.keymap.layer(profile) {
            let body = format!(
                "The extension `{}` bound `{}`, which is the start of a chord in the profile `{}`.",
                d.extension, d.command, profile.name
            );
            self.offer_rebind(
                "A key binding was dropped",
                &d.extension,
                &d.command,
                d.chord,
                body,
            );
        }
    }

    /// A notice about a binding an extension wanted and did not get, with the action that lets the user choose another key.
    fn offer_rebind(
        &mut self,
        title: &str,
        extension: &str,
        command: &str,
        chord: Vec<lykill::KeyEvent>,
        body: String,
    ) {
        let id = self.notices.post(tidindi::Notice {
            level: tidindi::Level::Warning,
            title: title.to_string(),
            body,
            actions: vec![tidindi::Action {
                id: REBIND_ACTION.to_string(),
                label: "Bind to another key…".to_string(),
            }],
            key: Some(tidindi::DedupTag(format!(
                "key-clash:{extension}:{command}:{chord:?}"
            ))),
        });
        self.rebinds.insert(id.0, (command.to_string(), chord));
    }

    /// The user invoked an action of a notice. `bind-another-key` asks CHORDS for a chord (a prompt is allowed: the user
    /// asked for it) and writes the choice to the user's own level, never to the extension. The notice goes when it is done.
    pub fn run_notice_action(
        &mut self,
        notice: tidindi::NoticeId,
        action: &str,
        chords: &dyn ChordPrompt,
    ) -> villa::Result<()> {
        if action != REBIND_ACTION {
            return Err(villa::Error::not_found("The notice has no such action."));
        }
        let Some((command, from)) = self.rebinds.get(&notice.0).cloned() else {
            return Err(villa::Error::not_found("The notice offers no rebinding."));
        };
        let Some(to) = chords.chord(&command) else {
            return Ok(());
        };
        self.keymap.rebind_by_user(&command, &from, &to)?;
        self.rebinds.remove(&notice.0);
        self.notices.dismiss(notice)
    }

    /// The commands of extensions that were run, for the host to hand to each extension's `run`.
    pub fn take_invocations(&mut self) -> Vec<Invocation> {
        std::mem::take(&mut *saman::lock(&self.invocations))
    }

    /// The answers that have come in, and the questions that failed, to deliver to the extensions that asked: an
    /// extension always hears back. It never waits.
    pub fn poll_answers(&mut self) -> Vec<Delivery> {
        let mut cx = Context::from_waker(Waker::noop());
        let mut out = Vec::new();
        self.questions
            .retain_mut(|p| match Pin::new(&mut p.task).poll(&mut cx) {
                Poll::Pending => true,
                Poll::Ready(r) => {
                    let (choice, how) = match r {
                        Ok(a) => (
                            a.choice,
                            match a.by {
                                spurn::AnswerBy::User => AnsweredHow::User,
                                spurn::AnswerBy::Default => AnsweredHow::Default,
                                spurn::AnswerBy::Timeout => AnsweredHow::Timeout,
                            },
                        ),
                        Err(_) => (String::new(), AnsweredHow::Cancelled),
                    };
                    out.push(Delivery {
                        extension: p.extension.clone(),
                        question: p.id,
                        choice,
                        how,
                    });
                    false
                }
            });
        out
    }

    fn live_notices(&mut self, extension: &str) -> usize {
        let notices = &self.notices;
        self.owners
            .retain(|id, _| notices.get(tidindi::NoticeId(*id)).is_some());
        self.owners.values().filter(|e| *e == extension).count()
    }
}

impl api::types::Api for Editor {}
impl api::buffers::Api for Editor {}
impl api::views::Api for Editor {}

impl api::commands::Api for Editor {
    fn register(&mut self, caller: &Caller, command: CommandSpec) -> Result<(), Error> {
        crate::valid_extension_name(&caller.extension).map_err(fail)?;
        if command.id.trim().is_empty() {
            return Err(err(ErrorKind::Invalid, "A command needs an id."));
        }
        // the user decides, per extension, whether its commands are open to agents; there is no way to say so yet
        if matches!(command.exposure, Exposure::Agent) {
            return Err(err(
                ErrorKind::Refused,
                "An extension's commands are open to agents only with the user's approval for that extension (the agent-exposure permission, which does not exist yet).",
            ));
        }
        // an extension's ids are its own: `ext/vim/visit`, never `buffer.save`
        let full = format!("ext/{}/{}", caller.extension, command.id);
        let queue = Arc::clone(&self.invocations);
        let (extension, id) = (caller.extension.clone(), command.id.clone());
        self.registry
            .register(
                bod::Command {
                    id: bod::CommandId(full),
                    title: command.title,
                    doc: command.doc,
                    args: parse_args(&command.args)?,
                    source: bod::SourceLoc {
                        file: format!("extension {}", caller.extension),
                        line: 0,
                    },
                    exposure: exposure_of(command.exposure),
                },
                // the extension's code runs in its host: the command is queued for it
                bod::handler(move |_cx, args| {
                    saman::lock(&queue).push(Invocation {
                        extension: extension.clone(),
                        id: id.clone(),
                        args,
                    });
                    Ok(Value::Null)
                }),
            )
            .map_err(fail)
    }

    fn describe(&mut self, _caller: &Caller, id: String) -> Result<CommandSpec, Error> {
        let c = self
            .registry
            .get(&id)
            .ok_or_else(|| err(ErrorKind::NotFound, "There is no such command."))?;
        Ok(CommandSpec {
            id: c.id.0.clone(),
            title: c.title.clone(),
            doc: c.doc.clone(),
            args: c
                .args
                .args
                .iter()
                .map(|a| ArgSpec {
                    name: a.name.clone(),
                    kind: kind_to(a.kind),
                    required: a.required,
                    doc: a.doc.clone(),
                })
                .collect(),
            exposure: exposure_to(c.exposure),
        })
    }

    fn run(&mut self, caller: &Caller, id: String, args: String) -> Result<String, Error> {
        let args: Value = if args.trim().is_empty() {
            Value::Null
        } else {
            serde_json::from_str(&args)
                .map_err(|_| err(ErrorKind::Invalid, "The arguments are not JSON."))?
        };
        // the origin that started the chain goes through, and the extension is the one the call goes through
        let mut cx = bod::Cx::through_extension(caller.origin.clone(), caller.extension.clone());
        let out = self.registry.run(&id, args, &mut cx).map_err(fail)?;
        Ok(out.to_string())
    }

    fn find_source(&mut self, _caller: &Caller, id: String) -> Result<String, Error> {
        let at = self.registry.find_source(&id).map_err(fail)?;
        Ok(format!("{}:{}", at.file, at.line))
    }
}

impl api::keys::Api for Editor {
    fn bind(
        &mut self,
        caller: &Caller,
        chord: String,
        command: String,
        context: String,
    ) -> Result<(), Error> {
        // an extension binds its own commands, and commands that are open to extensions: not the editor's
        let own = format!("ext/{}/", caller.extension);
        match self.registry.get(&command) {
            Some(c) if command.starts_with(&own) || c.exposure == bod::Exposure::Extension => {}
            Some(_) => {
                return Err(err(
                    ErrorKind::Refused,
                    "An extension binds its own commands and the ones open to extensions.",
                ));
            }
            None => return Err(err(ErrorKind::NotFound, "There is no such command.")),
        }
        let by = bod::Origin::Extension(caller.extension.clone());
        match self.keymap.bind_by(&by, &chord, &command, &context) {
            Ok(()) => Ok(()),
            Err(e) => {
                // a refused binding is kept as a wanted one, and the user is offered another key for it
                if e.kind() == villa::Kind::Refused
                    && let Ok(from) = lykill::parse_chord(&chord)
                {
                    let body = format!(
                        "The extension `{}` asked for `{chord}` for `{command}`: {}",
                        caller.extension,
                        e.message()
                    );
                    self.offer_rebind(
                        "A key binding was refused",
                        &caller.extension,
                        &command,
                        from,
                        body,
                    );
                }
                Err(fail(e))
            }
        }
    }

    fn resolve(
        &mut self,
        _caller: &Caller,
        chord: String,
        context: String,
    ) -> Result<String, Error> {
        // the context is `term=value` pairs and bare flags, separated by commas
        let mut cx = lykill::KeyContext::new();
        for part in context.split(',').map(str::trim).filter(|p| !p.is_empty()) {
            cx = match part.split_once('=') {
                Some((k, v)) => cx.with(k.trim(), v.trim()),
                None => cx.with_flag(part, true),
            };
        }
        let chord = lykill::parse_chord(&chord).map_err(fail)?;
        Ok(match self.keymap.resolve(&chord, &cx) {
            lykill::Resolution::Command(c) => c,
            lykill::Resolution::Prefix => "prefix".to_string(),
            lykill::Resolution::None => String::new(),
        })
    }
}

impl api::settings::Api for Editor {
    fn get(&mut self, _caller: &Caller, key: String) -> Result<String, Error> {
        let v = self
            .settings
            .snapshot()
            .value_in(&key, &skipan::Scope::default())
            .map_err(fail)?;
        Ok(v.to_string())
    }

    fn set(
        &mut self,
        caller: &Caller,
        key: String,
        value: String,
        at: api::settings::ScopedLevel,
        scope_id: String,
    ) -> Result<(), Error> {
        let level = match at {
            api::settings::ScopedLevel::Stream => skipan::Level::Stream,
            api::settings::ScopedLevel::Language => skipan::Level::Language,
            api::settings::ScopedLevel::Document => skipan::Level::Document,
            api::settings::ScopedLevel::Pane => skipan::Level::Pane,
        };
        let value: Value = serde_json::from_str(&value)
            .map_err(|_| err(ErrorKind::Invalid, "The value is not JSON."))?;
        self.settings
            .set_by_extension(&caller.extension, &key, value, level, &scope_id)
            .map_err(fail)
    }

    /// The level a value comes from, and no more: a file's path is the user's business.
    fn provenance(&mut self, _caller: &Caller, key: String) -> Result<String, Error> {
        Ok(self
            .settings
            .provenance(&key)
            .map_err(fail)?
            .level
            .name()
            .to_string())
    }
}

impl api::ask::Api for Editor {
    fn choose(
        &mut self,
        caller: &Caller,
        title: String,
        body: String,
        choices: Vec<String>,
        default_choice: String,
        timeout_ms: u32,
    ) -> Result<u64, Error> {
        // an extension's question always has a timeout, and a short one: the user is not held up by it
        if timeout_ms == 0 || timeout_ms > MAX_QUESTION_MS {
            return Err(err(
                ErrorKind::Invalid,
                "A question's timeout is from 1 ms to 5 minutes.",
            ));
        }
        let own = self
            .questions
            .iter()
            .filter(|p| p.extension == caller.extension)
            .count();
        if own >= MAX_PER_EXTENSION {
            return Err(err(ErrorKind::Refused, "Too many questions are open."));
        }
        let choices: Vec<spurn::Choice> = choices
            .iter()
            .filter(|c| !c.is_empty())
            .map(|c| spurn::Choice::new(c, c))
            .collect();
        let q = spurn::Question::new(
            &title,
            &body,
            choices,
            &default_choice,
            Some(Duration::from_millis(u64::from(timeout_ms))),
            spurn::Origin::Extension(caller.extension.clone()),
        )
        .map_err(fail)?;
        self.next_question += 1;
        let id = self.next_question;
        let task = self.ask.choose(q);
        self.questions.push(Pending {
            extension: caller.extension.clone(),
            id,
            task,
        });
        Ok(id)
    }
}

impl api::notices::Api for Editor {
    fn post(
        &mut self,
        caller: &Caller,
        at: api::notices::Level,
        title: String,
        body: String,
        key: String,
    ) -> Result<u64, Error> {
        let level = tidindi::Level::from_name(at.as_str())
            .ok_or_else(|| err(ErrorKind::Invalid, "Not a level."))?;
        // the key is the extension's own: two extensions with the key `disk` have two notices
        let key =
            (!key.is_empty()).then(|| tidindi::DedupTag(format!("{}/{key}", caller.extension)));
        let held = self.live_notices(&caller.extension);
        let id = self.notices.post(tidindi::Notice {
            level,
            title,
            body,
            actions: Vec::new(),
            key,
        });
        // a posting that updates one of the extension's own notices adds none; any other is capped
        if !self.owners.contains_key(&id.0) {
            if held >= MAX_PER_EXTENSION {
                self.notices.dismiss(id).map_err(fail)?;
                return Err(err(ErrorKind::Refused, "Too many notices are open."));
            }
            self.owners.insert(id.0, caller.extension.clone());
        }
        Ok(id.0)
    }

    fn dismiss(&mut self, caller: &Caller, id: u64) -> Result<(), Error> {
        match self.owners.get(&id) {
            Some(owner) if *owner == caller.extension => {
                self.owners.remove(&id);
                self.notices.dismiss(tidindi::NoticeId(id)).map_err(fail)
            }
            // another extension's notice, or the editor's own: not the caller's to touch
            Some(_) | None => Err(err(
                ErrorKind::Refused,
                "That notice is not yours to dismiss.",
            )),
        }
    }
}
