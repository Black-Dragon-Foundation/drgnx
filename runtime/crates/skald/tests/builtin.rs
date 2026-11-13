//! The built-in packs in `packs/` (language packs Task 2b): each passes the schema rules, names its own folder, and
//! together they claim no extension, grammar or mode twice. Their pins are the Emacs modes' (pin test: test/unit).

use std::collections::HashMap;
use std::path::PathBuf;

use skald::{Claims, Manifest, Source, check_dir};

fn packs_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../packs")
}

fn all() -> Vec<(String, Manifest)> {
    let mut out = Vec::new();
    for e in std::fs::read_dir(packs_dir()).expect("packs/ exists") {
        let e = e.unwrap();
        if !e.file_type().unwrap().is_dir() {
            continue;
        }
        let name = e.file_name().to_string_lossy().into_owned();
        let r = check_dir(&e.path(), Source::Builtin, &Claims::default());
        assert!(r.problems.is_empty(), "{name}: {:?}", r.problems);
        out.push((name, r.manifest.expect("reads")));
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

#[test]
fn every_builtin_pack_passes_and_is_named_for_its_folder() {
    let packs = all();
    assert!(packs.len() >= 19, "{} packs", packs.len());
    for (folder, m) in &packs {
        assert_eq!(&m.pack, folder);
    }
}

#[test]
fn the_languages_of_today_are_all_there() {
    let names: Vec<String> = all().into_iter().map(|p| p.0).collect();
    // the 17 grammar languages (bash is the shell pack's grammar), and the two format-only ones
    for want in [
        "python",
        "javascript",
        "typescript",
        "tsx",
        "go",
        "rust",
        "java",
        "c",
        "cpp",
        "shell",
        "ruby",
        "lua",
        "html",
        "css",
        "json",
        "yaml",
        "toml",
        "terraform",
        "dart",
    ] {
        assert!(names.iter().any(|n| n == want), "no {want} pack");
    }
}

#[test]
fn no_extension_grammar_or_mode_is_claimed_twice() {
    let (mut ext, mut gram, mut modes): (
        HashMap<String, String>,
        HashMap<String, String>,
        HashMap<String, String>,
    ) = Default::default();
    for (name, m) in all() {
        for e in &m.files.extensions {
            if let Some(o) = ext.insert(e.clone(), name.clone()) {
                panic!(".{e} is claimed by {o} and {name}");
            }
        }
        for g in m.grammars.iter().filter(|g| g.from_pack.is_none()) {
            if let Some(o) = gram.insert(g.name.clone(), name.clone()) {
                panic!("the {} grammar is pinned by {o} and {name}", g.name);
            }
        }
        for mode in m
            .mode
            .iter()
            .flat_map(|m| m.ts.iter().chain(m.classic.iter()))
        {
            if let Some(o) = modes.insert(mode.clone(), name.clone()) {
                panic!("{mode} is named by {o} and {name}");
            }
        }
    }
}

#[test]
fn the_languages_hrafn_stores_today_keep_their_names_and_files() {
    // hrafn::files::lang_of (Task 5 moves it onto these packs): extension -> stored language name
    let want = [
        ("rs", "rust"),
        ("c", "c"),
        ("h", "c"),
        ("sh", "shell"),
        ("bash", "shell"),
        ("zsh", "shell"),
        ("py", "python"),
        ("pyi", "python"),
        ("js", "javascript"),
        ("mjs", "javascript"),
        ("cjs", "javascript"),
        ("jsx", "javascript"),
        ("ts", "typescript"),
        ("mts", "typescript"),
        ("cts", "typescript"),
        ("tsx", "tsx"),
        ("go", "go"),
        ("java", "java"),
    ];
    let packs = all();
    for (ext, lang) in want {
        let owner = packs
            .iter()
            .find(|(_, m)| m.files.extensions.iter().any(|e| e == ext));
        let owner = owner.unwrap_or_else(|| panic!("no pack owns .{ext}"));
        assert_eq!(
            owner.1.hrafn.as_ref().map(|h| h.lang.as_str()),
            Some(lang),
            ".{ext}"
        );
    }
}

#[test]
fn only_go_rust_terraform_and_dart_format_every_project() {
    let standard: Vec<String> = all()
        .into_iter()
        .filter(|p| p.1.format.as_ref().is_some_and(|f| f.standard))
        .map(|p| p.0)
        .collect();
    assert_eq!(standard, ["dart", "go", "rust", "terraform"]);
}
