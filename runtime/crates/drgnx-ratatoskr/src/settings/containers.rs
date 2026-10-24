//! The limits and the image allow-list of container jobs (Task 11b), read from the decoded runtime settings:
//! `agents-container-images` (`mod.rs` decodes it), `agents-job-memory` and `agents-job-cpus`.

use super::RuntimeValues;
use crate::exec::container::{Caps, PIDS};

/// The caps of a container job under VALUES.  The proxy network is the runner's to name.
pub fn caps(values: &RuntimeValues) -> Caps {
    Caps {
        images: values.agents_container_images.clone(),
        memory: values.agents_job_memory.clone(),
        cpus: values.agents_job_cpus,
        pids: PIDS,
        proxy_network: None,
    }
}
