//! One line of the protocol: the length limits, the codec that enforces the client's, and the strict parse.

use crate::wire::Id;
use serde::de::{self, DeserializeSeed, MapAccess, SeqAccess, Visitor};
use serde_json::{Map, Value};
use std::cell::RefCell;
use std::fmt;

/// The longest line a client may send (bytes, without its newline); a longer one closes the connection.
pub const MAX_CLIENT_LINE: usize = 1 << 20;

/// The longest line the hub sends to a client.
pub const MAX_HUB_LINE: usize = 16 << 20;

/// The deepest nesting of objects and arrays a line may have (the top object is depth 1).
pub const MAX_DEPTH: usize = 64;

/// The codec for a client's lines: a line over [`MAX_CLIENT_LINE`] is an error (the connection is then closed).
pub fn codec() -> tokio_util::codec::LinesCodec {
    tokio_util::codec::LinesCodec::new_with_max_length(MAX_CLIENT_LINE)
}

/// A line that is not a request object.  `id` is read leniently from it when it can be, so its sender gets an
/// answer instead of waiting; `path` says where in the line it went wrong, when that is known.
#[derive(Clone, Debug, PartialEq)]
pub struct LineError {
    pub id: Option<Id>,
    pub message: String,
    pub path: Option<String>,
}

/// The line as a JSON object, refusing a duplicate key at any depth, a nesting deeper than [`MAX_DEPTH`] and
/// anything but an object at the top.
pub fn parse_strict(line: &str) -> Result<Value, LineError> {
    let path = RefCell::new(Vec::new());
    let mut de = serde_json::Deserializer::from_str(line);
    let parsed = Strict {
        depth: 0,
        path: &path,
    }
    .deserialize(&mut de)
    .and_then(|v| de.end().map(|()| v));
    let message = match parsed {
        Ok(v) if v.is_object() => return Ok(v),
        Ok(_) => "not a JSON object".to_string(),
        Err(e) => e.to_string(),
    };
    let path = path.into_inner();
    Err(LineError {
        id: lenient_id(line),
        message,
        path: (!path.is_empty()).then(|| render(&path)),
    })
}

/// One step of a path into a line.
enum Seg {
    Key(String),
    Index(usize),
}

/// `params.env[0].x`: the form `decode` uses for its paths too.
fn render(path: &[Seg]) -> String {
    let mut s = String::new();
    for seg in path {
        match seg {
            Seg::Key(k) => {
                if !s.is_empty() {
                    s.push('.');
                }
                s.push_str(k);
            }
            Seg::Index(i) => s.push_str(&format!("[{i}]")),
        }
    }
    s
}

/// A JSON value, refusing a duplicate key and a container deeper than [`MAX_DEPTH`].  `path` is where the parse
/// is; it is left where a refusal happened.
struct Strict<'p> {
    depth: usize,
    path: &'p RefCell<Vec<Seg>>,
}

impl Strict<'_> {
    fn enter<E: de::Error>(&self) -> Result<usize, E> {
        let depth = self.depth + 1;
        if depth > MAX_DEPTH {
            return Err(E::custom(format!("nested deeper than {MAX_DEPTH}")));
        }
        Ok(depth)
    }
}

impl<'de> DeserializeSeed<'de> for Strict<'_> {
    type Value = Value;

    fn deserialize<D: de::Deserializer<'de>>(self, d: D) -> Result<Value, D::Error> {
        d.deserialize_any(self)
    }
}

impl<'de> Visitor<'de> for Strict<'_> {
    type Value = Value;

    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("a JSON value")
    }

    fn visit_bool<E>(self, b: bool) -> Result<Value, E> {
        Ok(Value::Bool(b))
    }

    fn visit_i64<E>(self, n: i64) -> Result<Value, E> {
        Ok(Value::from(n))
    }

    fn visit_u64<E>(self, n: u64) -> Result<Value, E> {
        Ok(Value::from(n))
    }

    fn visit_f64<E>(self, n: f64) -> Result<Value, E> {
        Ok(Value::from(n)) // as serde_json's own Value: a non-finite number is null
    }

    fn visit_str<E>(self, s: &str) -> Result<Value, E> {
        Ok(Value::String(s.to_owned()))
    }

    fn visit_string<E>(self, s: String) -> Result<Value, E> {
        Ok(Value::String(s))
    }

    fn visit_unit<E>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }

    fn visit_none<E>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }

    fn visit_some<D: de::Deserializer<'de>>(self, d: D) -> Result<Value, D::Error> {
        self.deserialize(d)
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Value, A::Error> {
        let depth = self.enter()?;
        let mut out = Vec::new();
        loop {
            self.path.borrow_mut().push(Seg::Index(out.len()));
            let next = seq.next_element_seed(Strict {
                depth,
                path: self.path,
            })?;
            self.path.borrow_mut().pop();
            match next {
                Some(v) => out.push(v),
                None => return Ok(Value::Array(out)),
            }
        }
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Value, A::Error> {
        let depth = self.enter()?;
        let mut out = Map::new();
        while let Some(key) = map.next_key::<String>()? {
            if out.contains_key(&key) {
                let message = format!("duplicate key {key:?}");
                self.path.borrow_mut().push(Seg::Key(key));
                return Err(de::Error::custom(message));
            }
            self.path.borrow_mut().push(Seg::Key(key));
            let v = map.next_value_seed(Strict {
                depth,
                path: self.path,
            })?;
            let Some(Seg::Key(key)) = self.path.borrow_mut().pop() else {
                unreachable!("the key was pushed above")
            };
            out.insert(key, v);
        }
        Ok(Value::Object(out))
    }
}

/// The id of a line that is not a request object, when one can be read: its top-level `id` when the line is JSON
/// (duplicates and depth allowed), else the Lisp hub's rule (`drgnx-hub--malformed`): the first `"id"`, blanks,
/// `:`, blanks, a number, blanks and `,` or `}`.
fn lenient_id(line: &str) -> Option<Id> {
    if let Ok(Value::Object(o)) = serde_json::from_str::<Value>(line) {
        return o
            .get("id")
            .and_then(|v| serde_json::from_value(v.clone()).ok());
    }
    let b = line.as_bytes();
    let blanks = |mut i: usize| {
        while matches!(b.get(i), Some(b' ' | b'\t')) {
            i += 1;
        }
        i
    };
    let mut from = 0;
    while let Some(at) = line[from..].find("\"id\"") {
        let start = from + at;
        from = start + 1;
        let mut i = blanks(start + 4);
        if b.get(i) != Some(&b':') {
            continue;
        }
        i = blanks(i + 1);
        let negative = b.get(i) == Some(&b'-');
        if negative {
            i += 1;
        }
        let digits = i;
        while b.get(i).is_some_and(u8::is_ascii_digit) {
            i += 1;
        }
        if i == digits || !matches!(b.get(blanks(i)), Some(b',' | b'}')) {
            continue;
        }
        // the first match is the id; a negative or too large one cannot be answered as one
        return match negative {
            true => None,
            false => line[digits..i].parse().ok().map(Id::Num),
        };
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn nested(depth: usize) -> String {
        // depth objects: the top one and depth-1 under it, each under "a"
        let mut s = String::new();
        for _ in 1..depth {
            s.push_str("{\"a\":");
        }
        s.push_str("{\"id\":7}");
        for _ in 1..depth {
            s.push('}');
        }
        s
    }

    #[test]
    fn duplicate_keys_refused_at_any_depth() {
        let e = parse_strict(r#"{"id":1,"method":"x","id":2}"#).unwrap_err();
        assert!(e.message.contains("duplicate key"), "{e:?}");
        assert_eq!(e.path.as_deref(), Some("id"));
        let e = parse_strict(r#"{"id":5,"method":"x","params":{"env":[{"k":1},{"k":2,"k":3}]}}"#)
            .unwrap_err();
        assert!(e.message.contains("duplicate key"), "{e:?}");
        assert_eq!(e.path.as_deref(), Some("params.env[1].k"));
        assert_eq!(e.id, Some(Id::Num(5)));
        // the same key in sibling objects is no duplicate
        assert!(parse_strict(r#"{"a":{"k":1},"b":{"k":2},"c":[{"k":1},{"k":1}]}"#).is_ok());
    }

    #[test]
    fn id_read_from_a_malformed_line() {
        let e = parse_strict(r#"{"id": 42, "method": "ping", "params": {"#).unwrap_err();
        assert_eq!(e.id, Some(Id::Num(42)));
        let e = parse_strict(r#"{"id":"s-1","method":"x","params":{"a":1,"a":2}}"#).unwrap_err();
        assert_eq!(e.id, Some(Id::Str("s-1".into())));
        // a negative id cannot be answered as one; garbage has none
        assert_eq!(parse_strict(r#"{"id": -3, oops"#).unwrap_err().id, None);
        assert_eq!(parse_strict("not json at all").unwrap_err().id, None);
        assert_eq!(parse_strict(r#"{"idx": 4, oops"#).unwrap_err().id, None);
        // not an object at the top
        let e = parse_strict("[1,2]").unwrap_err();
        assert_eq!(e.id, None);
        assert!(parse_strict("7").is_err());
        assert!(parse_strict(r#""s""#).is_err());
        // a good line
        assert_eq!(
            parse_strict(r#"{"id":1,"method":"ping"}"#).unwrap(),
            json!({"id": 1, "method": "ping"})
        );
    }

    #[test]
    fn depth_65_refused() {
        assert!(parse_strict(&nested(64)).is_ok());
        let e = parse_strict(&nested(65)).unwrap_err();
        assert!(e.message.contains("deeper than 64"), "{e:?}");
        // arrays count too
        let arrays = format!("{{\"a\":{}1{}}}", "[".repeat(64), "]".repeat(64));
        assert!(parse_strict(&arrays).is_err());
        let arrays = format!("{{\"a\":{}1{}}}", "[".repeat(63), "]".repeat(63));
        assert!(parse_strict(&arrays).is_ok());
        // a very deep line is refused, not a stack overflow
        let deep = format!("{{\"a\":{}{}}}", "[".repeat(100_000), "]".repeat(100_000));
        assert!(parse_strict(&deep).is_err());
    }

    #[test]
    fn the_codec_limits_a_client_line() {
        use tokio_util::codec::Decoder;
        let mut c = codec();
        let mut buf = Default::default();
        assert_eq!(c.decode(&mut buf).unwrap(), None);
        buf.extend_from_slice(&vec![b'a'; MAX_CLIENT_LINE]);
        buf.extend_from_slice(b"\n");
        assert_eq!(
            c.decode(&mut buf).unwrap().map(|l| l.len()),
            Some(MAX_CLIENT_LINE)
        );
        buf.extend_from_slice(&vec![b'a'; MAX_CLIENT_LINE + 1]);
        assert!(c.decode(&mut buf).is_err());
    }
}
