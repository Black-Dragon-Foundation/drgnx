//! Temporary layouts (§5.3.3): a multi-window tool (ediff, gdb) holds one group for its lifetime.
//!
//! The tool's tab is active while it lasts; opens aimed at the group go to the next group (with one group, behind the
//! tool's tab, not activated); activating another of its tabs is refused with the reason. A temporary layout is never
//! saved (its return tab is) and never enters layout undo. Only a user command starts one.

use crate::intent::Intent;
use crate::model::{
    Focus, GroupId, Origin, Ref, Refusal, TabId, TempLayout, Version, Workbench, refuse,
};

impl Workbench {
    /// Start a tool's temporary layout in group `g`; returns its tab.
    pub fn begin_temp_layout(
        &mut self,
        g: GroupId,
        tool: &str,
        title: &str,
        origin: Origin,
    ) -> Result<(Version, TabId), Refusal> {
        self.gate(origin, Intent::TempLayout)?;
        let Some(w) = self.window_of_group(g) else {
            return refuse("no such group");
        };
        let wi = self.wi(w)?;
        if let Some(tl) = &self.groups[&g].temp {
            return refuse(crate::intent::temp_reason(&tl.tool));
        }
        let return_to = self.groups[&g].active;
        let r = Ref::Buffer {
            id: format!("smidja-temp:{tool}:{}", g.0),
            name: title.to_string(),
        };
        let t = self.new_tab(r, false, Some("text".to_string()), Some(title.to_string()));
        let grp = self.group_mut(g);
        let at = match return_to.and_then(|a| grp.tabs.iter().position(|x| *x == a)) {
            Some(i) => i + 1,
            None => grp.tabs.len(),
        };
        grp.tabs.insert(at, t);
        grp.mru.push(t);
        grp.temp = Some(TempLayout {
            tool: tool.to_string(),
            tab: t,
            return_to,
        });
        self.activate(wi, g, t);
        self.set_base_focus(wi, Focus::Center(g));
        Ok((self.bump(), t))
    }

    /// End group `g`'s temporary layout: the tool's tab goes and its return tab is active again.
    pub fn end_temp_layout(&mut self, g: GroupId) -> Result<Version, Refusal> {
        let Some(w) = self.window_of_group(g) else {
            return refuse("no such group");
        };
        let wi = self.wi(w)?;
        let Some(tl) = self.group_mut(g).temp.take() else {
            return refuse("no temporary layout in this group");
        };
        self.detach(g, tl.tab);
        self.tabs.remove(&tl.tab);
        if let Some(r) = tl.return_to.filter(|r| self.groups[&g].tabs.contains(r)) {
            self.activate(wi, g, r);
        }
        Ok(self.bump())
    }

    /// The temporary layout a group holds.
    pub fn temp_of(&self, g: GroupId) -> Option<&TempLayout> {
        self.groups.get(&g)?.temp.as_ref()
    }
}
