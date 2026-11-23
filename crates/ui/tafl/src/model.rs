//! Model objects: one cell per object with a 64-bit changed-field mask, declared with [`model!`](crate::model!).

use std::ops::Deref;

use crate::cell::{CellId, Value};
use crate::rd::{Rd, Wr};
use crate::splice::Key;

/// A model type: a plain struct declared with [`tafl::model!`](crate::model!), whose schema Luau proxies and the WIT
/// see too. At most 64 fields (one bit each in the changed-field mask).
pub trait Model: Value {
    /// The type's name (`"File"`).
    const TYPE: &'static str;
    /// The field readers `model!` generates: `obj.name(r)` reaches them through [`Obj`]'s `Deref`.
    type Fields: FieldSet;
    fn schema() -> &'static Schema;
    /// The bits of the fields whose values differ between A and B.
    fn diff(a: &Self, b: &Self) -> u64;
}

/// A model type's fields, in declaration order.
#[derive(Debug)]
pub struct Schema {
    pub name: &'static str,
    pub fields: &'static [FieldDef],
}

/// One field: its name and its Rust type as written.
#[derive(Debug)]
pub struct FieldDef {
    pub name: &'static str,
    pub ty: &'static str,
}

/// The handle `model!` generates for a type's field readers (an object's [`ModelRef`] inside).
pub trait FieldSet: Copy + 'static {
    fn new(r: ModelRef) -> Self;
    fn model_ref(&self) -> ModelRef;
}

/// An object's or a collection's place in the engine: its cell, and for a collection its row in the list table.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct ModelRef {
    pub(crate) cell: CellId,
    pub(crate) aux: u32,
}

/// A model object of type T. 12 bytes, `Copy`. Its field readers (`f.name(r)`) come from `model!` through `Deref`.
pub struct Obj<T: Model>(pub(crate) T::Fields);

impl<T: Model> Clone for Obj<T> {
    fn clone(&self) -> Self {
        *self
    }
}
impl<T: Model> Copy for Obj<T> {}

impl<T: Model> PartialEq for Obj<T> {
    fn eq(&self, other: &Self) -> bool {
        self.model_ref() == other.model_ref()
    }
}
impl<T: Model> Eq for Obj<T> {}

impl<T: Model> std::fmt::Debug for Obj<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Obj<{}>({:?})", T::TYPE, self.key())
    }
}

impl<T: Model> Deref for Obj<T> {
    type Target = T::Fields;
    fn deref(&self) -> &T::Fields {
        &self.0
    }
}

impl<T: Model> Obj<T> {
    pub(crate) fn from_ref(r: ModelRef) -> Self {
        Obj(T::Fields::new(r))
    }

    pub fn model_ref(self) -> ModelRef {
        self.0.model_ref()
    }

    /// The object's stable key in collections.
    pub fn key(self) -> Key {
        Key::of(self.model_ref().cell)
    }

    /// The whole object, read inside a formula (a read of every field).
    pub fn get(self, r: &Rd) -> T {
        r.read::<T>(self.model_ref().cell)
    }

    /// Change the object in place: the fields F changes are compared with their old values, and only their readers
    /// are marked.
    pub fn update(self, w: &mut Wr, f: impl FnOnce(&mut T)) {
        w.patch::<T>(self.model_ref().cell, f);
    }
}

/// Declares a model type: an ordinary struct. It gets `Clone` and `PartialEq`, the [`Model`] impl and its schema,
/// and per field a reader `obj.field(r)` that records (object, field bit). Writes go through [`Obj::update`].
///
/// ```ignore
/// tafl::model! { pub struct File { pub name: Arc<str>, pub dir: Arc<str>, pub kind: FileKind, pub path: PathBuf } }
/// ```
#[macro_export]
macro_rules! model {
    (
        $(#[$m:meta])*
        $vis:vis struct $name:ident {
            $( $(#[$fm:meta])* $fvis:vis $field:ident : $ty:ty ),* $(,)?
        }
    ) => {
        $(#[$m])*
        #[derive(Clone, PartialEq)]
        $vis struct $name { $( $(#[$fm])* $fvis $field: $ty ),* }

        const _: () = {
            #[allow(non_camel_case_types, dead_code, clippy::upper_case_acronyms)]
            #[repr(u32)]
            enum Bit { $( $field ),* }
            const FIELDS: &[$crate::FieldDef] = &[ $( $crate::FieldDef { name: stringify!($field), ty: stringify!($ty) } ),* ];
            const _: () = assert!(FIELDS.len() <= 64, "a model type has at most 64 fields");
            static SCHEMA: $crate::Schema = $crate::Schema { name: stringify!($name), fields: FIELDS };

            /// The field readers of the model type.
            #[derive(Clone, Copy)]
            pub struct Fields($crate::ModelRef);

            impl $crate::FieldSet for Fields {
                fn new(r: $crate::ModelRef) -> Self {
                    Fields(r)
                }
                fn model_ref(&self) -> $crate::ModelRef {
                    self.0
                }
            }

            impl Fields {
                $(
                    /// The field's value, read inside a formula: recorded as (object, field).
                    pub fn $field(&self, r: &$crate::Rd) -> $ty {
                        r.read_field::<$name, $ty>(self.0, Bit::$field as u32, |v: &$name| &v.$field)
                    }
                )*
            }

            impl $crate::Model for $name {
                const TYPE: &'static str = stringify!($name);
                type Fields = Fields;
                fn schema() -> &'static $crate::Schema {
                    &SCHEMA
                }
                fn diff(a: &Self, b: &Self) -> u64 {
                    let mut m = 0u64;
                    $( if a.$field != b.$field { m |= 1u64 << (Bit::$field as u32); } )*
                    m
                }
            }
        };
    };
}
