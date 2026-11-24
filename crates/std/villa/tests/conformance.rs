//! The errors standard (docs/develop/standards/errors.md): one error type, its kinds, the user's sentence.

use std::error::Error as _;
use std::io;

use villa::{Error, Kind};

#[test]
fn io_not_found_maps_to_not_found() {
    let e = Error::from(io::Error::from(io::ErrorKind::NotFound));
    assert_eq!(e.kind(), Kind::NotFound);
    assert!(e.source().is_some(), "the io error stays as the source");
}

#[test]
fn io_permission_maps_to_refused() {
    assert_eq!(
        Error::from(io::Error::from(io::ErrorKind::PermissionDenied)).kind(),
        Kind::Refused
    );
    assert_eq!(
        Error::from(io::Error::from(io::ErrorKind::TimedOut)).kind(),
        Kind::Timeout
    );
    assert_eq!(
        Error::from(io::Error::from(io::ErrorKind::BrokenPipe)).kind(),
        Kind::Io
    );
}

#[test]
fn error_display_is_the_user_sentence() {
    let e = Error::conflict("The file changed on disk since you opened it.")
        .with_detail("mtime 12 != 11")
        .with_source(io::Error::other("inner cause"));
    assert_eq!(
        e.to_string(),
        "The file changed on disk since you opened it."
    );
    let debug = format!("{e:?}");
    for part in [
        "Conflict",
        "The file changed on disk",
        "mtime 12 != 11",
        "inner cause",
    ] {
        assert!(debug.contains(part), "{debug} lacks {part}");
    }
    assert_eq!(e.detail(), Some("mtime 12 != 11"));
    assert_eq!(e.message(), "The file changed on disk since you opened it.");
}

#[test]
fn errors_are_equal_when_kind_sentence_and_detail_are_and_the_source_is_not_compared() {
    let a = Error::invalid("bad").with_detail("d");
    assert_eq!(a, Error::invalid("bad").with_detail("d"));
    assert_eq!(
        a,
        Error::invalid("bad")
            .with_detail("d")
            .with_source(io::Error::other("x"))
    );
    assert_ne!(a, Error::invalid("bad"));
    assert_ne!(a, Error::refused("bad").with_detail("d"));
    assert_ne!(a, Error::invalid("worse").with_detail("d"));
}

#[test]
fn every_kind_has_its_constructor_and_wire_name() {
    let cases = [
        (Error::not_found("m"), "not-found"),
        (Error::conflict("m"), "conflict"),
        (Error::unavailable("m"), "unavailable"),
        (Error::refused("m"), "refused"),
        (Error::io("m"), "io"),
        (Error::timeout("m"), "timeout"),
        (Error::invalid("m"), "invalid"),
        (Error::cancelled("m"), "cancelled"),
        (Error::internal("m"), "internal"),
    ];
    for (e, wire) in cases {
        assert_eq!(e.kind().wire(), wire);
        assert_eq!(Kind::from_wire(wire), Some(e.kind()));
    }
    assert_eq!(Kind::from_wire("nope"), None);
}

#[test]
fn result_alias_carries_the_error() {
    fn f() -> villa::Result<u8> {
        Err(Error::invalid("A width must be a number."))
    }
    assert_eq!(f().map_err(|e| e.kind()), Err(Kind::Invalid));
}
