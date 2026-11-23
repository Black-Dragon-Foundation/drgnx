//! Stage timestamps on long request paths (`history/fork`, the debugger tools): one debug line per finished stage under
//! the target `ratatoskr::stages`, with the real milliseconds since the request began, so the log of a slow or
//! stuck request names the stage it is in (the last line is the stage before it). Cheap: a disabled target is one
//! check per stage.

/// One request's stages: WHAT (the method or tool) and ID (its session, or what names the request in the log).
pub struct Stages {
    what: &'static str,
    id: String,
    t0: std::time::Instant,
}

impl Stages {
    pub fn new(what: &'static str, id: impl Into<String>) -> Stages {
        Stages {
            what,
            id: id.into(),
            t0: crate::clock::real_now(),
        }
    }

    /// STAGE is done.
    pub fn at(&self, stage: &'static str) {
        tracing::debug!(
            target: "ratatoskr::stages",
            what = self.what,
            id = %self.id,
            stage,
            ms = self.t0.elapsed().as_millis() as u64,
            "a stage done"
        );
    }
}
