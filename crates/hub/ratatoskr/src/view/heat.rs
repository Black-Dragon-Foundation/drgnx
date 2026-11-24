//! The minimap's heat layers (design X3, docs/develop/core.md "Minimap"): per-line values of one source, 0..=1000,
//! as spans the hub pushes to Sjá as `heat:S` ([`super::minimap`]).  Each span keeps a fact (the peek's text, "2 days
//! ago · 9f3c21e read tables lazily · r.okafor"); the wire sends it once Sjá reads a 4th item element (Task 15).
//!
//! Sources, each a pure function here:
//! - **blame:** git's blame of the file ([`blame`]): the newest line 1000, the oldest 0, uncommitted lines 1000;
//! - **coverage:** an lcov tracefile, a Cobertura XML report or llvm-cov's JSON export ([`coverage`]): a covered line
//!   1000, an uncovered one 0;
//! - **profile:** pprof (gzipped or not), `perf script` with source lines, or a speedscope file ([`profile`]): each
//!   line's own samples (or self time), the hottest line 1000;
//! - **agent-read:** the `read` steps of the Work space's timeline ([`agent_read`]): how often agents read the line,
//!   the most-read line 1000.
//!
//! A report names files by absolute path or relative to where it ran; a name matches the minimap's file when it is
//! the file or a suffix of it at a `/` ([`names_file`]).

use runstav::methods::history::GitBlamed;
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};

/// The largest coverage report or profile read, in bytes (after a pprof file is unzipped).
pub const REPORT_MAX: u64 = 256 << 20;

/// One run of lines with the same value and fact, lines from 1.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Span {
    pub first: u32,
    pub last: u32,
    pub value: u16,
    pub fact: String,
}

/// Each line's value and fact, as spans: neighbouring lines with the same both become one.
pub fn spans(lines: BTreeMap<u32, (u16, String)>) -> Vec<Span> {
    let mut out: Vec<Span> = Vec::new();
    for (line, (value, fact)) in lines {
        if line == 0 {
            continue;
        }
        match out.last_mut() {
            Some(s) if s.last + 1 == line && s.value == value && s.fact == fact => s.last = line,
            _ => out.push(Span {
                first: line,
                last: line,
                value: value.min(1000),
                fact,
            }),
        }
    }
    out
}

/// Whether a report's NAME for a file is FILE (absolute): the same path, or, relative, a suffix of FILE at a `/`.
pub fn names_file(name: &str, file: &str) -> bool {
    let name = name.trim_start_matches("./");
    if name.is_empty() {
        return false;
    }
    if name.starts_with('/') {
        return name == file;
    }
    file.strip_suffix(name)
        .is_some_and(|head| head.ends_with('/'))
}

fn scaled(w: f64, max: f64) -> u16 {
    if max <= 0.0 {
        0
    } else {
        ((w / max) * 1000.0).round().clamp(0.0, 1000.0) as u16
    }
}

// ---------------------------------------------------------------------------------------------------------------
// blame

/// How long ago SECS (seconds) is, as a person says it.
fn ago(secs: i64) -> String {
    let s = secs.max(0);
    let (n, unit) = match s {
        s if s < 3600 => (s / 60, "minute"),
        s if s < 86_400 => (s / 3600, "hour"),
        s if s < 86_400 * 31 => (s / 86_400, "day"),
        s if s < 86_400 * 365 => (s / (86_400 * 30), "month"),
        s => (s / (86_400 * 365), "year"),
    };
    match n {
        0 => "just now".into(),
        1 => format!("1 {unit} ago"),
        n => format!("{n} {unit}s ago"),
    }
}

/// The blame layer of B at NOW (seconds since the epoch): each line's age between the file's oldest and newest
/// commit, newest 1000; lines not committed are 1000 and "not committed".
pub fn blame(b: &GitBlamed, now: i64) -> Vec<Span> {
    let times: Vec<i64> = b.commits.iter().filter_map(|c| c.time).collect();
    let (lo, hi) = (
        times.iter().copied().min().unwrap_or(0),
        times.iter().copied().max().unwrap_or(0),
    );
    let mut lines = BTreeMap::new();
    for (i, &ci) in b.lines.iter().enumerate() {
        let Some(c) = b.commits.get(ci as usize) else {
            continue;
        };
        let line = u32::try_from(i + 1).unwrap_or(u32::MAX);
        let v = match c.time {
            None => (1000, "not committed".to_string()),
            Some(t) => (
                if hi > lo {
                    scaled((t - lo) as f64, (hi - lo) as f64)
                } else {
                    1000
                },
                format!(
                    "{} · {} {} · {}",
                    ago(now - t),
                    c.sha.get(..7).unwrap_or(&c.sha),
                    c.summary,
                    c.author
                ),
            ),
        };
        lines.insert(line, v);
    }
    spans(lines)
}

// ---------------------------------------------------------------------------------------------------------------
// coverage

/// Each line of FILE a report counts, with its hit count; lines a report lists twice add up.
type Hits = BTreeMap<u32, u64>;

fn covered(hits: Hits) -> Vec<Span> {
    spans(
        hits.into_iter()
            .map(|(l, h)| {
                let v = if h > 0 {
                    (
                        1000,
                        format!("covered · {h} hit{}", if h == 1 { "" } else { "s" }),
                    )
                } else {
                    (0, "not covered".to_string())
                };
                (l, v)
            })
            .collect(),
    )
}

/// The lines of FILE in an lcov tracefile (`SF:`, `DA:line,hits`, `end_of_record`).
pub fn lcov(text: &str, file: &str) -> Hits {
    let mut hits = Hits::new();
    let mut ours = false;
    for l in text.lines() {
        if let Some(sf) = l.strip_prefix("SF:") {
            ours = names_file(sf.trim(), file);
        } else if l == "end_of_record" {
            ours = false;
        } else if ours && let Some(da) = l.strip_prefix("DA:") {
            let mut it = da.split(',');
            if let (Some(Ok(line)), Some(Ok(h))) = (
                it.next().map(|s| s.trim().parse::<u32>()),
                it.next().map(|s| s.trim().parse::<u64>()),
            ) {
                *hits.entry(line).or_default() += h;
            }
        }
    }
    hits
}

/// The lines of FILE in a Cobertura report (`<class filename=…>` with `<line number= hits=>`); none when it is not
/// XML.
pub fn cobertura(xml: &str, file: &str) -> Hits {
    use quick_xml::XmlVersion::Implicit1_0;
    use quick_xml::events::Event;
    let mut hits = Hits::new();
    let mut r = quick_xml::Reader::from_str(xml);
    let mut ours = false;
    let attr = |e: &quick_xml::events::BytesStart<'_>, k: &str| -> Option<String> {
        e.try_get_attribute(k)
            .ok()
            .flatten()
            .and_then(|a| a.normalized_value(Implicit1_0).ok().map(|v| v.into_owned()))
    };
    loop {
        let (e, start) = match r.read_event() {
            Ok(Event::Start(e)) => (e, true),
            Ok(Event::Empty(e)) => (e, false),
            Ok(Event::End(e)) => {
                if e.local_name().as_ref() == "class" {
                    ours = false;
                }
                continue;
            }
            Ok(Event::Eof) | Err(_) => break,
            Ok(_) => continue,
        };
        match e.local_name().as_ref() {
            "class" => ours = start && attr(&e, "filename").is_some_and(|n| names_file(&n, file)),
            "line" if ours => {
                if let (Some(Ok(line)), Some(Ok(h))) = (
                    attr(&e, "number").map(|s| s.parse::<u32>()),
                    attr(&e, "hits").map(|s| s.parse::<u64>()),
                ) {
                    *hits.entry(line).or_default() += h;
                }
            }
            _ => {}
        }
    }
    hits
}

/// The lines of FILE in llvm-cov's JSON export (`data[].files[]`, each `filename` and `segments` `[line, col, count,
/// has_count, is_region_entry, is_gap_region]`): a line's count is the largest of the counted regions that start on
/// it, else the count of the region it lies in; gap regions count nothing.
pub fn llvm_cov(json: &Value, file: &str) -> Hits {
    let mut hits = Hits::new();
    let files = json["data"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|d| d["files"].as_array().into_iter().flatten());
    for f in files.filter(|f| f["filename"].as_str().is_some_and(|n| names_file(n, file))) {
        let segs: Vec<(u32, u64, bool, bool)> = f["segments"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|s| {
                let s = s.as_array()?;
                Some((
                    u32::try_from(s.first()?.as_u64()?).ok()?,
                    s.get(2)?.as_u64()?,
                    s.get(3)?.as_bool()?,
                    s.get(5).and_then(Value::as_bool).unwrap_or(false),
                ))
            })
            .collect();
        // the region a line starts in: the last segment before it
        let mut wrapped: Option<(u64, bool)> = None;
        let mut i = 0;
        while i < segs.len() {
            let line = segs[i].0;
            let mut starts: Option<u64> = None;
            let entering = wrapped;
            while i < segs.len() && segs[i].0 == line {
                let (_, count, has, gap) = segs[i];
                if has && !gap {
                    starts = Some(starts.map_or(count, |c: u64| c.max(count)));
                }
                wrapped = Some((count, has && !gap));
                i += 1;
            }
            let here = starts.or(entering.filter(|e| e.1).map(|e| e.0));
            if let Some(c) = here {
                *hits.entry(line).or_default() += c;
            }
            // the lines up to the next segment lie in this one's region
            let next = segs.get(i).map_or(line, |s| s.0);
            if let Some((count, true)) = wrapped {
                for l in line + 1..next {
                    *hits.entry(l).or_default() += count;
                }
            }
        }
    }
    hits
}

/// The coverage layer of FILE from a report's BYTES, read by its kind: Cobertura (XML), llvm-cov (JSON), else lcov.
pub fn coverage(bytes: &[u8], file: &str) -> Vec<Span> {
    let text = String::from_utf8_lossy(bytes);
    let head = text.trim_start();
    let hits = if head.starts_with('<') {
        cobertura(&text, file)
    } else if head.starts_with('{') {
        serde_json::from_str::<Value>(&text)
            .map(|v| llvm_cov(&v, file))
            .unwrap_or_default()
    } else {
        lcov(&text, file)
    };
    covered(hits)
}

// ---------------------------------------------------------------------------------------------------------------
// profile

/// Each (file name as the profile has it, line) and its own weight.
type Weights = HashMap<(String, u32), f64>;

/// The profile layer of FILE from a profile's BYTES, read by its kind: pprof (protobuf, gzipped or not), speedscope
/// (JSON), else `perf script` text.  The hottest line is 1000.
pub fn profile(bytes: &[u8], file: &str) -> Vec<Span> {
    let w = if bytes.starts_with(&[0x1f, 0x8b]) {
        let mut out = Vec::new();
        use std::io::Read;
        crate::soft::done(
            flate2::read::GzDecoder::new(bytes)
                .take(REPORT_MAX)
                .read_to_end(&mut out),
            "flate2::read::GzDecoder::new",
        );
        pprof(&out)
    } else if bytes.trim_ascii_start().starts_with(b"{") {
        serde_json::from_slice::<Value>(bytes)
            .map(|v| speedscope(&v))
            .unwrap_or_default()
    } else {
        // an unzipped pprof starts with its first sample type (field 1, length-delimited: 0x0a); text never parses
        // as one, so a text that starts with a newline still reads as `perf script`
        Some(bytes)
            .filter(|b| b.first() == Some(&0x0a))
            .map(pprof)
            .filter(|w| !w.is_empty())
            .unwrap_or_else(|| perf_script(&String::from_utf8_lossy(bytes)))
    };
    let mine: BTreeMap<u32, f64> = w
        .into_iter()
        .filter(|((n, _), _)| names_file(n, file))
        .fold(BTreeMap::new(), |mut m, ((_, l), w)| {
            *m.entry(l).or_default() += w;
            m
        });
    let total: f64 = mine.values().sum();
    let max = mine.values().copied().fold(0.0, f64::max);
    spans(
        mine.into_iter()
            .map(|(l, w)| {
                let pct = if total > 0.0 { 100.0 * w / total } else { 0.0 };
                (
                    l,
                    (scaled(w, max), format!("{pct:.1} % of this file's samples")),
                )
            })
            .collect(),
    )
}

/// `perf script` output with source lines (`-F +srcline`): each sample's first frame that has a `path:line` line
/// under it gets the sample.
pub fn perf_script(text: &str) -> Weights {
    let mut w = Weights::new();
    let mut taken = false;
    for l in text.lines() {
        if l.trim().is_empty() {
            taken = false;
            continue;
        }
        if !l.starts_with([' ', '\t']) {
            // a sample's header line
            taken = false;
            continue;
        }
        let t = l.trim();
        if taken || t.contains(' ') {
            continue;
        }
        if let Some((path, line)) = t.rsplit_once(':')
            && let Ok(n) = line.parse::<u32>()
            && !path.is_empty()
        {
            *w.entry((path.to_string(), n)).or_default() += 1.0;
            taken = true;
        }
    }
    w
}

/// A speedscope file: a sampled profile's samples (each stack's last frame, by its weight) and an evented one's self
/// time, for frames that name a `file` and `line`.
pub fn speedscope(v: &Value) -> Weights {
    let frames: Vec<Option<(String, u32)>> = v["shared"]["frames"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|f| {
            Some((
                f["file"].as_str()?.to_string(),
                u32::try_from(f["line"].as_u64()?).ok()?,
            ))
        })
        .collect();
    let mut w = Weights::new();
    let mut add = |frame: Option<u64>, by: f64| {
        if let Some(Some(k)) = frame.and_then(|i| frames.get(usize::try_from(i).ok()?)) {
            *w.entry(k.clone()).or_default() += by;
        }
    };
    for p in v["profiles"].as_array().into_iter().flatten() {
        match p["type"].as_str() {
            Some("sampled") => {
                let weights = p["weights"].as_array();
                for (i, s) in p["samples"].as_array().into_iter().flatten().enumerate() {
                    let by = weights
                        .and_then(|ws| ws.get(i))
                        .and_then(Value::as_f64)
                        .unwrap_or(1.0);
                    add(
                        s.as_array().and_then(|s| s.last()).and_then(Value::as_u64),
                        by,
                    );
                }
            }
            Some("evented") => {
                let mut stack: Vec<u64> = Vec::new();
                let mut at = p["startValue"].as_f64().unwrap_or(0.0);
                for e in p["events"].as_array().into_iter().flatten() {
                    let t = e["at"].as_f64().unwrap_or(at);
                    add(stack.last().copied(), (t - at).max(0.0));
                    at = t;
                    match (e["type"].as_str(), e["frame"].as_u64()) {
                        (Some("O"), Some(f)) => stack.push(f),
                        (Some("C"), Some(_)) => {
                            stack.pop();
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    w
}

/// A protobuf message's fields: (number, varint value or the bytes of a length-delimited one).  Stops at the first
/// field it cannot read.
fn fields(mut b: &[u8]) -> Vec<(u64, Result<u64, &[u8]>)> {
    fn varint(b: &mut &[u8]) -> Option<u64> {
        let mut v = 0u64;
        for shift in (0..64).step_by(7) {
            let (&x, rest) = b.split_first()?;
            *b = rest;
            v |= u64::from(x & 0x7f) << shift;
            if x & 0x80 == 0 {
                return Some(v);
            }
        }
        None
    }
    let mut out = Vec::new();
    while !b.is_empty() {
        let Some(key) = varint(&mut b) else { break };
        let (n, wire) = (key >> 3, key & 7);
        match wire {
            0 => match varint(&mut b) {
                Some(v) => out.push((n, Ok(v))),
                None => break,
            },
            1 | 5 => {
                let k = if wire == 1 { 8 } else { 4 };
                if b.len() < k {
                    break;
                }
                b = &b[k..];
            }
            2 => {
                let Some(len) = varint(&mut b).and_then(|l| usize::try_from(l).ok()) else {
                    break;
                };
                if b.len() < len {
                    break;
                }
                out.push((n, Err(&b[..len])));
                b = &b[len..];
            }
            _ => break,
        }
    }
    out
}

/// A repeated integer field, packed (bytes) or not (one value).
fn ints(v: &Result<u64, &[u8]>) -> Vec<u64> {
    match v {
        Ok(x) => vec![*x],
        Err(b) => {
            let mut b = *b;
            let mut out = Vec::new();
            while !b.is_empty() {
                let mut v = 0u64;
                let mut ok = false;
                for shift in (0..64).step_by(7) {
                    let Some((&x, rest)) = b.split_first() else {
                        break;
                    };
                    b = rest;
                    v |= u64::from(x & 0x7f) << shift;
                    if x & 0x80 == 0 {
                        ok = true;
                        break;
                    }
                }
                if !ok {
                    break;
                }
                out.push(v);
            }
            out
        }
    }
}

/// A pprof profile (profile.proto, unzipped): each sample's first value goes to its leaf location's innermost line
/// (a location's first `line`; later ones are the callers it was inlined into).
pub fn pprof(b: &[u8]) -> Weights {
    let top = fields(b);
    let strings: Vec<String> = top
        .iter()
        .filter(|(n, _)| *n == 6)
        .map(|(_, v)| match v {
            Err(s) => String::from_utf8_lossy(s).into_owned(),
            Ok(_) => String::new(),
        })
        .collect();
    let field = |msg: &[u8], k: u64| -> Option<u64> {
        fields(msg)
            .into_iter()
            .find(|(n, _)| *n == k)
            .and_then(|(_, v)| v.ok())
    };
    // function id → its file name
    let mut func_file: HashMap<u64, String> = HashMap::new();
    for (_, v) in top.iter().filter(|(n, _)| *n == 5) {
        if let Err(m) = v
            && let (Some(id), Some(fi)) = (field(m, 1), field(m, 4))
            && let Some(s) = usize::try_from(fi).ok().and_then(|i| strings.get(i))
        {
            func_file.insert(id, s.clone());
        }
    }
    // location id → (file, line) of its innermost line
    let mut loc: HashMap<u64, (String, u32)> = HashMap::new();
    for (_, v) in top.iter().filter(|(n, _)| *n == 4) {
        let Err(m) = v else { continue };
        let Some(id) = field(m, 1) else { continue };
        let first_line = fields(m).into_iter().find(|(n, _)| *n == 4);
        if let Some((_, Err(line))) = first_line
            && let (Some(fid), Some(ln)) = (field(line, 1), field(line, 2))
            && let (Some(file), Ok(ln)) = (func_file.get(&fid), u32::try_from(ln))
        {
            loc.insert(id, (file.clone(), ln));
        }
    }
    let mut w = Weights::new();
    for (_, v) in top.iter().filter(|(n, _)| *n == 2) {
        let Err(m) = v else { continue };
        let fs = fields(m);
        let leaf = fs
            .iter()
            .find(|(n, _)| *n == 1)
            .and_then(|(_, v)| ints(v).first().copied());
        let value = fs
            .iter()
            .find(|(n, _)| *n == 2)
            .and_then(|(_, v)| ints(v).first().copied())
            .map_or(1.0, |x| x as i64 as f64);
        if let Some(k) = leaf.and_then(|l| loc.get(&l)) {
            *w.entry(k.clone()).or_default() += value;
        }
    }
    w
}

// ---------------------------------------------------------------------------------------------------------------
// agent-read

/// The agent-read layer of a file of LINES lines from its `read` steps, (first line, last line, agent) each, lines
/// from 1 (none: from the start; no last: to the end): how many reads cover each line, the most-read 1000.  A sweep
/// over the reads' edges: a whole-file read of a long file costs no more than a short one.
pub fn agent_read(reads: &[(Option<u32>, Option<u32>, Option<String>)], lines: u32) -> Vec<Span> {
    let ranges: Vec<(u32, u32, Option<&str>)> = reads
        .iter()
        .map(|(a, b, who)| {
            (
                a.unwrap_or(1).max(1),
                b.unwrap_or(lines).min(lines),
                who.as_deref(),
            )
        })
        .filter(|(a, b, _)| a <= b)
        .collect();
    let mut edges: Vec<u32> = ranges.iter().flat_map(|(a, b, _)| [*a, b + 1]).collect();
    edges.sort_unstable();
    edges.dedup();
    let mut runs: Vec<(u32, u32, u32, String)> = Vec::new();
    for w in edges.windows(2) {
        let (a, b) = (w[0], w[1] - 1);
        let on: Vec<&(u32, u32, Option<&str>)> =
            ranges.iter().filter(|r| r.0 <= a && a <= r.1).collect();
        if on.is_empty() {
            continue;
        }
        let mut who: Vec<&str> = on.iter().filter_map(|r| r.2).collect();
        who.sort_unstable();
        who.dedup();
        let n = u32::try_from(on.len()).unwrap_or(u32::MAX);
        let fact = if who.is_empty() {
            format!("read {n}×")
        } else {
            format!("read {n}× · {}", who.join(", "))
        };
        runs.push((a, b, n, fact));
    }
    let max = runs.iter().map(|r| r.2).max().unwrap_or(0);
    let mut out: Vec<Span> = Vec::new();
    for (a, b, n, fact) in runs {
        let value = scaled(f64::from(n), f64::from(max));
        match out.last_mut() {
            Some(s) if s.last + 1 == a && s.value == value && s.fact == fact => s.last = b,
            _ => out.push(Span {
                first: a,
                last: b,
                value,
                fact,
            }),
        }
    }
    out
}

#[cfg(test)]
mod tests;
