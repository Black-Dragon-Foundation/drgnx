#[derive(Debug, Clone)]
pub struct ApiToken(String);

#[derive(Debug)]
pub struct WrappedToken {
    t: Secret<String>,
}

pub struct PlainKey(String);

// numbers only: a cache key, no secret; not flagged
#[derive(Debug)]
pub struct CacheKey {
    image: u32,
    at: (u32, u32),
}
