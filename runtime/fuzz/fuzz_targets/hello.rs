//! Hello params from arbitrary JSON, then the proof check against a fixed cap: as given, and with the right proof
//! for the client's nonce, on a main socket and on an agent socket.
#![no_main]

use drgnx_proto::methods::hub::HelloParams;
use drgnx_proto::proof::{self, Cap};
use drgnx_proto::types::Hex64;
use drgnx_ratatoskr::hello::{Session, Socket, hello};
use libfuzzer_sys::fuzz_target;
use std::sync::OnceLock;

const HUB_NONCE: &str = "00112233445566778899aabbccddeeff";

fn cap() -> &'static Cap {
    static CAP: OnceLock<Cap> = OnceLock::new();
    CAP.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("drgnx-fuzz-cap-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("cap");
        std::fs::write(&file, "ab".repeat(32)).unwrap();
        let cap = Cap::read(&file).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        cap
    })
}

fn session(socket: Socket) -> Session {
    let mut s = Session::new(1, socket);
    s.hub_nonce = HUB_NONCE.into();
    s
}

fuzz_target!(|data: &[u8]| {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(data) else {
        return;
    };
    let Ok((mut p, _ignored)) = drgnx_proto::decode::typed::<HelloParams>(&v) else {
        return;
    };
    let agent = || Socket::Agent {
        sid: "s1".into(),
        job: None,
    };
    for socket in [Socket::Main, agent()] {
        let _ = hello(&mut session(socket), cap(), &p, 0);
    }
    let right = proof::client_proof(cap(), HUB_NONCE, p.nonce.as_str());
    p.proof = Hex64::new(right).ok();
    for socket in [Socket::Main, agent()] {
        let mut s = session(socket);
        let _ = hello(&mut s, cap(), &p, 7);
        // a second hello on the same connection is refused, whatever it holds
        let _ = hello(&mut s, cap(), &p, 7);
    }
});
