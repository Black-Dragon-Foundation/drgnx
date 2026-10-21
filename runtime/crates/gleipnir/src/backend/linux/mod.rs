//! The Linux backends: the full tier under bubblewrap ([`bwrap`]) and the reduced tier, Landlock and seccomp without
//! bwrap ([`reduced`]). [`detect`] and [`prepare_full`]/[`prepare_reduced`] are what `Sandbox` calls (Task 13).

pub mod bwrap;
pub mod reduced;

use super::{BackendKind, Hooks, Invocation, Prepared, Sandbox};
use crate::bwrap::{InnerCommand, SPEC_FD, STATUS_FD};
use crate::inner::{self, InnerSpec};
use crate::landlock::Tier;
use crate::sbpl::MacContext;
use crate::spec::{HELPER_INSIDE, ValidSpec};
use crate::validate::{Refusal, Rule};
use std::io;
use std::path::PathBuf;

/// The backend for `tier`. The full tier needs bwrap ≥ 0.12.0 from a root-owned path (`bwrap_override`, a test
/// hook, is still held to that); without it the full tier is refused, never run in the reduced tier instead. Both
/// need a seccomp filter for this architecture. Landlock's ABI is the helper's to check, when it runs.
pub(super) fn detect(
    tier: Tier,
    helper: InnerCommand,
    bwrap_override: Option<PathBuf>,
) -> Result<Sandbox, Refusal> {
    if crate::seccomp::native().is_none() {
        return Err(super::none::refusal(
            "gleipnir has no seccomp filter for this architecture",
        ));
    }
    if !helper.source.is_absolute() {
        return Err(Refusal {
            rule: Rule::Malformed,
            path: Some(helper.source.clone()),
            message: format!(
                "the inner helper's path is not absolute: {}",
                helper.source.display()
            ),
        });
    }
    let (kind, program) = match tier {
        Tier::Full => {
            let (program, _version) = match &bwrap_override {
                Some(p) => bwrap::find_in(&[p.as_path()]),
                None => bwrap::find(),
            }?;
            (BackendKind::Bwrap, Some(program))
        }
        Tier::Reduced => (BackendKind::Reduced, None),
    };
    Ok(Sandbox {
        kind,
        tier,
        helper,
        program,
        mac: MacContext::default(),
    })
}

fn setup(what: &str, e: io::Error) -> Refusal {
    Refusal {
        rule: Rule::Setup,
        path: None,
        message: format!("sandbox setup failed: {what}: {e}"),
    }
}

/// The test hooks, into the inner spec. Without the feature there is nothing to set.
fn apply(inner: &mut InnerSpec, hooks: Hooks) {
    #[cfg(feature = "test-hooks")]
    {
        inner.landlock_omit = hooks.landlock_omit;
        inner.abi_cap = hooks.abi_cap;
    }
    #[cfg(not(feature = "test-hooks"))]
    let _ = (inner, hooks);
}

/// The full tier: every source opened without links (`bwrap::open_sources`), the inner spec (Landlock for the
/// inside paths, the relay run as [`HELPER_INSIDE`]) on a sealed memfd at fd 3, the status pipe's write end at 4,
/// the binds from 5; bwrap's argv; no environment (the program's travels in the inner spec).
pub(super) fn prepare_full(
    sandbox: &Sandbox,
    spec: ValidSpec,
    command: Vec<String>,
    hooks: Hooks,
) -> Result<Prepared, Refusal> {
    let program = sandbox
        .program
        .as_ref()
        .ok_or_else(|| super::none::refusal("bwrap was not found"))?;
    let opened = bwrap::open_sources(&spec, &sandbox.helper)?;
    let relay = inner::relay_plan(HELPER_INSIDE, &sandbox.helper.relay_args, &spec)?;
    let mut inner = InnerSpec::for_spec(&spec, Tier::Full, relay);
    apply(&mut inner, hooks);
    let memfd = inner::spec_memfd(&inner).map_err(|e| setup("the inner spec", e))?;
    let (status, write_end) = inner::status_pipe().map_err(|e| setup("the status pipe", e))?;
    let (args, binds) = crate::bwrap::argv(&spec, opened, &command);
    let mut fds = vec![(memfd, SPEC_FD), (write_end, STATUS_FD)];
    fds.extend(binds);
    Ok(Prepared {
        invocation: Invocation {
            program: program.path.clone(),
            args,
            env: vec![],
            cwd: None,
            fds,
            new_session: false,
        },
        status: Some(status),
        layers: None,
    })
}

/// The reduced tier: the helper run directly as `helper sandbox-inner --spec-fd 3 -- CMD…` in a session of its own,
/// fds 3 and 4, no environment. A `hide` entry inside a root the reduced tier grants is refused: without a mount
/// namespace nothing can be put over it, and Landlock only ever adds rights.
pub(super) fn prepare_reduced(
    sandbox: &Sandbox,
    spec: ValidSpec,
    command: Vec<String>,
    hooks: Hooks,
) -> Result<Prepared, Refusal> {
    let helper = &sandbox.helper;
    let mut inner = reduced::inner_spec(&spec, &helper.source, &helper.relay_args)?;
    unhideable(&spec, &inner)?;
    apply(&mut inner, hooks);
    let run = reduced::prepare(&inner, &helper.source, &helper.inner_args, &command)
        .map_err(|e| setup("the reduced run", e))?;
    Ok(Prepared {
        invocation: Invocation {
            program: run.program,
            args: run.args,
            env: vec![],
            cwd: None,
            fds: run.fds,
            new_session: true,
        },
        status: Some(run.status),
        layers: None,
    })
}

/// The first `hide` entry that lies in a root `inner`'s Landlock plan grants anything on, as a refusal.
fn unhideable(spec: &ValidSpec, inner: &InnerSpec) -> Result<(), Refusal> {
    let plan = &inner.landlock;
    let granted = plan
        .read_roots
        .iter()
        .chain(&plan.write_roots)
        .chain(&plan.unix_connect_roots)
        .chain(&plan.dev_write_files);
    for (i, h) in spec.spec().hide.iter().enumerate() {
        if let Some(root) = granted.clone().find(|r| h.starts_with(r)) {
            return Err(Refusal {
                rule: Rule::Malformed,
                path: Some(h.clone()),
                message: format!(
                    "hide[{i}]: {} lies in {}, which the reduced tier grants; without a mount namespace it cannot \
                     be hidden there (leave that root out, or use the full tier)",
                    h.display(),
                    root.display()
                ),
            });
        }
    }
    Ok(())
}
