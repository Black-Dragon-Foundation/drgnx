#[derive(Debug, Clone)]
pub struct ApiToken(String);

#[derive(Debug)]
pub struct WrappedToken {
    t: Secret<String>,
}

pub struct PlainKey(String);
