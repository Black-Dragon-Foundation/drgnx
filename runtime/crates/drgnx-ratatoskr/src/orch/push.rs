//! The push gate (`docs/develop/orchestration.md`, "The push gate"): a job's agent asking to push (`push.ci`,
//! `push.main`) is refused until the pack's tiers are green on the exact commit's tree with the hub's env stamp now
//! (`vordr::push::judge`); the missing tiers start through the queue as evidence of `push:JOB@TREE`.  The push itself
//! stays the user's: a push the gate lets through still meets the matrix.
//!
//! The gate reads the command itself ([`parse`]): `git` with its global options (`-C`, `-c`, …), each push in a
//! list of commands, and the source of each refspec it sends; a command it can't read (a shell around it, another
//! repository, every branch at once) is refused, never let by.  A job (`exec/start`) never pushes.

use std::path::Path;

use vordr::push::{Push, judge};

use crate::front::Front;
use crate::orch::gates::{git, run_of, start};

/// One `git push` in a command: the folder `-C` named (relative to the command's), and the source refs it sends.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PushCmd {
    pub dir: Option<String>,
    pub refs: Vec<String>,
}

/// What a command is to the push gate.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Parsed {
    NotPush,
    Push(Vec<PushCmd>),
    /// It may push, but not in a way the gate can read.
    Unclear,
}

/// The pushes in the shell COMMAND.
pub fn parse(command: &str) -> Parsed {
    let separators = |c: char| matches!(c, ';' | '&' | '|' | '\n' | '\r');
    let words = || {
        command
            .split(|c: char| c.is_whitespace() || separators(c))
            .map(|w| w.trim_matches(|c| c == '\'' || c == '"'))
    };
    // no `push` word, or nothing named git: not a push
    if !words().any(|w| w == "push") || !words().any(|w| w.contains("git")) {
        return Parsed::NotPush;
    }
    if command.contains(['$', '`', '(', ')', '\\', '\'', '"', '<', '>']) {
        return Parsed::Unclear;
    }
    let mut out = Vec::new();
    for segment in command.split(separators) {
        let mut w = segment.split_whitespace().skip_while(|w| {
            w.contains('=') && !w.starts_with('-') && !w.contains('/') && !w.starts_with("git")
        });
        let Some(program) = w.next() else { continue };
        let rest: Vec<&str> = w.collect();
        if program.rsplit('/').next() != Some("git") {
            if rest.contains(&"push") {
                return Parsed::Unclear;
            }
            continue;
        }
        let mut dir = None;
        let mut i = 0;
        // git's global options, up to the subcommand
        while let Some(a) = rest.get(i) {
            match *a {
                "-C" => {
                    dir = rest.get(i + 1).map(|d| d.to_string());
                    i += 2;
                }
                "-c" => i += 2,
                "--no-pager"
                | "-P"
                | "-p"
                | "--paginate"
                | "--no-replace-objects"
                | "--literal-pathspecs"
                | "--no-optional-locks" => i += 1,
                a if a.starts_with('-') => return Parsed::Unclear,
                _ => break,
            }
        }
        if rest.get(i) != Some(&"push") {
            continue;
        }
        let mut positional = Vec::new();
        let mut args = rest[i + 1..].iter();
        while let Some(a) = args.next() {
            match *a {
                "--all" | "--mirror" | "--tags" | "--follow-tags" => return Parsed::Unclear,
                "-o" | "--push-option" | "--repo" | "--receive-pack" | "--exec" => {
                    args.next();
                }
                a if a.starts_with('-') => {}
                a => positional.push(a),
            }
        }
        let refs: Vec<String> = if positional.len() < 2 {
            vec!["HEAD".into()]
        } else {
            positional[1..]
                .iter()
                .map(|r| {
                    r.trim_start_matches('+')
                        .split(':')
                        .next()
                        .unwrap_or_default()
                })
                .filter(|src| !src.is_empty())
                .map(str::to_owned)
                .collect()
        };
        out.push(PushCmd { dir, refs });
    }
    if out.is_empty() {
        Parsed::NotPush
    } else {
        Parsed::Push(out)
    }
}

/// The refusal's words for the refs it judged: (ref, commit, why), each named.
fn said(refused: &[(String, String, String)]) -> String {
    let each: Vec<String> = refused
        .iter()
        .map(|(r, c, why)| format!("{r} ({c}): {why}"))
        .collect();
    format!(
        "a push needs one full run green on each commit it sends first; {} (ask again once they are green)",
        each.join("; ")
    )
}

/// Why JOB's push COMMAND, run in the folder DIR, is refused, or none when it may go on to the matrix: each ref it
/// sends is judged on its commit.  A job with no rule pack, or whose pack has no push gate, has none.
pub async fn refusal(front: &Front, job: &str, dir: &Path, command: &str) -> Option<String> {
    let j = job.to_owned();
    let pack = front
        .writer
        .db
        .read(move |c| norn::read::evidence::pack_of_job(c, &j))
        .await
        .ok()
        .flatten()?;
    if !pack.on("push-gate") {
        return None;
    }
    let pushes = match parse(command) {
        Parsed::NotPush => return None,
        Parsed::Unclear => {
            return Some(
                "the push gate can't tell which commits this command sends: push with a plain `git push REMOTE \
                 REF…` (no shell around it, this repository, one ref at a time or several named)"
                    .into(),
            );
        }
        Parsed::Push(p) => p,
    };
    let mut refused = Vec::new();
    for p in &pushes {
        let d = p
            .dir
            .as_ref()
            .map_or_else(|| dir.to_owned(), |s| dir.join(s));
        for r in &p.refs {
            if let Some((commit, why)) = judge_ref(front, job, &pack, &d, r).await {
                refused.push((r.clone(), commit, why));
            }
        }
    }
    (!refused.is_empty()).then(|| said(&refused))
}

/// Whether REF in the tree DIR may be pushed under PACK: none when its commit's tiers are green, else (commit, why);
/// the missing tiers start.
async fn judge_ref(
    front: &Front,
    job: &str,
    pack: &vordr::pack::Pack,
    dir: &Path,
    r: &str,
) -> Option<(String, String)> {
    let (d, rf) = (dir.to_owned(), r.to_owned());
    let found = crate::clock::blocking(move || {
        let top = git(&d, &["rev-parse", "--show-toplevel"])?
            .trim()
            .to_owned();
        let head = git(&d, &["rev-parse", "--verify", &format!("{rf}^{{commit}}")])?
            .trim()
            .to_owned();
        let tree = git(&d, &["rev-parse", &format!("{head}^{{tree}}")])?
            .trim()
            .to_owned();
        Ok::<_, String>((top, head, tree))
    })
    .await;
    let (top, head, tree) = match found {
        Ok(Ok(t)) => t,
        Ok(Err(e)) => return Some((String::new(), format!("the push gate cannot read it: {e}"))),
        Err(e) => return Some((String::new(), format!("the push gate cannot read it: {e}"))),
    };
    let short = head[..head.len().min(12)].to_owned();
    front.queue.at_push(job, &head, &tree);
    let key = format!("push:{job}@{tree}");
    let k = key.clone();
    let evidence = match front
        .writer
        .db
        .read(move |c| norn::read::evidence::of_task(c, &k))
        .await
    {
        Ok(e) => e,
        Err(e) => return Some((short, format!("the push gate cannot read its runs: {e}"))),
    };
    match judge(pack, &evidence, &tree, crate::exec::env_stamp()) {
        Push::Ready => None,
        Push::NoTiers => Some((
            short,
            "the push gate is on but the job's pack names no tiers".into(),
        )),
        Push::Red(red) => {
            let said: Vec<String> = red
                .iter()
                .map(|(t, rows)| format!("{t}: {}", rows.join(", ")))
                .collect();
            Some((short, format!("fails {}", said.join("; "))))
        }
        Push::Missing(tiers) => {
            for t in &tiers {
                match start(front, &key, Path::new(&top), &head, &tree, &run_of(t)).await {
                    Ok(None) => {}
                    Ok(Some(why)) => return Some((short, format!("its {}: {why}", t.name))),
                    Err(e) => {
                        return Some((short, format!("could not start {}: {e}", t.name)));
                    }
                }
            }
            let names: Vec<&str> = tiers.iter().map(|t| t.name.as_str()).collect();
            Some((short, format!("running now: {}", names.join(", "))))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn push(dir: Option<&str>, refs: &[&str]) -> PushCmd {
        PushCmd {
            dir: dir.map(str::to_owned),
            refs: refs.iter().map(|r| r.to_string()).collect(),
        }
    }

    /// Every spelling of a push is one, with the refs it sends; what the gate can't read is refused, never let by.
    #[test]
    fn a_push_is_read_with_its_global_options_and_the_refs_it_sends() {
        assert_eq!(parse("git status"), Parsed::NotPush);
        assert_eq!(parse("git stash push -m x"), Parsed::NotPush);
        assert_eq!(parse("git log --grep push"), Parsed::NotPush);
        assert_eq!(parse("git push"), Parsed::Push(vec![push(None, &["HEAD"])]));
        assert_eq!(
            parse("git  push origin"),
            Parsed::Push(vec![push(None, &["HEAD"])])
        );
        assert_eq!(
            parse("git -C sub -c x=y --no-pager push -u origin feat +wip:main :gone"),
            Parsed::Push(vec![push(Some("sub"), &["feat", "wip"])])
        );
        assert_eq!(
            parse("/usr/bin/git push origin HEAD:refs/heads/x"),
            Parsed::Push(vec![push(None, &["HEAD"])])
        );
        assert_eq!(
            parse("GIT_TRACE=1 git push -o ci.skip origin a"),
            Parsed::Push(vec![push(None, &["a"])])
        );
        assert_eq!(
            parse("make && git push origin a; git push origin b"),
            Parsed::Push(vec![push(None, &["a"]), push(None, &["b"])])
        );
        // what it can't read: a shell around it, another repository, every branch at once
        for c in [
            "sh -c 'git push'",
            "env git push",
            "git push $(cat r)",
            "git --git-dir=/x push",
            "git push --all",
            "git push --mirror",
            "xargs git push",
        ] {
            assert_eq!(parse(c), Parsed::Unclear, "{c}");
        }
    }

    #[test]
    fn the_refusal_names_the_refs_it_judged() {
        let w = said(&[
            ("feat".into(), "1234567".into(), "unit: a::t".into()),
            ("wip".into(), "89abcde".into(), "running now: unit".into()),
        ]);
        assert!(w.contains("feat (1234567): unit: a::t"), "{w}");
        assert!(w.contains("wip (89abcde): running now: unit"), "{w}");
    }
}
