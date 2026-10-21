//! Opens that refuse every link (Task 1). Linux and Android: `openat2` with `RESOLVE_NO_SYMLINKS`
//! (`any(target_os = "linux", target_os = "android")`: a kernel fact); macOS: `O_NOFOLLOW_ANY`.
