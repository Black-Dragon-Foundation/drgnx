//! The reduced tier: the inner helper run directly, with no mount, pid or network namespace; Landlock ABI ≥ 9 and
//! seccomp, or a refusal (Task 8). Task 13's `Sandbox::prepare` turns a [`ReducedRun`] into its `Invocation`.
//!
//! The run: the helper's own path with `sandbox-inner --spec-fd 3 -- CMD…`, an empty environment, the sealed spec at
//! fd 3 and the status pipe's write end at fd 4. The spawn must make the helper a session leader (`setsid` before
//! exec) or leave it outside any process group of its own: a process-group leader cannot call `setsid()`, and the
//! helper refuses to run without a new session. `setsid` also makes the helper's pid its process group's, so the
//! caller ends the sandbox by killing that group.

use crate::inner::{self, InnerSpec};
use crate::landlock::Tier;
use crate::spec::{Target, ValidSpec};
use crate::validate::{Refusal, Rule};
use std::ffi::OsString;
use std::io;
use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};

/// What the reduced tier runs. `fds` are `(spec memfd, 3)` and `(status write end, 4)`; both move into the spawn,
/// and the caller keeps only `status`, the read end, for [`inner::read_status`].
#[derive(Debug)]
pub struct ReducedRun {
    pub program: PathBuf,
    pub args: Vec<OsString>,
    pub fds: Vec<(OwnedFd, i32)>,
    pub status: OwnedFd,
}

/// The inner spec of `spec` in the reduced tier: the reduced Landlock plan, the spec's environment and `chdir`, a new
/// session, and under `Net::Isolated` the relay, run as `helper relay_args… --ready-fd 3 PORT=SOCK…`. The relay is
/// exec'd under Landlock, so the helper file itself joins the read roots then (read and execute on that one file).
pub fn inner_spec(
    spec: &ValidSpec,
    helper: &Path,
    relay_args: &[OsString],
) -> Result<InnerSpec, Refusal> {
    if spec.target() != Target::LinuxReduced {
        return Err(Refusal {
            rule: Rule::Malformed,
            path: None,
            message: format!(
                "the reduced tier runs only a LinuxReduced spec, not {:?}",
                spec.target()
            ),
        });
    }
    let program = helper
        .to_str()
        .filter(|p| helper.is_absolute() && !p.contains('\n'))
        .ok_or_else(|| Refusal {
            rule: Rule::NotUtf8,
            path: Some(helper.to_owned()),
            message: format!(
                "the helper's path is not absolute UTF-8: {}",
                helper.display()
            ),
        })?;
    let relay = inner::relay_plan(program, relay_args, spec)?;
    let mut inner = InnerSpec::for_spec(spec, Tier::Reduced, relay);
    if inner.relay.is_some() {
        let roots = &mut inner.landlock.read_roots;
        roots.push(helper.to_owned());
        roots.sort();
        roots.dedup();
    }
    Ok(inner)
}

/// The run for `inner`: `helper inner_args… --spec-fd 3 -- command…`, the spec in a sealed memfd at 3 and a fresh
/// status pipe's write end at 4.
pub fn prepare(
    inner: &InnerSpec,
    helper: &Path,
    inner_args: &[OsString],
    command: &[String],
) -> io::Result<ReducedRun> {
    if command.first().is_none_or(String::is_empty) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "the reduced tier needs a command",
        ));
    }
    let spec = inner::spec_memfd(inner)?;
    let (status, write_end) = inner::status_pipe()?;
    let mut args: Vec<OsString> = inner_args.to_vec();
    args.extend(["--spec-fd", "3", "--"].map(OsString::from));
    args.extend(command.iter().map(OsString::from));
    Ok(ReducedRun {
        program: helper.to_owned(),
        args,
        fds: vec![(spec, inner::SPEC_FD), (write_end, inner::STATUS_FD)],
        status,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::{Bind, Layers, Mode, Net, RelayPort, Spec};

    fn spec(net: Net) -> Spec {
        Spec {
            read: vec!["/srv/docs".into()],
            write: vec!["/work/task".into()],
            hide: vec![],
            sockets: vec![],
            binds: vec![],
            home: None,
            run: Some(Bind {
                mode: Mode::Ro,
                source: "/rt/s/S1".into(),
                dest: "/rt/s/S1".into(),
            }),
            env: vec![("PATH".into(), "/usr/bin".into())],
            chdir: "/work/task".into(),
            net,
            tmp: Some("/state/tmp-1".into()),
            layers: Layers::for_target(Target::LinuxReduced),
            extra_tcp_ports: vec![8080],
        }
    }

    fn isolated() -> Net {
        Net::Isolated {
            relay: vec![RelayPort {
                port: 3128,
                socket: "/rt/s/S1/proxy.sock".into(),
            }],
            mac_tcp_ports: vec![],
        }
    }

    const HELPER: &str = "/opt/drgnx/bin/ratatoskr";

    #[test]
    fn inner_spec_for_a_reduced_spec() {
        let v = ValidSpec::assume_valid(spec(isolated()), Target::LinuxReduced);
        let i = inner_spec(&v, Path::new(HELPER), &[OsString::from("relay")]).unwrap();
        assert_eq!(i.version, inner::VERSION);
        assert_eq!(i.landlock.tier, Tier::Reduced);
        assert_eq!(i.landlock.min_abi, 9);
        assert!(i.new_session);
        assert_eq!(i.env, vec![("PATH".to_owned(), "/usr/bin".to_owned())]);
        assert_eq!(i.chdir, Some(PathBuf::from("/work/task")));
        let relay = i.relay.as_ref().unwrap();
        assert_eq!(
            relay.argv,
            [
                HELPER,
                "relay",
                "--ready-fd",
                "3",
                "3128=/rt/s/S1/proxy.sock"
            ]
        );
        assert_eq!(relay.ready_timeout_ms, inner::RELAY_READY_TIMEOUT_MS);
        assert!(i.landlock.read_roots.contains(&PathBuf::from(HELPER)));
        assert!(!i.landlock.write_roots.contains(&PathBuf::from(HELPER)));
        // Not network-open: TCP only to the relay's port, never `extra_tcp_ports`.
        assert_eq!(i.landlock.tcp_connect_ports, Some(vec![3128]));
        assert_eq!(i.landlock.tcp_bind_ports, Some(vec![3128]));
    }

    #[test]
    fn a_shared_reduced_spec_has_no_relay_and_no_helper_root() {
        let v = ValidSpec::assume_valid(spec(Net::Shared), Target::LinuxReduced);
        let i = inner_spec(&v, Path::new(HELPER), &[OsString::from("relay")]).unwrap();
        assert_eq!(i.relay, None);
        assert!(!i.landlock.read_roots.contains(&PathBuf::from(HELPER)));
        assert_eq!(i.landlock.tcp_connect_ports, Some(vec![]));
    }

    #[test]
    fn only_a_reduced_spec_and_an_absolute_helper() {
        let mut s = spec(Net::Shared);
        s.layers = Layers::for_target(Target::LinuxBwrap);
        let v = ValidSpec::assume_valid(s, Target::LinuxBwrap);
        assert_eq!(
            inner_spec(&v, Path::new(HELPER), &[]).unwrap_err().rule,
            Rule::Malformed
        );
        let v = ValidSpec::assume_valid(spec(Net::Shared), Target::LinuxReduced);
        assert_eq!(
            inner_spec(&v, Path::new("ratatoskr"), &[])
                .unwrap_err()
                .rule,
            Rule::NotUtf8
        );
    }

    #[test]
    fn prepare_puts_spec_at_3_and_status_at_4() {
        let v = ValidSpec::assume_valid(spec(Net::Shared), Target::LinuxReduced);
        let i = inner_spec(&v, Path::new(HELPER), &[]).unwrap();
        let run = prepare(
            &i,
            Path::new(HELPER),
            &[OsString::from("sandbox-inner")],
            &["/bin/sh".into(), "-c".into(), "echo hi".into()],
        )
        .unwrap();
        assert_eq!(run.program, PathBuf::from(HELPER));
        assert_eq!(
            run.args,
            [
                "sandbox-inner",
                "--spec-fd",
                "3",
                "--",
                "/bin/sh",
                "-c",
                "echo hi"
            ]
            .map(OsString::from)
        );
        let targets: Vec<i32> = run.fds.iter().map(|(_, t)| *t).collect();
        assert_eq!(targets, [3, 4]);
        // fd 3 holds this spec; fd 4 is the write end of `status`.
        let mut s = String::new();
        let mut f = std::fs::File::from(run.fds[0].0.try_clone().unwrap());
        std::io::Read::read_to_string(&mut f, &mut s).unwrap();
        assert_eq!(serde_json::from_str::<InnerSpec>(&s).unwrap(), i);
        rustix::io::write(&run.fds[1].0, b"x").unwrap();
        let mut b = [0u8; 1];
        assert_eq!(rustix::io::read(&run.status, &mut b).unwrap(), 1);
        assert!(prepare(&i, Path::new(HELPER), &[], &[]).is_err());
    }
}
