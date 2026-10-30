//! Reading a plan file as a job (`drgnx-job-read-plan`, `drgnx-job--check`, `drgnx-job--needs`; the Lisp is the
//! oracle): `# Title`, `**Repo:** path`, `### Task N: title` headings with `**Role:**` and `**Depends:** Task M`
//! lines in their bodies, `**Won't build:** subject` lines for the decision log.

use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq)]
pub struct PlanTask {
    pub n: i64,
    pub title: String,
    pub role: String,
    pub deps: Vec<i64>,
    pub body: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Plan {
    pub title: String,
    /// The **Repo:** line, made absolute against the plan's directory (with a trailing `/`).
    pub repo: Option<String>,
    pub tasks: Vec<PlanTask>,
    pub wont_build: Vec<String>,
    /// A hash of the text, to see later that the file changed (the job never follows it).
    pub hash: String,
}

/// The text after PREFIX on the first line that starts with it, trimmed and not empty.
fn line_after<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    text.lines()
        .find_map(|l| l.strip_prefix(prefix))
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

fn lines_after<'a>(text: &'a str, prefix: &'a str) -> impl Iterator<Item = &'a str> {
    text.lines()
        .filter_map(move |l| l.strip_prefix(prefix))
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

/// `### Task N[:.] title` as (N, title).
fn task_head(line: &str) -> Option<(i64, String)> {
    let rest = line.strip_prefix("### Task ")?;
    let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
    let n = digits.parse().ok()?;
    let rest = &rest[digits.len()..];
    let rest = rest
        .strip_prefix(':')
        .or_else(|| rest.strip_prefix('.'))
        .unwrap_or(rest);
    Some((n, rest.trim().to_owned()))
}

/// Every `Task N` in S.
fn task_numbers(s: &str) -> Vec<i64> {
    let mut out = Vec::new();
    let mut rest = s;
    while let Some(at) = rest.find("Task ") {
        rest = &rest[at + 5..];
        let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
        if let Ok(n) = digits.parse() {
            out.push(n);
        }
    }
    out
}

fn fnv(text: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in text.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{h:016x}")
}

fn dir_with_slash(p: PathBuf) -> String {
    let s = p.to_string_lossy().into_owned();
    if s.ends_with('/') { s } else { format!("{s}/") }
}

/// TEXT, read from FILE, as a plan.
pub fn read(text: &str, file: &Path) -> Plan {
    let dir = file.parent().unwrap_or(Path::new("/"));
    let title = text
        .lines()
        .find_map(|l| l.strip_prefix("# "))
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .or_else(|| file.file_stem().map(|s| s.to_string_lossy().into_owned()))
        .unwrap_or_default();
    let repo = line_after(text, "**Repo:**").map(|r| dir_with_slash(dir.join(r)));
    let mut tasks: Vec<PlanTask> = Vec::new();
    let mut body = String::new();
    let mut head: Option<(i64, String)> = None;
    let mut close = |head: &mut Option<(i64, String)>, body: &mut String| {
        if let Some((n, title)) = head.take() {
            let b = std::mem::take(body);
            tasks.push(PlanTask {
                n,
                title,
                role: lines_after(&b, "**Role:**")
                    .next()
                    .map(|r| {
                        r.chars()
                            .take_while(|c| c.is_ascii_lowercase() || *c == '-')
                            .collect::<String>()
                    })
                    .filter(|r| !r.is_empty())
                    .unwrap_or_else(|| "implement".into()),
                deps: line_after(&b, "**Depends:**")
                    .map(task_numbers)
                    .unwrap_or_default(),
                body: b.trim().to_owned(),
            });
        }
        body.clear();
    };
    for line in text.lines() {
        if let Some(h) = task_head(line) {
            close(&mut head, &mut body);
            head = Some(h);
        } else if line.starts_with("##") {
            close(&mut head, &mut body);
        } else if head.is_some() {
            body.push_str(line);
            body.push('\n');
        }
    }
    close(&mut head, &mut body);
    Plan {
        title,
        repo,
        tasks,
        wont_build: lines_after(text, "**Won't build:**")
            .map(str::to_owned)
            .collect(),
        hash: fnv(text),
    }
}

/// Refuse tasks that number a task twice, whose dependencies name a task that is not there, or go round in a cycle.
pub fn check(tasks: &[PlanTask]) -> Result<(), String> {
    for t in tasks {
        if tasks.iter().filter(|o| o.n == t.n).count() > 1 {
            return Err(format!("Task {} appears twice in the plan", t.n));
        }
    }
    for t in tasks {
        for d in &t.deps {
            if !tasks.iter().any(|o| o.n == *d) {
                return Err(format!(
                    "Task {} depends on Task {d}, which the plan does not have",
                    t.n
                ));
            }
        }
    }
    // 0: unseen, 1: visiting, 2: done
    fn visit(
        n: i64,
        tasks: &[PlanTask],
        state: &mut std::collections::HashMap<i64, u8>,
        path: &mut Vec<i64>,
    ) -> Result<(), String> {
        match state.get(&n) {
            Some(2) => return Ok(()),
            Some(1) => {
                path.push(n);
                return Err(format!(
                    "The plan's dependencies go round in a cycle: {}",
                    path.iter()
                        .map(|x| format!("Task {x}"))
                        .collect::<Vec<_>>()
                        .join(" -> ")
                ));
            }
            _ => {}
        }
        state.insert(n, 1);
        path.push(n);
        if let Some(t) = tasks.iter().find(|t| t.n == n) {
            for d in &t.deps {
                visit(*d, tasks, state, path)?;
            }
        }
        path.pop();
        state.insert(n, 2);
        Ok(())
    }
    let mut state = std::collections::HashMap::new();
    for t in tasks {
        visit(t.n, tasks, &mut state, &mut Vec::new())?;
    }
    Ok(())
}

/// Task N of TASKS and every task it depends on, directly or not, in the plan's order (Start as Job).
pub fn needs(tasks: &[PlanTask], n: i64) -> Result<Vec<PlanTask>, String> {
    let mut want: Vec<i64> = Vec::new();
    let mut todo = vec![n];
    while let Some(k) = todo.pop() {
        let Some(t) = tasks.iter().find(|t| t.n == k) else {
            return Err(if k == n {
                format!("The plan has no Task {k}")
            } else {
                format!("A task depends on Task {k}, which the plan does not have")
            });
        };
        if !want.contains(&k) {
            want.push(k);
            todo.extend(t.deps.iter().copied());
        }
    }
    Ok(tasks
        .iter()
        .filter(|t| want.contains(&t.n))
        .cloned()
        .collect())
}

/// The repository of FILE: the nearest directory above it with a `.git`.
pub fn dominating_repo(file: &Path) -> Option<String> {
    let mut dir = file.parent();
    while let Some(d) = dir {
        if d.join(".git").exists() {
            return Some(dir_with_slash(d.to_path_buf()));
        }
        dir = d.parent();
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const PLAN: &str = "# Two tasks\n\n**Repo:** ../repo\n**Won't build:** a thing\n\n## Tasks\n\n### Task 1: Do the thing\n\n**Role:** implement\n\nBody one.\n\n### Task 2. Check it\n\n**Role:** review\n**Depends:** Task 1\n\nCheck.\n";

    #[test]
    fn a_plan_reads_like_the_lisp_reads_it() {
        let p = read(PLAN, Path::new("/w/plans/p.md"));
        assert_eq!(p.title, "Two tasks");
        assert_eq!(p.repo.as_deref(), Some("/w/plans/../repo/"));
        assert_eq!(p.wont_build, ["a thing"]);
        assert_eq!(p.tasks.len(), 2);
        assert_eq!(p.tasks[0].title, "Do the thing");
        assert_eq!(p.tasks[0].body, "**Role:** implement\n\nBody one.");
        assert_eq!(p.tasks[1].role, "review");
        assert_eq!(p.tasks[1].deps, [1]);
        assert_eq!(check(&p.tasks), Ok(()));
    }

    #[test]
    fn a_role_defaults_and_a_title_comes_from_the_file() {
        let p = read("### Task 3: x\n\nnothing\n", Path::new("/w/some-plan.md"));
        assert_eq!(p.title, "some-plan");
        assert_eq!(p.tasks[0].role, "implement");
    }

    #[test]
    fn duplicates_missing_deps_and_cycles_are_refused() {
        let t = |n, deps: &[i64]| PlanTask {
            n,
            title: String::new(),
            role: "implement".into(),
            deps: deps.to_vec(),
            body: String::new(),
        };
        assert!(
            check(&[t(1, &[]), t(1, &[])])
                .unwrap_err()
                .contains("twice")
        );
        assert!(check(&[t(1, &[9])]).unwrap_err().contains("Task 9"));
        let cyc = check(&[t(1, &[2]), t(2, &[1])]).unwrap_err();
        assert!(cyc.contains("cycle"), "{cyc}");
    }

    #[test]
    fn start_as_job_takes_the_task_and_what_it_needs() {
        let p = read(PLAN, Path::new("/w/p.md"));
        let got = needs(&p.tasks, 2).unwrap();
        assert_eq!(got.iter().map(|t| t.n).collect::<Vec<_>>(), [1, 2]);
        assert_eq!(needs(&p.tasks, 1).unwrap().len(), 1);
        assert!(needs(&p.tasks, 7).unwrap_err().contains("no Task 7"));
    }
}
