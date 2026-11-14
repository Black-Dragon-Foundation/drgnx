//! The hub–runner protocol (`docs/develop/sleipnir.md`, "The protocol"): the frames ([`Frame`]) and their wire
//! ([`FrameReader`], [`FrameWriter`]). Pure: serde, serde_json, and `secrecy` for a key's value.
//!
//! The control channel carries every job's frames, its logs and its keys; the bulk channels carry `blob` and
//! `bundle` frames in the same format. The version is checked at `hello`. Every job frame carries its
//! [`JobRef`] (job, attempt, nonce).

mod codec;
mod frame;

pub use codec::{CodecError, FrameReader, FrameWriter, MAX_CHUNK, MAX_LINE};
pub use frame::{
    AttemptInfo, AttemptState, Facts, Frame, JobRef, Key, KeyValue, ManifestEntry, Missing, Nonce,
    Sha256,
};

/// The protocol's version. A hub and a runner of different versions don't talk: the hub copies its own bundle to
/// the runner first, and the old binaries stay while their attempts run.
pub const PROTO_VERSION: u32 = 1;

#[cfg(test)]
mod tests {
    use super::*;
    use forseti::{
        Expect, Expected, Grant, JobSpec, JobTrust, Kind, Lane, Priority, Psi, Range, WaitReason,
        Weight,
    };
    use proptest::prelude::*;
    use secrecy::SecretString;
    use std::path::PathBuf;

    fn r() -> JobRef {
        JobRef {
            job: "a3f".into(),
            attempt: 2,
            nonce: Nonce([0xab; 16]),
        }
    }

    fn spec() -> JobSpec {
        JobSpec {
            os: Default::default(),
            name: "unit".into(),
            kind: Kind::Test,
            weight: Weight::Heavy,
            suite: Some("cargo".into()),
            tree: PathBuf::from("/src/p"),
            cwd: PathBuf::from("."),
            command: vec!["cargo".into(), "test".into()],
            select: None,
            needs: vec![],
            inputs_extra: vec![],
            inputs_outside: vec![],
            features: vec!["podman".into()],
            cores: Range { min: 1, max: 4 },
            mem_mib: Range {
                min: 512,
                max: 2048,
            },
            disk_gib: 1,
            timeout_s: 600,
            restartable: true,
            writes_tree: false,
            priority: Some(Priority::P3),
            for_user: None,
            gate: None,
            expect: Expect::default(),
            outputs: vec![],
            state: vec![],
            on: None,
            lane: Lane::Work,
            fresh: false,
            stop_on_red: false,
            project: "p".into(),
            trust: JobTrust::PrivateKeys,
            keys: vec!["TOKEN".into()],
            local_only: false,
            writes: vec![],
        }
    }

    const SECRET: &str = "s3cr3t-value-that-must-not-leak";

    fn key() -> Frame {
        Frame::Key(Key {
            r: r(),
            name: "TOKEN".into(),
            value: KeyValue::new(SecretString::from(SECRET)),
        })
    }

    /// One of every frame, with its fields filled.
    fn every_frame() -> Vec<Frame> {
        let grant = Grant {
            cores: 2,
            mem_cap_mib: 1024,
            reserve_mib: 512,
        };
        vec![
            Frame::Hello {
                version: PROTO_VERSION,
                hub_id: "hub-1".into(),
            },
            Frame::HelloOk {
                version: PROTO_VERSION,
                bundle: "0.1.0".into(),
                hub_id: "hub-1".into(),
                runner_id: "desk".into(),
                boot_id: "b00t".into(),
                linger: true,
                attempts: vec![AttemptInfo {
                    r: r(),
                    state: AttemptState::Running,
                    log_offset: 4096,
                }],
                missing: vec![Missing {
                    what: "linger".into(),
                    fix: "loginctl enable-linger".into(),
                }],
            },
            Frame::Probe,
            Frame::ProbeResult {
                facts: Some(Facts {
                    arch: "x86_64".into(),
                    cores: 16,
                    ..Facts::default()
                }),
                missing: vec![],
                limits: Some("no controllers".into()),
                features: vec!["podman".into()],
                mem_available_mib: 5376,
            },
            Frame::Ready {
                free_mib: -12,
                mem_available_mib: 5376,
                free_cpu: 3.5,
                psi: Psi {
                    mem_some10: 1.5,
                    ..Psi::default()
                },
                running: vec![r()],
                slots: vec!["s1".into()],
                images: vec!["fedora@sha256:00".into()],
                on_battery: true,
            },
            Frame::Offer {
                r: r(),
                spec: Box::new(spec()),
                priority: Priority::P3,
                input_key: "k1".into(),
                grant_hint: Some(grant),
                expected: Some(Expected {
                    minutes: 2.0,
                    cpu: 1.0,
                    mem_p95_mib: Some(700),
                }),
            },
            Frame::Admit { r: r(), grant },
            Frame::Refuse {
                r: r(),
                why: "no room".into(),
                reason: Some(WaitReason::NoRoom {
                    need_mib: 2048,
                    free_mib: 100,
                }),
            },
            Frame::SyncHave {
                r: r(),
                repo: "p-0a1b2c3d".into(),
                input_key: "k1".into(),
                commit: "c0ffee".into(),
                tree: "7ree".into(),
                manifest: vec![
                    ManifestEntry::File {
                        path: b"a b\n\xff".to_vec(),
                        mode: 0o100644,
                        sha256: Sha256([7; 32]),
                        size: 12,
                    },
                    ManifestEntry::Deleted {
                        path: b"gone".to_vec(),
                    },
                ],
            },
            Frame::SyncNeed {
                r: r(),
                blobs: vec![Sha256([7; 32])],
                commit: true,
                refs: vec!["c0ffee".repeat(6) + "c0ff"],
            },
            Frame::Blob {
                r: r(),
                sha256: Sha256([7; 32]),
                offset: 0,
                total: 7,
                bytes: b"\0blob\n\xff".to_vec(),
            },
            Frame::Bundle {
                r: r(),
                id: "b1".into(),
                offset: 1 << 20,
                total: 3 << 20,
                sha256: Some(Sha256([9; 32])),
                bytes: vec![1; 300],
            },
            Frame::OriginFetch {
                r: r(),
                repo: "p".into(),
                url: "https://example.org/p.git".into(),
                commit: "c0ffee".into(),
                cred: Some("DEPLOY".into()),
            },
            Frame::Start {
                r: r(),
                image: Some("fedora@sha256:00".into()),
                env: vec![("CI".into(), "1".into())],
                net_hosts: vec!["crates.io:443".into()],
                pins: vec![("registry.corp".into(), "10.0.0.5".parse().unwrap())],
                parser: "cargo-test".into(),
            },
            Frame::Started {
                r: r(),
                unit: "drgnx-run-a3f-2.service".into(),
                at: 1000,
            },
            Frame::Log {
                r: r(),
                offset: 77,
                bytes: b"line\n\x1b[0m".to_vec(),
            },
            Frame::Returned {
                r: r(),
                what: "patch".into(),
                offset: 0,
                total: 9,
                sha256: Sha256([7; 32]),
                left: vec![("w/bin".into(), "a binary file".into())],
                kept: false,
                bytes: b"diff --gi".to_vec(),
            },
            Frame::Row {
                r: r(),
                name: "t::a".into(),
                verdict: "pass".into(),
            },
            key(),
            Frame::KeyUse {
                r: r(),
                name: "TOKEN".into(),
                at: 1001,
            },
            Frame::Finished {
                r: r(),
                result: serde_json::json!({"verdict": "Pass", "counts": {"ran": 3}}),
            },
            Frame::Cancel { r: r() },
            Frame::Fetch {
                r: r(),
                path: "reports/junit.xml".into(),
            },
            Frame::Attach {
                r: r(),
                log_offset: 4096,
            },
            Frame::Done { r: r() },
            Frame::Preempting { at: 5 },
            Frame::Draining,
            Frame::Idle { since: 6 },
            Frame::Ping { at: 7 },
            Frame::Pong { at: 8 },
            Frame::Bye { why: "done".into() },
        ]
    }

    fn wire(frames: &[Frame]) -> Vec<u8> {
        let mut w = FrameWriter::new(Vec::new());
        for f in frames {
            w.write(f).unwrap();
        }
        w.into_inner()
    }

    fn read_all(bytes: &[u8]) -> Result<Vec<Frame>, CodecError> {
        let mut r = FrameReader::new(bytes);
        let mut out = vec![];
        while let Some(f) = r.read()? {
            out.push(f);
        }
        Ok(out)
    }

    /// [D] Every frame, written and read back in one stream, is the frame it was, bytes and key value included.
    #[test]
    fn every_frame_round_trips() {
        let frames = every_frame();
        let back = read_all(&wire(&frames)).unwrap();
        assert_eq!(back.len(), frames.len());
        for (a, b) in frames.iter().zip(&back) {
            assert_eq!(a, b);
        }
    }

    /// [D] A newer peer's fields are ignored, its frames read as `Unknown` (their bytes skipped, so the next frame
    /// still reads), and fields an older peer doesn't send take their defaults.
    #[test]
    fn unknown_fields_and_frames_are_ignored() {
        let mut stream = Vec::new();
        stream.extend_from_slice(
            br#"{"t":"hello","version":1,"hub_id":"h","new_field":{"x":[1,2]}}"#,
        );
        stream.push(b'\n');
        stream.extend_from_slice(br#"{"t":"teleport","to":"mars","len":3}"#);
        stream.push(b'\n');
        stream.extend_from_slice(&3u32.to_be_bytes());
        stream.extend_from_slice(b"xyz");
        stream.extend_from_slice(br#"{"t":"hello-ok","version":1}"#);
        stream.push(b'\n');
        stream.extend_from_slice(
            br#"{"t":"refuse","r":{"job":"a","attempt":1,"nonce":"abababababababababababababababab"},"why":"w","reason":{"Wormhole":3}}"#,
        );
        stream.push(b'\n');
        let frames = read_all(&stream).unwrap();
        assert_eq!(
            frames,
            vec![
                Frame::Hello {
                    version: 1,
                    hub_id: "h".into()
                },
                Frame::Unknown,
                Frame::HelloOk {
                    version: 1,
                    bundle: String::new(),
                    hub_id: String::new(),
                    runner_id: String::new(),
                    boot_id: String::new(),
                    linger: false,
                    attempts: vec![],
                    missing: vec![],
                },
                Frame::Refuse {
                    r: JobRef {
                        job: "a".into(),
                        attempt: 1,
                        nonce: Nonce([0xab; 16])
                    },
                    why: "w".into(),
                    reason: None,
                },
            ]
        );
    }

    /// [D] A key's value is in no `Debug` text and no loggable line, and serde writes it only inside the codec.
    #[test]
    fn a_key_frame_is_never_loggable_or_debug_printed() {
        let f = key();
        assert!(!format!("{f:?}").contains(SECRET));
        assert!(!format!("{f:#?}").contains(SECRET));
        assert_eq!(f.loggable(), None);
        assert!(
            serde_json::to_string(&f).is_err(),
            "serde outside the codec"
        );
        // the codec does write it, and only there
        assert!(String::from_utf8_lossy(&wire(&[f])).contains(SECRET));
        // other frames are loggable, without their bytes
        let log = Frame::Log {
            r: r(),
            offset: 0,
            bytes: b"BYTES".to_vec(),
        };
        let line = log.loggable().unwrap();
        assert!(line.contains("\"t\":\"log\"") && !line.contains("BYTES"));
        // a nonce shows 8 hex digits in Debug
        assert_eq!(format!("{:?}", Nonce([0xab; 16])), "Nonce(abababab)");
    }

    /// [D] A chunk over 1 MiB is refused on both sides: the writer sends nothing, the reader keeps nothing.
    #[test]
    fn binary_chunks_over_1_mib_are_refused() {
        let big = Frame::Blob {
            r: r(),
            sha256: Sha256([0; 32]),
            offset: 0,
            total: 0,
            bytes: vec![0; MAX_CHUNK + 1],
        };
        let mut w = FrameWriter::new(Vec::new());
        assert!(matches!(w.write(&big), Err(CodecError::TooLong { .. })));
        assert!(w.into_inner().is_empty());
        // exactly 1 MiB passes
        let ok = Frame::Blob {
            r: r(),
            sha256: Sha256([0; 32]),
            offset: 0,
            total: 0,
            bytes: vec![0; MAX_CHUNK],
        };
        assert_eq!(read_all(&wire(&[ok])).unwrap().len(), 1);
        // a reader is told a bigger chunk follows: refused before reading it
        let mut stream = br#"{"t":"blob","r":{"job":"a","attempt":1,"nonce":"abababababababababababababababab"},"sha256":"0000000000000000000000000000000000000000000000000000000000000000","len":1048577}"#.to_vec();
        stream.push(b'\n');
        stream.extend_from_slice(&((MAX_CHUNK + 1) as u32).to_be_bytes());
        assert!(matches!(
            read_all(&stream),
            Err(CodecError::TooLong { what: "chunk", .. })
        ));
    }

    /// [D] A job frame needs its whole `JobRef`: without the nonce, or with a short one, it doesn't parse.
    #[test]
    fn a_job_frame_without_a_nonce_does_not_parse() {
        for line in [
            br#"{"t":"cancel","r":{"job":"a","attempt":1}}"#.as_slice(),
            br#"{"t":"cancel","r":{"job":"a","attempt":1,"nonce":"abab"}}"#.as_slice(),
            br#"{"t":"log","r":{"job":"a","attempt":1},"offset":0}"#.as_slice(),
            br#"{"t":"cancel"}"#.as_slice(),
        ] {
            let mut s = line.to_vec();
            s.push(b'\n');
            assert!(
                matches!(read_all(&s), Err(CodecError::Json(_))),
                "{}",
                String::from_utf8_lossy(line)
            );
        }
    }

    proptest! {
        /// [D] Whatever bytes arrive, the reader returns frames or an error, and never panics.
        #[test]
        fn codec_never_panics_on_any_bytes(bytes in proptest::collection::vec(any::<u8>(), 0..2048)) {
            let _ = read_all(&bytes);
            // and the same bytes after a valid frame
            let mut s = wire(&[Frame::Ping { at: 1 }]);
            s.extend_from_slice(&bytes);
            let _ = read_all(&s);
        }
    }
}
