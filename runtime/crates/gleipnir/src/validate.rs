//! The rules that refuse a spec (docs/develop/gleipnir.md, "What is refused"). [`validate`] is the only way to make
//! a [`ValidSpec`] outside tests.

use crate::spec::{
    BASE_ENV_DENY, Bind, HELPER_INSIDE, LANDLOCK_ABI_MAX, Mode, Net, RESERVED_DESTS, RelayPort,
    SYSTEM_CLOSED, Spec, Target, ValidSpec,
};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::{fmt, fs, io};

/// What validation compares a spec's paths with. Every path is a true name (absolute, canonical, no link); a
/// context that is not is refused as [`Rule::Malformed`], never read loosely.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Context {
    /// The user's home. No source may be or contain it, nor lie inside one of its secret dirs.
    pub home: PathBuf,
    /// Directories no source may be, contain or lie inside (beside [`crate::SYSTEM_CLOSED`]).
    pub closed: Vec<PathBuf>,
    /// Directories inside a `closed` entry whose insides may be bound after all (a job's own directory).
    pub open_inside_closed: Vec<PathBuf>,
    /// Sockets of the user's (ssh agent, D-Bus, the hub). No source may be or contain one.
    pub user_sockets: Vec<PathBuf>,
    /// Where session dirs are made: `run` must be a direct child of one, and nothing else may touch them.
    pub run_parents: Vec<PathBuf>,
    /// The caller's `PATH`. No writable source may be or contain one.
    pub program_dirs: Vec<PathBuf>,
    /// Environment names to refuse beside [`crate::BASE_ENV_DENY`].
    pub env_deny: Vec<String>,
}

/// Which rule refused a spec. The rules apply in this order; the first that applies wins.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rule {
    NotUtf8,
    NotCanonical,
    ExposesUser,
    Closed,
    SecretDir,
    SessionDir,
    ProgramDir,
    Missing,
    Malformed,
    EnvDenied,
    DestDiffers,
    ReservedDest,
    /// Not a validation rule: the sandbox did not start. The inner helper's status line said why, or none came
    /// before the deadline ([`crate::inner::read_status`]).
    Setup,
}

/// Why a spec was refused: the rule, the path it applies to (when it is about a path) and a sentence naming the key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub rule: Rule,
    pub path: Option<PathBuf>,
    pub message: String,
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Refusal {}

/// Proof that a spec passed validation. Its field is private to this module, so only this module can make one, and
/// [`ValidSpec`]'s constructor takes one: no other module of the crate can make a `ValidSpec` (tests use
/// `ValidSpec::assume_valid`).
pub(crate) struct Checked(());

#[cfg(test)]
impl Checked {
    pub(crate) fn for_tests() -> Checked {
        Checked(())
    }
}

/// Check `spec` for `target` against `ctx`. The rules apply in [`Rule`]'s order, each over the whole spec, and the
/// first that applies wins. `read` and `hide` entries that do not exist pass every rule like the others (a closed
/// path is refused even while it is absent) and are then dropped from the result: there is nothing to bind.
pub fn validate(mut spec: Spec, ctx: &Context, target: Target) -> Result<ValidSpec, Refusal> {
    let cmp = Cmp {
        fold: target == Target::Macos,
    };
    let ctx = prepare(ctx, cmp, target)?;
    let paths = all_paths(&spec, target);
    forms(&paths)?;
    let absent = true_names(&paths)?;
    let sources = sources(&spec, cmp);
    exposes_user(&sources, &ctx)?;
    closed(&sources, &ctx)?;
    secret_dirs(&sources, &ctx)?;
    session_dirs(&spec, &sources, &ctx, cmp)?;
    program_dirs(&sources, &ctx)?;
    missing(&sources, &absent)?;
    malformed(&spec, target)?;
    env_denied(&spec, ctx.env_deny)?;
    dests_differ(&spec, target)?;
    reserved_dests(&spec, cmp)?;
    drop_absent(&mut spec, &absent);
    Ok(ValidSpec::new(spec, target, Checked(())))
}

fn refusal(rule: Rule, path: Option<&Path>, message: String) -> Refusal {
    Refusal {
        rule,
        path: path.map(Path::to_path_buf),
        message,
    }
}

/// How paths compare for a target. macOS file systems ignore case, so there both sides are lowercased: a check
/// can then only refuse more, never less.
#[derive(Clone, Copy)]
struct Cmp {
    fold: bool,
}

impl Cmp {
    /// `p` as compared: valid UTF-8 by the time this is called (rule 1, or `prepare`).
    fn norm(self, p: &Path) -> String {
        let s = p.to_string_lossy();
        if self.fold {
            s.to_lowercase()
        } else {
            s.into_owned()
        }
    }
}

/// Is `p` `dir` or inside it? Both in canonical form, so a component-wise prefix is the whole answer.
fn within(p: &str, dir: &str) -> bool {
    Path::new(p).starts_with(dir)
}

/// Is `p` strictly inside `dir`?
fn under(p: &str, dir: &str) -> bool {
    p != dir && within(p, dir)
}

/// Why `p` is not an absolute path in canonical form, or None. Lexical only: nothing is looked up.
fn form_problem(p: &Path) -> Option<(Rule, String)> {
    let Some(s) = p.to_str() else {
        return Some((Rule::NotUtf8, "is not UTF-8".into()));
    };
    if s.contains(['\0', '\n']) {
        return Some((Rule::NotCanonical, "holds a NUL or a newline".into()));
    }
    if !s.starts_with('/') {
        return Some((Rule::NotCanonical, "is not absolute".into()));
    }
    if s != "/"
        && !s[1..]
            .split('/')
            .all(|c| !c.is_empty() && c != "." && c != "..")
    {
        return Some((
            Rule::NotCanonical,
            "is not in canonical form (a `//`, a `.` or `..` component, or a trailing slash)"
                .into(),
        ));
    }
    None
}

/// The context, checked and in compared form. The closed dirs of the context and the system's are kept apart:
/// only the context's own can be opened by `open_inside_closed`.
struct Ctx<'a> {
    home: String,
    secret: Vec<String>,
    closed: Vec<String>,
    system: Vec<String>,
    open: Vec<String>,
    user_sockets: Vec<String>,
    run_parents: Vec<String>,
    program_dirs: Vec<String>,
    env_deny: &'a [String],
}

fn prepare(ctx: &Context, cmp: Cmp, target: Target) -> Result<Ctx<'_>, Refusal> {
    let lists: [(&str, &[PathBuf]); 6] = [
        ("home", std::slice::from_ref(&ctx.home)),
        ("closed", &ctx.closed),
        ("open_inside_closed", &ctx.open_inside_closed),
        ("user_sockets", &ctx.user_sockets),
        ("run_parents", &ctx.run_parents),
        ("program_dirs", &ctx.program_dirs),
    ];
    let mut named = Vec::new();
    for (key, list) in lists {
        for (i, p) in list.iter().enumerate() {
            if let Some((_, why)) = form_problem(p) {
                let msg = format!("the context's {key}: {} {why}", p.display());
                return Err(refusal(Rule::Malformed, Some(p.as_path()), msg));
            }
            named.push(Named {
                key: format!("the context's {key}[{i}]"),
                path: p,
                host: true,
            });
        }
    }
    // True names on disk too (GL-T2-2): a home or closed dir given through a link would weaken every prefix rule.
    // One that does not exist needs a true-named deepest existing ancestor, as a spec's paths do.
    true_names(&named).map_err(|r| Refusal {
        rule: Rule::Malformed,
        ..r
    })?;
    let norm = |list: &[PathBuf]| list.iter().map(|p| cmp.norm(p)).collect::<Vec<_>>();
    Ok(Ctx {
        home: cmp.norm(&ctx.home),
        secret: target
            .secret_dirs()
            .map(|d| cmp.norm(&ctx.home.join(d)))
            .collect(),
        closed: norm(&ctx.closed),
        system: SYSTEM_CLOSED
            .iter()
            .map(|d| cmp.norm(Path::new(d)))
            .collect(),
        open: norm(&ctx.open_inside_closed),
        user_sockets: norm(&ctx.user_sockets),
        run_parents: norm(&ctx.run_parents),
        program_dirs: norm(&ctx.program_dirs),
        env_deny: &ctx.env_deny,
    })
}

/// A path of the spec, named for messages. A host path is looked up (rule 1's true name); an inside path is the
/// name of a place in bwrap's new root, which is not the host's, so only its form is checked.
struct Named<'a> {
    key: String,
    path: &'a Path,
    host: bool,
}

/// Does the target run without a mount namespace, so that inside paths are host paths?
fn no_mounts(target: Target) -> bool {
    matches!(target, Target::LinuxReduced | Target::Macos)
}

/// The spec's binds with their names: `binds[i]`, `home`, `run`.
fn named_binds(spec: &Spec) -> impl Iterator<Item = (String, &Bind)> {
    let binds = spec.binds.iter().enumerate();
    let binds = binds.map(|(i, b)| (format!("binds[{i}]"), b));
    let home = spec.home.iter().map(|b| ("home".to_owned(), b));
    let run = spec.run.iter().map(|b| ("run".to_owned(), b));
    binds.chain(home).chain(run)
}

fn all_paths(spec: &Spec, target: Target) -> Vec<Named<'_>> {
    fn named(key: String, path: &Path, host: bool) -> Named<'_> {
        Named { key, path, host }
    }
    let mut out = Vec::new();
    let inside_is_host = no_mounts(target);
    for (name, list) in [
        ("read", &spec.read),
        ("write", &spec.write),
        ("hide", &spec.hide),
        ("sockets", &spec.sockets),
    ] {
        for (i, p) in list.iter().enumerate() {
            out.push(named(format!("{name}[{i}]"), p, true));
        }
    }
    for (name, b) in named_binds(spec) {
        out.push(named(format!("{name}.source"), &b.source, true));
        out.push(named(format!("{name}.dest"), &b.dest, inside_is_host));
    }
    if let Some(t) = &spec.tmp {
        out.push(named("tmp".into(), t, true));
    }
    out.push(named("chdir".into(), &spec.chdir, inside_is_host));
    if let Net::Isolated { relay, .. } = &spec.net {
        for (i, r) in relay.iter().enumerate() {
            out.push(named(
                format!("net.relay[{i}].socket"),
                &r.socket,
                inside_is_host,
            ));
        }
    }
    out
}

/// Rule 1, its form: every path is UTF-8, absolute, without NUL or newline, and in canonical form.
fn forms(paths: &[Named<'_>]) -> Result<(), Refusal> {
    for n in paths {
        if let Some((rule, why)) = form_problem(n.path) {
            let msg = format!("{}: {} {why}", n.key, n.path.display());
            return Err(refusal(rule, Some(n.path), msg));
        }
    }
    Ok(())
}

/// Rule 1, its true name: a host path that exists equals its `canonicalize`, so a link anywhere in it is refused.
/// One that does not exist has a deepest existing ancestor, which must equal its own (a link above a missing tail
/// would otherwise widen every prefix check). Returns the host paths that do not exist.
fn true_names(paths: &[Named<'_>]) -> Result<HashSet<PathBuf>, Refusal> {
    let mut absent = HashSet::new();
    for n in paths.iter().filter(|n| n.host) {
        let mut probe = n.path;
        loop {
            match fs::symlink_metadata(probe) {
                Ok(_) => break,
                Err(e) if is_absent(&e) => {
                    absent.insert(n.path.to_path_buf());
                    // Absolute and canonical: the walk ends at `/`, which exists.
                    let Some(up) = probe.parent() else { break };
                    probe = up;
                }
                Err(e) => {
                    let msg = format!("{}: {} cannot be looked up ({e})", n.key, n.path.display());
                    return Err(refusal(Rule::NotCanonical, Some(n.path), msg));
                }
            }
        }
        match fs::canonicalize(probe) {
            Ok(true_name) if true_name == probe => {}
            Ok(true_name) => {
                let what = if probe == n.path {
                    "it"
                } else {
                    "its existing part"
                };
                let msg = format!(
                    "{}: {} is not its own true name: {what} resolves to {} (a link)",
                    n.key,
                    n.path.display(),
                    true_name.display()
                );
                return Err(refusal(Rule::NotCanonical, Some(n.path), msg));
            }
            Err(e) => {
                let msg = format!(
                    "{}: {} does not resolve ({e}; a dangling link or a loop)",
                    n.key,
                    n.path.display()
                );
                return Err(refusal(Rule::NotCanonical, Some(n.path), msg));
            }
        }
    }
    Ok(absent)
}

fn is_absent(e: &io::Error) -> bool {
    matches!(
        e.kind(),
        io::ErrorKind::NotFound | io::ErrorKind::NotADirectory
    )
}

/// `read` and `hide` entries that do not exist are left out: there is nothing to bind or to hide.
fn drop_absent(spec: &mut Spec, absent: &HashSet<PathBuf>) {
    spec.read.retain(|p| !absent.contains(p));
    spec.hide.retain(|p| !absent.contains(p));
}

/// A path bound from outside: what rules 2 to 7 look at.
struct Source<'a> {
    key: String,
    path: &'a Path,
    /// As compared.
    cmp: String,
    /// Read-write (rule 6).
    writable: bool,
    /// Must exist (rule 7).
    must_exist: bool,
    /// `run`'s source (rules 3 and 5).
    run: bool,
}

fn sources(spec: &Spec, cmp: Cmp) -> Vec<Source<'_>> {
    // (writable, must_exist, run)
    const READ: (bool, bool, bool) = (false, false, false);
    const WRITE: (bool, bool, bool) = (true, true, false);
    let mut rows: Vec<(String, &PathBuf, (bool, bool, bool))> = Vec::new();
    for (i, p) in spec.read.iter().enumerate() {
        rows.push((format!("read[{i}]"), p, READ));
    }
    for (i, p) in spec.write.iter().enumerate() {
        rows.push((format!("write[{i}]"), p, WRITE));
    }
    for (i, b) in spec.binds.iter().enumerate() {
        let rw = b.mode == Mode::Rw;
        rows.push((format!("binds[{i}].source"), &b.source, (rw, true, false)));
    }
    if let Some(h) = &spec.home {
        rows.push(("home.source".into(), &h.source, WRITE));
    }
    if let Some(r) = &spec.run {
        rows.push(("run.source".into(), &r.source, (false, true, true)));
    }
    if let Some(t) = &spec.tmp {
        rows.push(("tmp".into(), t, (true, false, false)));
    }
    rows.into_iter()
        .map(|(key, path, (writable, must_exist, run))| Source {
            cmp: cmp.norm(path),
            key,
            path,
            writable,
            must_exist,
            run,
        })
        .collect()
}

/// Rule 2: no source is, or holds, the home, a user's socket, or a closed dir. Read-only counts too: a read of `~`
/// is every key in it.
fn exposes_user(sources: &[Source<'_>], ctx: &Ctx<'_>) -> Result<(), Refusal> {
    let never = std::iter::once((&ctx.home, "your home"))
        .chain(ctx.user_sockets.iter().map(|s| (s, "a socket of yours")))
        .chain(ctx.closed.iter().map(|d| (d, "a closed directory")))
        .chain(ctx.system.iter().map(|d| (d, "a closed system directory")));
    for (what, why) in never {
        if let Some(s) = sources.iter().find(|s| within(what, &s.cmp)) {
            let msg = format!(
                "{}: {} would expose {why} ({what})",
                s.key,
                s.path.display()
            );
            return Err(refusal(Rule::ExposesUser, Some(s.path), msg));
        }
    }
    Ok(())
}

/// Is `s` the source of `run` and one session's dir: a direct child of a run parent?
fn is_session_dir(s: &Source<'_>, ctx: &Ctx<'_>) -> bool {
    s.run
        && Path::new(&s.cmp)
            .parent()
            .is_some_and(|up| ctx.run_parents.iter().any(|r| Path::new(r) == up))
}

/// Rule 3: no source lies inside a closed dir, unless it lies inside an `open_inside_closed` entry that is itself
/// inside that closed dir. A system dir opens for nothing; `run`, one session's dir, is rule 5's.
fn closed(sources: &[Source<'_>], ctx: &Ctx<'_>) -> Result<(), Refusal> {
    for s in sources.iter().filter(|s| !is_session_dir(s, ctx)) {
        for d in &ctx.closed {
            let opened = ctx.open.iter().any(|o| under(o, d) && under(&s.cmp, o));
            if under(&s.cmp, d) && !opened {
                let msg = format!(
                    "{}: {} is inside a closed directory ({d})",
                    s.key,
                    s.path.display()
                );
                return Err(refusal(Rule::Closed, Some(s.path), msg));
            }
        }
        if let Some(d) = ctx.system.iter().find(|d| under(&s.cmp, d)) {
            let msg = format!(
                "{}: {} is inside a closed system directory ({d})",
                s.key,
                s.path.display()
            );
            return Err(refusal(Rule::Closed, Some(s.path), msg));
        }
    }
    Ok(())
}

/// Rule 4: no source is, holds or lies inside a secret dir of the home (`.ssh`, `.config/gh`, …; macOS adds
/// `Library/…`).
fn secret_dirs(sources: &[Source<'_>], ctx: &Ctx<'_>) -> Result<(), Refusal> {
    for s in sources {
        if let Some(d) = ctx
            .secret
            .iter()
            .find(|d| within(&s.cmp, d) || within(d, &s.cmp))
        {
            let msg = format!(
                "{}: {} would expose credentials ({d})",
                s.key,
                s.path.display()
            );
            return Err(refusal(Rule::SecretDir, Some(s.path), msg));
        }
    }
    Ok(())
}

/// Rule 5: `run` is one session's dir; nothing else touches a sessions dir (not even a sub-path of `run`, which a
/// live agent could swap for a link); every socket lies inside `run`.
fn session_dirs(
    spec: &Spec,
    sources: &[Source<'_>],
    ctx: &Ctx<'_>,
    cmp: Cmp,
) -> Result<(), Refusal> {
    for s in sources {
        if s.run {
            if !is_session_dir(s, ctx) {
                let msg = format!(
                    "{}: {} is not one session's dir (a direct child of a run parent)",
                    s.key,
                    s.path.display()
                );
                return Err(refusal(Rule::SessionDir, Some(s.path), msg));
            }
        } else if let Some(r) = ctx
            .run_parents
            .iter()
            .find(|r| within(&s.cmp, r) || within(r, &s.cmp))
        {
            let msg = format!(
                "{}: {} touches the session dirs in {r}",
                s.key,
                s.path.display()
            );
            return Err(refusal(Rule::SessionDir, Some(s.path), msg));
        }
    }
    let run = spec.run.as_ref().map(|r| cmp.norm(&r.source));
    for (i, p) in spec.sockets.iter().enumerate() {
        if !run.as_ref().is_some_and(|r| under(&cmp.norm(p), r)) {
            let msg = format!("sockets[{i}]: {} is not inside run's source", p.display());
            return Err(refusal(Rule::SessionDir, Some(p.as_path()), msg));
        }
    }
    Ok(())
}

/// Rule 6: no writable source is or holds a dir of the caller's PATH, where the agent could plant a `bwrap` or a
/// `git` that the caller would then run outside any sandbox.
fn program_dirs(sources: &[Source<'_>], ctx: &Ctx<'_>) -> Result<(), Refusal> {
    for s in sources.iter().filter(|s| s.writable) {
        if let Some(d) = ctx.program_dirs.iter().find(|d| within(d, &s.cmp)) {
            let msg = format!(
                "{}: {} would let the sandbox change {d}, where programs are found",
                s.key,
                s.path.display()
            );
            return Err(refusal(Rule::ProgramDir, Some(s.path), msg));
        }
    }
    Ok(())
}

/// Rule 7: `write`, `binds`, `home` and `run` sources exist.
fn missing(sources: &[Source<'_>], absent: &HashSet<PathBuf>) -> Result<(), Refusal> {
    if let Some(s) = sources
        .iter()
        .find(|s| s.must_exist && absent.contains(s.path))
    {
        let msg = format!("{}: {} does not exist", s.key, s.path.display());
        return Err(refusal(Rule::Missing, Some(s.path), msg));
    }
    Ok(())
}

fn is_env_name(n: &str) -> bool {
    let mut b = n.bytes();
    b.next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == b'_')
        && b.all(|c| c.is_ascii_alphanumeric() || c == b'_')
}

/// Rule 8: names, ports, the Landlock floors and what a target cannot honour.
fn malformed(spec: &Spec, target: Target) -> Result<(), Refusal> {
    let bad = |msg: String| Err(refusal(Rule::Malformed, None, msg));
    for (name, value) in &spec.env {
        if !is_env_name(name) {
            return bad(format!(
                "env: {name:?} is not a variable name ([A-Za-z_][A-Za-z0-9_]*)"
            ));
        }
        if value.contains('\0') {
            return bad(format!("env: the value of {name} holds a NUL"));
        }
    }
    let (relay, mac_ports): (&[RelayPort], &[u16]) = match &spec.net {
        Net::Shared => (&[], &[]),
        Net::Isolated {
            relay,
            mac_tcp_ports,
        } => (relay, mac_tcp_ports),
    };
    let ports = spec.extra_tcp_ports.iter().chain(mac_ports);
    if relay.iter().map(|r| &r.port).chain(ports).any(|&p| p == 0) {
        return bad("a port is 0".into());
    }
    let abi = spec.layers.landlock_min_abi;
    if abi > LANDLOCK_ABI_MAX {
        return bad(format!(
            "layers.landlock_min_abi {abi} is above {LANDLOCK_ABI_MAX}, the highest Landlock ABI gleipnir knows"
        ));
    }
    if target == Target::Macos && abi != 0 {
        return bad(format!(
            "layers.landlock_min_abi {abi}: macOS has no Landlock"
        ));
    }
    let floor = target.landlock_floor();
    if abi < floor {
        return bad(format!(
            "layers.landlock_min_abi {abi} is below {floor}, the floor of {target:?}"
        ));
    }
    let linux = target != Target::Macos;
    if linux && matches!(spec.net, Net::Isolated { .. }) && relay.is_empty() {
        return bad("net: isolated without a relay on Linux".into());
    }
    if linux && !mac_ports.is_empty() {
        return bad("net: mac_tcp_ports on Linux".into());
    }
    if target == Target::LinuxReduced && spec.tmp.is_none() {
        return bad("tmp: the reduced tier has no private /tmp, so its spec needs a tmp".into());
    }
    if spec.run.as_ref().is_some_and(|r| r.mode == Mode::Rw) {
        return bad("run: the session dir is bound read-only; its mode must be ro".into());
    }
    Ok(())
}

/// Rule 9: names never passed into a sandbox.
fn env_denied(spec: &Spec, extra: &[String]) -> Result<(), Refusal> {
    for (name, _) in &spec.env {
        if BASE_ENV_DENY.contains(&name.as_str()) || extra.contains(name) {
            let msg = format!("env: {name} is never passed into a sandbox");
            return Err(refusal(Rule::EnvDenied, None, msg));
        }
    }
    Ok(())
}

/// Rule 10: without a mount namespace a path is seen where it is, so every bind's, the home's and run's dest is
/// its source.
fn dests_differ(spec: &Spec, target: Target) -> Result<(), Refusal> {
    if !no_mounts(target) {
        return Ok(());
    }
    if let Some((key, b)) = named_binds(spec).find(|(_, b)| b.dest != b.source) {
        let msg = format!(
            "{key}: dest {} differs from source {}; {target:?} has no mount namespace",
            b.dest.display(),
            b.source.display()
        );
        return Err(refusal(Rule::DestDiffers, Some(b.dest.as_path()), msg));
    }
    Ok(())
}

/// Rule 11: nothing is mounted at, above or under the helper's place, a reserved dest or run's dest, so no bind can
/// cover the helper (bwrap would then exec a program that applies neither Landlock nor seccomp) or the session's
/// sockets. `read`, `write`, `hide` and `tmp` are mounted at their own path, so they count as dests too.
fn reserved_dests(spec: &Spec, cmp: Cmp) -> Result<(), Refusal> {
    let reserved: Vec<String> = std::iter::once(HELPER_INSIDE)
        .chain(RESERVED_DESTS.iter().copied())
        .map(|d| cmp.norm(Path::new(d)))
        .collect();
    let clash = |p: &Path, list: &[String]| {
        let p = cmp.norm(p);
        list.iter()
            .find(|r| within(&p, r) || within(r, &p))
            .cloned()
    };
    if let Some(run) = &spec.run
        && let Some(r) = clash(&run.dest, &reserved)
    {
        let msg = format!("run.dest: {} is at, above or under {r}", run.dest.display());
        return Err(refusal(Rule::ReservedDest, Some(run.dest.as_path()), msg));
    }
    let reserved: Vec<String> = reserved
        .into_iter()
        .chain(spec.run.iter().map(|r| cmp.norm(&r.dest)))
        .collect();
    let lists = [
        ("read", &spec.read),
        ("write", &spec.write),
        ("hide", &spec.hide),
    ];
    let same_path = lists
        .into_iter()
        .flat_map(|(name, l)| {
            l.iter()
                .enumerate()
                .map(move |(i, p)| (format!("{name}[{i}]"), p))
        })
        .chain(spec.tmp.iter().map(|t| ("tmp".to_owned(), t)));
    let dests = named_binds(spec)
        .filter(|(key, _)| key != "run")
        .map(|(key, b)| (format!("{key}.dest"), &b.dest));
    for (key, p) in same_path.chain(dests) {
        if let Some(r) = clash(p, &reserved) {
            let msg = format!("{key}: {} is at, above or under {r}", p.display());
            return Err(refusal(Rule::ReservedDest, Some(p.as_path()), msg));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::{BASE_ENV_DENY, Bind, Layers, Mode, Net, RelayPort};
    use std::ffi::OsStr;
    use std::fs;
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;

    /// A tree under /tmp/glp-XXXXXX that stands for a user's machine:
    ///
    /// - `home/u`: the user's home, with `proj` (a task folder), `.ssh`, `.config/gh`, `go/bin` (on PATH);
    /// - `state` (closed): `sandbox/J1` is this job's dir (open), `sandbox/J2` another job's, `sandbox/folders.eld`;
    /// - `rt` (closed, the runtime dir): `drgnx/s` is a run parent inside it, `S1` this session's dir;
    /// - `x/sess`: a run parent in no closed dir (so the session rule is seen on its own), with `S2`, `S3`;
    /// - `agent/agent.1`: the ssh agent's socket; `other`: a folder of nobody's.
    struct Fx {
        _dir: tempfile::TempDir,
        b: PathBuf,
    }

    impl Fx {
        fn new() -> Fx {
            let dir = tempfile::Builder::new().prefix("glp-").tempdir().unwrap();
            let b = fs::canonicalize(dir.path()).unwrap();
            for d in [
                "home/u/proj/docs",
                "home/u/.ssh",
                "home/u/.config/gh",
                "home/u/go/bin",
                "home/u/Library/Keychains",
                "state/sandbox/J1/home-1",
                "state/sandbox/J1/tmp",
                "state/sandbox/J2/home-1",
                "rt/drgnx/s/S1",
                "x/sess/S2",
                "x/sess/S3/out",
                "agent",
                "other",
            ] {
                fs::create_dir_all(b.join(d)).unwrap();
            }
            for f in [
                "home/u/proj/.env",
                "home/u/.ssh/id_ed25519",
                "state/sandbox/folders.eld",
                "rt/drgnx/s/S1/proxy.sock",
                "x/sess/S3/proxy.sock",
                "agent/agent.1",
            ] {
                fs::write(b.join(f), "x").unwrap();
            }
            Fx { _dir: dir, b }
        }

        fn p(&self, rel: &str) -> PathBuf {
            self.b.join(rel)
        }

        fn ctx(&self) -> Context {
            Context {
                home: self.p("home/u"),
                closed: vec![self.p("state"), self.p("rt")],
                open_inside_closed: vec![self.p("state/sandbox/J1")],
                user_sockets: vec![self.p("agent/agent.1")],
                run_parents: vec![self.p("rt/drgnx/s"), self.p("x/sess")],
                program_dirs: vec![self.p("home/u/go/bin"), "/usr/bin".into()],
                env_deny: vec!["DRGNX_AGENT".into()],
            }
        }

        /// A spec that passes for `target`, every field set.
        fn spec(&self, target: Target) -> Spec {
            let same = !matches!(target, Target::LinuxBwrap);
            let bind = |mode, src: PathBuf, dest: &str| Bind {
                mode,
                dest: if same { src.clone() } else { dest.into() },
                source: src,
            };
            let net = match target {
                Target::Macos => Net::Isolated {
                    relay: vec![],
                    mac_tcp_ports: vec![3128],
                },
                _ => Net::Isolated {
                    relay: vec![RelayPort {
                        port: 3128,
                        socket: if same {
                            self.p("rt/drgnx/s/S1/proxy.sock")
                        } else {
                            "/run/drgnx/proxy.sock".into()
                        },
                    }],
                    mac_tcp_ports: vec![],
                },
            };
            Spec {
                read: vec![self.p("home/u/proj/docs")],
                write: vec![self.p("home/u/proj")],
                hide: vec![self.p("home/u/proj/.env")],
                sockets: vec![self.p("rt/drgnx/s/S1/proxy.sock")],
                binds: vec![bind(Mode::Ro, self.p("other"), "/mnt/other")],
                home: Some(bind(
                    Mode::Rw,
                    self.p("state/sandbox/J1/home-1"),
                    "/home/agent",
                )),
                run: Some(bind(Mode::Ro, self.p("rt/drgnx/s/S1"), "/run/drgnx")),
                env: vec![
                    ("PATH".into(), "/usr/bin".into()),
                    ("LANG".into(), "C.UTF-8".into()),
                ],
                chdir: self.p("home/u/proj"),
                net,
                tmp: Some(self.p("state/sandbox/J1/tmp")),
                layers: Layers::for_target(target),
                extra_tcp_ports: vec![8080],
            }
        }
    }

    const TARGETS: [Target; 3] = [Target::LinuxBwrap, Target::LinuxReduced, Target::Macos];

    /// Validate `spec` for `target`; it must be refused by `rule`. Names the row on failure.
    fn refused(fx: &Fx, row: &str, target: Target, spec: Spec, rule: Rule) {
        match validate(spec, &fx.ctx(), target) {
            Ok(_) => panic!("{row} ({target:?}): accepted, expected {rule:?}"),
            Err(r) => {
                assert_eq!(r.rule, rule, "{row} ({target:?}): {}", r.message);
                assert!(!r.message.is_empty(), "{row}: no message");
            }
        }
    }

    /// The base spec of every target passes, so each refusal below is its row's change (no vacuous oracle).
    fn base_passes(fx: &Fx) {
        for t in TARGETS {
            if let Err(r) = validate(fx.spec(t), &fx.ctx(), t) {
                panic!("the base spec for {t:?} is refused: {r:?}");
            }
        }
    }

    /// Where a source path can go, for tables that try one path in every source key.
    #[derive(Clone, Copy, Debug)]
    enum Key {
        Read,
        Write,
        BindRo,
        BindRw,
        Home,
        Run,
        Tmp,
    }

    const SOURCE_KEYS: [Key; 7] = [
        Key::Read,
        Key::Write,
        Key::BindRo,
        Key::BindRw,
        Key::Home,
        Key::Run,
        Key::Tmp,
    ];

    /// `spec` with `p` as the source of `key` (and as its dest where dests equal sources).
    fn put(mut spec: Spec, key: Key, p: &Path, target: Target) -> Spec {
        let dest = |d: &str| {
            if target == Target::LinuxBwrap {
                PathBuf::from(d)
            } else {
                p.to_path_buf()
            }
        };
        let bind = |mode, d: &str| Bind {
            mode,
            source: p.to_path_buf(),
            dest: dest(d),
        };
        match key {
            Key::Read => spec.read.push(p.into()),
            Key::Write => spec.write.push(p.into()),
            Key::BindRo => spec.binds.push(bind(Mode::Ro, "/mnt/x")),
            Key::BindRw => spec.binds.push(bind(Mode::Rw, "/mnt/x")),
            Key::Home => spec.home = Some(bind(Mode::Rw, "/home/agent")),
            Key::Run => {
                spec.run = Some(bind(Mode::Ro, "/run/drgnx"));
                spec.sockets.clear();
                if let Net::Isolated { relay, .. } = &mut spec.net {
                    for r in relay.iter_mut().filter(|_| target != Target::LinuxBwrap) {
                        r.socket = p.join("proxy.sock");
                    }
                }
            }
            Key::Tmp => spec.tmp = Some(p.into()),
        }
        spec
    }

    #[test]
    fn hostile_paths_table() {
        let fx = Fx::new();
        base_passes(&fx);
        fs::create_dir_all(fx.p("other/a b")).unwrap();
        fs::create_dir_all(fx.p("other/q\"x\\y")).unwrap();
        std::os::unix::fs::symlink(fx.p("other"), fx.p("lnk")).unwrap();
        let s = |rel: &str| format!("{}/{rel}", fx.b.display());
        let rows: Vec<(&str, PathBuf, Option<Rule>)> = vec![
            ("a space", s("other/a b").into(), None),
            ("a quote and a backslash", s("other/q\"x\\y").into(), None),
            (
                "a newline",
                s("other/a\nb").into(),
                Some(Rule::NotCanonical),
            ),
            ("a NUL", s("other/a\0b").into(), Some(Rule::NotCanonical)),
            (
                "// in front",
                format!("/{}", s("other")).into(),
                Some(Rule::NotCanonical),
            ),
            (
                "// inside",
                s("other//a b").into(),
                Some(Rule::NotCanonical),
            ),
            (
                "a . component",
                s("other/./a b").into(),
                Some(Rule::NotCanonical),
            ),
            (
                "a .. component",
                s("other/../other").into(),
                Some(Rule::NotCanonical),
            ),
            (
                "a trailing slash",
                s("other/").into(),
                Some(Rule::NotCanonical),
            ),
            ("relative", "other/a b".into(), Some(Rule::NotCanonical)),
            ("empty", "".into(), Some(Rule::NotCanonical)),
            (
                "a link component",
                s("lnk/a b").into(),
                Some(Rule::NotCanonical),
            ),
            ("a link itself", s("lnk").into(), Some(Rule::NotCanonical)),
            (
                "a link under an absent tail",
                s("lnk/nope/deeper").into(),
                Some(Rule::NotCanonical),
            ),
            (
                "non-UTF-8 bytes",
                PathBuf::from(OsStr::from_bytes(b"/t/\xff")),
                Some(Rule::NotUtf8),
            ),
        ];
        // `run` must be a session's dir, so its rows live in a sessions dir (x/sess), through the link `lnks`.
        fs::create_dir_all(fx.p("x/sess/a b")).unwrap();
        fs::create_dir_all(fx.p("x/sess/q\"x\\y")).unwrap();
        std::os::unix::fs::symlink(fx.p("x/sess"), fx.p("lnks")).unwrap();
        let run_rows: Vec<(&str, PathBuf, Option<Rule>)> = vec![
            ("a space", s("x/sess/a b").into(), None),
            ("a quote and a backslash", s("x/sess/q\"x\\y").into(), None),
            (
                "// inside",
                s("x/sess//a b").into(),
                Some(Rule::NotCanonical),
            ),
            (
                "a .. component",
                s("x/sess/../sess/a b").into(),
                Some(Rule::NotCanonical),
            ),
            (
                "a link component",
                s("lnks/a b").into(),
                Some(Rule::NotCanonical),
            ),
            (
                "non-UTF-8 bytes",
                PathBuf::from(OsStr::from_bytes(b"/t/\xff")),
                Some(Rule::NotUtf8),
            ),
        ];
        for t in TARGETS {
            let cases = SOURCE_KEYS
                .iter()
                .filter(|k| !matches!(k, Key::Run))
                .flat_map(|k| rows.iter().map(move |r| (*k, r)))
                .chain(run_rows.iter().map(|r| (Key::Run, r)));
            for (key, (row, p, want)) in cases {
                let spec = put(fx.spec(t), key, p, t);
                let got = validate(spec, &fx.ctx(), t).map(|_| ()).map_err(|r| r.rule);
                assert_eq!(got, want.map_or(Ok(()), Err), "{row} as {key:?} ({t:?})");
            }
        }
        // Paths that are not sources follow the form rules too: hide, sockets, chdir, dests, relay sockets.
        let bad: PathBuf = s("other/../other").into();
        let t = Target::LinuxBwrap;
        let rows: Vec<(&str, Spec)> = vec![
            ("hide", {
                let mut x = fx.spec(t);
                x.hide.push(bad.clone());
                x
            }),
            ("sockets", {
                let mut x = fx.spec(t);
                x.sockets.push(bad.clone());
                x
            }),
            (
                "chdir",
                Spec {
                    chdir: "/w/".into(),
                    ..fx.spec(t)
                },
            ),
            ("bind dest", {
                let mut x = fx.spec(t);
                x.binds[0].dest = "/mnt//x".into();
                x
            }),
            ("home dest", {
                let mut x = fx.spec(t);
                x.home.as_mut().unwrap().dest = "home/agent".into();
                x
            }),
            ("run dest", {
                let mut x = fx.spec(t);
                x.run.as_mut().unwrap().dest = "/run/./drgnx".into();
                x
            }),
            ("relay socket", {
                let mut x = fx.spec(t);
                let Net::Isolated { relay, .. } = &mut x.net else {
                    unreachable!()
                };
                relay[0].socket = "/run/drgnx/\nproxy.sock".into();
                x
            }),
        ];
        for (row, spec) in rows {
            refused(&fx, row, t, spec, Rule::NotCanonical);
        }
    }

    /// A bind dest is a path inside: under bwrap it is not looked up on the host (a fresh root), so a dest whose
    /// host twin is a link (Silverblue's /home) passes. Without a mount namespace it must equal its source.
    #[test]
    fn bwrap_dests_are_not_host_paths() {
        let fx = Fx::new();
        std::os::unix::fs::symlink(fx.p("other"), fx.p("lnk")).unwrap();
        let mut spec = fx.spec(Target::LinuxBwrap);
        spec.home.as_mut().unwrap().dest = fx.p("lnk/agent");
        spec.chdir = fx.p("lnk/agent");
        validate(spec, &fx.ctx(), Target::LinuxBwrap).unwrap();
        let mut spec = fx.spec(Target::LinuxReduced);
        spec.chdir = fx.p("lnk");
        refused(
            &fx,
            "chdir through a link",
            Target::LinuxReduced,
            spec,
            Rule::NotCanonical,
        );
    }

    #[test]
    fn home_through_a_link_is_refused() {
        // SB-T3-2: /home → /var/home. The caller passes the true name; a spec through the link is refused.
        let fx = Fx::new();
        base_passes(&fx);
        fs::create_dir_all(fx.p("var/hm/v/proj")).unwrap();
        std::os::unix::fs::symlink(fx.p("var/hm"), fx.p("vhm")).unwrap();
        let ctx = Context {
            home: fx.p("var/hm/v"),
            ..fx.ctx()
        };
        for t in TARGETS {
            let mut spec = fx.spec(t);
            spec.write = vec![fx.p("var/hm/v/proj")];
            validate(spec.clone(), &ctx, t).expect("the true name passes");
            spec.write = vec![fx.p("vhm/v/proj")];
            let r = validate(spec, &ctx, t).unwrap_err();
            assert_eq!(r.rule, Rule::NotCanonical, "{t:?}: {}", r.message);
            assert_eq!(r.path, Some(fx.p("vhm/v/proj")));
        }
    }

    #[test]
    fn never_home_runtime_or_their_parents() {
        let fx = Fx::new();
        base_passes(&fx);
        let rows = [
            ("the home", fx.p("home/u"), Rule::ExposesUser),
            ("/", PathBuf::from("/"), Rule::ExposesUser),
            ("the home's parent", fx.p("home"), Rule::ExposesUser),
            (
                "/run/user/1000",
                PathBuf::from("/run/user/1000"),
                Rule::Closed,
            ),
            ("/run", PathBuf::from("/run"), Rule::ExposesUser),
            ("/proc/sys", PathBuf::from("/proc/sys"), Rule::Closed),
            ("a closed entry", fx.p("rt"), Rule::ExposesUser),
            ("inside a closed entry", fx.p("rt/drgnx"), Rule::Closed),
        ];
        for t in TARGETS {
            for (row, p, rule) in &rows {
                for key in SOURCE_KEYS {
                    refused(
                        &fx,
                        &format!("{row} as {key:?}"),
                        t,
                        put(fx.spec(t), key, p, t),
                        *rule,
                    );
                }
            }
        }
    }

    #[test]
    fn ssh_agent_socket_dir_refused() {
        let fx = Fx::new();
        base_passes(&fx);
        for t in TARGETS {
            for p in [fx.p("agent"), fx.p("agent/agent.1")] {
                for key in SOURCE_KEYS {
                    refused(
                        &fx,
                        &format!("{p:?} as {key:?}"),
                        t,
                        put(fx.spec(t), key, &p, t),
                        Rule::ExposesUser,
                    );
                }
            }
        }
    }

    #[test]
    fn secret_dirs_refused() {
        let fx = Fx::new();
        base_passes(&fx);
        let t = Target::LinuxBwrap;
        for (row, p) in [
            ("~/.ssh", fx.p("home/u/.ssh")),
            ("a key in it", fx.p("home/u/.ssh/id_ed25519")),
            ("~/.config/gh", fx.p("home/u/.config/gh")),
            ("~/.config, which holds gh", fx.p("home/u/.config")),
        ] {
            let mut spec = fx.spec(t);
            spec.read.push(p);
            refused(&fx, row, t, spec, Rule::SecretDir);
        }
        // macOS adds Library/…; the target decides, not the host.
        let mut spec = fx.spec(Target::LinuxBwrap);
        spec.read.push(fx.p("home/u/Library/Keychains"));
        validate(spec, &fx.ctx(), Target::LinuxBwrap).expect("not a secret dir on Linux");
        let mut spec = fx.spec(Target::Macos);
        spec.read.push(fx.p("home/u/Library/Keychains"));
        refused(
            &fx,
            "~/Library/Keychains",
            Target::Macos,
            spec,
            Rule::SecretDir,
        );
    }

    /// APFS ignores case, so on macOS `~/.SSH` is `~/.ssh`: comparisons fold case for that target.
    #[test]
    fn macos_compares_without_case() {
        let fx = Fx::new();
        let ctx = Context {
            home: fx.p("home/U"),
            ..fx.ctx()
        };
        let mut spec = fx.spec(Target::Macos);
        spec.write.push(fx.p("home"));
        assert_eq!(
            validate(spec, &ctx, Target::Macos).unwrap_err().rule,
            Rule::ExposesUser
        );
        fs::create_dir_all(fx.p("home/u/.SSH")).unwrap();
        let mut spec = fx.spec(Target::Macos);
        spec.read.push(fx.p("home/u/.SSH"));
        refused(&fx, "~/.SSH", Target::Macos, spec, Rule::SecretDir);
    }

    #[test]
    fn only_this_jobs_dir_opens_the_state_dir() {
        // SB-T3-6: the state dir is closed; only what lies inside this job's dir may be bound.
        let fx = Fx::new();
        base_passes(&fx);
        for t in TARGETS {
            for (row, p, rule) in [
                (
                    "another job's home",
                    fx.p("state/sandbox/J2/home-1"),
                    Rule::Closed,
                ),
                ("another job's dir", fx.p("state/sandbox/J2"), Rule::Closed),
                (
                    "this job's dir itself",
                    fx.p("state/sandbox/J1"),
                    Rule::Closed,
                ),
                (
                    "the registry beside the jobs",
                    fx.p("state/sandbox/folders.eld"),
                    Rule::Closed,
                ),
                ("the sandbox dir", fx.p("state/sandbox"), Rule::Closed),
                ("the state dir", fx.p("state"), Rule::ExposesUser),
            ] {
                refused(&fx, row, t, put(fx.spec(t), Key::BindRw, &p, t), rule);
            }
        }
        // The context opens only its own closed dirs: a system dir stays closed whatever it says.
        let mut ctx = fx.ctx();
        ctx.open_inside_closed.push("/proc/sys".into());
        let t = Target::LinuxBwrap;
        validate(fx.spec(t), &ctx, t).expect("the base passes with this context");
        let spec = put(fx.spec(t), Key::Read, Path::new("/proc/sys/kernel"), t);
        assert_eq!(validate(spec, &ctx, t).unwrap_err().rule, Rule::Closed);
    }

    #[test]
    fn run_must_be_one_session_dir() {
        let fx = Fx::new();
        base_passes(&fx);
        for t in TARGETS {
            let with_run = |src: PathBuf| put(fx.spec(t), Key::Run, &src, t);
            let rows: Vec<(&str, Spec)> = vec![
                (
                    "run: a sub-path of a session dir",
                    with_run(fx.p("x/sess/S3/out")),
                ),
                ("run: the sessions dir itself", with_run(fx.p("x/sess"))),
                ("run: not in a sessions dir", with_run(fx.p("other"))),
                (
                    "read: another session's dir",
                    put(fx.spec(t), Key::Read, &fx.p("x/sess/S2"), t),
                ),
                ("read: a sub-path of this session's dir", {
                    let s = with_run(fx.p("x/sess/S3"));
                    put(s, Key::Read, &fx.p("x/sess/S3/out"), t)
                }),
                (
                    "write: what holds a sessions dir",
                    put(fx.spec(t), Key::Write, &fx.p("x"), t),
                ),
                ("a socket outside run", {
                    let mut s = fx.spec(t);
                    s.sockets.push(fx.p("x/sess/S3/proxy.sock"));
                    s
                }),
                ("a socket without run", {
                    let mut s = fx.spec(t);
                    s.run = None;
                    if let Net::Isolated { relay, .. } = &mut s.net {
                        for r in relay.iter_mut().filter(|_| t != Target::LinuxBwrap) {
                            r.socket = fx.p("other/proxy.sock");
                        }
                    }
                    s
                }),
            ];
            for (row, spec) in rows {
                refused(&fx, row, t, spec, Rule::SessionDir);
            }
            // A session dir in a sessions dir that lies in no closed dir passes too.
            let mut s = with_run(fx.p("x/sess/S3"));
            s.sockets = vec![fx.p("x/sess/S3/proxy.sock")];
            validate(s, &fx.ctx(), t).expect("S3 is one session's dir");
        }
    }

    #[test]
    fn program_dir_never_writable() {
        let fx = Fx::new();
        base_passes(&fx);
        for t in TARGETS {
            for p in [fx.p("home/u/go"), fx.p("home/u/go/bin")] {
                for key in [Key::Write, Key::BindRw, Key::Home, Key::Tmp] {
                    refused(
                        &fx,
                        &format!("{p:?} as {key:?}"),
                        t,
                        put(fx.spec(t), key, &p, t),
                        Rule::ProgramDir,
                    );
                }
                for key in [Key::Read, Key::BindRo] {
                    let spec = put(fx.spec(t), key, &p, t);
                    validate(spec, &fx.ctx(), t).unwrap_or_else(|r| panic!("{key:?} {p:?}: {r:?}"));
                }
            }
        }
    }

    #[test]
    fn missing_write_refused() {
        let fx = Fx::new();
        base_passes(&fx);
        for t in TARGETS {
            for key in [Key::Write, Key::BindRo, Key::BindRw, Key::Home] {
                refused(
                    &fx,
                    &format!("{key:?}"),
                    t,
                    put(fx.spec(t), key, &fx.p("other/nope"), t),
                    Rule::Missing,
                );
            }
            let mut spec = put(fx.spec(t), Key::Run, &fx.p("x/sess/S9"), t);
            spec.sockets.clear();
            refused(&fx, "run", t, spec, Rule::Missing);
            // tmp may be made later.
            validate(
                put(fx.spec(t), Key::Tmp, &fx.p("other/nope"), t),
                &fx.ctx(),
                t,
            )
            .unwrap();
        }
    }

    #[test]
    fn missing_read_dropped() {
        let fx = Fx::new();
        for t in TARGETS {
            let mut spec = fx.spec(t);
            spec.read.insert(0, fx.p("other/nope"));
            spec.hide.insert(0, fx.p("other/gone/deeper"));
            let v = validate(spec, &fx.ctx(), t).unwrap();
            assert_eq!(v.spec().read, vec![fx.p("home/u/proj/docs")], "{t:?}");
            assert_eq!(v.spec().hide, vec![fx.p("home/u/proj/.env")], "{t:?}");
            assert_eq!(v.target(), t);
            // Absent is no excuse: every rule still applies before the drop.
            let mut spec = fx.spec(t);
            spec.read.push(fx.p("rt/drgnx/nope"));
            refused(&fx, "an absent read in a closed dir", t, spec, Rule::Closed);
            let mut spec = fx.spec(t);
            spec.read.push(fx.p("home/u/.aws"));
            refused(&fx, "an absent secret dir", t, spec, Rule::SecretDir);
        }
    }

    #[test]
    fn floors_refused() {
        let fx = Fx::new();
        base_passes(&fx);
        let abi = |t, n| Spec {
            layers: Layers {
                landlock_min_abi: n,
            },
            ..fx.spec(t)
        };
        refused(
            &fx,
            "bwrap, ABI 0",
            Target::LinuxBwrap,
            abi(Target::LinuxBwrap, 0),
            Rule::Malformed,
        );
        refused(
            &fx,
            "reduced, ABI 6",
            Target::LinuxReduced,
            abi(Target::LinuxReduced, 6),
            Rule::Malformed,
        );
        refused(
            &fx,
            "reduced, ABI 8",
            Target::LinuxReduced,
            abi(Target::LinuxReduced, 8),
            Rule::Malformed,
        );
        refused(
            &fx,
            "reduced without tmp",
            Target::LinuxReduced,
            Spec {
                tmp: None,
                ..fx.spec(Target::LinuxReduced)
            },
            Rule::Malformed,
        );
        for t in TARGETS {
            refused(&fx, "ABI 10", t, abi(t, 10), Rule::Malformed);
        }
        refused(
            &fx,
            "macOS asks for Landlock",
            Target::Macos,
            abi(Target::Macos, 1),
            Rule::Malformed,
        );
        for (t, n) in [
            (Target::LinuxBwrap, 1),
            (Target::LinuxBwrap, 9),
            (Target::LinuxReduced, 9),
        ] {
            validate(abi(t, n), &fx.ctx(), t).unwrap_or_else(|r| panic!("{t:?} ABI {n}: {r:?}"));
        }
        validate(
            Spec {
                tmp: None,
                ..fx.spec(Target::LinuxBwrap)
            },
            &fx.ctx(),
            Target::LinuxBwrap,
        )
        .expect("the full tier has a private /tmp");
    }

    #[test]
    fn malformed_net_and_ports() {
        let fx = Fx::new();
        base_passes(&fx);
        for t in [Target::LinuxBwrap, Target::LinuxReduced] {
            let mut s = fx.spec(t);
            s.net = Net::Isolated {
                relay: vec![],
                mac_tcp_ports: vec![],
            };
            refused(&fx, "isolated without a relay", t, s, Rule::Malformed);
            let mut s = fx.spec(t);
            if let Net::Isolated { mac_tcp_ports, .. } = &mut s.net {
                mac_tcp_ports.push(3128);
            }
            refused(&fx, "mac_tcp_ports on Linux", t, s, Rule::Malformed);
            let mut s = fx.spec(t);
            if let Net::Isolated { relay, .. } = &mut s.net {
                relay[0].port = 0;
            }
            refused(&fx, "relay port 0", t, s, Rule::Malformed);
            validate(
                Spec {
                    net: Net::Shared,
                    ..fx.spec(t)
                },
                &fx.ctx(),
                t,
            )
            .expect("shared needs no relay");
        }
        for t in TARGETS {
            refused(
                &fx,
                "extra port 0",
                t,
                Spec {
                    extra_tcp_ports: vec![0],
                    ..fx.spec(t)
                },
                Rule::Malformed,
            );
        }
        let mut s = fx.spec(Target::Macos);
        s.net = Net::Isolated {
            relay: vec![],
            mac_tcp_ports: vec![0],
        };
        refused(&fx, "mac port 0", Target::Macos, s, Rule::Malformed);
    }

    /// Task 0's note: `run` is bound read-only, so a spec asking for it read-write is refused (never widened, never
    /// narrowed in silence). A home asked read-only stays read-only.
    #[test]
    fn run_mode_rw_refused() {
        let fx = Fx::new();
        base_passes(&fx);
        for t in TARGETS {
            let mut s = fx.spec(t);
            s.run.as_mut().unwrap().mode = Mode::Rw;
            refused(&fx, "run rw", t, s, Rule::Malformed);
            let mut s = fx.spec(t);
            s.home.as_mut().unwrap().mode = Mode::Ro;
            let v = validate(s, &fx.ctx(), t).unwrap();
            assert_eq!(v.spec().home.as_ref().unwrap().mode, Mode::Ro);
        }
    }

    #[test]
    fn env_denied_names() {
        let fx = Fx::new();
        base_passes(&fx);
        for t in TARGETS {
            for name in BASE_ENV_DENY.iter().copied().chain(["DRGNX_AGENT"]) {
                let mut s = fx.spec(t);
                s.env.push((name.into(), "x".into()));
                refused(&fx, name, t, s, Rule::EnvDenied);
            }
        }
    }

    #[test]
    fn env_name_shape() {
        let fx = Fx::new();
        base_passes(&fx);
        let t = Target::LinuxBwrap;
        for name in ["", "1A", "A-B", "A=B", "A B", "Ä", "A\0", "PATH\n"] {
            let mut s = fx.spec(t);
            s.env.push((name.into(), "x".into()));
            refused(&fx, &format!("{name:?}"), t, s, Rule::Malformed);
        }
        let mut s = fx.spec(t);
        s.env.push(("A".into(), "a\0b".into()));
        refused(&fx, "a NUL in a value", t, s, Rule::Malformed);
        let mut s = fx.spec(t);
        s.env.extend([
            ("_a1".into(), String::new()),
            ("Z_9".into(), "\"x\"\n".into()),
        ]);
        validate(s, &fx.ctx(), t).expect("good names, any value without NUL");
    }

    #[test]
    fn dest_must_equal_source_without_mounts() {
        let fx = Fx::new();
        base_passes(&fx);
        for t in [Target::LinuxReduced, Target::Macos] {
            let mut s = fx.spec(t);
            s.binds[0].dest = "/mnt/other".into();
            refused(&fx, "bind", t, s, Rule::DestDiffers);
            let mut s = fx.spec(t);
            s.home.as_mut().unwrap().dest = "/home/agent".into();
            refused(&fx, "home", t, s, Rule::DestDiffers);
            let mut s = fx.spec(t);
            s.run.as_mut().unwrap().dest = "/run/drgnx".into();
            refused(&fx, "run", t, s, Rule::DestDiffers);
        }
    }

    #[test]
    fn reserved_dests_refused() {
        let fx = Fx::new();
        base_passes(&fx);
        let t = Target::LinuxBwrap;
        for dest in [
            "/run/gleipnir",
            "/run/gleipnir/helper",
            "/run/gleipnir/x/y",
            "/run",
            "/",
            "/run/drgnx",
            "/run/drgnx/x",
        ] {
            let mut s = fx.spec(t);
            s.binds[0].dest = dest.into();
            refused(&fx, &format!("bind dest {dest}"), t, s, Rule::ReservedDest);
            let mut s = fx.spec(t);
            s.home.as_mut().unwrap().dest = dest.into();
            refused(&fx, &format!("home dest {dest}"), t, s, Rule::ReservedDest);
        }
        for dest in ["/run/gleipnir", "/run/gleipnir/helper", "/run"] {
            let mut s = fx.spec(t);
            s.run.as_mut().unwrap().dest = dest.into();
            s.net = Net::Shared;
            refused(&fx, &format!("run dest {dest}"), t, s, Rule::ReservedDest);
        }
        // A hide, a read and a write are mounted at their own path: the run dest is the base spec's source here.
        for t in [Target::LinuxReduced, Target::Macos] {
            let run = fx.p("rt/drgnx/s/S1");
            let mut s = fx.spec(t);
            s.hide.push(run.join("proxy.sock"));
            refused(&fx, "hide under the run dest", t, s, Rule::ReservedDest);
        }
        let mut s = fx.spec(t);
        s.binds[0].dest = "/run/gleipnirx".into();
        validate(s, &fx.ctx(), t).expect("a sibling with a longer name is no child");
    }

    #[test]
    fn a_malformed_context_is_refused() {
        let fx = Fx::new();
        base_passes(&fx);
        let t = Target::LinuxBwrap;
        for (row, ctx) in [
            (
                "relative home",
                Context {
                    home: "home/u".into(),
                    ..fx.ctx()
                },
            ),
            (
                "empty home",
                Context {
                    home: PathBuf::new(),
                    ..fx.ctx()
                },
            ),
            (
                "closed with ..",
                Context {
                    closed: vec![fx.p("state/../rt")],
                    ..fx.ctx()
                },
            ),
            (
                "relative PATH entry",
                Context {
                    program_dirs: vec![".".into()],
                    ..fx.ctx()
                },
            ),
            (
                "run parent with a trailing slash",
                Context {
                    run_parents: vec!["/r/".into()],
                    ..fx.ctx()
                },
            ),
            (
                "open entry not UTF-8",
                Context {
                    open_inside_closed: vec![PathBuf::from(OsStr::from_bytes(b"/s/\xff"))],
                    ..fx.ctx()
                },
            ),
            (
                "user socket with a newline",
                Context {
                    user_sockets: vec!["/a\nb".into()],
                    ..fx.ctx()
                },
            ),
        ] {
            let r = validate(fx.spec(t), &ctx, t).unwrap_err();
            assert_eq!(r.rule, Rule::Malformed, "{row}: {}", r.message);
        }
    }

    /// GL-T2-2: the context's paths are true names on disk too. A home or closed dir named through a link would make
    /// every prefix rule compare against a name no source has; one that does not exist passes when its existing part
    /// is a true name.
    #[test]
    fn context_paths_are_true_names() {
        let fx = Fx::new();
        base_passes(&fx);
        std::os::unix::fs::symlink(fx.p("home"), fx.p("hlink")).unwrap();
        std::os::unix::fs::symlink(fx.p("state"), fx.p("slink")).unwrap();
        let ok = Context {
            closed: vec![fx.p("state"), fx.p("rt"), fx.p("rt/not-yet/there")],
            ..fx.ctx()
        };
        for t in TARGETS {
            validate(fx.spec(t), &ok, t).expect("a missing tail under a true name passes");
        }
        for (row, ctx) in [
            (
                "home through a link",
                Context {
                    home: fx.p("hlink/u"),
                    ..fx.ctx()
                },
            ),
            (
                "closed through a link",
                Context {
                    closed: vec![fx.p("slink"), fx.p("rt")],
                    ..fx.ctx()
                },
            ),
            (
                "a missing PATH dir under a link",
                Context {
                    program_dirs: vec![fx.p("hlink/u/nope/bin")],
                    ..fx.ctx()
                },
            ),
        ] {
            for t in TARGETS {
                let r = validate(fx.spec(t), &ctx, t).unwrap_err();
                assert_eq!(r.rule, Rule::Malformed, "{row} {t:?}: {}", r.message);
                assert!(r.message.contains("the context's"), "{row}: {}", r.message);
            }
        }
    }

    /// Random byte paths in every key: validation answers, never panics, and what it accepts is in canonical form.
    #[test]
    fn any_os_bytes_validate_or_refuse_never_panic() {
        use proptest::prelude::*;
        use proptest::test_runner::{Config, TestRunner};
        let fx = Fx::new();
        base_passes(&fx);
        let base = fx.b.to_str().unwrap().as_bytes().to_vec();
        let part = prop_oneof![
            Just(b"".to_vec()),
            Just(b".".to_vec()),
            Just(b"..".to_vec()),
            Just(b"home".to_vec()),
            Just(b"u".to_vec()),
            Just(b"proj".to_vec()),
            Just(b".ssh".to_vec()),
            Just(b"other".to_vec()),
            Just(b"a b".to_vec()),
            Just(b"\xff".to_vec()),
            Just(b"\n".to_vec()),
            Just(b"\0".to_vec()),
            prop::collection::vec(any::<u8>(), 0..6),
        ];
        let path =
            (any::<bool>(), prop::collection::vec(part, 0..5)).prop_map(move |(rooted, parts)| {
                let mut p = if rooted { base.clone() } else { Vec::new() };
                for x in parts {
                    p.push(b'/');
                    p.extend(x);
                }
                PathBuf::from(OsStr::from_bytes(&p))
            });
        let mut runner = TestRunner::new(Config {
            cases: 2000,
            failure_persistence: None,
            ..Config::default()
        });
        runner
            .run(&(0usize..14, path, 0usize..3), |(slot, p, ti)| {
                let t = TARGETS[ti];
                let mut s = fx.spec(t);
                match slot {
                    0 => s.read.push(p),
                    1 => s.write.push(p),
                    2 => s.hide.push(p),
                    3 => s.sockets.push(p),
                    4 => s.binds[0].source = p,
                    5 => s.binds[0].dest = p,
                    6 => s.home.as_mut().unwrap().source = p,
                    7 => s.home.as_mut().unwrap().dest = p,
                    8 => s.run.as_mut().unwrap().source = p,
                    9 => s.run.as_mut().unwrap().dest = p,
                    10 => s.chdir = p,
                    11 => s.tmp = Some(p),
                    12 => {
                        if let Net::Isolated { relay, .. } = &mut s.net {
                            relay.push(RelayPort { port: 9, socket: p });
                        }
                    }
                    _ => s.read.push(p),
                }
                match validate(s, &fx.ctx(), t) {
                    Err(r) => prop_assert!(!r.message.is_empty()),
                    Ok(v) => {
                        let s = v.spec();
                        let binds = s.binds.iter().chain(&s.home).chain(&s.run);
                        let relays = match &s.net {
                            Net::Isolated { relay, .. } => {
                                relay.iter().map(|r| &r.socket).collect()
                            }
                            Net::Shared => Vec::new(),
                        };
                        let all = s
                            .read
                            .iter()
                            .chain(&s.write)
                            .chain(&s.hide)
                            .chain(&s.sockets)
                            .chain(binds.flat_map(|b| [&b.source, &b.dest]))
                            .chain(std::iter::once(&s.chdir))
                            .chain(&s.tmp)
                            .chain(relays);
                        for q in all {
                            let q = q.to_str();
                            prop_assert!(q.is_some(), "accepted a path that is not UTF-8");
                            let q = q.unwrap();
                            prop_assert!(
                                q.starts_with('/') && !q.contains(['\0', '\n']),
                                "accepted {q:?}"
                            );
                            prop_assert!(
                                q == "/"
                                    || q[1..]
                                        .split('/')
                                        .all(|c| !c.is_empty() && c != "." && c != ".."),
                                "accepted {q:?}"
                            );
                        }
                    }
                }
                Ok(())
            })
            .unwrap();
    }
}
