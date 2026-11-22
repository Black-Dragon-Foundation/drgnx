//! Task 14: the C door, through `smidja_call` itself (flat values in and out).
use smidja::abi::*;

fn sy(s: &str) -> Val {
    Val::Sym(s.to_string())
}
fn st(s: &str) -> Val {
    Val::Str(s.to_string())
}
fn l(xs: Vec<Val>) -> Val {
    Val::List(xs)
}
fn i(x: i64) -> Val {
    Val::Int(x)
}

fn call(op: &str, args: Vec<Val>) -> Val {
    let n = op_number(op);
    assert!(n >= 0, "no op {op}");
    call_flat(n, &args).unwrap_or_else(|c| panic!("{op} failed with code {c}"))
}

fn refused(v: &Val) -> bool {
    matches!(v, Val::List(xs) if xs.first() == Some(&sy("refused")))
}

/// Each call answers, and the intents a fresh window allows are not refused; the ids in answers round-trip into the
/// next calls.
#[test]
fn abi_round_trips_every_op() {
    let mut seen = std::collections::BTreeSet::new();
    let mut c = |op: &str, args: Vec<Val>| {
        seen.insert(op.to_string());
        call(op, args)
    };
    c("reset", vec![]);
    assert_eq!(c("trace", vec![sy("t")]), l(vec![]));
    for d in [
        l(vec![sy("place"), st("p1"), sy(":icon"), st("i")]),
        l(vec![
            sy("place"),
            st("p2"),
            sy(":home"),
            st("k2"),
            sy(":foot"),
            sy("t"),
        ]),
        l(vec![
            sy("page-kind"),
            st("k1"),
            sy(":title"),
            st("K one"),
            sy(":place"),
            st("p1"),
        ]),
        l(vec![sy("page-kind"), st("k2")]),
        l(vec![sy("selection-kind"), st("s1")]),
        l(vec![sy("bottom-kind"), st("b1")]),
        l(vec![sy("tab-kind"), st("t1")]),
        l(vec![
            sy("preset"),
            st("pr"),
            sy(":center"),
            l(vec![sy("page"), st("k1")]),
            sy(":left"),
            l(vec![sy("show"), st("p1")]),
            sy(":bottom"),
            sy("hide"),
        ]),
    ] {
        assert!(matches!(c("declare", vec![d]), Val::Int(_)));
    }
    assert!(matches!(
        c("set_monitors", vec![l(vec![st("m0"), st("m1")])]),
        Val::Int(_)
    ));
    let Val::Int(w) = c(
        "window_new",
        vec![
            st("m0"),
            l(vec![sy("px"), i(1920), i(1080)]),
            Val::Float(1.0),
            Val::Nil,
        ],
    ) else {
        panic!("no window")
    };
    let u = sy("user");
    let ok = |v: &Val| assert!(!refused(v), "refused: {v:?}");
    ok(&c(
        "set_window_size",
        vec![i(w), l(vec![sy("px"), i(1920), i(1080)]), Val::Float(1.0)],
    ));
    let file = |p: &str| l(vec![sy("file"), st(p), Val::Nil]);
    let Val::List(o) = c(
        "open",
        vec![
            i(w),
            file("/a.rs"),
            sy("pin"),
            l(vec![sy(":focus"), sy("t")]),
            u.clone(),
        ],
    ) else {
        panic!()
    };
    let Val::Int(t) = o[1] else {
        panic!("no tab: {o:?}")
    };
    let Val::List(o2) = c(
        "open",
        vec![i(w), file("/b.rs"), sy("pin"), l(vec![]), u.clone()],
    ) else {
        panic!()
    };
    let Val::Int(t2) = o2[1] else { panic!() };
    ok(&c(
        "update_tab",
        vec![
            i(t),
            l(vec![sy(":title"), st("a.rs"), sy(":dirty"), sy("t")]),
        ],
    ));
    ok(&c("pin", vec![i(t), u.clone()]));
    let real = c("realisation", vec![i(w)]);
    let Val::List(r) = &real else { panic!() };
    assert_eq!(r[0], sy(":version"));
    let groups = &r[r.iter().position(|x| *x == sy(":groups")).unwrap() + 1];
    let Val::List(gs) = groups else { panic!() };
    let Val::List(g0) = &gs[0] else { panic!() };
    let Val::Int(g) = g0[0] else { panic!() };
    ok(&c(
        "select",
        vec![i(w), st("s1"), st("x"), sy("left"), u.clone()],
    ));
    ok(&c("pin_detail", vec![i(w), sy("t"), u.clone()]));
    ok(&c(
        "show_context",
        vec![i(w), sy("detail"), sy("t"), u.clone()],
    ));
    ok(&c("navigate", vec![i(w), st("p1"), u.clone()]));
    ok(&c(
        "set_place_state",
        vec![i(w), st("p1"), l(vec![sy(":scroll"), i(3)]), u.clone()],
    ));
    let Val::List(ov) = c("overlay", vec![i(w), sy("palette"), st("spec"), u.clone()]) else {
        panic!()
    };
    ok(&c("dismiss", vec![i(w), ov[1].clone(), u.clone()]));
    ok(&c(
        "focus",
        vec![i(w), l(vec![sy("group"), i(g)]), u.clone()],
    ));
    ok(&c(
        "focus",
        vec![i(w), l(vec![sy("group"), i(g)]), u.clone(), sy("key")],
    ));
    ok(&c("cycle_region", vec![i(w), sy("next"), u.clone()]));
    ok(&c("side", vec![i(w), sy("right"), sy("show"), u.clone()]));
    ok(&c("resize", vec![i(w), sy("left"), i(300), u.clone()]));
    ok(&c("bottom", vec![i(w), st("b1"), sy("show"), u.clone()]));
    ok(&c("bottom", vec![i(w), st("b1"), sy("hide"), u.clone()]));
    let Val::List(sp) = c("split", vec![i(g), sy("right"), u.clone()]) else {
        panic!()
    };
    let Val::Int(g2) = sp[1] else {
        panic!("{sp:?}")
    };
    ok(&c(
        "move_tab",
        vec![i(t2), l(vec![sy("group"), i(g2)]), u.clone()],
    ));
    ok(&c("swap", vec![i(g), sy("right"), u.clone()]));
    ok(&c("focus_dir", vec![i(w), sy("left"), u.clone()]));
    ok(&c(
        "resize_split",
        vec![
            i(w),
            l(vec![]),
            l(vec![Val::Float(0.4), Val::Float(0.6)]),
            u.clone(),
        ],
    ));
    ok(&c("full_size", vec![i(w), u.clone()]));
    ok(&c("full_size", vec![i(w), u.clone()]));
    ok(&c("stack", vec![i(g2), sy("left"), u.clone()]));
    ok(&c("restore_previous_layout", vec![i(w), u.clone()]));
    let Val::List(gl) = c("query", vec![i(w), st("groups")]) else {
        panic!()
    };
    assert!(!gl.is_empty());
    ok(&c("apply_preset", vec![i(w), st("pr"), u.clone()]));
    ok(&c("next_layout", vec![i(w), u.clone()]));
    ok(&c("set_project", vec![i(w), st("proj")]));
    ok(&c(
        "save_project_layout",
        vec![i(w), st("proj"), st("mine"), u.clone()],
    ));
    assert!(matches!(
        c(
            "set_attention",
            vec![i(2), l(vec![l(vec![st("agent"), i(2)])])]
        ),
        Val::Int(_)
    ));
    let Val::Int(ver) = c("version", vec![]) else {
        panic!()
    };
    let edges = l(vec![l(vec![
        l(vec![sy("region"), sy("left")]),
        l(vec![i(50), i(38), i(272), i(900)]),
    ])]);
    assert_eq!(c("set_edges", vec![i(w), i(ver), edges]), sy("t"));
    let Val::List(r) = c("realisation", vec![i(w)]) else {
        panic!()
    };
    let Val::List(gs) = &r[r.iter().position(|x| *x == sy(":groups")).unwrap() + 1] else {
        panic!()
    };
    let Val::List(g0) = &gs[0] else { panic!() };
    let Val::Int(ga) = g0[0] else { panic!() };
    let Val::List(tl) = c(
        "begin_temp_layout",
        vec![i(ga), st("tool"), st("Tool"), u.clone()],
    ) else {
        panic!()
    };
    assert!(matches!(tl[1], Val::Int(_)), "{tl:?}");
    ok(&c("end_temp_layout", vec![i(ga)]));
    assert!(matches!(c("buffer_gone", vec![st("nobuf")]), Val::Int(_)));
    assert_eq!(c("chrome", vec![i(w)]), Val::Nil);
    assert!(matches!(c("roles", vec![i(w)]), Val::List(_)));
    assert!(matches!(c("fold", vec![i(w)]), Val::List(_)));
    let Val::Int(snap) = c("snapshot", vec![]) else {
        panic!()
    };
    ok(&c("close", vec![i(t), u.clone()]));
    ok(&c("reopen_closed", vec![i(w), u.clone()]));
    assert!(matches!(c("restore", vec![i(snap)]), Val::Int(_)));
    let Val::Str(text) = c("save", vec![Val::Nil]) else {
        panic!()
    };
    assert!(text.starts_with("smidja-layout 1"), "{text}");
    let Val::List(tw) = c("tear_out", vec![l(vec![sy("tab"), i(t2)]), u.clone()]) else {
        panic!()
    };
    let Val::Int(w2) = tw[1] else {
        panic!("{tw:?}")
    };
    ok(&c("window_close", vec![i(w2), u.clone()]));
    ok(&c("close_group", vec![i(ga), u.clone()]));
    c("reset", vec![]);
    let Val::List(ws) = c("load", vec![st(&text)]) else {
        panic!()
    };
    assert!(!ws.is_empty());
    assert!(matches!(c("pending_refs", vec![]), Val::List(_)));
    c("resolve", vec![file("/a.rs"), sy("now")]);
    assert!(matches!(c("restore_tick", vec![]), Val::Int(_)));
    assert!(matches!(c("take_notices", vec![]), Val::List(_)));
    let Val::List(tr) = c("trace", vec![Val::Nil]) else {
        panic!()
    };
    assert!(tr.len() > 40, "the trace kept {} calls", tr.len());
    for op in &OPS[..SECTION_12] {
        assert!(seen.contains(*op), "{op} not called");
    }
    for op in OPS {
        assert!(seen.contains(*op), "{op} not called");
    }
}

#[test]
fn abi_rejects_bad_utf8() {
    let bad = [0xffu8, 0xfe];
    let v = SmidjaVal {
        tag: SMIDJA_STR,
        int_: 0,
        float_: 0.0,
        ptr: bad.as_ptr(),
        len: bad.len(),
    };
    assert_eq!(call_raw(op_number("buffer_gone"), &[v]), Err(SMIDJA_E_ARG));
    let sym = SmidjaVal {
        tag: SMIDJA_SYM,
        ..v
    };
    assert_eq!(call_raw(op_number("version"), &[sym]), Err(SMIDJA_E_ARG));
    // an unknown op and a bad argument kind are told apart
    assert_eq!(call_flat(9999, &[]), Err(SMIDJA_E_OP));
    assert_eq!(op_number("no_such_op"), -1);
    assert_eq!(call_flat(op_number("pin"), &[st("x")]), Err(SMIDJA_E_ARG));
}

/// A refused intent answers `(refused REASON)`, not a code.
#[test]
fn a_refusal_is_an_answer_with_its_reason() {
    call("reset", vec![]);
    let v = call("apply_preset", vec![i(1), st("nope"), sy("user")]);
    let Val::List(xs) = v else { panic!() };
    assert_eq!(xs[0], sy("refused"));
    assert!(matches!(&xs[1], Val::Str(s) if !s.is_empty()));
}

/// `query W "sections" REGION` answers `(PLACE (ID TITLE SIZE) ...)` for the region's current place, a lone section
/// still a list of one row (W5, Task 27's section windows).
#[test]
fn sections_query_answers_the_current_places_sections() {
    call("reset", vec![]);
    for d in [
        l(vec![
            sy("place"),
            st("one"),
            sy(":sections"),
            l(vec![st("Files")]),
        ]),
        l(vec![
            sy("place"),
            st("two"),
            sy(":sections"),
            l(vec![st("Open"), st("Outline")]),
        ]),
    ] {
        call("declare", vec![d]);
    }
    call("set_monitors", vec![l(vec![st("m0")])]);
    let Val::Int(w) = call(
        "window_new",
        vec![
            st("m0"),
            l(vec![sy("px"), i(1920), i(1080)]),
            Val::Float(1.0),
            Val::Nil,
        ],
    ) else {
        panic!("no window")
    };
    let u = sy("user");
    // the first place declared is the left's at first (navigating to it again would hide the left)
    let Val::List(one) = call("query", vec![i(w), st("sections"), sy("left")]) else {
        panic!("not a list")
    };
    assert_eq!(one.len(), 2, "the place and one row: {one:?}");
    assert_eq!(one[0], st("one"));
    let Val::List(row) = &one[1] else {
        panic!("a lone row is a list: {one:?}")
    };
    assert_eq!(row[0], i(0));
    assert_eq!(row[1], st("Files"));
    assert!(matches!(row[2], Val::Int(h) if h > 0), "a size: {row:?}");
    call("navigate", vec![i(w), st("two"), u]);
    let Val::List(two) = call("query", vec![i(w), st("sections"), sy("left")]) else {
        panic!("not a list")
    };
    assert_eq!(two[0], st("two"));
    let titles: Vec<&Val> = two[1..]
        .iter()
        .map(|r| match r {
            Val::List(x) => &x[1],
            _ => panic!("{r:?}"),
        })
        .collect();
    assert_eq!(titles, [&st("Open"), &st("Outline")]);
    let Val::List(r1) = &two[2] else { panic!() };
    assert_eq!(r1[0], i(1));
}
