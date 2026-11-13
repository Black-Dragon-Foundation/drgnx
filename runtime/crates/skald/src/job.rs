//! The pack job's grammar half (design §5.2, Task 2a): for each pinned grammar, fetch it at its commit (shallow, then
//! full), check the tree hash, build `parser.c` (and a scanner) into a shared library with the `cc` crate configured
//! for runtime, check that it loads and reports an ABI at or above the floor, hash the library, and compile the
//! pack's queries against it. Everything happens in a work folder under the staging folder; only when every unit
//! passed are the libraries moved into `grammars/NAME/COMMIT/`, so a failure leaves the staging folder as it was.
//!
//! The library is loaded here to check it (dlopen runs its constructors): the job runs inside the pack job's own
//! process, which Task 2b hands to the sandbox. Sync (Task 2b) owns the lock, `active.eld` and the move out of staging.

use std::fmt;
use std::path::{Path, PathBuf};
use std::process::Command;

use sha2::{Digest, Sha256};
use tree_sitter::Language;
use tree_sitter_language::LanguageFn;

/// The shared library extension on this platform.
pub const LIB_EXT: &str = if cfg!(target_vendor = "apple") {
    "dylib"
} else {
    "so"
};

/// A grammar to fetch and build: a manifest's owned `:grammars` entry.
#[derive(Clone, Debug)]
pub struct Unit {
    pub name: String,
    pub repo: String,
    pub commit: String,
    pub tree_sha256: String,
    /// The folder holding `parser.c`, relative to the repository root (`src`, `tsx/src`).
    pub src: String,
}

/// A query file to compile against a grammar.
#[derive(Clone, Debug)]
pub struct Query {
    pub grammar: String,
    /// Shown in an error (`queries/tags.scm`).
    pub file: String,
    pub text: String,
}

#[derive(Clone, Debug)]
pub struct Options {
    /// Where results land: `STAGING/grammars/NAME/COMMIT/`. Work files live in a folder of it that is always removed.
    pub staging: PathBuf,
    /// The lowest tree-sitter ABI a grammar may report (the design's one ABI is 15).
    pub min_abi: u32,
}

/// A grammar that passed every check.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Staged {
    pub name: String,
    pub commit: String,
    pub tree_sha256: String,
    pub lib: PathBuf,
    pub lib_sha256: String,
    pub abi: u32,
}

#[derive(Debug)]
pub enum JobError {
    Fetch(String),
    /// A file the tree hash cannot cover (a symlink, a device).
    Tree(String),
    TreeHash {
        name: String,
        expected: String,
        got: String,
    },
    Build(String),
    Load(String),
    Abi {
        name: String,
        found: u32,
        min: u32,
    },
    LibHash {
        expected: String,
        got: String,
    },
    Query {
        file: String,
        message: String,
    },
    Io(String),
}

impl fmt::Display for JobError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            JobError::Fetch(m) => write!(f, "fetch failed: {m}"),
            JobError::Tree(m) => write!(f, "the tree cannot be hashed: {m}"),
            JobError::TreeHash {
                name,
                expected,
                got,
            } => {
                write!(f, "the {name} tree hash is {got}, the pack pins {expected}")
            }
            JobError::Build(m) => write!(f, "build failed: {m}"),
            JobError::Load(m) => write!(f, "the library does not load: {m}"),
            JobError::Abi { name, found, min } => {
                write!(
                    f,
                    "the {name} grammar is ABI {found}, below the floor {min}"
                )
            }
            JobError::LibHash { expected, got } => {
                write!(f, "the library hash is {got}, the lock has {expected}")
            }
            JobError::Query { file, message } => write!(f, "{file}: {message}"),
            JobError::Io(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for JobError {}

fn io(what: &str, e: std::io::Error) -> JobError {
    JobError::Io(format!("{what}: {e}"))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The sha256 of a file, in hex.
pub fn file_sha256(path: &Path) -> Result<String, JobError> {
    let bytes = std::fs::read(path).map_err(|e| io(&path.display().to_string(), e))?;
    Ok(hex(&Sha256::digest(&bytes)))
}

/// The tree hash (design §3.3): sha256 over the sorted lines `MODE PATH sha256(blob)` of the files under DIR, one
/// line each ending in a newline, MODE `100644` or `100755`. A top-level `.git` is not part of the tree; a symlink
/// or any file that is not a regular file is refused. It depends on neither git's SHA-1 nor `git archive`.
pub fn tree_hash(dir: &Path) -> Result<String, JobError> {
    fn walk(
        root: &Path,
        dir: &Path,
        out: &mut Vec<(String, bool, String)>,
    ) -> Result<(), JobError> {
        for entry in std::fs::read_dir(dir).map_err(|e| io(&dir.display().to_string(), e))? {
            let entry = entry.map_err(|e| io("reading a folder", e))?;
            let path = entry.path();
            let rel = path
                .strip_prefix(root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            if dir == root && rel == ".git" {
                continue;
            }
            let meta = std::fs::symlink_metadata(&path).map_err(|e| io(&rel, e))?;
            if meta.is_dir() {
                walk(root, &path, out)?;
            } else if meta.is_file() {
                use std::os::unix::fs::PermissionsExt;
                let exec = meta.permissions().mode() & 0o111 != 0;
                out.push((rel, exec, file_sha256(&path)?));
            } else {
                return Err(JobError::Tree(format!("{rel} is not a regular file")));
            }
        }
        Ok(())
    }
    let mut files = Vec::new();
    walk(dir, dir, &mut files)?;
    files.sort_by(|a, b| a.0.cmp(&b.0));
    let mut h = Sha256::new();
    for (path, exec, sha) in files {
        h.update(format!(
            "{} {path} {sha}\n",
            if exec { "100755" } else { "100644" }
        ));
    }
    Ok(hex(&h.finalize()))
}

fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_ASKPASS", "true")
        .args([
            "-c",
            "protocol.ext.allow=never",
            "-c",
            "core.hooksPath=/dev/null",
        ])
        .args(args)
        .output()
        .map_err(|e| format!("git: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

/// REPO at COMMIT into DEST: a shallow fetch of the bare commit (GitHub and GitLab allow it), else a full fetch.
fn fetch(repo: &str, commit: &str, dest: &Path) -> Result<(), JobError> {
    std::fs::create_dir_all(dest).map_err(|e| io("work folder", e))?;
    let f = |m: String| JobError::Fetch(m);
    git(dest, &["init", "-q"]).map_err(f)?;
    if git(dest, &["fetch", "-q", "--depth", "1", "--", repo, commit]).is_err() {
        git(
            dest,
            &[
                "fetch",
                "-q",
                "--tags",
                "--",
                repo,
                "+refs/heads/*:refs/remotes/pack/*",
            ],
        )
        .map_err(f)?;
    }
    git(dest, &["checkout", "-q", "--detach", commit])
        .map_err(|e| JobError::Fetch(format!("{commit} is not in {repo}: {e}")))?;
    let head = git(dest, &["rev-parse", "HEAD"]).map_err(JobError::Fetch)?;
    if head.eq_ignore_ascii_case(commit) {
        Ok(())
    } else {
        Err(JobError::Fetch(format!(
            "checked out {head}, wanted {commit}"
        )))
    }
}

/// `parser.c` (and a scanner) of SRC into the shared library OUT.
fn build(name: &str, src: &Path, work: &Path, out: &Path) -> Result<(), JobError> {
    let b = |m: String| JobError::Build(m);
    let parser = src.join("parser.c");
    if !parser.is_file() {
        return Err(b(format!("{name}: no parser.c in {}", src.display())));
    }
    let objdir = work.join("obj");
    std::fs::create_dir_all(&objdir).map_err(|e| io("object folder", e))?;
    let base = |cpp: bool| {
        let mut c = cc::Build::new();
        c.target(env!("SKALD_TARGET"))
            .host(env!("SKALD_HOST"))
            .opt_level(2)
            .debug(false)
            .pic(true)
            .warnings(false)
            .cargo_metadata(false)
            .cargo_warnings(false)
            .cargo_debug(false)
            .cargo_output(false)
            .out_dir(&objdir)
            .include(src)
            .cpp(cpp);
        c
    };
    let mut c_build = base(false);
    c_build.file(&parser);
    if src.join("scanner.c").is_file() {
        c_build.file(src.join("scanner.c"));
    }
    let mut objects = c_build
        .try_compile_intermediates()
        .map_err(|e| b(format!("{name}: {e}")))?;
    let mut linker = c_build.get_compiler();
    if src.join("scanner.cc").is_file() {
        let mut cpp = base(true);
        cpp.file(src.join("scanner.cc"));
        objects.extend(
            cpp.try_compile_intermediates()
                .map_err(|e| b(format!("{name}: {e}")))?,
        );
        linker = cpp.get_compiler();
    }
    let mut cmd = linker.to_command();
    cmd.arg(if cfg!(target_vendor = "apple") {
        "-dynamiclib"
    } else {
        "-shared"
    })
    .arg("-o")
    .arg(out)
    .args(&objects);
    let result = cmd
        .output()
        .map_err(|e| b(format!("{name}: linker: {e}")))?;
    if result.status.success() {
        Ok(())
    } else {
        Err(b(format!(
            "{name}: link: {}",
            String::from_utf8_lossy(&result.stderr).trim()
        )))
    }
}

/// The library at PATH and its `tree_sitter_NAME` language. The library must outlive the language and anything
/// built from it (a tree, a query): never drop it while either is in use.
pub fn load(path: &Path, name: &str) -> Result<(libloading::Library, Language), JobError> {
    let l = |m: String| JobError::Load(format!("{}: {m}", path.display()));
    let symbol = format!("tree_sitter_{}\0", name.replace('-', "_"));
    // SAFETY: loading a grammar library runs its initialisers, as every tree-sitter host's loader does; the symbol is
    // the grammar's `const TSLanguage *tree_sitter_NAME(void)`.
    unsafe {
        let lib = libloading::Library::new(path).map_err(|e| l(e.to_string()))?;
        let f: libloading::Symbol<unsafe extern "C" fn() -> *const ()> =
            lib.get(symbol.as_bytes()).map_err(|e| l(e.to_string()))?;
        let language = Language::from(LanguageFn::from_raw(*f));
        Ok((lib, language))
    }
}

/// The local integrity check the hub and the editor's loader run: the library's hash is the lock's and its ABI is at
/// least MIN_ABI. Returns the ABI.
pub fn verify_lib(
    path: &Path,
    name: &str,
    expected_sha256: &str,
    min_abi: u32,
) -> Result<u32, JobError> {
    let got = file_sha256(path)?;
    if got != expected_sha256 {
        return Err(JobError::LibHash {
            expected: expected_sha256.into(),
            got,
        });
    }
    let (_lib, language) = load(path, name)?;
    let abi = language.abi_version() as u32;
    if abi < min_abi {
        return Err(JobError::Abi {
            name: name.into(),
            found: abi,
            min: min_abi,
        });
    }
    Ok(abi)
}

/// Removes its folder when dropped, so a failed job leaves nothing in staging.
struct Work(PathBuf);

impl Drop for Work {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn safe_rel(s: &str) -> bool {
    !s.is_empty() && !s.starts_with('/') && s.split('/').all(|c| !c.is_empty() && c != "..")
}

/// Fetches, checks, builds and loads every unit, compiles QUERIES against their grammars, and only then moves the
/// libraries into `STAGING/grammars/NAME/COMMIT/`. A unit whose folder is already there (content-addressed) is kept.
pub fn run(units: &[Unit], queries: &[Query], opts: &Options) -> Result<Vec<Staged>, JobError> {
    std::fs::create_dir_all(&opts.staging).map_err(|e| io("staging folder", e))?;
    let work = Work(opts.staging.join(format!(".work-{}", std::process::id())));
    let _ = std::fs::remove_dir_all(&work.0);
    std::fs::create_dir_all(&work.0).map_err(|e| io("work folder", e))?;

    let mut built: Vec<(Staged, PathBuf)> = Vec::new();
    for u in units {
        if !safe_rel(&u.src) {
            return Err(JobError::Build(format!(
                "{}: the source folder {:?} is not a folder inside the repository",
                u.name, u.src
            )));
        }
        let tree = work.0.join(format!("tree-{}", u.name));
        fetch(&u.repo, &u.commit, &tree)?;
        let got = tree_hash(&tree)?;
        if got != u.tree_sha256 {
            return Err(JobError::TreeHash {
                name: u.name.clone(),
                expected: u.tree_sha256.clone(),
                got,
            });
        }
        let lib_dir = work.0.join(format!("lib-{}", u.name));
        std::fs::create_dir_all(&lib_dir).map_err(|e| io("library folder", e))?;
        let lib = lib_dir.join(format!("libtree-sitter-{}.{LIB_EXT}", u.name));
        build(
            &u.name,
            &tree.join(&u.src),
            &work.0.join(format!("build-{}", u.name)),
            &lib,
        )?;
        let lib_sha256 = file_sha256(&lib)?;
        let (library, language) = load(&lib, &u.name)?;
        let abi = language.abi_version() as u32;
        if abi < opts.min_abi {
            return Err(JobError::Abi {
                name: u.name.clone(),
                found: abi,
                min: opts.min_abi,
            });
        }
        for q in queries.iter().filter(|q| q.grammar == u.name) {
            tree_sitter::Query::new(&language, &q.text).map_err(|e| JobError::Query {
                file: q.file.clone(),
                message: e.to_string(),
            })?;
        }
        drop(language);
        drop(library);
        let dest = opts.staging.join("grammars").join(&u.name).join(&u.commit);
        let staged = Staged {
            name: u.name.clone(),
            commit: u.commit.clone(),
            tree_sha256: got,
            lib: dest.join(lib.file_name().expect("a file name")),
            lib_sha256,
            abi,
        };
        built.push((staged, lib_dir));
    }
    for (s, lib_dir) in &built {
        let dest = s.lib.parent().expect("a folder");
        if dest.exists() {
            continue;
        }
        std::fs::create_dir_all(dest.parent().expect("a folder"))
            .map_err(|e| io("grammars folder", e))?;
        std::fs::rename(lib_dir, dest)
            .map_err(|e| io(&format!("moving {} into place", s.name), e))?;
    }
    Ok(built.into_iter().map(|(s, _)| s).collect())
}
