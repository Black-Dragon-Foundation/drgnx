//! The `http`, `expect_http` and `file_grep` verbs, and `spawn`'s `capture_stdout` (docs/develop/runtime.md).

use crate::matcher::{self, Captures};
use serde_json::{Map, Value};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

type R<T = ()> = Result<T, String>;

enum Stream {
    Tcp(TcpStream),
    Unix(UnixStream),
}

pub enum Fill {
    Data,
    Eof,
    Timeout,
}

/// One HTTP/1.1 connection and everything read from it so far.
pub struct Exchange {
    stream: Stream,
    buf: Vec<u8>,
    eof: bool,
}

/// The response as far as it has arrived (a chunked body decoded).
pub struct Parsed {
    pub status: u16,
    /// Lower-case names.
    pub headers: Map<String, Value>,
    pub body: Vec<u8>,
    pub complete: bool,
}

pub enum ReadMode {
    Head,
    All,
    Bytes(usize),
}

impl ReadMode {
    pub fn parse(v: Option<&Value>) -> R<ReadMode> {
        match v {
            None => Ok(ReadMode::All),
            Some(Value::String(s)) if s == "head" => Ok(ReadMode::Head),
            Some(Value::String(s)) if s == "all" => Ok(ReadMode::All),
            Some(Value::Object(o)) => o
                .get("bytes")
                .and_then(Value::as_u64)
                .map(|n| ReadMode::Bytes(n as usize))
                .ok_or_else(|| "\"read\": {\"bytes\": N} needs a number".into()),
            Some(_) => Err("\"read\" is \"head\", \"all\" or {\"bytes\": N}".into()),
        }
    }
}

impl Exchange {
    /// `to` is `tcp:HOST:PORT` or `unix:PATH`.
    pub fn connect(to: &str) -> R<Exchange> {
        let stream = if let Some(addr) = to.strip_prefix("tcp:") {
            Stream::Tcp(TcpStream::connect(addr).map_err(|e| format!("connect {to}: {e}"))?)
        } else if let Some(path) = to.strip_prefix("unix:") {
            Stream::Unix(UnixStream::connect(path).map_err(|e| format!("connect {to}: {e}"))?)
        } else {
            return Err(format!("\"to\" is tcp:HOST:PORT or unix:PATH, not {to:?}"));
        };
        let ex = Exchange {
            stream,
            buf: vec![],
            eof: false,
        };
        let w = Some(Duration::from_secs(10));
        let r = match &ex.stream {
            Stream::Tcp(s) => s.set_write_timeout(w),
            Stream::Unix(s) => s.set_write_timeout(w),
        };
        r.map_err(|e| e.to_string())?;
        Ok(ex)
    }

    /// A new request on this connection: what was read before is dropped.
    pub fn restart(&mut self) {
        self.buf.clear();
    }

    pub fn send(&mut self, data: &[u8]) -> R {
        let r = match &mut self.stream {
            Stream::Tcp(s) => s.write_all(data),
            Stream::Unix(s) => s.write_all(data),
        };
        r.map_err(|e| format!("write: {e}"))
    }

    /// Read some more, waiting until DEADLINE.
    pub fn fill(&mut self, deadline: Instant) -> R<Fill> {
        if self.eof {
            return Ok(Fill::Eof);
        }
        let left = deadline
            .saturating_duration_since(Instant::now())
            .max(Duration::from_millis(1));
        let mut chunk = vec![0u8; 65536];
        let r = match &mut self.stream {
            Stream::Tcp(s) => s
                .set_read_timeout(Some(left))
                .and_then(|()| s.read(&mut chunk)),
            Stream::Unix(s) => s
                .set_read_timeout(Some(left))
                .and_then(|()| s.read(&mut chunk)),
        };
        match r {
            Ok(0) => {
                self.eof = true;
                Ok(Fill::Eof)
            }
            Ok(n) => {
                self.buf.extend_from_slice(&chunk[..n]);
                Ok(Fill::Data)
            }
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                Ok(Fill::Timeout)
            }
            // a reset after a response is the peer going away
            Err(e) if e.kind() == std::io::ErrorKind::ConnectionReset => {
                self.eof = true;
                Ok(Fill::Eof)
            }
            Err(e) => Err(format!("read: {e}")),
        }
    }

    pub fn parse(&self) -> Option<Parsed> {
        let head_end = self.buf.windows(4).position(|w| w == b"\r\n\r\n")? + 4;
        let head = String::from_utf8_lossy(&self.buf[..head_end - 4]).into_owned();
        let mut lines = head.split("\r\n");
        let status = lines.next()?.split(' ').nth(1)?.parse().ok()?;
        let mut headers = Map::new();
        for l in lines {
            if let Some((k, v)) = l.split_once(':') {
                headers.insert(
                    k.trim().to_ascii_lowercase(),
                    Value::String(v.trim().to_string()),
                );
            }
        }
        let raw = &self.buf[head_end..];
        let header = |k: &str| headers.get(k).and_then(Value::as_str).unwrap_or("");
        let (body, complete) = if header("transfer-encoding").eq_ignore_ascii_case("chunked") {
            decode_chunked(raw)
        } else if let Ok(len) = header("content-length").parse::<usize>() {
            (raw[..raw.len().min(len)].to_vec(), raw.len() >= len)
        } else {
            (raw.to_vec(), self.eof)
        };
        Some(Parsed {
            status,
            headers,
            body,
            complete,
        })
    }

    /// Read until MODE is satisfied (the head; the whole response; N body bytes) or the connection ends.
    pub fn read(&mut self, mode: &ReadMode, deadline: Instant) -> R {
        loop {
            if let Some(p) = self.parse() {
                let done = match mode {
                    ReadMode::Head => true,
                    ReadMode::All => p.complete,
                    ReadMode::Bytes(n) => p.body.len() >= *n,
                };
                if done {
                    return Ok(());
                }
            }
            match self.fill(deadline)? {
                Fill::Data => {}
                Fill::Eof if self.parse().is_some() => return Ok(()),
                Fill::Eof => return Err("the connection closed before a response head".into()),
                Fill::Timeout => return Err("timed out reading the response".into()),
            }
        }
    }

    pub fn close(self) {
        match &self.stream {
            Stream::Tcp(s) => {
                let _ = s.shutdown(std::net::Shutdown::Both);
            }
            Stream::Unix(s) => {
                let _ = s.shutdown(std::net::Shutdown::Both);
            }
        }
    }
}

/// The decoded body of a chunked message so far, and whether its last chunk arrived.
pub fn decode_chunked(raw: &[u8]) -> (Vec<u8>, bool) {
    let mut out = Vec::new();
    let mut at = 0;
    loop {
        let Some(nl) = raw[at..].windows(2).position(|w| w == b"\r\n") else {
            return (out, false);
        };
        let size_text = String::from_utf8_lossy(&raw[at..at + nl]).into_owned();
        let Ok(size) = usize::from_str_radix(size_text.split(';').next().unwrap_or("").trim(), 16)
        else {
            return (out, false);
        };
        at += nl + 2;
        if size == 0 {
            return (out, true);
        }
        let end = (at + size).min(raw.len());
        out.extend_from_slice(&raw[at..end]);
        if raw.len() < at + size + 2 {
            return (out, false);
        }
        at += size + 2;
    }
}

/// What `expect_http` wants (patterns already substituted).
#[derive(Default)]
pub struct Want {
    pub status: Option<u64>,
    pub headers: Option<Value>,
    pub body_contains: Option<String>,
    pub body_json: Option<Value>,
}

fn check(ex: &Exchange, want: &Want, caps: &mut Captures) -> R {
    let p = ex.parse().ok_or("no response head has arrived")?;
    if let Some(s) = want.status
        && u64::from(p.status) != s
    {
        return Err(format!("status {}, wanted {s}", p.status));
    }
    let mut trial = caps.clone();
    if let Some(Value::Object(h)) = &want.headers {
        let lower: Map<String, Value> = h
            .iter()
            .map(|(k, v)| (k.to_ascii_lowercase(), v.clone()))
            .collect();
        matcher::matches(
            &Value::Object(lower),
            &Value::Object(p.headers.clone()),
            &mut trial,
        )
        .map_err(|e| format!("headers: {e}"))?;
    }
    if let Some(text) = &want.body_contains
        && !String::from_utf8_lossy(&p.body).contains(text.as_str())
    {
        return Err(format!("the body does not contain {text:?}"));
    }
    if let Some(pattern) = &want.body_json {
        let got: Value = serde_json::from_slice(&p.body)
            .map_err(|e| format!("the body is not JSON (yet): {e}"))?;
        matcher::matches(pattern, &got, &mut trial).map_err(|e| format!("body: {e}"))?;
    }
    *caps = trial;
    Ok(())
}

/// The response read so far must match WANT; more is read until `within`.
pub fn expect(ex: &mut Exchange, want: &Want, caps: &mut Captures, within: Duration) -> R {
    let deadline = Instant::now() + within;
    loop {
        let r = check(ex, want, caps);
        if r.is_ok() {
            return r;
        }
        match ex.fill(deadline)? {
            Fill::Data => {}
            Fill::Eof => return check(ex, want, caps),
            Fill::Timeout => {
                return r.map_err(|e| format!("{e} (within {} ms)", within.as_millis()));
            }
        }
    }
}

// ------------------------------------------------------------------------------------------ file_grep

fn walk(base: &Path, comps: &[&str], out: &mut Vec<PathBuf>) {
    let is_file = |p: &Path| std::fs::symlink_metadata(p).is_ok_and(|m| m.is_file());
    let children = |p: &Path| {
        let mut v: Vec<PathBuf> = std::fs::read_dir(p)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .collect();
        v.sort();
        v
    };
    let Some((first, rest)) = comps.split_first() else {
        if is_file(base) {
            out.push(base.to_path_buf());
        }
        return;
    };
    if *first == "**" {
        if !rest.is_empty() {
            walk(base, rest, out);
        }
        for c in children(base) {
            if std::fs::symlink_metadata(&c).is_ok_and(|m| m.is_dir()) {
                walk(&c, comps, out);
            } else if rest.is_empty() && is_file(&c) {
                out.push(c);
            }
        }
    } else if first.contains(['*', '?']) {
        for c in children(base) {
            if c.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| crate::scenario::glob(first, n))
            {
                walk(&c, rest, out);
            }
        }
    } else {
        walk(&base.join(first), rest, out);
    }
}

/// The regular files an absolute glob names: `*` and `?` within a component, `**` for any depth.
pub fn expand(pattern: &str) -> Vec<PathBuf> {
    let comps: Vec<&str> = pattern.split('/').filter(|c| !c.is_empty()).collect();
    let mut out = vec![];
    walk(Path::new("/"), &comps, &mut out);
    out
}

/// No file of PATTERNS contains TEXT (bytes, binary files too); at least one file must exist.
pub fn file_grep_absent(patterns: &[String], text: &[u8]) -> R {
    if text.is_empty() {
        return Err("\"absent\" is not empty".into());
    }
    let mut seen = 0;
    for pattern in patterns {
        for f in expand(pattern) {
            seen += 1;
            let bytes = std::fs::read(&f).map_err(|e| format!("{}: {e}", f.display()))?;
            if bytes.windows(text.len()).any(|w| w == text) {
                return Err(format!(
                    "{} contains {:?}",
                    f.display(),
                    String::from_utf8_lossy(text)
                ));
            }
        }
    }
    if seen == 0 {
        return Err(format!("no file matches {patterns:?}"));
    }
    Ok(())
}

// ------------------------------------------------------------------------------------------ capture_stdout

/// A small regex form: literal text with at most one capture group `(\d+)`, `([0-9]+)`, `(\w+)`, `(\S+)` or `(.+)`.
/// The group's text is returned (the matched text, with no group).  `\x` in the literals is `x`.
pub fn capture_line(pattern: &str, line: &str) -> R<Option<String>> {
    fn unescape(s: &str) -> String {
        let mut out = String::new();
        let mut it = s.chars();
        while let Some(c) = it.next() {
            if c == '\\' {
                out.extend(it.next());
            } else {
                out.push(c);
            }
        }
        out
    }
    let Some((prefix, rest)) = pattern.split_once('(') else {
        let lit = unescape(pattern);
        return Ok(line.contains(&lit).then_some(lit));
    };
    let (group, suffix) = rest.split_once(')').ok_or("\"regex\": an unclosed group")?;
    let class: fn(char) -> bool = match group {
        "\\d+" | "[0-9]+" => |c| c.is_ascii_digit(),
        "\\w+" => |c| c.is_alphanumeric() || c == '_',
        "\\S+" => |c| !c.is_whitespace(),
        ".+" => |_| true,
        other => {
            return Err(format!(
                "\"regex\": the group ({other}) is not one of \\d+ [0-9]+ \\w+ \\S+ .+"
            ));
        }
    };
    let (prefix, suffix) = (unescape(prefix), unescape(suffix));
    for (i, _) in line.match_indices(prefix.as_str()) {
        let after = &line[i + prefix.len()..];
        let run: String = after.chars().take_while(|c| class(*c)).collect();
        // greedy, then backing off until the suffix follows
        let mut len = run.len();
        while len > 0 {
            if after[len..].starts_with(&suffix) {
                return Ok(Some(after[..len].to_string()));
            }
            len -= after[..len].chars().next_back().map_or(1, char::len_utf8);
        }
    }
    Ok(None)
}

/// The first match of PATTERN on a line of the child's stdout within `within`; the rest is drained.
pub fn wait_capture(out: std::process::ChildStdout, pattern: &str, within: Duration) -> R<String> {
    use std::io::BufRead;
    capture_line(pattern, "")?; // a bad pattern is an error now
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for line in std::io::BufReader::new(out).lines().map_while(Result::ok) {
            // once nobody listens the send fails; the loop keeps draining so the child never blocks on a full pipe
            let _ = tx.send(line);
        }
    });
    let deadline = Instant::now() + within;
    let mut seen = vec![];
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        match rx.recv_timeout(left) {
            Ok(line) => {
                if let Some(m) = capture_line(pattern, &line)? {
                    return Ok(m);
                }
                seen.push(line);
            }
            Err(_) => return Err(format!("stdout never matched {pattern:?} (saw {seen:?})")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_line_takes_the_group() {
        assert_eq!(
            capture_line(r"MOCK-LLM-PORT (\d+)", "MOCK-LLM-PORT 4242").unwrap(),
            Some("4242".into())
        );
        assert_eq!(capture_line(r"MOCK-LLM-PORT (\d+)", "other").unwrap(), None);
        assert_eq!(
            capture_line(r"port=(\S+);", "port=ab:1;").unwrap(),
            Some("ab:1".into())
        );
        assert!(capture_line(r"x(a|b)", "xa").is_err());
    }

    #[test]
    fn chunked_bodies_decode() {
        assert_eq!(
            decode_chunked(b"3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"),
            (b"abcde".to_vec(), true)
        );
        assert_eq!(
            decode_chunked(b"3\r\nabc\r\n2\r\nd"),
            (b"abcd".to_vec(), false)
        );
    }

    #[test]
    fn globs_and_grep_find_bytes() {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(d.path().join("a/b")).unwrap();
        std::fs::write(d.path().join("a/x.log"), b"hello secret!").unwrap();
        std::fs::write(d.path().join("a/b/y.db"), b"\0\0token\0").unwrap();
        let root = d.path().display();
        assert_eq!(expand(&format!("{root}/a/*.log")).len(), 1);
        assert_eq!(expand(&format!("{root}/**")).len(), 2);
        assert_eq!(expand(&format!("{root}/**/y.db")).len(), 1);
        let all = [format!("{root}/**")];
        assert!(file_grep_absent(&all, b"nothing").is_ok());
        assert!(
            file_grep_absent(&all, b"token")
                .unwrap_err()
                .contains("y.db")
        );
        assert!(
            file_grep_absent(&[format!("{root}/none/*")], b"x").is_err(),
            "a glob that names no file is a mistake"
        );
    }
}
