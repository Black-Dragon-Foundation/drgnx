//! The SSE usage scanner (Task 18).
//!
//! [`Scanner`] watches a response body as it streams past and keeps the token counts the provider reports. The mode is
//! decided on the first non-blank byte: `{` is one JSON body, anything else is Server-Sent Events (WHATWG HTML §9.2).
//! Every byte is looked at once by the line splitter; the JSON of each dispatched event is parsed once.

use serde_json::Value;

/// The largest JSON body (and the largest SSE line or event) the scanner keeps.
const CAP: usize = 32 * 1024 * 1024;

/// What a response used. `input` counts cache writes at 1.25 and cache reads at 0.1 of a token.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Usage {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    /// The provider's own cost (OpenRouter's `usage.cost`), if it sent one.
    pub cost: Option<f64>,
}

/// The numeric fields seen so far; a later number overwrites an earlier one, anything else leaves it alone.
#[derive(Debug, Clone, Default)]
struct Raw {
    input_tokens: Option<u64>,
    prompt_tokens: Option<u64>,
    prompt_eval_count: Option<u64>,
    output_tokens: Option<u64>,
    completion_tokens: Option<u64>,
    eval_count: Option<u64>,
    cache_read: Option<u64>,
    cache_write: Option<u64>,
    cost: Option<f64>,
}

fn num(o: &serde_json::Map<String, Value>, key: &str, into: &mut Option<u64>) {
    if let Some(n) = o.get(key).and_then(Value::as_f64) {
        if n.is_finite() && n >= 0.0 {
            *into = Some(n.round() as u64);
        }
    }
}

impl Raw {
    /// Take usage from one JSON value: `usage`, else `message.usage`, plus Ollama's top-level counts.
    fn take(&mut self, v: &Value) {
        let Some(o) = v.as_object() else { return };
        let usage = o
            .get("usage")
            .and_then(Value::as_object)
            .or_else(|| o.get("message")?.get("usage")?.as_object());
        if let Some(u) = usage {
            num(u, "input_tokens", &mut self.input_tokens);
            num(u, "prompt_tokens", &mut self.prompt_tokens);
            num(u, "output_tokens", &mut self.output_tokens);
            num(u, "completion_tokens", &mut self.completion_tokens);
            num(u, "cache_read_input_tokens", &mut self.cache_read);
            num(u, "cache_creation_input_tokens", &mut self.cache_write);
            if let Some(c) = u.get("cost").and_then(Value::as_f64) {
                if c.is_finite() {
                    self.cost = Some(c);
                }
            }
        }
        num(o, "prompt_eval_count", &mut self.prompt_eval_count);
        num(o, "eval_count", &mut self.eval_count);
    }

    fn usage(&self) -> Usage {
        let i = self.input_tokens.or(self.prompt_tokens).or(self.prompt_eval_count).unwrap_or(0);
        let cr = self.cache_read.unwrap_or(0);
        let cw = self.cache_write.unwrap_or(0);
        let input = (i as f64 + 1.25 * cw as f64 + 0.1 * cr as f64).round() as u64;
        let output = self.output_tokens.or(self.completion_tokens).or(self.eval_count).unwrap_or(0);
        Usage { input, output, cache_read: cr, cache_write: cw, cost: self.cost }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Mode {
    Undecided,
    Json,
    Sse,
}

/// The usage scanner: `feed` it the body's chunks in order, then read `usage`.
#[derive(Debug)]
pub struct Scanner {
    mode: Mode,
    raw: Raw,
    /// JSON mode: the body so far.
    body: Vec<u8>,
    /// SSE mode: the current line, the current event's data, and the line-ending state.
    line: Vec<u8>,
    data: Vec<u8>,
    skip_lf: bool,
    first_line: bool,
}

impl Default for Scanner {
    fn default() -> Self {
        Self::new()
    }
}

impl Scanner {
    pub fn new() -> Self {
        Scanner {
            mode: Mode::Undecided,
            raw: Raw::default(),
            body: Vec::new(),
            line: Vec::new(),
            data: Vec::new(),
            skip_lf: false,
            first_line: true,
        }
    }

    pub fn feed(&mut self, chunk: &[u8]) {
        let mut chunk = chunk;
        if self.mode == Mode::Undecided {
            let Some(at) = chunk.iter().position(|b| !matches!(b, b' ' | b'\t' | b'\r' | b'\n')) else {
                return;
            };
            chunk = &chunk[at..];
            self.mode = if chunk[0] == b'{' { Mode::Json } else { Mode::Sse };
        }
        match self.mode {
            Mode::Json => {
                let room = CAP.saturating_sub(self.body.len());
                self.body.extend_from_slice(&chunk[..chunk.len().min(room)]);
            }
            _ => chunk.iter().for_each(|&b| self.sse_byte(b)),
        }
    }

    pub fn usage(&self) -> Usage {
        if self.mode == Mode::Json {
            let mut raw = Raw::default();
            if let Some(Ok(v)) = serde_json::Deserializer::from_slice(&self.body).into_iter::<Value>().next() {
                raw.take(&v);
            }
            return raw.usage();
        }
        self.raw.usage()
    }

    fn sse_byte(&mut self, b: u8) {
        if self.skip_lf {
            self.skip_lf = false;
            if b == b'\n' {
                return;
            }
        }
        match b {
            b'\n' | b'\r' => {
                self.skip_lf = b == b'\r';
                self.end_line();
            }
            _ if self.line.len() < CAP => self.line.push(b),
            _ => {}
        }
    }

    fn end_line(&mut self) {
        let mut line = std::mem::take(&mut self.line);
        if self.first_line {
            self.first_line = false;
            if line.starts_with(&[0xEF, 0xBB, 0xBF]) {
                line.drain(..3);
            }
        }
        if line.is_empty() {
            self.dispatch();
        } else if line[0] != b':' {
            let (field, value) = match line.iter().position(|&c| c == b':') {
                Some(i) => (&line[..i], &line[i + 1..]),
                None => (&line[..], &line[line.len()..]),
            };
            if field == b"data" {
                let value = value.strip_prefix(b" ").unwrap_or(value);
                if self.data.len() + value.len() < CAP {
                    self.data.extend_from_slice(value);
                    self.data.push(b'\n');
                }
            }
        }
        line.clear();
        self.line = line;
    }

    fn dispatch(&mut self) {
        if self.data.is_empty() {
            return;
        }
        if self.data.last() == Some(&b'\n') {
            self.data.pop();
        }
        if let Ok(v) = serde_json::from_slice::<Value>(&self.data) {
            self.raw.take(&v);
        }
        self.data.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scan(s: &str) -> Usage {
        let mut sc = Scanner::new();
        sc.feed(s.as_bytes());
        sc.usage()
    }

    #[test]
    fn message_start_then_delta() {
        let u = scan(
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":25,\"output_tokens\":1}}}\n\n\
             event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":15}}\n\n",
        );
        assert_eq!((u.input, u.output, u.cost), (25, 15, None));
    }

    #[test]
    fn cache_tokens_weigh_into_input() {
        let u = scan(
            "data: {\"message\":{\"usage\":{\"input_tokens\":100,\"cache_creation_input_tokens\":40,\"cache_read_input_tokens\":200}}}\n\n",
        );
        assert_eq!((u.input, u.cache_write, u.cache_read), (170, 40, 200));
    }

    #[test]
    fn openrouter_cost_wins() {
        let u = scan("data: {\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"cost\":0.0042}}\n\n");
        assert_eq!(u.cost, Some(0.0042));
    }

    #[test]
    fn json_body_mode() {
        let u = scan("  \n{\"usage\":{\"input_tokens\":7,\"output_tokens\":3}}");
        assert_eq!((u.input, u.output), (7, 3));
        let mut sc = Scanner::new();
        for b in b"{\"usage\":{\"input_tokens\":7,\"output_tokens\":3}}" {
            sc.feed(&[*b]);
        }
        assert_eq!(sc.usage(), u);
    }

    #[test]
    fn crlf_and_bare_cr() {
        let a = scan("data: {\"usage\":{\"input_tokens\":4,\"output_tokens\":2}}\r\n\r\n");
        let b = scan("data: {\"usage\":{\"input_tokens\":4,\"output_tokens\":2}}\r\r");
        assert_eq!((a.input, a.output), (4, 2));
        assert_eq!(a, b);
    }

    #[test]
    fn split_crlf() {
        let mut sc = Scanner::new();
        sc.feed(b"data: {\"usage\":{\"input_tokens\":4}}\r");
        sc.feed(b"\n\r");
        sc.feed(b"\ndata: {\"usage\":{\"output_tokens\":9}}\n\n");
        let u = sc.usage();
        assert_eq!((u.input, u.output), (4, 9));
    }

    #[test]
    fn bom() {
        let mut s = vec![0xEF, 0xBB, 0xBF];
        s.extend_from_slice(b"data: {\"usage\":{\"input_tokens\":3}}\n\n");
        let mut sc = Scanner::new();
        sc.feed(&s[..2]);
        sc.feed(&s[2..]);
        assert_eq!(sc.usage().input, 3);
    }

    #[test]
    fn comments_ignored() {
        let u = scan(": OPENROUTER PROCESSING\n\ndata: {\"usage\":{\"input_tokens\":3}}\n: keep-alive\n\n");
        assert_eq!(u.input, 3);
    }

    #[test]
    fn done_sentinel_ignored() {
        let u = scan("data: {\"usage\":{\"input_tokens\":3,\"output_tokens\":4}}\n\ndata: [DONE]\n\n");
        assert_eq!((u.input, u.output), (3, 4));
    }

    #[test]
    fn multi_line_data() {
        let u = scan("data: {\"usage\":\ndata: {\"input_tokens\":8,\ndata: \"output_tokens\":2}}\n\n");
        assert_eq!((u.input, u.output), (8, 2));
    }

    #[test]
    fn a_mid_stream_error_event_keeps_the_counts() {
        let u = scan(
            "data: {\"message\":{\"usage\":{\"input_tokens\":12,\"output_tokens\":1}}}\n\n\
             event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n",
        );
        assert_eq!((u.input, u.output), (12, 1));
    }

    #[test]
    fn openai_chat_json_usage() {
        let u = scan("{\"choices\":[],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":6,\"total_tokens\":17}}");
        assert_eq!((u.input, u.output), (11, 6));
    }

    #[test]
    fn openai_stream_last_chunk_usage() {
        let u = scan(
            "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}],\"usage\":null}\n\n\
             data: {\"choices\":[],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":2}}\n\n\
             data: [DONE]\n\n",
        );
        assert_eq!((u.input, u.output), (9, 2));
    }

    #[test]
    fn embeddings_usage_has_no_output() {
        let u = scan("{\"data\":[],\"usage\":{\"prompt_tokens\":5,\"total_tokens\":5}}");
        assert_eq!((u.input, u.output), (5, 0));
    }

    #[test]
    fn ollama_counts() {
        let u = scan("{\"model\":\"m\",\"done\":true,\"prompt_eval_count\":14,\"eval_count\":30}");
        assert_eq!((u.input, u.output), (14, 30));
    }

    #[test]
    fn no_usage_is_zero() {
        assert_eq!(scan("{\"content\":\"ok\"}"), Usage::default());
        assert_eq!(scan("data: {\"choices\":[]}\n\n"), Usage::default());
        assert_eq!(Scanner::new().usage(), Usage::default());
    }
}
