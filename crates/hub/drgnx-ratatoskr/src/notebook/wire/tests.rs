use super::*;
use serde_json::json;

fn key() -> Key {
    Key::from_connection_file(&"ab".repeat(16)).unwrap()
}

fn hdr(t: &str) -> Header {
    Header {
        msg_id: "m1".into(),
        session: "s1".into(),
        username: "u".into(),
        date: "2026-11-14T00:00:00Z".into(),
        msg_type: t.into(),
        version: "5.3".into(),
    }
}

fn msg() -> Message {
    Message {
        idents: vec![b"id-1".to_vec()],
        header: hdr("execute_request"),
        parent: json!({}),
        metadata: json!({"a": 1}),
        content: json!({"code": "1+1", "silent": false}),
        buffers: vec![vec![1, 2, 3]],
    }
}

#[test]
fn a_message_round_trips_through_its_frames() {
    let frames = encode(&key(), &msg());
    assert_eq!(frames[0], b"id-1");
    assert_eq!(frames[1], DELIM);
    assert_eq!(frames.len(), 1 + 1 + 1 + 4 + 1);
    assert_eq!(decode(&key(), &frames).unwrap(), msg());
}

#[test]
fn a_message_signed_with_another_key_or_changed_is_refused() {
    let frames = encode(&key(), &msg());
    let other = Key::from_connection_file(&"cd".repeat(16)).unwrap();
    assert_eq!(decode(&other, &frames), Err(WireError::BadSignature));
    // one byte of the content changed
    let mut t = frames.clone();
    let last_json = 2 + 3;
    t[last_json][2] ^= 1;
    assert_eq!(decode(&key(), &t), Err(WireError::BadSignature));
    // a signature that is not hex, odd, upper case wrong, too short, empty: refused, never a panic
    for bad in [
        &b"zz"[..],
        b"abc",
        b"",
        b"0",
        &[0xff, 0xfe][..],
        &b"AB".repeat(32)[..],
    ] {
        let mut t = frames.clone();
        t[2] = bad.to_vec();
        assert_eq!(decode(&key(), &t), Err(WireError::BadSignature), "{bad:?}");
    }
}

#[test]
fn the_shape_of_the_frames_is_checked() {
    let frames = encode(&key(), &msg());
    assert_eq!(decode(&key(), &[]), Err(WireError::TooFewFrames));
    assert_eq!(decode(&key(), &frames[..4]), Err(WireError::TooFewFrames));
    let mut no_delim = frames.clone();
    no_delim[1] = b"<IDS|XXX>".to_vec();
    assert_eq!(decode(&key(), &no_delim), Err(WireError::NoDelimiter));
    // no identities is fine (a PUB socket's), many are not
    let mut none = frames.clone();
    none.remove(0);
    assert!(decode(&key(), &none).is_ok());
    let mut many = vec![b"x".to_vec(); MAX_IDENTS + 1];
    many.extend(frames[1..].iter().cloned());
    assert_eq!(decode(&key(), &many), Err(WireError::TooManyFrames));
    let mut buffers = frames.clone();
    buffers.extend(std::iter::repeat_n(vec![0u8], MAX_BUFFERS + 1));
    assert_eq!(
        decode(&key(), &buffers),
        Err(WireError::TooLarge("buffers"))
    );
}

#[test]
fn a_frame_over_its_cap_is_refused_before_it_is_parsed() {
    // the signature is wrong on purpose: the size check comes first, so the answer is TooLarge, not BadSignature
    let mut frames = encode(&key(), &msg());
    frames[3] = vec![b' '; MAX_SMALL + 1];
    assert_eq!(decode(&key(), &frames), Err(WireError::TooLarge("header")));
    let mut frames = encode(&key(), &msg());
    frames[6] = vec![b' '; MAX_CONTENT + 1];
    assert_eq!(decode(&key(), &frames), Err(WireError::TooLarge("content")));
    let mut frames = encode(&key(), &msg());
    frames.push(vec![0u8; MAX_BUFFER_BYTES]);
    frames.push(vec![0u8; 1]);
    assert_eq!(decode(&key(), &frames), Err(WireError::TooLarge("buffers")));
}

#[test]
fn json_that_is_deep_or_wrong_is_an_error_not_a_crash() {
    let k = key();
    // correctly signed messages whose parts are deep or the wrong JSON
    let deep = format!("{}{}", "[".repeat(10_000), "]".repeat(10_000));
    for (what, header, content) in [
        (
            "deep",
            br#"{"msg_id":"a","msg_type":"t"}"#.to_vec(),
            deep.into_bytes(),
        ),
        ("no msg_type", br#"{"msg_id":"a"}"#.to_vec(), b"{}".to_vec()),
        ("header not an object", b"[1]".to_vec(), b"{}".to_vec()),
        ("not JSON", b"{".to_vec(), b"{}".to_vec()),
        (
            "content not an object",
            br#"{"msg_id":"a","msg_type":"t"}"#.to_vec(),
            b"3".to_vec(),
        ),
    ] {
        let frames = signed(&k, &header, b"{}", b"{}", &content);
        let r = decode(&k, &frames);
        assert!(matches!(r, Err(WireError::Json(_))), "{what}: {r:?}");
    }
}

/// Frames for the four JSON parts as given (not through `encode`), correctly signed.
fn signed(k: &Key, header: &[u8], parent: &[u8], meta: &[u8], content: &[u8]) -> Vec<Vec<u8>> {
    use hmac::{Hmac, KeyInit, Mac};
    let mut mac = Hmac::<sha2::Sha256>::new_from_slice(&k.0).unwrap();
    for p in [header, parent, meta, content] {
        mac.update(p);
    }
    let sig: String = mac
        .finalize()
        .into_bytes()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    vec![
        DELIM.to_vec(),
        sig.into_bytes(),
        header.to_vec(),
        parent.to_vec(),
        meta.to_vec(),
        content.to_vec(),
    ]
}

#[test]
fn random_frames_never_panic_and_a_good_message_survives_noise_around_it() {
    let mut state = 0x9e37_79b9_7f4a_7c15_u64;
    let mut next = move || {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        state
    };
    let k = key();
    for _ in 0..3000 {
        let n = (next() % 9) as usize;
        let frames: Vec<Vec<u8>> = (0..n)
            .map(|_| (0..(next() % 40)).map(|_| next() as u8).collect())
            .collect();
        let _ = decode(&k, &frames);
        // delimiter in a random place
        let mut with = frames.clone();
        with.insert((next() as usize) % (with.len() + 1), DELIM.to_vec());
        let _ = decode(&k, &with);
    }
}

#[test]
fn a_key_prints_nothing_and_is_random_and_round_trips() {
    let a = Key::generate().unwrap();
    let b = Key::generate().unwrap();
    assert_ne!(a.to_connection_file(), b.to_connection_file());
    assert_eq!(a.to_connection_file().len(), 64);
    assert_eq!(format!("{a:?}"), "Key(..)");
    assert!(!format!("{a:?}").contains(&a.to_connection_file()));
    let again = Key::from_connection_file(&a.to_connection_file()).unwrap();
    assert_eq!(again.to_connection_file(), a.to_connection_file());
    assert!(Key::from_connection_file("not hex").is_none());
    assert!(
        Key::from_connection_file("").is_none(),
        "an empty key would switch signing off"
    );
}

#[test]
fn an_identity_over_255_bytes_and_a_header_field_over_a_few_kib_are_refused() {
    let frames = encode(&key(), &msg());
    let mut t = frames.clone();
    t[0] = vec![b'i'; 256];
    assert_eq!(decode(&key(), &t), Err(WireError::TooLarge("identity")));
    let mut ok = frames.clone();
    ok[0] = vec![b'i'; 255];
    assert!(decode(&key(), &ok).is_ok());
    let k = key();
    let long = format!(
        r#"{{"msg_id":"a","msg_type":"{}"}}"#,
        "t".repeat(MAX_FIELD + 1)
    );
    let f = signed(&k, long.as_bytes(), b"{}", b"{}", b"{}");
    assert_eq!(decode(&k, &f), Err(WireError::Json("header")));
    // a signature that is not exactly 64 hex characters is refused, however long
    let mut s = frames;
    s[2] = vec![b'a'; 1 << 20];
    assert_eq!(decode(&key(), &s), Err(WireError::BadSignature));
}

#[test]
fn a_signature_of_another_length_is_refused_before_it_is_decoded() {
    assert!(sig_bytes(&vec![b'a'; 1 << 20]).is_none());
    assert!(sig_bytes(&[b'a'; 63]).is_none());
    assert!(sig_bytes(&[b'a'; 65]).is_none());
    assert!(
        sig_bytes(&[b'z'; 64]).is_none(),
        "64 characters that are not hex"
    );
    assert_eq!(sig_bytes(&[b'a'; 64]).unwrap(), vec![0xaa; 32]);
}

#[test]
fn decode_checks_the_signature_through_sig_bytes_and_only_after_the_sizes() {
    let k = key();
    let frames = encode(&k, &msg());
    let before = SIG_CHECKS.with(std::cell::Cell::get);
    decode(&k, &frames).unwrap();
    assert_eq!(
        SIG_CHECKS.with(std::cell::Cell::get),
        before + 1,
        "one signature, checked by length"
    );
    // a frame over its cap is refused before the signature is looked at
    let mut big = frames.clone();
    big[3] = vec![b' '; MAX_SMALL + 1];
    let before = SIG_CHECKS.with(std::cell::Cell::get);
    assert!(decode(&k, &big).is_err());
    assert_eq!(SIG_CHECKS.with(std::cell::Cell::get), before);
}
