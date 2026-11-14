//! Arbitrary sidecar output into the owner's end of the relay channel, its input a sink: no panic, and the channel
//! ends at the output's end (a partial frame included), by a violation, or with the ids used up. Never a stall.
#![no_main]

use drgnx_px::owner::{BEAT, End, STREAMS_ROOM, run};
use drgnx_px::shell::{Log, STALL};
use libfuzzer_sys::fuzz_target;
use tokio::io::AsyncWriteExt;
use tokio::sync::mpsc;

fuzz_target!(|data: &[u8]| {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
        .expect("a runtime");
    rt.block_on(async {
        let (mut w, out) = tokio::io::duplex(data.len().max(1));
        w.write_all(data).await.expect("room for the whole input");
        drop(w);
        // the proxy's side and the events, held and never read
        let (streams, _relayed) = mpsc::channel(STREAMS_ROOM);
        let (events, _heard) = mpsc::channel(16);
        let end = run(out, tokio::io::sink(), streams, events, BEAT, STALL, Log::default()).await;
        assert!(
            matches!(end, End::Eof | End::Violation(_) | End::IdsUsedUp),
            "{end:?}"
        );
    });
});
