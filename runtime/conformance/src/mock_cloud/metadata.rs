//! Instance metadata, per instance under `/__metadata/<id or name>/…`: AWS IMDSv2 (tokens, hop limit, the spot
//! `instance-action`) and GCE's metadata server (`preempted`, `maintenance-event`).
//!
//! A request carrying `X-Mock-Hops: N` has crossed N-1 routers; IMDSv2 drops a token request past the instance's hop
//! limit (the connection closes with no answer).

use super::instances::{Provider, St, iso};
use super::{Out, Req, State, unknown};
use serde_json::json;

pub(crate) fn handle(st: &mut State, req: &Req, rest: &str) -> Out {
    let Some((key, path)) = rest.split_once('/') else {
        return unknown(st, req, "metadata needs an instance");
    };
    match answer(st, req, key, &format!("/{path}")) {
        Ok(out) => out,
        Err(what) => unknown(st, req, what),
    }
}

fn answer(st: &State, req: &Req, key: &str, path: &str) -> Result<Out, &'static str> {
    let Some(i) = st
        .instances
        .iter()
        .find(|i| i.key() == key && i.state != St::Gone)
    else {
        return Ok(Out::json(
            404,
            json!({"mock": "no such instance", "id": key}),
        ));
    };
    let hops: u32 = req
        .header("x-mock-hops")
        .and_then(|h| h.parse().ok())
        .unwrap_or(1);
    match (i.provider, req.method.as_str(), path) {
        (Provider::Aws, "PUT", "/latest/api/token") => {
            if hops > i.hop_limit {
                return Ok(Out::Drop);
            }
            if req.header("x-aws-ec2-metadata-token-ttl-seconds").is_none() {
                return Ok(Out::text(
                    400,
                    "missing X-aws-ec2-metadata-token-ttl-seconds",
                ));
            }
            Ok(Out::text(200, &format!("imds-{}", i.id)))
        }
        (Provider::Aws, "GET", p) if p.starts_with("/latest/meta-data/") => {
            let ok = req.header("x-aws-ec2-metadata-token") == Some(&format!("imds-{}", i.id));
            if !ok {
                return Ok(Out::text(401, "Unauthorized"));
            }
            match &p["/latest/meta-data/".len()..] {
                "instance-id" => Ok(Out::text(200, &i.id)),
                "spot/instance-action" if i.notice_active(st.now) => {
                    let when = iso(i.notice_at.unwrap_or(st.now) + i.notice_secs);
                    Ok(Out::json(200, json!({"action": "terminate", "time": when})))
                }
                "spot/instance-action" => Ok(Out::text(404, "Not Found")),
                _ => Err("metadata item"),
            }
        }
        (Provider::Gcp, "GET", p) if p.starts_with("/computeMetadata/v1/instance/") => {
            if req.header("metadata-flavor") != Some("Google") {
                return Ok(Out::text(403, "Missing Metadata-Flavor:Google header."));
            }
            let on = i.notice_active(st.now);
            match &p["/computeMetadata/v1/instance/".len()..] {
                "preempted" => Ok(Out::text(200, if on { "TRUE" } else { "FALSE" })),
                "maintenance-event" => Ok(Out::text(
                    200,
                    if on {
                        "TERMINATE_ON_HOST_MAINTENANCE"
                    } else {
                        "NONE"
                    },
                )),
                "name" => Ok(Out::text(200, &i.name)),
                _ => Err("metadata item"),
            }
        }
        _ => Err("metadata request"),
    }
}
