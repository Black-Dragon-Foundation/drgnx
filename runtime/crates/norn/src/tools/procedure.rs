//! `procedure_get` (`docs/develop/orchestration.md`, "Procedures"): the job's rule pack's procedures (provider-neutral
//! write-ups: executing a plan, red first, debugging, merging by intent), served as a tool because most adapters never
//! show an MCP prompt to the model.  The text is the pack's, frozen with the job at its approval.

use mimir::{BoxFuture, Tool};
use schemars::JsonSchema;
use serde::Deserialize;
use vordr::pack::Pack;

use super::guard::{CoordTool, guarded};
use super::{Coord, Ctx, Identity};

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ProcedureArgs {
    /// The procedure's name; none: the list of the job's procedures.
    #[serde(default)]
    pub name: Option<String>,
}

/// The answer for NAME under the job's PACK: the procedure's text, or the names there are.
pub fn answer(pack: Option<&Pack>, name: Option<&str>) -> Result<String, String> {
    let pack = pack.ok_or("your job has no rule pack, so it has no procedures")?;
    let names = || {
        pack.procedures
            .iter()
            .map(|p| p.name.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    };
    match name {
        None if pack.procedures.is_empty() => Ok("procedures: none".into()),
        None => Ok(format!("procedures: {}", names())),
        Some(n) => pack
            .procedure(n)
            .map(|p| p.text.clone())
            .ok_or_else(|| format!("no procedure {n}; there are: {}", names())),
    }
}

pub struct ProcedureGet;

impl CoordTool for ProcedureGet {
    type Args = ProcedureArgs;
    const NAME: &'static str = "procedure_get";
    const DESCRIPTION: &'static str = "One of your job's procedures (how this project executes a plan, works red first, \
        debugs, merges by intent) by name; without a name, the names there are.";

    fn run<'a>(
        &'a self,
        coord: &'a Coord,
        who: &'a Identity,
        args: ProcedureArgs,
    ) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            let job = who
                .job()
                .ok_or("procedures are a job's: this session works for none")?
                .to_owned();
            let pack = coord
                .db()
                .read(move |c| crate::read::evidence::pack_of_job(c, &job))
                .await
                .map_err(|e| format!("{e:?}"))?;
            answer(pack.as_ref(), args.name.as_deref())
        })
    }
}

/// This file's tools.
pub fn tools() -> Vec<Box<dyn Tool<Ctx>>> {
    vec![guarded(ProcedureGet)]
}

#[cfg(test)]
mod tests {
    use super::*;
    use vordr::pack::Procedure;

    /// [D] A named procedure answers its text; no name lists the names; an unknown name says which there are; a job
    /// without a pack, or a pack without procedures, says so.
    #[test]
    fn a_procedure_by_name_or_the_list() {
        let pack = Pack {
            name: "p".into(),
            procedures: vec![
                Procedure {
                    name: "red-first".into(),
                    text: "Write the test.".into(),
                    ..Procedure::default()
                },
                Procedure {
                    name: "debugging".into(),
                    text: "Find the cause.".into(),
                    ..Procedure::default()
                },
            ],
            ..Pack::default()
        };
        assert_eq!(
            answer(Some(&pack), Some("red-first")).unwrap(),
            "Write the test."
        );
        assert_eq!(
            answer(Some(&pack), None).unwrap(),
            "procedures: red-first, debugging"
        );
        let e = answer(Some(&pack), Some("nope")).unwrap_err();
        assert!(
            e.contains("no procedure nope") && e.contains("red-first, debugging"),
            "{e}"
        );
        assert!(answer(None, None).unwrap_err().contains("no rule pack"));
        let empty = Pack::default();
        assert!(answer(Some(&empty), None).unwrap().contains("none"));
    }
}
