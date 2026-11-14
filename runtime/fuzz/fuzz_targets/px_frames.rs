//! Arbitrary bytes, cut at arbitrary places, through the relay's frame decoder: no panic, and the frames it returns
//! re-encode to exactly the bytes it consumed.
#![no_main]

use drgnx_px::frame::{Decoder, HEADER, MAX_DATA, encode};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    // The first byte picks the chunk size, so the cuts vary with the input.
    let Some((&cut, rest)) = data.split_first() else {
        return;
    };
    let chunk = usize::from(cut) % 64 + 1;
    let mut d = Decoder::new();
    let mut fed = 0usize;
    let mut encoded = Vec::new();
    for piece in rest.chunks(chunk) {
        match d.push(piece) {
            Ok(frames) => {
                fed += piece.len();
                for f in &frames {
                    encode(f, &mut encoded);
                }
                assert!(d.buffered() <= HEADER + MAX_DATA);
                let consumed = fed - d.buffered();
                assert_eq!(encoded, rest[..consumed], "the frames re-encode to the bytes consumed");
            }
            // a violation closes the channel; the decoder is done
            Err(_) => return,
        }
    }
});
