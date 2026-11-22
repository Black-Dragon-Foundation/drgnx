//! A huge file's density strip (design M7, state C, §7.6): past the density limit the editor has no line model, so
//! the hub scans the file on disk.  It reads [`BLOCK`] blocks, splits the file into at most [`BUCKETS`] equal byte
//! ranges, and counts per bucket its ink (the bytes that are not whitespace: the strip's brightness, so blank and
//! sparse stretches read dim) and the lines that match the error and warning expressions (counted where each line
//! starts, each expression on its own, as `grep -c` counts).  The table goes out in parts: the first before
//! [`FIRST_PART`] passes (once the next block, as slow as the slowest so far, could end past it), then at each
//! further tenth of the file, then whole.  The scan stops when its watch goes
//! or asks again, and starts over when the file changes on disk under it; after it, the file is looked at every
//! [`POLL`] and scanned again when it changed.

use regex::bytes::Regex;
use std::fs::File;
use std::io::{self, Read};
use std::path::Path;
use std::time::{Duration, Instant, SystemTime};

/// The blocks the scan reads.
pub const BLOCK: usize = 4 << 20;
/// The most buckets a file has.
pub const BUCKETS: u64 = 1024;
/// When the first part goes out at the latest (the large-files first-paint budget).
pub const FIRST_PART: Duration = Duration::from_millis(250);
/// How often a scanned file is looked at for a change.
pub const POLL: Duration = Duration::from_secs(2);
/// The longest line a bucket peek shows, in bytes.
pub const PEEK_LINE_MAX: usize = 400;

/// One bucket: its ink, error lines and warning lines.
pub type Bucket = (u64, u32, u32);

/// What a file was when it was scanned: a change to either means scanning again.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stamp {
    pub len: u64,
    pub modified: Option<SystemTime>,
}

/// PATH's stamp, or none when it cannot be read.
pub fn stamp(path: &Path) -> Option<Stamp> {
    let m = std::fs::metadata(path).ok()?;
    m.is_file().then(|| Stamp {
        len: m.len(),
        modified: m.modified().ok(),
    })
}

/// How many bytes each bucket of a file of LEN bytes holds (the last may hold fewer) and how many buckets it has.
pub fn geometry(len: u64) -> (u64, u32) {
    let size = len.div_ceil(BUCKETS).max(1);
    (size, len.div_ceil(size).max(1) as u32)
}

/// How a scan ended.
#[derive(Debug, PartialEq)]
pub enum Scanned {
    /// The whole table, of the file as STAMP.
    Done(Vec<Bucket>, Stamp),
    /// The watch went or asked again.
    Cancelled,
    /// The file changed under the scan.
    Changed,
}

/// Scan PATH, as stamped STAMP, for the table: PART gets each part (the buckets finished so far and the bucket count)
/// and answers whether to go on; it is asked at every block too, with no part, so a cancel stops the scan within a
/// block.  NOW is the clock the first part's deadline is read on.
pub fn scan(
    path: &Path,
    stamp: Stamp,
    error: &Regex,
    warning: &Regex,
    now: impl Fn() -> Instant,
    mut part: impl FnMut(Option<(&[Bucket], u32)>) -> bool,
) -> io::Result<Scanned> {
    let (size, count) = geometry(stamp.len);
    let mut buckets: Vec<Bucket> = vec![(0, 0, 0); count as usize];
    let mut file = File::open(path)?;
    let start = now();
    // the first part goes out before the deadline: once the next block, as slow as the slowest so far, could end
    // past it
    let (mut last, mut slowest) = (start, Duration::ZERO);
    let mut first_sent = false;
    let mut next_tenth = 1u64;
    // the block, with the unfinished last line of the one before at its head
    let mut buf: Vec<u8> = Vec::with_capacity(BLOCK + 4096);
    let mut carry_at = 0u64; // the file offset of buf[0]
    let mut read = 0u64;
    loop {
        if !part(None) {
            return Ok(Scanned::Cancelled);
        }
        let had = buf.len();
        buf.resize(had + BLOCK, 0);
        let n = read_full(&mut file, &mut buf[had..])?;
        buf.truncate(had + n);
        let eof = n == 0 || read + n as u64 >= stamp.len;
        // ink of the bytes read now, bucket by bucket
        let mut off = read;
        let mut fresh = &buf[had..];
        while !fresh.is_empty() {
            let b = (off / size) as usize;
            let room = ((b as u64 + 1) * size - off) as usize;
            let (here, rest) = fresh.split_at(room.min(fresh.len()));
            if let Some(slot) = buckets.get_mut(b) {
                slot.0 += here.iter().filter(|&&c| !c.is_ascii_whitespace()).count() as u64;
            }
            off += here.len() as u64;
            fresh = rest;
        }
        read += n as u64;
        // the whole lines held: through the last newline, or everything at the end of the file
        let whole = if eof {
            buf.len()
        } else {
            memchr::memrchr(b'\n', &buf).map_or(0, |i| i + 1)
        };
        count_lines(&buf[..whole], carry_at, size, error, warning, &mut buckets);
        buf.drain(..whole);
        carry_at += whole as u64;
        if eof {
            break;
        }
        // a part: the first before FIRST_PART passes, then at each tenth
        let done = (read / size) as u32;
        let tenth = read * 10 / stamp.len.max(1);
        let first_due = !first_sent && {
            let t = now();
            slowest = slowest.max(t.duration_since(last));
            last = t;
            t.duration_since(start) + slowest >= FIRST_PART
        };
        if first_due || (first_sent && tenth >= next_tenth) {
            first_sent = true;
            next_tenth = tenth + 1;
            if !part(Some((&buckets[..done.min(count) as usize], count))) {
                return Ok(Scanned::Cancelled);
            }
        }
        if self::stamp(path) != Some(stamp) {
            return Ok(Scanned::Changed);
        }
    }
    if self::stamp(path) != Some(stamp) {
        return Ok(Scanned::Changed);
    }
    Ok(Scanned::Done(buckets, stamp))
}

/// Fill BUF from R as far as it goes: the bytes read, fewer only at the end.
fn read_full(r: &mut impl Read, buf: &mut [u8]) -> io::Result<usize> {
    let mut n = 0;
    while n < buf.len() {
        match r.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(n)
}

/// Count TEXT's lines (whole ones, TEXT starting at file offset AT) that ERROR and WARNING match, each where its
/// line starts.
fn count_lines(
    text: &[u8],
    at: u64,
    size: u64,
    error: &Regex,
    warning: &Regex,
    buckets: &mut [Bucket],
) {
    for (re, which) in [(error, 1), (warning, 2)] {
        let mut last_line = usize::MAX;
        for m in re.find_iter(text) {
            let line = memchr::memrchr(b'\n', &text[..m.start()]).map_or(0, |i| i + 1);
            // a line counts once, whatever it matches; a match across lines counts where it starts
            if line == last_line {
                continue;
            }
            last_line = line;
            if let Some(b) = buckets.get_mut(((at + line as u64) / size) as usize) {
                if which == 1 {
                    b.1 += 1;
                } else {
                    b.2 += 1;
                }
            }
        }
    }
}

/// The first LINES lines of bucket BUCKET of PATH, as `minimap/bucket` answers: from the first line that starts in
/// the bucket (the bucket's start when it is a line's), each cut at [`PEEK_LINE_MAX`] bytes; and that line's offset
/// and the bucket count.  Reads at most what it shows.
pub fn peek(path: &Path, bucket: u32, lines: u32) -> io::Result<(String, u64, u32)> {
    use std::io::{BufRead, BufReader, Seek, SeekFrom};
    let len = std::fs::metadata(path)?.len();
    let (size, count) = geometry(len);
    let at = (u64::from(bucket) * size).min(len);
    let mut r = BufReader::new(File::open(path)?);
    let mut start = at;
    if at > 0 {
        // back one byte: a bucket starting just after a newline starts with its line
        r.seek(SeekFrom::Start(at - 1))?;
        let mut skip = Vec::new();
        r.by_ref().take(1 << 20).read_until(b'\n', &mut skip)?;
        start = at - 1 + skip.len() as u64;
    }
    let mut out = Vec::new();
    for _ in 0..lines {
        let mut line = Vec::new();
        let n = r.by_ref().take(1 << 20).read_until(b'\n', &mut line)?;
        if n == 0 {
            break;
        }
        while line.last().is_some_and(|c| *c == b'\n' || *c == b'\r') {
            line.pop();
        }
        line.truncate(PEEK_LINE_MAX);
        out.push(String::from_utf8_lossy(&line).into_owned());
    }
    Ok((out.join("\n"), start, count))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn re(s: &str) -> Regex {
        Regex::new(s).unwrap()
    }

    /// A log of LINES lines, every 7th an ERROR, every 11th a WARN, every 13th blank.
    fn log(dir: &Path, lines: usize) -> std::path::PathBuf {
        let p = dir.join("big.log");
        let mut f = std::io::BufWriter::new(File::create(&p).unwrap());
        for i in 0..lines {
            if i % 13 == 0 {
                writeln!(f).unwrap();
            } else if i % 7 == 0 {
                writeln!(f, "2026-11-20 12:00:{:02} ERROR request {i} failed", i % 60).unwrap();
            } else if i % 11 == 0 {
                writeln!(f, "2026-11-20 12:00:{:02} WARN slow request {i}", i % 60).unwrap();
            } else {
                writeln!(f, "2026-11-20 12:00:{:02} INFO request {i} ok", i % 60).unwrap();
            }
        }
        p
    }

    fn grep_c(p: &Path, re: &Regex) -> u32 {
        std::fs::read(p)
            .unwrap()
            .split(|c| *c == b'\n')
            .filter(|l| re.is_match(l))
            .count() as u32
    }

    /// The buckets tile the file (their ranges sum to its size), the ink is its non-whitespace bytes, and the error
    /// and warning counts are `grep -c`'s, over a file of many blocks whose lines cross block boundaries.
    #[test]
    fn the_buckets_tile_the_file_and_the_counts_are_greps() {
        let dir = tempfile::tempdir().unwrap();
        let p = log(dir.path(), 600_000);
        let st = stamp(&p).unwrap();
        assert!(
            st.len > 3 * BLOCK as u64,
            "the log spans blocks: {}",
            st.len
        );
        let (error, warning) = (re("ERROR|FATAL"), re("WARN"));
        let Scanned::Done(b, _) = scan(&p, st, &error, &warning, Instant::now, |_| true).unwrap()
        else {
            panic!("not done")
        };
        let (size, count) = geometry(st.len);
        assert_eq!(b.len() as u32, count);
        assert!(count <= BUCKETS as u32);
        let spans: u64 = (0..u64::from(count))
            .map(|i| ((i + 1) * size).min(st.len) - i * size)
            .sum();
        assert_eq!(spans, st.len);
        assert!(size * u64::from(count) >= st.len && size * (u64::from(count) - 1) < st.len);
        let text = std::fs::read(&p).unwrap();
        let ink = text.iter().filter(|c| !c.is_ascii_whitespace()).count() as u64;
        assert_eq!(b.iter().map(|x| x.0).sum::<u64>(), ink);
        assert_eq!(b.iter().map(|x| x.1).sum::<u32>(), grep_c(&p, &error));
        assert_eq!(b.iter().map(|x| x.2).sum::<u32>(), grep_c(&p, &warning));
    }

    /// The first part goes out once [`FIRST_PART`] passed (a clock that jumps past it at the second block), then a
    /// part at each tenth, with the finished buckets so far, never more than the file's.
    #[test]
    fn parts_go_out_first_at_the_deadline_then_each_tenth() {
        let dir = tempfile::tempdir().unwrap();
        let p = log(dir.path(), 900_000);
        let st = stamp(&p).unwrap();
        let t0 = Instant::now();
        let calls = std::cell::Cell::new(0u32);
        let clock = || {
            calls.set(calls.get() + 1);
            if calls.get() > 2 { t0 + FIRST_PART } else { t0 }
        };
        let mut parts: Vec<(usize, u32)> = Vec::new();
        let r = scan(&p, st, &re("ERROR"), &re("WARN"), clock, |part| {
            if let Some((b, n)) = part {
                parts.push((b.len(), n));
            }
            true
        })
        .unwrap();
        assert!(matches!(r, Scanned::Done(..)));
        assert!(!parts.is_empty());
        assert!(parts.len() <= 11, "{parts:?}");
        assert!(parts.windows(2).all(|w| w[0].0 < w[1].0), "{parts:?}");
        assert!(parts.iter().all(|(b, n)| *b as u32 <= *n));
    }

    /// The first part goes out within [`FIRST_PART`], not after it: at the block after which the next one, as slow as
    /// the slowest so far, could end past the deadline (blocks of 100 ms on the clock: at 200 ms, not 300).
    #[test]
    fn the_first_part_goes_out_before_the_deadline() {
        let dir = tempfile::tempdir().unwrap();
        let p = log(dir.path(), 900_000);
        let st = stamp(&p).unwrap();
        let at = std::cell::Cell::new(Instant::now());
        // the scan's own start is the clock's first reading; the deadline counts from it
        let t0 = std::cell::Cell::new(None);
        let clock = || {
            at.set(at.get() + Duration::from_millis(100));
            t0.set(t0.get().or(Some(at.get())));
            at.get()
        };
        let mut first = None;
        scan(&p, st, &re("ERROR"), &re("WARN"), clock, |part| {
            if part.is_some() && first.is_none() {
                first = Some(at.get().duration_since(t0.get().unwrap()));
            }
            true
        })
        .unwrap();
        let first = first.expect("a part went out");
        assert!(first <= FIRST_PART, "the first part at {first:?}");
    }

    /// The perf lane's 200 MB generated log (design §9, state C): the buckets tile the file, the error and warning
    /// counts are `grep -c`'s, the first part goes out within [`FIRST_PART`] on the real clock, and a close (the part
    /// callback answering no) stops the scan within a block.  Ignored in normal runs: release, pinned
    /// (`perf-exclusive.sh env DRGNX_PERF_CPUS=4 cargo test --release -p drgnx-ratatoskr --lib -- --ignored
    /// --nocapture density_200mb`; docs/develop/perf.md).
    #[test]
    #[ignore = "perf lane"]
    fn density_200mb_log() {
        let dir = tempfile::tempdir().unwrap();
        let p = log(dir.path(), 5_600_000);
        let st = stamp(&p).unwrap();
        assert!(st.len >= 200 << 20, "the log is 200 MB: {}", st.len);
        let (error, warning) = (re("ERROR|FATAL"), re("WARN"));
        let t0 = Instant::now();
        let (mut first, mut parts) = (None, 0u32);
        let r = scan(&p, st, &error, &warning, Instant::now, |part| {
            if part.is_some() {
                parts += 1;
                first.get_or_insert(t0.elapsed());
            }
            true
        })
        .unwrap();
        let whole = t0.elapsed();
        let Scanned::Done(b, _) = r else {
            panic!("not done: {r:?}")
        };
        let (size, count) = geometry(st.len);
        assert_eq!((b.len() as u32, count), (1024, 1024));
        let spans: u64 = (0..u64::from(count))
            .map(|i| ((i + 1) * size).min(st.len) - i * size)
            .sum();
        assert_eq!(spans, st.len, "the buckets tile the file");
        assert_eq!(b.iter().map(|x| x.1).sum::<u32>(), grep_c(&p, &error));
        assert_eq!(b.iter().map(|x| x.2).sum::<u32>(), grep_c(&p, &warning));
        eprintln!("density-200mb: first part {first:?}, {parts} parts, whole scan {whole:?}");
        if let Some(first) = first {
            assert!(first <= FIRST_PART, "the first part at {first:?}");
        }
        let t1 = Instant::now();
        let mut blocks = 0;
        let r = scan(&p, st, &error, &warning, Instant::now, |part| {
            blocks += 1;
            part.is_none() && blocks < 3
        })
        .unwrap();
        assert_eq!(
            (r, blocks),
            (Scanned::Cancelled, 3),
            "a close stops it within a block"
        );
        assert!(
            t1.elapsed() < whole,
            "the cancelled scan read only its blocks"
        );
    }

    /// A cancel stops the scan within a block; a file that changes under the scan says so.
    #[test]
    fn a_cancel_stops_it_and_a_change_restarts_it() {
        let dir = tempfile::tempdir().unwrap();
        let p = log(dir.path(), 600_000);
        let st = stamp(&p).unwrap();
        let mut asked = 0;
        let r = scan(&p, st, &re("ERROR"), &re("WARN"), Instant::now, |_| {
            asked += 1;
            asked < 2
        })
        .unwrap();
        assert_eq!(r, Scanned::Cancelled);
        assert_eq!(asked, 2, "stopped at the second block");
        let mut first = true;
        let r = scan(&p, st, &re("ERROR"), &re("WARN"), Instant::now, |_| {
            if std::mem::take(&mut first) {
                std::fs::OpenOptions::new()
                    .append(true)
                    .open(&p)
                    .unwrap()
                    .write_all(b"more\n")
                    .unwrap();
            }
            true
        })
        .unwrap();
        assert_eq!(r, Scanned::Changed);
    }

    /// A small file has a bucket per byte at most; an empty one one empty bucket.
    #[test]
    fn small_files_have_few_buckets() {
        assert_eq!(geometry(0), (1, 1));
        assert_eq!(geometry(10), (1, 10));
        assert_eq!(geometry(1024 * 3 + 1), (4, 769));
        let (size, n) = geometry(200 << 20);
        assert_eq!(n, 1024);
        assert_eq!(size * 1024, 200 << 20);
    }

    /// A bucket's peek starts at the first line that starts in it, cuts long lines, and says where it starts.
    #[test]
    fn a_bucket_peek_reads_its_first_whole_lines() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("p.log");
        let long = "x".repeat(1000);
        let mut text = String::new();
        for i in 0..4000 {
            text.push_str(&format!("line {i}\n"));
        }
        text.push_str(&long);
        text.push('\n');
        std::fs::write(&p, &text).unwrap();
        let (size, count) = geometry(text.len() as u64);
        let (t, start, n) = peek(&p, 3, 2).unwrap();
        assert_eq!(n, count);
        assert!(start >= 3 * size && text.as_bytes()[start as usize - 1] == b'\n');
        let first = &text[start as usize..];
        let want: Vec<&str> = first.lines().take(2).collect();
        assert_eq!(t, want.join("\n"));
        let (t, ..) = peek(&p, count - 1, 5).unwrap();
        assert!(t.lines().all(|l| l.len() <= PEEK_LINE_MAX));
        let (t, start, _) = peek(&p, 0, 1).unwrap();
        assert_eq!((t.as_str(), start), ("line 0", 0));
    }
}
