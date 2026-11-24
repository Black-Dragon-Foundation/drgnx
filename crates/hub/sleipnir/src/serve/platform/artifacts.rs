//! What an attempt gets from the artifact store, the named caches and its pack's variables, resolved on the runner for
//! `launch` (docs/develop/sleipnir.md, "Artifacts"), and what happens to an artifact build when it ends.
//!
//! - A **container job** runs its argv with the placeholders expanded when its pack made it (`Derived::expand`), the
//!   artifacts it uses mounted read-only, its caches mounted by role, and its variables set; a toolchain (an image
//!   artifact used as `toolchain` or `image`) is the image it runs in, by ID and only when the label names the key.
//! - A **command artifact build** is a container job whose `{out}` is the artifact's part folder; [`done`] commits the
//!   part when the job passed and drops it when it did not.
//! - An **image artifact build** is no container job: the runner pulls the registry's image by digest (checked against
//!   the project's allow-list) or builds it from the tree, and [`done`] records the image in the store.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use forseti::{ArtifactKey, ArtifactUse, Grant, JobSpec, Role};

use crate::artifact::expand::{self, Ctx};
use crate::artifact::image::{self, RECORD, Recorded};
use crate::artifact::store::Store;
use crate::artifact::{command, name_ok};
use crate::linux::podman::{
    self, ART_INSIDE, BuildReq, CacheMount, GATE_CACHE_INSIDE, ImageRef, OUT_INSIDE, RunnerArgs,
    TARGET, UseMount, WORK,
};
use crate::sync::cache::{self, CacheJob, MountKind, SuiteCache};
use crate::sync::register::{Register, epoch_s};

/// What `launch` runs.
pub(super) enum Plan {
    /// A container job.
    Run(Box<Run>),
    /// The runner's own command line (`podman pull`, `podman build`): an image artifact's build.
    Host { argv: Vec<String> },
}

/// A container job's resolved parts.
pub(super) struct Run {
    pub image: ImageRef,
    pub argv: Vec<String>,
    pub uses: Vec<UseMount>,
    pub out: Option<PathBuf>,
    pub caches: Vec<CacheMount>,
    pub env: Vec<(String, String)>,
    /// `(key name, variable)` for the keys an environment entry names (`{key:NAME}`).
    pub key_vars: Vec<(String, String)>,
}

fn bad(why: impl Into<String>) -> villa::Error {
    villa::Error::invalid(why.into())
}

/// The folder of the committed artifact of USE for a job of ROLE (an author's job may be served from the gate's).
fn committed(
    store: &Store,
    project: &str,
    role: Role,
    kind: &str,
    key: &ArtifactKey,
) -> Option<PathBuf> {
    let roles: &[Role] = match role {
        Role::Gate => &[Role::Gate],
        Role::Author => &[Role::Gate, Role::Author],
    };
    roles
        .iter()
        .find_map(|r| store.path(project, *r, kind, key))
}

/// The image of a committed `image` artifact at DIR: its ID, and the label it proves it by.
fn image_of(dir: &Path, key: &ArtifactKey) -> villa::Result<(String, Option<String>)> {
    let text = crate::fsio::read_to_string(dir.join(RECORD))
        .map_err(|e| villa::Error::io(format!("{}: {e}", dir.join(RECORD).display())))?;
    let rec: Recorded = serde_json::from_str(&text).map_err(|e| {
        bad(format!(
            "{} does not parse: {e}",
            dir.join(RECORD).display()
        ))
    })?;
    let label = match rec.source.as_str() {
        // built here: the image's own label is the proof
        "built" => image::label_of(&rec.id)?,
        // pulled by digest from the allow-listed registry, which this runner checked and recorded for this key
        "pulled" => Some(key.0.clone()),
        other => return Err(bad(format!("an image record of source {other:?}"))),
    };
    Ok((rec.id, label))
}

/// Resolves SPEC for `launch`: ATTEMPT is `<job>.<attempt>`, SRC the source the job reads, DIR its folder under ROOT.
pub(super) fn prepare(
    root: &Path,
    dir: &Path,
    src: &Path,
    spec: &JobSpec,
    grant: &Grant,
    attempt: &str,
    ra: &RunnerArgs,
) -> villa::Result<Plan> {
    let store = Store::at(root);
    let project = spec.project.as_str();
    if let Some(b) = &spec.derived.build
        && b.kind == "image"
    {
        return image_job(dir, src, spec, ra).map(|argv| Plan::Host { argv });
    }
    let mut image = ImageRef::Name("job".into());
    let mut uses: Vec<UseMount> = vec![];
    let mut ctx = Ctx {
        src: WORK.into(),
        build: TARGET.into(),
        jobs: forseti::jobs_for(
            grant.cores,
            grant.mem_cap_mib,
            spec.derived
                .unit_mib
                .unwrap_or(forseti::admit::DEFAULT_UNIT_MIB),
        ),
        keys: spec.keys.iter().cloned().collect::<BTreeSet<_>>(),
        ..Ctx::default()
    };
    for u in &spec.artifacts {
        use_of(&store, spec, u, &mut image, &mut uses, &mut ctx.arts)?;
    }
    // the caches, by role
    let slot_target = dir.join("target");
    let job = CacheJob {
        root,
        project,
        trust: spec.trust,
        role: spec.role,
        id: attempt,
        slot_target: &slot_target,
    };
    let specs: Vec<SuiteCache> = spec.derived.caches.iter().map(SuiteCache::from).collect();
    let mounts = cache::mounts_for(&job, &specs);
    let mut caches = vec![];
    for m in mounts.iter().filter(|m| m.kind == MountKind::Cache) {
        for d in std::iter::once(&m.host).chain(m.gate_ro.as_ref().map(|(h, _)| h)) {
            std::fs::create_dir_all(d)
                .map_err(|e| villa::Error::io(format!("{}: {e}", d.display())))?;
        }
        caches.push(CacheMount {
            host: m.host.clone(),
            inside: m.inside.clone(),
            gate_ro: m.gate_ro.clone(),
        });
    }
    if !caches.is_empty() {
        let mut reg = Register::open(root)?;
        cache::register(&mut reg, &job, &specs, &mounts, epoch_s())?;
    }
    for c in &spec.derived.caches {
        ctx.caches.insert(c.name.clone(), c.inside.clone());
        if spec.role == Role::Author && c.sharing != forseti::Sharing::Private {
            ctx.gates
                .insert(c.name.clone(), format!("{GATE_CACHE_INSIDE}/{}", c.name));
        }
    }
    // a command artifact's build writes the artifact's part folder
    let build = spec.derived.build.as_ref();
    let mut out = None;
    if let Some(b) = build {
        let part = store
            .begin(project, spec.role, "command", &b.key)?
            .release();
        ctx.out = Some(OUT_INSIDE.into());
        out = Some(part);
    }
    // the argv and the variables
    let argv = match build {
        Some(b) => command::container_argv(&b.steps, &ctx)?,
        None if spec.derived.expand => expand::expand(&spec.command, &ctx)?,
        None => spec.command.clone(),
    };
    let mut pairs: Vec<(String, String)> = vec![];
    for c in &spec.derived.caches {
        pairs.extend(c.env.iter().cloned());
        if spec.role == Role::Author {
            pairs.extend(c.readonly_env.iter().cloned());
        }
    }
    pairs.extend(spec.derived.env.iter().cloned());
    let (env, key_vars) = if spec.derived.expand || !pairs.is_empty() {
        let e = expand::expand_env(&pairs, &ctx)?;
        (e.vars, e.keys)
    } else {
        (vec![], vec![])
    };
    Ok(Plan::Run(Box::new(Run {
        image,
        argv,
        uses,
        out,
        caches,
        env,
        key_vars,
    })))
}

/// One use of an artifact by the job: a read-only mount, or the image the job runs in.
fn use_of(
    store: &Store,
    spec: &JobSpec,
    u: &ArtifactUse,
    image: &mut ImageRef,
    uses: &mut Vec<UseMount>,
    arts: &mut BTreeMap<String, String>,
) -> villa::Result<()> {
    let project = spec.project.as_str();
    if !name_ok(&u.name) {
        return Err(bad(format!(
            "an artifact's name is a plain word, not {:?}",
            u.name
        )));
    }
    let missing = || {
        villa::Error::unavailable(format!(
            "the artifact {} ({}) is not on this runner",
            u.name, u.key.0
        ))
    };
    let dir = committed(store, project, spec.role, &u.kind, &u.key).ok_or_else(missing)?;
    match (u.kind.as_str(), u.use_.as_str()) {
        ("command", "ro") => {
            uses.push(UseMount::Dir {
                host: dir,
                name: u.name.clone(),
            });
            arts.insert(u.name.clone(), format!("{ART_INSIDE}/{}", u.name));
        }
        ("image", "ro") => {
            let (id, label) = image_of(&dir, &u.key)?;
            if label.as_deref() != Some(u.key.0.as_str()) {
                return Err(bad(format!(
                    "the image of {} does not carry its key's label",
                    u.name
                )));
            }
            uses.push(UseMount::Image {
                id,
                name: u.name.clone(),
            });
            arts.insert(u.name.clone(), format!("{ART_INSIDE}/{}", u.name));
        }
        ("image", "image" | "toolchain") => {
            if !matches!(image, ImageRef::Name(_)) {
                return Err(bad("a job runs in one image: it names two"));
            }
            let (id, label) = image_of(&dir, &u.key)?;
            *image = ImageRef::Id {
                id,
                key: u.key.clone(),
                label,
            };
        }
        (kind, how) => {
            return Err(bad(format!(
                "a {kind} artifact has no use {how:?} (a command is used ro; an image ro, image or toolchain)"
            )));
        }
    }
    Ok(())
}

/// The command line of an image artifact's job: a pull by digest, or a build from the tree.
fn image_job(
    dir: &Path,
    src: &Path,
    spec: &JobSpec,
    ra: &RunnerArgs,
) -> villa::Result<Vec<String>> {
    let b = spec.derived.build.as_ref().ok_or_else(|| bad("no build"))?;
    let i = b
        .image
        .as_ref()
        .ok_or_else(|| bad("an image artifact names its recipe"))?;
    let strings = |v: Vec<std::ffi::OsString>| -> villa::Result<Vec<String>> {
        v.into_iter()
            .map(|a| {
                a.into_string()
                    .map_err(|_| bad("a podman argument is not UTF-8"))
            })
            .collect()
    };
    let mut argv = vec!["podman".to_string()];
    match &i.digest {
        Some(d) => {
            let reference = format!("{}@{d}", i.repo);
            crate::sync::guard::check_pull(&reference, &i.allow)
                .map_err(|e| villa::Error::refused(e.to_string()))?;
            argv.extend(strings(
                podman::pull_argv(&reference).map_err(|r| bad(r.message))?,
            )?);
        }
        None => {
            let req = BuildReq {
                key: b.key.clone(),
                containerfile: src.join(&i.containerfile),
                context: src.join(&i.context),
                dnf_cache: dir.join("dnf"),
                iidfile: dir.join("image.id"),
                net: ra.allowed.contains(&podman::Feature::BuildNet),
                proxy: None,
            };
            std::fs::create_dir_all(&req.dnf_cache)
                .map_err(|e| villa::Error::io(format!("{}: {e}", req.dnf_cache.display())))?;
            argv.extend(strings(
                podman::build_argv(&req, ra).map_err(|r| bad(r.message))?,
            )?);
        }
    }
    Ok(argv)
}

/// An artifact build ended: PASSED (the job's verdict) commits what it made into the store, else drops it.
pub(super) fn done(root: &Path, dir: &Path, spec: &JobSpec, passed: bool) -> villa::Result<()> {
    let Some(b) = &spec.derived.build else {
        return Ok(());
    };
    let store = Store::at(root);
    let project = spec.project.as_str();
    let mut reg = Register::open(root)?;
    let now = epoch_s();
    match b.kind.as_str() {
        "command" => {
            let part = store.resume(project, spec.role, "command", &b.key)?;
            command::finish(
                part,
                passed,
                &dir.join("target"),
                b.keep.as_ref(),
                &mut reg,
                now,
            )?;
        }
        "image" => {
            let part = store.begin(project, spec.role, "image", &b.key)?;
            if !passed {
                return Ok(());
            }
            let i = b.image.as_ref().ok_or_else(|| bad("no image recipe"))?;
            let (id, source, reference) = match &i.digest {
                Some(d) => {
                    let r = format!("{}@{d}", i.repo);
                    (image::id_of(&r)?, "pulled", Some(r))
                }
                None => (image::built_id(&dir.join("image.id"))?, "built", None),
            };
            if source == "built" && image::label_of(&id)?.as_deref() != Some(b.key.0.as_str()) {
                return Err(bad(format!(
                    "the image built for {} does not carry its key's label",
                    b.key.0
                )));
            }
            let rec = Recorded {
                id: id.clone(),
                source: source.into(),
                reference: reference.clone(),
            };
            crate::fsio::write(
                part.path().join(RECORD),
                serde_json::to_vec_pretty(&rec)
                    .map_err(|e| villa::Error::internal(e.to_string()))?,
            )
            .map_err(|e| villa::Error::io(e.to_string()))?;
            part.commit(&mut reg, now)?;
            // the image is ours: the guard keeps the newest two per name
            reg.add(
                crate::sync::guard::image_item(
                    &id,
                    reference
                        .as_deref()
                        .unwrap_or(&format!("localhost/{}", i.repo)),
                    project,
                    now,
                ),
                Path::new(""),
            )?;
        }
        _ => {}
    }
    Ok(())
}
