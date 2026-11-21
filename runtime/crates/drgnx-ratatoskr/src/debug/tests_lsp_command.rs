//! The data side of the `lsp-command` start kind: the brace words of a server's command line, `{glob:…}`, file URIs and the
//! values a server's answer may put into the launch arguments.
use super::lsp_command::{Vars, expand, file_uri, plain};
use serde_json::json;
use std::path::{Path, PathBuf};

fn vars(tools: &Path) -> Vars {
    Vars {
        tools: tools.to_path_buf(),
        root: PathBuf::from("/work/my project"),
        session: PathBuf::from("/tmp/s1"),
        file: Some(PathBuf::from("/work/my project/A.java")),
    }
}

#[test]
fn brace_words_are_filled_in_and_another_word_is_an_error_naming_it() {
    let v = vars(Path::new("/opt/tools"));
    assert_eq!(
        expand("{tools}/jdk/bin/java", &v).unwrap(),
        "/opt/tools/jdk/bin/java"
    );
    assert_eq!(
        expand("-data={session}/ws", &v).unwrap(),
        "-data=/tmp/s1/ws"
    );
    assert_eq!(
        expand("{root-uri}", &v).unwrap(),
        "file:///work/my%20project"
    );
    assert!(
        expand("config_{os}{arch-suffix}", &v)
            .unwrap()
            .starts_with("config_")
    );
    assert_eq!(expand("no braces", &v).unwrap(), "no braces");
    let e = expand("{nope}", &v).unwrap_err();
    assert!(e.contains("unknown {nope}"), "{e}");
    assert!(expand("a { b", &v).is_err());
    assert_eq!(file_uri(Path::new("/a/ü b")), "file:///a/%C3%BC%20b");
}

#[test]
fn a_glob_names_exactly_one_file_under_the_tools_folder() {
    let dir = tempfile::tempdir().unwrap();
    let plugins = dir.path().join("jdtls/plugins");
    std::fs::create_dir_all(&plugins).unwrap();
    std::fs::write(
        plugins.join("org.eclipse.equinox.launcher_1.6.900.v2024.jar"),
        "",
    )
    .unwrap();
    std::fs::write(plugins.join("other.jar"), "").unwrap();
    let v = vars(dir.path());
    let got = expand(
        "{glob:jdtls/plugins/org.eclipse.equinox.launcher_*.jar}",
        &v,
    )
    .unwrap();
    assert!(
        got.ends_with("org.eclipse.equinox.launcher_1.6.900.v2024.jar"),
        "{got}"
    );
    // none, two, no star, a path that leaves the folder
    assert!(
        expand("{glob:jdtls/plugins/nothing_*.jar}", &v)
            .unwrap_err()
            .contains("matches nothing")
    );
    std::fs::write(plugins.join("org.eclipse.equinox.launcher_2.jar"), "").unwrap();
    assert!(
        expand(
            "{glob:jdtls/plugins/org.eclipse.equinox.launcher_*.jar}",
            &v
        )
        .unwrap_err()
        .contains("matches 2 files")
    );
    assert!(expand("{glob:jdtls/plugins/other.jar}", &v).is_err());
    assert!(expand("{glob:../x_*}", &v).is_err());
    assert!(expand("{glob:/etc/p*}", &v).is_err());
}

#[test]
fn an_answer_is_a_plain_string_or_a_list_of_plain_strings_and_nothing_else() {
    assert_eq!(plain("k", &json!("a/b")).unwrap(), json!("a/b"));
    assert_eq!(plain("k", &json!(["a", "b"])).unwrap(), json!(["a", "b"]));
    assert_eq!(plain("k", &json!([])).unwrap(), json!([]));
    for hostile in [
        json!({"a": "b"}),
        json!([{"a": "b"}]),
        json!([["x"]]),
        json!(5),
        json!(true),
        json!(null),
        json!("${env:HOME}/x"),
        json!(["fine", "bad ${config:mainClass}"]),
        json!("a".repeat(5000)),
    ] {
        assert!(plain("k", &hostile).is_err(), "{hostile}");
    }
    let many: Vec<String> = (0..9000).map(|i| i.to_string()).collect();
    assert!(plain("k", &json!(many)).is_err());
}
