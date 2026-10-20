//! What the binary is: `version` and `version --json`.  `DRGNX_BUILD_COMMIT` and `DRGNX_CHECKOUT` are embedded at
//! build time (build.rs; the commit is "unknown" when the builder does not say).

use serde_json::{Value, json};

/// The drgnx commit this binary was built from.
pub const COMMIT: &str = env!("DRGNX_BUILD_COMMIT");

/// The checkout it was built in (empty when the builder did not say).
pub const CHECKOUT: &str = env!("DRGNX_CHECKOUT");

/// The hub protocol version served.
pub const PROTO: u32 = 1;

/// The records format served (records 2: JSON objects).
pub const RECORDS: u32 = 2;

/// The linked SQLite as "3.53.0".
pub fn sqlite() -> String {
    let n = urdr::sqlite_version_number();
    format!("{}.{}.{}", n / 1_000_000, n / 1000 % 1000, n % 1000)
}

/// `version --json`.
pub fn json() -> Value {
    json!({
        "version": env!("CARGO_PKG_VERSION"),
        "commit": COMMIT,
        "proto": PROTO,
        "records": RECORDS,
        "sqlite": sqlite(),
        "test_hooks": cfg!(feature = "test-hooks"),
    })
}

/// `version`.
pub fn text() -> String {
    format!("ratatoskr {} ({COMMIT})", env!("CARGO_PKG_VERSION"))
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_json_has_every_key() {
        let v = super::json();
        for k in [
            "version",
            "commit",
            "proto",
            "records",
            "sqlite",
            "test_hooks",
        ] {
            assert!(v.get(k).is_some(), "{k} missing: {v}");
        }
        assert_eq!(v["proto"], 1);
        assert_eq!(v["records"], 2);
        assert!(v["sqlite"].as_str().unwrap().starts_with("3."), "{v}");
        assert_eq!(v["test_hooks"], cfg!(feature = "test-hooks"));
    }
}
