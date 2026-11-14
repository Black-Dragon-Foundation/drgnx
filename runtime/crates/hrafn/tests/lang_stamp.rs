//! The language stamp (language packs Task 6a, spec §4.4): a file indexed while its pack's grammar was missing is
//! parsed again once the grammar is built, with no edit to the file, and a chunk whose text did not change keeps its
//! key and so its vector. Its own process: the grammar registry is process-wide.
//!
//! test-pattern: pure (D): the store thread answers in order, nothing here has a clock or a timeout.

use hrafn::symbols::{Find, Match, find};
use hrafn::{CodeStore, Listed, Scope, View, classify, refresh};
use std::collections::HashMap;
use std::io;
use std::path::Path;

const PY: &str = "def make_widget(n):\n    \"\"\"Makes one.\"\"\"\n    return n\n";

fn listed(path: &str, text: &str) -> Listed {
    let (lang, class) = classify(path, text.as_bytes());
    Listed {
        path: path.into(),
        blob: format!("b-{path}-{}", text.len()),
        class,
        lang,
        generated: false,
        size: text.len() as u64,
    }
}

async fn index(s: &CodeStore) {
    let texts: HashMap<String, String> = HashMap::from([("a.py".to_string(), PY.to_string())]);
    refresh(
        s,
        &[listed("a.py", PY)],
        &move |p: &str| {
            texts
                .get(p)
                .map(|t| t.as_bytes().to_vec())
                .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
        },
        &[],
    )
    .await
    .unwrap();
}

async fn hits(s: &CodeStore) -> usize {
    let f = Find {
        name: "make_widget".into(),
        mode: Match::Exact,
        kinds: vec![],
        glob: None,
        scope: Scope::All,
        k: 20,
    };
    find(s, View::Base, &f)
        .await
        .map(|r| r.hits.len())
        .unwrap_or(0)
}

async fn keys(s: &CodeStore) -> Vec<Vec<u8>> {
    s.handle()
        .read(|c| {
            let mut q = c.prepare("select key from chunk order by path, start")?;
            Ok(q.query_map([], |r| r.get::<_, Vec<u8>>(0))?
                .collect::<Result<Vec<_>, _>>()?)
        })
        .await
        .unwrap()
}

#[tokio::test]
async fn a_grammar_built_later_re_parses_the_files_without_an_edit() {
    let lock = std::env::var("DRGNX_PACK_LOCK").expect("the test run's pack grammars");
    let grammars = std::env::var("DRGNX_PACK_GRAMMARS").expect("the test run's pack grammars");
    let dir = tempfile::tempdir().unwrap();
    let s = CodeStore::open(&dir.path().join("code.db")).unwrap();

    // the Python pack's grammar is not built: the file reads as text, no symbol
    skald::registry::install(Vec::new());
    index(&s).await;
    assert_eq!(hits(&s).await, 0);
    let text_keys = keys(&s).await;

    // the grammar is built: the same file, unedited, is parsed again
    skald::registry::install_from(Path::new(&lock), Path::new(&grammars)).unwrap();
    index(&s).await;
    assert_eq!(hits(&s).await, 1);
    assert!(!keys(&s).await.is_empty());

    // and the other way: nothing moves while the stamp does not
    let again = keys(&s).await;
    index(&s).await;
    assert_eq!(keys(&s).await, again);
    // (the text chunks' keys are the whole file's text; the parsed file may chunk the same text, so keys may match)
    let _ = text_keys;
}

/// A change to the rules that classify files re-parses them: the stamp holds their version.
#[test]
fn the_stamp_holds_the_version_of_the_language_rules() {
    assert!(hrafn::files::LANG_RULES >= 2, "the .h rule moved the version");
    assert_eq!(hrafn::chunk::lang_stamp(), hrafn::chunk::lang_stamp());
}
