//! Reading `settings.el` (design §11.1, §5.2): the file checks, the runtime entries decoded, and the fallbacks.
//!
//! - The file is `<config>/settings.el` and nothing else: a repository's file is never read.  A link there is
//!   followed (a stow link); what it points at must be a regular file of at most 1 MiB, owned by the user, writable
//!   by nobody else.
//! - A file that does not read (refused, or not well-formed): every `strict` setting has its shipped default, every
//!   other one its last good value from `kv` (else its default).  One problem says why.
//! - An entry whose value does not fit falls back alone, by the same rule; its problem names the line and the path.
//! - Every other entry is skipped (a package's setting, an unknown name, a `(:mode …)` section): never an error.

use std::collections::BTreeMap;
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

use huginn::form::{Problem as FormProblem, parse_settings};
use huginn::read::{Limits, read_all};
use huginn::span::line_col;
use huginn::value::Node;
use runstav::methods::gateway::ProviderConfig;

use super::{OnError, RUNTIME, RuntimeSetting, RuntimeValues, decode, defaults, providers};

/// The file, in the config folder.
pub const FILE: &str = "settings.el";

/// The `kv` key of the last good values: a JSON object, setting → the Lisp text of its value.
pub const KV_LAST_GOOD: &str = "settings-last-good";

/// The largest `settings.el` read (the config layer's limit).
pub const MAX_BYTES: u64 = 1 << 20;

/// The last good values of the `LastGood` settings, as `runtime.db` keeps them: setting → the Lisp text of the value
/// that last decoded.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Kv {
    pub last_good: BTreeMap<String, String>,
}

impl Kv {
    /// The kept JSON TEXT (none, or one that does not read: no last good value).
    pub fn from_text(text: Option<&str>) -> Kv {
        Kv {
            last_good: text
                .and_then(|t| serde_json::from_str(t).ok())
                .unwrap_or_default(),
        }
    }

    pub fn to_text(&self) -> String {
        serde_json::to_string(&self.last_good).expect("a map of strings serializes")
    }
}

/// How the file read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileState {
    /// There is none: every setting has its default.
    Absent,
    Ok,
    /// Refused, or not well-formed: the fallbacks hold for every runtime setting.
    Failed,
}

/// Something the user should hear about (one `notice` each): the file, or one runtime setting.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Problem {
    /// The setting it is about; none for the file.
    pub setting: Option<&'static str>,
    /// The line in `settings.el`, when it is at one.
    pub line: Option<u32>,
    pub text: String,
}

/// One read: the values, the provider table they give, the problems, and the last good values to keep.
#[derive(Clone, Debug, PartialEq)]
pub struct Loaded {
    pub file: FileState,
    pub values: RuntimeValues,
    /// The provider table: the presets with the user's providers over them by id ([`providers::table`]).
    pub providers: Vec<ProviderConfig>,
    pub problems: Vec<Problem>,
    /// What `kv` keeps after this read.
    pub kv: Kv,
}

/// What a file looked like when it was read: a change of any part reads it again.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stamp {
    Absent,
    /// It could not be looked at (its problem stands until it can).
    Unreadable,
    File {
        dev: u64,
        ino: u64,
        len: u64,
        mtime: i64,
        mtime_nsec: i64,
        mode: u32,
        uid: u32,
    },
}

/// PATH's stamp, through a link.
pub fn stamp(path: &Path) -> Stamp {
    match std::fs::metadata(path) {
        Ok(m) => Stamp::File {
            dev: m.dev(),
            ino: m.ino(),
            len: m.len(),
            mtime: m.mtime(),
            mtime_nsec: m.mtime_nsec(),
            mode: m.mode(),
            uid: m.uid(),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Stamp::Absent,
        Err(_) => Stamp::Unreadable,
    }
}

/// PATH's bytes, or none when there is no file, or why it is refused.  The checks are made on the file opened (a
/// link followed), so what is checked is what is read; a FIFO or device is opened without waiting and refused.
pub fn read_checked(path: &Path) -> Result<Option<Vec<u8>>, String> {
    let file = match std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)
    {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("cannot be opened: {e}")),
    };
    let meta = file
        .metadata()
        .map_err(|e| format!("cannot be looked at: {e}"))?;
    if !meta.is_file() {
        return Err("is not a regular file".into());
    }
    if meta.len() > MAX_BYTES {
        return Err(format!("is over 1 MiB ({} bytes)", meta.len()));
    }
    if meta.uid() != rustix::process::geteuid().as_raw() {
        return Err(format!("is owned by user {}, not by you", meta.uid()));
    }
    if meta.mode() & 0o022 != 0 {
        return Err(format!(
            "is writable by others (mode {:o}): chmod go-w it",
            meta.mode() & 0o777
        ));
    }
    let mut bytes = Vec::new();
    file.take(MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("cannot be read: {e}"))?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err("is over 1 MiB".into());
    }
    Ok(Some(bytes))
}

/// `settings.el` in CONFIG_DIR, with KV's last good values for the fallbacks.
pub fn load(config_dir: &Path, kv: &Kv) -> Loaded {
    let mut r = Reading {
        values: defaults().values.clone(),
        problems: Vec::new(),
        kept: Kv::default(),
        before: kv,
    };
    let file = match read_checked(&config_dir.join(FILE)) {
        Ok(None) => FileState::Absent,
        Err(why) => {
            r.file_failed(None, format!("settings.el {why}"));
            FileState::Failed
        }
        Ok(Some(bytes)) => match parse_settings(&bytes, "drgnx-settings", Limits::default()) {
            Err(refusal) => {
                let text = String::from_utf8_lossy(&bytes);
                let (line, col) = line_col(&text, refusal.span.start);
                r.file_failed(
                    Some(line),
                    format!(
                        "settings.el does not read (line {line}, column {col}): {}",
                        refusal.message
                    ),
                );
                FileState::Failed
            }
            Ok(parsed) => {
                let text = std::str::from_utf8(&bytes).expect("huginn read it as UTF-8");
                for s in RUNTIME {
                    r.setting(s, text, &parsed.entries, &parsed.problems);
                }
                FileState::Ok
            }
        },
    };
    let d = defaults();
    let (providers, skipped) = providers::table(&d.presets, &r.values.ai_providers);
    r.problems.extend(skipped_problems(skipped));
    Loaded {
        file,
        values: r.values,
        providers,
        problems: r.problems,
        kv: r.kept,
    }
}

/// The problems of the providers [`providers::table`] left out (SKIPPED: each with why).
pub(crate) fn skipped_problems(skipped: Vec<String>) -> impl Iterator<Item = Problem> {
    skipped.into_iter().map(|text| Problem {
        setting: Some("drgnx-ai-providers"),
        line: None,
        text: format!("drgnx-ai-providers: {text}; that provider is left out"),
    })
}

/// One read in progress.
struct Reading<'a> {
    values: RuntimeValues,
    problems: Vec<Problem>,
    kept: Kv,
    before: &'a Kv,
}

impl Reading<'_> {
    /// The whole file failed: one problem, and every runtime setting falls back.
    fn file_failed(&mut self, line: Option<u32>, why: String) {
        self.problems.push(Problem {
            setting: None,
            line,
            text: format!(
                "{why}; the agents' settings use the shipped defaults, the others their last good values"
            ),
        });
        for s in RUNTIME {
            fallback(s, self.before, &mut self.values, &mut self.kept);
        }
    }

    /// Setting S of a file that read (TEXT; its ENTRIES and huginn's PROBLEMS).
    fn setting(
        &mut self,
        s: &RuntimeSetting,
        text: &str,
        entries: &[huginn::form::Entry],
        problems: &[FormProblem],
    ) {
        let line = |at: usize| line_col(text, at).0;
        for p in problems {
            if p.message.starts_with(&format!("{} is set twice", s.name)) {
                self.problems.push(Problem {
                    setting: Some(s.name),
                    line: Some(line(p.span.start)),
                    text: format!("settings.el line {}: {}", line(p.span.start), p.message),
                });
            }
        }
        // only a top-level entry: a runtime setting has one value for all of Emacs
        if let Some(e) = entries
            .iter()
            .find(|e| e.var == s.name && e.scope.is_empty())
        {
            match decode(s.name, &e.value, &mut self.values) {
                Ok(()) => {
                    if s.on_error == OnError::LastGood {
                        let span = e.value.span;
                        self.kept
                            .last_good
                            .insert(s.name.to_string(), text[span.start..span.end].to_string());
                    }
                }
                Err(bad) => {
                    let at = line(e.span.start);
                    let how = fallback(s, self.before, &mut self.values, &mut self.kept);
                    self.problems.push(Problem {
                        setting: Some(s.name),
                        line: Some(at),
                        text: format!("settings.el line {at}: {}: {}; {how}", s.name, bad.text()),
                    });
                }
            }
        } else if let Some(p) = problems
            .iter()
            .find(|p| p.message.starts_with(&format!("{}: ", s.name)))
        {
            // an entry of this setting that is not (VAR VALUE): it falls back as a bad value does
            let at = line(p.span.start);
            let how = fallback(s, self.before, &mut self.values, &mut self.kept);
            self.problems.push(Problem {
                setting: Some(s.name),
                line: Some(at),
                text: format!("settings.el line {at}: {}; {how}", p.message),
            });
        }
    }
}

/// S's value when its own cannot be used, put in VALUES: the shipped default for a `strict` setting; for the others
/// the last good value in BEFORE (kept on in KEPT), else the default.  What it used, as a problem says it.
fn fallback(
    s: &RuntimeSetting,
    before: &Kv,
    values: &mut RuntimeValues,
    kept: &mut Kv,
) -> &'static str {
    let default = &defaults().values;
    let reset = |values: &mut RuntimeValues| {
        decode_default(s.name, default, values);
    };
    if s.on_error == OnError::Strict {
        reset(values);
        return "it uses the shipped default";
    }
    if let Some(text) = before.last_good.get(s.name)
        && let Some(node) = one_datum(text)
        && decode(s.name, &node, values).is_ok()
    {
        kept.last_good.insert(s.name.to_string(), text.clone());
        return "it keeps its last good value";
    }
    reset(values);
    "it uses its default (there is no last good value)"
}

/// TEXT's one datum, when it reads.
fn one_datum(text: &str) -> Option<Node> {
    let mut nodes = read_all(text.as_bytes(), Limits::default()).ok()?;
    (nodes.len() == 1).then(|| nodes.remove(0))
}

/// NAME's value in VALUES set back to its value in DEFAULT.
fn decode_default(name: &str, default: &RuntimeValues, values: &mut RuntimeValues) {
    match name {
        "drgnx-agents-profiles" => values.agents_profiles = default.agents_profiles.clone(),
        "drgnx-agents-default" => values.agents_default = default.agents_default.clone(),
        "drgnx-agents-mcp" => values.agents_mcp = default.agents_mcp.clone(),
        "drgnx-agents-routes" => values.agents_routes = default.agents_routes.clone(),
        "drgnx-agents-openrouter" => values.agents_openrouter = default.agents_openrouter.clone(),
        "drgnx-agents-allow-unsandboxed" => {
            values.agents_allow_unsandboxed = default.agents_allow_unsandboxed;
        }
        "drgnx-ai-providers" => values.ai_providers = default.ai_providers.clone(),
        "drgnx-ai-roles" => values.ai_roles = default.ai_roles.clone(),
        "drgnx-agents-matrix" => values.agents_matrix = default.agents_matrix.clone(),
        "drgnx-agents-away-after" => values.agents_away_after = default.agents_away_after,
        "drgnx-agents-wait-refusals" => values.agents_wait_refusals = default.agents_wait_refusals,
        "drgnx-agents-close-idle-after" => {
            values.agents_close_idle_after = default.agents_close_idle_after;
        }
        "drgnx-agents-checkpoint-cap" => {
            values.agents_checkpoint_cap = default.agents_checkpoint_cap;
        }
        "drgnx-agents-job-memory" => values.agents_job_memory = default.agents_job_memory.clone(),
        "drgnx-agents-job-cpus" => values.agents_job_cpus = default.agents_job_cpus,
        "drgnx-agents-net-hosts" => values.agents_net_hosts = default.agents_net_hosts.clone(),
        "drgnx-agents-container-images" => {
            values.agents_container_images = default.agents_container_images.clone();
        }
        "drgnx-agents-silent-after" => {
            values.agents_silent_after = default.agents_silent_after.clone();
        }
        "drgnx-agents-repeat-limit" => values.agents_repeat_limit = default.agents_repeat_limit,
        "drgnx-agents-no-progress-tokens" => {
            values.agents_no_progress_tokens = default.agents_no_progress_tokens;
        }
        "drgnx-agents-manager-context" => {
            values.agents_manager_context = default.agents_manager_context;
        }
        _ => {}
    }
}
