use std::collections::HashMap;

struct Counter {
    seen: HashMap<String, usize>,
}

impl Counter {
    fn add(&mut self, word: &str) {
        *self.seen.entry(word.to_string()).or_insert(0) += 1;
    }
}

fn main() {
    let mut c = Counter { seen: HashMap::new() };
    c.add("a");
    let v: Vec<u32> = Vec::new();
    v.
    let unused: i32 = "not an int";
}
