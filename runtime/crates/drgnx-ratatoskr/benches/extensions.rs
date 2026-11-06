//! The Extensions catalog at the size of the four archives (7,150 packages): `catalog-load` (the file parsed and merged
//! into the index) and `search` (a ranked query over the rows).  Budgets (design §13): load at most 100 ms and 15 MB
//! resident, a search at most 3 ms at the 95th percentile.  Ignored in normal runs; the combined gate pass runs it under
//! the perf lock: `cargo test -p drgnx-ratatoskr --bench extensions -- --ignored --nocapture`.  It measures and prints;
//! the pass judges.  The catalog is made here from fixed arithmetic (no network, no random numbers), in the shape
//! `drgnx extensions refresh` writes.

use std::time::Instant;

use drgnx_ratatoskr::extensions::catalog::{Inputs, build, parse_catalog};
use drgnx_ratatoskr::extensions::rank;
use runstav::methods::extensions as w;
use serde_json::json;

const WORDS: [&str; 24] = [
    "magit",
    "org",
    "evil",
    "lsp",
    "dash",
    "helm",
    "ivy",
    "company",
    "flycheck",
    "projectile",
    "git",
    "rust",
    "go",
    "python",
    "docker",
    "yaml",
    "json",
    "web",
    "mode",
    "theme",
    "snippets",
    "tree",
    "sitter",
    "vterm",
];

/// (archive, packages): the four archives at their 2026-11-06 sizes.
const ARCHIVES: [(&str, usize); 4] = [
    ("gnu", 420),
    ("nongnu", 480),
    ("melpa", 5500),
    ("melpa-stable", 750),
];

/// The catalog file's bytes: every archive's packages, one entry each.
fn catalog() -> Vec<u8> {
    let mut packages = Vec::new();
    for (a, (archive, count)) in ARCHIVES.iter().enumerate() {
        for i in 0..*count {
            let name = format!(
                "{}-{}-{}{}",
                WORDS[(i * 7) % WORDS.len()],
                WORDS[(i * 13 + a) % WORDS.len()],
                (b'a' + a as u8) as char,
                i
            );
            packages.push(json!({
                "name": name,
                "summary": format!("Fixture package {i} of {archive}, a {} helper", WORDS[i % WORDS.len()]),
                "keywords": ["tools", WORDS[(i * 5) % WORDS.len()]],
                "maintainer": "A. Maintainer",
                "url": "https://example.invalid/pkg",
                "kind": if i % 3 == 0 { "single" } else { "tar" },
                "versions": [{"archive": archive, "version": format!("1.{}", i % 9),
                              "reqs": if i % 5 == 0 { json!([["emacs", "29.1"]]) } else { json!([]) }}],
                "candidate": {"archive": archive, "version": format!("1.{}", i % 9)},
                "held": false,
                "incompat": false,
                "downloads": i * 3,
            }));
        }
    }
    let archives: Vec<_> = ARCHIVES
        .iter()
        .map(|(n, _)| json!({"name": n, "url": format!("https://example.invalid/{n}/"), "signed": *n == "gnu"}))
        .collect();
    serde_json::to_vec(&json!({
        "version": 1, "written": 1_730_851_200.0, "emacs": "31.1",
        "archives": archives, "packages": packages,
    }))
    .unwrap()
}

/// Resident memory in kB (Linux), 0 where there is no /proc.
fn rss_kb() -> u64 {
    std::fs::read_to_string("/proc/self/statm")
        .ok()
        .and_then(|s| s.split_whitespace().nth(1).and_then(|p| p.parse::<u64>().ok()))
        .map(|pages| pages * 4)
        .unwrap_or(0)
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    sorted[((sorted.len() as f64 * p) as usize).min(sorted.len() - 1)]
}

#[test]
#[ignore]
fn catalog_load() {
    let bytes = catalog();
    println!(
        "catalog-load: {} packages, {} kB of JSON",
        ARCHIVES.iter().map(|a| a.1).sum::<usize>(),
        bytes.len() / 1024
    );
    let mut times = Vec::new();
    for _ in 0..21 {
        let t = Instant::now();
        let file = parse_catalog(&bytes).unwrap();
        let index = build(Inputs {
            catalog: Some(&file),
            ..Inputs::default()
        });
        times.push(t.elapsed().as_secs_f64() * 1000.0);
        assert!(index.entries.len() >= 7000);
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!(
        "catalog-load: p50 {:.1} ms, p95 {:.1} ms, max {:.1} ms (budget 100 ms)",
        percentile(&times, 0.5),
        percentile(&times, 0.95),
        times.last().unwrap()
    );
    // resident: the index alone, as the hub keeps it (the bytes and the parsed file are gone by then)
    let before = rss_kb();
    let index = {
        let file = parse_catalog(&bytes).unwrap();
        build(Inputs {
            catalog: Some(&file),
            ..Inputs::default()
        })
    };
    let after = rss_kb();
    println!(
        "catalog-load: index of {} rows resident +{} kB (budget 15360 kB; rss {} kB before, {} after)",
        index.entries.len(),
        after.saturating_sub(before),
        before,
        after
    );
}

#[test]
#[ignore]
fn search() {
    let bytes = catalog();
    let file = parse_catalog(&bytes).unwrap();
    let index = build(Inputs {
        catalog: Some(&file),
        ..Inputs::default()
    });
    let queries = [
        "magit", "dash helm", "e", "ts", "fixture package", "vterm-ivy", "zzzz", "",
    ];
    let filters = [
        w::Filters::default(),
        w::Filters {
            unsigned: true,
            ..w::Filters::default()
        },
        w::Filters {
            archive: Some("melpa".into()),
            keyword: Some("tools".into()),
            ..w::Filters::default()
        },
    ];
    let mut times = Vec::new();
    for round in 0..40 {
        for q in &queries {
            for f in &filters {
                let sort = if round % 4 == 3 { w::Sort::Downloads } else { w::Sort::Relevance };
                let t = Instant::now();
                let hits = rank::search(&index.entries, q, f, sort);
                times.push(t.elapsed().as_secs_f64() * 1000.0);
                std::hint::black_box(hits);
            }
        }
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!(
        "search: {} searches over {} rows: p50 {:.2} ms, p95 {:.2} ms, max {:.2} ms (budget p95 3 ms)",
        times.len(),
        index.entries.len(),
        percentile(&times, 0.5),
        percentile(&times, 0.95),
        times.last().unwrap()
    );
}
