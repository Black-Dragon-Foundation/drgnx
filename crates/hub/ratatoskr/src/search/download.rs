//! The model download. It fetches exactly a table row's files and nothing else, and only with a consent that names the
//! model and its size. A file lands under its real name only after its sum passes, so `cache::state` never sees a bad one.
//!
//! A failed run is left to be resumed: its `.part` files stay, and the next run asks `resolve/` again, because the target
//! is a signed URL that expires. Nothing here retries: being offline is reported once, and the hub tries again at its next
//! start or when asked.

use bifrost::Uri;
use bifrost::upstream::{Fetched, Upstream, UpstreamError, UpstreamOpts};
use hrafn_embed::cache::{model_dir, part_path, sha256_file};
use hrafn_embed::{ModelFile, ModelSpec, download_bytes};
use std::future::Future;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::fs;
use tokio::io::AsyncWriteExt;

const MAX_REDIRECTS: usize = 3;

/// How long a silent connection counts as alive.
const STALL: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Consent {
    pub model: String,
    pub bytes: u64,
    pub at: f64,
}

#[derive(Debug, PartialEq, Eq)]
pub enum DownloadError {
    /// No consent that names this model and its size.
    NoConsent,
    /// No network, or it broke off.
    Offline,
    /// The status the host answered with, or the redirect that was refused.
    Http(u16),
    /// This file does not match its sum, or the host sent more than the table says.
    Corrupt(String),
    Disk,
}

fn offline(e: UpstreamError) -> DownloadError {
    tracing::info!("model download: {e}");
    DownloadError::Offline
}

fn disk(e: io::Error) -> DownloadError {
    tracing::warn!("model download: {e}");
    DownloadError::Disk
}

/// Fetches what `spec` still lacks into its directory under `cache_root`. `progress` gets bytes held and bytes in all.
pub async fn download(
    spec: &ModelSpec,
    cache_root: &Path,
    base: &Uri,
    consent: &Consent,
    progress: &(dyn Fn(u64, u64) + Sync),
) -> Result<(), DownloadError> {
    let total = download_bytes(spec);
    if consent.model != spec.id || consent.bytes != total {
        return Err(DownloadError::NoConsent);
    }
    let client = Upstream::new(UpstreamOpts::default()).map_err(offline)?;
    let dir = model_dir(cache_root, spec);
    let mut done = 0;
    for file in spec.files {
        if !sum_holds(dir.join(file.name), file).await? {
            let url = file_url(base, spec, file.name)?;
            fetch(&client, url, &dir, file, &|have| {
                progress(done + have, total)
            })
            .await?;
        }
        done += file.bytes;
        progress(done, total);
    }
    Ok(())
}

fn file_url(base: &Uri, spec: &ModelSpec, name: &str) -> Result<Uri, DownloadError> {
    let base = base.to_string();
    let (repo, revision) = (spec.repo, spec.revision);
    let root = base.trim_end_matches('/');
    format!("{root}/{repo}/resolve/{revision}/{name}")
        .parse()
        .map_err(|_| DownloadError::Http(400))
}

async fn sum_of(path: PathBuf) -> Result<String, DownloadError> {
    crate::clock::blocking(move || sha256_file(&path))
        .await
        .map_err(|e| disk(io::Error::other(e)))?
        .map_err(disk)
}

async fn sum_holds(path: PathBuf, file: &ModelFile) -> Result<bool, DownloadError> {
    match fs::metadata(&path).await {
        Ok(m) if m.len() == file.bytes => Ok(sum_of(path).await? == file.sha256),
        _ => Ok(false),
    }
}

/// `file` into its `.part`, from where an earlier run stopped, and on to its real name once the sum holds.
async fn fetch(
    client: &Upstream,
    url: Uri,
    dir: &Path,
    file: &ModelFile,
    progress: &(dyn Fn(u64) + Sync),
) -> Result<(), DownloadError> {
    let (dest, part) = (dir.join(file.name), part_path(dir, file));
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent).await.map_err(disk)?;
    }
    let mut have = fs::metadata(&part).await.map_or(0, |m| m.len());
    if have > file.bytes {
        fs::remove_file(&part).await.map_err(disk)?;
        have = 0;
    }
    if have < file.bytes {
        let mut response = follow(client, url, have).await?;
        match response.status() {
            206 if have > 0 && range_start(&response) == Some(have) => {}
            200 => have = 0, // no Range honoured: the whole file
            416 => {
                fs::remove_file(&part).await.map_err(disk)?;
                return Err(DownloadError::Http(416));
            }
            status => return Err(DownloadError::Http(status)),
        }
        have = receive(&mut response, &part, have, file, progress).await?;
        if have < file.bytes {
            return Err(DownloadError::Offline); // the connection closed early, in good order
        }
    }
    if sum_of(part.clone()).await? != file.sha256 {
        fs::remove_file(&part).await.map_err(disk)?;
        return Err(DownloadError::Corrupt(file.name.to_string()));
    }
    fs::rename(&part, &dest).await.map_err(disk)
}

/// The start of a 206's `Content-Range: bytes START-END/SIZE`.
fn range_start(response: &Fetched) -> Option<u64> {
    let value = response.header("content-range")?;
    value
        .strip_prefix("bytes ")?
        .split('-')
        .next()?
        .parse()
        .ok()
}

/// The body into `part`, after its first `have` bytes. Gives how many bytes the file holds, written and flushed, also when
/// the connection broke: that is the next run's start.
async fn receive(
    response: &mut Fetched,
    part: &Path,
    mut have: u64,
    file: &ModelFile,
    progress: &(dyn Fn(u64) + Sync),
) -> Result<u64, DownloadError> {
    let mut out = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .append(have > 0)
        .truncate(have == 0)
        .open(part)
        .await
        .map_err(disk)?;
    let ended = loop {
        match stalls(response.chunk()).await {
            Err(e) => break Err(e),
            Ok(None) => break Ok(()),
            Ok(Some(Err(e))) => break Err(offline(e)),
            Ok(Some(Ok(piece))) => {
                have += piece.len() as u64;
                if have > file.bytes {
                    drop(out);
                    fs::remove_file(part).await.map_err(disk)?;
                    return Err(DownloadError::Corrupt(file.name.to_string()));
                }
                out.write_all(&piece).await.map_err(disk)?;
                progress(have);
            }
        }
    };
    out.flush().await.map_err(disk)?;
    out.sync_data().await.map_err(disk)?;
    ended.map(|()| have)
}

/// WORK, a wait on the network (a wait outside the hub's clock), or `Offline` once it has been silent for `STALL` on
/// the hub's clock.
async fn stalls<T>(work: impl Future<Output = T>) -> Result<T, DownloadError> {
    crate::clock::timeout(STALL, crate::clock::real(work))
        .await
        .map_err(|_| DownloadError::Offline)
}

/// A GET that follows redirects by hand: at most 3, each checked by [`redirect_target`].
async fn follow(client: &Upstream, url: Uri, have: u64) -> Result<Fetched, DownloadError> {
    let range = (have > 0).then(|| ("range", format!("bytes={have}-")));
    let headers: Vec<_> = range.into_iter().collect();
    let (mut at, mut status) = (url, 0);
    for _ in 0..=MAX_REDIRECTS {
        let response = stalls(client.get(&at, &headers)).await?.map_err(offline)?;
        status = response.status();
        if !matches!(status, 301 | 302 | 303 | 307 | 308) {
            return Ok(response);
        }
        at = response
            .header("location")
            .and_then(|l| redirect_target(&at, l))
            .ok_or(DownloadError::Http(status))?;
    }
    Err(DownloadError::Http(status))
}

fn loopback(uri: &Uri) -> bool {
    matches!(uri.host(), Some("127.0.0.1" | "localhost" | "[::1]"))
}

/// Where a redirect from `from` goes, or none when it may not be followed: only to https, and with no credentials in the
/// URL. A local mirror (and the test host) stays on http between loopback addresses.
fn redirect_target(from: &Uri, location: &str) -> Option<Uri> {
    let target: Uri = if location.starts_with('/') {
        let (scheme, host) = (from.scheme_str()?, from.authority()?);
        format!("{scheme}://{host}{location}").parse().ok()?
    } else {
        location.parse().ok()?
    };
    let allowed = match target.scheme_str()? {
        "https" => true,
        "http" => loopback(&target) && loopback(from),
        _ => false,
    };
    (allowed && !target.authority()?.as_str().contains('@')).then_some(target)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn uri(text: &str) -> Uri {
        text.parse().unwrap()
    }

    #[test]
    fn a_redirect_goes_to_https_with_no_credentials() {
        let host = uri("https://huggingface.co/a/resolve/r/f");
        let target = |l: &str| redirect_target(&host, l).map(|u| u.to_string());
        let cdn = "https://cdn.example/f?sig=1";
        assert_eq!(target(cdn).as_deref(), Some(cdn));
        assert_eq!(
            target("/api/resolve-cache/f").as_deref(),
            Some("https://huggingface.co/api/resolve-cache/f")
        );
        assert_eq!(target("http://cdn.example/f"), None);
        assert_eq!(target("ftp://cdn.example/f"), None);
        assert_eq!(target("https://me:secret@cdn.example/f"), None);
        assert_eq!(target("elsewhere"), None);
        assert_eq!(target("http://127.0.0.1:1/f"), None, "https never falls");
    }

    #[test]
    fn loopback_stays_on_plain_http() {
        let mock = uri("http://127.0.0.1:1/a");
        assert!(redirect_target(&mock, "http://127.0.0.1:2/f").is_some());
        assert!(redirect_target(&mock, "http://cdn.example/f").is_none());
    }
}
