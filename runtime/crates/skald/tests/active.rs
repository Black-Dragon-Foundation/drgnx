//! `active.eld` as the hub reads it (language packs Task 6b-1): each pack's manifest and its built grammar folders.

use skald::registry::{ActivePack, active_from};
use std::path::PathBuf;

#[test]
fn the_packs_of_an_active_file_with_their_manifests_and_grammar_folders() {
    let text = br#";; drgnx active language packs
(:version 1 :packs ((rust :manifest "/p/rust/pack.eld" :grammars ((rust . "/d/grammars/rust/abc")))
                    (mylang :manifest "/data/packs/mylang/pack.eld" :translated nil
                            :grammars ((mylang . "/d/grammars/mylang/def") (mylang-inline . "/d/grammars/mi/123")))
                    (nogrammar :manifest "/p/x/pack.eld" :grammars nil)
                    (broken :grammars nil)))"#;
    let got = active_from(text).unwrap();
    assert_eq!(
        got,
        vec![
            ActivePack {
                name: "rust".into(),
                manifest: PathBuf::from("/p/rust/pack.eld"),
                grammars: vec![("rust".into(), PathBuf::from("/d/grammars/rust/abc"))],
            },
            ActivePack {
                name: "mylang".into(),
                manifest: PathBuf::from("/data/packs/mylang/pack.eld"),
                grammars: vec![
                    ("mylang".into(), PathBuf::from("/d/grammars/mylang/def")),
                    ("mylang-inline".into(), PathBuf::from("/d/grammars/mi/123")),
                ],
            },
            ActivePack {
                name: "nogrammar".into(),
                manifest: PathBuf::from("/p/x/pack.eld"),
                grammars: vec![],
            },
        ]
    );
    assert_eq!(active_from(b"(:version 1)").unwrap(), vec![]);
    assert!(active_from(b"\"not a plist\"").is_err());
}
