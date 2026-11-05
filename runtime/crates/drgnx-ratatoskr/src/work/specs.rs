//! Live specs: a spec file an agent writes becomes a `spec` entity at once, not at the next scan
//! (docs/develop/work-space.md, "Live specs").
//!
//! A file under `docs/specs/` (a folder named by `drgnx-work-space-spec-dirs`, default [`DEFAULT_DIRS`]) written by an
//! agent's edit step is read after the write: its title is the first `# ` heading, and the entity goes in through the
//! scan's own door (`graph/put-parsed`, id `spec:<path>`), so the deny-list and the content compare apply as they do
//! for a scanned spec. Specs written by a shell command are seen by the scan, not here. The spec links `asked` to the
//! writer's current ask ([`crate::work::asks`]).

use runstav::methods::graph::PutParsedParams;
use serde_json::json;
use std::path::Path;
use std::sync::Arc;

/// The folders whose Markdown files are specs, as path tails.
pub const DEFAULT_DIRS: &[&str] = &["docs/specs/"];

/// The most of a spec file read for its title.
const READ_MAX: u64 = 1 << 20;

/// Whether PATH is a Markdown file under one of DIRS (each a folder tail such as `docs/specs/`), at any depth of the
/// workspace.
pub fn is_spec_path(path: &Path, dirs: &[&str]) -> bool {
    let p = path.to_string_lossy();
    if !p.ends_with(".md") {
        return false;
    }
    dirs.iter().any(|d| {
        let d = d.trim_start_matches('/');
        p.starts_with(d) || p.contains(&format!("/{d}"))
    })
}

/// The first `# ` heading of TEXT outside a code fence.
pub fn title_of(text: &str) -> Option<String> {
    let mut fence = false;
    for line in text.lines() {
        let t = line.trim_start();
        if t.starts_with("```") || t.starts_with("~~~") {
            fence = !fence;
        } else if !fence && let Some(h) = line.strip_prefix("# ") {
            let h = h.trim();
            if !h.is_empty() {
                return Some(h.to_string());
            }
        }
    }
    None
}

/// The `graph/put-parsed` request that stores the spec at PATH with TEXT.
pub fn params_for(path: &Path, text: &str, mtime: f64) -> PutParsedParams {
    let p = path.to_string_lossy().into_owned();
    let title = title_of(text).unwrap_or_else(|| {
        path.file_stem()
            .map_or_else(|| p.clone(), |s| s.to_string_lossy().into_owned())
    });
    serde_json::from_value(json!({"sources": [{
        "source": {"kind": "spec", "path": p},
        "mtime": mtime,
        "entities": [{"id": format!("spec:{p}"), "kind": "spec", "title": title,
                      "data": {"path": p, "line": 1}}]
    }]}))
    .expect("a put-parsed request")
}

/// SESSION wrote PATH: when it is a spec, store it, linked to the session's current ask (through ASKS). Best effort,
/// never blocks the step writer for long.
pub async fn on_written(
    writer: &crate::coord::Writer,
    tools: &Arc<norn::tools::Coord>,
    asks: Option<&crate::work::asks::AskTx>,
    session: &str,
    path: &Path,
) {
    if !is_spec_path(path, DEFAULT_DIRS) {
        return;
    }
    let owned = path.to_path_buf();
    let read = crate::clock::blocking(move || {
        let meta = std::fs::metadata(&owned).ok()?;
        if !meta.is_file() || meta.len() > READ_MAX {
            return None;
        }
        let mtime = meta
            .modified()
            .ok()?
            .duration_since(std::time::UNIX_EPOCH)
            .ok()?
            .as_secs_f64();
        Some((std::fs::read_to_string(&owned).ok()?, mtime))
    })
    .await;
    let Ok(Some((text, mtime))) = read else {
        return;
    };
    match crate::graph::put_parsed(writer, tools, params_for(path, &text, mtime)).await {
        // the scan's door writes it as the scan: the session's ask is linked here
        Ok(_) => {
            if let Some(a) = asks {
                a.send(crate::work::asks::AskEv::GraphWrite {
                    session: session.to_string(),
                    entity: format!("spec:{}", path.to_string_lossy()),
                    kind: "spec".into(),
                });
            }
        }
        Err(e) => tracing::warn!(session, "spec not stored: {}", e.message),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pattern D.
    #[test]
    fn a_written_spec_becomes_an_entity() {
        let p = params_for(
            Path::new("/w/org/docs/specs/2026-11-05-x.md"),
            "front\n\n```\n# not a title\n```\n\n# The real title\n\n# second\n",
            12.5,
        );
        let v = serde_json::to_value(&p).unwrap();
        let s = &v["sources"][0];
        assert_eq!(
            s["source"],
            json!({"kind": "spec", "path": "/w/org/docs/specs/2026-11-05-x.md"})
        );
        let e = &s["entities"][0];
        assert_eq!(e["id"], "spec:/w/org/docs/specs/2026-11-05-x.md");
        assert_eq!(
            (e["kind"].as_str(), e["title"].as_str()),
            (Some("spec"), Some("The real title"))
        );
        // no heading: the file's name
        let q = serde_json::to_value(params_for(
            Path::new("/w/docs/specs/a-b.md"),
            "no heading",
            1.0,
        ))
        .unwrap();
        assert_eq!(q["sources"][0]["entities"][0]["title"], "a-b");
    }

    /// Pattern D.
    #[test]
    fn outside_the_spec_dirs_is_ignored() {
        let d = DEFAULT_DIRS;
        assert!(is_spec_path(Path::new("/w/org/docs/specs/a.md"), d));
        assert!(is_spec_path(Path::new("/w/org/docs/specs/drgnx/a.md"), d));
        assert!(!is_spec_path(Path::new("/w/org/docs/plans/a.md"), d));
        assert!(!is_spec_path(Path::new("/w/org/docs/specs/a.txt"), d));
        assert!(!is_spec_path(Path::new("/w/org/src/specs/a.md"), d));
        assert!(!is_spec_path(Path::new("/w/org/mydocs/specs/a.md"), d));
    }
}
