//! The image set of one (view, class): the hub owns it. Each image is sent once; a reset carries every image its rows
//! name (the editor drops the rest), any other patch only those not sent since.

use crate::row::{ImageId, Row};
use std::collections::{BTreeMap, BTreeSet};

/// The width an SVG is drawn at, device px: its root's `width` (the editor makes the image at scale 1).
pub fn svg_width(svg: &str) -> Option<u32> {
    let root = &svg[svg.find("<svg")?..];
    let root = &root[..root.find('>')?];
    let at = root.find(" width=\"")? + " width=\"".len();
    let v = &root[at..];
    let v = &v[..v.find('"')?];
    v.trim_end_matches("px")
        .parse::<f32>()
        .ok()
        .map(|w| w.ceil() as u32)
}

/// The live images and which of them the editor holds.
#[derive(Debug, Default)]
pub struct ImageSet {
    live: BTreeMap<ImageId, String>,
    sent: BTreeSet<ImageId>,
}

impl ImageSet {
    /// SVG drawn at EPOCH, kept; its id (content hash and epoch).
    pub fn add(&mut self, svg: String, epoch: u64) -> ImageId {
        let id = ImageId::of(svg.as_bytes(), epoch);
        self.live.entry(id).or_insert(svg);
        id
    }

    /// Keep the image ID with SVG (an image a builder made already).
    pub fn put(&mut self, id: ImageId, svg: &str) {
        self.live.entry(id).or_insert_with(|| svg.to_owned());
    }

    /// The images a patch to ROWS carries: on a RESET every image the rows name, else those named and not sent.
    /// Images no row names are dropped.
    pub fn for_patch(&mut self, rows: &[Row], reset: bool) -> Vec<(ImageId, String)> {
        let named: BTreeSet<ImageId> = rows
            .iter()
            .flat_map(|r| r.images.iter().map(|i| i.1))
            .collect();
        self.live.retain(|id, _| named.contains(id));
        if reset {
            self.sent.clear();
        }
        self.sent.retain(|id| named.contains(id));
        let out: Vec<(ImageId, String)> = self
            .live
            .iter()
            .filter(|(id, _)| !self.sent.contains(id))
            .map(|(id, s)| (*id, s.clone()))
            .collect();
        self.sent.extend(out.iter().map(|i| i.0));
        out
    }

    /// The SVG of image ID, when it is live.
    pub fn svg(&self, id: &ImageId) -> Option<&str> {
        self.live.get(id).map(String::as_str)
    }

    pub fn len(&self) -> usize {
        self.live.len()
    }

    pub fn is_empty(&self) -> bool {
        self.live.is_empty()
    }
}
