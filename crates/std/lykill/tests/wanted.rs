//! An extension's bindings: prefix checks within one context, shadowing between extensions, and the user's own level
//! that rebinds or unbinds an extension's chord without touching the extension.

use lykill::{KeyContext, KeyEvent, Keymap, Resolution, WantedState, parse_chord};

fn chord(s: &str) -> Vec<KeyEvent> {
    parse_chord(s).expect("a chord")
}

fn ext(name: &str) -> bod::Origin {
    bod::Origin::Extension(name.into())
}

fn run(k: &Keymap, c: &str) -> Resolution {
    k.resolve(&chord(c), &KeyContext::new())
}

fn rust() -> KeyContext {
    KeyContext::new().with("language", "rust")
}

#[test]
fn a_prefix_in_another_context_does_not_refuse_a_binding() {
    let mut k = Keymap::new();
    k.bind("C-x C-f", "find-file", "language == go")
        .expect("go's");
    // `C-x` in Rust is not a prefix of anything in Rust
    k.bind_by(&ext("vim"), "C-x", "vim-cut", "language == rust")
        .expect("another context");
    assert_eq!(
        k.resolve(&chord("C-x"), &rust()),
        Resolution::Command("vim-cut".into())
    );
    // and the same chord in the same context is refused
    k.bind("C-w C-q", "close-all", "language == rust")
        .expect("rust's");
    let e = k
        .bind_by(&ext("vim"), "C-w", "vim-win", "language == rust")
        .expect_err("a prefix in its own context");
    assert_eq!(e.kind(), villa::Kind::Refused);
}

#[test]
fn a_profile_layered_in_another_context_drops_nothing() {
    let mut k = Keymap::new();
    k.bind_by(&ext("vim"), "C-y", "vim-yank", "language == rust")
        .expect("bound");
    let (go, _) = lykill::Profile::parse(
        "go",
        b"(drgnx-keys :version 1\n (paste ((\"C-y C-z\" \"language == go\"))))\n",
    )
    .expect("parses");
    assert!(k.layer(&go).is_empty(), "another context");
    assert_eq!(
        k.resolve(&chord("C-y"), &rust()),
        Resolution::Command("vim-yank".into())
    );
    let (rs, _) = lykill::Profile::parse(
        "rs",
        b"(drgnx-keys :version 1\n (paste ((\"C-y C-z\" \"language == rust\"))))\n",
    )
    .expect("parses");
    assert_eq!(k.layer(&rs).len(), 1, "the same context");
}

#[test]
fn an_extension_cannot_extend_another_extensions_chord() {
    let mut k = Keymap::new();
    k.bind_by(&ext("a"), "C-y", "ext/a/yank", "").expect("A's");
    let e = k
        .bind_by(&ext("b"), "C-y C-z", "ext/b/zap", "")
        .expect_err("B's chord could never be reached");
    assert_eq!(e.kind(), villa::Kind::Refused);
    assert_eq!(run(&k, "C-y C-z"), Resolution::None);
    // in another context it is reachable, so it is fine
    k.bind_by(&ext("b"), "C-y C-z", "ext/b/zap", "language == rust")
        .expect("another context");
    assert_eq!(
        k.resolve(&chord("C-y C-z"), &rust()),
        Resolution::Command("ext/b/zap".into())
    );
}

#[test]
fn every_extension_binding_is_kept_with_what_became_of_it() {
    let mut k = Keymap::new();
    k.bind_by(&ext("a"), "C-y", "ext/a/yank", "")
        .expect("bound");
    k.bind_by(&ext("b"), "C-g", "ext/b/evil", "")
        .expect_err("reserved");
    k.bind_by(&ext("b"), "C-y C-z", "ext/b/zap", "")
        .expect_err("clash");
    let (p, _) = lykill::Profile::parse("mine", b"(drgnx-keys :version 1\n (x \"C-w C-q\"))\n")
        .expect("parses");
    k.bind_by(&ext("a"), "C-w", "ext/a/win", "").expect("bound");
    k.layer(&p);
    let state = |ext: &str, c: &str| {
        k.wanted()
            .iter()
            .find(|w| w.extension == ext && w.chord == chord(c))
            .map(|w| w.state.clone())
    };
    assert_eq!(state("a", "C-y"), Some(WantedState::Bound));
    assert!(matches!(state("b", "C-g"), Some(WantedState::Refused(_))));
    assert!(matches!(
        state("b", "C-y C-z"),
        Some(WantedState::Refused(_))
    ));
    assert!(matches!(state("a", "C-w"), Some(WantedState::Dropped(_))));
}

#[test]
fn a_refused_clash_rebound_by_the_user_runs_the_command_on_the_new_chord() {
    let mut k = Keymap::new();
    k.bind_by(&ext("a"), "C-y", "ext/a/yank", "").expect("A's");
    k.bind_by(&ext("b"), "C-y C-z", "ext/b/zap", "")
        .expect_err("clash");
    k.rebind_by_user("ext/b/zap", &chord("C-y C-z"), "C-c z")
        .expect("the user's choice");
    assert_eq!(run(&k, "C-c z"), Resolution::Command("ext/b/zap".into()));
    assert_eq!(run(&k, "C-y C-z"), Resolution::None);
    let w = k
        .wanted()
        .iter()
        .find(|w| w.command == "ext/b/zap")
        .expect("kept");
    assert_eq!(w.state, WantedState::Rebound(chord("C-c z")));
    assert_eq!(
        w.chord,
        chord("C-y C-z"),
        "what the extension asked is unchanged"
    );
}

#[test]
fn the_override_survives_the_extension_reloading() {
    let mut k = Keymap::new();
    k.bind_by(&ext("a"), "C-y", "ext/a/yank", "").expect("A's");
    k.bind_by(&ext("b"), "C-y C-z", "ext/b/zap", "")
        .expect_err("clash");
    k.rebind_by_user("ext/b/zap", &chord("C-y C-z"), "C-c z")
        .expect("rebound");
    // B reloads and asks again: no refusal, and the command stays on the user's chord
    k.unload_extension("b");
    k.bind_by(&ext("b"), "C-y C-z", "ext/b/zap", "")
        .expect("the user's override applies, there is nothing to refuse");
    assert_eq!(run(&k, "C-c z"), Resolution::Command("ext/b/zap".into()));
    assert_eq!(run(&k, "C-y C-z"), Resolution::None);
    // the keys are the user's, so A's `C-y` is still A's
    assert_eq!(run(&k, "C-y"), Resolution::Command("ext/a/yank".into()));
    // the host that saved the overrides gets them back after a restart
    let saved = k.overrides().to_vec();
    let mut fresh = Keymap::new();
    fresh.set_overrides(saved);
    fresh
        .bind_by(&ext("b"), "C-y C-z", "ext/b/zap", "")
        .expect("applies");
    assert!(matches!(
        fresh.wanted()[0].state,
        WantedState::Rebound(ref to) if *to == chord("C-c z")
    ));
}

#[test]
fn the_user_unbinding_an_extension_chord_sticks() {
    let mut k = Keymap::new();
    k.bind_by(&ext("a"), "C-y", "ext/a/yank", "").expect("A's");
    k.unbind_by_user("ext/a/yank", &chord("C-y"))
        .expect("unbound");
    assert_eq!(run(&k, "C-y"), Resolution::None);
    k.unload_extension("a");
    k.bind_by(&ext("a"), "C-y", "ext/a/yank", "")
        .expect("accepted, not applied");
    assert_eq!(
        run(&k, "C-y"),
        Resolution::None,
        "still unbound after a reload"
    );
    assert_eq!(k.wanted()[0].state, WantedState::Unbound);
}

#[test]
fn the_users_level_wins_over_every_extension() {
    let mut k = Keymap::new();
    k.bind_by(&ext("a"), "C-y", "ext/a/yank", "").expect("A's");
    k.bind_by(&ext("b"), "C-t", "ext/b/tab", "").expect("B's");
    k.rebind_by_user("ext/b/tab", &chord("C-t"), "C-y")
        .expect("onto A's chord");
    assert_eq!(run(&k, "C-y"), Resolution::Command("ext/b/tab".into()));
    assert_eq!(
        run(&k, "C-t"),
        Resolution::None,
        "the extension's own chord is gone"
    );
    // a later extension binding of the same chord does not take it back
    k.bind_by(&ext("c"), "C-y", "ext/c/other", "").expect("C's");
    assert_eq!(run(&k, "C-y"), Resolution::Command("ext/b/tab".into()));
    // deciding again replaces the earlier decision
    k.rebind_by_user("ext/b/tab", &chord("C-t"), "C-c t")
        .expect("again");
    assert_eq!(run(&k, "C-c t"), Resolution::Command("ext/b/tab".into()));
    assert_eq!(run(&k, "C-y"), Resolution::Command("ext/c/other".into()));
    assert_eq!(k.overrides().len(), 1);
}

#[test]
fn rebinding_what_no_extension_asked_for_is_not_found() {
    let mut k = Keymap::new();
    let e = k
        .rebind_by_user("ext/a/none", &chord("C-y"), "C-c y")
        .expect_err("nothing asked");
    assert_eq!(e.kind(), villa::Kind::NotFound);
}

#[test]
fn a_decision_is_still_there_after_a_restart() {
    let sb = raun::Sandbox::new();
    let file = sb.home().join("config").join("keys.eld");
    {
        let mut k = Keymap::new();
        k.attach_user_file(&file).expect("no decisions yet");
        k.bind_by(&ext("a"), "C-y", "ext/a/yank", "").expect("A's");
        k.bind_by(&ext("b"), "C-y C-z", "ext/b/zap", "")
            .expect_err("clash");
        k.bind_by(&ext("c"), "C-t", "ext/c/tab", "language == rust")
            .expect("C's");
        k.rebind_by_user("ext/b/zap", &chord("C-y C-z"), "C-c z")
            .expect("rebound");
        k.unbind_by_user("ext/a/yank", &chord("C-y"))
            .expect("unbound");
        k.rebind_by_user("ext/c/tab", &chord("C-t"), "C-c \"")
            .expect("in its context");
    }
    // a full restart: a fresh keymap from the disk, before any extension has loaded
    let mut k = Keymap::new();
    k.attach_user_file(&file).expect("reads");
    assert_eq!(run(&k, "C-c z"), Resolution::Command("ext/b/zap".into()));
    assert_eq!(
        k.resolve(&chord("C-c \""), &rust()),
        Resolution::Command("ext/c/tab".into())
    );
    assert_eq!(
        run(&k, "C-c \""),
        Resolution::None,
        "in the context it was asked for"
    );
    assert_eq!(k.overrides().len(), 3);
    // the extensions load again: nothing is refused and none of their chords is in force
    k.bind_by(&ext("a"), "C-y", "ext/a/yank", "")
        .expect("unbound by the user, accepted");
    k.bind_by(&ext("b"), "C-y C-z", "ext/b/zap", "")
        .expect("rebound, accepted");
    k.bind_by(&ext("c"), "C-t", "ext/c/tab", "language == rust")
        .expect("rebound");
    assert_eq!(run(&k, "C-y"), Resolution::None);
    assert_eq!(run(&k, "C-y C-z"), Resolution::None);
    assert_eq!(k.resolve(&chord("C-t"), &rust()), Resolution::None);
    // a later decision is written too, over the same file
    k.unbind_by_user("ext/b/zap", &chord("C-y C-z"))
        .expect("changed");
    let mut again = Keymap::new();
    again.attach_user_file(&file).expect("reads");
    assert_eq!(
        run(&again, "C-c z"),
        Resolution::None,
        "the new decision replaced the old"
    );
}

#[test]
fn a_keys_file_that_cannot_be_read_is_refused_not_ignored() {
    let sb = raun::Sandbox::new();
    let file = sb.home().join("keys.eld");
    eitri::replace_file(
        &file,
        b"(drgnx-keys-user :version 1\n (ext/a/yank (\"C-y\" \"nonsense key\" \"\")))\n",
    )
    .expect("written");
    let e = Keymap::new()
        .attach_user_file(&file)
        .expect_err("a bad chord");
    assert_eq!(e.kind(), villa::Kind::Invalid);
    eitri::replace_file(&file, b"(not-keys)").expect("written");
    assert!(Keymap::new().attach_user_file(&file).is_err());
}

#[test]
fn a_chord_is_written_so_it_reads_back_the_same() {
    for c in [
        "C-x C-f", "M-x", "C-S-a", "s-k", "RET", "TAB", "SPC", "<f5>", "C-<up>", "M-pageup", "C--",
        "C-c \"",
    ] {
        let keys = chord(c);
        assert_eq!(chord(&lykill::format_chord(&keys)), keys, "{c}");
    }
}
