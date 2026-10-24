//! Sandboxed launch (Task 10; `docs/develop/gleipnir.md`, "Ratatoskr's side"): `launch::spawn(plan, req) ->
//! draugr::Spec` for every worker and manager (its worktree writable, the lock's protected paths read-only, the
//! network the matrix's `network` cell grants) and `launch::spawn_plain(plan, sid)` for a chat with no project (still
//! in Gleipnir: a scratch cwd, provider network only).  No code path starts a session unsandboxed: `Unsandboxed` is
//! never granted here, and a host with no sandbox refuses the launch.

use crate::agents::lock::LaunchPlan;
use crate::sandbox::{self, SessionShape};
use gleipnir::{Refusal, Rule, Sandbox, Tier};
use runstav::methods::matrix::Role;
use runstav::paths::{self, Env};
use std::path::{Path, PathBuf};

/// The matrix's Network cell, as a launch needs it.  Provider-only and provider-and-packages both reach the world only
/// through the session's proxy (its allowlist differs, which is the proxy owner's); `Open` shares the host network.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetCell {
    ProviderOnly,
    ProviderAndPackages,
    Open,
}

/// What a worker's or manager's launch asks of the sandbox.
#[derive(Debug, Clone)]
pub struct SandboxReq {
    pub sid: String,
    pub worktree: PathBuf,
    pub read: Vec<PathBuf>,
    pub net: NetCell,
    pub role: Role,
}

/// A launch ready to spawn: the `draugr::Spec`, and the helper's status pipe (read end) and known layers.  The caller
/// reads the status line (`gleipnir::read_status`) after spawning: a launch whose status is not read is not known to
/// have started inside the sandbox, so the session must be killed when it fails.
#[derive(Debug)]
pub struct Launch {
    pub spec: draugr::Spec,
    pub status: Option<std::os::fd::OwnedFd>,
    pub layers: Option<gleipnir::LayersReport>,
}

/// A worker or manager session's launch: its worktree is the only project path it can write.  A `Role::Chat` is
/// refused (a chat has no worktree: [`spawn_plain`]).
pub fn spawn(plan: &LaunchPlan, req: &SandboxReq) -> Result<Launch, Refusal> {
    if req.role == Role::Chat {
        return Err(refusal("a chat has no worktree: use spawn_plain"));
    }
    let env = Env::process();
    let shape = SessionShape {
        sid: req.sid.clone(),
        cwd: req.worktree.clone(),
        write: vec![req.worktree.clone()],
        read: req.read.clone(),
        net: req.net,
    };
    launch(&env, plan, &shape)
}

/// A chat with no project, still in Gleipnir: its cwd is a scratch dir of its own (`scratch_dir`), nothing of the
/// project or the home is bound beyond the CLI's own login dir, and only the provider's network is reachable.
pub fn spawn_plain(plan: &LaunchPlan, sid: &str) -> Result<Launch, Refusal> {
    let env = Env::process();
    let scratch = scratch_dir(&env, sid)?;
    let shape = SessionShape {
        sid: sid.to_string(),
        cwd: scratch.clone(),
        write: vec![scratch],
        read: vec![],
        net: NetCell::ProviderOnly,
    };
    launch(&env, plan, &shape)
}

/// A session's scratch dir, `<tmp>/drgnx-scratch-UID/SID` (made private).  It is not in the session dir: that one is
/// bound read-only and nothing else may lie in it (Gleipnir's rule 5).
pub fn scratch_dir(env: &Env, sid: &str) -> Result<PathBuf, Refusal> {
    // The same name check as the session dir's.
    paths::session_dir(env, &paths::socket_path(env), sid)
        .map_err(|e| refusal(&format!("session id: {e}")))?;
    let root = sandbox::tmp_dir(env).join(format!("drgnx-scratch-{}", env.uid));
    let dir = root.join(sid);
    for d in [&root, &dir] {
        paths::private_dir(d).map_err(|e| setup(d, &e.to_string()))?;
    }
    Ok(dir)
}

/// Validate and prepare `shape` for `plan` on this host: the full tier when bwrap is usable, else the reduced tier
/// (the caller's explicit choice), else a refusal.  Nothing is spawned.
pub fn launch(env: &Env, plan: &LaunchPlan, shape: &SessionShape) -> Result<Launch, Refusal> {
    let helper = sandbox::helper().map_err(|e| refusal(&format!("the helper's own path: {e}")))?;
    let sb = Sandbox::detect(Tier::Full, helper.clone(), None)
        .or_else(|_| Sandbox::detect(Tier::Reduced, helper, None))?;
    #[cfg(target_os = "macos")]
    let sb = sb.with_mac(sandbox::mac_context());
    launch_on(env, &sb, plan, shape)
}

/// [`launch`] on a chosen sandbox.
pub fn launch_on(
    env: &Env,
    sb: &Sandbox,
    plan: &LaunchPlan,
    shape: &SessionShape,
) -> Result<Launch, Refusal> {
    let target = sb
        .target()
        .ok_or_else(|| refusal("no sandbox backend here"))?;
    let ctx = sandbox::context(env);
    let scratch = scratch_dir(env, &shape.sid)?;
    let spec = sandbox::session_spec(env, &ctx, plan, shape, &scratch, sb.tier(), target)?;
    let valid = gleipnir::validate(spec, &ctx, target)?;
    let command = plan
        .argv
        .iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    let prepared = sb.prepare(
        valid,
        command,
        #[cfg(feature = "test-hooks")]
        gleipnir::TestHooks::default(),
    )?;
    Ok(Launch {
        spec: sandbox::to_draugr(prepared.invocation),
        status: prepared.status,
        layers: prepared.layers,
    })
}

fn refusal(message: &str) -> Refusal {
    Refusal {
        rule: Rule::Malformed,
        path: None,
        message: message.to_string(),
    }
}

fn setup(path: &Path, message: &str) -> Refusal {
    Refusal {
        rule: Rule::Setup,
        path: Some(path.to_path_buf()),
        message: format!("{}: {message}", path.display()),
    }
}

#[cfg(test)]
mod tests;
