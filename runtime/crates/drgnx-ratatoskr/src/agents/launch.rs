//! Sandboxed launch (Task 10; `docs/develop/gleipnir.md`, "Ratatoskr's side"): `launch::spawn(env, plan, req) ->
//! draugr::Spec` for every worker and manager (its worktree writable, the lock's protected paths read-only, the
//! network the matrix's `network` cell grants), `launch::spawn_plain(env, plan, sid)` for a chat with no project (still
//! in Gleipnir: a scratch cwd, provider network only) and `launch::spawn_chat(env, plan, sid, project)` for a chat in a
//! project (the project read-only, its scratch dir writable, provider network only).  [`kind`] picks one.  No code path
//! starts a session unsandboxed: `Unsandboxed` is never granted here, and a host with no sandbox refuses the launch.

use crate::agents::lock::LaunchPlan;
use crate::sandbox::{self, SessionShape};
use gleipnir::{Refusal, Rule, Sandbox, Tier};
use runstav::methods::matrix::Role;
use runstav::paths::{self, Env};
use std::path::{Path, PathBuf};

/// The matrix's Network cell, as a launch needs it.  Provider-only and provider-and-packages both reach the world only
/// through the session's proxy (its allowlist differs, which is the proxy owner's); `Open` shares the host network.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
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
/// refused (a chat has no worktree: [`spawn_plain`] or [`spawn_chat`]).
/// ENV is the hub's environment with the login shell's variables applied (`ShellEnv::paths_env`).
pub async fn spawn(env: &Env, plan: &LaunchPlan, req: &SandboxReq) -> Result<Launch, Refusal> {
    if req.role == Role::Chat {
        return Err(refusal(
            "a chat has no worktree: use spawn_plain or spawn_chat",
        ));
    }
    let (plan, shape) = worktree_launch(plan, req);
    launch(env, &plan, &shape).await.map(with_stdin)
}

/// An agent session's launch: the hub speaks ACP on the agent's stdin and stdout, so its stdin is a pipe, not the
/// `/dev/null` a job gets (`sandbox::to_draugr`).
pub fn with_stdin(mut launch: Launch) -> Launch {
    launch.spec.stdin_null = false;
    launch
}

/// The plan and shape of a worker's or manager's launch: its worktree writable, and the hooks and config of the git
/// folder inside it pinned read-only next to the lock's protected paths ([`sandbox::git_access`]).  The user's
/// repository is never writable: a plan run's or a manager worker's tree is a snapshot with a `.git` of its own.
pub fn worktree_launch(plan: &LaunchPlan, req: &SandboxReq) -> (LaunchPlan, SessionShape) {
    let mut plan = plan.clone();
    plan.protected_ro.extend(sandbox::git_access(&req.worktree));
    let write = vec![req.worktree.clone()];
    let shape = SessionShape {
        sid: req.sid.clone(),
        cwd: req.worktree.clone(),
        write,
        read: req.read.clone(),
        net: req.net,
    };
    (plan, shape)
}

/// A chat with no project, still in Gleipnir: its cwd is a scratch dir of its own (`scratch_dir`), nothing of the
/// project or the home is bound beyond the CLI's own login dir, and only the provider's network is reachable.
pub async fn spawn_plain(env: &Env, plan: &LaunchPlan, sid: &str) -> Result<Launch, Refusal> {
    let scratch = scratch_dir(env, sid)?;
    let shape = SessionShape {
        sid: sid.to_string(),
        cwd: scratch.clone(),
        write: vec![scratch],
        read: vec![],
        net: NetCell::ProviderOnly,
    };
    launch(env, plan, &shape).await.map(with_stdin)
}

/// A chat in a project (design §4.2: project-scoped, read access per the matrix): [`chat_launch`]'s shape.
pub async fn spawn_chat(
    env: &Env,
    plan: &LaunchPlan,
    sid: &str,
    project: &Path,
) -> Result<Launch, Refusal> {
    let (plan, shape) = chat_launch(env, plan, sid, project)?;
    launch(env, &plan, &shape).await.map(with_stdin)
}

/// The plan and shape of a chat in PROJECT: the project (as its true name: the editor's `default-directory` ends in a
/// slash, and a link would be refused) is its cwd and read-only, its scratch dir (`scratch_dir`) the only writable
/// path beside the CLI's login dir, and only the provider's network is reachable.  Nothing in the project can be
/// written, so its git folder's hooks and config are out of reach as well; the lock's protected paths are not pinned
/// (they are read-only with the rest), so nothing is made in the user's project and a linked `.envrc` is no refusal.
/// A linked worktree's (or a submodule's) git folders outside the project are read-only too ([`outside_git_dirs`]), so
/// `git log` and `git diff` work in it; they are never writable.
pub fn chat_launch(
    env: &Env,
    plan: &LaunchPlan,
    sid: &str,
    project: &Path,
) -> Result<(LaunchPlan, SessionShape), Refusal> {
    let dir = sandbox::true_name(project)
        .filter(|p| p.is_dir())
        .ok_or_else(|| setup(project, "the chat's project is not a folder"))?;
    let scratch = scratch_dir(env, sid)?;
    let mut plan = plan.clone();
    plan.protected_ro.clear();
    let mut read = vec![dir.clone()];
    read.extend(outside_git_dirs(&dir)?);
    let shape = SessionShape {
        sid: sid.to_string(),
        cwd: dir,
        write: vec![scratch],
        read,
        net: NetCell::ProviderOnly,
    };
    Ok((plan, shape))
}

/// The git folders PROJECT's git needs that lie outside it, as true names (`sandbox::git_dirs`): a linked worktree's
/// or a submodule's `.git` is a file naming its own folder, and that folder's `commondir` the common one (the objects,
/// refs and config).  The common folder is given, and the own one when it is not inside it.  A plain checkout (`.git`
/// a folder) or no `.git` needs none.  A `.git` file whose folders do not resolve is refused: the chat's git would read
/// nothing, and a path that is not its true name is never bound.
pub fn outside_git_dirs(project: &Path) -> Result<Vec<PathBuf>, Refusal> {
    let dot = project.join(".git");
    if !dot.symlink_metadata().is_ok_and(|m| m.is_file()) {
        return Ok(vec![]);
    }
    let g = sandbox::git_dirs(project)
        .ok_or_else(|| setup(&dot, "names a git folder that does not resolve"))?;
    let mut out: Vec<PathBuf> = Vec::new();
    for d in [g.common, g.gitdir] {
        if !d.starts_with(project) && !out.iter().any(|o| d.starts_with(o)) {
            out.push(d);
        }
    }
    Ok(out)
}

/// Which launch a session gets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// [`spawn_plain`]: a chat in its own scratch dir.
    Plain,
    /// [`spawn_chat`]: a chat in a project.
    Chat,
    /// [`spawn`]: a worker or manager in its worktree.
    Worktree,
}

/// The launch of a session in ROLE working in CWD, whose scratch dir is SCRATCH.
pub fn kind(role: Role, cwd: &Path, scratch: &Path) -> Kind {
    if cwd == scratch {
        Kind::Plain
    } else if role == Role::Chat {
        Kind::Chat
    } else {
        Kind::Worktree
    }
}

/// A session's scratch dir, `<tmp>/drgnx-scratch-UID/SID`.  It is not in the session dir: that one is
/// bound read-only and nothing else may lie in it (Gleipnir's rule 5).
pub fn scratch_path(env: &Env, sid: &str) -> PathBuf {
    sandbox::tmp_dir(env)
        .join(format!("drgnx-scratch-{}", env.uid))
        .join(sid)
}

/// [`scratch_path`], made private (the session id is checked like the session dir's).
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

/// Validate and prepare `shape` for `plan` on this host, in the sandbox [`detect`] finds.  Nothing is spawned.
pub async fn launch(env: &Env, plan: &LaunchPlan, shape: &SessionShape) -> Result<Launch, Refusal> {
    let sb = detect().await?;
    launch_on(env, &sb, plan, shape)
}

/// The tier that passed the check here, kept for the hub's life once it passed; a failed check is run again at the
/// next launch, so a bubblewrap installed since is found.
static USABLE: std::sync::Mutex<Option<Tier>> = std::sync::Mutex::new(None);

/// The sandbox a launch runs in: the full tier when its check passes (the doctor's check: the real invocation around
/// a probe, so a bwrap that is present but cannot run, as in a container, does not count), else the reduced tier
/// when its check passes, else a refusal with the full tier's reason and fix.
pub async fn detect() -> Result<Sandbox, Refusal> {
    let helper = sandbox::helper().map_err(|e| refusal(&format!("the helper's own path: {e}")))?;
    let known = *USABLE.lock().unwrap_or_else(|e| e.into_inner());
    let tier = match known {
        Some(t) => t,
        None => {
            // the probe's status is read blocking: on a thread and a runtime of its own, never a hub worker
            let t = pick(|tier| async move {
                tokio::task::spawn_blocking(move || {
                    sandbox::check_blocking(tier, None, sandbox::CHECK_TIMEOUT)
                })
                .await
                .unwrap_or_else(|e| gleipnir::check::Check::failed(format!("the check: {e}"), None))
            })
            .await?;
            *USABLE.lock().unwrap_or_else(|e| e.into_inner()) = Some(t);
            t
        }
    };
    let sb = Sandbox::detect(tier, helper, None)?;
    #[cfg(target_os = "macos")]
    let sb = sb.with_mac(sandbox::mac_context());
    Ok(sb)
}

/// The tier [`detect`] takes, given the check of a tier: the full one, else the reduced one, else the refusal (the
/// full tier's reason and fix, as `ratatoskr sandbox check` and the doctor say them).
pub async fn pick<F, Fut>(check: F) -> Result<Tier, Refusal>
where
    F: Fn(Tier) -> Fut,
    Fut: std::future::Future<Output = gleipnir::check::Check>,
{
    let full = check(Tier::Full).await;
    if full.ok {
        return Ok(Tier::Full);
    }
    if check(Tier::Reduced).await.ok {
        return Ok(Tier::Reduced);
    }
    let mut message = format!(
        "no sandbox can start here: {}",
        full.reason.as_deref().unwrap_or("unknown")
    );
    if let Some(fix) = &full.fix {
        message.push_str(&format!(" (fix: {fix})"));
    }
    Err(Refusal {
        rule: Rule::Setup,
        path: None,
        message,
    })
}

/// [`launch`] on a chosen sandbox.  The spec makes the session dir (`sandbox::session_spec`): a launch that is refused
/// removes it again when it was not there before.
pub fn launch_on(
    env: &Env,
    sb: &Sandbox,
    plan: &LaunchPlan,
    shape: &SessionShape,
) -> Result<Launch, Refusal> {
    let target = sb
        .target()
        .ok_or_else(|| refusal("no sandbox backend here"))?;
    let new_dir = paths::session_dir(env, &paths::socket_path(env), &shape.sid)
        .ok()
        .filter(|d| std::fs::symlink_metadata(d).is_err());
    let launched = launch_in(env, sb, target, plan, shape);
    if launched.is_err()
        && let Some(d) = new_dir
    {
        // empty, as it was just made; one that something filled since is left
        let _ = std::fs::remove_dir(d);
    }
    launched
}

fn launch_in(
    env: &Env,
    sb: &Sandbox,
    target: gleipnir::Target,
    plan: &LaunchPlan,
    shape: &SessionShape,
) -> Result<Launch, Refusal> {
    let ctx = sandbox::context(env);
    let scratch = scratch_dir(env, &shape.sid)?;
    let built = sandbox::session_spec(env, &ctx, plan, shape, &scratch, sb.tier(), target)?;
    let valid = gleipnir::validate(built.spec, &ctx, target)?;
    // the program by the path the spec showed it at; its arguments as the plan has them
    let command = std::iter::once(built.program.as_os_str())
        .chain(plan.argv.iter().skip(1).map(|a| a.as_os_str()))
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
