//! The scanner gives the same usage however a stream is cut into chunks (Task 18).

use bifrost::usage::{Scanner, Usage};
use proptest::prelude::*;

fn fixture(name: &str) -> Vec<u8> {
    let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../test/fixtures/sse").join(name);
    std::fs::read(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
}

fn scan_whole(b: &[u8]) -> Usage {
    let mut s = Scanner::new();
    s.feed(b);
    s.usage()
}

fn scan_cut(b: &[u8], cuts: &[usize]) -> Usage {
    let mut points: Vec<usize> = cuts.iter().map(|c| c % (b.len() + 1)).collect();
    points.sort_unstable();
    let mut s = Scanner::new();
    let mut at = 0;
    for p in points {
        s.feed(&b[at..p]);
        at = p;
    }
    s.feed(&b[at..]);
    s.usage()
}

#[test]
fn the_fixtures_give_their_known_usage() {
    let a = scan_whole(&fixture("anthropic.txt"));
    assert_eq!((a.input, a.output, a.cache_read, a.cache_write), (25 + 10 + 10, 15, 100, 8));
    let o = scan_whole(&fixture("openrouter.txt"));
    assert_eq!((o.input, o.output, o.cost), (10, 5, Some(0.0042)));
    let i = scan_whole(&fixture("openai.txt"));
    assert_eq!((i.input, i.output), (9, 2));
}

proptest! {
    #[test]
    fn any_chunking_gives_the_same_usage(
        which in 0usize..3,
        cuts in proptest::collection::vec(any::<usize>(), 0..24),
    ) {
        let b = fixture(["anthropic.txt", "openrouter.txt", "openai.txt"][which]);
        prop_assert_eq!(scan_cut(&b, &cuts), scan_whole(&b));
    }
}
