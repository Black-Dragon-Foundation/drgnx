//! The Luau host: mlua with the `luau` feature, `sandbox(true)`, no way out of the sandbox (no `io`, `require`,
//! `loadstring`, `dofile`, no `os.execute`), a memory limit and an interrupt callback that enforces a step budget.
//! The API's functions are bound by the generated `install_luau`, whose tables are read-only; a script's errors come
//! back as villa errors. Everything that runs script code goes through [`LuauHost`]'s methods, each of which renews the
//! budget and says for whom the call is.

use std::cell::Cell;
use std::rc::Rc;
use std::sync::{Arc, Mutex, RwLock};

use bod::Origin;
use mlua::{Lua, Table, VmState};

use crate::generated::Api;
use crate::generated::drgnx_api_v0_1_0::exports::entry;
use crate::generated::drgnx_api_v0_1_0::types::ErrorKind;
use crate::{Caller, Limits};

/// A Luau state with the API installed, for one extension.
pub struct LuauHost {
    lua: Lua,
    steps: Rc<Cell<u64>>,
    caller: Arc<RwLock<Caller>>,
    limits: Limits,
}

/// A failed script as a villa error: the script's own text is the detail.
pub fn script_error(e: mlua::Error) -> villa::Error {
    villa::Error::invalid("A script failed.").with_detail(e.to_string())
}

/// What a script must not have: the standard library's doors to files, processes and other code.
const GLOBALS_REMOVED: &[&str] = &["io", "dofile", "loadfile", "loadstring", "require"];
const OS_REMOVED: &[&str] = &[
    "execute",
    "exit",
    "remove",
    "rename",
    "tmpname",
    "getenv",
    "setlocale",
];

impl LuauHost {
    /// A state for EXTENSION with the API installed, sandboxed, held to LIMITS: every call may take `limits.steps`
    /// interrupt steps (a call or a loop edge each), and the state may hold `limits.memory_bytes` more than it starts
    /// with.
    pub fn new<A: Api + 'static>(
        api: &Arc<Mutex<A>>,
        extension: &str,
        limits: Limits,
    ) -> villa::Result<Self> {
        let lua = Lua::new();
        let globals = lua.globals();
        for name in GLOBALS_REMOVED {
            globals.set(*name, mlua::Value::Nil).map_err(script_error)?;
        }
        if let Ok(os) = globals.get::<Table>("os") {
            for name in OS_REMOVED {
                os.set(*name, mlua::Value::Nil).map_err(script_error)?;
            }
        }
        let caller = Arc::new(RwLock::new(Caller {
            extension: extension.to_string(),
            origin: Origin::Extension(extension.to_string()),
        }));
        crate::generated::install_luau(&lua, api, &caller).map_err(script_error)?;
        lua.sandbox(true).map_err(script_error)?;
        lua.set_memory_limit(lua.used_memory() + limits.memory_bytes)
            .map_err(script_error)?;
        let steps = Rc::new(Cell::new(0));
        let counter = Rc::clone(&steps);
        let budget = limits.steps;
        lua.set_interrupt(move |_| {
            counter.set(counter.get() + 1);
            if counter.get() > budget {
                return Err(mlua::Error::runtime("the script used up its step budget"));
            }
            Ok(VmState::Continue)
        });
        Ok(Self {
            lua,
            steps,
            caller,
            limits,
        })
    }

    /// F with the step budget renewed and the call made for ORIGIN: an agent that has the extension act is the origin
    /// of what the extension then does. A failure is a villa error.
    fn guarded<T>(
        &self,
        origin: Origin,
        f: impl FnOnce(&Lua) -> mlua::Result<T>,
    ) -> villa::Result<T> {
        self.steps.set(0);
        let before = self.set_origin(origin);
        let r = f(&self.lua);
        self.set_origin(before);
        r.map_err(script_error)
    }

    fn set_origin(&self, origin: Origin) -> Origin {
        let mut c = match self.caller.write() {
            Ok(c) => c,
            Err(p) => p.into_inner(),
        };
        std::mem::replace(&mut c.origin, origin)
    }

    /// Run SRC (the extension's code, or a test's) as ORIGIN.
    pub fn exec(&self, origin: Origin, name: &str, src: &str) -> villa::Result<()> {
        self.guarded(origin, |lua| lua.load(src).set_name(name).exec())
    }

    /// Load a chunk that returns the extension table (its exported functions).
    pub fn load(&self, origin: Origin, name: &str, src: &str) -> villa::Result<Table> {
        self.guarded(origin, |lua| lua.load(src).set_name(name).eval::<Table>())
    }

    /// The extension's `init`.
    pub fn init(&self, origin: Origin, ext: &Table) -> villa::Result<()> {
        self.guarded(origin, |lua| entry::luau_init(lua, ext))
    }

    /// The extension's `run` of the command NAME.
    pub fn run(
        &self,
        origin: Origin,
        ext: &Table,
        name: &str,
    ) -> villa::Result<Result<(), ErrorKind>> {
        self.guarded(origin, |lua| entry::luau_run(lua, ext, name))
    }

    /// The extension's `answered`: the answer to a question it asked.
    pub fn answered(
        &self,
        origin: Origin,
        ext: &Table,
        question: u64,
        choice: &str,
    ) -> villa::Result<()> {
        self.guarded(origin, |lua| {
            entry::luau_answered(lua, ext, question, choice)
        })
    }

    /// What the state holds now, in bytes.
    pub fn used_memory(&self) -> usize {
        self.lua.used_memory()
    }

    pub fn limits(&self) -> Limits {
        self.limits
    }
}
