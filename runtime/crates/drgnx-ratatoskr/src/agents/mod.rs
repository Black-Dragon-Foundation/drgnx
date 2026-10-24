//! Sessions in the hub (agent system part 1; V2 runtime phase 5; `docs/develop/hub.md`, "Sessions"): the hub is
//! every session's ACP client (`hermod`), answers its permissions through the matrix, delivers its messages, and
//! launches it inside Gleipnir with its provider's lock.
//!
//! - [`session`]: lifecycle, permissions, the mirror's shapes (Task 8a); prompts, queue and steer, transcripts,
//!   steps (Task 8b); moving to another model (Task 26).
//! - [`deliver`]: delivery and take-back (`messages/retract`) (Task 24).
//! - [`lock`]: a provider's launch options that make its CLI obey the hub (Task 9).
//! - [`launch`]: the session's Gleipnir spec (Task 10).

pub mod deliver;
pub mod launch;
pub mod lock;
pub mod session;

/// The sessions the hub holds (Tasks 8a, 8b fill it).
#[derive(Default)]
pub struct Hub {}
