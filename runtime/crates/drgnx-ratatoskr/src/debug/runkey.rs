//! The key of the recorded runs (spec §19.2, the user's Q18 ruling): run files are sealed at rest with a key kept in
//! the user's keyring, unlocked at login.
//!
//! - **The key** is 32 random bytes in the OS keyring: the Secret Service's default collection on Linux, the login
//!   Keychain on macOS. It is made on the first recording, and only in an unlocked keyring. Nothing here ever asks:
//!   no Unlock, no Prompt, no Keychain dialog (user interaction is off around each call). A locked keyring, or none
//!   (no default collection: making one would prompt), leaves recording off, says why, and the runs on disk cannot be
//!   read until it unlocks.
//! - **Each run file** has a random salt in its header; its key is HKDF-SHA256 of the keyring key with that salt.
//!   Every sealed piece (a block, the index, the run's start) is ChaCha20-Poly1305 with a random nonce in front of it.
//!   Losing the keyring key makes the old runs unreadable: they are disposable (14 days), so there is no escrow and no
//!   plaintext copy.
//! - The key, the derived keys, salts and nonces are never logged; derived key bytes are wiped once the cipher key is
//!   made.

use super::BoxFut;
use ring::aead::{CHACHA20_POLY1305, LessSafeKey, NONCE_LEN, Nonce, UnboundKey};
use ring::rand::{SecureRandom, SystemRandom};
use zeroize::Zeroizing;

/// The keyring key.
pub type Key = Zeroizing<[u8; 32]>;

/// The salt's length in a run file's header.
pub const SALT_LEN: usize = 32;

/// Why there is no key now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Unavailable {
    /// The keyring is locked: it unlocks at login.
    Locked,
    /// No keyring, or no key in it (and none may be made now): WHY.
    Missing(String),
    /// The keyring answered with an error.
    Failed(String),
}

impl Unavailable {
    /// What the user is told.
    pub fn why(&self) -> String {
        match self {
            Unavailable::Locked => "the keyring is locked; it unlocks when you log in".into(),
            Unavailable::Missing(w) | Unavailable::Failed(w) => w.clone(),
        }
    }
}

/// Where the key lives. `key` never prompts; CREATE makes the key when there is none, in an unlocked keyring only.
pub trait KeyStore: Send + Sync {
    fn key(&self, create: bool) -> BoxFut<'_, Result<Key, Unavailable>>;
}

/// 32 random bytes.
pub fn random_key() -> Key {
    let mut k = Zeroizing::new([0u8; 32]);
    SystemRandom::new()
        .fill(k.as_mut())
        .expect("the system's random source");
    k
}

/// A new salt for a run file.
pub fn new_salt() -> [u8; SALT_LEN] {
    let mut s = [0u8; SALT_LEN];
    SystemRandom::new()
        .fill(&mut s)
        .expect("the system's random source");
    s
}

struct Len32;

impl ring::hkdf::KeyType for Len32 {
    fn len(&self) -> usize {
        32
    }
}

/// One run file's cipher: the keyring key and the file's salt.
pub struct FileKey(LessSafeKey);

impl FileKey {
    pub fn new(key: &Key, salt: &[u8; SALT_LEN]) -> FileKey {
        let prk = ring::hkdf::Salt::new(ring::hkdf::HKDF_SHA256, salt).extract(key.as_ref());
        let mut bytes = Zeroizing::new([0u8; 32]);
        prk.expand(&[b"drgnx debug run v2"], Len32)
            .and_then(|okm| okm.fill(bytes.as_mut()))
            .expect("HKDF of 32 bytes");
        let unbound = UnboundKey::new(&CHACHA20_POLY1305, bytes.as_ref()).expect("a 32-byte key");
        FileKey(LessSafeKey::new(unbound))
    }

    /// PLAIN sealed, bound to WHAT (which piece of the file it is): the nonce, then the cipher text and its tag.
    pub fn seal(&self, what: &[u8], plain: &[u8]) -> Vec<u8> {
        let mut nonce = [0u8; NONCE_LEN];
        SystemRandom::new()
            .fill(&mut nonce)
            .expect("the system's random source");
        let mut body = plain.to_vec();
        self.0
            .seal_in_place_append_tag(
                Nonce::assume_unique_for_key(nonce),
                ring::aead::Aad::from(what),
                &mut body,
            )
            .expect("sealing in memory");
        let mut out = Vec::with_capacity(NONCE_LEN + body.len());
        out.extend_from_slice(&nonce);
        out.extend_from_slice(&body);
        out
    }

    /// SEALED (from [`FileKey::seal`] with the same WHAT) opened; none when it was changed or is another key's.
    pub fn open(&self, what: &[u8], sealed: &[u8]) -> Option<Vec<u8>> {
        if sealed.len() < NONCE_LEN {
            return None;
        }
        let (n, body) = sealed.split_at(NONCE_LEN);
        let nonce = Nonce::try_assume_unique_for_key(n).ok()?;
        let mut body = body.to_vec();
        let plain = self
            .0
            .open_in_place(nonce, ring::aead::Aad::from(what), &mut body)
            .ok()?;
        Some(plain.to_vec())
    }
}

/// A key store in memory (the default of [`super::record::Opts`], and tests'): its key, or why there is none (locked,
/// absent); `made` counts the keys it made.
#[derive(Default)]
pub struct Memory {
    pub state: std::sync::Mutex<MemoryState>,
}

#[derive(Default)]
pub struct MemoryState {
    pub key: Option<[u8; 32]>,
    pub locked: bool,
    /// No keyring at all.
    pub absent: bool,
    pub made: u32,
}

impl KeyStore for Memory {
    fn key(&self, create: bool) -> BoxFut<'_, Result<Key, Unavailable>> {
        Box::pin(async move {
            let mut s = self.state.lock().unwrap_or_else(|e| e.into_inner());
            if s.absent {
                return Err(Unavailable::Missing("no keyring".into()));
            }
            if s.locked {
                return Err(Unavailable::Locked);
            }
            match (s.key, create) {
                (Some(k), _) => Ok(Zeroizing::new(k)),
                (None, true) => {
                    let k = random_key();
                    s.key = Some(*k);
                    s.made += 1;
                    Ok(k)
                }
                (None, false) => Err(Unavailable::Missing("no key in the keyring yet".into())),
            }
        })
    }
}

/// The user's keyring on this system.
pub fn os() -> std::sync::Arc<dyn KeyStore> {
    #[cfg(target_os = "linux")]
    {
        std::sync::Arc::new(secret::SecretStore::default())
    }
    #[cfg(target_os = "macos")]
    {
        std::sync::Arc::new(keychain::Keychain)
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        std::sync::Arc::new(NoKeyring)
    }
}

/// A system with no keyring drgnx knows.
pub struct NoKeyring;

impl KeyStore for NoKeyring {
    fn key(&self, _create: bool) -> BoxFut<'_, Result<Key, Unavailable>> {
        Box::pin(async {
            Err(Unavailable::Missing(
                "this system has no keyring drgnx can use".into(),
            ))
        })
    }
}

/// The key's name in the keyring.
pub const SERVICE: &str = "drgnx";
pub const ACCOUNT: &str = "debug-runs";

fn key_of(bytes: &[u8]) -> Result<Key, Unavailable> {
    let arr: [u8; 32] = bytes
        .try_into()
        .map_err(|_| Unavailable::Failed("the keyring's debug-runs key is not 32 bytes".into()))?;
    Ok(Zeroizing::new(arr))
}

#[cfg(target_os = "linux")]
pub mod secret {
    //! The Secret Service (GNOME Keyring, KWallet's bridge, KeePassXC) over the session bus, its calls made one by one
    //! (a client library runs the prompts it is handed). Only the default collection, only when it is unlocked: the
    //! hub never calls Unlock and never a Prompt's `Prompt`; a prompt handed back (the collection locked meanwhile) is
    //! dismissed. A plain session: the secret goes over the user's own bus, as the bus itself is the boundary.
    use super::{ACCOUNT, Key, KeyStore, SERVICE, Unavailable, key_of, random_key};
    use crate::debug::BoxFut;
    use std::collections::HashMap;
    use zbus::{ObjectPath, OwnedObjectPath, OwnedVariant, Variant};

    const BUS: &str = "org.freedesktop.secrets";
    const ROOT: &str = "/org/freedesktop/secrets";

    /// The user's Secret Service, on the session bus (`DBUS_SESSION_BUS_ADDRESS`).
    #[derive(Default)]
    pub struct SecretStore;

    fn failed(e: zbus::Error) -> Unavailable {
        Unavailable::Failed(format!("the keyring: {e}"))
    }

    async fn proxy<'a>(
        conn: &zbus::Connection,
        path: impl TryInto<ObjectPath<'a>, Error = zbus::Error>,
        iface: &'a str,
    ) -> Result<zbus::Proxy<'a>, Unavailable> {
        let path = path.try_into().map_err(failed)?;
        // properties read when asked: no signal subscriptions on the user's bus
        zbus::proxy::Builder::<zbus::Proxy<'a>>::new(conn)
            .destination(BUS)
            .path(path)
            .interface(iface)
            .cache_properties(zbus::proxy::CacheProperties::No)
            .build()
            .await
            .map_err(failed)
    }

    /// The key from the Secret Service on CONN; see [`KeyStore::key`].
    pub async fn key_on(conn: &zbus::Connection, create: bool) -> Result<Key, Unavailable> {
        let conn = conn.clone();
        let service = proxy(&conn, ROOT, "org.freedesktop.Secret.Service").await?;
        let alias: OwnedObjectPath = service
            .call("ReadAlias", &("default",))
            .await
            .map_err(|e| Unavailable::Missing(format!("no keyring: {e}")))?;
        // no default collection: making one would prompt
        if alias.as_str() == "/" {
            return Err(Unavailable::Missing(
                "the keyring has no default collection".into(),
            ));
        }
        let collection = proxy(&conn, alias.as_str(), "org.freedesktop.Secret.Collection").await?;
        let locked: bool = collection.get_property("Locked").await.map_err(failed)?;
        if locked {
            return Err(Unavailable::Locked);
        }
        let (_, session): (OwnedVariant, OwnedObjectPath) = service
            .call("OpenSession", &("plain", Variant::from("")))
            .await
            .map_err(failed)?;
        let r = in_session(&conn, &collection, &session, create).await;
        if let Ok(s) = proxy(&conn, session.as_str(), "org.freedesktop.Secret.Session").await {
            let _: Result<(), _> = s.call("Close", &()).await;
        }
        r
    }

    async fn in_session(
        conn: &zbus::Connection,
        collection: &zbus::Proxy<'_>,
        session: &OwnedObjectPath,
        create: bool,
    ) -> Result<Key, Unavailable> {
        let attrs = HashMap::from([("service", SERVICE), ("account", ACCOUNT)]);
        let items: Vec<OwnedObjectPath> = collection
            .call("SearchItems", &(attrs.clone(),))
            .await
            .map_err(failed)?;
        if let Some(item) = items.first() {
            let item = proxy(conn, item.as_str(), "org.freedesktop.Secret.Item").await?;
            if item.get_property::<bool>("Locked").await.map_err(failed)? {
                return Err(Unavailable::Locked);
            }
            let (_, _, value, _): (OwnedObjectPath, Vec<u8>, Vec<u8>, String) =
                item.call("GetSecret", &(session,)).await.map_err(failed)?;
            let value = zeroize::Zeroizing::new(value);
            return key_of(&value);
        }
        if !create {
            return Err(Unavailable::Missing("no key in the keyring yet".into()));
        }
        let k = random_key();
        let props: HashMap<&str, Variant<'_>> = HashMap::from([
            (
                "org.freedesktop.Secret.Item.Label",
                Variant::from("drgnx: recorded debug runs"),
            ),
            (
                "org.freedesktop.Secret.Item.Attributes",
                Variant::from(attrs),
            ),
        ]);
        let secret = (
            session,
            Vec::<u8>::new(),
            zeroize::Zeroizing::new(k.to_vec()).to_vec(),
            "application/octet-stream",
        );
        let (item, prompt): (OwnedObjectPath, OwnedObjectPath) = collection
            .call("CreateItem", &(props, secret, false))
            .await
            .map_err(failed)?;
        if item.as_str() == "/" {
            // the collection locked meanwhile: the prompt goes unshown
            if let Ok(p) = proxy(conn, prompt.as_str(), "org.freedesktop.Secret.Prompt").await {
                let _: Result<(), _> = p.call("Dismiss", &()).await;
            }
            return Err(Unavailable::Locked);
        }
        Ok(k)
    }

    impl KeyStore for SecretStore {
        fn key(&self, create: bool) -> BoxFut<'_, Result<Key, Unavailable>> {
            Box::pin(async move {
                let conn = zbus::Connection::session()
                    .await
                    .map_err(|e| Unavailable::Missing(format!("no keyring: {e}")))?;
                key_on(&conn, create).await
            })
        }
    }
}

#[cfg(target_os = "macos")]
pub mod keychain {
    //! The login Keychain, with user interaction off around each call: a locked keychain, or an item another program
    //! made, is an error, never a dialog.
    use super::{ACCOUNT, Key, KeyStore, SERVICE, Unavailable, key_of, random_key};
    use crate::debug::BoxFut;
    use security_framework::os::macos::keychain::SecKeychain;

    pub struct Keychain;

    // errSecItemNotFound, errSecInteractionNotAllowed, errSecNoDefaultKeychain
    const NOT_FOUND: i32 = -25300;
    const NO_INTERACTION: i32 = -25308;
    const NO_KEYCHAIN: i32 = -25307;

    fn failed(e: security_framework::base::Error) -> Unavailable {
        match e.code() {
            NO_INTERACTION => Unavailable::Locked,
            NO_KEYCHAIN => Unavailable::Missing("there is no login keychain".into()),
            _ => Unavailable::Failed(format!("the keychain: {e}")),
        }
    }

    fn blocking(create: bool) -> Result<Key, Unavailable> {
        let _quiet = SecKeychain::disable_user_interaction().map_err(failed)?;
        match security_framework::passwords::get_generic_password(SERVICE, ACCOUNT) {
            Ok(bytes) => key_of(&zeroize::Zeroizing::new(bytes)),
            Err(e) if e.code() == NOT_FOUND && create => {
                let k = random_key();
                security_framework::passwords::set_generic_password(SERVICE, ACCOUNT, k.as_ref())
                    .map_err(failed)?;
                Ok(k)
            }
            Err(e) if e.code() == NOT_FOUND => {
                Err(Unavailable::Missing("no key in the keychain yet".into()))
            }
            Err(e) => Err(failed(e)),
        }
    }

    impl KeyStore for Keychain {
        fn key(&self, create: bool) -> BoxFut<'_, Result<Key, Unavailable>> {
            Box::pin(async move {
                crate::clock::blocking(move || blocking(create))
                    .await
                    .map_err(|e| Unavailable::Failed(e.to_string()))?
            })
        }
    }
}
