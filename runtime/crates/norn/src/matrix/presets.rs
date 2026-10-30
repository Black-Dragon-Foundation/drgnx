//! The three shipped presets.  Balanced is the design mockup's table (`permissions-matrix`); Cautious asks where
//! Balanced allows work that reaches beyond the worktree; Autonomous allows most of what Balanced asks of the manager
//! (a done task, the CI configuration, a larger spend and fleet), but still asks for pushes to main, settings and the
//! user's Emacs, asks the worker for the CI configuration, and keeps `spend.over` Ask for the manager and chat.
//! `unsandboxed` and `user.private` are Never in every column of every preset.

use super::{Action, Cell, Column, Limit, Matrix, Preset, Role, Unit, Verdict};

const fn v(verdict: Verdict) -> Cell {
    Cell {
        verdict,
        limit: None,
    }
}
const ALLOW: Cell = v(Verdict::Allow);
const ASK: Cell = v(Verdict::Ask);
const NEVER: Cell = v(Verdict::Never);

const fn allow_to(amount: f64, unit: Unit) -> Cell {
    Cell {
        verdict: Verdict::Allow,
        limit: Some(Limit { amount, unit }),
    }
}

/// ACTION's cells in the manager, worker and chat columns under P.
fn row(a: Action, p: Preset) -> [Cell; 3] {
    use Action::*;
    use Preset::*;
    match (a, p) {
        (AgentsStart, Cautious) => [ASK, NEVER, NEVER],
        (AgentsStart, Balanced) => [allow_to(4.0, Unit::Count), NEVER, NEVER],
        (AgentsStart, Autonomous) => [allow_to(8.0, Unit::Count), NEVER, NEVER],
        (AgentsModel, Cautious) => [ASK, NEVER, NEVER],
        (AgentsModel, _) => [ALLOW, NEVER, NEVER],
        (AgentsControl, _) => [ALLOW, NEVER, NEVER],
        (GraphChange, _) => [ALLOW, ALLOW, NEVER],
        (TaskDone, Autonomous) => [ALLOW, NEVER, NEVER],
        (TaskDone, _) => [ASK, NEVER, NEVER],
        (Spend, Cautious) => [ASK, ASK, allow_to(1.0, Unit::Usd)],
        (Spend, Balanced) => [
            allow_to(40.0, Unit::Usd),
            allow_to(10.0, Unit::Usd),
            allow_to(2.0, Unit::Usd),
        ],
        (Spend, Autonomous) => [
            allow_to(150.0, Unit::Usd),
            allow_to(30.0, Unit::Usd),
            allow_to(5.0, Unit::Usd),
        ],
        (SpendOver, Cautious) => [NEVER, NEVER, NEVER],
        (SpendOver, _) => [ASK, NEVER, ASK],
        (CodeRead, _) => [ALLOW, ALLOW, ASK],
        (CodeEdit, _) | (Commit, _) => [ALLOW, ALLOW, NEVER],
        (MergeIntegration, Cautious) => [ASK, NEVER, NEVER],
        (MergeIntegration, _) => [ALLOW, NEVER, NEVER],
        (PushCi, Cautious) => [ASK, NEVER, NEVER],
        (PushCi, _) => [ALLOW, NEVER, NEVER],
        (PushMain, Cautious) => [NEVER, NEVER, NEVER],
        (PushMain, _) => [ASK, NEVER, NEVER],
        (CodeCiConfig, Cautious) => [NEVER, NEVER, NEVER],
        (CodeCiConfig, Balanced) => [ASK, ASK, NEVER],
        (CodeCiConfig, Autonomous) => [ALLOW, ASK, NEVER],
        (Machines, Cautious) => [ASK, ASK, NEVER],
        (Machines, _) => [ALLOW, ALLOW, NEVER],
        (JobContainer, Cautious) => [ASK, ASK, NEVER],
        (JobContainer, _) => [ALLOW, ALLOW, NEVER],
        (Network, Cautious) => [ASK, ASK, ALLOW],
        (Network, _) => [ALLOW, ALLOW, ALLOW],
        (Unsandboxed, _) | (UserPrivate, _) => [NEVER, NEVER, NEVER],
        (SettingsChange, _) => [ASK, ASK, ASK],
        (UserEmacs, Cautious) => [NEVER, NEVER, NEVER],
        (UserEmacs, _) => [ASK, NEVER, NEVER],
        (ChatProjectRead, _) => [NEVER, NEVER, ASK],
    }
}

/// The matrix of preset P: every action in the three role columns.
pub fn preset(p: Preset) -> Matrix {
    let mut m = Matrix::default();
    for a in Action::ALL {
        let cells = row(a, p);
        for (role, cell) in [Role::Manager, Role::Worker, Role::Chat]
            .into_iter()
            .zip(cells)
        {
            m.set(a, Column::Role(role), cell);
        }
    }
    m
}
