//! The telemetry's storage (Task 38): `<runner root>/telemetry/YYYY-MM-DD.bin`, fixed-width records, one file per day.
//!
//! A record is 96 bytes. A bucket keeps the min, max, mean and last of one metric of one id over one store window, so a
//! 20 ms spike is still in the 1 s history; a marker keeps a moment's kind and detail. Layout (little endian):
//!
//! | bytes | bucket | marker |
//! |---|---|---|
//! | 0 | kind 1 | kind 2 |
//! | 1 | level | 0 |
//! | 2 | metric | 0 |
//! | 4..8 | sample count | 0 |
//! | 8..16 | window start, epoch ms | the moment, epoch ms |
//! | 16..56 | id, zero padded | id, zero padded |
//! | 56..88 | min, max, mean, last (f64) | `kind` and `detail` as text, `kind:detail`, zero padded |
//! | 88..96 | window width, ms (u32) | 0 |

use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};

use crate::proto::telemetry::{
    Level, Marker, Point, Range, Ranged, Series, metric_code, metric_name,
};

/// The width of a record.
pub const RECORD: usize = 96;
/// The most bytes of an id a record keeps (a slot instance's id is 34).
pub const ID_BYTES: usize = 40;
/// The most bytes of a marker's `kind:detail` a record keeps.
pub const TEXT_BYTES: usize = 32;

const DAY_MS: u64 = 86_400_000;

/// What one stored window of one metric holds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Bucket {
    pub t: u64,
    pub width_ms: u32,
    pub count: u32,
    pub min: f64,
    pub max: f64,
    pub mean: f64,
    pub last: f64,
}

/// A record read back.
#[derive(Clone, Debug, PartialEq)]
pub enum Record {
    Bucket {
        level: Level,
        id: String,
        metric: &'static str,
        b: Bucket,
    },
    Marker(Marker),
}

impl Record {
    /// The record as its 96 bytes; a bucket of an unknown metric, or an id longer than [`ID_BYTES`], is cut or refused
    /// by returning none.
    pub fn encode(&self) -> Option<[u8; RECORD]> {
        let mut r = [0u8; RECORD];
        match self {
            Record::Bucket {
                level,
                id,
                metric,
                b,
            } => {
                r[0] = 1;
                r[1] = level.code();
                r[2] = metric_code(metric)?;
                r[4..8].copy_from_slice(&b.count.to_le_bytes());
                r[8..16].copy_from_slice(&b.t.to_le_bytes());
                put_text(&mut r[16..16 + ID_BYTES], id);
                for (i, v) in [b.min, b.max, b.mean, b.last].into_iter().enumerate() {
                    r[56 + 8 * i..64 + 8 * i].copy_from_slice(&v.to_le_bytes());
                }
                r[88..92].copy_from_slice(&b.width_ms.to_le_bytes());
            }
            Record::Marker(m) => {
                r[0] = 2;
                r[8..16].copy_from_slice(&m.at_ms.to_le_bytes());
                put_text(&mut r[16..16 + ID_BYTES], &m.id);
                put_text(
                    &mut r[56..56 + TEXT_BYTES],
                    &format!("{}:{}", m.kind, m.detail),
                );
            }
        }
        Some(r)
    }

    /// The record in BYTES, none for a kind, level or metric this reader does not know.
    pub fn decode(bytes: &[u8; RECORD]) -> Option<Record> {
        let f = |i: usize| {
            f64::from_le_bytes(bytes[56 + 8 * i..64 + 8 * i].try_into().unwrap_or([0; 8]))
        };
        let t = u64::from_le_bytes(bytes[8..16].try_into().ok()?);
        let id = get_text(&bytes[16..16 + ID_BYTES]);
        match bytes[0] {
            1 => Some(Record::Bucket {
                level: Level::from_code(bytes[1])?,
                id,
                metric: metric_name(bytes[2])?,
                b: Bucket {
                    t,
                    width_ms: u32::from_le_bytes(bytes[88..92].try_into().ok()?),
                    count: u32::from_le_bytes(bytes[4..8].try_into().ok()?),
                    min: f(0),
                    max: f(1),
                    mean: f(2),
                    last: f(3),
                },
            }),
            2 => {
                let text = get_text(&bytes[56..56 + TEXT_BYTES]);
                let (kind, detail) = text.split_once(':').unwrap_or((&text, ""));
                Some(Record::Marker(Marker {
                    at_ms: t,
                    id,
                    kind: kind.to_string(),
                    detail: detail.to_string(),
                }))
            }
            _ => None,
        }
    }
}

fn put_text(dst: &mut [u8], s: &str) {
    // cut at a character boundary that fits
    let mut n = s.len().min(dst.len());
    while !s.is_char_boundary(n) {
        n -= 1;
    }
    dst[..n].copy_from_slice(&s.as_bytes()[..n]);
}

fn get_text(src: &[u8]) -> String {
    let end = src.iter().position(|b| *b == 0).unwrap_or(src.len());
    String::from_utf8_lossy(&src[..end]).into_owned()
}

/// The day number (days since 1970-01-01) of epoch millisecond T.
pub fn day_of(t_ms: u64) -> u64 {
    t_ms / DAY_MS
}

/// `YYYY-MM-DD` for day number DAY (proleptic Gregorian, civil-from-days).
pub fn day_name(day: u64) -> String {
    let z = day as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}")
}

/// The day number of a file named `YYYY-MM-DD.bin`.
pub fn day_from_name(name: &str) -> Option<u64> {
    let stem = name.strip_suffix(".bin")?;
    let mut p = stem.split('-');
    let (y, m, d): (i64, i64, i64) = (
        p.next()?.parse().ok()?,
        p.next()?.parse().ok()?,
        p.next()?.parse().ok()?,
    );
    if p.next().is_some() || !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    let y = y - i64::from(m <= 2);
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    u64::try_from(era * 146_097 + doe - 719_468).ok()
}

/// The runner's telemetry folder.
pub struct Store {
    dir: PathBuf,
}

impl Store {
    pub fn at(dir: &Path) -> Store {
        Store {
            dir: dir.to_path_buf(),
        }
    }

    /// RECS appended to the day file of each record's time (made if need be).
    pub fn append(&self, recs: &[Record]) -> io::Result<()> {
        use std::io::Write as _;
        let mut by_day: BTreeMap<u64, Vec<u8>> = BTreeMap::new();
        for rec in recs {
            let t = match rec {
                Record::Bucket { b, .. } => b.t,
                Record::Marker(m) => m.at_ms,
            };
            if let Some(bytes) = rec.encode() {
                by_day
                    .entry(day_of(t))
                    .or_default()
                    .extend_from_slice(&bytes);
            }
        }
        if by_day.is_empty() {
            return Ok(());
        }
        std::fs::create_dir_all(&self.dir)?;
        for (day, bytes) in by_day {
            let mut f = crate::fsio::append(self.dir.join(format!("{}.bin", day_name(day))), true)?;
            f.write_all(&bytes)?;
        }
        Ok(())
    }

    /// Every record from FROM (inclusive) to TO (exclusive) epoch ms, in file order.
    pub fn read(&self, from: u64, to: u64) -> Vec<Record> {
        let mut out = Vec::new();
        let last = day_of(to.saturating_sub(1).max(from));
        // the files that are there, not every day of the span (a span may be as long as u64)
        let mut days: Vec<u64> = std::fs::read_dir(&self.dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| e.file_name().to_str().and_then(day_from_name))
            .filter(|d| (day_of(from)..=last).contains(d))
            .collect();
        days.sort_unstable();
        for day in days {
            let Ok(bytes) = crate::fsio::read(self.dir.join(format!("{}.bin", day_name(day))))
            else {
                continue;
            };
            for raw in bytes.as_chunks::<RECORD>().0 {
                let Some(rec) = Record::decode(raw) else {
                    continue;
                };
                let t = match &rec {
                    Record::Bucket { b, .. } => b.t,
                    Record::Marker(m) => m.at_ms,
                };
                if t >= from && t < to {
                    out.push(rec);
                }
            }
        }
        out
    }

    /// Removes the day files older than KEEP_DAYS before NOW_MS; how many went.
    pub fn prune(&self, now_ms: u64, keep_days: u64) -> usize {
        let Ok(rd) = std::fs::read_dir(&self.dir) else {
            return 0;
        };
        let oldest = day_of(now_ms).saturating_sub(keep_days);
        let mut gone = 0;
        for e in rd.flatten() {
            let name = e.file_name();
            let Some(day) = name.to_str().and_then(day_from_name) else {
                continue;
            };
            if day < oldest && std::fs::remove_file(e.path()).is_ok() {
                gone += 1;
            }
        }
        gone
    }

    /// The history RANGE asks for from the stored files; see [`ranged`].
    pub fn range(&self, r: &Range) -> Ranged {
        ranged(self.read(r.from, r.to), r)
    }
}

/// The history RANGE asks for out of RECS: each (id, metric)'s buckets merged into STEP_MS windows (or kept as stored
/// when 0), with the min of the mins, the max of the maxes, the count-weighted mean and the latest last; and the
/// markers of the ids asked.
pub fn ranged(recs: Vec<Record>, r: &Range) -> Ranged {
    let wanted = |id: &str| r.ids.is_empty() || r.ids.iter().any(|i| i == id);
    // (id, metric) -> window -> (count, min, max, sum, last at, last)
    type Win = (u64, f64, f64, f64, u64, f64);
    let mut groups: BTreeMap<(String, &'static str), BTreeMap<u64, Win>> = BTreeMap::new();
    let mut markers = Vec::new();
    for rec in recs {
        match rec {
            Record::Bucket {
                level,
                id,
                metric,
                b,
            } if level == r.level && wanted(&id) => {
                let w = if r.step_ms == 0 {
                    b.t
                } else {
                    b.t - b.t % r.step_ms
                };
                let n = u64::from(b.count.max(1));
                let slot = groups.entry((id, metric)).or_default().entry(w).or_insert((
                    0,
                    f64::INFINITY,
                    f64::NEG_INFINITY,
                    0.0,
                    0,
                    0.0,
                ));
                slot.0 += n;
                slot.1 = slot.1.min(b.min);
                slot.2 = slot.2.max(b.max);
                slot.3 += b.mean * n as f64;
                if b.t >= slot.4 {
                    slot.4 = b.t;
                    slot.5 = b.last;
                }
            }
            Record::Marker(m) if m.at_ms >= r.from && m.at_ms < r.to && wanted(&m.id) => {
                markers.push(m)
            }
            _ => {}
        }
    }
    markers.sort_by_key(|m| m.at_ms);
    let series = groups
        .into_iter()
        .map(|((id, metric), wins)| Series {
            level: r.level,
            id,
            metric: metric.to_string(),
            points: wins
                .into_iter()
                .map(|(t, (n, min, max, sum, _, last))| Point {
                    t,
                    min,
                    max,
                    mean: sum / n as f64,
                    last,
                })
                .collect(),
        })
        .collect();
    Ranged { series, markers }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bucket(t: u64, v: f64, max: f64) -> Record {
        Record::Bucket {
            level: Level::Job,
            id: "a3f".into(),
            metric: "cpu",
            b: Bucket {
                t,
                width_ms: 1000,
                count: 4,
                min: v,
                max,
                mean: v,
                last: v,
            },
        }
    }

    /// [D] pure: a bucket and a marker round-trip through their 96 bytes; an id too long is cut at the width, a marker's
    /// text too, and a metric the format does not have is refused.
    #[test]
    fn records_round_trip_in_96_bytes() {
        let b = bucket(1_700_000_000_000, 0.5, 3.25);
        assert_eq!(Record::decode(&b.encode().unwrap()), Some(b));
        let m = Record::Marker(Marker {
            at_ms: 42,
            id: "a3f".into(),
            kind: "waited".into(),
            detail: "needs 4096 MiB; 1000 MiB is free".into(),
        });
        let back = Record::decode(&m.encode().unwrap()).unwrap();
        let Record::Marker(back) = back else {
            panic!("a marker")
        };
        assert_eq!((back.kind.as_str(), back.at_ms), ("waited", 42));
        assert_eq!(
            back.detail.len(),
            TEXT_BYTES - "waited:".len(),
            "cut at the width"
        );
        let long = Record::Bucket {
            level: Level::Slot,
            id: "x".repeat(60),
            metric: "cpu",
            b: Bucket {
                t: 1,
                width_ms: 1,
                count: 1,
                min: 0.0,
                max: 0.0,
                mean: 0.0,
                last: 0.0,
            },
        };
        let Some(Record::Bucket { id, .. }) = Record::decode(&long.encode().unwrap()) else {
            panic!("a bucket")
        };
        assert_eq!(id.len(), ID_BYTES);
        assert!(
            Record::Bucket {
                level: Level::Job,
                id: "a".into(),
                metric: "nope",
                b: Bucket {
                    t: 0,
                    width_ms: 0,
                    count: 0,
                    min: 0.0,
                    max: 0.0,
                    mean: 0.0,
                    last: 0.0
                }
            }
            .encode()
            .is_none()
        );
    }

    /// [D] pure: the day files' names are the civil dates of the epoch day, both ways, across a leap day.
    #[test]
    fn day_names_are_civil_dates() {
        assert_eq!(day_name(0), "1970-01-01");
        assert_eq!(day_name(19_782), "2024-02-29");
        assert_eq!(day_name(day_of(1_700_000_000_000)), "2023-11-14");
        for d in [0, 59, 60, 365, 19_782, 20_000, 24_000] {
            assert_eq!(
                day_from_name(&format!("{}.bin", day_name(d))),
                Some(d),
                "{d}"
            );
        }
        assert_eq!(day_from_name("notes.txt"), None);
        assert_eq!(day_from_name("2024-13-01.bin"), None);
    }

    /// [D] pure (a folder): records land in the day file of their time, and a read finds the window asked for.
    #[test]
    fn append_files_by_day_and_read_by_window() {
        let t = tempfile::tempdir().unwrap();
        let s = Store::at(&t.path().join("telemetry"));
        let day2 = 2 * DAY_MS;
        s.append(&[
            bucket(100, 1.0, 1.0),
            bucket(day2 + 5, 2.0, 2.0),
            bucket(day2 + 9, 3.0, 3.0),
        ])
        .unwrap();
        let mut names: Vec<String> = std::fs::read_dir(t.path().join("telemetry"))
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        assert_eq!(names, ["1970-01-01.bin", "1970-01-03.bin"]);
        assert_eq!(s.read(0, u64::MAX).len(), 3);
        assert_eq!(s.read(day2, day2 + 9).len(), 1, "to is exclusive");
        assert_eq!(s.read(day2 + 6, u64::MAX).len(), 1);
    }

    /// [D] pure (a folder): the stored series never loses a peak; a range as stored hands back each bucket's own
    /// min, max, mean and last.
    #[test]
    fn a_stored_bucket_keeps_the_spike_max() {
        let t = tempfile::tempdir().unwrap();
        let s = Store::at(t.path());
        // one second of a job's cpu: mostly 0.2 cores, one 20 ms spike to 7.5
        s.append(&[Record::Bucket {
            level: Level::Job,
            id: "a3f".into(),
            metric: "cpu",
            b: Bucket {
                t: 1000,
                width_ms: 1000,
                count: 200,
                min: 0.1,
                max: 7.5,
                mean: 0.3,
                last: 0.2,
            },
        }])
        .unwrap();
        let r = s.range(&Range {
            level: Level::Job,
            ids: vec![],
            from: 0,
            to: 10_000,
            step_ms: 0,
        });
        assert_eq!(r.series.len(), 1);
        assert_eq!(
            r.series[0].points,
            [Point {
                t: 1000,
                min: 0.1,
                max: 7.5,
                mean: 0.3,
                last: 0.2
            }]
        );
    }

    /// [D] pure (a folder): downsampling merges buckets into wider windows with the min of the mins, the max of the
    /// maxes, the mean weighted by sample count and the latest last; other levels and ids stay out; markers in the
    /// window come with it.
    #[test]
    fn range_downsampling_keeps_min_and_max() {
        let t = tempfile::tempdir().unwrap();
        let s = Store::at(t.path());
        let mk = |t: u64, count: u32, min: f64, max: f64, mean: f64, last: f64| Record::Bucket {
            level: Level::Job,
            id: "a3f".into(),
            metric: "cpu",
            b: Bucket {
                t,
                width_ms: 1000,
                count,
                min,
                max,
                mean,
                last,
            },
        };
        let other = Record::Bucket {
            level: Level::Slot,
            id: "s1-0".into(),
            metric: "cpu",
            b: Bucket {
                t: 1000,
                width_ms: 1000,
                count: 1,
                min: 9.0,
                max: 9.0,
                mean: 9.0,
                last: 9.0,
            },
        };
        s.append(&[
            mk(10_000, 1, 1.0, 1.0, 1.0, 1.0),
            mk(11_000, 3, 0.5, 4.0, 2.0, 3.0),
            mk(12_000, 4, 0.2, 0.9, 0.5, 0.4),
            mk(20_000, 1, 8.0, 8.0, 8.0, 8.0),
            other,
            Record::Marker(Marker {
                at_ms: 11_500,
                id: "a3f".into(),
                kind: "paused".into(),
                detail: String::new(),
            }),
        ])
        .unwrap();
        let r = s.range(&Range {
            level: Level::Job,
            ids: vec!["a3f".into()],
            from: 10_000,
            to: 30_000,
            step_ms: 5000,
        });
        assert_eq!(r.series.len(), 1, "one id, one metric");
        let pts = &r.series[0].points;
        assert_eq!(pts.len(), 2);
        // 10 s..15 s: counts 1, 3, 4 → mean (1×1 + 3×2 + 4×0.5) / 8
        assert_eq!(pts[0].t, 10_000);
        assert_eq!((pts[0].min, pts[0].max), (0.2, 4.0));
        assert!((pts[0].mean - 9.0 / 8.0).abs() < 1e-9, "{}", pts[0].mean);
        assert_eq!(pts[0].last, 0.4, "the latest window's last");
        assert_eq!((pts[1].t, pts[1].max), (20_000, 8.0));
        assert_eq!(r.markers.len(), 1);
        assert_eq!(r.markers[0].kind, "paused");
    }

    /// [D] pure (a folder): day files older than `keep_days` are removed, the rest and other files stay.
    #[test]
    fn telemetry_files_are_pruned_at_keep_days() {
        let t = tempfile::tempdir().unwrap();
        let s = Store::at(t.path());
        let now = 30 * DAY_MS + 5;
        for d in [0u64, 10, 15, 16, 30] {
            s.append(&[bucket(d * DAY_MS + 1, 1.0, 1.0)]).unwrap();
        }
        crate::fsio::write(t.path().join("README"), b"kept").unwrap();
        assert_eq!(
            s.prune(now, 14),
            3,
            "days 0, 10 and 15 are 30, 20 and 15 days old"
        );
        let mut left: Vec<String> = std::fs::read_dir(t.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        left.sort();
        let mut want = vec![
            day_name(16) + ".bin",
            day_name(30) + ".bin",
            "README".to_string(),
        ];
        want.sort();
        assert_eq!(left, want);
    }
}
