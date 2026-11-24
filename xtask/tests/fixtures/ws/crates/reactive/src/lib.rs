use std::cell::RefCell;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

pub fn observers(e: &mut Engine, s: SlabId, button: &mut Button) {
    let seen = Rc::new(RefCell::new(0u32));
    let _a = e.formula(s, Stage::Formula, move |r| *seen.borrow_mut() + 1);
    let log = Arc::new(Mutex::new(Vec::new()));
    let copy = log.clone();
    button.on_click(move |w| copy.lock().push(1));
    let (tx, _rx) = std::sync::mpsc::channel::<u32>();
    let _b = e.formula(s, Stage::Formula, move |r| tx.send(1).is_ok());
    let typed: Rc<RefCell<u32>> = make();
    let _c = e.formula(s, Stage::Formula, move |r| *typed.borrow());
    let fine = 3u32;
    let _d = e.formula(s, Stage::Formula, move |r| fine + 1);
    let n = [1u32, 2].iter().filter(|x| **x > fine).count();
}

pub struct Panel {
    pub inbox: State<std::sync::mpsc::Receiver<u32>>,
    pub fine: State<u32>,
}

pub fn use_effect(f: impl Fn(), deps: &[u32]) {}

pub fn create_signal<T: Clone>(v: T) -> (T, T) {
    (v.clone(), v)
}

pub fn memo_cell<F: Fn() -> u32>(f: F) -> u32 {
    f()
}

pub fn signal(pid: u32) -> bool {
    pid > 0
}

pub fn use_store(path: &str) -> bool {
    path.is_empty()
}

fn use_private(f: impl Fn()) {
    f()
}
