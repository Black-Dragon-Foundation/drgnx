//! The GCE REST subset: `instances` (insert, get, delete, stop, aggregatedList, serial port), `images`, `firewalls`,
//! `zoneOperations.get`, Resource Manager's `testIamPermissions` and the Billing Catalog's `skus.list`.
//!
//! Operations are always `DONE` when the call returns; a capacity or quota fault is the operation's `error`, as GCE
//! reports it. `requestId` makes `insert` idempotent, a `stop` clears `scheduling.terminationTime`, and a deadline
//! that the virtual clock passes deletes the instance (action `DELETE`) or stops it.

use super::instances::{Instance, Provider, St, iso, parse_iso};
use super::{Api, Gate, Out, Req, Res, State, error, unknown};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

const SELF: &str = "https://compute.mock/compute/v1/projects/mock";

fn route(method: &str, segs: &[&str]) -> Option<(&'static str, Vec<String>)> {
    let s = |v: &[&&str]| -> Vec<String> { v.iter().map(|x| x.to_string()).collect() };
    Some(match (method, segs) {
        ("POST", ["v1", "projects", x]) if x.ends_with(":testIamPermissions") => {
            ("projects.testIamPermissions", s(&[]))
        }
        ("GET", ["v1", "services", _, "skus"]) => ("skus.list", s(&[])),
        (_, ["compute", "v1", "projects", _, rest @ ..]) => match (method, rest) {
            ("POST", ["zones", z, "instances"]) => ("instances.insert", s(&[z])),
            ("GET", ["zones", z, "instances", n]) => ("instances.get", s(&[z, n])),
            ("DELETE", ["zones", z, "instances", n]) => ("instances.delete", s(&[z, n])),
            ("POST", ["zones", z, "instances", n, "stop"]) => ("instances.stop", s(&[z, n])),
            ("GET", ["zones", z, "instances", n, "serialPort"]) => {
                ("instances.getSerialPortOutput", s(&[z, n]))
            }
            ("GET", ["aggregated", "instances"]) => ("instances.aggregatedList", s(&[])),
            ("GET", ["global", "images", "family", f]) => ("images.getFromFamily", s(&[f])),
            ("POST", ["global", "images"]) => ("images.insert", s(&[])),
            ("GET", ["global", "images", n]) => ("images.get", s(&[n])),
            ("DELETE", ["global", "images", n]) => ("images.delete", s(&[n])),
            ("POST", ["global", "firewalls"]) => ("firewalls.insert", s(&[])),
            ("GET", ["global", "firewalls", n]) => ("firewalls.get", s(&[n])),
            ("DELETE", ["global", "firewalls", n]) => ("firewalls.delete", s(&[n])),
            ("GET", ["zones", _, "operations", o]) => ("zoneOperations.get", s(&[o])),
            ("GET", ["global", "operations", o]) => ("globalOperations.get", s(&[o])),
            _ => return None,
        },
        _ => return None,
    })
}

fn not_found(what: &str) -> Out {
    error(
        Api::Gce,
        404,
        "notFound",
        &format!("The resource '{what}' was not found"),
    )
}

/// Make an operation, keep it, answer with it.
fn operation(st: &mut State, kind: &str, target: &str, err: Option<(String, String)>) -> Value {
    let name = format!("operation-{}", st.next_id());
    let mut op = json!({
        "kind": "compute#operation", "name": name, "operationType": kind, "status": "DONE", "progress": 100,
        "targetLink": format!("{SELF}/{target}"), "insertTime": iso(st.now),
    });
    if let Some((code, msg)) = err {
        op["error"] = json!({"errors": [{"code": code, "message": msg}]});
    }
    st.operations.push(op.clone());
    op
}

fn instance_json(st: &State, i: &Instance) -> Value {
    let mut sched = match &i.scheduling {
        Value::Object(m) => m.clone(),
        _ => Map::new(),
    };
    sched.remove("terminationTime");
    sched.insert(
        "instanceTerminationAction".into(),
        json!(i.termination_action),
    );
    if let Some(t) = &i.termination_raw {
        sched.insert("terminationTime".into(), json!(t));
    }
    json!({
        "kind": "compute#instance", "id": i.id, "name": i.name, "status": i.gce_state(),
        "zone": format!("{SELF}/zones/{}", i.zone),
        "machineType": format!("{SELF}/zones/{}/machineTypes/{}", i.zone, i.itype),
        "labels": i.tags, "scheduling": sched, "creationTimestamp": iso(i.created),
        "networkInterfaces": [{"accessConfigs": [{"natIP": st.podman.container(i)}]}],
    })
}

pub(crate) fn handle(st: &mut State, req: &Req) -> Out {
    let path = req.path.clone();
    let segs: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    let Some((op, a)) = route(&req.method, &segs) else {
        return unknown(st, req, "GCE route");
    };
    let fault = match st.gate(req, Api::Gce, op) {
        Gate::Pass => None,
        Gate::Out(o) => return o,
        Gate::OperationError(c, m) => Some((c, m)),
    };
    match op {
        "instances.insert" => insert(st, req, &a[0], fault),
        "instances.get" => match st.find(Provider::Gcp, &a[1]) {
            Some(p) => Out::json(200, instance_json(st, &st.instances[p])),
            None => not_found(&a[1]),
        },
        "instances.delete" => match st.find(Provider::Gcp, &a[1]) {
            Some(p) => {
                let now = st.now;
                let i = &mut st.instances[p];
                i.state = St::Ending;
                i.end_at = Some(now);
                let target = format!("zones/{}/instances/{}", a[0], a[1]);
                let op = operation(st, "delete", &target, None);
                st.settle();
                Out::json(200, op)
            }
            None => not_found(&a[1]),
        },
        "instances.stop" => match st.find(Provider::Gcp, &a[1]) {
            Some(p) => {
                let i = &mut st.instances[p];
                i.state = St::Stopped;
                // a stop clears the deadline
                i.termination_at = None;
                i.termination_raw = None;
                st.podman.stop(i);
                let target = format!("zones/{}/instances/{}", a[0], a[1]);
                Out::json(200, operation(st, "stop", &target, None))
            }
            None => not_found(&a[1]),
        },
        "instances.getSerialPortOutput" => match st.find(Provider::Gcp, &a[1]) {
            Some(p) => {
                let i = &st.instances[p];
                let text = st.podman.console(i).unwrap_or_else(|| i.console_text());
                Out::json(
                    200,
                    json!({"kind": "compute#serialPortOutput", "contents": text, "start": 0, "next": text.len()}),
                )
            }
            None => not_found(&a[1]),
        },
        "instances.aggregatedList" => aggregated(st, req),
        "images.getFromFamily" => match st
            .res
            .iter()
            .find(|r| r.kind == "gce-image" && r.data["family"] == a[0].as_str())
        {
            Some(r) => Out::json(200, image_json(r)),
            None => not_found(&a[0]),
        },
        "images.insert" => {
            let b = req.json();
            let Some(name) = b["name"].as_str() else {
                return error(Api::Gce, 400, "required", "the image needs a name");
            };
            if st.res.iter().any(|r| r.kind == "gce-image" && r.id == name) {
                return error(Api::Gce, 409, "alreadyExists", "the image already exists");
            }
            let labels: BTreeMap<String, String> = b["labels"]
                .as_object()
                .into_iter()
                .flatten()
                .map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string()))
                .collect();
            st.res.push(Res {
                kind: "gce-image",
                id: name.into(),
                tags: labels,
                data: json!({"name": name, "family": b["family"]}),
            });
            Out::json(
                200,
                operation(st, "insert", &format!("global/images/{name}"), None),
            )
        }
        "images.get" => match st
            .res
            .iter()
            .find(|r| r.kind == "gce-image" && r.id == a[0])
        {
            Some(r) => Out::json(200, image_json(r)),
            None => not_found(&a[0]),
        },
        "firewalls.insert" => {
            let b = req.json();
            let Some(name) = b["name"].as_str() else {
                return error(Api::Gce, 400, "required", "the rule needs a name");
            };
            if st.res.iter().any(|r| r.kind == "firewall" && r.id == name) {
                return error(Api::Gce, 409, "alreadyExists", "the rule already exists");
            }
            st.res.push(Res {
                kind: "firewall",
                id: name.into(),
                tags: BTreeMap::new(),
                data: b.clone(),
            });
            Out::json(
                200,
                operation(st, "insert", &format!("global/firewalls/{name}"), None),
            )
        }
        "firewalls.get" => match st.res.iter().find(|r| r.kind == "firewall" && r.id == a[0]) {
            Some(r) => Out::json(200, r.data.clone()),
            None => not_found(&a[0]),
        },
        "images.delete" | "firewalls.delete" => {
            let kind = if op == "images.delete" {
                "gce-image"
            } else {
                "firewall"
            };
            match st.res.iter().position(|r| r.kind == kind && r.id == a[0]) {
                Some(p) => {
                    st.res.remove(p);
                    Out::json(200, operation(st, "delete", &a[0], None))
                }
                None => not_found(&a[0]),
            }
        }
        "zoneOperations.get" | "globalOperations.get" => {
            match st.operations.iter().find(|o| o["name"] == a[0].as_str()) {
                Some(o) => Out::json(200, o.clone()),
                None => not_found(&a[0]),
            }
        }
        "projects.testIamPermissions" => {
            let granted: Vec<Value> = req.json()["permissions"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|p| {
                    !p.as_str()
                        .is_some_and(|p| st.denied_permissions.iter().any(|d| d == p))
                })
                .cloned()
                .collect();
            Out::json(200, json!({"permissions": granted}))
        }
        _ => skus(st),
    }
}

fn image_json(r: &Res) -> Value {
    json!({"kind": "compute#image", "id": r.id, "name": r.data["name"], "family": r.data["family"], "status": "READY", "labels": r.tags})
}

fn insert(st: &mut State, req: &Req, zone: &str, fault: Option<(String, String)>) -> Out {
    let b = req.json();
    let Some(name) = b["name"].as_str().map(str::to_string) else {
        return error(Api::Gce, 400, "required", "the instance needs a name");
    };
    let rid = req.q("requestId").map(str::to_string);
    if let Some(op) = rid.as_ref().and_then(|r| st.request_ids.get(r)) {
        return Out::json(200, op.clone());
    }
    let target = format!("zones/{zone}/instances/{name}");
    if fault.is_none() && st.find(Provider::Gcp, &name).is_some() {
        return error(
            Api::Gce,
            409,
            "alreadyExists",
            &format!("The resource '{target}' already exists"),
        );
    }
    let op = if let Some(f) = fault {
        operation(st, "insert", &target, Some(f))
    } else {
        let id = (st.seq + 1) * 1_000_003;
        let mut i = Instance::new(Provider::Gcp, &id.to_string(), &name, zone, st.now);
        i.itype = b["machineType"]
            .as_str()
            .unwrap_or("")
            .rsplit('/')
            .next()
            .unwrap_or("")
            .to_string();
        i.image = b["disks"][0]["initializeParams"]["sourceImage"]
            .as_str()
            .unwrap_or("")
            .to_string();
        i.tags = b["labels"]
            .as_object()
            .into_iter()
            .flatten()
            .map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string()))
            .collect();
        let sched = &b["scheduling"];
        i.spot = sched["provisioningModel"] == "SPOT";
        i.termination_action = sched["instanceTerminationAction"]
            .as_str()
            .unwrap_or("STOP")
            .to_string();
        if !st.no_termination_time {
            i.termination_raw = sched["terminationTime"].as_str().map(str::to_string);
            i.termination_at = i.termination_raw.as_deref().and_then(parse_iso);
        }
        let secs = &sched["preemptionNoticeDuration"]["seconds"];
        i.notice_secs = secs
            .as_u64()
            .or(secs.as_str().and_then(|s| s.parse().ok()))
            .unwrap_or(30);
        i.scheduling = sched.clone();
        st.add_instance(i);
        let op = operation(st, "insert", &target, None);
        st.settle();
        op
    };
    if let Some(r) = rid {
        st.request_ids.insert(r, op.clone());
    }
    Out::json(200, op)
}

fn aggregated(st: &State, req: &Req) -> Out {
    // `labels.KEY=VALUE`, the only filter the hub uses
    let want = match req.q("filter") {
        None => None,
        Some(f) => match f.strip_prefix("labels.").and_then(|r| r.split_once('=')) {
            Some((k, v)) => Some((k.trim().to_string(), v.trim().trim_matches('"').to_string())),
            None => {
                return error(
                    Api::Gce,
                    400,
                    "invalid",
                    &format!("mock: filter {f:?} is not modelled"),
                );
            }
        },
    };
    let mut items = Map::new();
    for i in st
        .instances
        .iter()
        .filter(|i| i.provider == Provider::Gcp && i.state != St::Gone)
    {
        if want.as_ref().is_some_and(|(k, v)| i.tags.get(k) != Some(v)) {
            continue;
        }
        let e = items
            .entry(format!("zones/{}", i.zone))
            .or_insert_with(|| json!({"instances": []}));
        e["instances"]
            .as_array_mut()
            .unwrap()
            .push(instance_json(st, i));
    }
    Out::json(
        200,
        json!({"kind": "compute#instanceAggregatedList", "items": items}),
    )
}

fn skus(st: &State) -> Out {
    let skus: Vec<Value> = st
        .prices
        .iter()
        .filter_map(|(k, p)| {
            let (market, ty) = k.strip_prefix("gcp/")?.split_once('/')?;
            let spot = market == "spot";
            Some(json!({
                "description": format!("{} instance {ty} running in Americas", if spot { "Spot Preemptible" } else { "On Demand" }),
                "category": {"resourceFamily": "Compute", "usageType": if spot { "Preemptible" } else { "OnDemand" }},
                "serviceRegions": ["us-central1"],
                "pricingInfo": [{"pricingExpression": {"usageUnit": "h", "tieredRates": [
                    {"startUsageAmount": 0, "unitPrice": {"currencyCode": "USD", "units": p.floor().to_string(), "nanos": ((p - p.floor()) * 1e9).round() as i64}}
                ]}}],
            }))
        })
        .collect();
    Out::json(200, json!({"skus": skus}))
}
