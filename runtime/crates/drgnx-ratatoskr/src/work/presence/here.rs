//! Who is here as rows (docs/develop/hub.md, "The presence model"): an editor that subscribes to a workspace's presence
//! with a VIEW gets, in every class of it, one row per agent present in the user's tree (`a:SESSION`, in ordinal order:
//! its newest entry) and one per shown path (`p:PATH`: a file an agent is about to change or has changed, and each
//! folder above it up to its root, with the ordinals of those agents). A file outside the roots is shown where it lands
//! in the user's tree (a linked worktree's file at its place in the main checkout); one that lands nowhere is not shown.
//! What the rows show is the view's model ([`doc`]: a node per row, its data as fields, the lists `agents` and
//! `paths`); a row holds only its key and text. The marks and colours of an ordinal are the editor's. Pure: the files,
//! the landing and the identities come in as arguments.

use super::{Entry, RepoPath, under};
use crate::view::model::Doc;
use drgnx_rows::{Row, RowBuilder};
use runstav::methods::work::PresenceMode as Mode;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

/// One agent here: its newest entry in the user's tree.
#[derive(Clone, Debug, PartialEq)]
pub struct Agent {
    pub session: String,
    pub ordinal: u32,
    pub handle: String,
    pub mode: Mode,
    /// Where it is, in the user's tree.
    pub path: String,
    pub line: Option<u32>,
    at: f64,
}

/// What the view shows: the agents in ordinal order, and each shown path's ordinals and whether it is a folder.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Here {
    pub agents: Vec<Agent>,
    pub paths: BTreeMap<String, (BTreeSet<u32>, bool)>,
}

/// The modes that put a badge on a file: about to change, written by a command, changed by an edit.
fn editing(m: Mode) -> bool {
    matches!(m, Mode::Pending | Mode::Write | Mode::Edit)
}

/// Who is here from FILES (who is in each file now) under ROOTS: LAND places a file outside the roots in the user's
/// tree (or nowhere); IDENT is a session's (ordinal, handle), none before the hub named it (such an agent is not shown).
pub fn here(
    files: &[(RepoPath, Vec<Entry>)],
    roots: &[String],
    land: impl Fn(&str) -> Option<String>,
    ident: impl Fn(&str) -> Option<(u32, String)>,
) -> Here {
    let root_of = |p: &str| {
        roots
            .iter()
            .filter(|r| under(p, r))
            .max_by_key(|r| r.len())
            .map(|r| r.trim_end_matches('/').to_owned())
    };
    let mut newest: BTreeMap<String, Agent> = BTreeMap::new();
    let mut paths: BTreeMap<String, (BTreeSet<u32>, bool)> = BTreeMap::new();
    for (file, entries) in files {
        let (path, root) = match root_of(file) {
            Some(r) => (file.clone(), r),
            None => match land(file).and_then(|p| root_of(&p).map(|r| (p, r))) {
                Some(pr) => pr,
                None => continue,
            },
        };
        for e in entries {
            let Some((ordinal, handle)) = ident(&e.session) else {
                continue;
            };
            if newest.get(&e.session).is_none_or(|old| e.at > old.at) {
                newest.insert(
                    e.session.clone(),
                    Agent {
                        session: e.session.clone(),
                        ordinal,
                        handle,
                        mode: e.mode,
                        path: path.clone(),
                        line: e.line,
                        at: e.at,
                    },
                );
            }
            if editing(e.mode) {
                paths.entry(path.clone()).or_default().0.insert(ordinal);
                let mut dir = Path::new(&path).parent().map(Path::to_path_buf);
                while let Some(d) = dir {
                    let name = d.to_string_lossy().into_owned();
                    if !under(&name, &root) {
                        break;
                    }
                    let entry = paths.entry(name.clone()).or_default();
                    entry.0.insert(ordinal);
                    entry.1 = true;
                    if name == root {
                        break;
                    }
                    dir = d.parent().map(Path::to_path_buf);
                }
            }
        }
    }
    let mut agents: Vec<Agent> = newest.into_values().collect();
    agents.sort_by_key(|a| a.ordinal);
    Here { agents, paths }
}

/// ORDS space-separated, in order.
fn ordinals(ords: &BTreeSet<u32>) -> String {
    ords.iter()
        .map(u32::to_string)
        .collect::<Vec<_>>()
        .join(" ")
}

fn mode_name(m: Mode) -> Value {
    serde_json::to_value(m).unwrap_or(Value::Null)
}

/// The view's rows: the agents, then the paths.
pub fn rows(h: &Here) -> Vec<Row> {
    let mut out = Vec::with_capacity(h.agents.len() + h.paths.len());
    for a in &h.agents {
        let key = format!("a:{}", a.session);
        let name = Path::new(&a.path)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let mode = mode_name(a.mode);
        let mut b = RowBuilder::new(key.clone());
        b.push(&a.handle, None).push(
            &format!(
                " · {} · {}{}",
                mode.as_str().unwrap_or("here"),
                name,
                a.line.map(|l| format!(":{l}")).unwrap_or_default()
            ),
            None,
        );
        let end = b.pos();
        b.prop(0, end, "drgnx-work-id", json!(key));
        out.push(b.finish());
    }
    // a path's row says its ordinals too: a change of who edits it is a change of its row, which names the model's
    for (path, (ords, _)) in &h.paths {
        let key = format!("p:{path}");
        let mut b = RowBuilder::new(key.clone());
        b.push(&format!("{path} · {}", ordinals(ords)), None);
        let end = b.pos();
        b.prop(0, end, "drgnx-work-id", json!(key));
        out.push(b.finish());
    }
    out
}

/// The view's model: a node per row with what it shows as fields (an agent: `label` its handle, `session`, `ordinal`,
/// `mode`, `file`, `line`; a path, of kind `file` or `folder`: `path` and `ordinals`, the agents' ordinals in order,
/// space-separated), and the lists `agents` (in ordinal order) and `paths`.
pub fn doc(h: &Here) -> Doc {
    let mut d = Doc {
        descriptor: json!({
            "scheme": "tree",
            "chain_kinds": [],
            "match_fields": ["label"],
            "lists": ["agents", "paths"],
            "classes": ["selected"],
            "flags": [],
            "forms": [],
            "start": "agents",
        }),
        ..Doc::default()
    };
    let mut agents = Vec::with_capacity(h.agents.len());
    for a in &h.agents {
        let id = format!("a:{}", a.session);
        let mut fields = vec![
            json!(["label", a.handle]),
            json!(["session", a.session]),
            json!(["ordinal", a.ordinal]),
            json!(["mode", mode_name(a.mode)]),
            json!(["file", a.path]),
        ];
        if let Some(l) = a.line {
            fields.push(json!(["line", l]));
        }
        d.nodes.insert(
            id.clone(),
            json!({"id": id, "kind": "agent", "flags": 0, "fields": fields}),
        );
        agents.push(id);
    }
    let mut paths = Vec::with_capacity(h.paths.len());
    for (path, (ords, dir)) in &h.paths {
        let id = format!("p:{path}");
        d.nodes.insert(
            id.clone(),
            json!({"id": id, "kind": if *dir { "folder" } else { "file" }, "flags": 0,
                   "fields": [["label", path], ["path", path], ["ordinals", ordinals(ords)]]}),
        );
        paths.push(id);
    }
    d.lists.insert("agents".into(), agents);
    d.lists.insert("paths".into(), paths);
    d
}

#[cfg(test)]
mod tests;
