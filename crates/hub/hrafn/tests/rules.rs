//! The three layers of include, ignore and no-embed rules (`hrafn::rules`) and how the file list and the index apply
//! them.
//!
//! test-pattern: pure (D): rules are data, git runs to its exit, nothing here has a clock.

use hrafn::files::{self, Config, Snapshot};
use hrafn::rules::{Decision, Layer, List, RuleSet, Rules, Verdict, builtin_rules};
use hrafn::{CodeStore, GitCli, Listed, list, missing, refresh};
use std::path::Path;
use std::process::Command;

fn set(include: &[&str], ignore: &[&str], no_embed: &[&str]) -> RuleSet {
    let v = |a: &[&str]| a.iter().map(|s| s.to_string()).collect();
    RuleSet {
        include: v(include),
        ignore: v(ignore),
        no_embed: v(no_embed),
    }
}

fn allow_all(_: &str) -> bool {
    true
}

fn decide(r: &Rules, path: &str) -> Decision {
    r.decide(path, &allow_all)
}

fn none() -> RuleSet {
    RuleSet::default()
}

/// The `(verdict, layer)` of a decision.
fn vl(d: &Decision) -> (Verdict, Layer) {
    (d.verdict, d.layer)
}

#[test]
fn later_layer_wins() {
    let builtin = set(&[], &["*.gen"], &[]);
    let repo = set(&[], &["!*.gen"], &[]);
    let user = set(&[], &["a.gen"], &[]);
    let r = Rules::new(&builtin, &repo, &user, &[]);
    // the repo takes `*.gen` back from the built-in list, the user's own line ignores one of them again
    let b = decide(&r, "b.gen");
    assert_eq!(vl(&b), (Verdict::Index, Layer::Repo), "{b:?}");
    assert_eq!(b.rule.as_deref(), Some("!*.gen"));
    assert_eq!(b.list, List::Ignore);
    let a = decide(&r, "a.gen");
    assert_eq!(vl(&a), (Verdict::Ignored, Layer::User), "{a:?}");
    assert_eq!(a.rule.as_deref(), Some("a.gen"));
    // without the user's layer the repo's re-include stands
    let r = Rules::new(&builtin, &repo, &none(), &[]);
    assert_eq!(vl(&decide(&r, "a.gen")), (Verdict::Index, Layer::Repo));
    // without the repo's, the built-in one does
    let r = Rules::new(&builtin, &none(), &none(), &[]);
    assert_eq!(vl(&decide(&r, "a.gen")), (Verdict::Ignored, Layer::Builtin));
    // within a layer the last matching line wins
    let r = Rules::new(
        &none(),
        &set(&[], &["*.x", "!a.x", "a.x"], &[]),
        &none(),
        &[],
    );
    assert_eq!(decide(&r, "a.x").verdict, Verdict::Ignored);
    let r = Rules::new(
        &none(),
        &set(&[], &["*.x", "a.x", "!a.x"], &[]),
        &none(),
        &[],
    );
    assert_eq!(decide(&r, "a.x").verdict, Verdict::Index);
}

#[test]
fn negation_reincludes() {
    let repo = set(&[], &["!crates/x/golden/keep.rs"], &[]);
    let r = Rules::new(&builtin_rules(), &repo, &none(), &[]);
    let keep = decide(&r, "crates/x/golden/keep.rs");
    assert_eq!(vl(&keep), (Verdict::Index, Layer::Repo), "{keep:?}");
    let other = decide(&r, "crates/x/golden/other.rs");
    assert_eq!(vl(&other), (Verdict::Ignored, Layer::Builtin), "{other:?}");
    assert_eq!(other.rule.as_deref(), Some("**/golden/**"));
    assert_eq!(other.list, List::Ignore);
}

#[test]
fn include_is_an_allowlist() {
    let repo = set(&["src/**", "*.md"], &["src/gen/**"], &[]);
    let r = Rules::new(&none(), &repo, &none(), &[]);
    assert_eq!(decide(&r, "src/a.rs").verdict, Verdict::Index);
    assert_eq!(decide(&r, "README.md").verdict, Verdict::Index);
    let out = decide(&r, "docs/a.txt");
    assert_eq!(
        (out.verdict, out.layer, out.list),
        (Verdict::Ignored, Layer::Repo, List::Include),
        "{out:?}"
    );
    // the ignore list still applies inside the allowlist
    let gen_ = decide(&r, "src/gen/x.rs");
    assert_eq!((gen_.verdict, gen_.list), (Verdict::Ignored, List::Ignore));
    // a later layer's allowlist replaces the earlier one
    let user = set(&["src/a/**"], &[], &[]);
    let r = Rules::new(&none(), &repo, &user, &[]);
    assert_eq!(decide(&r, "src/a/x.rs").verdict, Verdict::Index);
    let out = decide(&r, "src/b.rs");
    assert_eq!(
        (out.verdict, out.layer, out.list),
        (Verdict::Ignored, Layer::User, List::Include)
    );
    // and no list at all lets everything in
    let r = Rules::new(&none(), &none(), &none(), &[]);
    assert_eq!(decide(&r, "anything/at/all.rs").verdict, Verdict::Index);
}

#[test]
fn deny_list_beats_every_layer() {
    // every layer tries to take them all back
    let all = set(
        &["**"],
        &["!**", "!private/**", "!.env", "!id_rsa", "!sub/nested/**"],
        &[],
    );
    let r = Rules::new(&all, &all, &all, &["sub/nested".to_string()]);
    let deny = |p: &str| !p.starts_with("private/");
    for path in [
        "private/a.rs",
        ".env",
        "id_rsa",
        ".hidden/x.rs",
        "dir/.dot.rs",
        "sub/nested/a.rs",
        "new\nline.rs",
    ] {
        let d = r.decide(path, &deny);
        assert_eq!(vl(&d), (Verdict::Ignored, Layer::Builtin), "{path}: {d:?}");
        assert!(d.rule.is_some(), "{path} says why");
    }
    assert_eq!(r.decide("ok.rs", &deny).verdict, Verdict::Index);
}

#[test]
fn defaults_list_is_the_designs() {
    let r = Rules::new(&builtin_rules(), &none(), &none(), &[]);
    // each of design section 11's patterns, by a sample path
    for path in [
        // fuzz corpora
        "fuzz/corpus/seed1",
        "a/fuzz/corpus/deep/seed2",
        "crates/x-fuzz/corpus/seed3",
        // snapshots and goldens
        "src/ui/render.snap",
        "crates/x/golden/out.txt",
        "tests/snapshots/a.txt",
        // images and SVG
        "docs/logo.png",
        "assets/icon.svg",
        "a/b/photo.jpg",
        "x.gif",
        "x.webp",
        "x.ico",
        // licence texts
        "LICENSE",
        "LICENSE-MIT",
        "LICENSE.md",
        "sub/LICENSE",
        "COPYING",
        "COPYING.LESSER",
        "LICENSES/MIT.txt",
        "THIRD_PARTY.md",
        // lock files, minified files
        "Cargo.lock",
        "web/yarn.lock",
        "package-lock.json",
        "static/app.min.js",
        "static/app.min.css",
        // vendored code
        "vendor/github.com/x/y.go",
        "third_party/zlib/zlib.c",
    ] {
        let d = decide(&r, path);
        assert_eq!(vl(&d), (Verdict::Ignored, Layer::Builtin), "{path}: {d:?}");
        assert_eq!(d.list, List::Ignore, "{path}");
        assert!(d.rule.is_some(), "{path}");
    }
    // and what they must not take
    for path in [
        "src/main.rs",
        "docs/guide.md",
        "README.md",
        "src/license_check.rs",
        "fuzz/fuzz_targets/parse.rs",
        "crates/x-fuzz/src/main.rs",
        "tests/render.rs",
        "src/vendored.rs",
        "lib/third_party_notes.rs",
    ] {
        let d = decide(&r, path);
        assert_eq!(d.verdict, Verdict::Index, "{path}: {d:?}");
    }
}

fn git(dir: &Path, args: &[&str]) {
    let st = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
        .args(args)
        .status()
        .unwrap();
    assert!(st.success(), "git {args:?}");
}

/// A repository of MANIFEST (everything added to the index) under the real path of the temp dir.
fn repo(manifest: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
    git(dir.path(), &["init", "-q"]);
    for (p, c) in manifest {
        let f = dir.path().join(p);
        std::fs::create_dir_all(f.parent().unwrap()).unwrap();
        std::fs::write(f, c).unwrap();
    }
    git(dir.path(), &["add", "-A"]);
    dir
}

fn run(dir: &Path, cfg: &Config) -> std::io::Result<Vec<Listed>> {
    list(dir, &GitCli, cfg, &allow_all)
}

fn names(l: &[Listed]) -> Vec<&str> {
    l.iter().map(|x| x.path.as_str()).collect()
}

fn user(rules: RuleSet) -> Config {
    Config {
        user: rules,
        off: false,
    }
}

#[test]
fn linguist_generated_is_ignored_by_default() {
    let d = repo(&[
        ("a.rs", "fn a() {}\n"),
        ("gen.rs", "fn g() {}\n"),
        ("vend/v.rs", "fn v() {}\n"),
        (
            ".gitattributes",
            "gen.rs linguist-generated\nvend/* linguist-vendored\n",
        ),
    ]);
    let l = run(d.path(), &Config::default()).unwrap();
    assert_eq!(names(&l), ["a.rs"], "not a generated mark: out of the list");
    let w = files::why(d.path(), &GitCli, &Config::default(), &allow_all, "gen.rs").unwrap();
    assert_eq!(vl(&w), (Verdict::Ignored, Layer::Builtin));
    assert_eq!(w.list, List::Ignore);
    assert!(w.rule.unwrap().contains("linguist"));
    assert_eq!(
        files::why(d.path(), &GitCli, &Config::default(), &allow_all, "a.rs")
            .unwrap()
            .verdict,
        Verdict::Index
    );
}

async fn store_of(d: &Path) -> CodeStore {
    CodeStore::open(&d.join(".git/code.db")).unwrap()
}

async fn index(s: &CodeStore, d: &Path, l: &[Listed]) {
    let root = d.to_path_buf();
    refresh(
        s,
        l,
        &move |p: &str| std::fs::read(root.join(p)),
        &[("m", 4)],
    )
    .await
    .unwrap();
}

/// (chunks, embedded chunks) of one path.
async fn chunk_counts(s: &CodeStore, path: &str) -> (i64, i64) {
    let path = path.to_string();
    s.handle()
        .read(move |c| {
            Ok(c.query_row(
                "select count(*), coalesce(sum(embed), 0) from chunk where path = ?1",
                [&path],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?)
        })
        .await
        .unwrap()
}

#[tokio::test]
async fn no_embed_is_listed_without_vectors() {
    let d = repo(&[
        ("a.rs", "fn alpha_thing() {}\n"),
        (
            "data/table.json",
            "{\"words\": \"several words of plain text for one chunk\"}\n",
        ),
    ]);
    let cfg = user(set(&[], &[], &["*.json"]));
    let l = run(d.path(), &cfg).unwrap();
    assert_eq!(
        names(&l),
        ["a.rs", "data/table.json"],
        "listed, not ignored"
    );
    let s = store_of(d.path()).await;
    index(&s, d.path(), &l).await;
    let (n, embedded) = chunk_counts(&s, "data/table.json").await;
    assert!(n > 0, "keyword and symbol search have its chunks");
    assert_eq!(embedded, 0, "no vectors wanted");
    assert!(chunk_counts(&s, "a.rs").await.1 > 0);
    let wanted = missing(&s, "m", 100).await.unwrap();
    assert!(!wanted.is_empty());
    assert!(
        wanted.iter().all(|(_, _, t)| !t.contains("plain text")),
        "missing() never offers a no-embed file: {wanted:?}"
    );
}

/// The rule moves, the file's blob does not: its chunks are written again, with the flag the rule now says.
#[tokio::test]
async fn a_no_embed_rule_added_later_rewrites_the_chunks() {
    let d = repo(&[(
        "data/table.json",
        "{\"words\": \"several words of plain text for one chunk\"}\n",
    )]);
    let s = store_of(d.path()).await;
    let l = run(d.path(), &Config::default()).unwrap();
    index(&s, d.path(), &l).await;
    let (n, embedded) = chunk_counts(&s, "data/table.json").await;
    assert!(n > 0 && embedded == n, "embedded at first");
    let l = run(d.path(), &user(set(&[], &[], &["*.json"]))).unwrap();
    index(&s, d.path(), &l).await;
    assert_eq!(chunk_counts(&s, "data/table.json").await.1, 0);
    // and taken away again
    let l = run(d.path(), &Config::default()).unwrap();
    index(&s, d.path(), &l).await;
    let (n, embedded) = chunk_counts(&s, "data/table.json").await;
    assert!(n > 0 && embedded == n);
}

#[test]
fn toml_that_cannot_be_read_turns_search_off() {
    let d = repo(&[("a.rs", "fn a() {}\n")]);
    let toml = d.path().join(".drgnx/search.toml");
    // a directory where the file should be
    std::fs::create_dir_all(&toml).unwrap();
    let e = run(d.path(), &Config::default()).unwrap_err();
    assert!(e.to_string().contains("search.toml cannot be read"), "{e}");
    std::fs::remove_dir(&toml).unwrap();
    // the other ways a file is unreadable: empty, not TOML, a key that is none of the three, a list that holds a
    // number, a value that is no list, over 64 KiB
    let big = format!("ignore = [\"{}\"]\n", "x".repeat(70 * 1024));
    for bad in [
        "",
        "ignore = [",
        "exclude = [\"a\"]\n",
        "ignore = [1]\n",
        "ignore = \"a\"\n",
        big.as_str(),
    ] {
        std::fs::write(&toml, bad).unwrap();
        let e = run(d.path(), &Config::default()).expect_err(bad);
        assert!(e.to_string().contains("search.toml cannot be read"), "{e}");
        assert!(
            files::why(d.path(), &GitCli, &Config::default(), &allow_all, "a.rs").is_err(),
            "why says so too"
        );
    }
    // readable: fine
    std::fs::write(&toml, "ignore = []\n").unwrap();
    assert_eq!(names(&run(d.path(), &Config::default()).unwrap()), ["a.rs"]);
}

#[test]
fn the_repo_file_is_a_layer_read_at_every_listing() {
    let d = repo(&[
        ("a.rs", "fn a() {}\n"),
        ("notes/n.md", "notes\n"),
        ("data/t.json", "{}\n"),
        ("licence-check/LICENSE", "text\n"),
    ]);
    let toml = d.path().join(".drgnx/search.toml");
    std::fs::create_dir_all(toml.parent().unwrap()).unwrap();
    std::fs::write(
        &toml,
        "# the team's rules\nignore = [\"notes/\", \"!licence-check/LICENSE\"]\nno-embed = [\"*.json\"]\n",
    )
    .unwrap();
    let mut snap = Snapshot::default();
    let cfg = Config::default();
    let l = files::list_with(d.path(), &GitCli, &cfg, &allow_all, &mut snap).unwrap();
    let rows: Vec<(&str, bool)> = l.iter().map(|x| (x.path.as_str(), x.embed)).collect();
    assert_eq!(
        rows,
        [
            ("a.rs", true),
            ("data/t.json", false),
            ("licence-check/LICENSE", true)
        ]
    );
    // an edit of the file takes effect at the next listing, with the same snapshot
    std::fs::write(&toml, "ignore = [\"a.rs\"]\n").unwrap();
    let l = files::list_with(d.path(), &GitCli, &cfg, &allow_all, &mut snap).unwrap();
    assert_eq!(names(&l), ["data/t.json", "notes/n.md"]);
}

#[test]
fn why_names_the_layer_that_decided() {
    let d = repo(&[
        ("a.rs", "fn a() {}\n"),
        ("vendor/v.rs", "fn v() {}\n"),
        ("src/r.rs", "fn r() {}\n"),
        ("src/u.rs", "fn u() {}\n"),
        ("data/t.json", "{}\n"),
    ]);
    std::fs::create_dir_all(d.path().join(".drgnx")).unwrap();
    std::fs::write(
        d.path().join(".drgnx/search.toml"),
        "ignore = [\"src/r.rs\"]\n",
    )
    .unwrap();
    let cfg = user(set(&[], &["src/u.rs"], &["*.json"]));
    let why = |p: &str| files::why(d.path(), &GitCli, &cfg, &allow_all, p).unwrap();
    let b = why("vendor/v.rs");
    assert_eq!(vl(&b), (Verdict::Ignored, Layer::Builtin));
    assert_eq!(
        (b.list, b.rule.as_deref()),
        (List::Ignore, Some("vendor/**"))
    );
    let r = why("src/r.rs");
    assert_eq!(vl(&r), (Verdict::Ignored, Layer::Repo));
    assert_eq!(
        (r.list, r.rule.as_deref()),
        (List::Ignore, Some("src/r.rs"))
    );
    let u = why("src/u.rs");
    assert_eq!(vl(&u), (Verdict::Ignored, Layer::User));
    assert_eq!(
        (u.list, u.rule.as_deref()),
        (List::Ignore, Some("src/u.rs"))
    );
    let n = why("data/t.json");
    assert_eq!(vl(&n), (Verdict::NoEmbed, Layer::User));
    assert_eq!(n.list, List::NoEmbed);
    let a = why("a.rs");
    assert_eq!(vl(&a), (Verdict::Index, Layer::Builtin));
    assert_eq!((a.list, a.rule), (List::Default, None));
    // a file that is not there is not indexed either
    assert_eq!(why("nope.rs").verdict, Verdict::Ignored);
}
