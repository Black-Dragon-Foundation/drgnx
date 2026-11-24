//! Who calls a method, and which peers the hub talks to at all.

use runstav::registry::Class;

/// Who calls a method: the connection's class, and for an agent socket its session and job.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Caller {
    pub class: Class,
    pub sid: Option<String>,
    pub job: Option<String>,
    pub conn_id: u64,
}

/// May a peer of PEER_UID talk to a hub running as OWN_UID?  Only the same uid: another user (root included) is
/// closed at once.
pub fn peer_allowed(peer_uid: u32, own_uid: u32) -> bool {
    peer_uid == own_uid
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_same_uid_is_allowed() {
        assert!(peer_allowed(1000, 1000));
        assert!(!peer_allowed(0, 1000));
        assert!(!peer_allowed(1000, 0));
    }
}
