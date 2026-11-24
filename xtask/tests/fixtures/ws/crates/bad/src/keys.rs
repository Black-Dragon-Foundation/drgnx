use skel::event::{Event, KeyEv};

pub fn raw(_k: KeyEv) {}

pub fn by_pattern(e: Event) {
    match e {
        Event::Key(_k) => {}
        _ => {}
    }
}
