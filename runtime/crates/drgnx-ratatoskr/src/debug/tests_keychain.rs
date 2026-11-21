//! The runs' key in the macOS Keychain, on CI's macOS runners only (runtime.yml makes a throwaway keychain the only
//! one searched, unlocked, then locked): the key is made and reads back, and a locked keychain answers "locked"
//! at once, never a dialog (user interaction is off; a dialog would hang the run past its time-out).
use super::runkey::{ACCOUNT, KeyStore, SERVICE, Unavailable, keychain::Keychain};
use std::time::Duration;

async fn timed(create: bool) -> Result<super::runkey::Key, Unavailable> {
    crate::clock::timeout(Duration::from_secs(20), Keychain.key(create))
        .await
        .expect("the keychain answered within 20 s (no dialog)")
}

#[tokio::test]
#[ignore = "macOS CI: a throwaway keychain, unlocked (runtime.yml)"]
async fn the_key_is_made_in_an_unlocked_keychain_and_reads_back() {
    let _ = security_framework::passwords::delete_generic_password(SERVICE, ACCOUNT);
    assert!(matches!(timed(false).await, Err(Unavailable::Missing(_))));
    let made = timed(true).await.unwrap();
    let read = timed(false).await.unwrap();
    assert_eq!(*made, *read);
}

#[tokio::test]
#[ignore = "macOS CI: the same keychain, locked (runtime.yml)"]
async fn a_locked_keychain_answers_locked_without_a_dialog() {
    assert_eq!(timed(true).await.err(), Some(Unavailable::Locked));
    assert_eq!(timed(false).await.err(), Some(Unavailable::Locked));
}
