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
    args: ArgSpec::of(&[("text", "what to echo")]),
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
        id: CommandId::from(id),
        title: "A title".to_string(),
        doc: "A doc.".to_string(),
        args: ArgSpec::NONE,
        source: SourceLoc {
            file: file!().to_string(),
            line: line!(),
        },
        exposure,
    }
}

#[test]
fn every_registered_command_has_a_title_a_doc_and_a_listing() {
    let r = Registry::linked().expect("the linked commands register");
    assert!(r.list().count() >= 3);
    let palette: Vec<&str> = r.palette().iter().map(|c| c.id.0.as_str()).collect();
    for c in r.list() {
        assert!(!c.title.trim().is_empty(), "{} has no title", c.id);
        assert!(!c.doc.trim().is_empty(), "{} has no doc", c.id);
        assert_eq!(
            palette.contains(&c.id.0.as_str()),
            !matches!(c.exposure, Exposure::KeyOnly | Exposure::Extension),
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
    c.doc = "  ".to_string();
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

    // the first advice adds one to the argument; the second (outside it) triples the argument first
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
            advice(|cx, args, next| next(cx, json!(args.as_i64().unwrap_or(0) * 3))),
        )
        .expect("advises");
    assert_eq!(run(&r, 5), json!(32), "outer first: (5 * 3 + 1) * 2");
    r.unadvise(plus).expect("unwraps the inner");
    assert_eq!(run(&r, 5), json!(30));
    r.unadvise(neg.clone()).expect("unwraps the outer");
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

#[test]
fn an_extension_runs_only_what_is_exposed_to_extensions_and_an_agent_cannot_borrow_it() {
    let mut r = Registry::new();
    for (id, exposure) in [
        ("p.palette", Exposure::Palette),
        ("p.agent", Exposure::Agent),
        ("p.ext", Exposure::Extension),
    ] {
        r.register(cmd(id, exposure), handler(|_, _| Ok(json!("ran"))))
            .expect("registers");
    }
    let by_ext = |origin: Origin| Cx::through_extension(origin, "vim");
    // an extension acting for the user: only the extension command
    assert_eq!(
        r.run("p.ext", Value::Null, &mut by_ext(Origin::User))
            .expect("runs"),
        json!("ran")
    );
    for id in ["p.palette", "p.agent"] {
        assert_eq!(
            r.run(id, Value::Null, &mut by_ext(Origin::User))
                .expect_err("not for extensions")
                .kind(),
            villa::Kind::Refused,
            "{id}"
        );
    }
    // the confused deputy: an agent has the extension run a command; the agent's origin goes through, so the command
    // must pass the agent door too, which an extension command does not
    for id in ["p.ext", "p.agent", "p.palette"] {
        assert_eq!(
            r.run(id, Value::Null, &mut by_ext(Origin::Agent("a1".into())))
                .expect_err("two doors")
                .kind(),
            villa::Kind::Refused,
            "{id}"
        );
    }
    // an extension command is neither in the palette's list nor a tool
    assert!(r.palette().iter().all(|c| c.id.0 != "p.ext"));
    assert!(tool_specs(&r).iter().all(|t| t.name != "p.ext"));
}
