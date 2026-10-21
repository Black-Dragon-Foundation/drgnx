//! Gleipnir, the sandbox (docs/develop/gleipnir.md).
//!
//! Self-contained: no drgnx type and no drgnx path in its public API. The caller passes the closed directories, the
//! session mount point, the relay ports and the env names to deny beyond [`BASE_ENV_DENY`].
//!
//! - [`spec`]: what a sandbox may see, as plain data; [`validate`]: the rules that refuse a spec.
//! - [`toolchain`]: toolchain roots from `PATH`, and the credentials beside them to hide.
//! - [`bwrap`], [`sbpl`], [`net`]: the pure generators (the bubblewrap argv, the Seatbelt profile, hosts, the relay
//!   and the CONNECT proxy). They build on every target, so their goldens run on Linux.
//! - [`backend`]: the one platform boundary (`linux`, `macos`, `none`) and [`Sandbox`], which detects a backend and
//!   prepares a run; [`inner`], [`landlock`], [`seccomp`]: the Linux layers. Every `cfg(target_os)` sits inside
//!   these module files, never here.
//! - [`check`]: whether the sandbox can start here, and the fix when it cannot.

pub mod backend;
pub mod bwrap;
pub mod check;
pub mod inner;
pub mod landlock;
pub mod net;
pub mod sbpl;
pub mod seccomp;
pub mod spec;
pub mod toolchain;
pub mod validate;

// What a caller needs to run something in the sandbox (docs/develop/gleipnir.md, "Using it").
#[cfg(feature = "test-hooks")]
pub use backend::TestHooks;
pub use backend::{BackendKind, Invocation, Prepared, Sandbox};
pub use bwrap::InnerCommand;
pub use inner::{LayersReport, read_status};
pub use landlock::Tier;
pub use validate::{Context, Refusal, Rule, validate};

pub use spec::{
    BASE_ENV_DENY, Bind, HELPER_INSIDE, LANDLOCK_ABI_MAX, LANDLOCK_FLOOR_FULL,
    LANDLOCK_FLOOR_REDUCED, Layers, Mode, Net, RESERVED_DESTS, RelayPort, SECRET_DIRS,
    SECRET_DIRS_MACOS, SYSTEM_CLOSED, Spec, Target, ValidSpec,
};
