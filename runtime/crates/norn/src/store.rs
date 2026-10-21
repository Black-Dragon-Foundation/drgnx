//! The writer's thread and its one read-write connection (Task 4).  [`CoordDb`] is declared at Task 0 so that
//! `tools::Coord` has its type; Task 4 gives it its fields and methods.

/// The coordination store: cheap to clone.
#[derive(Clone)]
pub struct CoordDb {}
