//! The coverage check: every listed class has chunks, and so has every non-empty file.

use crate::files::{Class, Listed};
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CoverageError {
    /// Files of this class are listed, and none of them has a chunk.
    ClassWithNoChunks(Class),
    /// A non-empty file has no chunk.
    FileWithoutChunks(String),
}

/// What is wrong with the chunks of `listed`: `chunks_per_file` maps a path to its chunk count.
pub fn coverage(listed: &[Listed], chunks_per_file: &HashMap<String, u32>) -> Vec<CoverageError> {
    let n = |l: &Listed| chunks_per_file.get(&l.path).copied().unwrap_or(0);
    let mut errors = Vec::new();
    for class in [Class::Code, Class::Test, Class::Docs] {
        let mut files = listed.iter().filter(|l| l.class == class).peekable();
        if files.peek().is_some() && files.all(|l| n(l) == 0) {
            errors.push(CoverageError::ClassWithNoChunks(class));
        }
    }
    for l in listed {
        if l.size > 0 && n(l) == 0 {
            errors.push(CoverageError::FileWithoutChunks(l.path.clone()));
        }
    }
    errors
}
