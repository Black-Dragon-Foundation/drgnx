//! lykill (*lykill*, a key): the one key engine (docs/develop/standards/keys.md).
//!
//! A [`Keymap`] holds bindings: a chord, a command id, and where it applies (a context expression, [`When`]). A
//! profile is a file of bindings (`emacs.eld`, `vscode.eld`), read through huginn; [`Profiles::load`] reads a folder
//! of them. [`Keymap::resolve`] says whether a chord is a command, the start of a longer chord, or nothing. A
//! [`Session`] holds the chord typed so far and drops a prefix that waited too long, on the virtual clock in tests.
//!
//! The shell's raw key events are turned into [`KeyEvent`]s at the edge and read nowhere else (`no-raw-key-event`).

mod key;
mod when;

use std::collections::BTreeMap;
use std::path::Path;
use std::time::Duration;

pub use key::{KeyCode, KeyEvent, Named, parse_chord};
pub use when::{KeyContext, Term, When};

/// The head of a profile file: `(drgnx-keys :version 1 (COMMAND KEYS)…)`.
pub const FILE_HEAD: &str = "drgnx-keys";

/// The chords no extension may bind or start a chord with: cancel, the command key and the palette's keys. A key the user
/// always has, whatever an extension does.
pub const RESERVED: &[&str] = &["C-g", "M-x", "ctrl+shift+p", "f1"];

/// One binding.
#[derive(Clone, Debug)]
pub struct Binding {
    pub chord: Vec<KeyEvent>,
    pub command: String,
    pub when: Option<When>,
    /// The profile file and line it came from, when it came from one.
    pub source: Option<(String, u32)>,
}

/// What a chord is in a context.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Resolution {
    Command(String),
    /// More keys are needed: some binding starts with this chord.
    Prefix,
    None,
}

/// The bindings in force. A later binding of the same chord and context wins.
#[derive(Clone, Default, Debug)]
pub struct Keymap {
    bindings: Vec<Binding>,
}

impl Keymap {
    pub fn new() -> Keymap {
        Keymap::default()
    }

    /// Bind CHORD (text, either spelling) to COMMAND where WHEN holds (empty: everywhere).
    pub fn bind(&mut self, chord: &str, command: &str, when: &str) -> villa::Result<()> {
        self.bindings.push(Binding {
            chord: parse_chord(chord)?,
            command: command.to_string(),
            when: if when.trim().is_empty() {
                None
            } else {
                Some(When::parse(when)?)
            },
            source: None,
        });
        Ok(())
    }

    /// What `bind` does, for the origin ORIGIN: an extension's binding may not be, or start with, a reserved key.
    pub fn bind_by(
        &mut self,
        origin: &bod::Origin,
        chord: &str,
        command: &str,
        when: &str,
    ) -> villa::Result<()> {
        if matches!(origin, bod::Origin::Extension(_)) {
            let wanted = parse_chord(chord)?;
            for r in RESERVED {
                let reserved = parse_chord(r)?;
                if wanted.first() == reserved.first() {
                    return Err(villa::Error::refused(format!(
                        "The key `{r}` is reserved: an extension may not use it."
                    )));
                }
            }
        }
        self.bind(chord, command, when)
    }

    /// Lay a profile over this keymap: its bindings win over the ones already here.
    pub fn layer(&mut self, profile: &Profile) {
        self.bindings.extend(profile.bindings.iter().cloned());
    }

    pub fn from_profile(profile: &Profile) -> Keymap {
        let mut k = Keymap::new();
        k.layer(profile);
        k
    }

    pub fn bindings(&self) -> &[Binding] {
        &self.bindings
    }

    /// What CHORD is in CX: a command (the latest binding that applies), a prefix, or nothing. A command beats a prefix.
    pub fn resolve(&self, chord: &[KeyEvent], cx: &KeyContext) -> Resolution {
        let mut prefix = false;
        for b in self.bindings.iter().rev() {
            if b.when.as_ref().is_some_and(|w| !w.holds(cx)) {
                continue;
            }
            if b.chord == chord {
                return Resolution::Command(b.command.clone());
            }
            if b.chord.len() > chord.len() && b.chord.starts_with(chord) {
                prefix = true;
            }
        }
        if prefix {
            Resolution::Prefix
        } else {
            Resolution::None
        }
    }

    /// Why a key does what it does: the bindings of COMMAND (find-the-source for keys).
    pub fn bindings_of(&self, command: &str) -> Vec<&Binding> {
        self.bindings
            .iter()
            .filter(|b| b.command == command)
            .collect()
    }
}

/// A profile: a named set of bindings.
#[derive(Clone, Debug)]
pub struct Profile {
    pub name: String,
    pub bindings: Vec<Binding>,
}

impl Profile {
    /// A profile from the text of a file called NAME.eld. Entries that cannot be read are returned, not fatal.
    pub fn parse(name: &str, bytes: &[u8]) -> villa::Result<(Profile, Vec<String>)> {
        use huginn::value::{Datum, Node};
        let text = String::from_utf8_lossy(bytes).into_owned();
        let line_of = |at: usize| huginn::span::line_col(&text, at).0;
        let file = huginn::form::parse_settings(bytes, FILE_HEAD, huginn::read::Limits::default())
            .map_err(|r| {
                villa::Error::invalid(format!("The key profile `{name}` could not be read."))
                    .with_detail(format!(
                        "{name}.eld:{}: {}",
                        line_of(r.span.start),
                        r.message
                    ))
            })?;
        let mut problems: Vec<String> = file
            .problems
            .iter()
            .map(|p| format!("{name}.eld:{}: {}", line_of(p.span.start), p.message))
            .collect();
        let mut bindings = Vec::new();
        for e in &file.entries {
            let line = line_of(e.span.start);
            // KEYS: "chord", or a list whose items are "chord" or ("chord" "when")
            let items: Vec<&Node> = match &e.value.datum {
                Datum::Str(_) => vec![&e.value],
                Datum::List(items) => items.iter().collect(),
                _ => {
                    problems.push(format!(
                        "{name}.eld:{line}: the keys of `{}` are not text",
                        e.var
                    ));
                    continue;
                }
            };
            for item in items {
                let (chord, when) = match &item.datum {
                    Datum::Str(c) => (c.clone(), String::new()),
                    Datum::List(pair) => match pair.as_slice() {
                        [
                            Node {
                                datum: Datum::Str(c),
                                ..
                            },
                            Node {
                                datum: Datum::Str(w),
                                ..
                            },
                        ] => (c.clone(), w.clone()),
                        _ => {
                            problems.push(format!("{name}.eld:{line}: a binding of `{}` is not (\"keys\" \"context\")", e.var));
                            continue;
                        }
                    },
                    _ => {
                        problems.push(format!(
                            "{name}.eld:{line}: a binding of `{}` is not text",
                            e.var
                        ));
                        continue;
                    }
                };
                let one = parse_chord(&chord).and_then(|c| {
                    let when = if when.trim().is_empty() {
                        None
                    } else {
                        Some(When::parse(&when)?)
                    };
                    Ok((c, when))
                });
                match one {
                    Ok((chord, when)) => bindings.push(Binding {
                        chord,
                        command: e.var.clone(),
                        when,
                        source: Some((format!("{name}.eld"), line)),
                    }),
                    Err(err) => problems.push(format!("{name}.eld:{line}: {err}")),
                }
            }
        }
        Ok((
            Profile {
                name: name.to_string(),
                bindings,
            },
            problems,
        ))
    }
}

/// The profiles of a folder: every `NAME.eld` in it is the profile NAME.
#[derive(Clone, Debug, Default)]
pub struct Profiles {
    profiles: BTreeMap<String, Profile>,
    /// What could not be read, as `file:line: why`.
    pub problems: Vec<String>,
}

impl Profiles {
    pub fn load(dir: &Path) -> villa::Result<Profiles> {
        let mut out = Profiles::default();
        let entries = std::fs::read_dir(dir).map_err(villa::Error::from)?;
        let mut files: Vec<_> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "eld"))
            .collect();
        files.sort();
        for path in files {
            let Some(name) = path.file_stem().map(|s| s.to_string_lossy().into_owned()) else {
                continue;
            };
            match read_file(&path).and_then(|b| Profile::parse(&name, &b)) {
                Ok((p, problems)) => {
                    out.problems.extend(problems);
                    out.profiles.insert(name, p);
                }
                Err(e) => out
                    .problems
                    .push(format!("{name}.eld: {e} {}", e.detail().unwrap_or(""))),
            }
        }
        Ok(out)
    }

    pub fn get(&self, name: &str) -> Option<&Profile> {
        self.profiles.get(name)
    }

    pub fn names(&self) -> Vec<&str> {
        self.profiles.keys().map(String::as_str).collect()
    }
}

fn read_file(path: &Path) -> villa::Result<Vec<u8>> {
    use std::os::fd::AsFd;
    let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
        return Err(villa::Error::invalid("A key profile path names no file."));
    };
    let io = |e: eitri::FsError| {
        villa::Error::io(format!(
            "The key profile {} could not be read.",
            path.display()
        ))
        .with_detail(e.to_string())
    };
    let dir = eitri::open_path(parent, eitri::Kind::Dir).map_err(io)?;
    eitri::read_regular(dir.fd.as_fd(), Path::new(name), 1 << 20).map_err(io)
}

/// The chord typed so far. A prefix that waits longer than the timeout is dropped, so the next key starts afresh.
#[derive(Debug)]
pub struct Session {
    pending: Vec<KeyEvent>,
    last: Duration,
    timeout: Duration,
}

impl Session {
    pub fn new(timeout: Duration) -> Session {
        Session {
            pending: Vec::new(),
            last: Duration::ZERO,
            timeout,
        }
    }

    /// The keys typed so far, for the status line.
    pub fn pending(&self) -> &[KeyEvent] {
        &self.pending
    }

    /// Drop a prefix that has waited out the timeout; true when one was dropped. Call it from a timer, and
    /// before every key (`feed` does).
    pub fn expire(&mut self) -> bool {
        if !self.pending.is_empty() && stund::now().saturating_sub(self.last) >= self.timeout {
            self.pending.clear();
            return true;
        }
        false
    }

    /// One more key. A command or a miss ends the chord; a prefix keeps it.
    pub fn feed(&mut self, keymap: &Keymap, ev: KeyEvent, cx: &KeyContext) -> Resolution {
        self.expire();
        self.pending.push(ev);
        let r = keymap.resolve(&self.pending, cx);
        match r {
            Resolution::Prefix => self.last = stund::now(),
            _ => self.pending.clear(),
        }
        r
    }
}
