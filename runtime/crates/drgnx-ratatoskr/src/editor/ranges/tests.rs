//! The line authors kept from operations, against a model that keeps every character's author.
use super::*;
use skuld::{Bound, Core, Partial, every_order};

/// The model: every character with its author.
#[derive(Clone, Debug, Default)]
struct Model {
    chars: Vec<(char, String)>,
}

impl Model {
    fn new(text: &str) -> Model {
        Model {
            chars: text.chars().map(|c| (c, String::new())).collect(),
        }
    }

    fn text(&self) -> String {
        self.chars.iter().map(|(c, _)| *c).collect()
    }

    fn apply(&mut self, op: Op<'_>) {
        let ins: Vec<(char, String)> = op
            .inserted
            .chars()
            .map(|c| (c, op.author.to_owned()))
            .collect();
        self.chars.splice(op.start..op.start + op.old_len, ins);
    }

    /// The blame: runs of characters by an author (the base left out).
    fn blame(&self) -> Vec<(Range<usize>, String)> {
        let mut out: Vec<(Range<usize>, String)> = Vec::new();
        for (i, (_, a)) in self.chars.iter().enumerate() {
            if a.is_empty() {
                continue;
            }
            match out.last_mut() {
                Some((r, b)) if r.end == i && b == a => r.end = i + 1,
                _ => out.push((i..i + 1, a.clone())),
            }
        }
        out
    }

    /// The character offset where line N (0-based, taken modulo the line count) starts, and that line's length
    /// without its line break.
    fn line(&self, n: usize) -> (usize, usize) {
        let text = self.text();
        let lines: Vec<&str> = text.split('\n').collect();
        let n = n % lines.len();
        let start: usize = lines[..n].iter().map(|l| l.chars().count() + 1).sum();
        (start, lines[n].chars().count())
    }
}

fn r(start: u32, end: u32) -> LineRange {
    LineRange { start, end }
}

/// What one author does, addressed by line so that every order is a valid one.
#[derive(Clone, Debug)]
enum Ev {
    /// AUTHOR types TEXT at the start of line N.
    Type(&'static str, usize, &'static str),
    /// AUTHOR replaces line N's text with TEXT.
    Replace(&'static str, usize, &'static str),
    /// AUTHOR deletes line N with its line break.
    Delete(&'static str, usize),
    /// The ranges are made again from the text and its blame.
    Rebuild,
}
skuld::events!(Ev {
    Type,
    Replace,
    Delete,
    Rebuild
});

struct Shell {
    model: Model,
    ranges: AgentRanges,
}

impl Core for Shell {
    type Event = Ev;

    fn step(&mut self, ev: Ev) -> Vec<Ev> {
        let op = match ev {
            Ev::Type(author, n, text) => {
                let (start, _) = self.model.line(n);
                (author, start, 0, text)
            }
            Ev::Replace(author, n, text) => {
                let (start, len) = self.model.line(n);
                (author, start, len, text)
            }
            Ev::Delete(author, n) => {
                let (start, len) = self.model.line(n);
                let total = self.model.chars.len();
                (author, start, (len + 1).min(total - start), "")
            }
            Ev::Rebuild => {
                self.ranges = AgentRanges::rebuild(&self.model.text(), &self.model.blame());
                return Vec::new();
            }
        };
        let op = Op {
            author: op.0,
            start: op.1,
            old_len: op.2,
            inserted: op.3,
        };
        self.model.apply(op);
        assert!(self.ranges.apply_op(op), "{op:?} refused");
        Vec::new()
    }
}

/// [A] The user types and an agent writes in every interleaving, with the ranges made again from the blame at any
/// point: the ranges kept from the operations are always the ones the blame of the text gives.
#[test]
fn every_order_ops_and_rebuild_agree() {
    let base = "one\ntwo\nthree\nfour\nfive\n";
    let mut p = Partial::new();
    p.source(
        "user",
        vec![
            Ev::Type("user", 1, "u-"),
            Ev::Replace("user", 3, "FOUR"),
            Ev::Delete("user", 0),
        ],
    );
    p.source(
        "agent",
        vec![
            Ev::Replace("agent:a", 2, "THREE\nthree-and-a-half"),
            Ev::Type("agent:a", 4, "\n"),
            Ev::Delete("agent:a", 1),
        ],
    );
    p.source("restart", vec![Ev::Rebuild, Ev::Rebuild]);
    every_order(
        &p,
        Bound::default(),
        || Shell {
            model: Model::new(base),
            ranges: AgentRanges::new(base),
        },
        |s, _| {
            let again = AgentRanges::rebuild(&s.model.text(), &s.model.blame());
            for a in ["user", "agent:a"] {
                if s.ranges.ranges(a) != again.ranges(a) {
                    return Err(format!(
                        "{a}: kept {:?}, from the blame {:?} (text {:?})",
                        s.ranges.ranges(a),
                        again.ranges(a),
                        s.model.text()
                    ));
                }
            }
            if s.ranges.chars() != s.model.chars.len() {
                return Err("the lengths differ".into());
            }
            Ok(())
        },
    );
}

/// [D] An agent wrote three lines; the user took the wheel and changed one of them and added two of their own: those
/// are the user's, never in the agent's colour, and the agent keeps only the lines nobody else touched.
#[test]
fn the_users_edits_under_the_wheel_have_no_agent_colour() {
    let base = "a\nb\nc\n";
    let mut m = Model::new(base);
    let mut g = AgentRanges::new(base);
    let ops = [
        Op {
            author: "agent:s1",
            start: 2,
            old_len: 1,
            inserted: "B1\nB2\nB3",
        },
        // the user, holding the wheel: types inside the agent's second line and adds two lines after the last
        Op {
            author: "user",
            start: 6,
            old_len: 0,
            inserted: "!",
        },
        Op {
            author: "user",
            start: 12,
            old_len: 0,
            inserted: "u1\nu2\n",
        },
    ];
    for op in ops {
        m.apply(op);
        assert!(g.apply_op(op));
    }
    assert_eq!(m.text(), "a\nB1\nB!2\nB3\nu1\nu2\nc\n");
    assert_eq!(g.ranges("agent:s1"), vec![r(2, 2), r(4, 4)]);
    assert_eq!(g.ranges("user"), vec![r(3, 3), r(5, 6)]);
    assert_eq!(
        g.authors(),
        vec!["agent:s1".to_string(), "user".to_string()]
    );
    // a deletion leaves no character of anyone's
    let del = Op {
        author: "user",
        start: 0,
        old_len: 2,
        inserted: "",
    };
    assert!(g.apply_op(del));
    assert_eq!(g.ranges("agent:s1"), vec![r(1, 1), r(3, 3)]);
    // outside the text: refused, nothing changed
    let before = g.clone();
    assert!(!g.apply_op(Op {
        author: "user",
        start: 999,
        old_len: 0,
        inserted: "x",
    }));
    assert_eq!(g, before);
}
