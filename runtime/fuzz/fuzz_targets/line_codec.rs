//! Arbitrary bytes, cut at arbitrary places, through the client line codec and then `parse_strict`.
#![no_main]

use bytes::BytesMut;
use libfuzzer_sys::fuzz_target;
use tokio_util::codec::Decoder;

fuzz_target!(|data: &[u8]| {
    // The first byte picks the chunk size, so the cuts vary with the input.
    let Some((&cut, rest)) = data.split_first() else {
        return;
    };
    let chunk = usize::from(cut) % 64 + 1;
    let mut codec = drgnx_proto::line::codec();
    let mut buf = BytesMut::new();
    for piece in rest.chunks(chunk) {
        buf.extend_from_slice(piece);
        loop {
            match codec.decode(&mut buf) {
                Ok(Some(line)) => {
                    let _ = drgnx_proto::line::parse_strict(&line);
                }
                Ok(None) => break,
                // an over-long or non-UTF-8 line closes the connection; the codec is done
                Err(_) => return,
            }
        }
    }
    if let Ok(Some(line)) = codec.decode_eof(&mut buf) {
        let _ = drgnx_proto::line::parse_strict(&line);
    }
});
