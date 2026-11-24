//! `Env`: an environment as a value, read by name, never from this process unless asked.

use stig::{Env, Xdg};

#[test]
fn a_variable_is_read_by_name_and_an_unset_one_is_nothing() {
    let env = Env::new(&[("A", "x"), ("EMPTY", "")], 7);
    assert_eq!(env.get("A"), Some("x"));
    assert_eq!(env.get("EMPTY"), Some(""));
    assert_eq!(env.get("B"), None);
    assert_eq!(env.uid, 7);
}

#[test]
fn only_an_absolute_value_counts() {
    let env = Env::new(
        &[
            ("ABS", "/a/b"),
            ("REL", "a/b"),
            ("TILDE", "~/x"),
            ("EMPTY", ""),
        ],
        0,
    );
    assert_eq!(env.absolute("ABS"), Some("/a/b"));
    assert_eq!(env.absolute("REL"), None);
    assert_eq!(env.absolute("TILDE"), None);
    assert_eq!(env.absolute("EMPTY"), None);
    assert_eq!(env.absolute("NONE"), None);
}

#[test]
fn home_is_read_as_set_and_xdg_only_when_absolute() {
    let env = Env::new(
        &[
            ("HOME", "/h"),
            ("XDG_DATA_HOME", "/xd"),
            ("XDG_CONFIG_HOME", "rel"),
            ("XDG_RUNTIME_DIR", "/run/user/1"),
        ],
        0,
    );
    assert_eq!(env.home(), Some("/h"));
    assert_eq!(env.xdg(Xdg::Data), Some("/xd"));
    assert_eq!(env.xdg(Xdg::Config), None);
    assert_eq!(env.xdg(Xdg::State), None);
    assert_eq!(env.xdg(Xdg::Runtime), Some("/run/user/1"));
    assert_eq!(Env::default().home(), None);
}

#[test]
fn each_xdg_directory_names_its_own_variable() {
    assert_eq!(Xdg::Data.var(), "XDG_DATA_HOME");
    assert_eq!(Xdg::Config.var(), "XDG_CONFIG_HOME");
    assert_eq!(Xdg::State.var(), "XDG_STATE_HOME");
    assert_eq!(Xdg::Cache.var(), "XDG_CACHE_HOME");
    assert_eq!(Xdg::Runtime.var(), "XDG_RUNTIME_DIR");
}

#[test]
fn the_process_environment_carries_this_process_uid() {
    let env = Env::process();
    assert_eq!(env.uid, rustix::process::geteuid().as_raw());
    assert!(!env.vars.is_empty());
}
