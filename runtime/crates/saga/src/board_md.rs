//! BUILD-BOARD.md: status tables between prose.  Parsed into text and table blocks, rendered back byte-exact.
//! Tables keep raw rows (`table::Table { header, rows }`), so a board refreshed from the graph can replace one
//! table's rows and leave the prose untouched.

use crate::table::{self, Block, Table};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BoardDoc {
    pub blocks: Vec<Block>,
}

impl BoardDoc {
    /// The tables in document order.
    pub fn tables(&self) -> Vec<&Table> {
        self.blocks
            .iter()
            .filter_map(|b| match b {
                Block::Table(t) => Some(t),
                _ => None,
            })
            .collect()
    }

    /// The first table whose first header cell is `first` (case-insensitive), mutable.
    pub fn table_mut(&mut self, first: &str) -> Option<&mut Table> {
        self.blocks.iter_mut().find_map(|b| match b {
            Block::Table(t)
                if t.header
                    .cells
                    .first()
                    .is_some_and(|c| c.eq_ignore_ascii_case(first)) =>
            {
                Some(t)
            }
            _ => None,
        })
    }
}

pub fn parse(text: &str) -> BoardDoc {
    BoardDoc {
        blocks: table::blocks(text),
    }
}

pub fn render(doc: &BoardDoc) -> String {
    table::render_blocks(&doc.blocks)
}
