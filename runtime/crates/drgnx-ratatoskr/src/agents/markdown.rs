//! An agent message as Markdown blocks, patched as it streams.
//!
//! Only the last top-level block of the text can still change when more text arrives (a paragraph grows, an open
//! fence takes more lines, a `===` turns a paragraph into a heading), so [`Stream::update`] parses the text from that
//! block's start on and returns the blocks that are new or differ: the `{block, kind, spans}` patches an editor
//! applies.  Earlier blocks are never parsed again.

use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};
use serde::Serialize;

/// A run of text in one style (`text`, or space-joined `emph`, `strong`, `strike`, `link`, `code`, `h1`..`h6`).
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Span {
    pub text: String,
    pub style: String,
}

/// One top-level block: `paragraph`, `heading`, `code`, `quote`, `list`, `rule`, `table` or `html`.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Block {
    pub block: usize,
    pub kind: &'static str,
    pub spans: Vec<Span>,
}

/// The blocks of one message so far.
#[derive(Debug, Default)]
pub struct Stream {
    blocks: Vec<Block>,
    starts: Vec<usize>,
    /// Where the last [`Stream::update`] began parsing.
    pub reparsed_from: usize,
}

impl Stream {
    /// TEXT is the whole message so far (it only grows): the blocks that are new or changed.
    pub fn update(&mut self, text: &str) -> Vec<Block> {
        let mut from = self.starts.last().copied().unwrap_or(0).min(text.len());
        while !text.is_char_boundary(from) {
            from -= 1;
        }
        self.reparsed_from = from;
        let parsed = parse(&text[from..]);
        if parsed.is_empty() {
            return Vec::new();
        }
        let base = self.blocks.len().saturating_sub(1);
        let old = self.blocks.split_off(base);
        self.starts.truncate(base);
        let mut patches = Vec::new();
        for (j, (start, kind, spans)) in parsed.into_iter().enumerate() {
            let block = Block {
                block: base + j,
                kind,
                spans,
            };
            if old.get(j) != Some(&block) {
                patches.push(block.clone());
            }
            self.blocks.push(block);
            self.starts.push(from + start);
        }
        patches
    }

    pub fn blocks(&self) -> &[Block] {
        &self.blocks
    }
}

/// What a top-level block collects while its events go by.
struct Collect {
    spans: Vec<Span>,
    emph: u32,
    strong: u32,
    strike: u32,
    link: u32,
    code: bool,
    heading: Option<u8>,
    lists: Vec<Option<u64>>,
}

impl Collect {
    fn style(&self) -> String {
        let mut s: Vec<String> = Vec::new();
        if let Some(h) = self.heading {
            s.push(format!("h{h}"));
        }
        for (n, name) in [
            (self.emph, "emph"),
            (self.strong, "strong"),
            (self.strike, "strike"),
            (self.link, "link"),
        ] {
            if n > 0 {
                s.push(name.into());
            }
        }
        if self.code {
            s.push("code".into());
        }
        if s.is_empty() {
            "text".into()
        } else {
            s.join(" ")
        }
    }

    fn push(&mut self, text: &str, style: String) {
        if text.is_empty() {
            return;
        }
        match self.spans.last_mut() {
            Some(last) if last.style == style => last.text.push_str(text),
            _ => self.spans.push(Span {
                text: text.to_string(),
                style,
            }),
        }
    }

    fn newline(&mut self) {
        if self.spans.last().is_some_and(|s| !s.text.ends_with('\n')) {
            let style = self
                .spans
                .last()
                .map(|s| s.style.clone())
                .unwrap_or_default();
            self.push("\n", style);
        }
    }

    fn finish(mut self) -> Vec<Span> {
        if let Some(last) = self.spans.last_mut() {
            while last.text.ends_with('\n') {
                last.text.pop();
            }
        }
        self.spans.retain(|s| !s.text.is_empty());
        self.spans
    }
}

/// The top-level blocks of TEXT: where each starts in it, its kind and its spans.
fn parse(text: &str) -> Vec<(usize, &'static str, Vec<Span>)> {
    let opts = Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH;
    let mut out = Vec::new();
    let mut depth = 0usize;
    let mut cur: Option<(usize, &'static str, Collect)> = None;
    for (event, range) in Parser::new_ext(text, opts).into_offset_iter() {
        match event {
            Event::Start(tag) => {
                if depth == 0 {
                    let kind = match tag {
                        Tag::Heading { .. } => "heading",
                        Tag::BlockQuote(_) => "quote",
                        Tag::CodeBlock(_) => "code",
                        Tag::HtmlBlock => "html",
                        Tag::List(_) => "list",
                        Tag::Table(_) => "table",
                        _ => "paragraph",
                    };
                    cur = Some((
                        range.start,
                        kind,
                        Collect {
                            spans: Vec::new(),
                            emph: 0,
                            strong: 0,
                            strike: 0,
                            link: 0,
                            code: false,
                            heading: None,
                            lists: Vec::new(),
                        },
                    ));
                }
                depth += 1;
                let Some((_, _, c)) = cur.as_mut() else {
                    continue;
                };
                match tag {
                    Tag::Emphasis => c.emph += 1,
                    Tag::Strong => c.strong += 1,
                    Tag::Strikethrough => c.strike += 1,
                    Tag::Link { .. } => c.link += 1,
                    Tag::Heading { level, .. } => c.heading = Some(level as u8),
                    Tag::CodeBlock(_) => c.code = true,
                    Tag::List(first) => c.lists.push(first),
                    Tag::Item => {
                        let marker = match c.lists.last_mut() {
                            Some(Some(n)) => {
                                *n += 1;
                                format!("{}. ", *n - 1)
                            }
                            _ => "- ".into(),
                        };
                        let style = c.style();
                        c.push(&marker, style);
                    }
                    _ => {}
                }
            }
            Event::End(tag) => {
                depth = depth.saturating_sub(1);
                if let Some((_, _, c)) = cur.as_mut() {
                    match tag {
                        TagEnd::Emphasis => c.emph = c.emph.saturating_sub(1),
                        TagEnd::Strong => c.strong = c.strong.saturating_sub(1),
                        TagEnd::Strikethrough => c.strike = c.strike.saturating_sub(1),
                        TagEnd::Link => c.link = c.link.saturating_sub(1),
                        TagEnd::Heading(_) => c.heading = None,
                        TagEnd::CodeBlock => c.code = false,
                        TagEnd::List(_) => {
                            c.lists.pop();
                        }
                        TagEnd::TableCell => c.push("\t", "text".into()),
                        TagEnd::Item | TagEnd::TableRow | TagEnd::TableHead if depth > 0 => {
                            c.newline()
                        }
                        TagEnd::Paragraph if depth > 0 => c.newline(),
                        _ => {}
                    }
                }
                if depth == 0
                    && let Some((start, kind, c)) = cur.take()
                {
                    out.push((start, kind, c.finish()));
                }
            }
            Event::Text(t) | Event::Html(t) | Event::InlineHtml(t) => {
                if let Some((_, _, c)) = cur.as_mut() {
                    let style = c.style();
                    c.push(&t, style);
                }
            }
            Event::Code(t) => {
                if let Some((_, _, c)) = cur.as_mut() {
                    let was = std::mem::replace(&mut c.code, true);
                    let style = c.style();
                    c.code = was;
                    c.push(&t, style);
                }
            }
            Event::SoftBreak | Event::HardBreak => {
                if let Some((_, _, c)) = cur.as_mut() {
                    let style = c.style();
                    c.push("\n", style);
                }
            }
            Event::Rule if depth == 0 => out.push((range.start, "rule", Vec::new())),
            _ => {}
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_last_open_block_is_reparsed() {
        let mut s = Stream::default();
        let mut text = String::from("# Title\n\npara one\n\npara two\n\n```\ncode");
        let first = s.update(&text);
        assert_eq!(
            first.iter().map(|b| b.block).collect::<Vec<_>>(),
            [0, 1, 2, 3]
        );
        assert_eq!(first[0].kind, "heading");
        assert_eq!(first[3].kind, "code");
        text.push_str(" more\n");
        let patch = s.update(&text);
        assert_eq!(s.reparsed_from, text.find("```").unwrap());
        assert_eq!(patch.len(), 1, "{patch:?}");
        assert_eq!(patch[0].block, 3);
        assert_eq!(patch[0].spans[0].text, "code more");
        assert_eq!(patch[0].spans[0].style, "code");
        // text that adds a block: the open one is unchanged, the new one is the patch
        text.push_str("```\n\nafter *it*\n");
        let patch = s.update(&text);
        assert_eq!(patch.iter().map(|b| b.block).collect::<Vec<_>>(), [4]);
        assert_eq!(s.blocks().len(), 5);
        assert_eq!(s.blocks()[4].spans[1].style, "emph");
    }

    #[test]
    fn a_closing_fence_patches_the_blocks_it_restyles() {
        let mut s = Stream::default();
        s.update("one\n\ntwo\n\n``");
        assert_eq!(s.blocks().len(), 3);
        assert_eq!(s.blocks()[2].kind, "paragraph");
        // the third backtick turns the half-typed paragraph into an open fence: that block, and only it
        let patch = s.update("one\n\ntwo\n\n```\nx\n\ny\n");
        assert_eq!(
            patch.iter().map(|b| (b.block, b.kind)).collect::<Vec<_>>(),
            [(2, "code")]
        );
        // the closing fence leaves the code as it was; what follows is new
        let patch = s.update("one\n\ntwo\n\n```\nx\n\ny\n```\n\nafter");
        assert_eq!(patch.iter().map(|b| b.block).collect::<Vec<_>>(), [3]);
        assert_eq!(s.blocks()[2].spans[0].text, "x\n\ny");
        // a line of `===` restyles the paragraph above it
        let mut s = Stream::default();
        s.update("intro\n\nTitle\n");
        let patch = s.update("intro\n\nTitle\n===\n");
        assert_eq!(
            patch.iter().map(|b| (b.block, b.kind)).collect::<Vec<_>>(),
            [(1, "heading")]
        );
    }
}
