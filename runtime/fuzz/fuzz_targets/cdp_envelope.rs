//! Bytes as one browser connection's traffic through heimdall: NUL-split (under a limit the first byte picks) into
//! messages, each one's first byte choosing the agent, the browser or the agent's close. Every message's envelope
//! parses or is refused without a panic; whatever the router sends the browser is a CDP command with an id and no
//! NUL, and an agent command that reaches the browser has an id below the hub's and a method off the refusal list.
//! The same bytes through the frame decoder, whole and in two pieces, give the same frames.
#![no_main]

use heimdall::codec::{FrameDecoder, Nul};
use heimdall::{HUB_ID_BASE, Router, Step, is_refused, parse};
use libfuzzer_sys::fuzz_target;

fn check_to_browser(msg: &[u8], from_agent: bool) {
    assert!(!msg.contains(&0));
    let env = parse(msg, usize::MAX).expect("the router sends the browser only CDP commands");
    let id = env.id.expect("a command has an id");
    let method = env.method.expect("a command has a method");
    assert!(!env.is_reply);
    if from_agent && id < HUB_ID_BASE {
        assert!(!is_refused(method), "{method} reached the browser");
    }
    if id >= HUB_ID_BASE {
        assert!(id <= i32::MAX as u64);
    }
}

fn check(step: Step, from_agent: bool) {
    match step {
        Step::ToBrowser(b) => check_to_browser(&b, from_agent),
        Step::Both { browser, agent } => {
            check_to_browser(&browser, false);
            assert!(!agent.contains(&0));
        }
        Step::ToAgent(a) | Step::ToAgentAndEvent { agent: a, .. } => assert!(!a.contains(&0)),
        Step::Drop | Step::Event(_) => {}
    }
}

fuzz_target!(|data: &[u8]| {
    let Some((&limit, rest)) = data.split_first() else {
        return;
    };
    let max = 16 + usize::from(limit) * 64;
    let (mut router, first) = Router::new();
    for m in &first {
        check_to_browser(m, false);
    }
    let mut nul = Nul::new(max);
    for msg in nul.push(rest).into_iter().flatten() {
        let _ = parse(&msg, max);
        let Some((&who, body)) = msg.split_first() else {
            continue;
        };
        match who % 3 {
            0 => check(router.from_agent(body), true),
            1 => check(router.from_browser(body), false),
            _ => {
                for m in router.agent_closed() {
                    check_to_browser(&m, false);
                }
            }
        }
    }

    let whole = FrameDecoder::new(max).push(rest);
    let cut = usize::from(limit).min(rest.len());
    let mut d = FrameDecoder::new(max);
    let pieces = d.push(&rest[..cut]).and_then(|mut a| {
        a.extend(d.push(&rest[cut..])?);
        Ok(a)
    });
    if let (Ok(w), Ok(p)) = (&whole, &pieces) {
        assert_eq!(w, p);
    }
    assert_eq!(whole.is_ok(), pieces.is_ok());
});
