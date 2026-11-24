pub fn f() -> Result<(), String> {
    Ok(())
}

fn private() -> Result<(), String> {
    Ok(())
}

pub fn fine() -> Result<(), std::io::Error> {
    private().map_err(std::io::Error::other)
}
