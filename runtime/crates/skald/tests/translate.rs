//! The generic mode's query translation (Task 3g): captures become faces, the portable predicates become Emacs's, the
//! rest is refused by name, and patterns are grouped by feature.

use skald::translate::{PredKind, definition_kinds, emacs_regexp, translate};

fn one(scm: &str) -> String {
    let t = translate("p", scm).expect("translates");
    assert_eq!(t.rules.len(), 1, "{:?}", t.rules);
    t.rules[0].query.clone()
}

#[test]
fn a_capture_becomes_the_face_it_names() {
    assert_eq!(
        one("(identifier) @function"),
        "(identifier) @font-lock-function-name-face"
    );
    assert_eq!(
        one("(call function: (identifier) @function.call)"),
        "(call function: (identifier) @font-lock-function-name-face)"
    );
    assert_eq!(
        one("[\"if\" \"else\"] @keyword.conditional"),
        "[\"if\" \"else\"] @font-lock-keyword-face"
    );
    assert_eq!(one("(a) @string.escape"), "(a) @font-lock-escape-face");
    // a name the table lacks falls back to its part before the dot
    assert_eq!(one("(a) @keyword.coroutine"), "(a) @font-lock-keyword-face");
}

#[test]
fn rules_keep_the_files_order_so_a_later_pattern_can_override_an_earlier_one() {
    let t = translate("p", "(identifier) @variable\n(function_declaration name: (identifier) @function)\n(identifier) @variable\n").unwrap();
    let f: Vec<&str> = t.rules.iter().map(|r| r.feature.as_str()).collect();
    assert_eq!(f, ["variable", "function", "variable"]);
}

#[test]
fn the_feature_is_the_first_known_capture_and_consecutive_patterns_share_a_rule() {
    let t = translate(
        "p",
        "(comment) @comment\n\"fn\" @keyword\n\"let\" @keyword\n(number) @number\n",
    )
    .unwrap();
    let f: Vec<&str> = t.rules.iter().map(|r| r.feature.as_str()).collect();
    assert_eq!(f, ["comment", "keyword", "number"]);
    assert_eq!(
        t.rules[1].query,
        "\"fn\" @font-lock-keyword-face\n\"let\" @font-lock-keyword-face"
    );
}

#[test]
fn an_unknown_capture_is_ignored_by_emacs_and_a_pattern_of_only_those_is_dropped() {
    let t = translate("p", "(a) @spell\n((b) @keyword (c) @conceal)\n").unwrap();
    assert_eq!(t.unmapped, ["spell", "conceal"]);
    assert_eq!(t.rules.len(), 1);
    assert_eq!(
        t.rules[0].query,
        "((b) @font-lock-keyword-face (c) @_conceal)"
    );
}

#[test]
fn eq_and_match_keep_their_shape_and_the_regexp_is_emacs_syntax() {
    assert_eq!(
        one("((identifier) @variable.builtin (#eq? @variable.builtin \"self\"))"),
        "((identifier) @font-lock-builtin-face (#eq? @font-lock-builtin-face \"self\"))"
    );
    assert_eq!(
        one("((identifier) @constant (#match? @constant \"^[A-Z_][A-Z0-9_]*$\"))"),
        "((identifier) @font-lock-constant-face (#match? @font-lock-constant-face \"^[A-Z_][A-Z0-9_]*$\"))"
    );
    assert_eq!(emacs_regexp("^(a|b)+\\.c$"), "^\\(a\\|b\\)+\\.c$");
    assert_eq!(emacs_regexp("a\\(b"), "a(b");
    assert_eq!(emacs_regexp("[(|)]x"), "[(|)]x");
}

#[test]
fn any_of_is_a_match_on_an_anchored_alternation() {
    assert_eq!(
        one("((identifier) @keyword (#any-of? @keyword \"if\" \"a.b\"))"),
        "((identifier) @font-lock-keyword-face (#match? @font-lock-keyword-face \"\\\\`\\\\(?:if\\\\|a\\\\.b\\\\)\\\\'\"))"
    );
}

#[test]
fn not_eq_and_not_match_become_predicates_the_editor_defines() {
    let t = translate(
        "kotlin",
        "((identifier) @function (#not-eq? @function \"main\") (#not-match? @function \"^_\"))\n((a) @type (b) @_x (#not-eq? @type @_x))\n",
    )
    .unwrap();
    assert_eq!(
        t.rules[0].query,
        "((identifier) @font-lock-function-name-face (#pred? drgnx-pack-pred--kotlin-1 @font-lock-function-name-face) (#pred? drgnx-pack-pred--kotlin-2 @font-lock-function-name-face))"
    );
    assert_eq!(
        t.rules[1].query,
        "((a) @font-lock-type-face (b) @_x (#pred? drgnx-pack-pred--kotlin-3 @font-lock-type-face @_x))"
    );
    let kinds: Vec<(&str, &PredKind, &str)> = t
        .preds
        .iter()
        .map(|p| (p.name.as_str(), &p.kind, p.arg.as_str()))
        .collect();
    assert_eq!(
        kinds,
        [
            ("drgnx-pack-pred--kotlin-1", &PredKind::NotEq, "main"),
            ("drgnx-pack-pred--kotlin-2", &PredKind::NotMatch, "^_"),
            ("drgnx-pack-pred--kotlin-3", &PredKind::NotEqNodes, ""),
        ]
    );
}

#[test]
fn what_is_outside_the_subset_is_refused_by_name() {
    let e = translate(
        "p",
        "((a) @keyword (#lua-match? @keyword \"x\"))\n((b) @keyword (#set! priority 105))",
    )
    .unwrap_err();
    assert!(e.iter().any(|m| m.contains("#lua-match?")), "{e:?}");
    assert!(e.iter().any(|m| m.contains("#set!")), "{e:?}");
}

#[test]
fn comments_are_skipped_and_strings_keep_their_escapes() {
    assert_eq!(
        one("; a comment (with parens\n(string) @string ; trailing\n"),
        "(string) @font-lock-string-face"
    );
    assert_eq!(
        one("\"a\\\"b\" @string"),
        "\"a\\\"b\" @font-lock-string-face"
    );
}

#[test]
fn definitions_name_the_kinds_to_navigate_to() {
    let tags = "(function_declaration name: (simple_identifier) @name) @definition.function\n\
                (class_declaration name: (type_identifier) @name) @definition.class\n\
                (call_expression function: (identifier) @name) @reference.call\n\
                (function_declaration) @definition.method\n";
    assert_eq!(
        definition_kinds(tags),
        ["function_declaration", "class_declaration"]
    );
}
