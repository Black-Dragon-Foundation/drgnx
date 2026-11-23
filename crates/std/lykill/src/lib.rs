//! lykill (*lykill*, a key): the one key engine (docs/develop/standards/keys.md).
//!
//! A [`Keymap`] holds bindings: a chord, a command id, and where it applies (a context expression, [`When`]). A
//! profile is a file of bindings (`emacs.eld`, `vscode.eld`), read through huginn; [`Profiles::load`] reads a folder
//! of them. [`Keymap::resolve`] says whether a chord is a command, the start of a longer chord, or nothing. A
//! [`Session`] holds the chord typed so far and drops a prefix that waited too long, on the virtual clock in tests.
//!
//! The shell's raw key events are turned into [`KeyEvent`]s at the edge and read nowhere else (`no-raw-key-event`).

mod key;
mod shell;
mod when;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub use key::{KeyCode, KeyEvent, Named, format_chord, parse_chord};
pub use when::{KeyContext, Term, When};

/// The head of a profile file: `(drgnx-keys :version 1 (COMMAND KEYS)…)`.
pub const FILE_HEAD: &str = "drgnx-keys";

/// The head of the user's own level, `keys.eld`: `(drgnx-keys-user :version 1 (COMMAND ("FROM" "TO" "CONTEXT"))…)`. A TO
/// that is empty unbinds the chord.
pub const USER_HEAD: &str = "drgnx-keys-user";

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
    /// Who bound it, when it was an extension (the one origin whose bindings are checked again when a profile is layered).
    pub by: Option<bod::Origin>,
    /// Bound by the user's own level (a rebinding of an extension's command): it wins over every other binding.
    pub user: bool,
}

/// An extension's binding that was dropped because a profile made it a prefix.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Dropped {
    pub extension: String,
    pub command: String,
    pub chord: Vec<KeyEvent>,
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
    wanted: Vec<Wanted>,
    overrides: Vec<Override>,
    /// The user's `keys.eld`: where the overrides are kept, and written after each decision.
    user_file: Option<PathBuf>,
}

/// What became of a binding an extension asked for.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum WantedState {
    /// In force.
    Bound,
    /// Refused when the extension asked (why).
    Refused(String),
    /// Dropped when a profile was layered after it (why).
    Dropped(String),
    /// The user bound the command to another chord.
    Rebound(Vec<KeyEvent>),
    /// The user unbound this chord.
    Unbound,
}

/// A binding an extension asked for, kept whether or not it is in force: the `keys` view lists them, and the user
/// rebinds the ones that clash without touching the extension.
#[derive(Clone, PartialEq, Debug)]
pub struct Wanted {
    pub extension: String,
    pub command: String,
    pub chord: Vec<KeyEvent>,
    pub when: Option<When>,
    pub state: WantedState,
}

/// The user's decision about one extension chord, kept in the user's own level (never in the extension). It is keyed
/// by the extension's command and the chord it asked for, so it holds across the extension's reloads and updates.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Override {
    pub command: String,
    pub from: Vec<KeyEvent>,
    /// The chord the user chose; none unbinds.
    pub to: Option<Vec<KeyEvent>>,
    /// The context the extension wanted the binding in (empty: everywhere); the user's chord applies in it too.
    pub when: String,
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
            when: parse_when(when)?,
            source: None,
            by: None,
            user: false,
        });
        Ok(())
    }

    /// What `bind` does, for the origin ORIGIN: an extension's binding may not be, or start with, a reserved key, may not
    /// be the start of a longer chord that is bound, and may not extend a chord that is bound (that one would be
    /// reached first); both are compared within one context. A binding that is refused is kept as a wanted one, and
    /// a user's override of it (a rebinding, or an unbinding) is applied instead of a refusal.
    pub fn bind_by(
        &mut self,
        origin: &bod::Origin,
        chord: &str,
        command: &str,
        when: &str,
    ) -> villa::Result<()> {
        let bod::Origin::Extension(ext) = origin else {
            return self.bind(chord, command, when);
        };
        let wanted = parse_chord(chord)?;
        let ctx = parse_when(when)?;
        if let Some(o) = self
            .overrides
            .iter()
            .find(|o| o.command == command && o.from == wanted)
        {
            let state = match &o.to {
                Some(to) => WantedState::Rebound(to.clone()),
                None => WantedState::Unbound,
            };
            self.note(ext, command, &wanted, &ctx, state);
            return Ok(());
        }
        if let Err(why) = self.check_extension(&wanted, &ctx) {
            self.note(
                ext,
                command,
                &wanted,
                &ctx,
                WantedState::Refused(why.message().to_string()),
            );
            return Err(why);
        }
        self.bind(chord, command, when)?;
        if let Some(b) = self.bindings.last_mut() {
            b.by = Some(origin.clone());
        }
        self.note(ext, command, &wanted, &ctx, WantedState::Bound);
        Ok(())
    }

    fn check_extension(&self, wanted: &[KeyEvent], ctx: &Option<When>) -> villa::Result<()> {
        for r in RESERVED {
            let reserved = parse_chord(r)?;
            if wanted.first() == reserved.first() {
                return Err(villa::Error::refused(format!(
                    "The key `{r}` is reserved: an extension may not use it."
                )));
            }
        }
        if self.shadows_in(wanted, ctx) {
            return Err(villa::Error::refused(
                "That chord is the start of a longer binding: an extension may not shadow it.",
            ));
        }
        if self
            .bindings
            .iter()
            .any(|b| b.when == *ctx && b.chord.len() < wanted.len() && wanted.starts_with(&b.chord))
        {
            return Err(villa::Error::refused(
                "A shorter binding is on the start of that chord, so it could never be reached.",
            ));
        }
        Ok(())
    }

    fn note(
        &mut self,
        ext: &str,
        command: &str,
        chord: &[KeyEvent],
        when: &Option<When>,
        state: WantedState,
    ) {
        if let Some(w) = self.wanted.iter_mut().find(|w| {
            w.extension == ext && w.command == command && w.chord == chord && w.when == *when
        }) {
            w.state = state;
        } else {
            self.wanted.push(Wanted {
                extension: ext.to_string(),
                command: command.to_string(),
                chord: chord.to_vec(),
                when: when.clone(),
                state,
            });
        }
    }

    /// Every binding an extension asked for, in force or not, with what became of it.
    pub fn wanted(&self) -> &[Wanted] {
        &self.wanted
    }

    /// Keep the user's decisions in FILE (the user's `keys.eld`): read now (a missing file is no decisions), and written
    /// atomically after every rebinding or unbinding, so a restart finds them.
    pub fn attach_user_file(&mut self, file: &Path) -> villa::Result<()> {
        self.user_file = Some(file.to_path_buf());
        if !file.exists() {
            return Ok(());
        }
        let bytes = read_file(file)?;
        let (overrides, problems) = parse_user(&bytes)?;
        if let Some(p) = problems.first() {
            return Err(villa::Error::invalid(format!(
                "The user's keys file {} has an entry that cannot be read.",
                file.display()
            ))
            .with_detail(p.clone()));
        }
        for o in &overrides {
            if let Some(to) = &o.to {
                self.bindings.push(Binding {
                    chord: to.clone(),
                    command: o.command.clone(),
                    when: parse_when(&o.when)?,
                    source: Some((file.display().to_string(), 0)),
                    by: None,
                    user: true,
                });
            }
        }
        self.overrides = overrides;
        Ok(())
    }

    fn persist(&self) -> villa::Result<()> {
        let Some(file) = &self.user_file else {
            return Ok(());
        };
        let q = |s: &str| format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""));
        let mut text = format!("({USER_HEAD} :version 1\n");
        for o in &self.overrides {
            let to = o.to.as_deref().map(format_chord).unwrap_or_default();
            text.push_str(&format!(
                " ({} ({} {} {}))\n",
                o.command,
                q(&format_chord(&o.from)),
                q(&to),
                q(&o.when)
            ));
        }
        text.push_str(")\n");
        if let Some(dir) = file.parent() {
            std::fs::create_dir_all(dir).map_err(villa::Error::from)?;
        }
        eitri::replace_file(file, text.as_bytes()).map_err(|e| {
            villa::Error::io(format!(
                "The user's keys file {} could not be written.",
                file.display()
            ))
            .with_detail(e.to_string())
        })
    }

    /// The user's overrides, for the host to keep in the user's keymap level.
    pub fn overrides(&self) -> &[Override] {
        &self.overrides
    }

    /// Put back overrides the host kept (at startup); bindings asked for later meet them.
    pub fn set_overrides(&mut self, overrides: Vec<Override>) {
        self.overrides = overrides;
    }

    /// An extension goes away (unloaded, or about to reload): its bindings and wanted ones go. The user's overrides stay,
    /// so the extension's next binding meets them.
    pub fn unload_extension(&mut self, extension: &str) {
        self.bindings
            .retain(|b| !matches!(&b.by, Some(bod::Origin::Extension(e)) if e == extension));
        self.wanted.retain(|w| w.extension != extension);
    }

    fn wanted_index(&self, command: &str, from: &[KeyEvent]) -> villa::Result<usize> {
        self.wanted
            .iter()
            .position(|w| w.command == command && w.chord == from)
            .ok_or_else(|| villa::Error::not_found("No extension asked for that binding."))
    }

    /// The user binds COMMAND, which an extension wanted on FROM, to TO instead. The user's level wins over every
    /// extension's request; the extension is not touched.
    pub fn rebind_by_user(
        &mut self,
        command: &str,
        from: &[KeyEvent],
        to: &str,
    ) -> villa::Result<()> {
        let to = parse_chord(to)?;
        let i = self.wanted_index(command, from)?;
        let when = self.wanted[i].when.clone();
        let when_text = when
            .as_ref()
            .map_or(String::new(), |w| w.text().to_string());
        self.drop_extension_binding(command, from);
        self.remove_user_binding(command, from);
        self.bindings.push(Binding {
            chord: to.clone(),
            command: command.to_string(),
            when,
            source: None,
            by: None,
            user: true,
        });
        // the user's binding is remembered with what it replaced, so a rebinding made again replaces it
        self.set_override(Override {
            command: command.to_string(),
            from: from.to_vec(),
            to: Some(to.clone()),
            when: when_text,
        });
        self.wanted[i].state = WantedState::Rebound(to);
        self.persist()
    }

    /// The user unbinds an extension's chord: it sticks across reloads.
    pub fn unbind_by_user(&mut self, command: &str, from: &[KeyEvent]) -> villa::Result<()> {
        let i = self.wanted_index(command, from)?;
        self.drop_extension_binding(command, from);
        self.remove_user_binding(command, from);
        self.set_override(Override {
            command: command.to_string(),
            from: from.to_vec(),
            to: None,
            when: self.wanted[i]
                .when
                .as_ref()
                .map_or(String::new(), |w| w.text().to_string()),
        });
        self.wanted[i].state = WantedState::Unbound;
        self.persist()
    }

    /// The user's binding made by an earlier override of COMMAND on FROM goes, so a new decision replaces it.
    fn remove_user_binding(&mut self, command: &str, from: &[KeyEvent]) {
        let Some(old) = self
            .overrides
            .iter()
            .find(|o| o.command == command && o.from == from)
            .and_then(|o| o.to.clone())
        else {
            return;
        };
        self.bindings
            .retain(|b| !(b.user && b.command == command && b.chord == old));
    }

    fn drop_extension_binding(&mut self, command: &str, from: &[KeyEvent]) {
        self.bindings.retain(|b| {
            !(matches!(b.by, Some(bod::Origin::Extension(_)))
                && b.command == command
                && b.chord == from)
        });
    }

    fn set_override(&mut self, o: Override) {
        self.overrides
            .retain(|e| !(e.command == o.command && e.from == o.from));
        self.overrides.push(o);
    }

    /// Whether CHORD is the start of a longer chord that is bound, in any context.
    pub fn shadows(&self, chord: &[KeyEvent]) -> bool {
        self.bindings
            .iter()
            .any(|b| b.chord.len() > chord.len() && b.chord.starts_with(chord))
    }

    /// Whether CHORD is the start of a longer chord that is bound in the context CTX (and only that one).
    fn shadows_in(&self, chord: &[KeyEvent], ctx: &Option<When>) -> bool {
        self.bindings
            .iter()
            .any(|b| b.when == *ctx && b.chord.len() > chord.len() && b.chord.starts_with(chord))
    }

    /// Lay a profile over this keymap: its bindings win over the ones already here.
    /// An extension's binding that the profile makes a prefix is dropped (the profile's chord wins, as an extension may
    /// not shadow one): the dropped ones are returned, for the user to be told.
    pub fn layer(&mut self, profile: &Profile) -> Vec<Dropped> {
        self.bindings.extend(profile.bindings.iter().cloned());
        let mut dropped = Vec::new();
        let all = self.bindings.clone();
        // only within one context: a binding that applies elsewhere does not make this one a prefix
        self.bindings.retain(|b| {
            let Some(bod::Origin::Extension(ext)) = &b.by else {
                return true;
            };
            let shadows = all.iter().any(|o| {
                o.when == b.when && o.chord.len() > b.chord.len() && o.chord.starts_with(&b.chord)
            });
            if shadows {
                dropped.push(Dropped {
                    extension: ext.clone(),
                    command: b.command.clone(),
                    chord: b.chord.clone(),
                });
            }
            !shadows
        });
        for d in &dropped {
            if let Some(w) = self.wanted.iter_mut().find(|w| {
                w.extension == d.extension && w.command == d.command && w.chord == d.chord
            }) {
                w.state = WantedState::Dropped(format!(
                    "The profile `{}` has a longer chord that starts with it.",
                    profile.name
                ));
            }
        }
        dropped
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
        // the user's own level first (latest first), then the rest (latest first)
        let ordered = self
            .bindings
            .iter()
            .rev()
            .filter(|b| b.user)
            .chain(self.bindings.iter().rev().filter(|b| !b.user));
        for b in ordered {
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
                        by: None,
                        user: false,
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

/// The overrides of the user's `keys.eld`, and the entries that could not be read.
fn parse_user(bytes: &[u8]) -> villa::Result<(Vec<Override>, Vec<String>)> {
    use huginn::value::{Datum, Node};
    let text = String::from_utf8_lossy(bytes).into_owned();
    let line_of = |at: usize| huginn::span::line_col(&text, at).0;
    let file =
        huginn::form::parse_settings(bytes, USER_HEAD, huginn::read::Limits::default()).map_err(
            |r| {
                villa::Error::invalid("The user's keys file could not be read.")
                    .with_detail(format!("keys.eld:{}: {}", line_of(r.span.start), r.message))
            },
        )?;
    let mut problems: Vec<String> = file
        .problems
        .iter()
        .map(|p| format!("keys.eld:{}: {}", line_of(p.span.start), p.message))
        .collect();
    let mut out = Vec::new();
    for e in &file.entries {
        let line = line_of(e.span.start);
        let Datum::List(items) = &e.value.datum else {
            problems.push(format!(
                "keys.eld:{line}: `{}` is not (\"from\" \"to\" \"context\")",
                e.var
            ));
            continue;
        };
        let strs: Vec<&str> = items
            .iter()
            .filter_map(|n: &Node| match &n.datum {
                Datum::Str(s) => Some(s.as_str()),
                _ => None,
            })
            .collect();
        let [from, to, when] = strs.as_slice() else {
            problems.push(format!(
                "keys.eld:{line}: `{}` is not (\"from\" \"to\" \"context\")",
                e.var
            ));
            continue;
        };
        match (
            parse_chord(from),
            if to.is_empty() {
                Ok(None)
            } else {
                parse_chord(to).map(Some)
            },
        ) {
            (Ok(from), Ok(to)) => out.push(Override {
                command: e.var.clone(),
                from,
                to,
                when: (*when).to_string(),
            }),
            (Err(err), _) | (_, Err(err)) => problems.push(format!("keys.eld:{line}: {err}")),
        }
    }
    Ok((out, problems))
}

fn parse_when(when: &str) -> villa::Result<Option<When>> {
    if when.trim().is_empty() {
        Ok(None)
    } else {
        When::parse(when).map(Some)
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
