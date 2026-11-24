//! villa (*villa*, error, going astray): the one error type (docs/develop/standards/errors.md).
//!
//! An [`Error`] has a [`Kind`] (what a caller branches on, and the wire name a client sees), a message (the sentence
//! the user reads: `Display` prints only that), an optional detail (for a log or a bug report) and an optional source
//! (the error underneath). `Debug` prints all four. Every public function that can fail returns [`Result`].

use std::fmt;

/// What went wrong, as a caller branches on it. The wire names (`not-found`, …) are W2's seven kinds plus `invalid`
/// and `cancelled`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    /// What was asked for does not exist.
    NotFound,
    /// The state changed under the request (an edit against a newer version, a name already taken).
    Conflict,
    /// Something needed is not there now (a service down, a device gone); trying later may work.
    Unavailable,
    /// Not allowed: permissions, a policy, the user said no.
    Refused,
    /// An input or output failed.
    Io,
    /// A deadline passed.
    Timeout,
    /// The request itself is wrong (a bad argument, a malformed file).
    Invalid,
    /// Cancelled before it finished.
    Cancelled,
    /// A bug: what should not happen did.
    Internal,
}

const KINDS: [(Kind, &str); 9] = [
    (Kind::NotFound, "not-found"),
    (Kind::Conflict, "conflict"),
    (Kind::Unavailable, "unavailable"),
    (Kind::Refused, "refused"),
    (Kind::Io, "io"),
    (Kind::Timeout, "timeout"),
    (Kind::Invalid, "invalid"),
    (Kind::Cancelled, "cancelled"),
    (Kind::Internal, "internal"),
];

impl Kind {
    /// The kind's name on the wire (`not-found`, `conflict`, …).
    pub fn wire(self) -> &'static str {
        KINDS
            .iter()
            .find(|(k, _)| *k == self)
            .map_or("internal", |(_, w)| w)
    }

    /// The kind a wire name names, if any.
    pub fn from_wire(name: &str) -> Option<Kind> {
        KINDS.iter().find(|(_, w)| *w == name).map(|(k, _)| *k)
    }
}

impl fmt::Display for Kind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.wire())
    }
}

type Source = Box<dyn std::error::Error + Send + Sync + 'static>;

/// The one error type: a kind, the user's sentence, a detail, a source.
pub struct Error {
    kind: Kind,
    message: String,
    detail: Option<String>,
    source: Option<Source>,
}

/// `Result<T, villa::Error>`.
pub type Result<T> = std::result::Result<T, Error>;

macro_rules! constructors {
    ($($(#[$doc:meta])* $name:ident => $kind:ident),* $(,)?) => {$(
        $(#[$doc])*
        pub fn $name(message: impl Into<String>) -> Error {
            Error::new(Kind::$kind, message)
        }
    )*};
}

impl Error {
    /// An error of KIND whose user-facing sentence is MESSAGE.
    pub fn new(kind: Kind, message: impl Into<String>) -> Error {
        Error {
            kind,
            message: message.into(),
            detail: None,
            source: None,
        }
    }

    constructors! {
        /// [`Kind::NotFound`].
        not_found => NotFound,
        /// [`Kind::Conflict`].
        conflict => Conflict,
        /// [`Kind::Unavailable`].
        unavailable => Unavailable,
        /// [`Kind::Refused`].
        refused => Refused,
        /// [`Kind::Io`].
        io => Io,
        /// [`Kind::Timeout`].
        timeout => Timeout,
        /// [`Kind::Invalid`].
        invalid => Invalid,
        /// [`Kind::Cancelled`].
        cancelled => Cancelled,
        /// [`Kind::Internal`].
        internal => Internal,
    }

    /// This error with DETAIL: what a log or a bug report needs and the user does not.
    pub fn with_detail(mut self, detail: impl Into<String>) -> Error {
        self.detail = Some(detail.into());
        self
    }

    /// This error with SOURCE underneath it.
    pub fn with_source(mut self, source: impl std::error::Error + Send + Sync + 'static) -> Error {
        self.source = Some(Box::new(source));
        self
    }

    pub fn kind(&self) -> Kind {
        self.kind
    }

    /// The sentence the user reads.
    pub fn message(&self) -> &str {
        &self.message
    }

    pub fn detail(&self) -> Option<&str> {
        self.detail.as_deref()
    }
}

impl PartialEq for Error {
    /// Two errors are equal when they say the same: the kind, the sentence and the detail. The source is not compared
    /// (an `io::Error` has no equality); this is for a test that asserts what a function answered.
    fn eq(&self, other: &Error) -> bool {
        self.kind == other.kind && self.message == other.message && self.detail == other.detail
    }
}

impl Eq for Error {}

impl fmt::Display for Error {
    /// Only the user's sentence.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl fmt::Debug for Error {
    /// Everything: the kind, the sentence, the detail and the source's own `Debug`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Error")
            .field("kind", &self.kind)
            .field("message", &self.message)
            .field("detail", &self.detail)
            .field("source", &self.source)
            .finish()
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        self.source
            .as_deref()
            .map(|s| s as &(dyn std::error::Error + 'static))
    }
}

impl From<std::io::Error> for Error {
    /// `NotFound` → [`Kind::NotFound`], `PermissionDenied` → [`Kind::Refused`], `TimedOut` → [`Kind::Timeout`], else
    /// [`Kind::Io`]; the io error is the source, its text the message.
    fn from(e: std::io::Error) -> Error {
        let kind = match e.kind() {
            std::io::ErrorKind::NotFound => Kind::NotFound,
            std::io::ErrorKind::PermissionDenied => Kind::Refused,
            std::io::ErrorKind::TimedOut => Kind::Timeout,
            _ => Kind::Io,
        };
        Error::new(kind, e.to_string()).with_source(e)
    }
}
