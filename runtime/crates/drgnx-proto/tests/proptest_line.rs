//! Random byte streams, in random reads, through the client codec and the strict parse: nothing panics, and the
//! codec never holds more than one line's limit plus the read that went past it.

use drgnx_proto::line::{MAX_CLIENT_LINE, codec, parse_strict};
use proptest::prelude::*;
use tokio_util::codec::Decoder;

/// A piece of a stream: bytes of any kind, a newline, JSON-ish text, or a run near the line limit.
fn piece() -> impl Strategy<Value = Vec<u8>> {
    prop_oneof![
        4 => proptest::collection::vec(any::<u8>(), 0..64),
        2 => Just(b"\n".to_vec()),
        3 => "[{}\\[\\]\":,0-9a-z \\\\-]{0,48}".prop_map(String::into_bytes),
        2 => Just(br#"{"id":1,"method":"ping","params":{"a":[1,{"b":null}]}}"#.to_vec()),
        1 => (MAX_CLIENT_LINE - 2..MAX_CLIENT_LINE + 3, any::<u8>())
            .prop_map(|(n, b)| vec![if b == b'\n' { b'x' } else { b }; n]),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn any_bytes_never_panic_and_never_exceed_the_limit(
        pieces in proptest::collection::vec(piece(), 0..24),
        reads in proptest::collection::vec(1usize..(256 << 10), 1..8),
    ) {
        let stream: Vec<u8> = pieces.concat();
        let mut c = codec();
        let mut buf = Default::default();
        let _ = c.decode(&mut buf);
        let (mut at, mut r) = (0, 0);
        'reading: while at < stream.len() {
            let n = reads[r % reads.len()].min(stream.len() - at);
            r += 1;
            buf.extend_from_slice(&stream[at..at + n]);
            at += n;
            loop {
                match c.decode(&mut buf) {
                    Ok(Some(line)) => {
                        prop_assert!(line.len() <= MAX_CLIENT_LINE);
                        let _ = parse_strict(&line);
                    }
                    Ok(None) => break,
                    // the connection is closed: nothing after it is read
                    Err(_) => {
                        prop_assert!(buf.len() <= MAX_CLIENT_LINE + n);
                        break 'reading;
                    }
                }
            }
            prop_assert!(buf.len() <= MAX_CLIENT_LINE, "{} bytes held", buf.len());
        }
    }
}
