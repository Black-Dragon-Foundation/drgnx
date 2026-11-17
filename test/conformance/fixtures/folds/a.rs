use std::collections::{
    HashMap,
    HashSet,
};

/* A block comment
   over two lines. */
struct Point {
    x: i32,
    y: i32,
}

impl Point {
    fn norm(&self) -> i32 {
        let v = [
            self.x,
            self.y,
        ];
        v.iter().sum()
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn adds() {
        assert_eq!(1 + 1, 2);
    }
}
