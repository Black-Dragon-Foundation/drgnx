//! The live theme switch: the `ui.theme` setting names the theme, and a change redraws. It lives here, not in `mot`, so
//! that the token table (`mot`) needs no settings and can sit under glitnir, skel, sja and smidja.

use std::sync::Arc;
use std::sync::mpsc::Receiver;

use mot::Theme;

use crate::{Changed, Kind, Settings};

/// The setting that names the theme.
pub const THEME_KEY: &str = "ui.theme";

/// The themes, the current one, and a watch on the settings. [`ThemeSwitch::poll`] applies a change and counts a damage
/// event for it: the UI redraws every window when it grows.
pub struct ThemeSwitch {
    themes: Vec<Arc<Theme>>,
    current: Arc<Theme>,
    changes: Receiver<Changed>,
    settings: Arc<Settings>,
    damage: u64,
}

impl ThemeSwitch {
    /// Define `ui.theme` (default `dark`) on SETTINGS and follow it. THEMES must include the default and the chosen one.
    pub fn new(settings: Arc<Settings>, themes: Vec<Theme>) -> villa::Result<ThemeSwitch> {
        settings.define(THEME_KEY, Kind::Str, serde_json::json!("dark"))?;
        let changes = settings.watch();
        let themes: Vec<Arc<Theme>> = themes.into_iter().map(Arc::new).collect();
        let current = Self::chosen(&settings, &themes)?;
        Ok(ThemeSwitch {
            themes,
            current,
            changes,
            settings,
            damage: 0,
        })
    }

    fn chosen(settings: &Settings, themes: &[Arc<Theme>]) -> villa::Result<Arc<Theme>> {
        let name: String = settings.get(THEME_KEY)?;
        themes
            .iter()
            .find(|t| t.name() == name)
            .cloned()
            .ok_or_else(|| villa::Error::not_found(format!("There is no theme called `{name}`.")))
    }

    pub fn current(&self) -> &Theme {
        &self.current
    }

    /// How many times the theme changed under the UI: a counter of damage events.
    pub fn damage_events(&self) -> u64 {
        self.damage
    }

    /// Apply the changes that have come in. Returns whether the theme changed (a redraw is due). A theme that is not
    /// there leaves the current one in place and is reported.
    pub fn poll(&mut self) -> villa::Result<bool> {
        let mut theme_changed = false;
        while let Ok(c) = self.changes.try_recv() {
            theme_changed |= c.key == THEME_KEY;
        }
        if !theme_changed {
            return Ok(false);
        }
        let next = Self::chosen(&self.settings, &self.themes)?;
        if Arc::ptr_eq(&next, &self.current) {
            return Ok(false);
        }
        self.current = next;
        self.damage += 1;
        Ok(true)
    }
}
