//! The generated face enum and kit tables (`src/faces.rs`, `src/kit_gen.rs`, from `bin/drgnx design`) agree with
//! themselves: every face's name reads back, the numbered families are whole, and the kit's tables answer.

use drgnx_rows::faces::FaceId;
use drgnx_rows::kit_gen::{self, CompId, STATES, State};

#[test]
fn faces_round_trip() {
    for face in FaceId::ALL {
        assert_eq!(FaceId::from_name(face.name()), Some(face), "{face:?}");
    }
    assert_eq!(FaceId::from_name("drgnx-no-such-face"), None);
    assert_eq!(FaceId::TextMuted.name(), "drgnx-text-muted");
    assert_eq!(FaceId::Bold.name(), "bold");
    assert_eq!(FaceId::AGENT.len(), 12);
    assert_eq!(FaceId::AGENT[0].name(), "drgnx-agent-1");
    assert_eq!(FaceId::AGENT[11].name(), "drgnx-agent-12");
    assert_eq!(FaceId::WORK_WHO.len(), 6);
}

#[test]
fn kit_tables_answer() {
    assert_eq!(STATES.len(), 6);
    assert_eq!(STATES[0], (State::Hover, FaceId::Hover));
    assert!(STATES.contains(&(State::Selected, FaceId::Selected)));
    let tree = kit_gen::geom(CompId::Row, &["tree"]);
    assert_eq!(tree.pad, (6, 6));
    assert_eq!(tree.radius, 6);
    assert!(!tree.boxed);
    assert_eq!(tree.height, 26);
    assert_eq!(tree.indent, 12);
    assert_eq!(kit_gen::geom(CompId::Row, &["tree", "roomy"]).height, 30);
    assert_eq!(kit_gen::geom(CompId::Row, &["list"]).indent, 0);
    assert_eq!(
        kit_gen::geom(CompId::Row, &[]),
        kit_gen::geom(CompId::Row, &["list", "comfortable"])
    );
    assert_eq!(kit_gen::face(CompId::Row, &[]), FaceId::Default);
    assert_eq!(kit_gen::label(CompId::Row, &[]), None);
}
