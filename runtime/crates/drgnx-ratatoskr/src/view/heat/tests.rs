use super::*;
use runstav::methods::history::BlameCommit;

const FILE: &str = "/r/src/a.rs";

fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(format!(
        "{}/tests/fixtures/heat/{name}",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap()
}

fn s(first: u32, last: u32, value: u16, fact: &str) -> Span {
    Span {
        first,
        last,
        value,
        fact: fact.into(),
    }
}

#[test]
fn a_reports_name_is_the_file_or_a_suffix_of_it_at_a_slash() {
    assert!(names_file("src/a.rs", FILE));
    assert!(names_file("./src/a.rs", FILE));
    assert!(names_file(FILE, FILE));
    assert!(!names_file("a.rs", "/r/src/ba.rs"));
    assert!(!names_file("/x/src/a.rs", FILE));
    assert!(!names_file("", FILE));
}

#[test]
fn lcov_gives_each_line_of_the_file_covered_or_not_and_adds_a_line_listed_twice() {
    assert_eq!(
        coverage(&fixture("lcov.info"), FILE),
        vec![
            s(1, 2, 1000, "covered · 3 hits"),
            s(3, 3, 1000, "covered · 2 hits"),
            s(5, 5, 1000, "covered · 1 hit"),
        ]
    );
    // another file's record is not this one's
    assert_eq!(
        coverage(&fixture("lcov.info"), "/r/src/other.rs"),
        vec![s(1, 1, 1000, "covered · 9 hits")]
    );
}

#[test]
fn cobertura_gives_the_lines_of_the_class_that_names_the_file() {
    assert_eq!(
        coverage(&fixture("cobertura.xml"), FILE),
        vec![
            s(1, 1, 1000, "covered · 2 hits"),
            s(2, 2, 0, "not covered"),
            s(4, 4, 1000, "covered · 1 hit"),
        ]
    );
    assert_eq!(coverage(b"<not xml", FILE), vec![]);
}

#[test]
fn llvm_cov_counts_a_line_by_the_regions_that_start_on_it_else_the_one_it_lies_in() {
    // line 2 lies in line 1's region, line 5 starts in line 4's; line 7 is a gap region and 6 lies in none
    assert_eq!(
        coverage(&fixture("llvm-cov.json"), FILE),
        vec![
            s(1, 2, 1000, "covered · 4 hits"),
            s(3, 3, 0, "not covered"),
            s(4, 5, 1000, "covered · 4 hits"),
        ]
    );
}

#[test]
fn perf_script_gives_each_sample_to_its_first_frame_with_a_source_line() {
    assert_eq!(
        profile(&fixture("perf-script.txt"), FILE),
        vec![
            s(3, 3, 500, "33.3 % of this file's samples"),
            s(7, 7, 1000, "66.7 % of this file's samples"),
        ]
    );
}

#[test]
fn speedscope_gives_sampled_leaves_their_weight_and_evented_frames_their_self_time() {
    // line 2: 3 sampled + 2 + 4 self; line 7: 3 + 1 sampled + 4 self; frames with no file count nowhere
    assert_eq!(
        profile(&fixture("speedscope.json"), FILE),
        vec![
            s(2, 2, 1000, "52.9 % of this file's samples"),
            s(7, 7, 889, "47.1 % of this file's samples"),
        ]
    );
}

/// A protobuf field: KEY's number, then a varint or bytes.
fn pb(out: &mut Vec<u8>, n: u64, v: Result<u64, &[u8]>) {
    fn varint(out: &mut Vec<u8>, mut v: u64) {
        while v >= 0x80 {
            out.push((v as u8) | 0x80);
            v >>= 7;
        }
        out.push(v as u8);
    }
    match v {
        Ok(x) => {
            varint(out, n << 3);
            varint(out, x);
        }
        Err(b) => {
            varint(out, (n << 3) | 2);
            varint(out, b.len() as u64);
            out.extend_from_slice(b);
        }
    }
}

fn msg(fields: &[(u64, Result<u64, &[u8]>)]) -> Vec<u8> {
    let mut out = Vec::new();
    for (n, v) in fields {
        pb(&mut out, *n, *v);
    }
    out
}

/// A pprof profile: a function in a.rs and one in other.rs; location 1 is line 7 inlined into line 2, location 2
/// line 2, location 3 other.rs's line 1.
fn pprof_bytes() -> Vec<u8> {
    let line = |f: u64, l: u64| msg(&[(1, Ok(f)), (2, Ok(l))]);
    let (l7, l2, o1) = (line(1, 7), line(1, 2), line(2, 1));
    let mut p = msg(&[(1, Err(&msg(&[(1, Ok(1)), (2, Ok(2))])))]);
    let samples = [
        msg(&[(1, Err(&[1, 2])), (2, Err(&[5]))]),
        msg(&[(1, Ok(2)), (2, Ok(10))]),
        msg(&[(1, Ok(3)), (2, Ok(7))]),
    ];
    let locations = [
        msg(&[(1, Ok(1)), (4, Err(&l7)), (4, Err(&l2))]),
        msg(&[(1, Ok(2)), (4, Err(&l2))]),
        msg(&[(1, Ok(3)), (4, Err(&o1))]),
    ];
    let functions = [
        msg(&[(1, Ok(1)), (2, Ok(3)), (4, Ok(1))]),
        msg(&[(1, Ok(2)), (2, Ok(3)), (4, Ok(2))]),
    ];
    for m in &samples {
        p.extend(msg(&[(2, Err(m))]));
    }
    for m in &locations {
        p.extend(msg(&[(4, Err(m))]));
    }
    for m in &functions {
        p.extend(msg(&[(5, Err(m))]));
    }
    for st in ["", FILE, "/r/src/other.rs", "main"] {
        p.extend(msg(&[(6, Err(st.as_bytes()))]));
    }
    p
}

#[test]
fn pprof_gives_each_samples_value_to_its_leafs_innermost_line_zipped_or_not() {
    let want = vec![
        s(2, 2, 1000, "66.7 % of this file's samples"),
        s(7, 7, 500, "33.3 % of this file's samples"),
    ];
    let raw = pprof_bytes();
    assert_eq!(profile(&raw, FILE), want);
    let mut z = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    std::io::Write::write_all(&mut z, &raw).unwrap();
    assert_eq!(profile(&z.finish().unwrap(), FILE), want);
    assert_eq!(
        profile(&raw, "/r/src/other.rs"),
        vec![s(1, 1, 1000, "100.0 % of this file's samples")]
    );
}

#[test]
fn blame_ramps_from_the_oldest_commit_to_the_newest_and_uncommitted_lines_are_hottest() {
    let c = |sha: &str, time: Option<i64>, summary: &str, author: &str| BlameCommit {
        sha: sha.into(),
        author: author.into(),
        time,
        summary: summary.into(),
    };
    let b = GitBlamed {
        head: None,
        commits: vec![
            c("1111111aaaa", Some(1000), "first", "ann"),
            c("9f3c21eabcd", Some(3000), "read tables lazily", "bob"),
            c(
                "0000000000000000000000000000000000000000",
                None,
                "Uncommitted changes",
                "",
            ),
        ],
        lines: vec![0, 0, 1, 2, 1],
        agents: vec![],
    };
    let new = "2 days ago · 9f3c21e read tables lazily · bob";
    assert_eq!(
        blame(&b, 3000 + 2 * 86_400),
        vec![
            s(1, 2, 0, "2 days ago · 1111111 first · ann"),
            s(3, 3, 1000, new),
            s(4, 4, 1000, "not committed"),
            s(5, 5, 1000, new),
        ]
    );
}

#[test]
fn agent_read_counts_the_reads_over_each_line_the_most_read_hottest() {
    let reads = [
        (Some(2), Some(4), Some("claude".to_string())),
        (Some(3), None, Some("codex".to_string())),
        (None, None, None),
    ];
    assert_eq!(
        agent_read(&reads, 5),
        vec![
            s(1, 1, 333, "read 1×"),
            s(2, 2, 667, "read 2× · claude"),
            s(3, 4, 1000, "read 3× · claude, codex"),
            s(5, 5, 667, "read 2× · codex"),
        ]
    );
    assert_eq!(agent_read(&[], 5), vec![]);
}
