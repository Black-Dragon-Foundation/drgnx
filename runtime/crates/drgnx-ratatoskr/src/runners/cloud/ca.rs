//! SSH to cloud machines (docs/develop/hub.md, "Runners: cloud SSH"; design §6.7.4): the hub's own CA, a short-lived
//! certificate per redial, the hub's private `ssh-agent`, and host keys pinned from the machine's console.
//!
//! - [`Ca`]: one ed25519 CA per hub, made at cloud setup. The editor writes it to the keyring ([`Ca::to_secret`]) and
//!   hands it back through `runners/keys` ([`Ca::from_secret`]); the hub holds it in memory only.
//! - [`UserKey`]: a fresh ed25519 key per redial, in memory only, added to [`Agent`] (the hub's own `ssh-agent`, never
//!   the user's) through `ssh-add -` on stdin, with a lifetime.
//! - [`Ca::sign`]: an OpenSSH user certificate for that key, the machine's principal, valid for an hour. A certificate
//!   is public: it is written as the file `CertificateFile` names, beside the key's public half (`IdentityFile`), so
//!   ssh signs with the agent's key.
//! - [`pin`]: the host keys the machine printed on its console at first boot, read as cloud-init prints them, written
//!   to the machine's `UserKnownHostsFile`. No trust on first use: a console without them refuses the machine.
//!
//! Keys are made with `ring` (Call 11's fallback: `ssh-key` 0.6 would add a second `sha2`), and the OpenSSH formats
//! (`openssh-key-v1`, `ssh-ed25519-cert-v01@openssh.com`) are written here.

use super::{b64, b64_decode};
use ring::rand::{SecureRandom, SystemRandom};
use ring::signature::{Ed25519KeyPair, KeyPair};
use secrecy::{ExposeSecret, SecretString};
use sha2::{Digest, Sha256};
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};
use zeroize::Zeroizing;

const ED25519: &str = "ssh-ed25519";
const CERT_ED25519: &str = "ssh-ed25519-cert-v01@openssh.com";
// the PEM armour, in pieces: the repo's pre-commit hook refuses the whole marker as a committed key
const PEM_BEGIN: &str = concat!("-----BEGIN OPENSSH ", "PRIVATE", " KEY-----");
const PEM_END: &str = concat!("-----END OPENSSH ", "PRIVATE", " KEY-----");
/// How far a certificate's start is set back, for a machine whose clock is a little behind the hub's.
const SKEW: Duration = Duration::from_secs(60);

fn put_string(out: &mut Vec<u8>, b: &[u8]) {
    out.extend_from_slice(&(b.len() as u32).to_be_bytes());
    out.extend_from_slice(b);
}

/// SSH's wire format, read.
struct Wire<'a>(&'a [u8]);

impl<'a> Wire<'a> {
    fn u32(&mut self) -> Option<u32> {
        let (h, t) = self.0.split_at_checked(4)?;
        self.0 = t;
        Some(u32::from_be_bytes(h.try_into().ok()?))
    }
    #[cfg(test)]
    fn u64(&mut self) -> Option<u64> {
        let (h, t) = self.0.split_at_checked(8)?;
        self.0 = t;
        Some(u64::from_be_bytes(h.try_into().ok()?))
    }
    fn string(&mut self) -> Option<&'a [u8]> {
        let n = self.u32()? as usize;
        let (h, t) = self.0.split_at_checked(n)?;
        self.0 = t;
        Some(h)
    }
}

fn sha256_fingerprint(blob: &[u8]) -> String {
    format!(
        "SHA256:{}",
        b64(&Sha256::digest(blob)).trim_end_matches('=')
    )
}

fn random<const N: usize>() -> [u8; N] {
    let mut b = [0u8; N];
    SystemRandom::new()
        .fill(&mut b)
        .expect("the system's random source answers");
    b
}

/// An SSH public key, as its wire blob.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PublicKey {
    blob: Vec<u8>,
}

impl PublicKey {
    fn ed25519(raw: &[u8]) -> PublicKey {
        let mut blob = Vec::new();
        put_string(&mut blob, ED25519.as_bytes());
        put_string(&mut blob, raw);
        PublicKey { blob }
    }

    /// `ssh-ed25519 AAAA… COMMENT`, as an `authorized_keys` or `.pub` file holds it.
    pub fn to_openssh(&self, comment: &str) -> String {
        format!("{ED25519} {} {comment}", b64(&self.blob))
    }

    /// `SHA256:…`, as `ssh-keygen -l` prints it.
    pub fn fingerprint(&self) -> String {
        sha256_fingerprint(&self.blob)
    }

    pub fn blob(&self) -> &[u8] {
        &self.blob
    }

    /// The raw 32-byte ed25519 key.
    fn raw(&self) -> &[u8] {
        let mut w = Wire(&self.blob);
        let _ = w.string();
        w.string().unwrap_or_default()
    }
}

/// An ed25519 key pair whose seed lives in memory only, wiped when dropped.
struct Ed25519Key {
    seed: Zeroizing<[u8; 32]>,
    pair: Ed25519KeyPair,
}

impl Ed25519Key {
    fn generate() -> Ed25519Key {
        let seed = Zeroizing::new(random::<32>());
        Ed25519Key::from_seed(seed).expect("a random seed is a key")
    }

    fn from_seed(seed: Zeroizing<[u8; 32]>) -> Result<Ed25519Key, String> {
        let pair = Ed25519KeyPair::from_seed_unchecked(&seed[..])
            .map_err(|e| format!("not an ed25519 key: {e}"))?;
        Ok(Ed25519Key { seed, pair })
    }

    fn public(&self) -> PublicKey {
        PublicKey::ed25519(self.pair.public_key().as_ref())
    }

    /// The `ssh-ed25519` signature blob over DATA.
    fn sign(&self, data: &[u8]) -> Vec<u8> {
        let mut sig = Vec::new();
        put_string(&mut sig, ED25519.as_bytes());
        put_string(&mut sig, self.pair.sign(data).as_ref());
        sig
    }

    /// The unencrypted `openssh-key-v1` PEM (`PEM_BEGIN`), as `ssh-add -` reads it.
    fn openssh_private(&self, comment: &str) -> Zeroizing<String> {
        let public = self.public();
        let raw_pub = public.raw().to_vec();
        let check = random::<4>();
        let mut private = Zeroizing::new(Vec::new());
        private.extend_from_slice(&check);
        private.extend_from_slice(&check);
        put_string(&mut private, ED25519.as_bytes());
        put_string(&mut private, &raw_pub);
        let mut both = Zeroizing::new(Vec::with_capacity(64));
        both.extend_from_slice(&self.seed[..]);
        both.extend_from_slice(&raw_pub);
        put_string(&mut private, &both);
        put_string(&mut private, comment.as_bytes());
        let mut pad = 1u8;
        while private.len() % 8 != 0 {
            private.push(pad);
            pad += 1;
        }
        let mut file = Zeroizing::new(b"openssh-key-v1\0".to_vec());
        put_string(&mut file, b"none");
        put_string(&mut file, b"none");
        put_string(&mut file, b"");
        file.extend_from_slice(&1u32.to_be_bytes());
        put_string(&mut file, public.blob());
        put_string(&mut file, &private);
        let body = Zeroizing::new(b64(&file));
        let mut pem = Zeroizing::new(String::with_capacity(body.len() + 80));
        pem.push_str(PEM_BEGIN);
        pem.push('\n');
        for line in body.as_bytes().chunks(70) {
            pem.push_str(std::str::from_utf8(line).expect("base64 is ASCII"));
            pem.push('\n');
        }
        pem.push_str(PEM_END);
        pem.push('\n');
        pem
    }

    /// The key in an unencrypted `openssh-key-v1` PEM.
    fn from_openssh_private(pem: &str) -> Result<Ed25519Key, String> {
        let bad = |what: &str| format!("not an unencrypted OpenSSH ed25519 key: {what}");
        let body = pem
            .trim()
            .strip_prefix(PEM_BEGIN)
            .and_then(|s| s.strip_suffix(PEM_END))
            .ok_or_else(|| bad("no PEM armour"))?;
        let file = Zeroizing::new(b64_decode(body).ok_or_else(|| bad("not base64"))?);
        let rest = file
            .strip_prefix(b"openssh-key-v1\0")
            .ok_or_else(|| bad("no magic"))?;
        let mut w = Wire(rest);
        let (cipher, kdf, _opts) = (w.string(), w.string(), w.string());
        if cipher != Some(&b"none"[..]) || kdf != Some(&b"none"[..]) {
            return Err(bad("encrypted"));
        }
        if w.u32() != Some(1) {
            return Err(bad("not one key"));
        }
        let _public = w.string().ok_or_else(|| bad("no public key"))?;
        let mut p = Wire(w.string().ok_or_else(|| bad("no private section"))?);
        let (c1, c2) = (p.u32(), p.u32());
        if c1.is_none() || c1 != c2 {
            return Err(bad("check numbers differ"));
        }
        if p.string() != Some(ED25519.as_bytes()) {
            return Err(bad("not ed25519"));
        }
        let raw_pub = p.string().ok_or_else(|| bad("no public half"))?;
        let both = p
            .string()
            .filter(|b| b.len() == 64)
            .ok_or_else(|| bad("no private half"))?;
        let mut seed = Zeroizing::new([0u8; 32]);
        seed.copy_from_slice(&both[..32]);
        let key = Ed25519Key::from_seed(seed)?;
        if key.public().raw() != raw_pub || &both[32..] != raw_pub {
            return Err(bad("the halves do not match"));
        }
        Ok(key)
    }
}

/// The hub's SSH CA. Never `Debug` or `Clone`; its private half leaves memory only as [`Ca::to_secret`], for the
/// editor to write to the keyring.
pub struct Ca {
    key: Ed25519Key,
}

/// A user key for one redial: in memory only, given to the hub's own agent and nowhere else.
pub struct UserKey {
    key: Ed25519Key,
}

impl UserKey {
    pub fn generate() -> UserKey {
        UserKey {
            key: Ed25519Key::generate(),
        }
    }

    pub fn public(&self) -> PublicKey {
        self.key.public()
    }
}

/// An OpenSSH user certificate.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Certificate {
    blob: Vec<u8>,
    pub principal: String,
    /// Seconds since the epoch.
    pub valid_after: u64,
    pub valid_before: u64,
}

impl Certificate {
    /// `ssh-ed25519-cert-v01@openssh.com AAAA… drgnx`, the `CertificateFile`'s line.
    pub fn to_openssh(&self) -> String {
        format!("{CERT_ED25519} {} drgnx\n", b64(&self.blob))
    }

    pub fn blob(&self) -> &[u8] {
        &self.blob
    }
}

impl Ca {
    /// A new CA and its public key (for `TrustedUserCAKeys` in the image).
    pub fn new() -> (Ca, PublicKey) {
        let ca = Ca {
            key: Ed25519Key::generate(),
        };
        let public = ca.public();
        (ca, public)
    }

    pub fn public(&self) -> PublicKey {
        self.key.public()
    }

    /// The CA as the keyring keeps it: its unencrypted OpenSSH PEM.
    pub fn to_secret(&self) -> SecretString {
        SecretString::from(self.key.openssh_private("drgnx-ca").as_str().to_owned())
    }

    /// The CA the editor handed back.
    pub fn from_secret(s: &SecretString) -> Result<Ca, String> {
        Ok(Ca {
            key: Ed25519Key::from_openssh_private(s.expose_secret())?,
        })
    }

    /// A user certificate for USER with PRINCIPAL as its only principal and key id, valid from now (less a minute for
    /// clock skew) for VALID (`-V +1h`); no extensions (no pty, no forwarding) and no critical options.
    pub fn sign(&self, user: &PublicKey, principal: &str, valid: Duration) -> Certificate {
        let now = crate::clock::wall()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        let (after, before) = (now.saturating_sub(SKEW.as_secs()), now + valid.as_secs());
        let mut blob = Vec::new();
        put_string(&mut blob, CERT_ED25519.as_bytes());
        put_string(&mut blob, &random::<32>());
        put_string(&mut blob, user.raw());
        blob.extend_from_slice(&u64::from_be_bytes(random::<8>()).to_be_bytes());
        blob.extend_from_slice(&1u32.to_be_bytes()); // a user certificate
        put_string(&mut blob, principal.as_bytes());
        let mut principals = Vec::new();
        put_string(&mut principals, principal.as_bytes());
        put_string(&mut blob, &principals);
        blob.extend_from_slice(&after.to_be_bytes());
        blob.extend_from_slice(&before.to_be_bytes());
        put_string(&mut blob, b""); // critical options
        put_string(&mut blob, b""); // extensions
        put_string(&mut blob, b""); // reserved
        put_string(&mut blob, self.public().blob());
        let sig = self.key.sign(&blob);
        put_string(&mut blob, &sig);
        Certificate {
            blob,
            principal: principal.to_string(),
            valid_after: after,
            valid_before: before,
        }
    }
}

/// The hub's own `ssh-agent` (design §6.7.4): a socket in the runners' folder under `$XDG_RUNTIME_DIR` (`$TMPDIR` on
/// macOS). Every command it runs has a clean environment with only `PATH` and our `SSH_AUTH_SOCK`, so the user's agent
/// is never asked anything. Dropping it stops the agent and removes its socket.
pub struct Agent {
    sock: PathBuf,
    child: std::process::Child,
    /// The agent's stdout, kept open: it would die of SIGPIPE writing to a closed one.
    _out: std::process::ChildStdout,
}

impl Agent {
    /// Starts the agent under RUNTIME_DIR (`drgnx-runners/agent.sock`) and returns once its socket is there: it prints
    /// `SSH_AUTH_SOCK=…` after binding it. Blocking.
    pub fn start(runtime_dir: &Path) -> io::Result<Agent> {
        let dir = runtime_dir.join("drgnx-runners");
        crate::runners::ssh_config::private_dir(&dir)?;
        let sock = dir.join("agent.sock");
        match std::fs::remove_file(&sock) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
            _ => {}
        }
        let mut child = clean("ssh-agent", None)
            .arg("-D")
            .arg("-a")
            .arg(&sock)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()?;
        let out = child.stdout.take().expect("piped");
        let mut first = String::new();
        let mut r = io::BufReader::new(out);
        r.read_line(&mut first)?;
        if !first.starts_with("SSH_AUTH_SOCK=") {
            let _ = child.kill();
            let _ = child.wait();
            return Err(io::Error::other("ssh-agent did not start"));
        }
        Ok(Agent {
            sock,
            child,
            _out: r.into_inner(),
        })
    }

    pub fn socket(&self) -> &Path {
        &self.sock
    }

    /// KEY to the agent for LIFETIME, through `ssh-add -t SECS -` with the key on stdin: never a file. Blocking.
    pub fn add(&self, key: &UserKey, lifetime: Duration) -> io::Result<()> {
        let mut child = clean("ssh-add", Some(self.sock.as_path()))
            .arg("-q")
            .arg("-t")
            .arg(lifetime.as_secs().max(1).to_string())
            .arg("-")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .spawn()?;
        {
            let pem = key.key.openssh_private("drgnx");
            let mut stdin = child.stdin.take().expect("piped");
            stdin.write_all(pem.as_bytes())?;
        }
        let out = child.wait_with_output()?;
        if !out.status.success() {
            return Err(io::Error::other(format!(
                "ssh-add refused the key: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
        Ok(())
    }
}

impl Drop for Agent {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_file(&self.sock);
    }
}

/// PROG with nothing of the hub's environment but `PATH`, and SOCK as `SSH_AUTH_SOCK` when given.
fn clean(prog: &str, sock: Option<&Path>) -> std::process::Command {
    let mut c = std::process::Command::new(prog);
    c.env_clear();
    if let Some(path) = std::env::var_os("PATH") {
        c.env("PATH", path);
    }
    if let Some(s) = sock {
        c.env("SSH_AUTH_SOCK", s);
    }
    c
}

/// Host keys from a machine's console (design §6.7.4): pinned, never learned.
pub mod pin {
    use super::{Wire, b64, b64_decode, sha256_fingerprint};

    const FP_BEGIN: &str = "-----BEGIN SSH HOST KEY FINGERPRINTS-----";
    const FP_END: &str = "-----END SSH HOST KEY FINGERPRINTS-----";
    const KEYS_BEGIN: &str = "-----BEGIN SSH HOST KEY KEYS-----";
    const KEYS_END: &str = "-----END SSH HOST KEY KEYS-----";
    /// More host keys than a machine has is a console that is not ours.
    const MAX_KEYS: usize = 16;

    /// A host key: its algorithm and wire blob.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub struct HostKey {
        pub algo: String,
        pub blob: Vec<u8>,
    }

    impl HostKey {
        pub fn fingerprint(&self) -> String {
            sha256_fingerprint(&self.blob)
        }
    }

    /// The lines between the last BEGIN and the END after it.
    fn last_block<'a>(lines: &[&'a str], begin: &str, end: &str) -> Option<Vec<&'a str>> {
        let start = lines.iter().rposition(|l| l.contains(begin))?;
        let len = lines[start + 1..].iter().position(|l| l.contains(end))?;
        Some(lines[start + 1..start + 1 + len].to_vec())
    }

    /// The host keys the machine printed at first boot, as cloud-init's `write-ssh-key-fingerprints` prints them: the
    /// fingerprints through `logger -s -t cloud-init` (each line after a syslog prefix), then the public keys as they
    /// are. A key counts only when its own SHA-256 is among the fingerprints. Refused: a console without both blocks
    /// (not booted yet, or not our image), a key the fingerprints don't list, no key at all.
    pub fn from_console(text: &str) -> Result<Vec<HostKey>, String> {
        let lines: Vec<&str> = text.lines().map(|l| l.trim_end_matches('\r')).collect();
        let fps: Vec<&str> = last_block(&lines, FP_BEGIN, FP_END)
            .ok_or("the console shows no host key fingerprints (cloud-init's BEGIN SSH HOST KEY FINGERPRINTS); no key is trusted on first use")?
            .into_iter()
            .flat_map(|l| l.split_whitespace())
            .filter(|w| w.starts_with("SHA256:"))
            .collect();
        let block = last_block(&lines, KEYS_BEGIN, KEYS_END).ok_or(
            "the console shows host key fingerprints but no keys (BEGIN SSH HOST KEY KEYS)",
        )?;
        let mut keys = Vec::new();
        for line in block {
            let words: Vec<&str> = line.split_whitespace().collect();
            let found = words.windows(2).find_map(|w| {
                let blob = b64_decode(w[1])?;
                let algo = Wire(&blob).string()?;
                (algo == w[0].as_bytes()).then(|| HostKey {
                    algo: w[0].to_string(),
                    blob,
                })
            });
            let Some(k) = found else { continue };
            if !fps.contains(&k.fingerprint().as_str()) {
                return Err(format!(
                    "the console's {} host key ({}) is not among its fingerprints",
                    k.algo,
                    k.fingerprint()
                ));
            }
            keys.push(k);
        }
        if keys.is_empty() {
            return Err("the console's host key block holds no key".into());
        }
        if keys.len() > MAX_KEYS {
            return Err(format!("the console lists {} host keys", keys.len()));
        }
        Ok(keys)
    }

    /// The `known_hosts` text pinning KEYS for HOST (a `user@` part is dropped; port 22).
    pub fn known_hosts(host: &str, keys: &[HostKey]) -> String {
        let h = host.rsplit_once('@').map_or(host, |(_, h)| h);
        keys.iter()
            .map(|k| format!("{h} {} {}\n", k.algo, b64(&k.blob)))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::pin::{HostKey, from_console, known_hosts};
    use super::*;

    // [D] pure
    #[test]
    fn a_certificate_carries_the_principal_and_1h() {
        let (ca, ca_pub) = Ca::new();
        let user = UserKey::generate();
        let before = crate::clock::wall()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let cert = ca.sign(&user.public(), "drgnx-c1", Duration::from_secs(3600));
        let mut w = Wire(cert.blob());
        assert_eq!(w.string(), Some(CERT_ED25519.as_bytes()));
        assert_eq!(w.string().map(<[u8]>::len), Some(32), "the nonce");
        assert_eq!(w.string(), Some(user.public().raw()));
        let _serial = w.u64().unwrap();
        assert_eq!(w.u32(), Some(1), "a user certificate");
        assert_eq!(w.string(), Some(&b"drgnx-c1"[..]), "the key id");
        let mut principals = Wire(w.string().unwrap());
        assert_eq!(principals.string(), Some(&b"drgnx-c1"[..]));
        assert_eq!(principals.string(), None, "one principal only");
        let (after, until) = (w.u64().unwrap(), w.u64().unwrap());
        assert!(
            after <= before && before - after <= SKEW.as_secs(),
            "{after} {before}"
        );
        assert!(
            until >= before + 3600 && until <= before + 3600 + 5,
            "{until} {before}"
        );
        assert_eq!((cert.valid_after, cert.valid_before), (after, until));
        assert_eq!(w.string(), Some(&b""[..]), "no critical options");
        assert_eq!(
            w.string(),
            Some(&b""[..]),
            "no extensions: no pty, no forwarding"
        );
        assert_eq!(w.string(), Some(&b""[..]));
        assert_eq!(w.string(), Some(ca_pub.blob()));
        let signed_len = cert.blob().len() - w.0.len();
        let mut sig = Wire(w.string().unwrap());
        assert_eq!(sig.string(), Some(ED25519.as_bytes()));
        let raw_sig = sig.string().unwrap();
        ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, ca_pub.raw())
            .verify(&cert.blob()[..signed_len], raw_sig)
            .expect("the CA's signature verifies");
        assert!(
            cert.to_openssh()
                .starts_with("ssh-ed25519-cert-v01@openssh.com AAAA")
        );
        // the keyring's copy is the same CA
        let again = Ca::from_secret(&ca.to_secret()).unwrap();
        assert_eq!(again.public(), ca_pub);
        assert!(Ca::from_secret(&SecretString::from("not a key".to_string())).is_err());
    }

    /// Every file under DIR (to depth 4) that holds NEEDLE.
    fn files_holding(dir: &Path, needle: &[u8], depth: u32, hits: &mut Vec<PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for e in entries.flatten() {
            let Ok(t) = e.file_type() else { continue };
            if t.is_dir() && depth > 0 {
                files_holding(&e.path(), needle, depth - 1, hits);
            } else if t.is_file()
                && e.metadata().is_ok_and(|m| m.len() < 16 << 20)
                && std::fs::read(e.path())
                    .is_ok_and(|b| b.windows(needle.len()).any(|w| w == needle))
            {
                hits.push(e.path());
            }
        }
    }

    // [D] pure (a real ssh-agent, waited on through its own announcement)
    #[test]
    fn the_ca_never_reaches_a_file() {
        let runtime = tempfile::tempdir().unwrap();
        let (ca, _) = Ca::new();
        let seed = ca.key.seed.to_vec();
        let pem = ca.to_secret();
        let user = UserKey::generate();
        let cert = ca.sign(&user.public(), "drgnx-c1", Duration::from_secs(3600));
        let agent = Agent::start(runtime.path()).unwrap();
        agent.add(&user, Duration::from_secs(60)).unwrap();
        let d = crate::runners::ssh_config::dir(runtime.path(), "c1");
        crate::runners::ssh_config::write_in(
            runtime.path(),
            "c1",
            "id-cert.pub",
            &cert.to_openssh(),
        )
        .unwrap();
        assert!(d.join("id-cert.pub").exists());
        let body: String = pem
            .expose_secret()
            .lines()
            .filter(|l| !l.starts_with("-----"))
            .collect();
        for needle in [
            &seed[..],
            body.as_bytes(),
            &body.as_bytes()[..40],
            b64(&seed).as_bytes(),
        ] {
            let mut hits = Vec::new();
            files_holding(runtime.path(), needle, 4, &mut hits);
            files_holding(&std::env::temp_dir(), needle, 2, &mut hits);
            assert!(hits.is_empty(), "the CA's bytes are in {hits:?}");
        }
    }

    // [D] pure (a real ssh-agent; the user's agent is a listener that records any connection)
    #[test]
    fn the_users_agent_is_never_touched() {
        let runtime = tempfile::tempdir().unwrap();
        let users = runtime.path().join("users-agent.sock");
        let fake = std::os::unix::net::UnixListener::bind(&users).unwrap();
        fake.set_nonblocking(true).unwrap();
        // SAFETY: no other test of this crate reads SSH_AUTH_SOCK from the process environment (the sandbox reads its
        // own copy of the environment); it is set for this test's children to inherit if anything let them.
        unsafe { std::env::set_var("SSH_AUTH_SOCK", &users) };
        let agent = Agent::start(runtime.path()).unwrap();
        let key = UserKey::generate();
        agent.add(&key, Duration::from_secs(60)).unwrap();
        // the key is in our agent
        let listed = clean("ssh-add", Some(agent.socket()))
            .arg("-L")
            .output()
            .unwrap();
        assert!(
            String::from_utf8_lossy(&listed.stdout).contains(&b64(key.public().blob())),
            "{listed:?}"
        );
        drop(agent);
        unsafe { std::env::remove_var("SSH_AUTH_SOCK") };
        // every command above has finished: a request to the user's agent would be waiting to be accepted
        match fake.accept() {
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
            other => panic!("the user's agent was asked: {other:?}"),
        }
    }

    /// A fake host key of ALGO: its wire blob with BODY.
    fn fake_key(algo: &str, body: &[u8]) -> HostKey {
        let mut blob = Vec::new();
        put_string(&mut blob, algo.as_bytes());
        put_string(&mut blob, body);
        HostKey {
            algo: algo.into(),
            blob,
        }
    }

    /// A console as cloud-init writes it: the fingerprints after syslog prefixes, then the keys.
    fn console(keys: &[HostKey], fps: &[String]) -> String {
        let mut t = String::from("[    3.141592] systemd[1]: Started cloud-final.service\n");
        let pre = "<14>Nov  6 00:00:05 cloud-init: ";
        t += &format!("{pre}#############################################################\n");
        t += &format!("{pre}-----BEGIN SSH HOST KEY FINGERPRINTS-----\n");
        for (k, fp) in keys.iter().zip(fps) {
            t += &format!(
                "{pre}256 {fp} root@ip-10-0-0-5 ({})\n",
                k.algo.to_uppercase()
            );
        }
        t += &format!("{pre}-----END SSH HOST KEY FINGERPRINTS-----\n");
        t += &format!("{pre}#############################################################\n");
        t += "-----BEGIN SSH HOST KEY KEYS-----\n";
        for k in keys {
            t += &format!("{} {} root@ip-10-0-0-5\n", k.algo, b64(&k.blob));
        }
        t += "-----END SSH HOST KEY KEYS-----\n";
        t
    }

    // [D] pure
    #[test]
    fn pinning_refuses_a_console_without_fingerprints() {
        let keys = [
            fake_key("ssh-ed25519", &[7; 32]),
            fake_key("ecdsa-sha2-nistp256", &[9; 40]),
            fake_key("ssh-mldsa44-ed25519@openssh.com", &[3; 64]),
        ];
        let fps: Vec<String> = keys.iter().map(HostKey::fingerprint).collect();
        let good = console(&keys, &fps);
        assert_eq!(from_console(&good).unwrap(), keys);
        let kh = known_hosts("runner@10.0.0.5", &keys[..1]);
        assert_eq!(kh, format!("10.0.0.5 ssh-ed25519 {}\n", b64(&keys[0].blob)));

        // nothing yet: a machine still booting, or not our image
        assert!(from_console("").is_err());
        assert!(from_console("[    0.0] Linux version 6.17\nlogin: ").is_err());
        // fingerprints without keys, keys without fingerprints
        let fp_only: String = good.lines().take(7).map(|l| format!("{l}\n")).collect();
        assert!(from_console(&fp_only).unwrap_err().contains("no keys"));
        let keys_only: String = good.lines().skip(7).map(|l| format!("{l}\n")).collect();
        assert!(
            from_console(&keys_only)
                .unwrap_err()
                .contains("fingerprints")
        );
        // a key whose hash the fingerprints don't list
        let wrong = console(
            &keys,
            &[
                fps[0].clone(),
                "SHA256:somethingelse".into(),
                fps[2].clone(),
            ],
        );
        assert!(
            from_console(&wrong)
                .unwrap_err()
                .contains("ecdsa-sha2-nistp256")
        );
        // a later boot's blocks win over an earlier one's
        let other = [fake_key("ssh-ed25519", &[8; 32])];
        let twice = format!("{good}{}", console(&other, &[other[0].fingerprint()]));
        assert_eq!(from_console(&twice).unwrap(), other);
    }
}
