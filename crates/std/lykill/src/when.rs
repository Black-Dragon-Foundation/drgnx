//! Context expressions: where a binding applies (editing-model design 4.6), for example
//! `language == rust && view == excerpts && !readonly`.
//!
//! The language is small on purpose: `==`, `!=`, `&&`, `||`, `!`, parentheses, identifiers (the terms of the context)
//! and string or bool literals. A bare word on the right of `==` or `!=` is a string (`language == rust`); `true` and
//! `false` there are bools. An identifier alone is true when its term is true (a bool) or not empty (a string); a term
//! the context does not have is false.

use std::collections::BTreeMap;

const MAX_TOKENS: usize = 256;
const MAX_DEPTH: usize = 32;

/// A term's value in a context.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Term {
    Bool(bool),
    Str(String),
}

/// What the expressions are evaluated in: the document, view kind, pane and features, as named terms.
#[derive(Clone, Default, Debug)]
pub struct KeyContext {
    terms: BTreeMap<String, Term>,
}

impl KeyContext {
    pub fn new() -> KeyContext {
        KeyContext::default()
    }

    /// A string term (`language`, `view`).
    pub fn with(mut self, name: &str, value: &str) -> KeyContext {
        self.terms
            .insert(name.to_string(), Term::Str(value.to_string()));
        self
    }

    /// A flag (`readonly`).
    pub fn with_flag(mut self, name: &str, on: bool) -> KeyContext {
        self.terms.insert(name.to_string(), Term::Bool(on));
        self
    }
}

#[derive(Clone, PartialEq, Eq, Debug)]
enum Expr {
    /// the empty expression
    True,
    Term(String),
    Not(Box<Expr>),
    And(Box<Expr>, Box<Expr>),
    Or(Box<Expr>, Box<Expr>),
    /// term, value, negated
    Cmp(String, Term, bool),
}

/// A parsed context expression.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct When {
    expr: Expr,
    text: String,
}

#[derive(Clone, PartialEq, Eq, Debug)]
enum Tok {
    Word(String),
    Str(String),
    Eq,
    Ne,
    And,
    Or,
    Not,
    Open,
    Close,
}

fn bad(text: &str, why: &str) -> villa::Error {
    villa::Error::invalid(format!("The context `{text}` is not valid: {why}."))
}

fn lex(text: &str) -> villa::Result<Vec<Tok>> {
    let cs: Vec<char> = text.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < cs.len() {
        let c = cs[i];
        let next = cs.get(i + 1).copied();
        match (c, next) {
            (c, _) if c.is_whitespace() => i += 1,
            ('=', Some('=')) => {
                out.push(Tok::Eq);
                i += 2;
            }
            ('!', Some('=')) => {
                out.push(Tok::Ne);
                i += 2;
            }
            ('&', Some('&')) => {
                out.push(Tok::And);
                i += 2;
            }
            ('|', Some('|')) => {
                out.push(Tok::Or);
                i += 2;
            }
            ('!', _) => {
                out.push(Tok::Not);
                i += 1;
            }
            ('(', _) => {
                out.push(Tok::Open);
                i += 1;
            }
            (')', _) => {
                out.push(Tok::Close);
                i += 1;
            }
            (q @ ('"' | '\''), _) => {
                let start = i + 1;
                let Some(len) = cs[start..].iter().position(|&x| x == q) else {
                    return Err(bad(text, "a string is not closed"));
                };
                out.push(Tok::Str(cs[start..start + len].iter().collect()));
                i = start + len + 1;
            }
            (c, _) if c.is_alphanumeric() || matches!(c, '_' | '-' | '.') => {
                let start = i;
                while i < cs.len() && (cs[i].is_alphanumeric() || matches!(cs[i], '_' | '-' | '.'))
                {
                    i += 1;
                }
                out.push(Tok::Word(cs[start..i].iter().collect()));
            }
            (c, _) => return Err(bad(text, &format!("`{c}` is not part of the language"))),
        }
        if out.len() > MAX_TOKENS {
            return Err(bad(text, "it is too long"));
        }
    }
    Ok(out)
}

struct Parser<'a> {
    toks: &'a [Tok],
    at: usize,
    text: &'a str,
}

impl Parser<'_> {
    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.at)
    }

    fn or(&mut self, depth: usize) -> villa::Result<Expr> {
        let mut l = self.and(depth)?;
        while self.peek() == Some(&Tok::Or) {
            self.at += 1;
            l = Expr::Or(Box::new(l), Box::new(self.and(depth)?));
        }
        Ok(l)
    }

    fn and(&mut self, depth: usize) -> villa::Result<Expr> {
        let mut l = self.unary(depth)?;
        while self.peek() == Some(&Tok::And) {
            self.at += 1;
            l = Expr::And(Box::new(l), Box::new(self.unary(depth)?));
        }
        Ok(l)
    }

    fn unary(&mut self, depth: usize) -> villa::Result<Expr> {
        if depth > MAX_DEPTH {
            return Err(bad(self.text, "it nests too deeply"));
        }
        match self.peek().cloned() {
            Some(Tok::Not) => {
                self.at += 1;
                Ok(Expr::Not(Box::new(self.unary(depth + 1)?)))
            }
            Some(Tok::Open) => {
                self.at += 1;
                let e = self.or(depth + 1)?;
                if self.peek() != Some(&Tok::Close) {
                    return Err(bad(self.text, "a parenthesis is not closed"));
                }
                self.at += 1;
                Ok(e)
            }
            Some(Tok::Word(w)) => {
                self.at += 1;
                let negated = match self.peek() {
                    Some(Tok::Eq) => Some(false),
                    Some(Tok::Ne) => Some(true),
                    _ => None,
                };
                let Some(negated) = negated else {
                    return Ok(Expr::Term(w));
                };
                self.at += 1;
                let value = match self.peek().cloned() {
                    Some(Tok::Str(s)) => Term::Str(s),
                    Some(Tok::Word(v)) if v == "true" => Term::Bool(true),
                    Some(Tok::Word(v)) if v == "false" => Term::Bool(false),
                    Some(Tok::Word(v)) => Term::Str(v),
                    _ => return Err(bad(self.text, "a comparison needs a value on its right")),
                };
                self.at += 1;
                Ok(Expr::Cmp(w, value, negated))
            }
            _ => Err(bad(self.text, "a term was expected")),
        }
    }
}

impl When {
    /// Parse TEXT; an empty text is the expression that is always true.
    pub fn parse(text: &str) -> villa::Result<When> {
        let toks = lex(text)?;
        if toks.is_empty() {
            return Ok(When {
                expr: Expr::True,
                text: String::new(),
            });
        }
        let mut p = Parser {
            toks: &toks,
            at: 0,
            text,
        };
        let expr = p.or(0)?;
        if p.at != toks.len() {
            return Err(bad(text, "something follows the end of the expression"));
        }
        Ok(When {
            expr,
            text: text.to_string(),
        })
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn holds(&self, cx: &KeyContext) -> bool {
        fn eval(e: &Expr, cx: &KeyContext) -> bool {
            match e {
                Expr::True => true,
                Expr::Term(t) => match cx.terms.get(t) {
                    Some(Term::Bool(b)) => *b,
                    Some(Term::Str(s)) => !s.is_empty(),
                    None => false,
                },
                Expr::Not(e) => !eval(e, cx),
                Expr::And(a, b) => eval(a, cx) && eval(b, cx),
                Expr::Or(a, b) => eval(a, cx) || eval(b, cx),
                Expr::Cmp(t, v, negated) => (cx.terms.get(t) == Some(v)) != *negated,
            }
        }
        eval(&self.expr, cx)
    }
}
