//! The editor's side of the API: the generated `Api` implemented once, on the standards' crates. Both hosts call it,
//! and it decides on the [`Caller`] of each call:
//!
//! - commands: an extension runs only commands exposed to extensions, and the origin that started the chain stays;
//! - keys: an extension binds no reserved key;
//! - settings: an extension sets the scoped levels only, through `skipan::Settings::set_by_extension`;
//! - ask: a question has a timeout of at most five minutes, is never waited for, and its answer is delivered later;
//! - notices: keys and ids belong to the extension that posted them, and each extension may hold only a few.

use std::collections::BTreeMap;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use serde_json::Value;

use crate::Caller;
use crate::generated::drgnx_api_v0_1_0 as api;
use api::types::ErrorKind;

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
    /// `extension/id` of every command an extension offered, with its title and doc
    pub extension_commands: BTreeMap<String, (String, String)>,
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

fn fail(e: villa::Error) -> ErrorKind {
    kind(e.kind())
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
            extension_commands: BTreeMap::new(),
        }
    }

    /// The answers that have come in, to deliver to the extensions that asked. It never waits.
    pub fn poll_answers(&mut self) -> Vec<Delivery> {
        let mut cx = Context::from_waker(Waker::noop());
        let mut out = Vec::new();
        self.questions
            .retain_mut(|p| match Pin::new(&mut p.task).poll(&mut cx) {
                Poll::Pending => true,
                Poll::Ready(r) => {
                    if let Ok(a) = r {
                        out.push(Delivery {
                            extension: p.extension.clone(),
                            question: p.id,
                            choice: a.choice,
                        });
                    }
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
    fn register(
        &mut self,
        caller: &Caller,
        id: String,
        title: String,
        doc: String,
    ) -> Result<(), ErrorKind> {
        if id.trim().is_empty() || title.trim().is_empty() || doc.trim().is_empty() {
            return Err(ErrorKind::Invalid);
        }
        // an extension's ids are its own: `vim/visit`, never `buffer.save`
        let owned = format!("{}/{id}", caller.extension);
        if self.extension_commands.contains_key(&owned) {
            return Err(ErrorKind::Conflict);
        }
        self.extension_commands.insert(owned, (title, doc));
        Ok(())
    }

    fn run(&mut self, caller: &Caller, id: String, args: String) -> Result<String, ErrorKind> {
        let args: Value = if args.trim().is_empty() {
            Value::Null
        } else {
            serde_json::from_str(&args).map_err(|_| ErrorKind::Invalid)?
        };
        // the origin that started the chain goes through, and the extension is the one the call goes through
        let mut cx = bod::Cx::through_extension(caller.origin.clone(), caller.extension.clone());
        let out = self.registry.run(&id, args, &mut cx).map_err(fail)?;
        Ok(out.to_string())
    }

    fn find_source(&mut self, _caller: &Caller, id: String) -> Result<String, ErrorKind> {
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
    ) -> Result<(), ErrorKind> {
        let by = bod::Origin::Extension(caller.extension.clone());
        self.keymap
            .bind_by(&by, &chord, &command, &context)
            .map_err(fail)
    }

    fn resolve(
        &mut self,
        _caller: &Caller,
        chord: String,
        context: String,
    ) -> Result<String, ErrorKind> {
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
    fn get(&mut self, _caller: &Caller, key: String) -> Result<String, ErrorKind> {
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
    ) -> Result<(), ErrorKind> {
        let level = match at {
            api::settings::ScopedLevel::Stream => skipan::Level::Stream,
            api::settings::ScopedLevel::Language => skipan::Level::Language,
            api::settings::ScopedLevel::Document => skipan::Level::Document,
            api::settings::ScopedLevel::Pane => skipan::Level::Pane,
        };
        let value: Value = serde_json::from_str(&value).map_err(|_| ErrorKind::Invalid)?;
        self.settings
            .set_by_extension(&caller.extension, &key, value, level, &scope_id)
            .map_err(fail)
    }

    fn provenance(&mut self, _caller: &Caller, key: String) -> Result<String, ErrorKind> {
        Ok(self.settings.provenance(&key).map_err(fail)?.to_string())
    }
}

impl api::ask::Api for Editor {
    fn choose(
        &mut self,
        caller: &Caller,
        title: String,
        body: String,
        choices: String,
        default_choice: String,
        timeout_ms: u32,
    ) -> Result<u64, ErrorKind> {
        // an extension's question always has a timeout, and a short one: the user is not held up by it
        if timeout_ms == 0 || timeout_ms > MAX_QUESTION_MS {
            return Err(ErrorKind::Invalid);
        }
        let own = self
            .questions
            .iter()
            .filter(|p| p.extension == caller.extension)
            .count();
        if own >= MAX_PER_EXTENSION {
            return Err(ErrorKind::Refused);
        }
        let choices: Vec<spurn::Choice> = choices
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| spurn::Choice::new(l, l))
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
    ) -> Result<u64, ErrorKind> {
        let level = tidindi::Level::from_name(at.as_str()).ok_or(ErrorKind::Invalid)?;
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
                return Err(ErrorKind::Refused);
            }
            self.owners.insert(id.0, caller.extension.clone());
        }
        Ok(id.0)
    }

    fn dismiss(&mut self, caller: &Caller, id: u64) -> Result<(), ErrorKind> {
        match self.owners.get(&id) {
            Some(owner) if *owner == caller.extension => {
                self.owners.remove(&id);
                self.notices.dismiss(tidindi::NoticeId(id)).map_err(fail)
            }
            // another extension's notice, or the editor's own: not the caller's to touch
            Some(_) | None => Err(ErrorKind::Refused),
        }
    }
}
