//! The wire errors the hub's handlers build: a code, a message and, for a bad parameter, the path to it.

use runstav::wire::{Error, ErrorCode};

/// `invalid-params` for the parameter at PATH.
pub fn invalid_at(path: &str, message: impl ToString) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.to_string(),
        path: Some(path.into()),
    }
}

/// `invalid-params` with no path.
pub fn invalid(message: impl ToString) -> Error {
    Error {
        code: ErrorCode::InvalidParams,
        message: message.to_string(),
        path: None,
    }
}

/// `internal`.
pub fn internal(message: impl ToString) -> Error {
    Error {
        code: ErrorCode::Internal,
        message: message.to_string(),
        path: None,
    }
}

/// `not-allowed`.
pub fn refuse(message: &str) -> Error {
    Error {
        code: ErrorCode::NotAllowed,
        message: message.into(),
        path: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_helper_builds_its_code_and_path() {
        assert_eq!(invalid_at("a/b", "x").path.as_deref(), Some("a/b"));
        assert_eq!(invalid("x").code, ErrorCode::InvalidParams);
        assert!(invalid("x").path.is_none());
        assert_eq!(internal("x").code, ErrorCode::Internal);
        assert_eq!(refuse("x").code, ErrorCode::NotAllowed);
    }
}
