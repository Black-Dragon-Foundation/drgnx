//! A clock a test moves by hand.

use crate::Provider;
use std::collections::BTreeMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::task::{Context, Poll, Waker};
use std::time::Duration;

/// One test at a time may hold the process's clock: the guard of [`Manual::install`].
static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

#[derive(Default)]
struct State {
    elapsed: Duration,
    next: u64,
    /// (due, seq) of each waiting sleeper
    sleepers: BTreeMap<(Duration, u64), Waker>,
    /// the ones an advance has fired
    fired: std::collections::BTreeSet<u64>,
}

/// A virtual clock: it stands still until [`Manual::advance`] moves it, and a sleeper is ready once it has.
/// [`Manual::install`] makes it the clock of every timer through this crate until the guard drops.
#[derive(Clone, Default)]
pub struct Manual(Arc<Mutex<State>>);

/// The clock installed and the process's turn at it; dropping it puts tokio's clock back.
pub struct Installed {
    pub clock: Manual,
    _turn: MutexGuard<'static, ()>,
}

impl Drop for Installed {
    fn drop(&mut self) {
        crate::uninstall();
    }
}

impl Manual {
    /// A new clock installed as the process's, waiting for its turn if another test holds it.
    pub fn install() -> Installed {
        let turn = ONE_AT_A_TIME.lock().unwrap_or_else(PoisonError::into_inner);
        let clock = Manual::default();
        crate::install(Arc::new(clock.clone()));
        Installed {
            clock,
            _turn: turn,
        }
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Virtual time since the clock was made.
    pub fn elapsed(&self) -> Duration {
        self.state().elapsed
    }

    /// How many timers wait on this clock now: a test waits for the one it expects (`skuld::wait_until`) before it
    /// advances, so no sleep is a guess at when a task got there.
    pub fn sleepers(&self) -> usize {
        self.state().sleepers.len()
    }

    /// Move the clock by D: every sleeper due by then is woken, in order of its deadline.
    pub fn advance(&self, d: Duration) {
        let woken: Vec<Waker> = {
            let mut st = self.state();
            st.elapsed += d;
            let now = st.elapsed;
            let due: Vec<(Duration, u64)> = st.sleepers.range(..=(now, u64::MAX)).map(|(k, _)| *k).collect();
            let mut out = Vec::new();
            for k in due {
                if let Some(w) = st.sleepers.remove(&k) {
                    st.fired.insert(k.1);
                    out.push(w);
                }
            }
            out
        };
        for w in woken {
            w.wake();
        }
    }
}

struct Sleep {
    clock: Manual,
    due: Duration,
    seq: Option<u64>,
}

impl Future for Sleep {
    type Output = ();

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        let this = &mut *self;
        let mut st = this.clock.state();
        match this.seq {
            Some(seq) => {
                if st.fired.remove(&seq) {
                    this.seq = None;
                    return Poll::Ready(());
                }
                st.sleepers.insert((this.due, seq), cx.waker().clone());
                Poll::Pending
            }
            None => {
                if this.due <= st.elapsed {
                    return Poll::Ready(());
                }
                let seq = st.next;
                st.next += 1;
                st.sleepers.insert((this.due, seq), cx.waker().clone());
                this.seq = Some(seq);
                Poll::Pending
            }
        }
    }
}

impl Drop for Sleep {
    fn drop(&mut self) {
        if let Some(seq) = self.seq {
            let mut st = self.clock.state();
            st.fired.remove(&seq);
            st.sleepers.remove(&(self.due, seq));
        }
    }
}

impl Provider for Manual {
    fn sleep(&self, d: Duration) -> Pin<Box<dyn Future<Output = ()> + Send>> {
        let due = self.elapsed() + d;
        Box::pin(Sleep {
            clock: self.clone(),
            due,
            seq: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// A sleeper is ready only once the clock was moved past its deadline, and not before.
    #[tokio::test]
    async fn a_sleep_ends_only_when_the_clock_moves_past_it() {
        let c = Manual::install();
        let done = Arc::new(AtomicBool::new(false));
        let t = tokio::spawn({
            let done = done.clone();
            async move {
                crate::sleep(Duration::from_secs(5)).await;
                done.store(true, Ordering::SeqCst);
            }
        });
        skuld::wait_until_async("the sleeper waits", 10, || async { (c.clock.sleepers() == 1).then_some(()) }).await;
        c.clock.advance(Duration::from_millis(4999));
        tokio::task::yield_now().await;
        assert!(!done.load(Ordering::SeqCst), "ended 1 ms early");
        c.clock.advance(Duration::from_millis(1));
        t.await.unwrap();
        assert!(done.load(Ordering::SeqCst));
        assert_eq!(c.clock.elapsed(), Duration::from_secs(5));
    }

    /// `timeout` gives the future its answer when it comes first, and `Elapsed` when the clock reaches the deadline first.
    #[tokio::test]
    async fn a_timeout_follows_the_installed_clock() {
        let c = Manual::install();
        let (tx, rx) = tokio::sync::oneshot::channel::<u8>();
        let waiting = tokio::spawn(crate::timeout(Duration::from_secs(10), rx));
        skuld::wait_until_async("the deadline is set", 10, || async { (c.clock.sleepers() == 1).then_some(()) }).await;
        tx.send(7).unwrap();
        assert_eq!(waiting.await.unwrap().unwrap().unwrap(), 7);
        assert_eq!(c.clock.sleepers(), 0, "the finished timeout left its timer");

        let never = tokio::spawn(crate::timeout(Duration::from_secs(10), std::future::pending::<()>()));
        skuld::wait_until_async("the deadline is set", 10, || async { (c.clock.sleepers() == 1).then_some(()) }).await;
        c.clock.advance(Duration::from_secs(10));
        assert_eq!(never.await.unwrap(), Err(crate::Elapsed));
    }

    /// Dropped, the guard puts tokio's clock back: nothing is installed, and a sleep is tokio's again.
    #[tokio::test]
    async fn dropping_the_guard_restores_tokios_clock() {
        {
            let _c = Manual::install();
            assert!(crate::current().is_some());
        }
        assert!(crate::current().is_none());
        crate::sleep(Duration::ZERO).await;
    }
}
