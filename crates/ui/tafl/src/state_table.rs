//! The state table: state values by (document, instance path, name), outside the slabs. An instance dropped off
//! screen leaves its named states here; made again, it finds them by name. Only values that differ from their initial
//! value are kept, and a snapshot of them survives a rebuild (a warm restart).

use std::any::{Any, TypeId};
use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::cell::{State, Value};
use crate::engine::Engine;
use crate::propagate::Core;
use crate::slab::SlabId;

/// A named state's key: its document, its instance's key path and its name.
#[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct StateKey {
    pub doc: Arc<str>,
    pub path: Arc<[u32]>,
    pub name: Arc<str>,
}

// written by hand: the name ends in `Key`, but it holds no secret (a document, a key path and a state's name)
impl std::fmt::Debug for StateKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}{:?}/{}", self.doc, self.path, self.name)
    }
}

/// Every stored state, serialised: kept across a rebuild for a warm restart.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct StateSnapshot {
    pub(crate) entries: Vec<(StateKey, String, serde_json::Value)>,
}

/// A named state's type, as the table handles it without knowing it.
#[derive(Clone, Copy)]
struct Kind {
    id: TypeId,
    name: &'static str,
    ser: fn(&dyn Any) -> serde_json::Value,
}

/// A live named state: its key, its initial value and its type.
struct Named {
    key: StateKey,
    init: Box<dyn Any>,
    eq: fn(&dyn Any, &dyn Any) -> bool,
    kind: Kind,
}

/// A stored value: the live value of a dropped instance, or a snapshot's JSON (a warm restart).
enum Stored {
    Live(Box<dyn Any>, Kind),
    Json(String, serde_json::Value),
}

#[derive(Default)]
pub(crate) struct Table {
    named: HashMap<u32, Named>,
    stored: BTreeMap<StateKey, Stored>,
    notices: Vec<String>,
}

fn ser<T: Serialize + 'static>(v: &dyn Any) -> serde_json::Value {
    v.downcast_ref::<T>()
        .and_then(|v| serde_json::to_value(v).ok())
        .unwrap_or(serde_json::Value::Null)
}

fn eq<T: PartialEq + 'static>(a: &dyn Any, b: &dyn Any) -> bool {
    matches!((a.downcast_ref::<T>(), b.downcast_ref::<T>()), (Some(a), Some(b)) if a == b)
}

impl Table {
    /// Before slab CELLS go: each named state that differs from its initial value is stored, the others forgotten.
    pub(crate) fn keep(&mut self, core: &Core, cells: &[u32]) {
        for c in cells {
            let Some(n) = self.named.remove(c) else {
                continue;
            };
            let node = core.g.borrow_mut().node[*c as usize].take();
            let Some(v) = node.and_then(|n| n.into_value()) else {
                continue;
            };
            if (n.eq)(&*v, &*n.init) {
                self.stored.remove(&n.key);
            } else {
                self.stored.insert(n.key, Stored::Live(v, n.kind));
            }
        }
    }
}

impl Engine {
    /// A state in slab S found by its name K: the stored value when there is one of type T, else INIT. A stored value
    /// of another type is dropped, with one notice ([`Engine::take_notices`]).
    pub fn named_state<T: Value + Serialize + DeserializeOwned>(
        &mut self,
        s: SlabId,
        k: StateKey,
        init: T,
    ) -> State<T> {
        let kind = Kind {
            id: TypeId::of::<T>(),
            name: std::any::type_name::<T>(),
            ser: ser::<T>,
        };
        let found = match self.states.stored.remove(&k) {
            None => None,
            Some(Stored::Live(v, kd)) if kd.id == kind.id => v.downcast::<T>().ok().map(|b| *b),
            Some(Stored::Json(ty, j)) if ty == kind.name => serde_json::from_value::<T>(j).ok(),
            Some(Stored::Live(_, kd)) => {
                self.states.type_changed(&k, kd.name, kind.name);
                None
            }
            Some(Stored::Json(ty, _)) => {
                self.states.type_changed(&k, &ty, kind.name);
                None
            }
        };
        let value = found.unwrap_or_else(|| init.clone());
        let st = self.state(s, value);
        self.states.named.insert(
            st.id().idx,
            Named {
                key: k,
                init: Box::new(init),
                eq: eq::<T>,
                kind,
            },
        );
        st
    }

    /// Every named state that differs from its initial value, stored or live, serialised.
    pub fn snapshot_states(&self) -> StateSnapshot {
        let mut entries = Vec::new();
        for (k, v) in &self.states.stored {
            match v {
                Stored::Live(v, kind) => {
                    entries.push((k.clone(), kind.name.to_string(), (kind.ser)(&**v)))
                }
                Stored::Json(ty, j) => entries.push((k.clone(), ty.clone(), j.clone())),
            }
        }
        let g = self.core.g.borrow();
        for (c, n) in &self.states.named {
            let Some(v) = g.node[*c as usize].as_ref().and_then(|n| n.value()) else {
                continue;
            };
            if !(n.eq)(v, &*n.init) {
                entries.push((n.key.clone(), n.kind.name.to_string(), (n.kind.ser)(v)));
            }
        }
        entries.sort_by(|a, b| a.0.cmp(&b.0));
        StateSnapshot { entries }
    }

    /// Take a snapshot's states as stored ones (a warm restart): instances made after find them by name.
    pub fn restore_states(&mut self, s: StateSnapshot) {
        for (k, ty, j) in s.entries {
            self.states.stored.insert(k, Stored::Json(ty, j));
        }
    }

    /// How many states are stored (of dropped instances, or restored).
    pub fn stored_states(&self) -> usize {
        self.states.stored.len()
    }

    /// The notices since the last call: stored states reset because their type changed.
    pub fn take_notices(&mut self) -> Vec<String> {
        std::mem::take(&mut self.states.notices)
    }
}

impl Table {
    fn type_changed(&mut self, k: &StateKey, old: &str, new: &str) {
        let msg = format!(
            "the state `{}` of {} was a {old} and is now a {new}: it starts again from its initial value",
            k.name, k.doc
        );
        tracing::warn!(state = %k.name, doc = %k.doc, old, new, "a stored state changed type");
        self.notices.push(msg);
    }
}
