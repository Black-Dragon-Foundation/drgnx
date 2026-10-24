//! The Seatbelt profile (SBPL) from a spec (Task 9; docs/develop/gleipnir.md, "macOS: Seatbelt"). Pure text, built on
//! every target, so its goldens and order checks run on Linux. Running `sandbox-exec` is `backend::macos`.
//!
//! macOS has no mount namespace: every path is seen at its own place, and what the program may touch is the profile's
//! allow list. Seatbelt denies by default and the last matching rule decides, so the order of the rules is the
//! policy ([`profile`] lists it). There is no SBPL evaluator here (review M6): the goldens pin the text, the order
//! checks pin the rule order, and the macOS rows check the real thing.

use crate::spec::{Mode, Net, Target, ValidSpec};
use crate::validate::{Refusal, Rule};
use std::path::{Component, Path, PathBuf};
use std::{fs, io};

/// The rules every profile starts with: Codex's Seatbelt base policy, unchanged (Apache-2.0; `sbpl/base.sbpl` names
/// the source). `(version 1)`, `(deny default)`, process exec and fork, the `hw.*` and `kern.*` sysctls (zsh exits
/// silently without them on macOS 26.5), user lookup, POSIX IPC and pseudo-terminals. No AppleEvents, no `lsopen`, no
/// LaunchServices and no Keychain.
pub const BASE: &str = include_str!("sbpl/base.sbpl");

/// The most bytes an SBPL string may hold between its quotes, escapes counted: `sandbox-exec` refuses a longer
/// literal ("Error reading string").
pub const MAX_LITERAL: usize = 1024;

/// Where the users' homes are on macOS.
pub const USERS_DIR: &str = "/Users";

/// What every profile reads, with everything under it, by true name: the system's roots, `/bin` and `/sbin` (real
/// directories on macOS), the process's own descriptors (`/dev/fd`), `/private/var/select` (the link `/bin/sh` and
/// xcrun follow), the time zones and xcode-select's link. Never all of `/dev`: [`DEVICES`].
pub const SYSTEM_READ: &[&str] = &[
    "/usr",
    "/bin",
    "/sbin",
    "/System",
    "/Library",
    "/opt/homebrew",
    "/private/etc",
    "/dev/fd",
    "/private/var/select",
    "/private/var/db/timezone",
    "/private/var/db/xcode_select_link",
];

/// The devices every profile reads, each by its own name: never the user's other terminals (`/dev/ttysN`, whose
/// keystrokes a process of the same user could read) nor disks. `/dev/tty` is the controlling terminal.
pub const DEVICES: &[&str] = &[
    "/dev/null",
    "/dev/zero",
    "/dev/random",
    "/dev/urandom",
    "/dev/tty",
    "/dev/dtracehelper",
];

/// Under the system's roots but never readable: Homebrew's data (the databases of Postgres, MySQL, Redis).
pub const SYSTEM_HIDDEN: &[&str] = &["/opt/homebrew/var", "/usr/local/var"];

/// The top-level links into `/private`: their own metadata only, so a path through one resolves. What they lead to
/// is allowed or not by its true name.
pub const LINKS: &[&str] = &["/tmp", "/var", "/etc"];

/// The system resolver's socket: every host name lookup goes through it. `Net::Shared` only.
pub const DNS_SOCKET: &str = "/private/var/run/mDNSResponder";

/// The resolver's configuration, read by resolvers that do not ask mDNSResponder (Go's). `Net::Shared` only.
pub const DNS_FILES: &[&str] = &["/private/var/run/resolv.conf"];

/// The mach services a networked CLI needs (TLS trust, the network's configuration, user dirs): Codex's
/// `seatbelt_network_policy.sbpl` (same commit and licence as the base) without `com.apple.SecurityServer`.
/// `Net::Shared` only: trustd and ocspd fetch certificate URLs outside the sandbox, a way past `(deny network*)`.
pub const NET_SERVICES: &[&str] = &[
    "com.apple.bsd.dirhelper",
    "com.apple.system.opendirectoryd.membership",
    "com.apple.networkd",
    "com.apple.ocspd",
    "com.apple.trustd.agent",
    "com.apple.SystemConfiguration.DNSConfiguration",
    "com.apple.SystemConfiguration.configd",
];

/// The caller's macOS facts. Gleipnir reads neither itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MacContext {
    /// The true name of the developer dir xcode-select's link selects (the Command Line Tools, or Xcode's
    /// `Contents/Developer`): `/usr/bin/git` is xcrun's shim and runs the git there, so the profile reads it. `None`:
    /// nothing beyond the system's roots.
    pub developer_dir: Option<PathBuf>,
    /// Where the users' homes are ([`USERS_DIR`]): denied before every allow.
    pub users_dir: PathBuf,
}

impl Default for MacContext {
    fn default() -> MacContext {
        MacContext {
            developer_dir: None,
            users_dir: PathBuf::from(USERS_DIR),
        }
    }
}

/// The Seatbelt profile of a spec validated for [`Target::Macos`]. In order (SBPL: the last matching rule decides):
///
/// 1. [`BASE`];
/// 2. AF_UNIX sockets may be made (pipes to children); connecting to one is decided at step 13;
/// 3. `(deny file-read* (subpath "/Users") …)`, before every allow;
/// 4. `/` itself, and the metadata of [`LINKS`] and of every directory above an allowed path (stat, never list);
/// 5. reads: [`SYSTEM_READ`], the developer dir, (shared) [`DNS_FILES`], `read`, `write`, `home`, `run`, `tmp`;
/// 6. [`DEVICES`], each by name;
/// 7. [`SYSTEM_HIDDEN`] denied;
/// 8. writes: `write`, `home` when `rw`, `tmp`;
/// 9. `binds`, in order: readable, and writable for `rw` or denied writes for `ro` (the pins);
/// 10. `hide`: neither readable nor writable;
/// 11. no unlink (so no rename) of a writable root, nor of a directory between one and a pin or a hidden path; no
///     clone of a directory above a hidden path (`hide`, [`SYSTEM_HIDDEN`]): `clonefile` copies a whole tree, hidden
///     files too, and Seatbelt checks only the directory named;
/// 12. the network: shared allows outbound IP anywhere, AF_SYSTEM and [`NET_SERVICES`]; isolated is
///     `(deny network*)` and outbound to `localhost` on `mac_tcp_ports` only;
/// 13. every Unix socket denied, then each of `sockets` (and, shared, [`DNS_SOCKET`]) allowed by `path-literal`.
///
/// Every deny also holds for every case of its path (a `regex` of character classes: APFS ignores case, and whether
/// Seatbelt does is unverified); allows stay exact, so a path spelled otherwise is simply not allowed. Every path is
/// one [`quote`]d string. Refused: a spec for another target, a context path that is not absolute and in canonical
/// form, a developer dir that is `/` or holds `users_dir`, and a path SBPL cannot hold ([`quote`]).
pub fn profile(spec: &ValidSpec, mac: &MacContext) -> Result<String, Refusal> {
    if spec.target() != Target::Macos {
        let msg = format!(
            "sbpl: the spec was validated for {:?}, not Macos",
            spec.target()
        );
        return Err(malformed(msg, None));
    }
    let s = spec.spec();
    let users = context_path("users_dir", &mac.users_dir)?;
    if users == "/" {
        return Err(malformed(
            "sbpl: users_dir is /".into(),
            Some(&mac.users_dir),
        ));
    }
    let dev = match &mac.developer_dir {
        None => None,
        Some(d) => {
            let d = context_path("developer_dir", Path::new(d))?;
            if within(users, d) {
                let msg = format!("sbpl: developer_dir {d} holds {users}");
                return Err(malformed(msg, Some(Path::new(d))));
            }
            Some(d)
        }
    };
    let shared = s.net == Net::Shared;
    let home = s.home.as_ref();
    let run = s.run.as_ref().map(|b| text(&b.source)).transpose()?;
    let tmp = s.tmp.as_deref().map(text).transpose()?;
    let read = texts(&s.read)?;
    let write = texts(&s.write)?;
    let hide = texts(&s.hide)?;
    let sockets = texts(&s.sockets)?;
    let home_src = home.map(|h| text(&h.source)).transpose()?;
    let binds = s
        .binds
        .iter()
        .map(|b| Ok((b.mode, text(&b.source)?)))
        .collect::<Result<Vec<_>, Refusal>>()?;

    let mut reads: Vec<&str> = SYSTEM_READ.to_vec();
    reads.extend(dev);
    if shared {
        reads.extend(DNS_FILES);
    }
    reads.extend(read.iter().chain(&write).copied());
    reads.extend(home_src.into_iter().chain(run).chain(tmp));
    let reads = dedup(reads);
    let writes: Vec<&str> = write
        .iter()
        .copied()
        .chain(home.filter(|h| h.mode == Mode::Rw).and(home_src))
        .chain(tmp)
        .collect();
    let rw_binds = binds.iter().filter(|b| b.0 == Mode::Rw).map(|b| b.1);
    let ro_binds = binds.iter().filter(|b| b.0 == Mode::Ro).map(|b| b.1);
    let roots: Vec<&str> = writes.iter().copied().chain(rw_binds).collect();
    let protected: Vec<&str> = ro_binds.chain(hide.iter().copied()).collect();
    let moves = move_blocks(&roots, &protected);
    let hidden: Vec<&str> = hide.iter().chain(SYSTEM_HIDDEN).copied().collect();
    let clones = ancestors(&hidden);
    let meta_of: Vec<&str> = reads
        .iter()
        .chain(DEVICES)
        .copied()
        .chain(binds.iter().map(|b| b.1))
        .chain(sockets.iter().copied())
        .collect();
    let meta = dedup(LINKS.iter().copied().chain(ancestors(&meta_of)).collect());
    let mut unix: Vec<&str> = sockets.clone();
    if shared {
        unix.push(DNS_SOCKET);
    }

    let mut out: Vec<String> = vec![
        "; gleipnir: the rules from the spec (gleipnir::sbpl::profile)".into(),
        "(allow system-socket (socket-domain AF_UNIX))".into(),
    ];
    let mut push = |r: Option<String>| out.extend(r);
    push(deny_any_case("file-read*", "subpath", &[users])?);
    push(rule("allow", "file-read*", "literal", &["/"])?);
    push(rule("allow", "file-read-metadata", "literal", &meta)?);
    push(rule("allow", "file-read*", "subpath", &reads)?);
    push(rule("allow", "file-read*", "literal", DEVICES)?);
    push(deny_any_case("file-read*", "subpath", SYSTEM_HIDDEN)?);
    push(rule("allow", "file-write*", "subpath", &writes)?);
    for (mode, p) in &binds {
        push(rule("allow", "file-read*", "subpath", &[p])?);
        push(match mode {
            Mode::Rw => rule("allow", "file-write*", "subpath", &[p])?,
            Mode::Ro => deny_any_case("file-write*", "subpath", &[p])?,
        });
    }
    push(deny_any_case("file-read* file-write*", "subpath", &hide)?);
    push(deny_any_case("file-write-unlink", "literal", &moves)?);
    push(deny_any_case("file-clone", "literal", &clones)?);
    match &s.net {
        Net::Shared => {
            push(Some("(allow network-outbound (remote ip \"*:*\"))".into()));
            push(Some(
                "(allow system-socket (require-all (socket-domain AF_SYSTEM) (socket-protocol 2)))"
                    .into(),
            ));
            push(rule("allow", "mach-lookup", "global-name", NET_SERVICES)?);
        }
        Net::Isolated { mac_tcp_ports, .. } => {
            push(Some("(deny network*)".into()));
            for port in mac_tcp_ports {
                push(Some(format!(
                    "(allow network-outbound (remote ip \"localhost:{port}\"))"
                )));
            }
        }
    }
    push(Some("(deny network-outbound (remote unix-socket))".into()));
    for sock in unix {
        push(Some(format!(
            "(allow network-outbound (remote unix-socket (path-literal {})))",
            quote(sock)?
        )));
    }
    Ok(format!("{BASE}\n{}\n", out.join("\n")))
}

/// `s` as an SBPL string: in double quotes, with `"` and `\` escaped by a backslash. Refused: a control character
/// (newline, tab, NUL, DEL, C1: SBPL's reader would take some as escapes, and no path needs one) and a literal of more
/// than [`MAX_LITERAL`] bytes between the quotes.
pub fn quote(s: &str) -> Result<String, Refusal> {
    let short: String = s.chars().take(40).collect();
    if s.chars().any(char::is_control) {
        let msg = format!("sbpl: {s:?} holds a control character");
        return Err(malformed(msg, None));
    }
    let mut body = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        if c == '"' || c == '\\' {
            body.push('\\');
        }
        body.push(c);
    }
    if body.len() > MAX_LITERAL {
        let msg = format!(
            "sbpl: {short:?}… is longer than a Seatbelt string may be ({MAX_LITERAL} bytes)"
        );
        return Err(malformed(msg, None));
    }
    Ok(format!("\"{body}\""))
}

/// A new directory for a session's `TMPDIR`: `parent/gleipnir-SID-RANDOM`, mode 0700, made with `mkdir` (so nothing
/// planted before is used: an existing name is never reused, another random suffix is tried), returned as its true
/// name. `sid` is a plain name: letters, digits, `.`, `_`, `-`, not starting with `.` or `-`, at most 64 bytes.
/// Removing it is the caller's job.
pub fn session_tmpdir(parent: &Path, sid: &str) -> io::Result<PathBuf> {
    use rustix::fs::{Mode as Perm, OFlags};
    use std::os::unix::fs::DirBuilderExt;
    let plain = !sid.is_empty()
        && sid.len() <= 64
        && sid.starts_with(|c: char| c.is_ascii_alphanumeric())
        && sid
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'));
    if !plain {
        let msg = format!("{sid:?} is not a session id for a directory name");
        return Err(io::Error::new(io::ErrorKind::InvalidInput, msg));
    }
    for _ in 0..8 {
        let mut bytes = [0u8; 8];
        io::Read::read_exact(&mut fs::File::open("/dev/urandom")?, &mut bytes)?;
        let dir = parent.join(format!("gleipnir-{sid}-{:016x}", u64::from_ne_bytes(bytes)));
        match fs::DirBuilder::new().mode(0o700).create(&dir) {
            Ok(()) => {
                // The umask can only take bits away; set 0700 exactly, on the directory itself, never through a link.
                let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
                let fd = rustix::fs::open(&dir, flags, Perm::empty())?;
                rustix::fs::fchmod(&fd, Perm::from_raw_mode(0o700))?;
                return fs::canonicalize(&dir);
            }
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "no fresh name for a session TMPDIR after 8 tries",
    ))
}

fn malformed(message: String, path: Option<&Path>) -> Refusal {
    Refusal {
        rule: Rule::Malformed,
        path: path.map(Path::to_path_buf),
        message,
    }
}

/// A spec path as text: validation already refused anything but UTF-8.
fn text(p: &Path) -> Result<&str, Refusal> {
    p.to_str().ok_or_else(|| Refusal {
        rule: Rule::NotUtf8,
        path: Some(p.to_path_buf()),
        message: format!("sbpl: {} is not UTF-8", p.display()),
    })
}

fn texts(ps: &[PathBuf]) -> Result<Vec<&str>, Refusal> {
    ps.iter().map(|p| text(p)).collect()
}

/// A context path: UTF-8, absolute and in canonical form (no `//`, `.`, `..` or trailing slash).
fn context_path<'a>(key: &str, p: &'a Path) -> Result<&'a str, Refusal> {
    let t = text(p)?;
    let canonical = p.is_absolute()
        && p.components().collect::<PathBuf>().as_os_str() == p.as_os_str()
        && p.components()
            .all(|c| matches!(c, Component::RootDir | Component::Normal(_)));
    if !canonical {
        let msg = format!("sbpl: {key} {t:?} is not an absolute path in canonical form");
        return Err(malformed(msg, Some(p)));
    }
    Ok(t)
}

/// Is `p` `dir` or inside it, ignoring case (macOS)? Paths in canonical form, so components are the whole answer.
fn within(p: &str, dir: &str) -> bool {
    Path::new(&p.to_lowercase()).starts_with(dir.to_lowercase())
}

fn dedup(v: Vec<&str>) -> Vec<&str> {
    let mut out: Vec<&str> = Vec::with_capacity(v.len());
    for p in v {
        if !out.contains(&p) {
            out.push(p);
        }
    }
    out
}

/// Every directory above `paths` but `/`, without duplicates, in order.
fn ancestors<'a>(paths: &[&'a str]) -> Vec<&'a str> {
    let mut out = Vec::new();
    for p in paths {
        let mut d = *p;
        while let Some(i) = d.rfind('/').filter(|&i| i > 0) {
            d = &d[..i];
            if !out.contains(&d) {
                out.push(d);
            }
        }
    }
    out
}

/// The directories that must not be unlinked or renamed, since a rename carries a path's contents to a name no rule
/// covers: every root, then every directory from a root down to the parent of each protected path (a read-only pin or
/// a hidden path) inside it. The protected paths themselves have their own denies. A path outside a root stops at
/// its first parent, which is outside too.
fn move_blocks<'a>(roots: &[&'a str], protected: &[&'a str]) -> Vec<&'a str> {
    let mut out = roots.to_vec();
    for p in protected {
        for r in roots {
            let mut d = *p;
            while let Some(i) = d.rfind('/').filter(|&i| i > 0) {
                d = &d[..i];
                if !within(d, r) {
                    break;
                }
                out.push(d);
            }
        }
    }
    dedup(out)
}

/// One rule, one filter a line: `(ACTION OPS\n  (FILTER "p")…)`; `None` without paths.
fn rule(action: &str, ops: &str, filter: &str, paths: &[&str]) -> Result<Option<String>, Refusal> {
    if paths.is_empty() {
        return Ok(None);
    }
    let mut r = format!("({action} {ops}");
    for p in paths {
        r.push_str(&format!("\n  ({filter} {})", quote(p)?));
    }
    r.push(')');
    Ok(Some(r))
}

/// A deny of `ops` on each path as `filter` and again as [`case_regex`], so it holds for every case of the path.
fn deny_any_case(ops: &str, filter: &str, paths: &[&str]) -> Result<Option<String>, Refusal> {
    if paths.is_empty() {
        return Ok(None);
    }
    let mut r = format!("(deny {ops}");
    for p in paths {
        let re = case_regex(p, filter == "subpath");
        r.push_str(&format!(
            "\n  ({filter} {})\n  (regex {})",
            quote(p)?,
            quote(&re)?
        ));
    }
    r.push(')');
    Ok(Some(r))
}

/// Letters case-insensitive APFS also takes for a lowercase letter, beyond its own two cases: Unicode case folding
/// (CaseFolding.txt) maps U+212A KELVIN SIGN to `k`, U+017F LONG S to `s` and U+212B ANGSTROM SIGN to `å`. A deny of
/// `.secrets` must also hold for `.ſecrets` (gate review S8), whichever spelling Seatbelt compares.
const FOLDS_TO: &[(char, char)] = &[('k', '\u{212A}'), ('s', '\u{17F}'), ('å', '\u{212B}')];

/// `path` as a regex that matches it in any case: an ASCII letter as a class of both cases (`[Gg]`), a letter with
/// more spellings ([`FOLDS_TO`]: `(k|K|K)`) or a non-ASCII letter with case variants as a group of them (`(é|É)`), a
/// regex metacharacter escaped. No `(?i)`, which SBPL is not known to support. `whole`: the path and everything under
/// it (as `subpath`); else the path alone (as `literal`).
fn case_regex(path: &str, whole: bool) -> String {
    let mut re = String::from("^");
    for c in path.chars() {
        let lower = single(c.to_lowercase());
        // c, its lowercase and uppercase, the uppercase of its lowercase (a Kelvin sign's lowercase is `k`, whose
        // uppercase is `K`), and the other spellings of that lowercase.
        let mut vars: Vec<char> = vec![c];
        let more = [
            lower,
            single(c.to_uppercase()),
            lower.and_then(|l| single(l.to_uppercase())),
        ];
        let folds = FOLDS_TO
            .iter()
            .filter(|(base, _)| Some(*base) == lower)
            .map(|&(_, extra)| extra);
        for v in more.into_iter().flatten().chain(folds) {
            if !vars.contains(&v) {
                vars.push(v);
            }
        }
        if c.is_ascii_alphabetic() && vars.len() == 2 {
            re.push_str(&format!(
                "[{}{}]",
                c.to_ascii_uppercase(),
                c.to_ascii_lowercase()
            ));
        } else if vars.len() > 1 {
            let alts: Vec<String> = vars.iter().map(char::to_string).collect();
            re.push_str(&format!("({})", alts.join("|")));
        } else {
            if ".^$*+?()[]{}|\\".contains(c) {
                re.push('\\');
            }
            re.push(c);
        }
    }
    re.push_str(if whole { "(/.*)?$" } else { "$" });
    re
}

/// The one character `it` yields, or `None` when it yields none or several (`ß` uppercases to `SS`).
fn single(mut it: impl Iterator<Item = char>) -> Option<char> {
    let one = it.next()?;
    it.next().is_none().then_some(one)
}

/// A small S-expression reader for the order checks and the `sbpl_quote` fuzz target (review M4): lists, `;`
/// comments, `"…"` strings with `\"` and `\\` (any other escape is an error), `#"…"` regex strings without escapes, and
/// atoms. Unbalanced input and an unclosed string are errors.
#[cfg(any(test, feature = "fuzzing"))]
pub mod sexp {
    /// One form.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum Sexp {
        List(Vec<Sexp>),
        Str(String),
        Atom(String),
    }

    /// Every top-level form of `text`.
    pub fn read(text: &str) -> Result<Vec<Sexp>, String> {
        let mut stack: Vec<Vec<Sexp>> = vec![Vec::new()];
        let mut cs = text.char_indices().peekable();
        while let Some((at, c)) = cs.next() {
            let form = match c {
                ';' => {
                    cs.find(|&(_, c)| c == '\n');
                    continue;
                }
                '(' => {
                    stack.push(Vec::new());
                    continue;
                }
                ')' if stack.len() > 1 => Sexp::List(stack.pop().unwrap_or_default()),
                ')' => return Err(format!("an unmatched ) at {at}")),
                '"' => Sexp::Str(string(&mut cs, true, at)?),
                '#' if cs.peek().is_some_and(|&(_, c)| c == '"') => {
                    cs.next();
                    Sexp::Str(string(&mut cs, false, at)?)
                }
                c if c.is_whitespace() => continue,
                c => {
                    let mut a = String::from(c);
                    while let Some(&(_, c)) = cs.peek() {
                        if c.is_whitespace() || "();\"".contains(c) {
                            break;
                        }
                        a.push(c);
                        cs.next();
                    }
                    Sexp::Atom(a)
                }
            };
            if let Some(list) = stack.last_mut() {
                list.push(form);
            }
        }
        match <[_; 1]>::try_from(stack) {
            Ok([top]) => Ok(top),
            Err(_) => Err("a list is not closed".into()),
        }
    }

    /// The rest of a string opened at `at`. `escapes`: `\"` and `\\` (any other escape is an error); else a `#"…"`
    /// string, which ends at the next `"`.
    fn string(
        cs: &mut std::iter::Peekable<std::str::CharIndices<'_>>,
        escapes: bool,
        at: usize,
    ) -> Result<String, String> {
        let mut s = String::new();
        loop {
            match cs.next() {
                None => return Err(format!("the string at {at} is not closed")),
                Some((_, '"')) => return Ok(s),
                Some((_, '\\')) if escapes => match cs.next() {
                    Some((_, c @ ('"' | '\\'))) => s.push(c),
                    other => return Err(format!("the escape {other:?} in the string at {at}")),
                },
                Some((_, c)) => s.push(c),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::sexp::{self, Sexp};
    use super::*;
    use crate::spec::{Bind, Layers, Spec};
    use std::os::unix::fs::PermissionsExt;

    // ---- fixtures ----

    const TMP: &str = "/private/var/folders/zz/T/gleipnir-S1-0123";
    const DEV: &str = "/Applications/Xcode.app/Contents/Developer";

    fn bind(mode: Mode, p: &str) -> Bind {
        Bind {
            mode,
            source: p.into(),
            dest: p.into(),
        }
    }

    fn isolated() -> Net {
        Net::Isolated {
            relay: vec![],
            mac_tcp_ports: vec![3128, 3129],
        }
    }

    /// A job's spec on a Mac: the task folder writable with its `.git` pinned and a `.env` hidden, a private home, an
    /// object store, the session dir with one socket and a TMPDIR.
    fn spec(net: Net) -> Spec {
        Spec {
            read: vec!["/opt/tools/node".into()],
            write: vec!["/w/task".into()],
            hide: vec!["/w/task/conf/.env".into()],
            sockets: vec!["/w/run/s/S1/gw.sock".into()],
            binds: vec![bind(Mode::Ro, "/w/task/.git"), bind(Mode::Rw, "/w/objects")],
            home: Some(bind(Mode::Rw, "/w/state/home-1")),
            run: Some(bind(Mode::Ro, "/w/run/s/S1")),
            env: vec![("PATH".into(), "/usr/bin:/bin".into())],
            chdir: "/w/task".into(),
            net,
            tmp: Some(TMP.into()),
            layers: Layers::for_target(Target::Macos),
            extra_tcp_ports: vec![],
        }
    }

    fn mac() -> MacContext {
        MacContext {
            developer_dir: Some(DEV.into()),
            users_dir: USERS_DIR.into(),
        }
    }

    fn try_prof(spec: Spec, mac: &MacContext) -> Result<String, Refusal> {
        profile(&ValidSpec::assume_valid(spec, Target::Macos), mac)
    }

    fn prof(spec: Spec) -> String {
        try_prof(spec, &mac()).unwrap()
    }

    // ---- reading the profile back ----

    /// The profile's own rules: everything after the base, which every profile starts with.
    fn own(text: &str) -> Vec<Sexp> {
        assert!(text.starts_with(BASE), "the profile starts with the base");
        sexp::read(&text[BASE.len()..]).unwrap()
    }

    fn atom(s: &Sexp) -> Option<&str> {
        match s {
            Sexp::Atom(a) => Some(a),
            _ => None,
        }
    }

    fn string(s: &Sexp) -> Option<&str> {
        match s {
            Sexp::Str(a) => Some(a),
            _ => None,
        }
    }

    fn items(s: &Sexp) -> &[Sexp] {
        match s {
            Sexp::List(l) => l,
            _ => panic!("not a list: {s:?}"),
        }
    }

    /// A rule `(ACTION OP… FILTER…)`: its action, its operations (the atoms) and its filters (the lists).
    struct R<'a> {
        action: &'a str,
        ops: Vec<&'a str>,
        filters: Vec<&'a Sexp>,
    }

    fn rule(f: &Sexp) -> R<'_> {
        let l = items(f);
        R {
            action: atom(&l[0]).unwrap(),
            ops: l[1..].iter().filter_map(atom).collect(),
            filters: l[1..]
                .iter()
                .filter(|x| matches!(x, Sexp::List(_)))
                .collect(),
        }
    }

    fn rules(forms: &[Sexp]) -> Vec<R<'_>> {
        forms.iter().map(rule).collect()
    }

    /// The strings of a rule's filters named `name`: `(subpath "a") (subpath "b")` → `["a", "b"]`.
    fn args<'a>(r: &R<'a>, name: &str) -> Vec<&'a str> {
        r.filters
            .iter()
            .filter(|f| atom(&items(f)[0]) == Some(name))
            .filter_map(|f| items(f).get(1).and_then(string))
            .collect()
    }

    fn is(r: &R<'_>, action: &str, ops: &[&str]) -> bool {
        r.action == action && r.ops == ops
    }

    /// The index of the one rule that matches `pred`.
    fn one(rs: &[R<'_>], what: &str, pred: impl Fn(&R<'_>) -> bool) -> usize {
        let hits: Vec<usize> = (0..rs.len()).filter(|&i| pred(&rs[i])).collect();
        assert_eq!(hits.len(), 1, "{what}: {hits:?}");
        hits[0]
    }

    /// Does `re`, a regex [`profile`] made (`^`, `\c`, `[Aa]`, `(é|É)`, then `(/.*)?$` or `$`), match `s`? Only that
    /// shape is understood; anything else fails the test.
    fn re_match(re: &str, s: &str) -> bool {
        let (body, whole) = if let Some(b) = re.strip_suffix("(/.*)?$") {
            (b, true)
        } else {
            (re.strip_suffix('$').expect("ends in $"), false)
        };
        let mut cs = body.strip_prefix('^').expect("starts with ^").chars();
        let mut toks: Vec<Vec<char>> = Vec::new();
        while let Some(c) = cs.next() {
            toks.push(match c {
                '\\' => vec![cs.next().unwrap()],
                '[' => cs.by_ref().take_while(|&c| c != ']').collect(),
                '(' => cs
                    .by_ref()
                    .take_while(|&c| c != ')')
                    .filter(|&c| c != '|')
                    .collect(),
                '.' | '^' | '$' | '*' | '+' | '?' | ')' | ']' | '{' | '}' | '|' => {
                    panic!("unescaped {c} in {re}")
                }
                c => vec![c],
            });
        }
        let sc: Vec<char> = s.chars().collect();
        if sc.len() < toks.len() || !toks.iter().zip(&sc).all(|(t, c)| t.contains(c)) {
            return false;
        }
        let rest = &sc[toks.len()..];
        rest.is_empty() || (whole && rest[0] == '/')
    }

    /// A deny's paths and regexes, in pairs: `(F "p") (regex "r")`.
    fn deny_pairs<'a>(r: &R<'a>, filter: &str) -> Vec<(&'a str, &'a str)> {
        let paths = args(r, filter);
        let res = args(r, "regex");
        assert_eq!(paths.len(), res.len(), "a regex for every path");
        paths.into_iter().zip(res).collect()
    }

    // ---- the tests ----

    #[test]
    fn golden_shared() {
        let p = prof(spec(Net::Shared));
        insta::assert_snapshot!("golden_shared", &p[BASE.len()..]);
    }

    #[test]
    fn golden_isolated() {
        let p = try_prof(spec(isolated()), &MacContext::default()).unwrap();
        insta::assert_snapshot!("golden_isolated", &p[BASE.len()..]);
    }

    const HOSTILE_Q: &str = r#"/w/q"x\y"#;
    const HOSTILE_RULE: &str = r#"/w/q"x\y/x") (allow default) (""#;

    fn hostile() -> Spec {
        let mut s = spec(Net::Shared);
        s.write = vec![HOSTILE_Q.into()];
        s.hide = vec![HOSTILE_RULE.into()];
        s.binds = vec![bind(Mode::Ro, "/w/q\"x\\y/a b")];
        s.chdir = HOSTILE_Q.into();
        s
    }

    #[test]
    fn golden_hostile_names() {
        let p = prof(hostile());
        insta::assert_snapshot!("golden_hostile_names", &p[BASE.len()..]);
        let forms = own(&p);
        let rs = rules(&forms);
        assert!(!rs.iter().any(|r| r.ops.contains(&"default")));
        let w = one(&rs, "the writes", |r| is(r, "allow", &["file-write*"]));
        assert_eq!(args(&rs[w], "subpath"), [HOSTILE_Q, "/w/state/home-1", TMP]);
        let h = one(&rs, "the hide", |r| {
            is(r, "deny", &["file-read*", "file-write*"])
        });
        assert_eq!(args(&rs[h], "subpath"), [HOSTILE_RULE]);
        let pin = one(&rs, "the pin", |r| is(r, "deny", &["file-write*"]));
        assert_eq!(args(&rs[pin], "subpath"), ["/w/q\"x\\y/a b"]);
        let (_, re) = deny_pairs(&rs[h], "subpath")[0];
        assert!(re_match(re, &HOSTILE_RULE.to_uppercase()));
    }

    #[test]
    fn denies_by_default() {
        for net in [Net::Shared, isolated()] {
            let p = prof(spec(net));
            let all = sexp::read(&p).unwrap();
            assert_eq!(
                all[0],
                Sexp::List(vec![Sexp::Atom("version".into()), Sexp::Atom("1".into())])
            );
            let rs = rules(&all[1..]);
            assert!(is(&rs[0], "deny", &["default"]) && rs[0].filters.is_empty());
            assert_eq!(rs.iter().filter(|r| r.ops.contains(&"default")).count(), 1);
            // An allow without a filter allows that operation everywhere: only the base's four.
            let bare: Vec<&str> = rs
                .iter()
                .filter(|r| r.action == "allow" && r.filters.is_empty())
                .flat_map(|r| r.ops.clone())
                .collect();
            assert_eq!(
                bare,
                [
                    "process-exec",
                    "process-fork",
                    "ipc-posix-sem",
                    "pseudo-tty"
                ]
            );
        }
    }

    #[test]
    fn users_denied_before_every_allow() {
        let mut s = spec(Net::Shared);
        s.write = vec!["/Users/_u/task".into()];
        s.hide = vec![];
        s.binds = vec![];
        let p = prof(s);
        let forms = own(&p);
        let rs = rules(&forms);
        let deny = one(&rs, "the /Users deny", |r| {
            is(r, "deny", &["file-read*"]) && args(r, "subpath") == [USERS_DIR]
        });
        let (_, re) = deny_pairs(&rs[deny], "subpath")[0];
        assert!(re_match(re, "/users/_u/.ssh/id_canary") && re_match(re, "/USERS"));
        for (i, r) in rs.iter().enumerate() {
            if r.action == "allow" && r.ops.iter().any(|o| o.starts_with("file-")) {
                assert!(
                    i > deny,
                    "allow {:?} at {i} before the /Users deny at {deny}",
                    r.ops
                );
            }
        }
        // /Users and the home: their metadata only (stat, never list); the task folder by subpath.
        let meta = one(&rs, "metadata", |r| is(r, "allow", &["file-read-metadata"]));
        let lits = args(&rs[meta], "literal");
        assert!(lits.contains(&"/Users") && lits.contains(&"/Users/_u"));
        let reads = one(&rs, "the reads", |r| {
            is(r, "allow", &["file-read*"]) && !args(r, "subpath").is_empty()
        });
        let subs = args(&rs[reads], "subpath");
        assert!(subs.contains(&"/Users/_u/task"));
        assert!(!subs.iter().any(|s| *s == "/Users" || *s == "/Users/_u"));
        // The deny follows the context's users dir.
        let other = MacContext {
            users_dir: "/Homes".into(),
            ..mac()
        };
        let p = try_prof(spec(Net::Shared), &other).unwrap();
        let forms = own(&p);
        let rs = rules(&forms);
        one(&rs, "the /Homes deny", |r| {
            is(r, "deny", &["file-read*"]) && args(r, "subpath") == ["/Homes"]
        });
    }

    #[test]
    fn no_appleevents_lsopen_launchservices_keychain() {
        for net in [Net::Shared, isolated()] {
            let shared = net == Net::Shared;
            let p = prof(spec(net));
            for word in [
                "appleevent-send",
                "lsopen",
                "com.apple.coreservices.launchservicesd",
                "com.apple.SecurityServer",
                "global-name-prefix",
                "global-name-regex",
            ] {
                assert!(!p.contains(word), "{word}");
            }
            let all = sexp::read(&p).unwrap();
            let rs = rules(&all[1..]);
            let mut names: Vec<&str> = rs
                .iter()
                .filter(|r| r.ops.contains(&"mach-lookup"))
                .flat_map(|r| {
                    assert_eq!(r.action, "allow");
                    assert!(!r.filters.is_empty(), "a bare mach-lookup allow");
                    args(r, "global-name")
                })
                .collect();
            names.sort_unstable();
            let mut want = vec![
                "com.apple.PowerManagement.control",
                "com.apple.system.opendirectoryd.libinfo",
            ];
            if shared {
                want.extend(NET_SERVICES);
            }
            want.sort_unstable();
            assert_eq!(names, want);
        }
    }

    #[test]
    fn unix_sockets_only_the_sessions() {
        for net in [Net::Shared, isolated()] {
            let shared = net == Net::Shared;
            let p = prof(spec(net));
            let forms = own(&p);
            let rs = rules(&forms);
            let unix = |r: &R<'_>| {
                r.filters
                    .iter()
                    .any(|f| items(f).iter().any(|x| atom(x) == Some("unix-socket")))
            };
            let deny = one(&rs, "the unix deny", |r| {
                is(r, "deny", &["network-outbound"]) && unix(r)
            });
            assert_eq!(rs[deny].filters.len(), 1);
            assert_eq!(
                items(rs[deny].filters[0]).len(),
                2,
                "(remote unix-socket), no path"
            );
            let mut allowed = Vec::new();
            for (i, r) in rs.iter().enumerate().filter(|(_, r)| unix(r)) {
                if i == deny {
                    continue;
                }
                assert!(i > deny && is(r, "allow", &["network-outbound"]));
                let remote = items(r.filters[0]);
                assert_eq!(remote.len(), 3, "{remote:?}");
                let lit = items(&remote[2]);
                assert_eq!(atom(&lit[0]), Some("path-literal"));
                allowed.push(string(&lit[1]).unwrap());
            }
            let mut want = vec!["/w/run/s/S1/gw.sock"];
            if shared {
                want.push(DNS_SOCKET);
            }
            assert_eq!(allowed, want);
            assert!(!p.contains("path-regex") && !p.contains("path-prefix"));
            assert!(
                !rs.iter()
                    .any(|r| r.action == "allow" && r.ops.contains(&"network*"))
            );
        }
    }

    #[test]
    fn isolated_only_listed_localhost_ports_and_no_trustd() {
        let p = prof(spec(isolated()));
        let forms = own(&p);
        let rs = rules(&forms);
        let deny = one(&rs, "(deny network*)", |r| is(r, "deny", &["network*"]));
        assert!(rs[deny].filters.is_empty());
        let mut ips = Vec::new();
        for (i, r) in rs.iter().enumerate() {
            if r.action == "allow" && r.ops.iter().any(|o| o.starts_with("network")) {
                assert!(i > deny);
                assert_eq!(r.ops, ["network-outbound"]);
                let remote = items(r.filters[0]);
                if atom(&remote[1]) == Some("ip") {
                    ips.push(string(&remote[2]).unwrap());
                }
            }
        }
        assert_eq!(ips, ["localhost:3128", "localhost:3129"]);
        for word in [
            "trustd",
            "ocspd",
            "networkd",
            "SystemConfiguration",
            "AF_SYSTEM",
            "*:*",
            "mDNSResponder",
            "resolv.conf",
        ] {
            assert!(!p.contains(word), "{word}");
        }
        // The control: shared has every one of them.
        let s = prof(spec(Net::Shared));
        for word in [
            "trustd",
            "AF_SYSTEM",
            "\"*:*\"",
            "mDNSResponder",
            "resolv.conf",
        ] {
            assert!(s.contains(word), "{word}");
        }
        assert!(!s.contains("(deny network*)"));
        // No port listed: nothing at all.
        let mut none = spec(Net::Isolated {
            relay: vec![],
            mac_tcp_ports: vec![],
        });
        none.sockets = vec![];
        let p = prof(none);
        assert!(!p.contains("remote ip"));
    }

    #[test]
    fn pins_and_hide_are_case_insensitive_denies() {
        let p = prof(spec(Net::Shared));
        let forms = own(&p);
        let rs = rules(&forms);
        let pin = one(&rs, "the pin", |r| is(r, "deny", &["file-write*"]));
        let pairs = deny_pairs(&rs[pin], "subpath");
        assert_eq!(pairs.len(), 1);
        let (path, re) = pairs[0];
        assert_eq!(path, "/w/task/.git");
        for hit in [
            "/w/task/.git",
            "/w/task/.GIT/config",
            "/W/Task/.Git/hooks/x",
            "/w/task/.gIt/COMMONDIR",
        ] {
            assert!(re_match(re, hit), "{hit}");
        }
        for miss in ["/w/task/.gitx", "/w/task/x.git", "/w/task/.gi", "/w/task"] {
            assert!(!re_match(re, miss), "{miss}");
        }
        // The pin is readable, and comes after the task folder's write allow, so it wins.
        let writes = one(&rs, "the writes", |r| {
            is(r, "allow", &["file-write*"]) && args(r, "subpath").contains(&"/w/task")
        });
        assert!(pin > writes);
        let h = one(&rs, "the hide", |r| {
            is(r, "deny", &["file-read*", "file-write*"])
        });
        let (path, re) = deny_pairs(&rs[h], "subpath")[0];
        assert_eq!(path, "/w/task/conf/.env");
        for hit in [
            "/w/task/conf/.ENV",
            "/w/task/CONF/.env",
            "/w/task/conf/.Env/x",
        ] {
            assert!(re_match(re, hit), "{hit}");
        }
        assert!(h > pin);
        // A non-ASCII letter: a group of its cases; a letter without cases and a metacharacter as themselves.
        let re = case_regex("/w/café/ß+x", true);
        assert!(re.contains("(é|É)") && re.contains("ß\\+"), "{re}");
        for hit in ["/w/CAFÉ/ß+X", "/w/Café/ß+x/y"] {
            assert!(re_match(&re, hit), "{hit}");
        }
        assert!(!re_match(&re, "/w/cafe/ß+x"));
        // Gate review S8: the letters APFS's case folding gives more spellings: k (Kelvin sign), s (long s), å
        // (Angstrom sign), from either case and from the odd spelling itself.
        let re = case_regex("/w/.kubes/å", false);
        assert!(
            re.contains("(k|K|\u{212A})") && re.contains("(s|S|\u{17F})"),
            "{re}"
        );
        assert!(re.contains("(å|Å|\u{212B})"), "{re}");
        for hit in [
            "/w/.kubes/å",
            "/w/.KUBES/Å",
            "/w/.\u{212A}ube\u{17F}/\u{212B}",
            "/W/.kUbEs/å",
        ] {
            assert!(re_match(&re, hit), "{hit}");
        }
        assert!(!re_match(&re, "/w/.cubes/å"));
        assert_eq!(case_regex("/\u{212A}", false), "^/(\u{212A}|k|K)$");
        assert_eq!(case_regex("/g", false), "^/[Gg]$");
        // Homebrew's data, in every case too.
        let brew = one(&rs, "homebrew", |r| {
            is(r, "deny", &["file-read*"]) && args(r, "subpath") == SYSTEM_HIDDEN
        });
        let (_, re) = deny_pairs(&rs[brew], "subpath")[0];
        assert!(re_match(re, "/opt/HomeBrew/var/postgres"));
        // Allows stay exact: no allow carries a regex.
        assert!(
            !rs.iter()
                .any(|r| r.action == "allow" && !args(r, "regex").is_empty())
        );
        assert!(!p.contains("(?i)"));
    }

    #[test]
    fn unlink_denied_on_roots_and_ancestors() {
        let p = prof(spec(Net::Shared));
        let forms = own(&p);
        let rs = rules(&forms);
        let u = one(&rs, "the unlink deny", |r| {
            is(r, "deny", &["file-write-unlink"])
        });
        let pairs = deny_pairs(&rs[u], "literal");
        let dirs: Vec<&str> = pairs.iter().map(|(p, _)| *p).collect();
        // The writable roots (write, home, tmp, the rw bind), then the dirs between a root and a pin's or a hidden
        // path's parent; never the pin or the hidden path itself (their own denies cover them).
        assert_eq!(
            dirs,
            [
                "/w/task",
                "/w/state/home-1",
                TMP,
                "/w/objects",
                "/w/task/conf"
            ]
        );
        let (_, re) = pairs[0];
        assert!(re_match(re, "/W/TASK") && !re_match(re, "/w/task/a.el"));
        // The last rule of the file rules: after the hide.
        let h = one(&rs, "the hide", |r| {
            is(r, "deny", &["file-read*", "file-write*"])
        });
        assert!(u > h);
        // A read-only home is no root: neither writable nor in the unlink list.
        let mut s = spec(Net::Shared);
        s.home = Some(bind(Mode::Ro, "/w/state/home-1"));
        let p = prof(s);
        let forms = own(&p);
        let rs = rules(&forms);
        let u = one(&rs, "the unlink deny", |r| {
            is(r, "deny", &["file-write-unlink"])
        });
        assert!(!args(&rs[u], "literal").contains(&"/w/state/home-1"));
        let w = one(&rs, "the writes", |r| {
            is(r, "allow", &["file-write*"]) && args(r, "subpath").contains(&"/w/task")
        });
        assert!(!args(&rs[w], "subpath").contains(&"/w/state/home-1"));
    }

    #[test]
    fn clone_denied_on_every_dir_above_a_hidden_path() {
        // MAC-SB-10 (j): a clonefile of /w/task/conf copied conf/.env to a name no rule covers. Every directory above a
        // hidden path (the spec's and the system's), in every case; never the hidden path itself (its deny covers it).
        let p = prof(spec(Net::Shared));
        let forms = own(&p);
        let rs = rules(&forms);
        let c = one(&rs, "the clone deny", |r| is(r, "deny", &["file-clone"]));
        let pairs = deny_pairs(&rs[c], "literal");
        let dirs: Vec<&str> = pairs.iter().map(|(p, _)| *p).collect();
        assert_eq!(
            dirs,
            [
                "/w/task/conf",
                "/w/task",
                "/w",
                "/opt/homebrew",
                "/opt",
                "/usr/local",
                "/usr"
            ]
        );
        let (_, re) = pairs[0];
        assert!(re_match(re, "/W/TASK/CONF") && !re_match(re, "/w/task/conf/.env"));
        // After every allow of the file rules, so no later allow lets a clone through.
        let u = one(&rs, "the unlink deny", |r| {
            is(r, "deny", &["file-write-unlink"])
        });
        assert!(c > u);
        // Without a hidden path of its own the spec still hides the system's.
        let mut s = spec(Net::Shared);
        s.hide = vec![];
        let p = prof(s);
        let forms = own(&p);
        let rs = rules(&forms);
        let c = one(&rs, "the clone deny", |r| is(r, "deny", &["file-clone"]));
        assert_eq!(
            args(&rs[c], "literal"),
            ["/opt/homebrew", "/opt", "/usr/local", "/usr"]
        );
    }

    #[test]
    fn devices_by_name_only() {
        for net in [Net::Shared, isolated()] {
            let p = prof(spec(net));
            let forms = own(&p);
            let rs = rules(&forms);
            let d = one(&rs, "the devices", |r| {
                is(r, "allow", &["file-read*"])
                    && !args(r, "literal").is_empty()
                    && args(r, "literal") != ["/"]
            });
            assert_eq!(args(&rs[d], "literal"), DEVICES);
            for r in rs.iter().filter(|r| r.action == "allow") {
                let full = r
                    .ops
                    .iter()
                    .any(|o| *o == "file-read*" || o.starts_with("file-write"));
                for p in args(r, "subpath").into_iter().chain(args(r, "literal")) {
                    if full && (p == "/dev" || p.starts_with("/dev/")) {
                        assert!(DEVICES.contains(&p) || p == "/dev/fd", "{:?} {p}", r.ops);
                        assert!(!r.ops.iter().any(|o| o.starts_with("file-write")), "{p}");
                    }
                }
            }
        }
    }

    #[test]
    fn hw_sysctls_present() {
        let p = prof(spec(Net::Shared));
        let all = sexp::read(&p).unwrap();
        let rs = rules(&all[1..]);
        let s = one(&rs, "sysctl-read", |r| is(r, "allow", &["sysctl-read"]));
        let names = args(&rs[s], "sysctl-name");
        for n in [
            "hw.ncpu",
            "hw.memsize",
            "hw.pagesize",
            "hw.logicalcpu_max",
            "kern.osproductversion",
        ] {
            assert!(names.contains(&n), "{n}");
        }
        let prefixes = args(&rs[s], "sysctl-name-prefix");
        for n in ["hw.optional.arm.", "hw.optional.armv8_", "hw.perflevel"] {
            assert!(prefixes.contains(&n), "{n}");
        }
    }

    #[test]
    fn quotes_hostile_paths() {
        assert_eq!(quote(r#"/a"b\c"#).unwrap(), r#""/a\"b\\c""#);
        for s in [
            HOSTILE_Q,
            HOSTILE_RULE,
            "/w/a b",
            "/w/é/ü",
            "\\",
            "\"\"",
            ")(",
            "; not a comment",
            "",
        ] {
            let q = quote(s).unwrap();
            assert_eq!(sexp::read(&q).unwrap(), [Sexp::Str(s.into())], "{s}");
        }
        for bad in [
            "/a\nb",
            "/a\tb",
            "/a\0b",
            "/a\x7fb",
            "/a\u{85}b",
            "/a\rb",
            "\x1b[0m",
        ] {
            let r = quote(bad).unwrap_err();
            assert_eq!(r.rule, Rule::Malformed, "{bad:?}");
        }
        let at = "a".repeat(MAX_LITERAL);
        assert!(quote(&at).is_ok());
        assert_eq!(quote(&format!("{at}a")).unwrap_err().rule, Rule::Malformed);
        // Escapes count: 1023 bytes and a quote are 1025 between the quotes.
        let esc = format!("{}\"", "a".repeat(MAX_LITERAL - 1));
        assert!(quote(&esc).is_err());
        // The profile refuses such a path instead of writing it.
        let mut s = spec(Net::Shared);
        s.read = vec!["/w/a\tb".into()];
        assert_eq!(try_prof(s, &mac()).unwrap_err().rule, Rule::Malformed);
        // A deny's regex is about four times its path: a long hidden path is refused, not cut.
        let mut s = spec(Net::Shared);
        s.hide = vec![format!("/w/task/{}", "x".repeat(300)).into()];
        assert_eq!(try_prof(s, &mac()).unwrap_err().rule, Rule::Malformed);
    }

    #[test]
    fn balanced_parentheses() {
        for s in [spec(Net::Shared), spec(isolated()), hostile()] {
            let p = prof(s);
            let all = sexp::read(&p).unwrap();
            assert!(all.len() > 20);
            for f in &all {
                let head = atom(&items(f)[0]).unwrap();
                assert!(["version", "allow", "deny"].contains(&head), "{head}");
            }
        }
        for bad in [
            "(version 1)\n(allow file-read* (subpath \"/a\")",
            "(version 1))",
            "(allow file-read* (subpath \"/a))",
            "(allow file-read* (subpath \"/a\\n\"))",
        ] {
            assert!(sexp::read(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn refuses_another_target_and_a_bad_context() {
        let v = ValidSpec::assume_valid(spec(Net::Shared), Target::LinuxBwrap);
        assert_eq!(profile(&v, &mac()).unwrap_err().rule, Rule::Malformed);
        for dev in [
            "/",
            "/Applications/../Users",
            "relative/dev",
            "/a//b",
            "/a/",
        ] {
            let m = MacContext {
                developer_dir: Some(dev.into()),
                ..mac()
            };
            assert_eq!(
                try_prof(spec(Net::Shared), &m).unwrap_err().rule,
                Rule::Malformed,
                "{dev}"
            );
        }
        for users in ["/", "Users", "/Users/"] {
            let m = MacContext {
                users_dir: users.into(),
                ..mac()
            };
            assert_eq!(
                try_prof(spec(Net::Shared), &m).unwrap_err().rule,
                Rule::Malformed,
                "{users}"
            );
        }
        // The developer dir is read by its true name, and only when given.
        let p = prof(spec(Net::Shared));
        assert!(p.contains(&format!("(subpath \"{DEV}\")")));
        let p = try_prof(spec(Net::Shared), &MacContext::default()).unwrap();
        assert!(!p.contains("Xcode.app"));
    }

    #[test]
    fn session_tmpdir_is_private_fresh_and_its_true_name() {
        let top = tempfile::Builder::new()
            .prefix("glp-")
            .tempdir_in("/tmp")
            .unwrap();
        let real = top.path().join("real");
        std::fs::create_dir(&real).unwrap();
        let link = top.path().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let a = session_tmpdir(&link, "S1").unwrap();
        let b = session_tmpdir(&link, "S1").unwrap();
        assert_ne!(a, b);
        for d in [&a, &b] {
            assert_eq!(d, &std::fs::canonicalize(d).unwrap());
            assert!(d.starts_with(std::fs::canonicalize(&real).unwrap()));
            let m = std::fs::symlink_metadata(d).unwrap();
            assert!(m.is_dir());
            assert_eq!(m.permissions().mode() & 0o7777, 0o700);
            let name = d.file_name().unwrap().to_str().unwrap();
            assert!(name.starts_with("gleipnir-S1-") && name.len() > "gleipnir-S1-".len() + 8);
        }
        let long = "x".repeat(65);
        for bad in ["", ".x", "-x", "a/b", "..", "a b", "a\nb", long.as_str()] {
            let e = session_tmpdir(&real, bad).unwrap_err();
            assert_eq!(e.kind(), io::ErrorKind::InvalidInput, "{bad:?}");
        }
    }
}
