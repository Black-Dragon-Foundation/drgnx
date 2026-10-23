//! A serde deserializer over a `Node` (Task 3): a plist with keyword keys is a struct, an alist a map, a list a
//! sequence, `nil` the target's empty value, a dotted pair a 2-tuple.
//!
//! Strings and symbols both read as strings; integers as `i64`; `t` and `nil` as `true` and `false`. A struct key
//! `:on-error` is the field `on_error`. For `deserialize_any` (self-describing targets such as `serde_json::Value`)
//! `nil` is a unit, `t` is `true`, a list whose even elements are keywords is a map, any other list a sequence.
//! An enum is a symbol or string (a unit variant) or `(VARIANT …)`, whose rest is the variant's value.

use std::fmt;

use serde::de::value::{BorrowedStrDeserializer, StringDeserializer};
use serde::de::{DeserializeSeed, EnumAccess, MapAccess, SeqAccess, VariantAccess, Visitor};

use crate::span::Span;
use crate::value::{Datum, Node};

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
    T::deserialize(Deserializer::new(node))
}

/// What is being deserialized: a node, or the rest of a list after its first element(s) (an alist pair's value, a
/// variant's payload).
#[derive(Clone, Copy)]
enum Val<'de> {
    Node(&'de Node),
    Tail(&'de [Node], Span),
}

fn tail<'de>(items: &'de [Node], whole: Span) -> Val<'de> {
    let span = match (items.first(), items.last()) {
        (Some(first), Some(last)) => Span {
            start: first.span.start,
            end: last.span.end,
        },
        _ => whole,
    };
    Val::Tail(items, span)
}

fn is_nil(node: &Node) -> bool {
    matches!(&node.datum, Datum::Sym(s) if s == "nil")
}

fn error(span: Span, message: impl Into<String>) -> Error {
    Error {
        message: message.into(),
        span,
    }
}

/// `e` with `span` when it has none yet (the innermost span wins).
fn spanned(mut e: Error, span: Span) -> Error {
    if e.span == Span::default() {
        e.span = span;
    }
    e
}

fn is_keyword(name: &str) -> bool {
    name.len() > 1 && name.starts_with(':')
}

fn is_plist(items: &[Node]) -> bool {
    !items.is_empty()
        && items.len().is_multiple_of(2)
        && items
            .iter()
            .step_by(2)
            .all(|k| matches!(&k.datum, Datum::Sym(s) if is_keyword(s)))
}

impl<'de> Val<'de> {
    fn span(self) -> Span {
        match self {
            Val::Node(n) => n.span,
            Val::Tail(_, span) => span,
        }
    }

    fn is_nil(self) -> bool {
        match self {
            Val::Node(n) => is_nil(n),
            Val::Tail(items, _) => items.is_empty(),
        }
    }

    /// The elements of a proper list (`nil` is empty).
    fn list(self) -> Option<&'de [Node]> {
        match self {
            Val::Node(n) => match &n.datum {
                Datum::List(items) => Some(items),
                Datum::Sym(s) if s == "nil" => Some(&[]),
                _ => None,
            },
            Val::Tail(items, _) => Some(items),
        }
    }

    /// The elements of a list, `nil` or vector; a dotted list too (its tail last) when `dotted`.
    fn items(self, dotted: bool) -> Result<Vec<&'de Node>, Error> {
        match self {
            Val::Node(n) => match &n.datum {
                Datum::Vec(items) => Ok(items.iter().collect()),
                Datum::Cons(items, last) if dotted => {
                    Ok(items.iter().chain(std::iter::once(last.as_ref())).collect())
                }
                _ => self
                    .list()
                    .map(|items| items.iter().collect())
                    .ok_or_else(|| error(n.span, "expected a list")),
            },
            Val::Tail(items, _) => Ok(items.iter().collect()),
        }
    }
}

/// The deserializer over one node.
pub struct Deserializer<'de>(Val<'de>);

impl<'de> Deserializer<'de> {
    pub fn new(node: &'de Node) -> Self {
        Deserializer(Val::Node(node))
    }

    fn at<T>(&self, result: Result<T, Error>) -> Result<T, Error> {
        result.map_err(|e| spanned(e, self.0.span()))
    }

    fn expected(&self, what: &str) -> Error {
        error(self.0.span(), format!("expected {what}"))
    }

    fn any<V: Visitor<'de>>(&self, v: V) -> Result<V::Value, Error> {
        let items = match self.0 {
            Val::Node(n) => match &n.datum {
                Datum::Int(i) => return v.visit_i64(*i),
                Datum::Float(f) => return v.visit_f64(*f),
                Datum::Str(s) => return v.visit_borrowed_str(s),
                Datum::Sym(s) => {
                    return match s.as_str() {
                        "nil" => v.visit_unit(),
                        "t" => v.visit_bool(true),
                        _ => v.visit_borrowed_str(s),
                    };
                }
                Datum::List(items) => items.as_slice(),
                Datum::Cons(..) | Datum::Vec(_) => {
                    return v.visit_seq(SeqDe::new(self.0.items(true)?));
                }
            },
            Val::Tail([], _) => return v.visit_unit(),
            Val::Tail(items, _) => items,
        };
        if is_plist(items) {
            v.visit_map(PlistMap::new(items)?)
        } else {
            v.visit_seq(SeqDe::new(items.iter().collect()))
        }
    }

    fn int<V: Visitor<'de>>(&self, v: V) -> Result<V::Value, Error> {
        match self.0 {
            Val::Node(Node {
                datum: Datum::Int(i),
                ..
            }) => v.visit_i64(*i),
            _ => Err(self.expected("an integer")),
        }
    }

    fn float<V: Visitor<'de>>(&self, v: V) -> Result<V::Value, Error> {
        match self.0 {
            Val::Node(Node {
                datum: Datum::Float(f),
                ..
            }) => v.visit_f64(*f),
            Val::Node(Node {
                datum: Datum::Int(i),
                ..
            }) => v.visit_i64(*i),
            _ => Err(self.expected("a number")),
        }
    }

    fn text<V: Visitor<'de>>(&self, v: V) -> Result<V::Value, Error> {
        match self.0 {
            Val::Node(Node {
                datum: Datum::Str(s) | Datum::Sym(s),
                ..
            }) => v.visit_borrowed_str(s),
            _ => Err(self.expected("a string or symbol")),
        }
    }

    fn sequence<V: Visitor<'de>>(
        &self,
        v: V,
        dotted: bool,
        len: Option<usize>,
    ) -> Result<V::Value, Error> {
        let items = self.0.items(dotted)?;
        if let Some(len) = len
            && items.len() != len
        {
            return Err(self.expected(&format!("{len} elements, found {}", items.len())));
        }
        v.visit_seq(SeqDe::new(items))
    }

    fn plist<V: Visitor<'de>>(&self, v: V) -> Result<V::Value, Error> {
        let items = self
            .0
            .list()
            .ok_or_else(|| self.expected("a plist (:key value …)"))?;
        v.visit_map(PlistMap::new(items)?)
    }

    fn alist<V: Visitor<'de>>(&self, v: V) -> Result<V::Value, Error> {
        let items = self
            .0
            .list()
            .ok_or_else(|| self.expected("an alist ((KEY . VALUE) …)"))?;
        v.visit_map(AlistMap {
            entries: items.iter(),
            value: None,
        })
    }

    fn variant<V: Visitor<'de>>(&self, v: V) -> Result<V::Value, Error> {
        let (name, rest, span) = match self.0 {
            Val::Node(n) => match &n.datum {
                Datum::Sym(s) | Datum::Str(s) => (s.as_str(), &[][..], n.span),
                Datum::List(items) => match items.split_first() {
                    Some((
                        Node {
                            datum: Datum::Sym(s) | Datum::Str(s),
                            ..
                        },
                        rest,
                    )) => (s.as_str(), rest, n.span),
                    _ => return Err(self.expected("(VARIANT …)")),
                },
                _ => return Err(self.expected("a variant name or (VARIANT …)")),
            },
            Val::Tail(..) => return Err(self.expected("a variant name or (VARIANT …)")),
        };
        v.visit_enum(EnumDe { name, rest, span })
    }
}

macro_rules! via {
    ($($method:ident => $helper:ident),* $(,)?) => {$(
        fn $method<V: Visitor<'de>>(self, v: V) -> Result<V::Value, Error> {
            let r = self.$helper(v);
            self.at(r)
        }
    )*};
}

impl<'de> serde::Deserializer<'de> for Deserializer<'de> {
    type Error = Error;

    via! {
        deserialize_any => any,
        deserialize_i8 => int, deserialize_i16 => int, deserialize_i32 => int, deserialize_i64 => int,
        deserialize_u8 => int, deserialize_u16 => int, deserialize_u32 => int, deserialize_u64 => int,
        deserialize_f32 => float, deserialize_f64 => float,
        deserialize_char => text, deserialize_str => text, deserialize_string => text,
        deserialize_identifier => text,
        deserialize_map => alist,
    }

    fn deserialize_bool<V: Visitor<'de>>(self, v: V) -> Result<V::Value, Error> {
        let r = match self.0 {
            Val::Node(Node {
                datum: Datum::Sym(s),
                ..
            }) if s == "t" => v.visit_bool(true),
            _ if self.0.is_nil() => v.visit_bool(false),
            _ => Err(self.expected("t or nil")),
        };
        self.at(r)
    }

    fn deserialize_bytes<V: Visitor<'de>>(self, v: V) -> Result<V::Value, Error> {
        self.deserialize_seq(v)
    }

    fn deserialize_byte_buf<V: Visitor<'de>>(self, v: V) -> Result<V::Value, Error> {
        self.deserialize_seq(v)
    }

    fn deserialize_option<V: Visitor<'de>>(self, v: V) -> Result<V::Value, Error> {
        let r = if self.0.is_nil() {
            v.visit_none()
        } else {
            v.visit_some(Deserializer(self.0))
        };
        self.at(r)
    }

    fn deserialize_unit<V: Visitor<'de>>(self, v: V) -> Result<V::Value, Error> {
        let r = if self.0.is_nil() {
            v.visit_unit()
        } else {
            Err(self.expected("nil"))
        };
        self.at(r)
    }

    fn deserialize_unit_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        v: V,
    ) -> Result<V::Value, Error> {
        self.deserialize_unit(v)
    }

    fn deserialize_newtype_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        v: V,
    ) -> Result<V::Value, Error> {
        let r = v.visit_newtype_struct(Deserializer(self.0));
        self.at(r)
    }

    fn deserialize_seq<V: Visitor<'de>>(self, v: V) -> Result<V::Value, Error> {
        let r = self.sequence(v, false, None);
        self.at(r)
    }

    fn deserialize_tuple<V: Visitor<'de>>(self, len: usize, v: V) -> Result<V::Value, Error> {
        let r = self.sequence(v, true, Some(len));
        self.at(r)
    }

    fn deserialize_tuple_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        len: usize,
        v: V,
    ) -> Result<V::Value, Error> {
        self.deserialize_tuple(len, v)
    }

    fn deserialize_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        _fields: &'static [&'static str],
        v: V,
    ) -> Result<V::Value, Error> {
        let r = self.plist(v);
        self.at(r)
    }

    fn deserialize_enum<V: Visitor<'de>>(
        self,
        _name: &'static str,
        _variants: &'static [&'static str],
        v: V,
    ) -> Result<V::Value, Error> {
        let r = self.variant(v);
        self.at(r)
    }

    fn deserialize_ignored_any<V: Visitor<'de>>(self, v: V) -> Result<V::Value, Error> {
        v.visit_unit()
    }
}

struct SeqDe<'de> {
    items: std::vec::IntoIter<&'de Node>,
}

impl<'de> SeqDe<'de> {
    fn new(items: Vec<&'de Node>) -> Self {
        SeqDe {
            items: items.into_iter(),
        }
    }
}

impl<'de> SeqAccess<'de> for SeqDe<'de> {
    type Error = Error;

    fn next_element_seed<T: DeserializeSeed<'de>>(
        &mut self,
        seed: T,
    ) -> Result<Option<T::Value>, Error> {
        self.items
            .next()
            .map(|n| seed.deserialize(Deserializer::new(n)))
            .transpose()
    }

    fn size_hint(&self) -> Option<usize> {
        Some(self.items.len())
    }
}

/// `(:key value :key value …)`.
struct PlistMap<'de> {
    items: &'de [Node],
    at: usize,
}

impl<'de> PlistMap<'de> {
    fn new(items: &'de [Node]) -> Result<Self, Error> {
        if items.len() % 2 == 1
            && let Some(last) = items.last()
        {
            return Err(error(last.span, "a key has no value"));
        }
        Ok(PlistMap { items, at: 0 })
    }
}

impl<'de> MapAccess<'de> for PlistMap<'de> {
    type Error = Error;

    fn next_key_seed<K: DeserializeSeed<'de>>(
        &mut self,
        seed: K,
    ) -> Result<Option<K::Value>, Error> {
        let Some(key) = self.items.get(self.at) else {
            return Ok(None);
        };
        let Datum::Sym(name) = &key.datum else {
            return Err(error(key.span, "expected a keyword key such as :name"));
        };
        if !is_keyword(name) {
            return Err(error(key.span, "expected a keyword key such as :name"));
        }
        let field = name[1..].replace('-', "_");
        seed.deserialize(StringDeserializer::<Error>::new(field))
            .map(Some)
            .map_err(|e| spanned(e, key.span))
    }

    fn next_value_seed<V: DeserializeSeed<'de>>(&mut self, seed: V) -> Result<V::Value, Error> {
        let value = &self.items[self.at + 1];
        self.at += 2;
        seed.deserialize(Deserializer::new(value))
    }

    fn size_hint(&self) -> Option<usize> {
        Some((self.items.len() - self.at) / 2)
    }
}

/// `((KEY . VALUE) (KEY VALUE…) …)`: an entry `(K A B)` is `(K . (A B))`, so its value is the list `(A B)`.
struct AlistMap<'de> {
    entries: std::slice::Iter<'de, Node>,
    value: Option<Val<'de>>,
}

impl<'de> MapAccess<'de> for AlistMap<'de> {
    type Error = Error;

    fn next_key_seed<K: DeserializeSeed<'de>>(
        &mut self,
        seed: K,
    ) -> Result<Option<K::Value>, Error> {
        let Some(entry) = self.entries.next() else {
            return Ok(None);
        };
        let (key, value) = match &entry.datum {
            Datum::Cons(items, last) if items.len() == 1 => (&items[0], Val::Node(last.as_ref())),
            Datum::List(items) => (&items[0], tail(&items[1..], entry.span)),
            _ => return Err(error(entry.span, "expected a (KEY . VALUE) pair")),
        };
        self.value = Some(value);
        seed.deserialize(Deserializer::new(key)).map(Some)
    }

    fn next_value_seed<V: DeserializeSeed<'de>>(&mut self, seed: V) -> Result<V::Value, Error> {
        match self.value.take() {
            Some(value) => seed.deserialize(Deserializer(value)),
            None => Err(error(Span::default(), "a map value without its key")),
        }
    }

    fn size_hint(&self) -> Option<usize> {
        Some(self.entries.len())
    }
}

struct EnumDe<'de> {
    name: &'de str,
    rest: &'de [Node],
    span: Span,
}

impl<'de> EnumAccess<'de> for EnumDe<'de> {
    type Error = Error;
    type Variant = VariantDe<'de>;

    fn variant_seed<V: DeserializeSeed<'de>>(
        self,
        seed: V,
    ) -> Result<(V::Value, Self::Variant), Error> {
        let value = seed
            .deserialize(BorrowedStrDeserializer::<Error>::new(self.name))
            .map_err(|e| spanned(e, self.span))?;
        Ok((
            value,
            VariantDe {
                rest: self.rest,
                span: self.span,
            },
        ))
    }
}

struct VariantDe<'de> {
    rest: &'de [Node],
    span: Span,
}

impl<'de> VariantAccess<'de> for VariantDe<'de> {
    type Error = Error;

    fn unit_variant(self) -> Result<(), Error> {
        if self.rest.is_empty() {
            Ok(())
        } else {
            Err(error(self.span, "this variant takes no value"))
        }
    }

    fn newtype_variant_seed<T: DeserializeSeed<'de>>(self, seed: T) -> Result<T::Value, Error> {
        match self.rest {
            [one] => seed.deserialize(Deserializer::new(one)),
            rest => seed.deserialize(Deserializer(tail(rest, self.span))),
        }
    }

    fn tuple_variant<V: Visitor<'de>>(self, len: usize, v: V) -> Result<V::Value, Error> {
        serde::Deserializer::deserialize_tuple(Deserializer(tail(self.rest, self.span)), len, v)
    }

    fn struct_variant<V: Visitor<'de>>(
        self,
        fields: &'static [&'static str],
        v: V,
    ) -> Result<V::Value, Error> {
        serde::Deserializer::deserialize_struct(
            Deserializer(tail(self.rest, self.span)),
            "",
            fields,
            v,
        )
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use serde::Deserialize;

    use super::*;
    use crate::read::{Limits, read_all};

    fn node(src: &str) -> Node {
        read_all(src.as_bytes(), Limits::default())
            .expect("the source reads")
            .remove(0)
    }

    #[derive(Debug, Deserialize, PartialEq)]
    #[serde(deny_unknown_fields)]
    struct Profile {
        command: Vec<String>,
        mode: String,
        on_error: Option<String>,
        max_turns: Option<u32>,
        #[serde(default)]
        doc: String,
        ratio: f64,
        flag: bool,
    }

    #[test]
    fn plist_to_struct() {
        let n = node(
            r#"(:command ("claude-agent-acp") :mode queue :on-error last-good :max-turns 3
                :doc "Reviews" :ratio 1 :flag t)"#,
        );
        let p: Profile = from_node(&n).expect("fits");
        assert_eq!(
            p,
            Profile {
                command: vec!["claude-agent-acp".into()],
                mode: "queue".into(),
                on_error: Some("last-good".into()),
                max_turns: Some(3),
                doc: "Reviews".into(),
                ratio: 1.0,
                flag: true,
            }
        );
    }

    #[test]
    fn alist_to_map() {
        let n = node(r#"(("a" . 1) ("b" . 2))"#);
        let m: BTreeMap<String, i64> = from_node(&n).expect("fits");
        assert_eq!(m, BTreeMap::from([("a".into(), 1), ("b".into(), 2)]));
        let n = node(r#"((a 1 2) (b))"#);
        let m: BTreeMap<String, Vec<i64>> = from_node(&n).expect("fits");
        assert_eq!(
            m,
            BTreeMap::from([("a".into(), vec![1, 2]), ("b".into(), vec![])])
        );
    }

    #[test]
    fn dotted_pair_is_a_2_tuple() {
        let n = node(r#"("in" . 3)"#);
        let t: (String, i64) = from_node(&n).expect("fits");
        assert_eq!(t, ("in".into(), 3));
        let n = node(r#"(("in" . 3) ("out" . 4))"#);
        let v: Vec<(String, i64)> = from_node(&n).expect("fits");
        assert_eq!(v.len(), 2);
        assert!(from_node::<(i64, i64, i64)>(&node("(1 2)")).is_err());
    }

    #[test]
    fn nil_is_empty_by_type() {
        let n = node("nil");
        assert_eq!(from_node::<Vec<String>>(&n).unwrap(), Vec::<String>::new());
        assert_eq!(from_node::<Option<String>>(&n).unwrap(), None);
        assert!(!from_node::<bool>(&n).unwrap());
        assert!(from_node::<BTreeMap<String, i64>>(&n).unwrap().is_empty());
        #[derive(Debug, Deserialize, Default, PartialEq)]
        #[serde(default)]
        struct Empty {
            a: Vec<i64>,
        }
        assert_eq!(from_node::<Empty>(&n).unwrap(), Empty::default());
    }

    #[test]
    fn unknown_plist_key_is_an_error_with_path() {
        #[derive(Debug, Deserialize)]
        #[serde(deny_unknown_fields)]
        #[allow(dead_code)]
        struct Inner {
            size: u32,
        }
        #[derive(Debug, Deserialize)]
        #[allow(dead_code)]
        struct Outer {
            name: String,
            inner: Inner,
        }
        let src = r#"(:name "x" :inner (:size 3 :bogus 1))"#;
        let n = node(src);
        let err = serde_path_to_error::deserialize::<_, Outer>(Deserializer::new(&n))
            .expect_err("unknown key");
        assert!(
            err.path().to_string().starts_with("inner"),
            "{}",
            err.path()
        );
        let at = src.find(":bogus").unwrap();
        assert_eq!(
            err.inner().span,
            Span {
                start: at,
                end: at + 6
            }
        );
        assert!(err.inner().message.contains("bogus"));
    }

    #[test]
    fn an_error_carries_the_nodes_span() {
        let src = r#"(:size "x")"#;
        #[derive(Debug, Deserialize)]
        #[allow(dead_code)]
        struct S {
            size: u32,
        }
        let err = from_node::<S>(&node(src)).unwrap_err();
        let at = src.find("\"x\"").unwrap();
        assert_eq!(
            err.span,
            Span {
                start: at,
                end: at + 3
            }
        );
    }

    #[test]
    fn enums_by_symbol_and_by_list() {
        #[derive(Debug, Deserialize, PartialEq)]
        #[serde(rename_all = "kebab-case")]
        enum OnError {
            LastGood,
            Strict,
            Limit(u32),
        }
        assert_eq!(
            from_node::<OnError>(&node("last-good")).unwrap(),
            OnError::LastGood
        );
        assert_eq!(
            from_node::<OnError>(&node("\"strict\"")).unwrap(),
            OnError::Strict
        );
        assert_eq!(
            from_node::<OnError>(&node("(limit 5)")).unwrap(),
            OnError::Limit(5)
        );
        assert!(from_node::<OnError>(&node("(strict 1)")).is_err());
        assert!(from_node::<OnError>(&node("other")).is_err());
    }
}
