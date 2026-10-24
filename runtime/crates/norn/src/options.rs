//! Settings history (Urdr Task 10b, built as unified-settings Task 23; design §12, §13): entities of kind `option`,
//! their id grammar, the name half of the settings deny-list, and norn's write rule for the kind.
//!
//! Ids (call 13; `<project>` is the Urdr project id without `project:`, or `root-<12 hex>` for a folder with no Urdr
//! project):
//! - `option:global:<var>`, `option:global:mode/<mode>:<var>`;
//! - `option:private/<project>:[dir/<sub>/:][mode/<mode>:]<var>`, and the same with `shared/`.
//!
//! The rule ([`rule`], registered by [`crate::grants::register`]): every class writes only well-formed ids; the user
//! writes any; an agent only under an active `options` grant whose `who` is its project, profile or session, whose
//! `what` covers the id's scope (`options:global`, or `options:project` for its own project's private and shared
//! ids), whose `names` match, and never a name of [`deny`]; the tracker scan (`graph/put-parsed`, unified-settings
//! Task 24) only the shared ids of the repository's own project, made parsed ([`scan_may_write`]). Every other class
//! (ext, the hub, imports) is refused.

use std::fmt;

use runstav::methods::settings::SettingScope;
use urdr::Connection;
use urdr::graph::entity::{self, Origin};
use urdr::graph::guard::Target;
use urdr::graph::{Class, TxMeta, WriteError};

use crate::grants::{self, Access, What};
use crate::scope::Caller;

/// The refusal of an option write by a class that never writes one (ext, the hub, an import, the scan).
pub const SETTINGS_ARE_THE_USERS: &str = crate::grants::SETTINGS_ARE_THE_USERS;
/// The refusal of an agent's write no active `options` grant covers.
pub const NO_GRANT: &str = "settings are the user's: no options grant covers this setting";
/// The refusal of a deny-listed name, whatever the grant.
pub const DENIED: &str = "this setting is never an agent's to change";
/// The refusal of an agent's write of another project's settings, or of an entity whose project is not its id's.
pub const NOT_ITS_PROJECT: &str = "an agent changes only its own project's settings";
/// The refusal of the scan's write of a shared id whose project is not the entity's (the repository's).
pub const NOT_THE_REPOSITORYS: &str = "a repository records only its own project's shared settings";

/// The tool of the tracker scan's txs (`graph/put-parsed`: actor `scan:<root>`, class `system`).
pub const SCAN_TOOL: &str = "scan";

/// The longest id accepted.
const MAX_ID: usize = 1024;

/// Which file an option lives in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Scope {
    /// `settings.el`.
    Global,
    /// The private workspace file of `<project>`.
    Private(String),
    /// The shared `.drgnx/settings.el` of `<project>`.
    Shared(String),
}

/// A parsed option id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OptionId {
    pub scope: Scope,
    /// The `:dir` section (`src/`), private and shared ids only.
    pub dir: Option<String>,
    /// The `:mode` section (`python-mode`).
    pub mode: Option<String>,
    /// The variable.
    pub var: String,
}

impl OptionId {
    /// The Urdr project id the id names (`project:<project>`): `None` for a global id and for a `root-` folder.
    pub fn project(&self) -> Option<String> {
        match &self.scope {
            Scope::Global => None,
            Scope::Private(p) | Scope::Shared(p) if p.starts_with("root-") => None,
            Scope::Private(p) | Scope::Shared(p) => Some(format!("project:{p}")),
        }
    }
}

impl fmt::Display for OptionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.scope {
            Scope::Global => f.write_str("option:global:")?,
            Scope::Private(p) => write!(f, "option:private/{p}:")?,
            Scope::Shared(p) => write!(f, "option:shared/{p}:")?,
        }
        if let Some(d) = &self.dir {
            write!(f, "dir/{d}:")?;
        }
        if let Some(m) = &self.mode {
            write!(f, "mode/{m}:")?;
        }
        f.write_str(&self.var)
    }
}

/// Why an id is not an option id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BadId(pub &'static str);

impl fmt::Display for BadId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0)
    }
}

/// A character no part of an id holds.
fn bad_char(c: char) -> bool {
    c.is_whitespace() || c.is_control()
}

/// ID as an [`OptionId`]. The project part is `[a-z0-9-]`; a dir is relative, ends in `/`, has no empty, `.` or
/// `..` part and no `:`; a mode has no `:` or `/`; the variable is not empty and does not start with `dir/` or
/// `mode/`. No part holds whitespace or a control character.
pub fn parse_id(id: &str) -> Result<OptionId, BadId> {
    if id.len() > MAX_ID {
        return Err(BadId("an option id is at most 1024 bytes"));
    }
    if id.chars().any(bad_char) {
        return Err(BadId(
            "an option id holds no whitespace or control character",
        ));
    }
    let rest = id
        .strip_prefix("option:")
        .ok_or(BadId("an option id starts with option:"))?;
    let (scope, mut rest) = rest
        .split_once(':')
        .ok_or(BadId("an option id names its scope and its variable"))?;
    let scope = if scope == "global" {
        Scope::Global
    } else {
        let (file, project) = scope.split_once('/').ok_or(BadId(
            "the scope is global, private/<project> or shared/<project>",
        ))?;
        let project_ok = !project.is_empty()
            && project.len() <= 64
            && project
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
        if !project_ok {
            return Err(BadId("a project is [a-z0-9-], 1 to 64 long"));
        }
        match file {
            "private" => Scope::Private(project.into()),
            "shared" => Scope::Shared(project.into()),
            _ => {
                return Err(BadId(
                    "the scope is global, private/<project> or shared/<project>",
                ));
            }
        }
    };
    let mut dir = None;
    if let Some(after) = rest.strip_prefix("dir/") {
        if scope == Scope::Global {
            return Err(BadId("a global id has no dir section"));
        }
        let (d, r) = after
            .split_once(':')
            .ok_or(BadId("a dir section ends with :"))?;
        let parts_ok = d.strip_suffix('/').is_some_and(|inner| {
            inner
                .split('/')
                .all(|p| !p.is_empty() && p != "." && p != "..")
        });
        if !parts_ok {
            return Err(BadId(
                "a dir is relative, ends in /, and has no empty, . or .. part",
            ));
        }
        dir = Some(d.to_string());
        rest = r;
    }
    let mut mode = None;
    if let Some(after) = rest.strip_prefix("mode/") {
        let (m, r) = after
            .split_once(':')
            .ok_or(BadId("a mode section ends with :"))?;
        if m.is_empty() || m.contains('/') {
            return Err(BadId("a mode is a name with no / or :"));
        }
        mode = Some(m.to_string());
        rest = r;
    }
    if rest.is_empty() || rest.starts_with("dir/") || rest.starts_with("mode/") {
        return Err(BadId(
            "the variable is a name, not empty, after the sections",
        ));
    }
    Ok(OptionId {
        scope,
        dir,
        mode,
        var: rest.to_string(),
    })
}

/// The name half of the settings deny-list (design §13, call 9): the lists of `test/fixtures/settings-deny.json`
/// (the test `deny_table` keeps them equal). The editor adds what only Lisp knows.
pub mod deny {
    /// drgnx's security settings and Emacs's, by name (and the dir-locals pseudo-variables `eval` and `mode`).
    pub const NAMES: &[&str] = &[
        "custom-file",
        "drgnx-agents-allow-unsandboxed",
        "drgnx-agents-default",
        "drgnx-agents-mcp",
        "drgnx-agents-openrouter",
        "drgnx-agents-own-env",
        "drgnx-agents-profiles",
        "drgnx-agents-routes",
        "drgnx-agents-scrubbed-env",
        "drgnx-ai-providers",
        "drgnx-ai-roles",
        "drgnx-keys-bind",
        "drgnx-keys-layers",
        "drgnx-keys-mac-option",
        "drgnx-keys-pending-layers",
        "drgnx-keys-tty-fallback",
        "drgnx-keys-unbind",
        "drgnx-look-theme",
        "drgnx-modules-disabled",
        "drgnx-modules-enabled",
        "drgnx-modules-external",
        "drgnx-modules-flags",
        "drgnx-sandbox-memory-max",
        "drgnx-sandbox-proxy-pinned-addresses",
        "drgnx-sandbox-secret-files",
        "drgnx-tty-mac-app-dirs",
        "drgnx-user-lisp-files",
        "enable-local-eval",
        "enable-local-variables",
        "eval",
        "exec-directory",
        "exec-path",
        "explicit-shell-file-name",
        "ignored-local-variables",
        "invocation-directory",
        "invocation-name",
        "load-path",
        "mode",
        "nil",
        "package-archives",
        "process-environment",
        "shell-command-switch",
        "shell-file-name",
        "t",
        "trusted-content",
    ];

    /// Name prefixes of the same set; `:` is a keyword (`:eval`, `:mode`, `:dir`), never a variable.
    pub const PREFIXES: &[&str] = &[":", "drgnx-trust-", "safe-local-variable-"];

    /// The characters no variable's name holds, as the editor refuses them (with whitespace and control characters).
    pub const CHARACTERS: &str = "()\";'`,#[]\\";

    /// Whether NAME is shaped as no variable an agent may name: a keyword, `nil` or `t` (in [`NAMES`]), or a name
    /// with whitespace, a control character or one of [`CHARACTERS`].
    pub fn is_not_a_name(name: &str) -> bool {
        name.starts_with(':')
            || name == "nil"
            || name == "t"
            || name
                .chars()
                .any(|c| c.is_whitespace() || c.is_control() || CHARACTERS.contains(c))
    }

    /// Emacs's risky endings (`risky-local-variable-p`) and design §4.4's program endings, compared case folded.
    pub const SUFFIXES: &[&str] = &[
        "-args",
        "-arguments",
        "-bindat-spec",
        "-command",
        "-commands",
        "-executable",
        "-form",
        "-forms",
        "-frame-alist",
        "-function",
        "-functions",
        "-hook",
        "-hooks",
        "-interpreter",
        "-map",
        "-map-alist",
        "-mode-alist",
        "-predicate",
        "-predicates",
        "-program",
        "-program-name",
        "font-lock-keywords",
        "font-lock-syntactic-keywords",
    ];

    /// Endings followed by one or more digits (`font-lock-keywords-2`), compared case folded.
    pub const NUMBERED_SUFFIXES: &[&str] = &["font-lock-keywords-"];

    /// Whether no agent may change the setting NAME, under any grant.
    pub fn is_denied(name: &str) -> bool {
        if NAMES.contains(&name)
            || PREFIXES.iter().any(|p| name.starts_with(p))
            || is_not_a_name(name)
        {
            return true;
        }
        let folded = name.to_ascii_lowercase();
        if SUFFIXES.iter().any(|s| folded.ends_with(s)) {
            return true;
        }
        let digits = folded.trim_end_matches(|c: char| c.is_ascii_digit());
        digits.len() < folded.len() && NUMBERED_SUFFIXES.iter().any(|s| digits.ends_with(s))
    }
}

/// Whether the glob PATTERN (`*` any run of characters, everything else itself) matches NAME: NAME starts with the
/// part before the first `*`, holds the parts between stars in order (each at its leftmost place, which is enough
/// for `*`-only globs), and ends with the part after the last `*`, after them.
pub(crate) fn glob_match(pattern: &str, name: &str) -> bool {
    let mut parts = pattern.split('*');
    let first = parts.next().unwrap_or_default();
    let Some(mut rest) = name.strip_prefix(first) else {
        return false;
    };
    let parts: Vec<&str> = parts.collect();
    let Some((last, middle)) = parts.split_last() else {
        // No `*`: the whole name.
        return rest.is_empty();
    };
    for m in middle {
        match rest.find(m) {
            Some(at) => rest = &rest[at + m.len()..],
            None => return false,
        }
    }
    rest.ends_with(last)
}

/// Whether CALLER may write the option entity TARGET at NOW (the rule of the module doc). Task 32's
/// `settings_change` asks it before it records a proposed tx; the guard asks it on every write of kind `option`.
pub fn may_write(
    conn: &Connection,
    caller: &Caller,
    target: Target<'_>,
    now: f64,
) -> Result<(), WriteError> {
    let id = parse_id(target.id)
        .map_err(|e| WriteError::Refused(format!("not an option id ({e}): {}", target.id)))?;
    match caller.class {
        Class::User => return Ok(()),
        Class::Agent => {}
        Class::Ext | Class::System => return Err(refused(SETTINGS_ARE_THE_USERS)),
    }
    if deny::is_denied(&id.var) {
        return Err(refused(DENIED));
    }
    let want = match id.scope {
        Scope::Global => {
            if target.project.is_some() {
                return Err(refused(NOT_ITS_PROJECT));
            }
            What::OptionsGlobal
        }
        Scope::Private(_) | Scope::Shared(_) => {
            let own = match caller.project {
                Some(p) => entity::by_n(conn, p)?
                    .filter(|e| e.kind == "project" && e.retired_tx.is_none())
                    .map(|e| (p, e.id)),
                None => None,
            };
            match own {
                Some((p, pid)) if id.project().as_deref() == Some(pid.as_str()) => {
                    if target.project != Some(p) {
                        return Err(refused(NOT_ITS_PROJECT));
                    }
                }
                _ => return Err(refused(NOT_ITS_PROJECT)),
            }
            What::OptionsProject
        }
    };
    let granted = grants::live(conn)?.iter().any(|g| {
        g.access == Access::Options
            && g.active(now)
            && g.who.matches(caller)
            && g.what == want
            && g.names_match(&id.var)
    });
    if granted {
        Ok(())
    } else {
        Err(refused(NO_GRANT))
    }
}

fn refused(text: &str) -> WriteError {
    WriteError::Refused(text.into())
}

/// The refusal of a `settings_get` no grant covers.
pub const NO_READ_GRANT: &str =
    "reading settings needs an options or a read grant for this scope: the user grants it";
/// The refusal of a project's settings for a caller with no project.
pub const NO_PROJECT: &str =
    "private and shared settings are your project's: this session has no project";

/// The option id of the plain setting NAME (no dir or mode section) in SCOPE, PROJECT being the bare project id
/// (`project:` taken off; call 13) a private or shared id needs. Refused when SCOPE needs a project and there is
/// none, or when the id is not well formed or NAME would read as a section.
pub fn option_id(scope: SettingScope, project: Option<&str>, name: &str) -> Result<String, BadId> {
    let id = match (scope, project) {
        (SettingScope::Global, _) => format!("option:global:{name}"),
        (SettingScope::Private, Some(p)) => format!("option:private/{p}:{name}"),
        (SettingScope::Shared, Some(p)) => format!("option:shared/{p}:{name}"),
        (_, None) => return Err(BadId(NO_PROJECT)),
    };
    // a dir or mode section parsed out of NAME leaves a variable that is not NAME
    if parse_id(&id)?.var != name {
        return Err(BadId(
            "a setting's name is a variable, not a dir or mode section",
        ));
    }
    Ok(id)
}

/// Whether CALLER may read the settings of SCOPE at NOW (`settings_get`, design §13): the user always; any other
/// caller under an active grant whose `who` is its own: an `options` grant of the scope (`options:global`, or
/// `options:project` for private and shared), or a `read` grant that covers it (`*` covers every scope; a grant of
/// its own project covers private and shared). The grant's `names` do not narrow a read.
pub fn may_read(
    conn: &Connection,
    caller: &Caller,
    scope: SettingScope,
    now: f64,
) -> Result<Result<(), &'static str>, urdr::SqliteError> {
    if caller.class == Class::User {
        return Ok(Ok(()));
    }
    let want = match scope {
        SettingScope::Global => What::OptionsGlobal,
        SettingScope::Private | SettingScope::Shared => What::OptionsProject,
    };
    let covered = grants::live(conn)?.iter().any(|g| {
        g.active(now)
            && g.who.matches(caller)
            && match g.access {
                Access::Options => g.what == want,
                Access::Read => match g.what {
                    What::All => true,
                    What::Project(p) => want == What::OptionsProject && caller.project == Some(p),
                    _ => false,
                },
                Access::EditUserTasks => false,
            }
    });
    Ok(if covered { Ok(()) } else { Err(NO_READ_GRANT) })
}

/// Whether the tracker scan (`graph/put-parsed`) may write the option entity TARGET (the manager's ruling for
/// unified-settings Task 24). A repository's `.drgnx/settings.el` describes the repository, never your global or
/// private settings, so: a well-formed shared id; a create makes it `parsed` (a write to a stored entity keeps its
/// origin, since a shared setting's history holds your Settings changes and the repository's alike); and the entity
/// is in the project the id names (no project for a `root-` folder). What the scan records applies nothing by
/// itself: workspace trust decides what the file's values do.
pub fn scan_may_write(conn: &Connection, target: Target<'_>) -> Result<(), WriteError> {
    let id = parse_id(target.id)
        .map_err(|e| WriteError::Refused(format!("not an option id ({e}): {}", target.id)))?;
    if !matches!(id.scope, Scope::Shared(_)) || target.origin.is_some_and(|o| o != Origin::Parsed) {
        return Err(refused(SETTINGS_ARE_THE_USERS));
    }
    let its_own = match (id.project(), target.project) {
        (None, None) => true,
        (Some(want), Some(n)) => entity::by_n(conn, n)?
            .is_some_and(|e| e.kind == "project" && e.retired_tx.is_none() && e.id == want),
        _ => false,
    };
    if its_own {
        Ok(())
    } else {
        Err(refused(NOT_THE_REPOSITORYS))
    }
}

/// The guard's rule for kind `option` ([`urdr::graph::guard::register_rule`]): [`scan_may_write`] for the scan's tx
/// (class `system`, tool `scan`), else [`may_write`] for the tx's author.
pub fn rule(
    conn: &Connection,
    meta: &TxMeta,
    at: f64,
    target: Target<'_>,
) -> Result<(), WriteError> {
    if meta.class == Class::System && meta.tool == SCAN_TOOL {
        return scan_may_write(conn, target);
    }
    let caller = Caller {
        class: meta.class,
        actor: meta.actor.clone(),
        session: meta.session.clone(),
        profile: meta.profile.clone(),
        job: meta.job.clone(),
        project: meta.project,
        backend: false,
    };
    may_write(conn, &caller, target, at)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    #[test]
    fn id_grammar() {
        let ok = [
            "option:global:fill-column",
            "option:global:mode/python-mode:fill-column",
            "option:private/1a2b3c4d5e6f:fill-column",
            "option:private/1a2b3c4d5e6f:dir/src/:fill-column",
            "option:private/1a2b3c4d5e6f:dir/src/lib/:mode/c-mode:c-basic-offset",
            "option:shared/x-abcd1234:mode/org-mode:org-indent",
            "option:shared/root-0123456789ab:tab-width",
            "option:global:pkg/odd:name",
        ];
        for id in ok {
            let parsed = parse_id(id).unwrap_or_else(|e| panic!("{id}: {e}"));
            assert_eq!(parsed.to_string(), id, "round trip");
        }
        let p = parse_id("option:private/1a2b3c4d5e6f:dir/src/lib/:mode/c-mode:c-basic-offset")
            .unwrap();
        assert_eq!(
            p,
            OptionId {
                scope: Scope::Private("1a2b3c4d5e6f".into()),
                dir: Some("src/lib/".into()),
                mode: Some("c-mode".into()),
                var: "c-basic-offset".into(),
            }
        );
        assert_eq!(parse_id("option:global:a:b").unwrap().var, "a:b");
        let bad = [
            "",
            "option:",
            "option:global",
            "option:global:",
            "setting:global:x",
            "option:local:x",
            "option:private:x",
            "option:private/:x",
            "option:private/ABC:x",
            "option:private/a_b:x",
            "option:global:dir/src/:x",
            "option:private/a:dir/src:x",
            "option:private/a:dir//:x",
            "option:private/a:dir//src/:x",
            "option:private/a:dir/../:x",
            "option:private/a:dir/./:x",
            "option:private/a:dir/src/x",
            "option:global:mode/:x",
            "option:global:mode/a/b:x",
            "option:global:mode/python-mode:",
            "option:global:mode/python-mode",
            "option:global:mode/m:mode/n:x",
            "option:private/a:mode/m:dir/src/:x",
            "option:global:fill column",
            "option:global:fill\ncolumn",
            "option:global:x\u{0}",
        ];
        for id in bad {
            assert!(parse_id(id).is_err(), "{id:?} parsed");
        }
        assert!(parse_id(&format!("option:global:{}", "x".repeat(MAX_ID))).is_err());
        // Exactly the limit parses.
        let at_limit = format!(
            "option:global:{}",
            "x".repeat(MAX_ID - "option:global:".len())
        );
        assert_eq!(at_limit.len(), MAX_ID);
        assert!(parse_id(&at_limit).is_ok());
    }

    #[test]
    fn project_is_the_ids_project() {
        let project = |id: &str| parse_id(id).unwrap().project();
        assert_eq!(project("option:global:fill-column"), None);
        assert_eq!(project("option:global:mode/c-mode:fill-column"), None);
        assert_eq!(
            project("option:private/1a2b3c4d5e6f:fill-column").as_deref(),
            Some("project:1a2b3c4d5e6f")
        );
        assert_eq!(
            project("option:shared/1a2b3c4d5e6f:dir/src/:fill-column").as_deref(),
            Some("project:1a2b3c4d5e6f")
        );
        assert_eq!(
            project("option:shared/x-abcd1234:fill-column").as_deref(),
            Some("project:x-abcd1234")
        );
        assert_eq!(
            project("option:private/root-0123456789ab:fill-column"),
            None
        );
    }

    fn table() -> Value {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../test/fixtures/settings-deny.json");
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap()
    }

    fn strings(v: &Value) -> Vec<&str> {
        v.as_array()
            .unwrap()
            .iter()
            .map(|s| s.as_str().unwrap())
            .collect()
    }

    #[test]
    fn deny_table() {
        let t = table();
        assert_eq!(t["version"], 1);
        assert_eq!(strings(&t["names"]), deny::NAMES);
        assert_eq!(strings(&t["prefixes"]), deny::PREFIXES);
        assert_eq!(strings(&t["suffixes"]), deny::SUFFIXES);
        assert_eq!(strings(&t["numbered_suffixes"]), deny::NUMBERED_SUFFIXES);
        assert_eq!(t["characters"].as_str().unwrap(), deny::CHARACTERS);
        for c in deny::CHARACTERS.chars().chain([' ', '\t', '\n', '\u{7f}']) {
            assert!(deny::is_denied(&format!("fill{c}column")), "{c:?}");
        }
        let cases = t["cases"].as_array().unwrap();
        assert!(cases.len() >= 40);
        for case in cases {
            let (name, denied) = (case[0].as_str().unwrap(), case[1].as_bool().unwrap());
            assert_eq!(deny::is_denied(name), denied, "{name}");
        }
        // Every listed name and prefix is denied, and each suffix is denied on any stem.
        for n in deny::NAMES.iter().chain(deny::PREFIXES) {
            assert!(deny::is_denied(n), "{n}");
        }
        for s in deny::SUFFIXES {
            assert!(deny::is_denied(&format!("x{s}")), "{s}");
        }
    }

    #[test]
    fn an_agents_setting_is_a_plain_variable() {
        use SettingScope::*;
        assert_eq!(
            option_id(Global, None, "fill-column").unwrap(),
            "option:global:fill-column"
        );
        assert_eq!(
            option_id(Global, Some("abc"), "fill-column").unwrap(),
            "option:global:fill-column"
        );
        assert_eq!(
            option_id(Private, Some("abc"), "tab-width").unwrap(),
            "option:private/abc:tab-width"
        );
        assert_eq!(
            option_id(Shared, Some("abc"), "tab-width").unwrap(),
            "option:shared/abc:tab-width"
        );
        assert_eq!(option_id(Private, None, "x"), Err(BadId(NO_PROJECT)));
        assert_eq!(option_id(Shared, None, "x"), Err(BadId(NO_PROJECT)));
        // a name that reads as a section, or as more than the name
        for (scope, name) in [
            (Global, "mode/c-mode:fill-column"),
            (Shared, "mode/c-mode:fill-column"),
            (Shared, "dir/src/:fill-column"),
            (Global, "dir/src/:x"),
            (Global, ""),
            (Global, "fill column"),
            (Shared, "a\nb"),
        ] {
            assert!(option_id(scope, Some("abc"), name).is_err(), "{name:?}");
        }
        // a colon is part of a variable's name, as the id grammar reads it
        assert_eq!(option_id(Global, None, "a:b").unwrap(), "option:global:a:b");
        assert!(option_id(Private, Some("ABC"), "x").is_err());
    }

    #[test]
    fn reading_settings_needs_a_grant_of_the_scope() {
        use crate::grants::{Who, create, create_options, revoke};
        use crate::scope::testkit::{db, project, user, write};
        use SettingScope::*;
        let (_d, _p, mut conn) = db();
        let (a, b) = (project(&mut conn, "a"), project(&mut conn, "b"));
        let agent = |sid: &str, p: Option<i64>| Caller {
            class: Class::Agent,
            actor: format!("agent:{sid}"),
            session: Some(sid.into()),
            profile: Some("prof".into()),
            job: None,
            project: p,
            backend: false,
        };
        let sid = |s: &str| Who::Session(s.into());
        let options = |conn: &mut Connection, who: Who, what: What| {
            write(conn, user(), |tx| {
                create_options(tx, who, what, Some(vec!["tab-*".into()]), None)
            })
            .unwrap()
        };
        let read = |conn: &mut Connection, who: Who, what: What| {
            write(conn, user(), |tx| create(tx, who, what, Access::Read, None)).unwrap()
        };
        const NOW: f64 = 2_000_000_000.0;
        // s1: options:global (its names do not narrow a read); s2: options:project; s3: read `*`; s4: a read of its
        // own project; s5: a read of another project; s6: edit-user-tasks `*`; s7: an expired options:global; s8: a
        // revoked read `*`; profile prof: options:project; s9: nothing
        options(&mut conn, sid("s1"), What::OptionsGlobal);
        options(&mut conn, sid("s2"), What::OptionsProject);
        read(&mut conn, sid("s3"), What::All);
        read(&mut conn, sid("s4"), What::Project(a));
        read(&mut conn, sid("s5"), What::Project(b));
        write(&mut conn, user(), |tx| {
            create(tx, sid("s6"), What::All, Access::EditUserTasks, None)
        })
        .unwrap();
        let soon = write(&mut conn, user(), |tx| {
            let at = tx.at();
            create_options(tx, sid("s7"), What::OptionsGlobal, None, Some(at + 1.0))
        })
        .unwrap();
        let gone = read(&mut conn, sid("s8"), What::All);
        write(&mut conn, user(), |tx| revoke(tx, &gone.id)).unwrap();
        let may = |conn: &Connection, c: &Caller, s: SettingScope, now: f64| {
            may_read(conn, c, s, now).unwrap()
        };
        let at = soon.expires.unwrap() - 0.5;
        for (who, p, scope, now, want) in [
            ("s1", Some(a), Global, NOW, true),
            ("s1", Some(a), Shared, NOW, false),
            ("s2", Some(a), Private, NOW, true),
            ("s2", Some(a), Shared, NOW, true),
            ("s2", Some(a), Global, NOW, false),
            ("s3", None, Global, NOW, true),
            ("s3", Some(a), Shared, NOW, true),
            ("s4", Some(a), Shared, NOW, true),
            ("s4", Some(a), Private, NOW, true),
            ("s4", Some(a), Global, NOW, false),
            ("s4", Some(b), Shared, NOW, false),
            ("s4", None, Shared, NOW, false),
            ("s5", Some(a), Shared, NOW, false),
            ("s6", Some(a), Global, NOW, false),
            ("s6", Some(a), Shared, NOW, false),
            ("s7", Some(a), Global, at, true),
            ("s7", Some(a), Global, soon.expires.unwrap(), false),
            ("s8", Some(a), Global, NOW, false),
            ("s9", Some(a), Global, NOW, false),
            ("s9", Some(a), Shared, NOW, false),
        ] {
            let got = may(&conn, &agent(who, p), scope, now);
            assert_eq!(got.is_ok(), want, "{who} {scope:?}");
            if !want {
                assert_eq!(got, Err(NO_READ_GRANT));
            }
        }
        // a profile grant covers its sessions; the user reads anything, with no grant
        options(&mut conn, Who::Profile("prof".into()), What::OptionsProject);
        assert_eq!(may(&conn, &agent("s9", Some(a)), Shared, NOW), Ok(()));
        assert_eq!(
            may(&conn, &agent("s9", Some(a)), Global, NOW),
            Err(NO_READ_GRANT)
        );
        assert_eq!(may(&conn, &Caller::user(false), Global, NOW), Ok(()));
        // an outside agent under a grant of its session reads; the hub's class does not read by class
        let mut ext = agent("ext:claude:1-ab", Some(a));
        ext.class = Class::Ext;
        assert_eq!(may(&conn, &ext, Global, NOW), Err(NO_READ_GRANT));
        read(&mut conn, sid("ext:claude:1-ab"), What::All);
        assert_eq!(may(&conn, &ext, Global, NOW), Ok(()));
        let mut hub = agent("s9", None);
        hub.class = Class::System;
        assert_eq!(may(&conn, &hub, Global, NOW), Err(NO_READ_GRANT));
    }

    #[test]
    fn globs_match_star_only() {
        for (p, n, want) in [
            ("fill-column", "fill-column", true),
            ("fill-column", "fill-columns", false),
            ("python-*", "python-indent-offset", true),
            ("python-*", "python-", true),
            ("python-*", "cython-x", false),
            ("*", "anything", true),
            ("*-offset", "c-basic-offset", true),
            ("*-offset", "c-basic-offsets", false),
            ("a*b*c", "aXbYc", true),
            ("a*b*c", "aXbY", false),
            ("a?c", "abc", false),
            ("a?c", "a?c", true),
            ("**", "", true),
            ("x", "", false),
            ("", "", true),
            ("", "x", false),
            ("a*bc*d", "aXbcYd", true),
            ("a*bc*d", "abcd", true),
            ("*ab*b", "ab", false),
            ("*ab*b", "abb", true),
            ("*a*a", "a", false),
            ("x*", "y", false),
            ("*x", "xy", false),
        ] {
            assert_eq!(glob_match(p, n), want, "{p} ~ {n}");
        }
    }
}
