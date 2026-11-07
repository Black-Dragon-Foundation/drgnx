//! One row of a view.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// An image's id: its content hash and the env epoch it was drawn for, so a theme change (a new epoch) never reuses
/// an old tile. On the wire it is one string, `HASH-EPOCH` (hex, then decimal).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ImageId {
    pub hash: u64,
    pub epoch: u64,
}

impl ImageId {
    /// The id of an image with CONTENT drawn at EPOCH (FNV-1a over the bytes: stable across runs and builds).
    pub fn of(content: &[u8], epoch: u64) -> Self {
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for b in content {
            h ^= u64::from(*b);
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
        ImageId { hash: h, epoch }
    }
}

impl Serialize for ImageId {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&format!("{:016x}-{}", self.hash, self.epoch))
    }
}

impl<'de> Deserialize<'de> for ImageId {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        let bad = || serde::de::Error::custom(format!("not an image id: {s:?}"));
        let (h, e) = s.split_once('-').ok_or_else(bad)?;
        Ok(ImageId {
            hash: u64::from_str_radix(h, 16).map_err(|_| bad())?,
            epoch: e.parse().map_err(|_| bad())?,
        })
    }
}

/// A row's height: LINES lines of UNIT px each (Lisp turns it into `line-height` from its own font metrics).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct RowHeight {
    pub lines: u32,
    pub unit: u32,
}

/// One row: its key (unique in the view), its text and what lies on it. Every position is a scalar index into
/// `text`; ranges are `[start, end)`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct Row {
    pub key: String,
    pub text: String,
    /// `[start, end, face]`: a registered drgnx face name (Lisp drops one it doesn't know, never interns it).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub runs: Vec<(u32, u32, String)>,
    /// `[start, end, name, value]`: a text property, such as `drgnx-work-id`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub props: Vec<(u32, u32, String, Value)>,
    /// `[pos, px]`: the text at POS is aligned to PX (`(space :align-to (PX))`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub stops: Vec<(u32, u32)>,
    /// `[pos, id, alt]`: the image ID is shown at POS (ALT on a terminal).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<(u32, ImageId, String)>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<RowHeight>,
}

#[cfg(feature = "schema")]
impl schemars::JsonSchema for ImageId {
    fn schema_name() -> std::borrow::Cow<'static, str> {
        "ImageId".into()
    }

    fn json_schema(_: &mut schemars::SchemaGenerator) -> schemars::Schema {
        schemars::json_schema!({"type": "string", "pattern": "^[0-9a-f]{16}-[0-9]+$",
                                "description": "an image's content hash and env epoch"})
    }
}
