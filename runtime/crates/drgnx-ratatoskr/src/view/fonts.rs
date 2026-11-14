//! The font files the editor names in `view/env`: read once per file, kept while an env names them, and made into
//! the [`FontSet`] a (view, class)'s builders measure with. The only font file read of the hub (`drgnx-rows` and
//! vegvisir do no I/O).

use drgnx_rows::fit::{Font, FontSet};
use runstav::methods::view::ViewEnv;
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;

/// The most font files held (each is dropped when no env names it).
pub const FILES_MAX: usize = 64;
/// The largest font file read (a CJK collection is ~30 MB): a bigger one is measured through the editor.
pub const FILE_MAX_BYTES: u64 = 64 << 20;

/// The bytes of the font files the live envs name.
#[derive(Default)]
pub struct Files {
    bytes: BTreeMap<String, Arc<Vec<u8>>>,
}

impl Files {
    /// FILE's bytes, read the first time; none when it cannot be read or is too large.
    fn get(&mut self, file: &str) -> Option<Arc<Vec<u8>>> {
        if let Some(b) = self.bytes.get(file) {
            return Some(b.clone());
        }
        if self.bytes.len() >= FILES_MAX {
            return None;
        }
        let p = Path::new(file);
        let len = std::fs::metadata(p).ok()?.len();
        if len > FILE_MAX_BYTES {
            return None;
        }
        let b = Arc::new(std::fs::read(p).ok()?);
        self.bytes.insert(file.to_owned(), b.clone());
        Some(b)
    }

    /// The font set ENV names: each role's face from its file (none when the env names no file, or it cannot be
    /// read: that role is measured through the editor).
    pub fn font_set(&mut self, env: &ViewEnv) -> FontSet {
        let mut set = FontSet::new();
        for (role, file, index, px, _ascent, _descent, avg, _space) in &env.fonts {
            let font = file
                .as_deref()
                .and_then(|f| self.get(f))
                .and_then(|b| Font::new(b, *index, *px, &[]).ok());
            set.set_role(role, font, *avg);
        }
        set
    }

    /// Drop the files no env in ENVS names.
    pub fn keep_only<'a>(&mut self, envs: impl Iterator<Item = &'a ViewEnv>) {
        let named: std::collections::BTreeSet<&str> = envs
            .flat_map(|e| e.fonts.iter().filter_map(|f| f.1.as_deref()))
            .collect();
        self.bytes.retain(|f, _| named.contains(f.as_str()));
    }
}
