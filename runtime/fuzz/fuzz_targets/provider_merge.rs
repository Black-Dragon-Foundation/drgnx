//! Arbitrary request bodies and OpenRouter restrictions through `rewrite::body`. Layout: byte 0 is flags (bit 0 data
//! collection deny, bit 1 zdr, bit 2 provider is openrouter, bit 3 path is `/v1/messages`, bit 4 a model is set), then
//! a line of drgnx's `only` slugs (comma separated), a line of its `ignore` slugs, and the rest is the body. An answer
//! for a request the restrictions apply to must be a JSON object whose `provider` carries them all (`only` inside
//! drgnx's, `ignore` holding all of drgnx's, `data_collection` `"deny"`, `zdr` true); with nothing to apply the body
//! comes back as it came.
#![no_main]

use bifrost::Restrictions;
use bifrost::rewrite;
use bytes::Bytes;
use libfuzzer_sys::fuzz_target;
use serde_json::Value;

fn slugs(line: &[u8]) -> Vec<String> {
    String::from_utf8_lossy(line)
        .split(',')
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect()
}

fuzz_target!(|data: &[u8]| {
    let [flags, rest @ ..] = data else {
        return;
    };
    let mut lines = rest.splitn(3, |b| *b == b'\n');
    let (only, ignore, body) = (
        lines.next().unwrap_or_default(),
        lines.next().unwrap_or_default(),
        lines.next().unwrap_or_default(),
    );
    let Ok(r) = Restrictions::new(slugs(only), slugs(ignore), flags & 1 != 0, flags & 2 != 0)
    else {
        return;
    };
    let provider = if flags & 4 != 0 {
        "openrouter"
    } else {
        "other"
    };
    let path = if flags & 8 != 0 {
        "/v1/messages?beta=true"
    } else {
        "/v1/models"
    };
    let model = (flags & 16 != 0).then_some("m-1");
    let applies = provider == "openrouter" && flags & 8 != 0 && !r.is_empty();

    let input = Bytes::copy_from_slice(body);
    let Ok(out) = rewrite::body(input.clone(), model, Some(&r), path, provider) else {
        return;
    };
    if !applies && model.is_none() {
        assert_eq!(out, input, "nothing to apply, the bytes stay");
        return;
    }
    if body.is_empty() {
        assert_eq!(out, input);
        return;
    }
    let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(&out) else {
        // a body that is not an object stays as it came, unless restrictions apply (then it is refused)
        assert!(!applies && out == input, "not a JSON object: {out:?}");
        return;
    };
    if let Some(m) = model {
        assert_eq!(object.get("model").and_then(Value::as_str), Some(m));
    }
    if !applies {
        return;
    }
    let p = object
        .get("provider")
        .and_then(Value::as_object)
        .expect("restrictions apply, so the body has a provider object");
    let strings = |key: &str| -> Option<Vec<String>> {
        p.get(key).map(|v| {
            v.as_array()
                .expect("a list")
                .iter()
                .map(|s| s.as_str().expect("a slug").to_owned())
                .collect()
        })
    };
    if !r.only().is_empty() {
        let only = strings("only").expect("only is set");
        assert!(!only.is_empty() && only.iter().all(|s| r.only().contains(s)));
    }
    if !r.ignore().is_empty() {
        let ignore = strings("ignore").expect("ignore is set");
        assert!(r.ignore().iter().all(|s| ignore.contains(s)));
    }
    if r.data_collection_deny() {
        assert_eq!(p.get("data_collection"), Some(&Value::from("deny")));
    }
    if r.zdr() {
        assert_eq!(p.get("zdr"), Some(&Value::Bool(true)));
    }
});
