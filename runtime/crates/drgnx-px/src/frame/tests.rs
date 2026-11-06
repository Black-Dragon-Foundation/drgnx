//! The codec's rules, each on single frames (pure, [D]).

use super::*;

fn bytes_of(frames: &[Frame]) -> Vec<u8> {
    let mut out = Vec::new();
    for f in frames {
        encode(f, &mut out);
    }
    out
}

/// A raw frame: any stream id, kind byte and payload, with the payload's true length.
fn raw(stream: u32, kind: u8, payload: &[u8]) -> Vec<u8> {
    raw_len(stream, kind, payload.len() as u32, payload)
}

fn raw_len(stream: u32, kind: u8, len: u32, payload: &[u8]) -> Vec<u8> {
    let mut out = stream.to_be_bytes().to_vec();
    out.push(kind);
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(payload);
    out
}

fn decode(bytes: &[u8]) -> Result<Vec<Frame>, Violation> {
    Decoder::new().push(bytes)
}

fn one_of_each() -> Vec<Frame> {
    vec![
        Frame::ready("127.0.0.1:3128".parse().unwrap()),
        Frame::empty(1, Kind::Open),
        Frame::data(1, b"hello".to_vec()),
        Frame::credit(1, 4096),
        Frame::empty(1, Kind::Fin),
        Frame::empty(3, Kind::Rst),
        Frame::empty(0, Kind::Beat),
        Frame::event("10.0.0.4".parse().unwrap()),
    ]
}

/// [D] Every kind, encoded and pushed in two parts cut at every byte, decodes to the same frames, and nothing waits
/// after the last.
#[test]
fn every_kind_round_trips_split_at_every_byte() {
    let frames = one_of_each();
    let bytes = bytes_of(&frames);
    for cut in 0..=bytes.len() {
        let mut d = Decoder::new();
        let mut got = d.push(&bytes[..cut]).unwrap();
        got.extend(d.push(&bytes[cut..]).unwrap());
        assert_eq!(got, frames, "cut at {cut}");
        assert_eq!(d.buffered(), 0, "cut at {cut}");
    }
    // one byte at a time, too
    let mut d = Decoder::new();
    let mut got = Vec::new();
    for b in &bytes {
        got.extend(d.push(std::slice::from_ref(b)).unwrap());
    }
    assert_eq!(got, frames);
}

/// [D] `DATA` carries 1 to 16384 bytes: the largest decodes, one more and none are violations, and the length is
/// judged from the header, before the payload arrives.
#[test]
fn data_over_16384_and_empty_data_are_violations() {
    let max = vec![7u8; MAX_DATA];
    assert_eq!(decode(&raw(1, 2, &max)).unwrap(), vec![Frame::data(1, max)]);
    assert_eq!(
        decode(&raw_len(1, 2, 16_385, &[])),
        Err(Violation::Length {
            kind: Kind::Data,
            len: 16_385
        })
    );
    assert_eq!(
        decode(&raw(1, 2, &[])),
        Err(Violation::Length {
            kind: Kind::Data,
            len: 0
        })
    );
}

/// [D] Control JSON over 4096 bytes is a violation from the header alone.
#[test]
fn control_json_over_4096_is_a_violation() {
    for (kind, k) in [(0u8, Kind::Ready), (7, Kind::Event)] {
        assert_eq!(
            decode(&raw_len(0, kind, 4_097, &[])),
            Err(Violation::Length {
                kind: k,
                len: 4_097
            })
        );
    }
}

/// [D] `READY` names version 1 and an address; anything else is a bad payload.
#[test]
fn ready_payload_must_be_version_1() {
    let good = br#"{"version":1,"listen":"127.0.0.1:3128"}"#;
    assert_eq!(
        decode(&raw(0, 0, good)).unwrap(),
        vec![Frame::ready("127.0.0.1:3128".parse().unwrap())]
    );
    for bad in [
        &br#"{"version":2}"#[..],
        br#"{"version":2,"listen":"127.0.0.1:3128"}"#,
        br#"{"version":1}"#,
        br#"{"version":1,"listen":"localhost:3128"}"#,
        br#"{"version":1,"listen":"127.0.0.1:3128","more":1}"#,
        b"ready",
        b"",
    ] {
        assert_eq!(
            decode(&raw(0, 0, bad)),
            Err(Violation::BadPayload(Kind::Ready)),
            "{}",
            String::from_utf8_lossy(bad)
        );
    }
}

/// [D] Kind bytes stop at 7.
#[test]
fn kind_8_is_unknown() {
    assert_eq!(decode(&raw(1, 8, &[])), Err(Violation::UnknownKind(8)));
    assert_eq!(decode(&raw(0, 255, &[])), Err(Violation::UnknownKind(255)));
}

/// [D] `CREDIT` is exactly a u32.
#[test]
fn credit_payload_is_exactly_four_bytes() {
    assert_eq!(
        decode(&raw(1, 3, &[0, 0, 1, 0])).unwrap(),
        vec![Frame::credit(1, 256)]
    );
    assert_eq!(Frame::credit(1, 256).credit_value(), Some(256));
    for len in [0usize, 3, 5, 8] {
        assert_eq!(
            decode(&raw(1, 3, &vec![1u8; len])),
            Err(Violation::Length {
                kind: Kind::Credit,
                len: len as u32
            }),
            "length {len}"
        );
    }
}

/// [D] A zero increment is a bad payload (RFC 9113 §6.9).
#[test]
fn credit_0_is_a_violation() {
    assert_eq!(
        decode(&raw(1, 3, &[0, 0, 0, 0])),
        Err(Violation::BadPayload(Kind::Credit))
    );
}

/// [D] `OPEN`, `FIN`, `RST` and `BEAT` carry nothing.
#[test]
fn open_fin_rst_beat_have_no_payload() {
    for (stream, b, kind) in [
        (1u32, 1u8, Kind::Open),
        (1, 4, Kind::Fin),
        (1, 5, Kind::Rst),
        (0, 6, Kind::Beat),
    ] {
        assert_eq!(
            decode(&raw(stream, b, &[])).unwrap(),
            vec![Frame::empty(stream, kind)]
        );
        assert_eq!(
            decode(&raw(stream, b, &[0])),
            Err(Violation::Length { kind, len: 1 })
        );
    }
}

/// [D] The high bit of a stream id is never set.
#[test]
fn a_stream_id_with_the_high_bit_is_a_violation() {
    for id in [0x8000_0000u32, 0x8000_0001, u32::MAX] {
        assert_eq!(decode(&raw(id, 1, &[])), Err(Violation::HighBit(id)));
    }
    // the last id is fine
    assert_eq!(
        decode(&raw(0x7FFF_FFFF, 1, &[])).unwrap(),
        vec![Frame::empty(0x7FFF_FFFF, Kind::Open)]
    );
}

/// [D] Only the sidecar opens streams, with odd ids: an even id other than 0 is a violation on every kind (0 keeps
/// the stream-0 rules).
#[test]
fn an_even_stream_id_other_than_0_is_a_violation() {
    for id in [2u32, 0x7FFF_FFFE] {
        for kind in 0u8..=7 {
            let payload: &[u8] = match kind {
                2 => b"x",
                3 => &[0, 0, 0, 1],
                _ => &[],
            };
            assert_eq!(
                decode(&raw(id, kind, payload)),
                Err(Violation::EvenId(id)),
                "id {id}, kind {kind}"
            );
        }
    }
}

/// [D] Stream 0 carries `READY`, `BEAT` and `EVENT` only, and those three nowhere else.
#[test]
fn stream_0_carries_only_ready_beat_event() {
    for (b, kind, payload) in [
        (1u8, Kind::Open, &[][..]),
        (2, Kind::Data, b"x"),
        (3, Kind::Credit, &[0, 0, 0, 1]),
        (4, Kind::Fin, &[]),
        (5, Kind::Rst, &[]),
    ] {
        assert_eq!(
            decode(&raw(0, b, payload)),
            Err(Violation::WrongStream(kind)),
            "{kind:?} on 0"
        );
    }
    for (b, kind, payload) in [
        (
            0u8,
            Kind::Ready,
            &br#"{"version":1,"listen":"127.0.0.1:3128"}"#[..],
        ),
        (6, Kind::Beat, &[]),
        (7, Kind::Event, br#"{"foreign_source":"10.0.0.4"}"#),
    ] {
        assert_eq!(
            decode(&raw(1, b, payload)),
            Err(Violation::WrongStream(kind)),
            "{kind:?} on 1"
        );
        assert_eq!(decode(&raw(0, b, payload)).unwrap().len(), 1);
    }
}

/// [D] A foreign source is an address and nothing else.
#[test]
fn an_event_source_must_parse_as_an_address() {
    for good in ["10.0.0.4", "::1"] {
        let payload = format!(r#"{{"foreign_source":"{good}"}}"#);
        assert_eq!(
            decode(&raw(0, 7, payload.as_bytes())).unwrap(),
            vec![Frame::event(good.parse().unwrap())]
        );
        assert_eq!(
            ForeignSource::parse(payload.as_bytes()),
            Some(ForeignSource(good.parse().unwrap()))
        );
    }
    for bad in [
        &br#"{"foreign_source":"x\n"}"#[..],
        br#"{"foreign_source":"example.com"}"#,
        br#"{"foreign_source":""}"#,
        br#"{"foreign_source":"10.0.0.4:80"}"#,
        br#"{"foreign_source":"10.0.0.4","more":1}"#,
        br#"{}"#,
        b"10.0.0.4",
    ] {
        assert_eq!(
            decode(&raw(0, 7, bad)),
            Err(Violation::BadPayload(Kind::Event)),
            "{}",
            String::from_utf8_lossy(bad)
        );
    }
}
