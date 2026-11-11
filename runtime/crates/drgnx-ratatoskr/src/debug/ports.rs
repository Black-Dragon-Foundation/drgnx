//! Each sandboxed debug session's block of loopback ports (spec §21). On macOS, Seatbelt lets a session's adapter
//! and program use only the ports named in its profile (`mac_loopback_ports`), so each session gets a fixed block:
//! the adapter's port, the program's, and one per child process. Blocks sit below macOS's ephemeral range, so the
//! system never hands one out for an outgoing connection.
//!
//! Before a block is given out each of its ports is bound once on 127.0.0.1, ::1 and 0.0.0.0 and let go: a block
//! with a port another process holds is passed over (the macOS runner's spike found 47610 taken now and then), and
//! when every block is taken the session is refused, naming the range.

use std::collections::BTreeSet;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, TcpListener};
use std::ops::Range;
use std::sync::{Arc, Mutex};

/// The first port of macOS's ephemeral range: blocks stay below it.
pub const MAC_EPHEMERAL: u16 = 49152;
/// The ports blocks are cut from.
pub const RANGE: Range<u16> = 47000..49000;
/// Ports per block: the adapter, the program and up to six children.
pub const LEN: u16 = 8;

/// The blocks in use, by first port.
type Taken = Arc<Mutex<BTreeSet<u16>>>;

/// The hub's blocks.
#[derive(Debug)]
pub struct Blocks {
    range: Range<u16>,
    len: u16,
    taken: Taken,
    /// Whether a port is free ([`free`]; the tests' own, as other tests' outgoing connections take real ports).
    probe: fn(u16) -> bool,
}

/// One session's block; its ports go back when it is dropped.
#[derive(Debug)]
pub struct Block {
    first: u16,
    len: u16,
    taken: Taken,
}

impl Default for Blocks {
    fn default() -> Blocks {
        Blocks::new(RANGE, LEN)
    }
}

/// Whether PORT is free on every loopback and the wildcard address (an address this machine lacks, ::1 without
/// IPv6, does not count against it).
pub fn free(port: u16) -> bool {
    let addrs = [
        SocketAddr::from((Ipv4Addr::LOCALHOST, port)),
        SocketAddr::from((Ipv6Addr::LOCALHOST, port)),
        SocketAddr::from((Ipv4Addr::UNSPECIFIED, port)),
    ];
    addrs.iter().all(|a| match TcpListener::bind(a) {
        Ok(_) => true,
        Err(e) => e.kind() == std::io::ErrorKind::AddrNotAvailable,
    })
}

impl Blocks {
    /// Blocks of LEN ports cut from RANGE.
    pub fn new(range: Range<u16>, len: u16) -> Blocks {
        Blocks::with_probe(range, len, free)
    }

    /// Blocks whose ports PROBE says are free.
    pub fn with_probe(range: Range<u16>, len: u16, probe: fn(u16) -> bool) -> Blocks {
        Blocks {
            range,
            len,
            taken: Arc::default(),
            probe,
        }
    }

    pub fn range(&self) -> Range<u16> {
        self.range.clone()
    }

    pub fn size(&self) -> u16 {
        self.len
    }

    /// The first block no session holds whose ports are all free; an error naming the range when there is none.
    pub fn claim(&self) -> Result<Block, String> {
        let mut taken = self.taken.lock().unwrap_or_else(|e| e.into_inner());
        let mut first = self.range.start;
        while first.saturating_add(self.len) <= self.range.end {
            if !taken.contains(&first) && (first..first + self.len).all(self.probe) {
                taken.insert(first);
                return Ok(Block {
                    first,
                    len: self.len,
                    taken: self.taken.clone(),
                });
            }
            first += self.len;
        }
        Err(format!(
            "no free block of {} debug ports in {}-{}: other sessions or programs hold them",
            self.len,
            self.range.start,
            self.range.end - 1
        ))
    }
}

impl Block {
    /// Its ports, in order.
    pub fn ports(&self) -> Vec<u16> {
        (self.first..self.first + self.len).collect()
    }
}

impl Drop for Block {
    fn drop(&mut self) {
        self.taken
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&self.first);
    }
}
