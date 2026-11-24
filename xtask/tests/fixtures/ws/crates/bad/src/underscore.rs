pub fn h() {
    let _ = std::fs::remove_file("x");
    let _kept_for_drop = 1;
}
