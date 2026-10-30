use super::*;
use proptest::prelude::*;

fn who(role: Role) -> Who {
    Who {
        role: Some(role),
        ..Who::default()
    }
}

fn cell(v: Verdict) -> Cell {
    Cell {
        verdict: v,
        limit: None,
    }
}

fn eff(layers: &[&Matrix], w: &Who) -> Effective {
    effective(layers, w)
}

#[test]
fn balanced_is_the_mockups_table() {
    use Action::*;
    use Verdict::*;
    let p = preset(Preset::Balanced);
    let rows: [(Action, [Verdict; 3]); 22] = [
        (AgentsStart, [Allow, Never, Never]),
        (AgentsModel, [Allow, Never, Never]),
        (AgentsControl, [Allow, Never, Never]),
        (GraphChange, [Allow, Allow, Never]),
        (TaskDone, [Ask, Never, Never]),
        (Spend, [Allow, Allow, Allow]),
        (SpendOver, [Ask, Never, Ask]),
        (CodeRead, [Allow, Allow, Ask]),
        (CodeEdit, [Allow, Allow, Never]),
        (Commit, [Allow, Allow, Never]),
        (MergeIntegration, [Allow, Never, Never]),
        (PushCi, [Allow, Never, Never]),
        (PushMain, [Ask, Never, Never]),
        (CodeCiConfig, [Ask, Ask, Never]),
        (Machines, [Allow, Allow, Never]),
        (JobContainer, [Allow, Allow, Never]),
        (Network, [Allow, Allow, Allow]),
        (Unsandboxed, [Never, Never, Never]),
        (SettingsChange, [Ask, Ask, Ask]),
        (UserPrivate, [Never, Never, Never]),
        (UserEmacs, [Ask, Never, Never]),
        (ChatProjectRead, [Never, Never, Ask]),
    ];
    assert_eq!(p.cells.len(), 22 * 3);
    for (a, vs) in rows {
        for (r, want) in [Role::Manager, Role::Worker, Role::Chat]
            .into_iter()
            .zip(vs)
        {
            assert_eq!(
                p.cells[&(a, Column::Role(r))].verdict,
                want,
                "{} {r:?}",
                a.id()
            );
        }
    }
    let m = |a| p.cells[&(a, Column::Role(Role::Manager))].limit;
    let lim = |amount, unit| Some(Limit { amount, unit });
    assert_eq!(m(AgentsStart), lim(4.0, Unit::Count));
    assert_eq!(m(Spend), lim(40.0, Unit::Usd));
    let c = |a| p.cells[&(a, Column::Role(Role::Chat))].limit;
    assert_eq!(c(Spend), lim(2.0, Unit::Usd));
}

#[test]
fn job_container_follows_the_users_call() {
    let jc = |p, r| preset(p).cells[&(Action::JobContainer, Column::Role(r))].verdict;
    for r in [Role::Manager, Role::Worker] {
        assert_eq!(jc(Preset::Balanced, r), Verdict::Allow);
        assert_eq!(jc(Preset::Autonomous, r), Verdict::Allow);
        assert_eq!(jc(Preset::Cautious, r), Verdict::Ask);
    }
    for p in [Preset::Cautious, Preset::Balanced, Preset::Autonomous] {
        assert_eq!(jc(p, Role::Chat), Verdict::Never);
    }
}

#[test]
fn never_beats_ask_beats_allow_across_columns() {
    for (a, b, want) in [
        (Verdict::Allow, Verdict::Ask, Verdict::Ask),
        (Verdict::Ask, Verdict::Never, Verdict::Never),
        (Verdict::Allow, Verdict::Never, Verdict::Never),
        (Verdict::Allow, Verdict::Allow, Verdict::Allow),
    ] {
        for (x, y) in [(a, b), (b, a)] {
            let mut m = Matrix::default();
            m.set(Action::CodeEdit, Column::Role(Role::Worker), cell(x));
            m.set(Action::CodeEdit, agent_column("a"), cell(y));
            let w = Who {
                role: Some(Role::Worker),
                agent: Some("a".into()),
                provider: None,
            };
            assert_eq!(eff(&[&m], &w).cell(Action::CodeEdit).verdict, want);
        }
    }
}

#[test]
fn a_provider_column_cannot_widen_a_role() {
    let base = preset(Preset::Balanced);
    let mut over = Matrix::default();
    over.set(
        Action::PushMain,
        provider_column("codex"),
        cell(Verdict::Allow),
    );
    over.set(
        Action::PushCi,
        provider_column("codex"),
        cell(Verdict::Never),
    );
    let w = Who {
        role: Some(Role::Manager),
        agent: None,
        provider: Some("codex".into()),
    };
    let e = eff(&[&base, &over], &w);
    assert_eq!(decide(&e, Action::PushMain, None), Verdict::Ask);
    assert_eq!(decide(&e, Action::PushCi, None), Verdict::Never);
    // another provider is untouched
    let other = Who {
        provider: Some("claude".into()),
        ..who(Role::Manager)
    };
    assert_eq!(
        decide(&eff(&[&base, &over], &other), Action::PushCi, None),
        Verdict::Allow
    );
}

#[test]
fn unsandboxed_and_private_stay_never_under_any_override() {
    let mut over = Matrix::default();
    for r in [Role::Manager, Role::Worker, Role::Chat] {
        for a in [Action::Unsandboxed, Action::UserPrivate] {
            over.set(a, Column::Role(r), cell(Verdict::Allow));
            over.set(a, agent_column("x"), cell(Verdict::Allow));
        }
    }
    for p in [Preset::Cautious, Preset::Balanced, Preset::Autonomous] {
        let base = preset(p);
        for r in [Role::Manager, Role::Worker, Role::Chat] {
            let w = Who {
                agent: Some("x".into()),
                ..who(r)
            };
            let e = eff(&[&base, &over], &w);
            for a in [Action::Unsandboxed, Action::UserPrivate] {
                assert_eq!(decide(&e, a, None), Verdict::Never);
                assert_eq!(e.cell(a).verdict, Verdict::Never);
            }
        }
    }
}

#[test]
fn later_layers_replace_cells_and_missing_cells_are_never() {
    let base = preset(Preset::Balanced);
    let mut project = Matrix::default();
    project.set(
        Action::PushMain,
        Column::Role(Role::Manager),
        cell(Verdict::Never),
    );
    let e = eff(&[&base, &project], &who(Role::Manager));
    assert_eq!(decide(&e, Action::PushMain, None), Verdict::Never);
    assert_eq!(
        decide(&Effective::default(), Action::CodeRead, None),
        Verdict::Never
    );
}

#[test]
fn over_the_limit_asks_only_if_spend_over_allows_asking() {
    let base = preset(Preset::Balanced);
    let e = eff(&[&base], &who(Role::Manager));
    assert_eq!(decide(&e, Action::Spend, Some(40.0)), Verdict::Allow);
    assert_eq!(decide(&e, Action::Spend, Some(40.5)), Verdict::Ask);
    assert_eq!(decide(&e, Action::Spend, Some(f64::NAN)), Verdict::Ask);
    let w = eff(&[&base], &who(Role::Worker));
    assert_eq!(decide(&w, Action::Spend, Some(11.0)), Verdict::Never);
}

#[test]
fn limits_compare_only_in_the_same_unit() {
    let lim = |amount, unit| Cell {
        verdict: Verdict::Allow,
        limit: Some(Limit { amount, unit }),
    };
    // combination: same unit takes the smaller, different units fall back to Ask without a limit
    let mut m = Matrix::default();
    m.set(
        Action::Spend,
        Column::Role(Role::Manager),
        lim(40.0, Unit::Usd),
    );
    m.set(Action::Spend, agent_column("a"), lim(10.0, Unit::Usd));
    m.set(
        Action::Spend,
        provider_column("p"),
        lim(0.3, Unit::LimitShare),
    );
    let w = |agent: bool, prov: bool| Who {
        role: Some(Role::Manager),
        agent: agent.then(|| "a".to_string()),
        provider: prov.then(|| "p".to_string()),
    };
    assert_eq!(
        eff(&[&m], &w(true, false)).cell(Action::Spend),
        lim(10.0, Unit::Usd)
    );
    let mixed = eff(&[&m], &w(true, true)).cell(Action::Spend);
    assert_eq!((mixed.verdict, mixed.limit), (Verdict::Ask, None));
    // narrowing: a child in another unit, or with no limit, is wider
    let parent = eff(&[&m], &w(false, false));
    for child in [
        lim(1.0, Unit::UsdEst),
        Cell {
            limit: None,
            ..lim(1.0, Unit::Usd)
        },
    ] {
        let c = Effective {
            cells: [(Action::Spend, child)].into(),
        };
        assert_eq!(
            narrow(&parent, &c),
            Err(Widening {
                action: Action::Spend
            })
        );
    }
    let ok = Effective {
        cells: [(Action::Spend, lim(5.0, Unit::Usd))].into(),
    };
    assert!(narrow(&parent, &ok).is_ok());
}

#[test]
fn time_presets_pick_by_away_then_hours() {
    let t = [
        TimePreset {
            when: When::Between(22 * 60, 6 * 60),
            preset: Preset::Autonomous,
        },
        TimePreset {
            when: When::Away,
            preset: Preset::Cautious,
        },
    ];
    let b = Preset::Balanced;
    assert_eq!(active(b, &t, false, 12 * 60), Preset::Balanced);
    assert_eq!(active(b, &t, false, 23 * 60), Preset::Autonomous);
    assert_eq!(active(b, &t, false, 5 * 60 + 59), Preset::Autonomous);
    assert_eq!(active(b, &t, false, 6 * 60), Preset::Balanced);
    assert_eq!(active(b, &t, true, 12 * 60), Preset::Cautious);
    assert_eq!(active(b, &t, true, 23 * 60), Preset::Cautious);
    assert_eq!(active(b, &[], true, 0), Preset::Balanced);
    let day = [TimePreset {
        when: When::Between(9 * 60, 17 * 60),
        preset: Preset::Cautious,
    }];
    assert_eq!(active(b, &day, false, 9 * 60), Preset::Cautious);
    assert_eq!(active(b, &day, false, 17 * 60), Preset::Balanced);
}

fn arb_cell() -> impl Strategy<Value = Cell> {
    let verdict = prop_oneof![
        Just(Verdict::Allow),
        Just(Verdict::Ask),
        Just(Verdict::Never)
    ];
    let limit = proptest::option::of(
        (
            0u8..4,
            prop_oneof![Just(Unit::Count), Just(Unit::Usd), Just(Unit::Tokens)],
        )
            .prop_map(|(a, unit)| Limit {
                amount: f64::from(a),
                unit,
            }),
    );
    (verdict, limit).prop_map(|(verdict, limit)| Cell { verdict, limit })
}

fn arb_eff() -> impl Strategy<Value = Effective> {
    proptest::collection::vec(proptest::option::of(arb_cell()), Action::ALL.len()).prop_map(|cs| {
        Effective {
            cells: Action::ALL
                .into_iter()
                .zip(cs)
                .filter_map(|(a, c)| c.map(|c| (a, c)))
                .collect(),
        }
    })
}

proptest! {
    #[test]
    fn narrow_refuses_any_wider_cell(parent in arb_eff(), child in arb_eff()) {
        if narrow(&parent, &child).is_ok() {
            for a in Action::ALL {
                let (c, p) = (child.cell(a), parent.cell(a));
                if c.verdict == Verdict::Never { continue; }
                prop_assert!(c.verdict >= p.verdict, "{}", a.id());
                if let Some(pl) = p.limit {
                    let cl = c.limit.expect("a limited parent needs a limited child");
                    prop_assert_eq!(cl.unit, pl.unit);
                    prop_assert!(cl.amount <= pl.amount);
                }
            }
        }
        // and a child never wider than itself, an empty child always fits
        prop_assert!(narrow(&parent, &parent).is_ok());
        prop_assert!(narrow(&parent, &Effective::default()).is_ok());
    }
}

#[test]
fn who_from_the_wire_keeps_every_column() {
    let w = WhoParam {
        role: Some(Role::Worker),
        agent: Some(Bounded("a".to_string())),
        provider: Some(Bounded("p".to_string())),
    };
    assert_eq!(
        Who::from(&w),
        Who {
            role: Some(Role::Worker),
            agent: Some("a".into()),
            provider: Some("p".into()),
        }
    );
}

#[test]
fn meet_is_the_tighter_cell_at_every_action() {
    let x = Effective {
        cells: [(Action::CodeEdit, cell(Verdict::Allow))].into(),
    };
    let y = Effective {
        cells: [
            (Action::CodeEdit, cell(Verdict::Ask)),
            (Action::CodeRead, cell(Verdict::Allow)),
        ]
        .into(),
    };
    let m = meet(&x, &y);
    assert_eq!(m.cell(Action::CodeEdit).verdict, Verdict::Ask);
    // an action one side lacks is Never there, so Never in the meet
    assert_eq!(m.cell(Action::CodeRead).verdict, Verdict::Never);
    assert_eq!(m.cells.len(), Action::ALL.len());
}

#[test]
fn a_never_row_stays_never_in_a_cell_that_says_allow() {
    // `decide` guards the rows itself, whatever the cells it is handed say
    let e = Effective {
        cells: [
            (Action::Unsandboxed, cell(Verdict::Allow)),
            (Action::UserPrivate, cell(Verdict::Ask)),
        ]
        .into(),
    };
    assert_eq!(decide(&e, Action::Unsandboxed, None), Verdict::Never);
    assert_eq!(decide(&e, Action::UserPrivate, None), Verdict::Never);
}

#[test]
fn an_equal_from_and_to_is_an_empty_range() {
    let t = [TimePreset {
        when: When::Between(9 * 60, 9 * 60),
        preset: Preset::Cautious,
    }];
    for minute in [0, 9 * 60 - 1, 9 * 60, 9 * 60 + 1, 23 * 60] {
        assert_eq!(
            active(Preset::Balanced, &t, false, minute),
            Preset::Balanced
        );
    }
}

#[test]
fn a_widening_names_the_action() {
    let w = Widening {
        action: Action::PushMain,
    };
    assert_eq!(
        w.to_string(),
        format!("{} is wider than the parent allows", Action::PushMain.id())
    );
}
