use std::fs::{File, OpenOptions};

pub fn read(p: &std::path::Path) {
    let _a = OpenOptions::new().read(true).open(p);
    let _b = File::options().write(true).open(p);
    let _fine = File::open(p);
}
