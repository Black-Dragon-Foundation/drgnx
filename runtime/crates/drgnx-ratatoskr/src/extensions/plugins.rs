//! The plugins as rows of the list: the hub's own account of them (`plugins/list`, read from memory), merged with which
//! of the approved ones the user's `drgnx-agents-plugins` setting turns on.

use runstav::methods::extensions as w;
use runstav::methods::plugins::{PluginRow, PluginState};

/// The row of each plugin in LIST.  ON names the plugins the user's setting turns on; an approved plugin is `on` when
/// it is named there and `off` when it is not, every other state is the hub's own.
pub fn rows(list: &[PluginRow], on: &[String]) -> Vec<w::Row> {
    list.iter()
        .map(|p| {
            let (state, signed) = match p.state {
                PluginState::Approved if on.contains(&p.name) => {
                    (w::State::On, w::Signed::HashApproved)
                }
                PluginState::Approved => (w::State::Off, w::Signed::HashApproved),
                PluginState::Unapproved => (w::State::Unapproved, w::Signed::None),
                PluginState::Changed => (w::State::Changed, w::Signed::None),
                PluginState::Disabled => (w::State::Disabled, w::Signed::None),
                PluginState::Broken => (w::State::Broken, w::Signed::None),
            };
            w::Row {
                id: format!("plugin:{}", p.name),
                kind: w::Kind::Plugin,
                name: p.name.clone(),
                summary: summary(p),
                state,
                source: "plugin".into(),
                signed,
                version: p.version.clone(),
                latest: None,
                downloads: None,
                why: Vec::new(),
            }
        })
        .collect()
}

/// One line on what the plugin reaches (a broken one says why).
fn summary(p: &PluginRow) -> String {
    if let Some(problem) = &p.problem {
        return format!("Plugin, broken: {problem}");
    }
    let count =
        |n: usize, one: &str, many: &str| format!("{n} {}", if n == 1 { one } else { many });
    format!(
        "Plugin: {}, {}, {}",
        count(p.abilities.len(), "ability", "abilities"),
        count(p.hooks.len(), "hook", "hooks"),
        count(p.hosts.len(), "host", "hosts"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plugin(name: &str, state: PluginState) -> PluginRow {
        PluginRow {
            name: name.into(),
            version: Some("1.0".into()),
            hash: None,
            state,
            abilities: vec!["lookup".into()],
            hooks: Vec::new(),
            hosts: Vec::new(),
            kv_bytes: None,
            approved_reach: None,
            problem: None,
        }
    }

    // pattern D
    #[test]
    fn plugin_rows_follow_the_hubs_states() {
        let mut broken = plugin("bad", PluginState::Broken);
        broken.problem = Some("no manifest".into());
        let list = [
            plugin("new", PluginState::Unapproved),
            plugin("moved", PluginState::Changed),
            plugin("stopped", PluginState::Disabled),
            broken,
        ];
        let rows = rows(&list, &[]);
        let states: Vec<_> = rows.iter().map(|r| (r.id.as_str(), r.state)).collect();
        assert_eq!(
            states,
            [
                ("plugin:new", w::State::Unapproved),
                ("plugin:moved", w::State::Changed),
                ("plugin:stopped", w::State::Disabled),
                ("plugin:bad", w::State::Broken),
            ]
        );
        assert!(rows.iter().all(|r| r.kind == w::Kind::Plugin
            && r.source == "plugin"
            && r.signed == w::Signed::None));
        assert_eq!(rows[3].summary, "Plugin, broken: no manifest");
        assert_eq!(rows[0].summary, "Plugin: 1 ability, 0 hooks, 0 hosts");
    }

    // pattern D
    #[test]
    fn on_and_off_come_from_the_plugins_setting() {
        let list = [
            plugin("a", PluginState::Approved),
            plugin("b", PluginState::Approved),
            plugin("c", PluginState::Unapproved),
        ];
        // named in the setting: on; approved and not named: off; the setting never turns on what is not approved
        let rows = rows(&list, &["a".into(), "c".into()]);
        assert_eq!(rows[0].state, w::State::On);
        assert_eq!(rows[1].state, w::State::Off);
        assert_eq!(rows[2].state, w::State::Unapproved);
        assert_eq!(rows[0].signed, w::Signed::HashApproved);
        assert_eq!(rows[1].signed, w::Signed::HashApproved);
    }
}
