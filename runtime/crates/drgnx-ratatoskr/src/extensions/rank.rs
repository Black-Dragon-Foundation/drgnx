//! Search over the rows: which match, and in what order.
//!
//! A query is split into lower-cased words.  A row matches when each word is a prefix of a word of its name, or a
//! substring of its name, keywords or summary.  The rank of a row is the worst of its words' ranks:
//! exact name, name prefix, name word prefix, inside the name, keyword, summary; then installed first, then downloads,
//! then name.  The other sorts are plain keys with the name as the last tie-break.

use super::catalog::Entry;
use runstav::methods::extensions as w;
use std::cmp::Ordering;
use std::collections::HashSet;

/// The indexes of ENTRIES that match QUERY and FILTERS, in SORT's order.
pub fn search(entries: &[Entry], query: &str, filters: &w::Filters, sort: w::Sort) -> Vec<usize> {
    let lowered = query.to_lowercase();
    let tokens: Vec<&str> = lowered.split_whitespace().collect();
    let ids: Option<HashSet<&str>> = filters
        .ids
        .as_ref()
        .map(|v| v.iter().map(String::as_str).collect());
    let mut hits: Vec<(usize, u8)> = entries
        .iter()
        .enumerate()
        .filter(|(_, e)| keeps(e, filters, ids.as_ref()))
        .filter_map(|(i, e)| rank_of(e, &tokens).map(|r| (i, r)))
        .collect();
    hits.sort_by(|&(a, ra), &(b, rb)| {
        let (x, y) = (&entries[a], &entries[b]);
        let order = match sort {
            w::Sort::Relevance => ra
                .cmp(&rb)
                .then_with(|| y.is_installed().cmp(&x.is_installed()))
                .then_with(|| y.row.downloads.cmp(&x.row.downloads)),
            w::Sort::Name => Ordering::Equal,
            w::Sort::Downloads => y.row.downloads.cmp(&x.row.downloads),
            w::Sort::Updated => newest(y).cmp(&newest(x)),
            w::Sort::Installed => y.is_installed().cmp(&x.is_installed()),
        };
        order
            .then_with(|| x.lname.cmp(&y.lname))
            .then_with(|| x.row.id.cmp(&y.row.id))
    });
    hits.into_iter().map(|(i, _)| i).collect()
}

/// The version a row would show as newest.
fn newest(e: &Entry) -> Option<&str> {
    e.row.latest.as_deref().or(e.row.version.as_deref())
}

/// Whether FILTERS keep E.
fn keeps(e: &Entry, f: &w::Filters, ids: Option<&HashSet<&str>>) -> bool {
    let row = &e.row;
    (!f.installed || e.is_installed())
        && (!f.updates || row.state == w::State::Update)
        && (!f.enabled || row.state == w::State::On)
        && (!f.disabled || row.state == w::State::Off)
        && (!f.builtin || row.kind == w::Kind::Emacs)
        && (!f.plugins || row.kind == w::Kind::Plugin)
        && (!f.unsigned || row.signed == w::Signed::UnsignedArchive)
        && f.kind.is_none_or(|k| row.kind == k)
        && f.archive.as_ref().is_none_or(|a| row.source == *a)
        && f.keyword
            .as_ref()
            .is_none_or(|k| e.lkeywords.contains(&k.to_lowercase()))
        && ids.is_none_or(|set| set.contains(row.id.as_str()))
}

/// How well E matches every token (0 best), or none when one token does not match.
fn rank_of(e: &Entry, tokens: &[&str]) -> Option<u8> {
    let mut worst = 0;
    for t in tokens {
        worst = worst.max(token_rank(e, t)?);
    }
    Some(worst)
}

fn token_rank(e: &Entry, t: &str) -> Option<u8> {
    if e.lname == t {
        Some(0)
    } else if e.lname.starts_with(t) {
        Some(1)
    } else if e.words.iter().any(|w| w.starts_with(t)) {
        Some(2)
    } else if e.lname.contains(t) {
        Some(3)
    } else if e.lkeywords.iter().any(|k| k.contains(t)) {
        Some(4)
    } else if e.lsummary.contains(t) {
        Some(5)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::extensions::catalog::Detail;

    fn entry(
        name: &str,
        summary: &str,
        keywords: &[&str],
        installed: bool,
        downloads: u64,
    ) -> Entry {
        Entry::new(
            w::Row {
                id: format!("pkg:{name}"),
                kind: w::Kind::Package,
                name: name.into(),
                summary: summary.into(),
                state: if installed {
                    w::State::Installed
                } else {
                    w::State::Available
                },
                source: "melpa".into(),
                signed: w::Signed::UnsignedArchive,
                version: None,
                latest: None,
                downloads: (downloads > 0).then_some(downloads),
                why: Vec::new(),
            },
            keywords.iter().map(|k| k.to_string()).collect(),
            Detail::default(),
        )
    }

    fn names(entries: &[Entry], hits: &[usize]) -> Vec<String> {
        hits.iter().map(|&i| entries[i].row.name.clone()).collect()
    }

    fn run(entries: &[Entry], q: &str) -> Vec<String> {
        names(
            entries,
            &search(entries, q, &w::Filters::default(), w::Sort::Relevance),
        )
    }

    fn six() -> Vec<Entry> {
        vec![
            entry("forge", "Access Git forges from Magit", &["git"], false, 0),
            entry("forge-notes", "Notes", &["magit"], false, 0),
            entry("emacs-magit-extras", "Odds and ends", &[], false, 0),
            entry("magit-todos", "TODOs in a status buffer", &[], false, 0),
            entry(
                "magit",
                "A Git porcelain inside Emacs",
                &["git", "vc"],
                false,
                0,
            ),
            entry("git-link", "URL for a buffer location", &["git"], false, 0),
        ]
    }

    // pattern D
    #[test]
    fn search_ranks_exact_then_prefix_then_word_then_keyword_then_summary() {
        assert_eq!(
            run(&six(), "magit"),
            [
                "magit",
                "magit-todos",
                "emacs-magit-extras",
                "forge-notes",
                "forge"
            ]
        );
    }

    // pattern D
    #[test]
    fn every_token_must_match() {
        let rows = six();
        assert_eq!(run(&rows, "git porc"), ["magit"]);
        // a name prefix first; then "git" inside a name; then a keyword hit; the name breaks each tie
        assert_eq!(
            run(&rows, "git"),
            [
                "git-link",
                "emacs-magit-extras",
                "magit",
                "magit-todos",
                "forge",
                "forge-notes"
            ]
        );
        assert_eq!(run(&rows, "  MAGIT  Todos "), ["magit-todos"]);
        assert!(run(&rows, "nothing like it").is_empty());
    }

    // pattern D
    #[test]
    fn installed_breaks_ties_then_downloads_then_name() {
        let rows = vec![
            entry("zeta", "same", &[], false, 10),
            entry("beta", "same", &[], false, 500),
            entry("alpha", "same", &[], false, 500),
            entry("omega", "same", &[], true, 1),
        ];
        assert_eq!(run(&rows, "same"), ["omega", "alpha", "beta", "zeta"]);
        // the rank still comes first: a name hit beats an installed summary hit
        let rows = vec![
            entry("other", "about zeta", &[], true, 9),
            entry("zeta", "x", &[], false, 0),
        ];
        assert_eq!(run(&rows, "zeta"), ["zeta", "other"]);
    }

    // pattern D
    #[test]
    fn filters_narrow_and_the_sorts_order() {
        let mut rows = six();
        rows.push(entry("dash", "Lists", &["lists"], true, 99));
        let f = w::Filters {
            installed: true,
            ..Default::default()
        };
        assert_eq!(
            names(&rows, &search(&rows, "", &f, w::Sort::Name)),
            ["dash"]
        );
        let f = w::Filters {
            keyword: Some("vc".into()),
            ..Default::default()
        };
        assert_eq!(
            names(&rows, &search(&rows, "", &f, w::Sort::Name)),
            ["magit"]
        );
        let f = w::Filters {
            ids: Some(vec!["pkg:forge".into(), "pkg:dash".into()]),
            ..Default::default()
        };
        assert_eq!(
            names(&rows, &search(&rows, "", &f, w::Sort::Name)),
            ["dash", "forge"]
        );
        let f = w::Filters::default();
        assert_eq!(
            names(&rows, &search(&rows, "", &f, w::Sort::Downloads))[0],
            "dash"
        );
    }
}
