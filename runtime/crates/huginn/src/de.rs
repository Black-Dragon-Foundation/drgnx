//! A serde deserializer over a `Node` (Task 3): a plist with keyword keys is a struct, an alist a map, a list a
//! sequence, `nil` the target's empty value, a dotted pair a 2-tuple.

use std::fmt;

use crate::span::Span;
use crate::value::Node;

/// A value that does not fit the target type, and where it is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    pub message: String,
    pub span: Span,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(
            f,
            "{} (bytes {}..{})",
            self.message, self.span.start, self.span.end
        )
    }
}

impl std::error::Error for Error {}

impl serde::de::Error for Error {
    fn custom<T: fmt::Display>(msg: T) -> Self {
        Error {
            message: msg.to_string(),
            span: Span::default(),
        }
    }
}

/// `node` as a `T`.
pub fn from_node<'de, T: serde::Deserialize<'de>>(node: &'de Node) -> Result<T, Error> {
    let _ = node;
    todo!("Task 3")
}
