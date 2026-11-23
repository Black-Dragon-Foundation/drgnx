//! The settings standard's conformance test: one schema, the eight levels, provenance with file and line, one
//! consistent snapshot for a command, atomic writes (docs/develop/standards/settings.md).

use std::path::PathBuf;

use serde_json::{Value, json};
use skipan::{Kind, Level, Scope, Settings, Source};

fn settings() -> Settings {
    let s = Settings::new();
    s.define("editor.tab-width", Kind::Int, json!(8))
        .expect("defines");
    s.define("editor.theme", Kind::Str, json!("light"))
        .expect("defines");
    s.define("editor.wrap", Kind::Bool, json!(false))
        .expect("defines");
    s.define("editor.ruler", Kind::Float, json!(1.5))
        .expect("defines");
    s.define("editor.fonts", Kind::List, json!(["mono"]))
        .expect("defines");
    s
}

fn put(path: &std::path::Path, text: &str) {
    eitri::replace_file(path, text.as_bytes()).expect("the file is written");
}

fn user_file(sb: &raun::Sandbox) -> PathBuf {
    sb.home().join("user.eld")
}

#[test]
fn provenance_names_file_and_line() {
    let sb = raun::Sandbox::new();
    let path = user_file(&sb);
    put(
        &path,
        "(drgnx-settings :version 1\n (editor.tab-width 4)\n (editor.theme \"dark\")\n (editor.wrap t)\n (editor.fonts (\"a\" \"b\")))\n",
    );
    let s = settings();
    s.attach(Level::User, &path).expect("attaches");
    assert_eq!(s.reload().expect("reloads"), Vec::<String>::new());

    assert_eq!(s.get::<i64>("editor.tab-width").expect("get"), 4);
    assert_eq!(s.get::<String>("editor.theme").expect("get"), "dark");
    assert!(s.get::<bool>("editor.wrap").expect("get"));
    assert_eq!(
        s.get::<Vec<String>>("editor.fonts").expect("get"),
        ["a", "b"]
    );
    let p = s.provenance("editor.tab-width").expect("provenance");
    assert_eq!(p.level, Level::User);
    assert_eq!(
        p.source,
        Source::File {
            path: path.clone(),
            line: 2
        }
    );
    let theme = s.provenance("editor.theme").expect("provenance");
    assert_eq!(
        theme.source,
        Source::File {
            path: path.clone(),
            line: 3
        }
    );
    assert!(theme.to_string().contains("user.eld:3"), "{theme}");
    // an unset key answers with the default, and says so
    let d = s.provenance("editor.ruler").expect("provenance");
    assert_eq!((d.level, d.source), (Level::BuiltIn, Source::Default));
    assert!((s.get::<f64>("editor.ruler").expect("get") - 1.5).abs() < f64::EPSILON);
    assert_eq!(
        s.get::<i64>("nope").expect_err("unknown").kind(),
        villa::Kind::NotFound
    );
}

#[test]
fn the_levels_stack_most_specific_last() {
    let s = settings();
    let key = "editor.tab-width";
    let get = |scope: &Scope| s.snapshot().get_in::<i64>(key, scope).expect("get");
    let level = |scope: &Scope| {
        s.snapshot()
            .provenance_in(key, scope)
            .expect("provenance")
            .level
    };
    let none = Scope::default();
    assert_eq!((get(&none), level(&none)), (8, Level::BuiltIn));

    // the file-less levels are in memory; the order is user < machine < project < stream < language < document < pane
    s.set(key, json!(1), Level::User).expect("user");
    s.set(key, json!(2), Level::Machine).expect("machine");
    s.set(key, json!(3), Level::Project).expect("project");
    assert_eq!((get(&none), level(&none)), (3, Level::Project));
    s.set_scoped(key, json!(4), Level::Stream, "task-7")
        .expect("stream");
    s.set_scoped(key, json!(5), Level::Language, "rust")
        .expect("language");
    s.set_scoped(key, json!(6), Level::Document, "a.rs")
        .expect("document");
    s.set_scoped(key, json!(7), Level::Pane, "p1")
        .expect("pane");

    let mut scope = Scope {
        stream: Some("task-7".into()),
        ..Scope::default()
    };
    assert_eq!((get(&scope), level(&scope)), (4, Level::Stream));
    scope.language = Some("rust".into());
    assert_eq!((get(&scope), level(&scope)), (5, Level::Language));
    scope.document = Some("a.rs".into());
    assert_eq!((get(&scope), level(&scope)), (6, Level::Document));
    scope.pane = Some("p1".into());
    assert_eq!((get(&scope), level(&scope)), (7, Level::Pane));
    // another language, another stream: the scoped values do not apply
    let other = Scope {
        stream: Some("task-8".into()),
        language: Some("python".into()),
        ..Scope::default()
    };
    assert_eq!((get(&other), level(&other)), (3, Level::Project));

    // refused: the built-in level, a scoped level without an id, a wrong type, an undefined key
    assert_eq!(
        s.set(key, json!(1), Level::BuiltIn)
            .expect_err("fixed")
            .kind(),
        villa::Kind::Refused
    );
    assert_eq!(
        s.set(key, json!(1), Level::Pane)
            .expect_err("needs an id")
            .kind(),
        villa::Kind::Invalid
    );
    assert_eq!(
        s.set(key, json!("x"), Level::User)
            .expect_err("a string")
            .kind(),
        villa::Kind::Invalid
    );
    assert_eq!(
        s.set("nope", json!(1), Level::User)
            .expect_err("undefined")
            .kind(),
        villa::Kind::NotFound
    );
    // an extension's override, for a language, says whose it is
    s.set_by_extension(
        "vim-keys",
        "editor.theme",
        json!("night"),
        Level::Language,
        "rust",
    )
    .expect("extension");
    let rust = Scope {
        language: Some("rust".into()),
        ..Scope::default()
    };
    assert_eq!(
        s.snapshot()
            .provenance_in("editor.theme", &rust)
            .expect("provenance")
            .source,
        Source::Extension("vim-keys".into())
    );
    assert_eq!(
        s.get::<String>("editor.theme").expect("get"),
        "light",
        "other languages do not see it"
    );
}

#[test]
fn reload_mid_command_sees_one_snapshot() {
    let sb = raun::Sandbox::new();
    let path = user_file(&sb);
    put(
        &path,
        "(drgnx-settings :version 1\n (editor.tab-width 4))\n",
    );
    let s = settings();
    s.attach(Level::User, &path).expect("attaches");
    s.reload().expect("reloads");
    let changes = s.watch();

    // a command starts, and reads its snapshot
    let snap = s.snapshot();
    assert_eq!(snap.get::<i64>("editor.tab-width").expect("get"), 4);

    // the file changes under it, and the settings reload; a `set` lands too
    put(
        &path,
        "(drgnx-settings :version 1\n (editor.tab-width 2)\n (editor.theme \"dark\"))\n",
    );
    s.reload().expect("reloads");
    s.set("editor.wrap", json!(true), Level::Machine)
        .expect("set");

    // the command still sees one consistent view: the old one
    assert_eq!(snap.get::<i64>("editor.tab-width").expect("get"), 4);
    assert_eq!(snap.get::<String>("editor.theme").expect("get"), "light");
    assert!(!snap.get::<bool>("editor.wrap").expect("get"));
    // and the next command sees the new
    let now = s.snapshot();
    assert_eq!(now.get::<i64>("editor.tab-width").expect("get"), 2);
    assert_eq!(now.get::<String>("editor.theme").expect("get"), "dark");
    assert!(now.generation() > snap.generation());

    let mut keys: Vec<String> = changes.try_iter().map(|c| c.key).collect();
    keys.sort();
    keys.dedup();
    assert_eq!(keys, ["editor.tab-width", "editor.theme", "editor.wrap"]);
}

#[test]
fn set_writes_atomically() {
    let sb = raun::Sandbox::new();
    let dir = sb.home().join("cfg");
    std::fs::create_dir_all(&dir).expect("a dir");
    let path = dir.join("user.eld");
    let s = settings();
    s.attach(Level::User, &path).expect("attaches");
    s.set("editor.tab-width", json!(3), Level::User)
        .expect("set");
    s.set("editor.theme", json!("dark \"quoted\"\nline"), Level::User)
        .expect("set");
    s.set("editor.fonts", json!(["a b", "c"]), Level::User)
        .expect("set");
    s.set("editor.ruler", json!(2), Level::User)
        .expect("an integer fits a float");

    // the file is whole and the folder holds nothing else (no temporary file is left)
    let names: Vec<_> = std::fs::read_dir(&dir)
        .expect("lists")
        .flatten()
        .map(|e| e.file_name())
        .collect();
    assert_eq!(names, ["user.eld"]);
    assert_eq!(
        s.provenance("editor.theme").expect("provenance").source,
        Source::File {
            path: path.clone(),
            line: 5
        }
    );

    // a second settings object reads back what was written, with the same lines
    let again = settings();
    again.attach(Level::User, &path).expect("attaches");
    assert_eq!(again.reload().expect("reloads"), Vec::<String>::new());
    assert_eq!(again.get::<i64>("editor.tab-width").expect("get"), 3);
    assert_eq!(
        again.get::<String>("editor.theme").expect("get"),
        "dark \"quoted\"\nline"
    );
    assert_eq!(
        again.get::<Vec<String>>("editor.fonts").expect("get"),
        ["a b", "c"]
    );
    assert!((again.get::<f64>("editor.ruler").expect("get") - 2.0).abs() < f64::EPSILON);
    assert_eq!(
        again.provenance("editor.theme").expect("provenance").source,
        s.provenance("editor.theme").expect("provenance").source
    );

    // a write that fails changes nothing in memory
    let lost = settings();
    lost.attach(Level::User, sb.home().join("missing-dir/user.eld"))
        .expect("attaches");
    assert!(lost.set("editor.tab-width", json!(9), Level::User).is_err());
    assert_eq!(lost.get::<i64>("editor.tab-width").expect("get"), 8);
}

#[test]
fn a_bad_entry_is_reported_and_the_rest_stands() {
    let sb = raun::Sandbox::new();
    let path = user_file(&sb);
    put(
        &path,
        "(drgnx-settings :version 1\n (editor.tab-width \"wide\")\n (editor.unknown 1)\n (editor.theme \"dark\"))\n",
    );
    let s = settings();
    s.attach(Level::User, &path).expect("attaches");
    let problems = s.reload().expect("reloads");
    assert_eq!(problems.len(), 2, "{problems:?}");
    assert!(
        problems[0].contains("user.eld:2") && problems[0].contains("editor.tab-width"),
        "{problems:?}"
    );
    assert!(
        problems[1].contains("user.eld:3") && problems[1].contains("no setting"),
        "{problems:?}"
    );
    assert_eq!(s.get::<String>("editor.theme").expect("get"), "dark");
    assert_eq!(
        s.get::<i64>("editor.tab-width").expect("get"),
        8,
        "the bad value did not land"
    );

    // a file that does not parse keeps the level as it was
    put(&path, "(drgnx-settings :version 1 (editor.theme \"light\"");
    let problems = s.reload().expect("reloads");
    assert_eq!(problems.len(), 1, "{problems:?}");
    assert_eq!(s.get::<String>("editor.theme").expect("get"), "dark");

    // a missing file is an empty level
    let missing = settings();
    missing
        .attach(Level::Project, sb.home().join("none.eld"))
        .expect("attaches");
    assert_eq!(missing.reload().expect("reloads"), Vec::<String>::new());
    assert_eq!(missing.get::<i64>("editor.tab-width").expect("get"), 8);
    let v: Value = json!(1);
    assert_eq!(
        missing
            .define("editor.tab-width", Kind::Int, v)
            .expect_err("twice")
            .kind(),
        villa::Kind::Conflict
    );
}

#[test]
fn an_extension_cannot_set_a_file_level() {
    let sb = raun::Sandbox::new();
    let path = user_file(&sb);
    put(
        &path,
        "(drgnx-settings :version 1\n (editor.theme \"dark\"))\n",
    );
    let s = settings();
    s.attach(Level::User, &path).expect("attaches");
    s.reload().expect("reloads");
    for level in [Level::BuiltIn, Level::User, Level::Machine, Level::Project] {
        let e = s
            .set_by_extension("vim-keys", "editor.theme", json!("night"), level, "x")
            .expect_err("a level that is not the extension's");
        assert_eq!(e.kind(), villa::Kind::Refused, "{level}");
    }
    assert_eq!(s.get::<String>("editor.theme").expect("get"), "dark");
    assert_eq!(
        s.provenance("editor.theme").expect("provenance").level,
        Level::User
    );
}
