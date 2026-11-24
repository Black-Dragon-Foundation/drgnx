//! A token on the wire: `#[serde(with = "crate::secret_text")]` and `#[schemars(with = "String")]` on a
//! `hulda::Secret<String>` field. It is sent and read as the plain string the protocol has, and everywhere else
//! (Debug, Display, a log field) it prints as hulda's redaction. The value leaves only through [`Secret::expose`].

use hulda::Secret;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

pub fn serialize<S: Serializer>(secret: &Secret<String>, s: S) -> Result<S::Ok, S::Error> {
    secret.expose().serialize(s)
}

pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Secret<String>, D::Error> {
    String::deserialize(d).map(Secret::new)
}
