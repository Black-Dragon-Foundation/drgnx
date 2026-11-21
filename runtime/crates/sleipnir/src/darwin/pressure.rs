//! The kernel's memory-pressure event on a Mac (design §5.3): a `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source on a
//! global queue keeps the last level in an atomic, which `serve`'s ladder reads ([`level`]); no polling. The level is
//! read once at [`start`] (`kern.memorystatus_vm_pressure_level`), since the event fires only on a change.

use forseti::safety::Level;
use std::ffi::c_void;
use std::sync::Once;
use std::sync::atomic::{AtomicUsize, Ordering};

/// `DISPATCH_MEMORYPRESSURE_*` (and the sysctl's values).
const NORMAL: usize = 1;
const WARN: usize = 2;
const CRITICAL: usize = 4;

static LAST: AtomicUsize = AtomicUsize::new(NORMAL);
static STARTED: Once = Once::new();

#[allow(non_upper_case_globals)]
unsafe extern "C" {
    static _dispatch_source_type_memorypressure: c_void;
    fn dispatch_get_global_queue(identifier: isize, flags: usize) -> *mut c_void;
    fn dispatch_source_create(
        kind: *const c_void,
        handle: usize,
        mask: usize,
        queue: *mut c_void,
    ) -> *mut c_void;
    fn dispatch_set_context(object: *mut c_void, context: *mut c_void);
    fn dispatch_source_set_event_handler_f(
        source: *mut c_void,
        handler: extern "C" fn(*mut c_void),
    );
    fn dispatch_source_get_data(source: *mut c_void) -> usize;
    fn dispatch_resume(object: *mut c_void);
}

extern "C" fn on_event(source: *mut c_void) {
    // SAFETY: the context is the source itself (set in `start`), alive for the process
    let data = unsafe { dispatch_source_get_data(source) };
    LAST.store(data, Ordering::Relaxed);
}

/// Starts listening, once per process.
pub fn start() {
    STARTED.call_once(|| {
        let mut v: u32 = 0;
        let mut len = std::mem::size_of::<u32>();
        // SAFETY: a NUL-terminated name and a u32-sized buffer
        let rc = unsafe {
            libc::sysctlbyname(
                c"kern.memorystatus_vm_pressure_level".as_ptr(),
                (&mut v as *mut u32).cast(),
                &mut len,
                std::ptr::null_mut(),
                0,
            )
        };
        if rc == 0 {
            LAST.store(v as usize, Ordering::Relaxed);
        }
        // SAFETY: libdispatch's documented C calls; the source lives as long as the process (never released)
        unsafe {
            let source = dispatch_source_create(
                &raw const _dispatch_source_type_memorypressure,
                0,
                NORMAL | WARN | CRITICAL,
                dispatch_get_global_queue(0, 0),
            );
            if source.is_null() {
                return;
            }
            dispatch_set_context(source, source);
            dispatch_source_set_event_handler_f(source, on_event);
            dispatch_resume(source);
        }
    });
}

/// The ladder's level from the last event: warn stops admissions, critical evicts.
pub fn level() -> Level {
    of(LAST.load(Ordering::Relaxed))
}

fn of(v: usize) -> Level {
    if v & CRITICAL != 0 {
        Level::Danger
    } else if v & WARN != 0 {
        Level::Tight
    } else {
        Level::Normal
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [D] The kernel's levels map onto the ladder, and a live start reads one.
    #[test]
    fn the_kernels_levels_map_onto_the_ladder() {
        assert_eq!(of(NORMAL), Level::Normal);
        assert_eq!(of(WARN), Level::Tight);
        assert_eq!(of(CRITICAL), Level::Danger);
        start();
        start();
        let _ = level();
    }
}
