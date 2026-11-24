//! tidindi (*tíðindi*, tidings, news): the one list of what wants the user's attention
//! (docs/develop/standards/attention.md).
//!
//! A [`Notice`] has a level, a title, a body, actions and an optional [`DedupTag`]: posting a notice whose key is
//! already on the list updates that notice in place (and keeps its id) instead of adding another. The list is shown as
//! rows ([`Notices::rows`]), so it is a Sjá list like every other: searchable, selectable, readable by a screen reader.

use std::sync::Mutex;

use rodd::Row;
use rodd::RowBuilder;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Level {
    Info,
    Warning,
    Error,
}

impl Level {
    pub fn name(self) -> &'static str {
        match self {
            Level::Info => "info",
            Level::Warning => "warning",
            Level::Error => "error",
        }
    }

    pub fn from_name(name: &str) -> Option<Level> {
        [Level::Info, Level::Warning, Level::Error]
            .into_iter()
            .find(|l| l.name() == name)
    }

    /// The face of the level's mark: the standard faces, so a theme colours them.
    fn face(self) -> &'static str {
        match self {
            Level::Info => rodd::faces::FaceId::Shadow.name(),
            Level::Warning => rodd::faces::FaceId::Warning.name(),
            Level::Error => rodd::faces::FaceId::Error.name(),
        }
    }
}

/// What makes two postings one notice.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub struct DedupTag(pub String);

/// Something the user can do about a notice.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Action {
    pub id: String,
    pub label: String,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Notice {
    pub level: Level,
    pub title: String,
    pub body: String,
    pub actions: Vec<Action>,
    pub key: Option<DedupTag>,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct NoticeId(pub u64);

struct Held {
    id: NoticeId,
    notice: Notice,
    /// how many times it was posted (a deduplicated notice counts up)
    count: u32,
}

#[derive(Default)]
struct List {
    next: u64,
    items: Vec<Held>,
}

/// The list. Share it by reference.
#[derive(Default)]
pub struct Notices {
    list: Mutex<List>,
}

impl Notices {
    pub fn new() -> Notices {
        Notices::default()
    }

    /// Post N. A notice whose key is on the list already replaces that one in place: the same id, the new text, the
    /// count up by one.
    pub fn post(&self, n: Notice) -> NoticeId {
        let mut l = saman::lock(&self.list);
        if let Some(key) = &n.key
            && let Some(h) = l
                .items
                .iter_mut()
                .find(|h| h.notice.key.as_ref() == Some(key))
        {
            h.notice = n;
            h.count += 1;
            return h.id;
        }
        l.next += 1;
        let id = NoticeId(l.next);
        l.items.push(Held {
            id,
            notice: n,
            count: 1,
        });
        id
    }

    pub fn dismiss(&self, id: NoticeId) -> villa::Result<()> {
        let mut l = saman::lock(&self.list);
        let before = l.items.len();
        l.items.retain(|h| h.id != id);
        if l.items.len() == before {
            return Err(villa::Error::not_found("That notice is gone already."));
        }
        Ok(())
    }

    pub fn get(&self, id: NoticeId) -> Option<Notice> {
        saman::lock(&self.list)
            .items
            .iter()
            .find(|h| h.id == id)
            .map(|h| h.notice.clone())
    }

    pub fn len(&self) -> usize {
        saman::lock(&self.list).items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The list as rows, newest first: one row per notice, keyed by its id. Its text is what search, copy and the
    /// accessibility tree see: `level: title (×N): body`.
    pub fn rows(&self) -> Vec<Row> {
        let l = saman::lock(&self.list);
        l.items
            .iter()
            .rev()
            .map(|h| {
                let mut b = RowBuilder::new(format!("notice:{}", h.id.0));
                b.push(h.notice.level.name(), Some(h.notice.level.face()));
                b.push(": ", None);
                b.push(&h.notice.title, Some(rodd::faces::FaceId::Bold.name()));
                if h.count > 1 {
                    b.push(
                        &format!(" (\u{d7}{})", h.count),
                        Some(rodd::faces::FaceId::Shadow.name()),
                    );
                }
                if !h.notice.body.is_empty() {
                    b.push(": ", None);
                    b.push(&h.notice.body, None);
                }
                b.finish()
            })
            .collect()
    }
}
