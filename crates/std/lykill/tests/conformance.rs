//! The keys standard's conformance test: one engine, profiles read from `.eld` files, contexts as expressions, a
//! prefix that times out on the virtual clock (docs/develop/standards/keys.md).

use std::time::Duration;

use lykill::{KeyContext, KeyEvent, Keymap, Profiles, Resolution, Session, When, parse_chord};

const EMACS: &str = "(drgnx-keys :version 1
 (find-file \"C-x C-f\")
 (save-buffer \"C-x C-s\")
 (forward-char \"C-f\")
 (execute-command \"M-x\"))
";

const VSCODE: &str = "(drgnx-keys :version 1
 (quick-open \"ctrl+p\")
 (command-palette (\"ctrl+shift+p\" \"f1\"))
 (keybindings \"ctrl+k ctrl+s\")
 (rust-only ((\"ctrl+alt+r\" \"language == rust && !readonly\"))))
";

fn profiles(sb: &raun::Sandbox) -> Profiles {
    let dir = sb.home().join("keys");
    std::fs::create_dir_all(&dir).expect("a dir");
    eitri::replace_file(&dir.join("emacs.eld"), EMACS.as_bytes()).expect("written");
    eitri::replace_file(&dir.join("vscode.eld"), VSCODE.as_bytes()).expect("written");
    let p = Profiles::load(&dir).expect("loads");
    assert!(p.problems.is_empty(), "{:?}", p.problems);
    p
}

fn chord(s: &str) -> Vec<KeyEvent> {
    parse_chord(s).expect("a chord")
}

#[test]
fn emacs_profile_resolves_c_x_c_f() {
    let sb = raun::Sandbox::new();
    let p = profiles(&sb);
    assert_eq!(p.names(), ["emacs", "vscode"]);
    let k = Keymap::from_profile(p.get("emacs").expect("the profile"));
    let cx = KeyContext::new();
    assert_eq!(k.resolve(&chord("C-x"), &cx), Resolution::Prefix);
    assert_eq!(
        k.resolve(&chord("C-x C-f"), &cx),
        Resolution::Command("find-file".into())
    );
    assert_eq!(
        k.resolve(&chord("C-x C-s"), &cx),
        Resolution::Command("save-buffer".into())
    );
    assert_eq!(
        k.resolve(&chord("M-x"), &cx),
        Resolution::Command("execute-command".into())
    );
    assert_eq!(k.resolve(&chord("C-x C-z"), &cx), Resolution::None);
    assert_eq!(k.resolve(&chord("C-q"), &cx), Resolution::None);
    // the other spelling is the same keys
    assert_eq!(chord("ctrl+x ctrl+f"), chord("C-x C-f"));
    assert_eq!(chord("alt+x"), chord("M-x"));
}

#[test]
fn vscode_profile_resolves_ctrl_p() {
    let sb = raun::Sandbox::new();
    let p = profiles(&sb);
    let k = Keymap::from_profile(p.get("vscode").expect("the profile"));
    let cx = KeyContext::new();
    assert_eq!(
        k.resolve(&chord("ctrl+p"), &cx),
        Resolution::Command("quick-open".into())
    );
    assert_eq!(
        k.resolve(&chord("ctrl+shift+p"), &cx),
        Resolution::Command("command-palette".into())
    );
    assert_eq!(
        k.resolve(&chord("f1"), &cx),
        Resolution::Command("command-palette".into())
    );
    assert_eq!(k.resolve(&chord("ctrl+k"), &cx), Resolution::Prefix);
    assert_eq!(
        k.resolve(&chord("ctrl+k ctrl+s"), &cx),
        Resolution::Command("keybindings".into())
    );
    // where the binding says: the design's example context
    let rust = KeyContext::new()
        .with("language", "rust")
        .with("view", "excerpts")
        .with_flag("readonly", false);
    assert_eq!(
        k.resolve(&chord("ctrl+alt+r"), &rust),
        Resolution::Command("rust-only".into())
    );
    let ro = rust.clone().with_flag("readonly", true);
    assert_eq!(k.resolve(&chord("ctrl+alt+r"), &ro), Resolution::None);
    assert_eq!(
        k.resolve(&chord("ctrl+alt+r"), &KeyContext::new()),
        Resolution::None
    );
    // the binding knows its file and line
    let b = k.bindings_of("quick-open");
    assert_eq!(b[0].source, Some(("vscode.eld".to_string(), 2)));
}

#[test]
fn prefix_then_timeout_is_none() {
    let sb = raun::Sandbox::new();
    let p = profiles(&sb);
    let k = Keymap::from_profile(p.get("emacs").expect("the profile"));
    let cx = KeyContext::new();
    let mut s = Session::new(Duration::from_secs(1));

    // the whole chord, inside the time: the command
    assert_eq!(s.feed(&k, KeyEvent::ctrl('x'), &cx), Resolution::Prefix);
    sb.advance(Duration::from_millis(900));
    assert!(!s.expire(), "not yet");
    assert_eq!(
        s.feed(&k, KeyEvent::ctrl('f'), &cx),
        Resolution::Command("find-file".into())
    );
    assert!(s.pending().is_empty());

    // the prefix waits too long: it is dropped, and the next key starts afresh
    assert_eq!(s.feed(&k, KeyEvent::ctrl('x'), &cx), Resolution::Prefix);
    sb.advance(Duration::from_secs(2));
    assert!(s.expire(), "the prefix timed out");
    assert!(s.pending().is_empty());
    assert_eq!(
        s.feed(&k, KeyEvent::ctrl('f'), &cx),
        Resolution::Command("forward-char".into())
    );

    // `feed` expires a stale prefix itself
    assert_eq!(s.feed(&k, KeyEvent::ctrl('x'), &cx), Resolution::Prefix);
    sb.advance(Duration::from_secs(5));
    assert_eq!(
        s.feed(&k, KeyEvent::ctrl('s'), &cx),
        Resolution::None,
        "C-s alone is bound to nothing here"
    );
}

#[test]
fn a_later_binding_wins_and_a_command_beats_a_prefix() {
    let mut k = Keymap::new();
    k.bind("C-x C-f", "find-file", "").expect("binds");
    k.bind("C-x", "cut", "").expect("binds");
    let cx = KeyContext::new();
    assert_eq!(
        k.resolve(&chord("C-x"), &cx),
        Resolution::Command("cut".into())
    );
    k.bind("C-x", "other-cut", "").expect("binds");
    assert_eq!(
        k.resolve(&chord("C-x"), &cx),
        Resolution::Command("other-cut".into())
    );
    k.bind("C-x", "only-in-rust", "language == rust")
        .expect("binds");
    assert_eq!(
        k.resolve(&chord("C-x"), &cx),
        Resolution::Command("other-cut".into())
    );
    assert_eq!(
        k.resolve(&chord("C-x"), &KeyContext::new().with("language", "rust")),
        Resolution::Command("only-in-rust".into())
    );
}

#[test]
fn context_expressions_are_small_and_checked() {
    let cx = KeyContext::new()
        .with("language", "rust")
        .with("view", "excerpts")
        .with_flag("readonly", false)
        .with_flag("on", true);
    let holds = |t: &str| When::parse(t).expect("parses").holds(&cx);
    assert!(holds("language == rust && view == excerpts && !readonly"));
    assert!(holds("language == \"rust\""));
    assert!(holds("language != python"));
    assert!(holds("(language == python || view == excerpts) && on"));
    assert!(holds("readonly == false"));
    assert!(holds("on == true"));
    assert!(holds(""), "no expression binds everywhere");
    assert!(!holds("language == python"));
    assert!(!holds("missing"), "a term the context lacks is false");
    assert!(!holds("language == rust && readonly"));
    assert!(holds("!missing"));
    for bad in [
        "language ==",
        "(language == rust",
        "language == rust)",
        "a b",
        "a & b",
        "a == == b",
        "\"open",
        "=a",
        "a ==  && b",
    ] {
        assert_eq!(
            When::parse(bad).expect_err(bad).kind(),
            villa::Kind::Invalid,
            "{bad}"
        );
    }
    let deep = format!("{}a{}", "(".repeat(200), ")".repeat(200));
    assert!(When::parse(&deep).is_err(), "nesting is bounded");
    let long = vec!["a"; 400].join(" || ");
    assert!(When::parse(&long).is_err(), "length is bounded");
}

#[test]
fn a_bad_chord_or_binding_is_reported_and_the_rest_stands() {
    let sb = raun::Sandbox::new();
    let dir = sb.home().join("keys");
    std::fs::create_dir_all(&dir).expect("a dir");
    eitri::replace_file(
        &dir.join("mixed.eld"),
        b"(drgnx-keys :version 1\n (good \"C-a\")\n (bad-key \"C-nope-nope\")\n (bad-when ((\"C-b\" \"a ==\")))\n (not-text 5))\n",
    )
    .expect("written");
    eitri::replace_file(
        &dir.join("broken.eld"),
        b"(drgnx-keys :version 1 (a \"C-a\"",
    )
    .expect("written");
    let p = Profiles::load(&dir).expect("loads");
    assert_eq!(p.problems.len(), 4, "{:?}", p.problems);
    assert!(
        p.problems.iter().any(|m| m.contains("mixed.eld:3")),
        "{:?}",
        p.problems
    );
    assert!(
        p.problems.iter().any(|m| m.contains("mixed.eld:4")),
        "{:?}",
        p.problems
    );
    assert!(
        p.problems.iter().any(|m| m.contains("mixed.eld:5")),
        "{:?}",
        p.problems
    );
    assert!(
        p.problems.iter().any(|m| m.contains("broken")),
        "{:?}",
        p.problems
    );
    let k = Keymap::from_profile(p.get("mixed").expect("the good entry stands"));
    assert_eq!(
        k.resolve(&chord("C-a"), &KeyContext::new()),
        Resolution::Command("good".into())
    );
    assert!(p.get("broken").is_none());
}

#[test]
fn an_extension_cannot_bind_a_reserved_key() {
    let mut k = Keymap::new();
    let ext = bod::Origin::Extension("vim".into());
    for chord in ["C-g", "C-g C-x", "M-x", "ctrl+shift+p", "f1", "ctrl+g"] {
        let e = k.bind_by(&ext, chord, "evil", "").expect_err(chord);
        assert_eq!(e.kind(), villa::Kind::Refused, "{chord}");
    }
    assert!(k.bindings().is_empty());
    // the same chords are fine for the user, and an extension's other chords are fine for it
    k.bind_by(&bod::Origin::User, "C-g", "cancel", "")
        .expect("the user may");
    k.bind_by(&ext, "C-x C-v", "vim-visit", "")
        .expect("an ordinary chord");
    assert_eq!(
        k.resolve(&chord("C-g"), &KeyContext::new()),
        Resolution::Command("cancel".into())
    );
}

#[test]
fn an_extension_cannot_shadow_a_prefix() {
    let mut k = Keymap::new();
    let ext = bod::Origin::Extension("vim".into());
    k.bind_by(&bod::Origin::User, "C-x C-f", "find-file", "")
        .expect("the user's chord");
    // `C-x` alone would turn the user's two-key chord into something the extension decides
    let e = k
        .bind_by(&ext, "C-x", "evil", "")
        .expect_err("shadows C-x C-f");
    assert_eq!(e.kind(), villa::Kind::Refused);
    k.bind_by(&ext, "C-y", "ok", "").expect("a free key");
    k.bind_by(&ext, "C-x C-f C-v", "longer", "")
        .expect("a longer chord does not shadow");
    assert_eq!(
        k.resolve(&chord("C-x C-f"), &KeyContext::new()),
        Resolution::Command("find-file".into())
    );
    k.bind_by(&bod::Origin::User, "C-x", "user-cut", "")
        .expect("the user may");
}
