//! Who is here as rows (docs/develop/hub.md, "The presence model"): an editor that subscribes to a workspace's presence
//! with a VIEW gets, in every class of it, one row per agent present in the user's tree (`a:SESSION`, in ordinal order:
//! its newest entry) and one per shown path (`p:PATH`: a file an agent is about to change or has changed, and each
//! folder above it up to its root, with the ordinals of those agents). A file outside the roots is shown where it lands
//! in the user's tree (a linked worktree's file at its place in the main checkout); one that lands nowhere is not shown.
//! The rows say what they show as properties; the marks and colours of an ordinal are the editor's. Pure: the files,
//! the landing and the identities come in as arguments.

use super::{Entry, RepoPath, under};
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
        b.prop(0, end, "drgnx-presence-session", json!(a.session))
            .prop(0, end, "drgnx-presence-ordinal", json!(a.ordinal))
            .prop(0, end, "drgnx-presence-mode", mode)
            .prop(0, end, "drgnx-presence-file", json!(a.path))
            .prop(0, end, "drgnx-work-id", json!(key));
        if let Some(l) = a.line {
            b.prop(0, end, "drgnx-presence-line", json!(l));
        }
        out.push(b.finish());
    }
    for (path, (ords, dir)) in &h.paths {
        let mut b = RowBuilder::new(format!("p:{path}"));
        b.push(path, None);
        let end = b.pos();
        b.prop(0, end, "drgnx-presence-ordinals", json!(ords)).prop(
            0,
            end,
            "drgnx-presence-dir",
            json!(dir),
        );
        out.push(b.finish());
    }
    out
}

#[cfg(test)]
mod tests;
