//! `cargo xtask standards`: the standards table, the generated clippy configs, the scanner and the ownership check
//! (docs/develop/standards/README.md).
//!
//! - `standards [--root DIR]`: every check; one line per finding. It exits 1 when a finding is enforced: one in the
//!   table, or in a crate marked clean. Findings in crates not yet clean are listed, with a count per crate.
//! - `standards --write`: writes the generated clippy.toml files, then checks.
//! - `standards --changed FILE…` (the pre-commit hook): the table's checks, and the files' findings only.
//! - `standards --commit-msg MSGFILE FILE…` (the commit-msg hook): a commit touching a crate not yet clean must be a
//!   migration (its subject starts with `migrate`).

mod allows;
mod deps;
mod scan;
mod table;

use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use table::{Member, Table};

/// One finding: `file:line: [<id>/<rule>] <message> (docs/develop/standards/<id>.md)`.
pub struct Finding {
    pub file: PathBuf,
    pub line: usize,
    pub id: String,
    pub rule: String,
    pub message: String,
    /// The crate the file belongs to; None for the table's own findings (always enforced).
    pub krate: Option<String>,
}

impl fmt::Display for Finding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let page = if self.id == "standards" {
            "README".to_string()
        } else {
            self.id.clone()
        };
        write!(
            f,
            "{}:{}: [{}/{}] {} (docs/develop/standards/{page}.md)",
            self.file.display(),
            self.line,
            self.id,
            self.rule,
            self.message
        )
    }
}

struct Args {
    root: PathBuf,
    write: bool,
    changed: Option<Vec<PathBuf>>,
    commit_msg: Option<PathBuf>,
}

fn parse(args: Vec<String>) -> Result<Args, String> {
    let mut a = Args {
        root: Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default(),
        write: false,
        changed: None,
        commit_msg: None,
    };
    let mut it = args.into_iter();
    let mut files = Vec::new();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--root" => a.root = it.next().ok_or("--root needs a directory")?.into(),
            "--write" => a.write = true,
            "--changed" => a.changed = Some(Vec::new()),
            "--commit-msg" => {
                a.commit_msg = Some(it.next().ok_or("--commit-msg needs a file")?.into())
            }
            f if !f.starts_with("--") => files.push(PathBuf::from(f)),
            other => return Err(format!("standards: unknown option `{other}`")),
        }
    }
    if a.changed.is_some() || a.commit_msg.is_some() {
        a.changed = Some(files);
    } else if !files.is_empty() {
        return Err("standards: files are given only with --changed or --commit-msg".into());
    }
    Ok(a)
}

pub fn run(args: Vec<String>) -> Result<ExitCode, String> {
    let a = parse(args)?;
    let table = Table::load(&a.root)?;
    let members = table::members(&a.root)?;
    if let Some(msg) = &a.commit_msg {
        return commit_msg(
            &a.root,
            &table,
            &members,
            msg,
            a.changed.as_deref().unwrap_or_default(),
        );
    }
    if a.write {
        for (path, text) in table::clippy_files(&a.root, &table, &members) {
            std::fs::write(&path, text).map_err(|e| format!("{}: {e}", path.display()))?;
        }
    }
    let mut findings = table::check(&a.root, &table, &members);
    for (path, text) in table::clippy_files(&a.root, &table, &members) {
        let on_disk = std::fs::read_to_string(&path).unwrap_or_default();
        if on_disk != text {
            findings.push(Finding {
                file: table::rel(&a.root, &path).into(),
                line: 1,
                id: "standards".into(),
                rule: "clippy-config".into(),
                message:
                    "missing or not what standards.toml gives: run `cargo xtask standards --write`"
                        .into(),
                krate: None,
            });
        }
    }
    findings.extend(deps::check(&a.root, &table, &members));
    for (file, krate) in rust_files(&members) {
        let rel = table::rel(&a.root, &file);
        if let Some(changed) = &a.changed
            && !changed
                .iter()
                .any(|c| Path::new(&rel) == c || a.root.join(c) == file)
        {
            continue;
        }
        findings.extend(scan_file(&a.root, &table, &file, &krate));
    }
    Ok(report(&table, findings))
}

fn report(table: &Table, mut findings: Vec<Finding>) -> ExitCode {
    findings.sort_by(|x, y| (&x.file, x.line).cmp(&(&y.file, y.line)));
    let enforced = |f: &Finding| f.krate.as_deref().is_none_or(|k| table.is_clean(k));
    let mut out = String::new();
    let mut later: BTreeMap<String, usize> = BTreeMap::new();
    let mut failed = 0;
    for f in &findings {
        out.push_str(&format!("{f}\n"));
        if enforced(f) {
            failed += 1;
        } else if let Some(k) = &f.krate {
            *later.entry(k.clone()).or_default() += 1;
        }
    }
    for (k, n) in &later {
        out.push_str(&format!(
            "standards: {n} finding(s) in `{k}`, not clean yet (not enforced; its migration owns them)\n"
        ));
    }
    out.push_str(&format!("standards: {failed} enforced finding(s)\n"));
    print!("{out}");
    if failed > 0 {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}

/// Every .rs file of the members, with its crate: a file belongs to the deepest member directory holding it, and a
/// directory with its own Cargo.toml that is not a member (a fixture, a separate workspace) is not walked.
fn rust_files(members: &[Member]) -> Vec<(PathBuf, String)> {
    let dirs: BTreeMap<PathBuf, String> = members
        .iter()
        .map(|m| (m.dir.clone(), m.name.clone()))
        .collect();
    let mut out = Vec::new();
    for m in members {
        walk(&m.dir, &m.name, &dirs, &mut out);
    }
    out.sort();
    out
}

fn walk(
    dir: &Path,
    krate: &str,
    members: &BTreeMap<PathBuf, String>,
    out: &mut Vec<(PathBuf, String)>,
) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut entries: Vec<_> = entries.flatten().map(|e| e.path()).collect();
    entries.sort();
    for p in entries {
        let name = p
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        if p.is_dir() {
            if name == "target"
                || name.starts_with('.')
                || members.contains_key(&p)
                || p.join("Cargo.toml").is_file()
            {
                continue;
            }
            walk(&p, krate, members, out);
        } else if name.ends_with(".rs") {
            out.push((p, krate.to_string()));
        }
    }
}

fn scan_file(root: &Path, table: &Table, file: &Path, krate: &str) -> Vec<Finding> {
    let rel: PathBuf = table::rel(root, file).into();
    let text = match std::fs::read_to_string(file) {
        Ok(t) => t,
        Err(e) => return vec![parse_failure(rel, krate, e.to_string())],
    };
    let parsed = match syn::parse_file(&text) {
        Ok(p) => p,
        Err(e) => return vec![parse_failure(rel, krate, e.to_string())],
    };
    let mut rules = scan::Rules {
        ui: table.is_ui(krate),
        ..Default::default()
    };
    for s in table.standard.iter().filter(|s| s.owner != krate) {
        for p in &s.clippy {
            rules
                .methods
                .insert(p.clone(), (s.id.clone(), s.owner.clone()));
        }
        for p in &s.clippy_types {
            rules
                .types
                .insert(p.clone(), (s.id.clone(), s.owner.clone()));
        }
        for r in &s.scan {
            rules.scan.insert(r.clone(), s.id.clone());
        }
    }
    let mut hits = scan::scan(&parsed, &rules);
    hits.extend(allows::check(&parsed, table, krate));
    hits.into_iter()
        .map(|h| Finding {
            file: rel.clone(),
            line: h.line,
            id: h.id,
            rule: h.rule,
            message: h.message,
            krate: Some(krate.to_string()),
        })
        .collect()
}

fn parse_failure(file: PathBuf, krate: &str, why: String) -> Finding {
    Finding {
        file,
        line: 1,
        id: "standards".into(),
        rule: "parse".into(),
        message: format!("the scanner could not read this file: {why}"),
        krate: Some(krate.to_string()),
    }
}

/// The freeze (D15): a commit that touches a crate not yet clean must say it is a migration.
fn commit_msg(
    root: &Path,
    table: &Table,
    members: &[Member],
    msg: &Path,
    files: &[PathBuf],
) -> Result<ExitCode, String> {
    let text = std::fs::read_to_string(msg).map_err(|e| format!("{}: {e}", msg.display()))?;
    let subject = text.lines().find(|l| !l.starts_with('#')).unwrap_or("");
    if subject.starts_with("migrate") {
        return Ok(ExitCode::SUCCESS);
    }
    let mut frozen: Vec<&str> = Vec::new();
    for f in files {
        let abs = root.join(f);
        let owner = members
            .iter()
            .filter(|m| abs.starts_with(&m.dir))
            .max_by_key(|m| m.dir.components().count());
        if let Some(m) = owner
            && !table.is_clean(&m.name)
            && !frozen.contains(&m.name.as_str())
        {
            frozen.push(&m.name);
        }
    }
    if frozen.is_empty() {
        return Ok(ExitCode::SUCCESS);
    }
    println!(
        "standards: this commit touches {}, not clean yet: such a crate takes migration commits only (D15). Start the subject with `migrate` if it is one (docs/develop/standards/README.md).",
        frozen.join(", ")
    );
    Ok(ExitCode::from(1))
}
