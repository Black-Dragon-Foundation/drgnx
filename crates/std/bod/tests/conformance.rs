//! The commands standard's conformance test: every command registered at link time has a title and a doc, is in
//! the palette's list, and, when exposed to agents, is a tool; the registry's rules (docs/develop/standards/commands.md).

use bod::{
    ArgSpec, Command, CommandId, Cx, Exposure, Origin, Registry, SourceLoc, advice, handler,
    tool_specs,
};
use serde_json::{Value, json};

const SAVE_AT: u32 = line!() + 1;
bod::command! {
    id: "buffer.save",
    title: "Save buffer",
    doc: "Write the buffer to its file.",
    args: ArgSpec::NONE,
    exposure: Exposure::Palette,
    handler: |_cx, _args| Ok(json!("saved")),
}

bod::command! {
    id: "agent.echo",
    title: "Echo",
    doc: "Give the text back.",
    args: ArgSpec { args: &[("text", "what to echo")] },
    exposure: Exposure::Agent,
    handler: |_cx, args| Ok(args["text"].clone()),
}

bod::command! {
    id: "key.only",
    title: "A key-only command",
    doc: "Reached by a key alone.",
    args: ArgSpec::NONE,
    exposure: Exposure::KeyOnly,
    handler: |_cx, _args| Ok(Value::Null),
}

fn cmd(id: &'static str, exposure: Exposure) -> Command {
    Command {
        id: CommandId(id),
        title: "A title",
        doc: "A doc.",
        args: ArgSpec::NONE,
        source: SourceLoc {
            file: file!(),
            line: line!(),
        },
        exposure,
    }
}

#[test]
fn every_registered_command_has_a_title_a_doc_and_a_listing() {
    let r = Registry::linked().expect("the linked commands register");
    assert!(r.list().count() >= 3);
    let palette: Vec<&str> = r.palette().iter().map(|c| c.id.0).collect();
    for c in r.list() {
        assert!(!c.title.trim().is_empty(), "{} has no title", c.id);
        assert!(!c.doc.trim().is_empty(), "{} has no doc", c.id);
        assert_eq!(
            palette.contains(&c.id.0),
            c.exposure != Exposure::KeyOnly,
            "{} is in the palette list exactly when it is not key-only",
            c.id
        );
    }
}

#[test]
fn agent_exposed_command_is_an_mcp_tool() {
    let r = Registry::linked().expect("registers");
    let tools = tool_specs(&r);
    let names: Vec<&str> = tools.iter().map(|t| t.name.as_str()).collect();
    assert_eq!(
        names,
        ["agent.echo"],
        "only the agent-exposed command is a tool"
    );
    assert!(tools[0].description.contains("Echo"));
    assert_eq!(tools[0].input_schema["required"], json!(["text"]));
    assert_eq!(
        tools[0].input_schema["properties"]["text"]["description"],
        "what to echo"
    );
    // and an agent can run it, but not the palette's command
    let mut cx = Cx::agent("a1");
    assert_eq!(
        r.run("agent.echo", json!({"text": "hi"}), &mut cx)
            .expect("runs"),
        json!("hi")
    );
    let e = r
        .run("buffer.save", Value::Null, &mut cx)
        .expect_err("not open to agents");
    assert_eq!(e.kind(), villa::Kind::Refused);
    assert!(r.run("buffer.save", Value::Null, &mut Cx::user()).is_ok());
}

#[test]
fn find_source_points_at_definition() {
    let r = Registry::linked().expect("registers");
    let at = r.find_source("buffer.save").expect("known");
    assert_eq!(at.file, file!());
    assert_eq!(at.line, SAVE_AT);
    assert_eq!(
        r.find_source("nope").expect_err("unknown").kind(),
        villa::Kind::NotFound
    );
}

#[test]
fn duplicate_id_is_conflict() {
    let mut r = Registry::new();
    r.register(
        cmd("a.b", Exposure::Palette),
        handler(|_, _| Ok(Value::Null)),
    )
    .expect("first");
    let e = r
        .register(
            cmd("a.b", Exposure::Palette),
            handler(|_, _| Ok(Value::Null)),
        )
        .expect_err("second");
    assert_eq!(e.kind(), villa::Kind::Conflict);
    assert!(
        e.detail().is_some_and(|d| d.contains("first defined at")),
        "{e:?}"
    );
    // the linked set has one `buffer.save`, so linking it twice into one registry conflicts
    let mut linked = Registry::linked().expect("registers");
    let again = linked.register(
        cmd("buffer.save", Exposure::Palette),
        handler(|_, _| Ok(Value::Null)),
    );
    assert_eq!(again.expect_err("conflict").kind(), villa::Kind::Conflict);
}

#[test]
fn a_command_without_a_title_or_doc_is_refused() {
    let mut r = Registry::new();
    let mut c = cmd("x.y", Exposure::Palette);
    c.doc = "  ";
    assert_eq!(
        r.register(c, handler(|_, _| Ok(Value::Null)))
            .expect_err("no doc")
            .kind(),
        villa::Kind::Invalid
    );
}

#[test]
fn advice_wraps_and_unwraps() {
    let mut r = Registry::new();
    r.register(
        cmd("math.double", Exposure::Palette),
        handler(|_, args| Ok(json!(args.as_i64().unwrap_or(0) * 2))),
    )
    .expect("registers");
    let run = |r: &Registry, n: i64| {
        r.run("math.double", json!(n), &mut Cx::user())
            .expect("runs")
    };
    assert_eq!(run(&r, 5), json!(10));

    // the first advice adds one to the argument; the second (outside it) negates the result
    let plus = r
        .advise(
            "math.double",
            advice(|cx, args, next| next(cx, json!(args.as_i64().unwrap_or(0) + 1))),
        )
        .expect("advises");
    assert_eq!(run(&r, 5), json!(12));
    let neg = r
        .advise(
            "math.double",
            advice(|cx, args, next| {
                let v = next(cx, args)?;
                Ok(json!(-v.as_i64().unwrap_or(0)))
            }),
        )
        .expect("advises");
    assert_eq!(run(&r, 5), json!(-12));
    r.unadvise(plus).expect("unwraps the inner");
    assert_eq!(run(&r, 5), json!(-10));
    r.unadvise(neg).expect("unwraps the outer");
    assert_eq!(run(&r, 5), json!(10));
    assert_eq!(
        r.unadvise(neg).expect_err("twice").kind(),
        villa::Kind::NotFound
    );
    assert_eq!(
        r.advise("nope", advice(|cx, a, next| next(cx, a)))
            .expect_err("no command")
            .kind(),
        villa::Kind::NotFound
    );
    // the origin reaches the handler and the advice
    assert!(matches!(Cx::agent("x").origin, Origin::Agent(_)));
}
