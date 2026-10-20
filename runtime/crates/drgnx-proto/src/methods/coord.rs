//! Coordination: what the coordination servers tell the hub.

use super::{Empty, method};
use crate::registry::Method;

pub(crate) fn methods() -> Vec<Method> {
    vec![method!(
        "coord/notify", CoordNotify(Empty) -> bool,
        classes: [User, Agent, Service], writes: false,
        doc: "a coordination server wrote: delivery runs now and the new events go out (a notification; users too, SB-T12-4)",
    )]
}
