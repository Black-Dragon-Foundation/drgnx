//! The project of a folder, asked of `norn` on a blocking thread of the clock.

use std::path::Path;

use norn::project;

/// The project of DIR (`norn::project::resolve`, on a blocking thread): `None` outside a repository; an error naming
/// git when git cannot answer, which a caller never reads as "no project".
pub async fn project_of(dir: &Path) -> villa::Result<Option<project::ProjectRef>> {
    let at = dir.to_path_buf();
    let named = |e: villa::Error| {
        villa::Error::new(e.kind(), format!("the project of {}: {e}", dir.display()))
    };
    crate::clock::blocking(move || project::resolve(&at))
        .await
        .map_err(named)?
        .map_err(named)
}
