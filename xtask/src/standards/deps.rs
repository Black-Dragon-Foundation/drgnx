//! The layers: `[[layer]]` rows of standards.toml. A crate may not depend on a named crate, directly or through other
//! workspace crates (normal and build dependencies, from `cargo metadata`).

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use super::Finding;
use super::table::{Member, Table, rel};

pub fn check(root: &Path, table: &Table, members: &[Member]) -> Vec<Finding> {
    let by_name: BTreeMap<&str, &Member> = members.iter().map(|m| (m.name.as_str(), m)).collect();
    let mut out = Vec::new();
    for layer in &table.layer {
        let Some(top) = by_name.get(layer.krate.as_str()) else {
            continue;
        };
        // every crate reachable from TOP, each with the direct dependency of TOP it came through
        let mut seen: BTreeSet<&str> = BTreeSet::new();
        let mut stack: Vec<(&str, &str)> =
            top.deps.iter().map(|d| (d.as_str(), d.as_str())).collect();
        while let Some((name, via)) = stack.pop() {
            if !seen.insert(name) {
                continue;
            }
            if layer.may_not_depend.iter().any(|n| n == name) {
                let manifest = top.dir.join("Cargo.toml");
                out.push(Finding {
                    line: line_of(&manifest, via),
                    file: rel(root, &manifest).into(),
                    id: "standards".into(),
                    rule: "layer".into(),
                    message: if name == via {
                        format!("`{}` may not depend on `{name}`", layer.krate)
                    } else {
                        format!(
                            "`{}` may not depend on `{name}` (it does through `{via}`)",
                            layer.krate
                        )
                    },
                    krate: Some(layer.krate.clone()),
                });
            }
            if let Some(m) = by_name.get(name) {
                stack.extend(m.deps.iter().map(|d| (d.as_str(), via)));
            }
        }
    }
    out
}

/// The line of MANIFEST that names DEP, else 1.
fn line_of(manifest: &Path, dep: &str) -> usize {
    std::fs::read(manifest)
        .ok()
        .and_then(|b| {
            String::from_utf8_lossy(&b)
                .lines()
                .position(|l| l.trim_start().starts_with(dep))
                .map(|i| i + 1)
        })
        .unwrap_or(1)
}
