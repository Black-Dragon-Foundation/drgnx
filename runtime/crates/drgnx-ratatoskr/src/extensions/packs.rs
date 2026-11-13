//! Language packs as rows of the Extensions view (docs/develop/packs.md): the built-in packs (`skald::builtin`) with
//! what the lock says of each. A pack is `available` until the lock records it, then `installed`; its layers (what it
//! gives) are the chips. Packs from an index or a URL come with the index (Task 8).

use super::catalog::{Detail, PackLock};
use runstav::methods::extensions as w;
use skald::manifest::Manifest;

/// What a pack gives, as the chips the row shows.
pub fn layers(m: &Manifest) -> Vec<String> {
    let mut out = Vec::new();
    let mut add = |on: bool, name: &str| {
        if on {
            out.push(name.to_owned());
        }
    };
    add(m.grammars.iter().any(|g| g.repo.is_some()), "grammar");
    add(m.mode.is_some(), "mode");
    add(!m.servers.is_empty(), "server");
    add(m.format.is_some(), "format");
    add(m.hrafn.is_some(), "search");
    add(!m.adapters.is_empty(), "debug");
    out
}

/// One row per built-in pack: the row, its search keywords (its name, extensions and language) and its detail.
pub fn rows(locked: &[PackLock]) -> Vec<(w::Row, Vec<String>, Detail)> {
    skald::builtin::manifests()
        .iter()
        .map(|m| {
            let lock = locked.iter().find(|l| l.name == m.pack);
            let mut keywords = vec![m.pack.clone()];
            keywords.extend(m.files.extensions.iter().cloned());
            keywords.extend(m.hrafn.as_ref().map(|h| h.lang.clone()));
            keywords.sort();
            keywords.dedup();
            let row = w::Row {
                id: format!("pack:{}", m.pack),
                kind: w::Kind::Pack,
                name: m.name.clone(),
                summary: m.summary.clone(),
                state: if lock.is_some() {
                    w::State::Installed
                } else {
                    w::State::Available
                },
                source: "builtin".into(),
                signed: w::Signed::None,
                version: Some(m.version.clone()),
                latest: None,
                downloads: None,
                why: lock
                    .filter(|l| l.wanted_user)
                    .map(|_| vec![w::Why::You])
                    .unwrap_or_default(),
                layers: layers(m),
            };
            let detail = Detail {
                requires: m
                    .requires
                    .packages
                    .iter()
                    .map(|p| w::Requirement {
                        name: p.clone(),
                        version: None,
                    })
                    .collect(),
                maintainer: m.maintainers.first().cloned(),
                url: None,
                commit: lock.and_then(|l| l.commit.clone()),
                revdesc: None,
            };
            (row, keywords, detail)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lock(name: &str, user: bool) -> PackLock {
        PackLock {
            name: name.into(),
            commit: Some("c".repeat(64)),
            wanted_user: user,
        }
    }

    #[test]
    fn every_builtin_pack_is_a_row_and_the_lock_says_which_is_installed() {
        let all = rows(&[]);
        assert_eq!(all.len(), skald::builtin::manifests().len());
        assert!(all.iter().all(|(r, _, _)| r.kind == w::Kind::Pack
            && r.state == w::State::Available
            && r.id.starts_with("pack:")
            && r.source == "builtin"));
        let with = rows(&[lock("python", true), lock("go", false)]);
        let state = |id: &str| with.iter().find(|(r, _, _)| r.id == id).unwrap().0.clone();
        assert_eq!(state("pack:python").state, w::State::Installed);
        assert_eq!(state("pack:python").why, vec![w::Why::You]);
        assert_eq!(state("pack:go").state, w::State::Installed);
        assert!(
            state("pack:go").why.is_empty(),
            "wanted by default, not asked for"
        );
        assert_eq!(state("pack:rust").state, w::State::Available);
    }

    #[test]
    fn the_chips_are_what_the_pack_gives() {
        let all = rows(&[]);
        let layers = |id: &str| {
            all.iter()
                .find(|(r, _, _)| r.id == id)
                .unwrap()
                .0
                .layers
                .clone()
        };
        assert_eq!(
            layers("pack:python"),
            ["grammar", "mode", "format", "search", "debug"]
        );
        assert_eq!(layers("pack:terraform"), ["mode", "format"]);
        assert_eq!(
            layers("pack:kotlin"),
            ["grammar", "mode", "server", "format"]
        );
        assert_eq!(
            layers("pack:php"),
            ["grammar", "mode", "server", "format", "debug"]
        );
    }

    #[test]
    fn a_row_is_found_by_its_name_extension_or_language() {
        let all = rows(&[]);
        let kw = |id: &str| all.iter().find(|(r, _, _)| r.id == id).unwrap().1.clone();
        for w in ["typescript", "ts", "mts"] {
            assert!(kw("pack:typescript").contains(&w.to_owned()), "{w}");
        }
        assert!(kw("pack:shell").contains(&"sh".to_owned()));
        // a package a pack requires is on its detail
        let haskell = all.iter().find(|(r, _, _)| r.id == "pack:haskell").unwrap();
        assert_eq!(haskell.2.requires[0].name, "haskell-ts-mode");
    }
}
