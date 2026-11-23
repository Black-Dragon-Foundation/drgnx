//! Arbitrary bytes through the gateway's usage scanner, in chunks. The first two bytes pick the chunk sizes, the rest is
//! the body. The usage must be the same for the whole body at once, byte by byte, and cut into pieces of the sizes the
//! two bytes give (cycled); no panic.
#![no_main]

use bifrost::usage::{Scanner, Usage};
use libfuzzer_sys::fuzz_target;

fn scan(body: &[u8], sizes: &[usize]) -> Usage {
    let mut s = Scanner::new();
    let mut rest = body;
    for size in sizes.iter().cycle() {
        if rest.is_empty() {
            break;
        }
        let (head, tail) = rest.split_at((*size).min(rest.len()));
        s.feed(head);
        rest = tail;
    }
    s.usage()
}

fuzz_target!(|data: &[u8]| {
    let [a, b, body @ ..] = data else {
        return;
    };
    let (a, b) = (usize::from(*a), usize::from(*b));
    let whole = scan(body, &[body.len().max(1)]);
    assert_eq!(scan(body, &[1]), whole, "byte by byte");
    assert_eq!(
        scan(body, &[1 + a % 16, 1 + b % 64, 1 + (a ^ b) % 255]),
        whole,
        "cut by the input's sizes"
    );
});
