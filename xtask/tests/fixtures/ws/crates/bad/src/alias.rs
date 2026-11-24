use std::process::Command as C;

type R<T> = Result<T, String>;

pub fn run() -> R<()> {
    drop(C::new("x"));
    Ok(())
}

mod glob {
    use std::process::*;

    pub fn g() {
        drop(Command::new("y"));
    }
}

pub fn in_macro() -> Vec<std::process::Command> {
    vec![std::process::Command::new("z")]
}
