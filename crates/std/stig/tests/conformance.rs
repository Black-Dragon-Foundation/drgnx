//! The paths standard (docs/develop/standards/paths.md). The resolver reads a given environment, never this
//! process's, so no test depends on (or reaches) the real home.

use std::ffi::OsString;
use std::path::Path;

use stig::{Dirs, Profile};

fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<OsString> {
    move |k| {
        pairs
            .iter()
            .find(|(n, _)| *n == k)
            .map(|(_, v)| OsString::from(v))
    }
}

#[test]
fn dev_profile_never_resolves_to_default() {
    let d = Dirs::from_lookup(env(&[("DRGNX_PROFILE", "dev"), ("HOME", "/h")])).unwrap();
    assert_eq!(d.profile, Profile::Dev);
    assert_eq!(d.config, Path::new("/h/.config/drgnx/dev"));
    assert_eq!(d.state, Path::new("/h/.local/state/drgnx/dev"));
    assert_eq!(d.cache, Path::new("/h/.cache/drgnx/dev"));
    assert_eq!(d.data, Path::new("/h/.local/share/drgnx/dev"));
    assert!(d.runtime.ends_with("drgnx/dev"), "{:?}", d.runtime);
}

#[test]
fn default_profile_has_no_subfolder_and_xdg_wins() {
    let d = Dirs::from_lookup(env(&[
        ("HOME", "/h"),
        ("XDG_CONFIG_HOME", "/xc"),
        ("XDG_RUNTIME_DIR", "/run/user/1"),
        // a relative XDG value is ignored (the XDG spec)
        ("XDG_DATA_HOME", "rel/data"),
    ]))
    .unwrap();
    assert_eq!(d.profile, Profile::Default);
    assert_eq!(d.config, Path::new("/xc/drgnx"));
    assert_eq!(d.runtime, Path::new("/run/user/1/drgnx"));
    assert_eq!(d.data, Path::new("/h/.local/share/drgnx"));
}

#[test]
fn unknown_profile_is_refused() {
    let e = Dirs::from_lookup(env(&[("DRGNX_PROFILE", "devv"), ("HOME", "/h")])).unwrap_err();
    assert_eq!(e.kind(), villa::Kind::Invalid);
}

#[test]
fn no_home_is_unavailable() {
    let e = Dirs::from_lookup(env(&[])).unwrap_err();
    assert_eq!(e.kind(), villa::Kind::Unavailable);
}

#[test]
fn init_for_test_roots_every_dir() {
    let root = tempfile::tempdir().unwrap();
    stig::init_for_test(root.path());
    assert_eq!(stig::profile(), Profile::Test);
    for d in [
        stig::config(),
        stig::state(),
        stig::cache(),
        stig::data(),
        stig::runtime(),
    ] {
        assert!(d.starts_with(root.path()), "{d:?}");
        assert!(d.ends_with("drgnx/test"), "{d:?}");
    }
    stig::reset_for_test();
}

#[test]
fn the_system_runtime_dir_is_the_xdg_one_and_absolute() {
    assert_eq!(stig::SYSTEM_RUNTIME_VAR, "XDG_RUNTIME_DIR");
    assert!(stig::system_runtime_dir().is_none_or(|p| p.is_absolute()));
    // not drgnx's own folder
    assert_ne!(stig::system_runtime_dir().as_deref(), Some(stig::runtime()));
}

#[test]
fn a_relative_system_runtime_dir_is_ignored() {
    let at = |v: &str| {
        stig::system_runtime_dir_from(|k| (k == "XDG_RUNTIME_DIR").then(|| OsString::from(v)))
    };
    assert_eq!(
        at("/run/user/1000"),
        Some(std::path::PathBuf::from("/run/user/1000"))
    );
    assert_eq!(at("run/user"), None);
    assert_eq!(stig::system_runtime_dir_from(|_| None), None);
}
