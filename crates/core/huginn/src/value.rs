//! The data a file holds, each with its span in the source (Task 1).

use crate::span::Span;

/// One datum, as Emacs's `read` gives it. A character literal is its integer; `nil` and `t` are symbols; a keyword
/// keeps its colon; `'X` is `(quote X)` and `#'F` is `(function F)`.
#[derive(Debug, Clone, PartialEq)]
pub enum Datum {
    Int(i64),
    Float(f64),
    Str(String),
    Sym(String),
    /// A proper list (`nil` is `Sym("nil")`, never an empty `List`).
    List(Vec<Node>),
    /// A dotted list: the elements before the dot, and the tail.
    Cons(Vec<Node>, Box<Node>),
    Vec(Vec<Node>),
}

/// A datum and where it was read.
#[derive(Debug, Clone, PartialEq)]
pub struct Node {
    pub datum: Datum,
    pub span: Span,
}
