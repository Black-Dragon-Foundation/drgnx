//! `agents/probe`: does a profile's agent start and answer `initialize`?  The onboarding asks it before it offers the
//! agent.  The agent is started as a chat session would be (the profile, its lock, the sandbox, in a scratch folder),
//! asked once, and ended with its process group.  No session is made: nothing is recorded, nothing is registered with
//! the gateway.

use super::session::{find_profile, internal, invalid, new_sid, prepare, refuse};
use super::transcript::redact;
use crate::dispatch::Caller;
use crate::front::Front;
use hermod::{Conn, ConnOpts, Error as AcpError, Event};
use runstav::methods::agents::{AgentInfo, ProbeParams, ProbeResult};
use runstav::methods::matrix::Role;
use runstav::registry::Class;
use runstav::wire::Error;
use serde_json::json;
use std::time::Duration;

/// Seconds the agent has to answer when the call names none.
const WAIT_S: u64 = 15;
/// What the answer carries of the agent's stderr.
const STDERR_MAX: usize = 2048;
/// How long the end of an agent that exited is waited for (a grandchild may hold its pipe open).
const EXIT_WAIT: Duration = Duration::from_secs(3);

/// A refused or a failed check is an answer, not an error: `ok: false` and why.
fn failed(why: String, stderr_tail: Option<String>) -> ProbeResult {
    ProbeResult {
        ok: false,
        agent: None,
        why: Some(why),
        stderr_tail,
    }
}

/// The last [`STDERR_MAX`] bytes of TAIL (whole characters), redacted; none when it is blank.
fn tail_of(tail: &str) -> Option<String> {
    let tail = tail.trim();
    if tail.is_empty() {
        return None;
    }
    let mut from = tail.len().saturating_sub(STDERR_MAX);
    while !tail.is_char_boundary(from) {
        from += 1;
    }
    Some(redact(&tail[from..]))
}

pub async fn probe(front: &Front, caller: &Caller, p: ProbeParams) -> Result<ProbeResult, Error> {
    if caller.class != Class::User {
        return Err(refuse("only the user checks an agent"));
    }
    // as `agents/start`: the settings as the file says now
    front.refresh_settings().await;
    let mut profile = find_profile(front, p.profile.as_str()).ok_or_else(|| {
        invalid(
            "profile",
            format!("no agent profile {:?}", p.profile.as_str()),
        )
    })?;
    // the check asks nothing of a model: no gateway registration is made for it
    profile.ai = None;
    let wait = Duration::from_secs(p.wait_s.unwrap_or(WAIT_S));
    let sid = format!("probe{}", &new_sid()?[1..9]);
    let env = runstav::paths::Env::process();
    let cwd = crate::agents::launch::scratch_dir(&env, &sid)
        .map_err(|r| internal(format!("scratch directory: {}", r.message)))?;
    let result = run(front, &profile, &sid, &cwd, wait).await;
    let _ = std::fs::remove_dir_all(&cwd);
    // the sandboxed launch made its session dir (and, on macOS, its profile file in it)
    if let Ok(dir) = runstav::paths::session_dir(&env, &runstav::paths::socket_path(&env), &sid) {
        let _ = std::fs::remove_dir_all(dir);
    }
    result
}

async fn run(
    front: &Front,
    profile: &crate::settings::AgentProfile,
    sid: &str,
    cwd: &std::path::Path,
    wait: Duration,
) -> Result<ProbeResult, Error> {
    let prep = prepare(front, profile, Role::Chat, sid, cwd, None, &[]).await?;
    let command = profile.command.join(" ");
    let opts = ConnOpts {
        deadline: wait,
        stderr_tail: STDERR_MAX,
        tap: crate::recording::acp_tap(sid, None, &profile.name, &prep.spec, cwd),
    };
    let (conn, mut events) = match Conn::spawn(prep.spec, opts).await {
        Ok(c) => c,
        Err(e) => return Ok(failed(format!("{command}: {e}"), None)),
    };
    let end = |conn: &Conn| {
        let pid = conn.pid();
        async move {
            draugr::kill_group(pid, Duration::ZERO, &draugr::RealSignaller).await;
        }
    };
    // the sandbox helper reports on a pipe; a launch whose status is not read hangs
    if let Some(fd) = prep.status {
        let stderr = conn.stderr();
        let read = crate::clock::blocking(move || {
            gleipnir::read_status(fd, &|| stderr.get(), Duration::from_secs(20))
        })
        .await;
        match read {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => {
                end(&conn).await;
                return Ok(failed(
                    format!("the sandbox did not start: {}", e.message),
                    None,
                ));
            }
            Err(e) => {
                end(&conn).await;
                return Err(internal(format!("reading the sandbox status: {e}")));
            }
        }
    }
    let caps = serde_json::from_value(json!({"fs": {"readTextFile": true, "writeTextFile": true}}))
        .map_err(|e| internal(e.to_string()))?;
    let answer = conn.initialize(caps).await;
    let result = match answer {
        Ok(info) => ProbeResult {
            ok: true,
            agent: info.name.map(|name| AgentInfo {
                name,
                version: info.version,
            }),
            why: None,
            stderr_tail: None,
        },
        Err(AcpError::Deadline(_)) => failed(
            format!("did not answer within {} seconds", wait.as_secs()),
            None,
        ),
        // the agent ended before it answered: its exit status and the end of its stderr
        Err(e) => {
            let exit = crate::clock::timeout(EXIT_WAIT, async {
                while let Some(ev) = events.recv().await {
                    if let Event::Exit {
                        code,
                        signal,
                        stderr,
                    } = ev
                    {
                        return Some((code, signal, stderr));
                    }
                }
                None
            })
            .await
            .ok()
            .flatten();
            match exit {
                Some((code, signal, stderr)) => {
                    let status = match (code, signal) {
                        (Some(c), _) => format!("exit {c}"),
                        (None, Some(s)) => format!("signal {s}"),
                        (None, None) => "no status".to_string(),
                    };
                    failed(
                        format!("ended before it answered ({status})"),
                        tail_of(&stderr),
                    )
                }
                None => failed(e.to_string(), None),
            }
        }
    };
    end(&conn).await;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_stderr_tail_is_bounded_whole_characters_and_redacted() {
        assert_eq!(tail_of("  \n"), None);
        let long = "é".repeat(2000);
        let t = tail_of(&long).unwrap();
        assert!(
            t.len() <= STDERR_MAX && t.chars().all(|c| c == 'é'),
            "{}",
            t.len()
        );
        // built at run time: a key-shaped literal would be refused by the public repo's hook
        let key = format!("sk-{}", "q".repeat(40));
        let keyed = tail_of(&format!("boom\nOPENAI_API_KEY={key}")).unwrap();
        assert!(!keyed.contains(&key), "{keyed}");
    }
}
