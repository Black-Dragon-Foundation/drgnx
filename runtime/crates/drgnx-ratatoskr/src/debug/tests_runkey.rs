//! The Secret Service client of the runs' key against a fake service on a socket pair: it never asks for an unlock, a
//! new collection or a prompt (the user's Q18 ruling), and the key it makes reads back.
use super::runkey::{Unavailable, secret::key_on};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use zbus::{OwnedObjectPath, OwnedVariant};

const COLLECTION: &str = "/org/freedesktop/secrets/collection/login";
const ITEM: &str = "/org/freedesktop/secrets/collection/login/1";
const SESSION: &str = "/org/freedesktop/secrets/session/1";
const PROMPT: &str = "/org/freedesktop/secrets/prompt/1";

#[derive(Default)]
struct State {
    /// Every method called, by name.
    calls: Vec<String>,
    no_default: bool,
    locked: bool,
    secret: Option<Vec<u8>>,
    /// CreateItem answers with a prompt (the collection locked meanwhile).
    create_prompts: bool,
}

type Shared = Arc<Mutex<State>>;

fn path(p: &str) -> OwnedObjectPath {
    OwnedObjectPath::try_from(p).unwrap()
}

fn note(s: &Shared, call: &str) {
    s.lock().unwrap().calls.push(call.to_owned());
}

struct Service(Shared);

#[zbus::interface(name = "org.freedesktop.Secret.Service")]
impl Service {
    fn read_alias(&self, _name: &str) -> OwnedObjectPath {
        note(&self.0, "ReadAlias");
        path(if self.0.lock().unwrap().no_default {
            "/"
        } else {
            COLLECTION
        })
    }
    fn open_session(
        &self,
        _algorithm: &str,
        _input: OwnedVariant,
    ) -> (OwnedVariant, OwnedObjectPath) {
        note(&self.0, "OpenSession");
        (OwnedVariant::from(0u32), path(SESSION))
    }
    fn unlock(&self, _objects: Vec<OwnedObjectPath>) -> (Vec<OwnedObjectPath>, OwnedObjectPath) {
        note(&self.0, "Unlock");
        (vec![], path(PROMPT))
    }
    fn create_collection(
        &self,
        _props: HashMap<String, OwnedVariant>,
        _alias: &str,
    ) -> (OwnedObjectPath, OwnedObjectPath) {
        note(&self.0, "CreateCollection");
        (path("/"), path(PROMPT))
    }
}

struct Collection(Shared);

#[zbus::interface(name = "org.freedesktop.Secret.Collection")]
impl Collection {
    #[zbus(property)]
    fn locked(&self) -> bool {
        self.0.lock().unwrap().locked
    }
    fn search_items(&self, _attrs: HashMap<String, String>) -> Vec<OwnedObjectPath> {
        note(&self.0, "SearchItems");
        if self.0.lock().unwrap().secret.is_some() {
            vec![path(ITEM)]
        } else {
            vec![]
        }
    }
    fn create_item(
        &self,
        _props: HashMap<String, OwnedVariant>,
        secret: (OwnedObjectPath, Vec<u8>, Vec<u8>, String),
        _replace: bool,
    ) -> (OwnedObjectPath, OwnedObjectPath) {
        note(&self.0, "CreateItem");
        let mut s = self.0.lock().unwrap();
        if s.create_prompts {
            return (path("/"), path(PROMPT));
        }
        s.secret = Some(secret.2);
        (path(ITEM), path("/"))
    }
}

struct Item(Shared);

#[zbus::interface(name = "org.freedesktop.Secret.Item")]
impl Item {
    #[zbus(property)]
    fn locked(&self) -> bool {
        false
    }
    fn get_secret(&self, _session: OwnedObjectPath) -> (OwnedObjectPath, Vec<u8>, Vec<u8>, String) {
        note(&self.0, "GetSecret");
        let v = self.0.lock().unwrap().secret.clone().unwrap_or_default();
        (path(SESSION), vec![], v, "application/octet-stream".into())
    }
}

struct Session(Shared);

#[zbus::interface(name = "org.freedesktop.Secret.Session")]
impl Session {
    fn close(&self) {
        note(&self.0, "Close");
    }
}

struct Prompt(Shared);

#[zbus::interface(name = "org.freedesktop.Secret.Prompt")]
impl Prompt {
    fn prompt(&self, _window: &str) {
        note(&self.0, "Prompt");
    }
    fn dismiss(&self) {
        note(&self.0, "Dismiss");
    }
}

/// A client connection to a fake Secret Service in STATE.
async fn fake(state: &Shared) -> zbus::Connection {
    let (a, b) = std::os::unix::net::UnixStream::pair().unwrap();
    let server = zbus::connection::Builder::unix_stream(a)
        .server(zbus::Guid::generate())
        .p2p()
        .serve_at("/org/freedesktop/secrets", Service(state.clone()))
        .serve_at(COLLECTION, Collection(state.clone()))
        .serve_at(ITEM, Item(state.clone()))
        .serve_at(SESSION, Session(state.clone()))
        .serve_at(PROMPT, Prompt(state.clone()))
        .build();
    let client = zbus::connection::Builder::unix_stream(b).p2p().build();
    let (server, client) = tokio::join!(server, client);
    // the server runs as long as the client's test does
    std::mem::forget(server.unwrap());
    client.unwrap()
}

fn shared(f: impl FnOnce(&mut State)) -> Shared {
    let mut s = State::default();
    f(&mut s);
    Arc::new(Mutex::new(s))
}

fn asked(s: &Shared) -> Vec<String> {
    s.lock()
        .unwrap()
        .calls
        .iter()
        .filter(|c| matches!(c.as_str(), "Unlock" | "CreateCollection" | "Prompt"))
        .cloned()
        .collect()
}

#[tokio::test]
async fn no_default_collection_is_missing_and_nothing_is_created_or_prompted() {
    let s = shared(|s| s.no_default = true);
    let conn = fake(&s).await;
    let r = key_on(&conn, true).await;
    assert!(
        matches!(&r, Err(Unavailable::Missing(w)) if w.contains("no default collection")),
        "{:?}",
        r.as_ref().err()
    );
    assert_eq!(asked(&s), Vec::<String>::new());
    assert!(!s.lock().unwrap().calls.contains(&"CreateItem".into()));
}

#[tokio::test]
async fn a_locked_collection_is_never_unlocked_or_prompted() {
    let s = shared(|s| s.locked = true);
    let conn = fake(&s).await;
    assert_eq!(key_on(&conn, true).await.err(), Some(Unavailable::Locked));
    assert_eq!(asked(&s), Vec::<String>::new());
    assert!(!s.lock().unwrap().calls.contains(&"CreateItem".into()));
}

#[tokio::test]
async fn the_key_is_made_in_an_unlocked_collection_and_reads_back() {
    let s = shared(|_| {});
    let conn = fake(&s).await;
    // reading only: none yet, none made
    assert!(matches!(
        key_on(&conn, false).await,
        Err(Unavailable::Missing(_))
    ));
    assert!(!s.lock().unwrap().calls.contains(&"CreateItem".into()));
    let made = key_on(&conn, true).await.unwrap();
    let read = key_on(&conn, false).await.unwrap();
    assert_eq!(*made, *read);
    assert_eq!(asked(&s), Vec::<String>::new());
    assert!(s.lock().unwrap().calls.contains(&"Close".into()));
}

#[tokio::test]
async fn a_prompt_handed_back_is_dismissed_never_shown() {
    let s = shared(|s| s.create_prompts = true);
    let conn = fake(&s).await;
    assert_eq!(key_on(&conn, true).await.err(), Some(Unavailable::Locked));
    assert_eq!(asked(&s), Vec::<String>::new());
    assert!(s.lock().unwrap().calls.contains(&"Dismiss".into()));
}
