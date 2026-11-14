//! The pack format (Task 1): a valid manifest reads, each bad field is refused with its path, and the rules a fetched
//! pack must meet (command, claim, install digest, highlights subset) each refuse their case.

use skald::{Claims, ProblemKind, Source, check, check_dir, highlights, read};

const COMMIT: &str = "0123456789abcdef0123456789abcdef01234567";
const TREE: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn scala_with(extra: &str) -> String {
    format!(
        r#"(:pack "scala" :schema 1 :version "1.0.0" :name "Scala" :summary "Scala support"
 :files (:extensions ("kt" "kts") :shebangs ("^scala") :mode-regexp "\\.kts?\\'")
 :grammars ((:name scala :repo "https://github.com/example/tree-sitter-scala" :commit "{COMMIT}"
             :tree-sha256 "{TREE}" :src "src" :required t))
 :mode (:generic t :indent ((class_body . 4)))
 :servers ((:id "scala-language-server" :modes (drgnx-scala-ts-mode)
            :command ("scala-language-server") :find (:path "scala-language-server")
            :install (:into "scala-ls" :platforms ((:platform "linux-x64" :url "https://example.org/k.zip" :sha256 "{TREE}")))))
 :format (:formatter scalafmt :command ("scalafmt" "--scalalang-style" "-") :standard nil :config-files (".editorconfig"))
 :hrafn (:lang "scala" :tags "queries/tags.scm" :chunks "queries/chunks.scm"
         :docs (:line "//" :block "/**" :members (block)) :sigil "µ" :helpers ())
 :origin (:decls ("val {{t}} = $V"))
 :inline (:functions ("function_declaration") :loops ("for_statement") :names ("simple_identifier"))
 :license "MIT" :maintainers ("someone")
 {extra})"#
    )
}

fn scala() -> String {
    scala_with("")
}

fn problems(text: &str, source: Source) -> Vec<(ProblemKind, String, String)> {
    let m = read(text.as_bytes()).expect("reads");
    check(&m, source, &Claims::default())
        .into_iter()
        .map(|p| (p.kind, p.path, p.message))
        .collect()
}

fn has(ps: &[(ProblemKind, String, String)], kind: ProblemKind, path: &str) -> bool {
    ps.iter().any(|(k, p, _)| *k == kind && p == path)
}

#[test]
fn a_valid_pack_reads_and_checks_clean() {
    let m = read(scala().as_bytes()).expect("reads");
    assert_eq!(m.pack, "scala");
    assert_eq!(m.files.extensions, ["kt", "kts"]);
    assert_eq!(m.grammars[0].name, "scala");
    assert!(m.grammars[0].required);
    assert!(m.mode.as_ref().unwrap().generic);
    assert_eq!(m.mode.unwrap().indent, [("class_body".to_string(), 4)]);
    assert!(!m.format.as_ref().unwrap().standard);
    assert_eq!(m.hrafn.unwrap().docs.unwrap().members.len(), 1);
    assert_eq!(problems(&scala(), Source::Fetched), []);
}

#[test]
fn an_unknown_field_is_refused_with_its_path() {
    let text = scala().replace(":required t", ":required t :bogus 1");
    let e = read(text.as_bytes()).unwrap_err();
    assert!(
        e.path.as_deref().unwrap_or("").starts_with("grammars[0]"),
        "{e}"
    );
    assert!(e.message.contains("bogus"), "{e}");
    let top = scala_with(":nope 1");
    assert!(read(top.as_bytes()).unwrap_err().message.contains("nope"));
}

#[test]
fn a_wrong_schema_or_a_missing_field_is_refused() {
    let e = read(scala().replace(":schema 1", ":schema 2").as_bytes()).unwrap_err();
    assert_eq!(e.path.as_deref(), Some("schema"));
    let e = read(scala().replace(":version \"1.0.0\"", "").as_bytes()).unwrap_err();
    assert!(e.message.contains("version"), "{e}");
    assert!(read(b"(:pack \"a\") (:pack \"b\")").is_err(), "two forms");
    assert!(read(b"`(:pack ,x)").is_err(), "a reader macro");
}

#[test]
fn a_bad_pin_is_refused_with_its_path() {
    let short = scala().replace(COMMIT, "abc123");
    let ps = problems(&short, Source::Fetched);
    assert!(
        has(&ps, ProblemKind::Schema, "grammars[0].commit"),
        "{ps:?}"
    );
    let ps = problems(&scala().replace(TREE, "zz"), Source::Fetched);
    assert!(
        has(&ps, ProblemKind::Schema, "grammars[0].tree-sha256"),
        "{ps:?}"
    );
    let ps = problems(
        &scala().replace(":src \"src\"", ":src \"../x\""),
        Source::Fetched,
    );
    assert!(has(&ps, ProblemKind::Schema, "grammars[0].src"), "{ps:?}");
}

#[test]
fn grammar_units_are_owned_or_referenced_never_both() {
    let both = scala().replace(":required t", ":required t :from-pack \"javascript\"");
    assert!(has(
        &problems(&both, Source::Fetched),
        ProblemKind::Schema,
        "grammars[0]"
    ));
    let bare = scala().replace(
        &format!(":repo \"https://github.com/example/tree-sitter-scala\" :commit \"{COMMIT}\"\n             :tree-sha256 \"{TREE}\" :src \"src\""),
        "",
    );
    assert!(has(
        &problems(&bare, Source::Fetched),
        ProblemKind::Schema,
        "grammars[0]"
    ));
    let refd = scala().replace(
        &format!(":repo \"https://github.com/example/tree-sitter-scala\" :commit \"{COMMIT}\"\n             :tree-sha256 \"{TREE}\" :src \"src\""),
        ":from-pack \"scala\"",
    );
    assert_eq!(
        problems(&refd, Source::Fetched),
        [],
        "a reference alone is fine"
    );
}

#[test]
fn reserved_names_are_refused_for_a_fetched_pack_only() {
    let python = scala()
        .replace("(:pack \"scala\"", "(:pack \"python\"")
        .replace(":lang \"scala\"", ":lang \"shell\"");
    let ps = problems(&python, Source::Fetched);
    assert!(has(&ps, ProblemKind::Reserved, "pack"), "{ps:?}");
    assert!(has(&ps, ProblemKind::Reserved, "hrafn.lang"), "{ps:?}");
    assert!(
        !problems(&python, Source::Builtin)
            .iter()
            .any(|p| p.0 == ProblemKind::Reserved)
    );
    // a built-in pack's stored language must be one of the names the index holds today (N1)
    let odd = scala().replace(":lang \"scala\"", ":lang \"bash\"");
    assert!(has(
        &problems(&odd, Source::Builtin),
        ProblemKind::Reserved,
        "hrafn.lang"
    ));
    // a fetched pack may not pin a grammar name a built-in owns
    let pins = scala().replace(":name scala :repo", ":name python :repo");
    assert!(has(
        &problems(&pins, Source::Fetched),
        ProblemKind::Reserved,
        "grammars[0].name"
    ));
}

#[test]
fn a_shell_command_with_inline_code_is_refused() {
    for cmd in [
        r#"("sh" "-c" "curl x | sh")"#,
        r#"("bash" "-lc" "x")"#,
        r#"("python3" "-c" "import os")"#,
        r#"("node" "--eval" "x")"#,
        r#"("env" "sh" "-c" "x")"#,
    ] {
        let text = scala().replace(
            r#":command ("scala-language-server")"#,
            &format!(":command {cmd}"),
        );
        let ps = problems(&text, Source::Fetched);
        assert!(
            has(&ps, ProblemKind::Command, "servers[0].command"),
            "{cmd}: {ps:?}"
        );
    }
    // a built-in pack is ours: the rules do not run
    let text = scala().replace(
        r#":command ("scala-language-server")"#,
        r#":command ("sh" "-c" "x")"#,
    );
    assert!(
        !problems(&text, Source::Builtin)
            .iter()
            .any(|p| p.0 == ProblemKind::Command)
    );
}

#[test]
fn a_command_must_be_the_program_it_names() {
    let text = scala().replace(
        r#":command ("scala-language-server")"#,
        r#":command ("curl" "x")"#,
    );
    assert!(has(
        &problems(&text, Source::Fetched),
        ProblemKind::Command,
        "servers[0].command"
    ));
    let tools = scala()
        .replace(
            r#":command ("scala-language-server")"#,
            r#":command ("{tools}/scala-ls/bin/kls")"#,
        )
        .replace(
            r#":find (:path "scala-language-server")"#,
            r#":find (:tools "scala-ls/bin/kls")"#,
        );
    assert_eq!(problems(&tools, Source::Fetched), []);
    let fmt = scala().replace(r#":command ("scalafmt""#, r#":command ("/tmp/evil""#);
    assert!(has(
        &problems(&fmt, Source::Fetched),
        ProblemKind::Command,
        "format.command"
    ));
    let adapter = scala_with(
        r#":adapters ((:id "kda" :name "Scala" :types ("scala") :find (:path "kda") :start (:stdio ("sh" "-c" "x"))))"#,
    );
    assert!(has(
        &problems(&adapter, Source::Fetched),
        ProblemKind::Command,
        "adapters[0].start.stdio"
    ));
}

#[test]
fn an_install_without_a_digest_is_refused_and_system_is_shown_only() {
    let no_digest = scala().replace(&format!(":sha256 \"{TREE}\"))))"), ":sha256 nil))))");
    assert!(has(
        &problems(&no_digest, Source::Fetched),
        ProblemKind::Install,
        "servers[0].install.platforms[0]"
    ));
    let url = scala().replace(
        r#":install (:into"#,
        r#":install (:url "https://example.org/x.zip" :into "x") :unused (:into"#,
    );
    // `:unused` is no field: refused before any rule runs
    assert!(read(url.as_bytes()).is_err());
    let plain_url = scala_with(
        r#":adapters ((:id "kda" :name "K" :types ("scala") :install (:url "https://example.org/x.zip" :into "x")))"#,
    );
    assert!(has(
        &problems(&plain_url, Source::Fetched),
        ProblemKind::Install,
        "adapters[0].install"
    ));
    let pip = scala_with(
        r#":adapters ((:id "kda" :name "K" :types ("scala") :install (:pip "kda==1.0")))"#,
    );
    assert!(has(
        &problems(&pip, Source::Fetched),
        ProblemKind::Install,
        "adapters[0].install"
    ));
    let sys = scala_with(
        r#":adapters ((:id "kda" :name "K" :types ("scala") :install (:system "dnf install kda")))"#,
    );
    assert_eq!(problems(&sys, Source::Fetched), []);
}

#[test]
fn a_claim_over_another_packs_files_is_refused() {
    let python_pack = scala()
        .replace("(:pack \"scala\"", "(:pack \"python\"")
        .replace(r#":extensions ("kt" "kts")"#, r#":extensions ("py")"#)
        .replace(
            r#":mode (:generic t :indent ((class_body . 4)))"#,
            r#":mode (:ts python-ts-mode :builtin t :classic python-mode)"#,
        )
        .replace(r#":shebangs ("^scala")"#, r#":shebangs ("^python")"#)
        .replace(r#":shebangs ("^scala")"#, r#":shebangs ("^python")"#)
        .replace(":lang \"scala\"", ":lang \"python\"");
    let owner = read(python_pack.as_bytes()).unwrap();
    let mut claims = Claims::default();
    claims.add_pack(&owner);
    claims.add_adapter_types("debugpy", &["debugpy".to_string(), "python".to_string()]);

    let clash = scala()
        .replace(r#":extensions ("kt" "kts")"#, r#":extensions ("kt" "py")"#)
        .replace(
            r#":mode (:generic t :indent ((class_body . 4)))"#,
            r#":mode (:ts scala-ts-mode :builtin t :classic python-mode)"#,
        )
        .replace(r#":shebangs ("^scala")"#, r#":shebangs ("^python")"#);
    let m = read(clash.as_bytes()).unwrap();
    let ps = check(&m, Source::Fetched, &claims);
    let at = |path: &str| {
        ps.iter()
            .any(|p| p.kind == ProblemKind::Claim && p.path == path)
    };
    assert!(at("files.extensions[1]"), "{ps:?}");
    assert!(at("mode.classic"), "{ps:?}");
    assert!(at("files.shebangs[0]"), "{ps:?}");

    let launch = scala_with(
        r#":adapters ((:id "kda" :name "K" :types ("python") :find (:path "kda") :start (:stdio ("kda"))))"#,
    );
    let ps = check(&read(launch.as_bytes()).unwrap(), Source::Fetched, &claims);
    assert!(
        ps.iter()
            .any(|p| p.kind == ProblemKind::Claim && p.path == "adapters[0].types[0]"),
        "{ps:?}"
    );

    // two packs pinning one grammar name: one owner (Q10)
    let mut claims = Claims::default();
    claims.add_pack(&read(scala().as_bytes()).unwrap());
    let twin = scala()
        .replace("(:pack \"scala\"", "(:pack \"scala2\"")
        .replace(":lang \"scala\"", ":lang \"scala2\"");
    let ps = check(&read(twin.as_bytes()).unwrap(), Source::Fetched, &claims);
    assert!(
        ps.iter()
            .any(|p| p.kind == ProblemKind::Claim && p.path == "grammars[0].name"),
        "{ps:?}"
    );
    // a pack never conflicts with itself
    let ps = check(&read(scala().as_bytes()).unwrap(), Source::Fetched, &claims);
    assert_eq!(ps, []);
}

#[test]
fn highlights_use_only_the_portable_subset() {
    let ok = r#"
; a comment with #lua-match? inside is not a predicate
((identifier) @variable (#eq? @variable "self"))
((identifier) @constant (#match? @constant "^[A-Z_][A-Z0-9_]*$"))
((identifier) @keyword (#any-of? @keyword "if" "else"))
((identifier) @x (#not-eq? @x "a") (#not-match? @x "^(a|b)+$"))
"#;
    assert!(highlights::check(ok).is_empty());
    for (src, word) in [
        (r#"((a) @b (#lua-match? @b "x"))"#, "#lua-match?"),
        (r#"((a) @b (#set! priority 105))"#, "#set!"),
        (r#"((a) @b (#vim-match? @b "x"))"#, "#vim-match?"),
        (r#"((a) @b (#match? @b "\\d+"))"#, "\\d"),
        (r#"((a) @b (#match? @b "(?=x)"))"#, "(?"),
        (r#"((a) @b (#not-match? @b "x{2}"))"#, "{"),
    ] {
        let ps = highlights::check(src);
        assert!(ps.iter().any(|p| p.contains(word)), "{src}: {ps:?}");
    }
    assert!(
        highlights::check("((a) @b (#set! priority 1))\n")
            .iter()
            .any(|p| p.starts_with("line 1"))
    );
}

fn write(dir: &std::path::Path, rel: &str, text: &str) {
    let p = dir.join(rel);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, text).unwrap();
}

#[test]
fn a_pack_folder_is_checked_whole() {
    let d = tempfile::tempdir().unwrap();
    write(d.path(), "pack.eld", &scala());
    write(
        d.path(),
        "queries/tags.scm",
        "(function_declaration) @definition.function",
    );
    write(d.path(), "queries/chunks.scm", "");
    write(
        d.path(),
        "queries/highlights.scm",
        r#"((a) @b (#eq? @b "x"))"#,
    );
    let r = check_dir(d.path(), Source::Fetched, &Claims::default());
    assert!(r.problems.is_empty(), "{:?}", r.problems);
    assert_eq!(r.manifest.unwrap().pack, "scala");

    // a named query that is missing
    std::fs::remove_file(d.path().join("queries/chunks.scm")).unwrap();
    let r = check_dir(d.path(), Source::Fetched, &Claims::default());
    assert!(
        r.problems.iter().any(|p| p.path == "hrafn.chunks"),
        "{:?}",
        r.problems
    );

    // a generic mode needs highlights.scm; a bad predicate in it is refused with its file
    write(d.path(), "queries/chunks.scm", "");
    write(
        d.path(),
        "queries/highlights.scm",
        r#"((a) @b (#lua-match? @b "x"))"#,
    );
    let r = check_dir(d.path(), Source::Fetched, &Claims::default());
    assert!(
        r.problems
            .iter()
            .any(|p| p.kind == ProblemKind::Highlights && p.path == "queries/highlights.scm")
    );
    std::fs::remove_file(d.path().join("queries/highlights.scm")).unwrap();
    let r = check_dir(d.path(), Source::Fetched, &Claims::default());
    assert!(
        r.problems
            .iter()
            .any(|p| p.path == "queries/highlights.scm")
    );
}

#[test]
fn a_symlink_leaving_the_pack_is_refused() {
    let d = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    write(outside.path(), "secret.scm", "");
    write(d.path(), "pack.eld", &scala());
    write(d.path(), "queries/chunks.scm", "");
    write(d.path(), "queries/highlights.scm", "");
    std::fs::create_dir_all(d.path().join("queries")).unwrap();
    std::os::unix::fs::symlink(
        outside.path().join("secret.scm"),
        d.path().join("queries/tags.scm"),
    )
    .unwrap();
    let r = check_dir(d.path(), Source::Fetched, &Claims::default());
    assert!(
        r.problems
            .iter()
            .any(|p| p.path == "hrafn.tags" && p.message.contains("symlink")),
        "{:?}",
        r.problems
    );
}

#[test]
fn a_missing_manifest_is_one_problem() {
    let d = tempfile::tempdir().unwrap();
    let r = check_dir(d.path(), Source::Fetched, &Claims::default());
    assert!(r.manifest.is_none());
    assert_eq!(r.problems.len(), 1);
    assert_eq!(r.problems[0].path, "pack.eld");
}

const LSP_ADAPTER: &str = r#":adapters ((:id "jv" :name "Java" :types ("java") :find (:tools "jv/x.jar")
 :start (:lsp-command (:server ("{tools}/jdk/bin/java" "-jar" "{tools}/jdtls/launcher.jar") :root "{root}"
                       :init-options (:bundles ("{tools}/jv/x.jar")) :debug-command "vscode.java.startDebugSession"
                       :fill ((:command "vscode.java.resolveMainClass" :args ("{root-uri}")
                               :select (:field "filePath" :equals "${file}") :when-missing "mainClass"
                               :into ((:key "mainClass" :field "mainClass") (:key "projectName" :field "projectName")))
                              (:command "vscode.java.resolveClasspath" :args ("${config:mainClass}" "${config:projectName}")
                               :into ((:key "modulePaths" :index 0) (:key "classPaths" :index 1)))
                              (:command "vscode.java.resolveJavaExecutable" :args ("${config:mainClass}")
                               :into ((:key "javaExec"))))))
 :install (:parts ((:into "jdk" :root "jdk-21" :platforms ((:platform "linux-x64" :url "https://example.org/jdk.tar.gz" :sha256 "SHA")))
                   (:into "jv" :file "x.jar" :url "https://example.org/x.jar" :sha256 "SHA")))))"#;

fn lsp() -> String {
    scala_with(&LSP_ADAPTER.replace("SHA", &"a".repeat(64)))
}

#[test]
fn an_lsp_command_adapter_and_its_install_parts_read_and_a_built_in_pack_may_have_them() {
    let m = read(lsp().as_bytes()).unwrap();
    let a = &m.adapters[0];
    let l = a.start.as_ref().unwrap().lsp_command.as_ref().unwrap();
    assert_eq!(l.debug_command, "vscode.java.startDebugSession");
    assert_eq!(l.fill.len(), 3);
    assert_eq!(l.fill[0].when_missing.as_deref(), Some("mainClass"));
    assert_eq!(l.fill[1].into[1].index, Some(1));
    assert_eq!(l.fill[2].into[0].field, None);
    let parts = &a.install.as_ref().unwrap().parts;
    assert_eq!(parts.len(), 2);
    assert_eq!(parts[1].file.as_deref(), Some("x.jar"));
    // the hub reads the recipe as JSON, parts included
    let json = a.install.as_ref().unwrap().to_json();
    assert_eq!(json["parts"][1]["file"], "x.jar");
    assert_eq!(json["parts"][0]["platforms"][0]["platform"], "linux-x64");
    // a built-in pack may start a language server: no command or install problem (the fixture's `scala` is no stored language)
    assert!(
        problems(&lsp(), Source::Builtin)
            .iter()
            .all(|(k, _, _)| !matches!(k, ProblemKind::Command | ProblemKind::Install)),
    );
}

#[test]
fn a_fetched_pack_may_not_start_a_language_server_and_a_part_needs_its_digest() {
    assert!(has(
        &problems(&lsp(), Source::Fetched),
        ProblemKind::Command,
        "adapters[0].start.lsp-command"
    ));
    let no_digest = scala_with(
        &LSP_ADAPTER
            .replace("SHA", "nil")
            .replace(":sha256 \"nil\"", ":sha256 nil"),
    );
    assert!(has(
        &problems(&no_digest, Source::Fetched),
        ProblemKind::Install,
        "adapters[0].install.parts[1]"
    ));
    let escape = scala_with(
        &LSP_ADAPTER
            .replace("SHA", &"a".repeat(64))
            .replace(":file \"x.jar\"", ":file \"../x.jar\""),
    );
    assert!(has(
        &problems(&escape, Source::Fetched),
        ProblemKind::Install,
        "adapters[0].install.parts[1]"
    ));
}
