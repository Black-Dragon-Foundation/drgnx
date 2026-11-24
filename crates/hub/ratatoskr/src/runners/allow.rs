//! The allow-lists (docs/guide/jobs.md, "Allow-lists"): what the user lets a project's jobs pull or run, per project.
//!
//! - **Classes:** `image` (a registry digest a job may pull: an index digest, or a platform digest; an index entry
//!   allows every platform it lists), `tool` (a pinned tool), `host` (a `host` stage: the job runs on the machine, not
//!   in a container) and `fetch` (reserved).
//! - **Per project.** A project's list never applies to another's: the lookup is keyed by the project first.
//! - **Only the user** edits a list (`jobs/allow` is a user-class method): a connection that is an agent's is refused
//!   at the dispatch, whatever the class, `host` included.
//! - Stored in `runtime.db`'s `kv` as `allow/<project>/<class>` (a JSON array), so no migration number is taken.

use std::collections::{BTreeMap, BTreeSet};

use forseti::ProjectId;

/// The classes of an allow-list.
pub const CLASSES: [&str; 4] = ["image", "tool", "host", "fetch"];

/// The `kv` key of PROJECT's CLASS list.
pub fn kv_key(project: &str, class: &str) -> String {
    format!("allow/{project}/{class}")
}

/// Every project's lists.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Allow {
    rows: BTreeMap<(ProjectId, String), BTreeSet<String>>,
}

impl Allow {
    /// Rows `(kv key, JSON array)` as `runtime.db` holds them; a key or value that does not parse is dropped.
    pub fn from_kv(rows: impl IntoIterator<Item = (String, String)>) -> Allow {
        let mut a = Allow::default();
        for (key, value) in rows {
            let mut parts = key.splitn(3, '/');
            let (Some("allow"), Some(project), Some(class)) =
                (parts.next(), parts.next(), parts.next())
            else {
                continue;
            };
            if !CLASSES.contains(&class) {
                continue;
            }
            if let Ok(values) = serde_json::from_str::<BTreeSet<String>>(&value) {
                a.rows
                    .insert((ProjectId(project.to_string()), class.to_string()), values);
            }
        }
        a
    }

    /// PROJECT's CLASS list.
    pub fn list(&self, project: &ProjectId, class: &str) -> Vec<String> {
        self.rows
            .get(&(project.clone(), class.to_string()))
            .map(|s| s.iter().cloned().collect())
            .unwrap_or_default()
    }

    /// VALUE added to (ON) or removed from PROJECT's CLASS list; the list and its JSON for `runtime.db`.
    pub fn set(
        &mut self,
        project: &ProjectId,
        class: &str,
        value: &str,
        on: bool,
    ) -> villa::Result<(Vec<String>, String)> {
        if !CLASSES.contains(&class) {
            return Err(villa::Error::invalid(format!(
                "{class:?} is not an allow class: image, tool, host or fetch"
            )));
        }
        if value.is_empty() || value.contains(['\0', '\n']) {
            return Err(villa::Error::invalid(
                "an allow entry is one non-empty line",
            ));
        }
        let set = self
            .rows
            .entry((project.clone(), class.to_string()))
            .or_default();
        if on {
            set.insert(value.to_string());
        } else {
            set.remove(value);
        }
        let list: Vec<String> = set.iter().cloned().collect();
        let json =
            serde_json::to_string(&list).map_err(|e| villa::Error::internal(e.to_string()))?;
        Ok((list, json))
    }

    /// Whether PROJECT's list of CLASS has VALUE. The project is the first key of the lookup: another project's list
    /// is never read.
    pub fn allowed(&self, project: &ProjectId, class: &str, value: &str) -> bool {
        self.rows
            .get(&(project.clone(), class.to_string()))
            .is_some_and(|s| s.contains(value))
    }

    /// Whether PROJECT may pull the image of platform digest PLATFORM, listed by the index INDEX (when the registry
    /// has one): the platform digest itself on the list, or its index.
    pub fn image_allowed(&self, project: &ProjectId, platform: &str, index: Option<&str>) -> bool {
        self.allowed(project, "image", platform)
            || index.is_some_and(|i| self.allowed(project, "image", i))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> ProjectId {
        ProjectId(s.into())
    }

    // [D] pure
    #[test]
    fn another_projects_allow_list_does_not_apply() {
        let mut a = Allow::default();
        a.set(&p("drgnx"), "image", "sha256:aa", true).unwrap();
        assert!(a.allowed(&p("drgnx"), "image", "sha256:aa"));
        assert!(!a.allowed(&p("other"), "image", "sha256:aa"));
        assert!(!a.allowed(&p("drgnx"), "tool", "sha256:aa"));
    }

    // [D] pure
    #[test]
    fn an_index_digest_allows_its_platforms() {
        let mut a = Allow::default();
        a.set(&p("drgnx"), "image", "sha256:index", true).unwrap();
        assert!(a.image_allowed(&p("drgnx"), "sha256:amd64", Some("sha256:index")));
        assert!(!a.image_allowed(&p("drgnx"), "sha256:amd64", Some("sha256:other")));
        assert!(!a.image_allowed(&p("drgnx"), "sha256:amd64", None));
        a.set(&p("drgnx"), "image", "sha256:amd64", true).unwrap();
        assert!(a.image_allowed(&p("drgnx"), "sha256:amd64", None));
    }

    // [D] pure
    #[test]
    fn a_list_round_trips_through_the_kv_rows() {
        let mut a = Allow::default();
        let (_, json) = a.set(&p("drgnx"), "host", "make-docs", true).unwrap();
        let back = Allow::from_kv([(kv_key("drgnx", "host"), json)]);
        assert_eq!(back, a);
        // a stray key or a broken value is dropped, never read as a list
        let back = Allow::from_kv([
            ("allow/drgnx/bogus".to_string(), "[\"x\"]".to_string()),
            ("allow/drgnx/image".to_string(), "not json".to_string()),
            ("other".to_string(), "[]".to_string()),
        ]);
        assert_eq!(back, Allow::default());
        assert!(a.set(&p("drgnx"), "bogus", "x", true).is_err());
        assert!(a.set(&p("drgnx"), "host", "", true).is_err());
    }
}
