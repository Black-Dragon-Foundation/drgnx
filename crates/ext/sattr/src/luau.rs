//! The Luau host: mlua with the `luau` feature, `sandbox(true)` and an interrupt callback that enforces a step budget.
//! The API's functions are bound by the generated `install_luau`, whose tables are read-only; a script's errors come
//! back as villa errors.

use std::cell::Cell;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use mlua::{Lua, Table, VmState};

use crate::generated::Api;

/// A Luau state with the API installed.
pub struct LuauHost {
    pub lua: Lua,
    steps: Rc<Cell<u64>>,
    budget: u64,
}

/// A failed script as a villa error: the script's own text is the detail.
pub fn script_error(e: mlua::Error) -> villa::Error {
    villa::Error::invalid("A script failed.").with_detail(e.to_string())
}

impl LuauHost {
    /// A state with the API installed, sandboxed, whose every call may take at most BUDGET interrupt steps (a call or a
    /// loop edge each).
    pub fn new<A: Api + 'static>(api: &Arc<Mutex<A>>, budget: u64) -> villa::Result<Self> {
        let lua = Lua::new();
        crate::generated::install_luau(&lua, api).map_err(script_error)?;
        lua.sandbox(true).map_err(script_error)?;
        let steps = Rc::new(Cell::new(0));
        let counter = Rc::clone(&steps);
        lua.set_interrupt(move |_| {
            counter.set(counter.get() + 1);
            if counter.get() > budget {
                return Err(mlua::Error::runtime("the script used up its step budget"));
            }
            Ok(VmState::Continue)
        });
        Ok(Self { lua, steps, budget })
    }

    /// F with the step budget renewed; a failure is a villa error.
    pub fn guarded<T>(&self, f: impl FnOnce(&Lua) -> mlua::Result<T>) -> villa::Result<T> {
        self.steps.set(0);
        f(&self.lua).map_err(script_error)
    }

    /// Load a chunk that returns the extension table (its exported functions).
    pub fn load(&self, name: &str, src: &str) -> villa::Result<Table> {
        self.guarded(|lua| lua.load(src).set_name(name).eval::<Table>())
    }

    pub fn budget(&self) -> u64 {
        self.budget
    }
}
