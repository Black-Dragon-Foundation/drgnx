//! A collection from the hub's wire: `sja`'s windowed list (`total`/`from`, ids) applied as splices.

use std::sync::Arc;

use crate::list::List;
use crate::model::{Model, Obj};
use crate::ops::emit;
use crate::propagate::ALL;
use crate::rd::Wr;
use crate::splice::Splice;

/// Bind the hub's id ID to the object O, so lists that name ID reach it.
pub fn bind<T: Model>(w: &mut Wr, id: Arc<str>, o: Obj<T>) {
    w.e.core
        .wire_ids
        .borrow_mut()
        .insert(id, o.model_ref().cell);
}

/// Apply the hub's window MSG to L: the items that went are removed, the new ones inserted, the moved ones moved, and the
/// window's `total` and `from` taken. An id never bound is an error and nothing is applied (the reader resyncs).
pub fn apply<T: Model>(w: &mut Wr, l: List<T>, msg: &sja::model::List) -> villa::Result<()> {
    let core = &w.e.core;
    let new = {
        let ids = core.wire_ids.borrow();
        let mut new = Vec::with_capacity(msg.ids.len());
        for id in &msg.ids {
            match ids.get(id) {
                Some(c) => new.push(*c),
                None => {
                    return Err(villa::Error::new(
                        villa::Kind::NotFound,
                        format!("The list names `{id}`, which this view does not hold."),
                    ));
                }
            }
        }
        new
    };
    let r = l.model_ref();
    let changed = {
        let mut lists = core.lists.borrow_mut();
        let data = &mut lists[r.aux as usize];
        let total = msg.total.map(|t| t as u64);
        let moved = data.from != msg.from || data.total != total;
        data.from = msg.from;
        data.total = total;
        let spliced = emit(data, new);
        if moved && !spliced {
            // the window moved over the same items: readers start over at the new place
            let epoch = data.epoch;
            data.log_splice(Splice::Reset { total: 0, epoch });
        }
        moved || spliced
    };
    if changed {
        let mut g = core.g.borrow_mut();
        core.changed(&mut g, r.cell.idx, ALL);
    }
    Ok(())
}
