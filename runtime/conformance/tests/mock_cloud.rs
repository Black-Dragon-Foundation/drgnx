//! `ratatoskr-mock cloud`: the EC2 and GCE subsets, the instance clocks and the failure knobs, over HTTP.
//!
//! Every test starts its own mock on a free port with no containers (`--podman-remote none`). The mock's clock is
//! virtual (`POST /__mock/clock`), so nothing here sleeps and nothing waits on a deadline except the timeout test,
//! whose "answer" is the absence of one.

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

const MOCK: &str = env!("CARGO_BIN_EXE_ratatoskr-mock");
const HUB: &str = "hub-1";

struct Cloud {
    child: Child,
    port: u16,
}

impl Drop for Cloud {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct Reply {
    status: u16,
    body: String,
}

impl Reply {
    fn json(&self) -> Value {
        serde_json::from_str(&self.body).unwrap_or_else(|e| panic!("not JSON ({e}): {}", self.body))
    }
}

/// A fake credential header, built in pieces.
fn aws_auth(region: &str) -> String {
    let id = ["AK", "IA", "FAKEFAKEFAKE0000"].concat();
    format!(
        "AWS4-HMAC-SHA256 Credential={id}/20261106/{region}/ec2/aws4_request, SignedHeaders=host, Signature=00"
    )
}

impl Cloud {
    fn start(extra: &[&str]) -> Cloud {
        let mut child = Command::new(MOCK)
            .args([
                "cloud",
                "--listen",
                "127.0.0.1:0",
                "--podman-remote",
                "none",
                "--prefix",
                "t",
                "--run",
                "r1",
            ])
            .args(extra)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        let port = line
            .strip_prefix("MOCK-CLOUD-PORT ")
            .unwrap_or_else(|| panic!("no port line: {line:?}"))
            .trim()
            .parse()
            .unwrap();
        Cloud { child, port }
    }

    fn raw(&self, method: &str, path: &str, headers: &[(&str, &str)], body: &str) -> Reply {
        let mut s = TcpStream::connect(("127.0.0.1", self.port)).unwrap();
        let mut req = format!("{method} {path} HTTP/1.1\r\nHost: mock\r\nConnection: close\r\n");
        for (k, v) in headers {
            req += &format!("{k}: {v}\r\n");
        }
        req += &format!("Content-Length: {}\r\n\r\n{body}", body.len());
        s.write_all(req.as_bytes()).unwrap();
        let mut out = Vec::new();
        s.read_to_end(&mut out).unwrap();
        let text = String::from_utf8_lossy(&out).into_owned();
        let (head, body) = text.split_once("\r\n\r\n").unwrap_or((&text, ""));
        let status = head
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        Reply {
            status,
            body: body.to_string(),
        }
    }

    /// An EC2 Query call; `params` are `k=v` pairs, values are not escaped (the tests use plain ones).
    fn ec2(&self, action: &str, params: &[(&str, &str)]) -> Reply {
        self.ec2_in("us-east-1", action, params)
    }

    fn ec2_in(&self, region: &str, action: &str, params: &[(&str, &str)]) -> Reply {
        let mut body = format!("Action={action}&Version=2016-11-15");
        for (k, v) in params {
            body += &format!("&{k}={v}");
        }
        self.raw(
            "POST",
            "/",
            &[
                ("Authorization", &aws_auth(region)),
                ("Content-Type", "application/x-www-form-urlencoded"),
            ],
            &body,
        )
    }

    fn gce(&self, method: &str, path: &str, body: Option<Value>) -> Reply {
        self.gce_tok(method, path, body, "any")
    }

    fn gce_tok(&self, method: &str, path: &str, body: Option<Value>, tok: &str) -> Reply {
        let auth = format!("Bearer {tok}");
        self.raw(
            method,
            path,
            &[
                ("Authorization", &auth),
                ("Content-Type", "application/json"),
            ],
            &body.map(|b| b.to_string()).unwrap_or_default(),
        )
    }

    fn knob(&self, name: &str, body: Value) -> Value {
        let r = self.raw("POST", &format!("/__mock/{name}"), &[], &body.to_string());
        assert_eq!(r.status, 200, "knob {name}: {}", r.body);
        r.json()
    }

    fn resources(&self) -> Value {
        self.raw("GET", "/__mock/resources", &[], "").json()
    }
}

fn tag(x: &str) -> String {
    format!("<{x}>")
}

/// The text between `<name>` and `</name>`, first occurrence.
fn xml<'a>(body: &'a str, name: &str) -> &'a str {
    let open = tag(name);
    let from = body
        .find(&open)
        .unwrap_or_else(|| panic!("no {open} in {body}"))
        + open.len();
    let to = body[from..].find(&format!("</{name}>")).unwrap() + from;
    &body[from..to]
}

const RUN: &[(&str, &str)] = &[
    ("ImageId", "ami-base0fedora45x86"),
    ("InstanceType", "m7g.large"),
    ("MinCount", "1"),
    ("MaxCount", "1"),
    ("InstanceInitiatedShutdownBehavior", "terminate"),
    ("MetadataOptions.HttpTokens", "required"),
    ("MetadataOptions.HttpPutResponseHopLimit", "1"),
    ("TagSpecification.1.ResourceType", "instance"),
    ("TagSpecification.1.Tag.1.Key", "drgnx-hub"),
    ("TagSpecification.1.Tag.1.Value", HUB),
];

fn run_with(extra: &[(&str, &str)]) -> Vec<(String, String)> {
    let mut v: Vec<(String, String)> = RUN
        .iter()
        .map(|(a, b)| (a.to_string(), b.to_string()))
        .collect();
    v.extend(extra.iter().map(|(a, b)| (a.to_string(), b.to_string())));
    v
}

fn ec2_run(c: &Cloud, extra: &[(&str, &str)]) -> Reply {
    let owned = run_with(extra);
    let p: Vec<(&str, &str)> = owned
        .iter()
        .map(|(a, b)| (a.as_str(), b.as_str()))
        .collect();
    c.ec2("RunInstances", &p)
}

const GCE_ZONE: &str = "/compute/v1/projects/p1/zones/us-central1-a";

fn gce_body(name: &str) -> Value {
    json!({
        "name": name,
        "machineType": "zones/us-central1-a/machineTypes/n2-standard-4",
        "labels": {"drgnx-hub": HUB},
        "scheduling": {
            "provisioningModel": "SPOT",
            "instanceTerminationAction": "DELETE",
            "terminationTime": "2026-11-06T06:00:00Z",
            "preemptionNoticeDuration": {"seconds": 120},
        },
    })
}

#[test]
fn ec2_dry_run_answers_like_ec2() {
    let c = Cloud::start(&["--hub", HUB]);
    // allowed under the fixture policy: the dry run says it would have succeeded, and creates nothing
    let owned = run_with(&[("DryRun", "true")]);
    let p: Vec<(&str, &str)> = owned
        .iter()
        .map(|(a, b)| (a.as_str(), b.as_str()))
        .collect();
    let ok = c.ec2("RunInstances", &p);
    assert_eq!(ok.status, 412, "{}", ok.body);
    assert_eq!(xml(&ok.body, "Code"), "DryRunOperation");
    // denied (no hub tag): UnauthorizedOperation, even with DryRun
    let denied = c.ec2(
        "RunInstances",
        &[
            ("ImageId", "ami-base0fedora45x86"),
            ("InstanceType", "m7g.large"),
            ("MinCount", "1"),
            ("MaxCount", "1"),
            ("DryRun", "true"),
        ],
    );
    assert_eq!(denied.status, 403, "{}", denied.body);
    assert_eq!(xml(&denied.body, "Code"), "UnauthorizedOperation");
    assert_eq!(c.resources()["instances"].as_array().unwrap().len(), 0);
}

#[test]
fn client_token_returns_the_same_instance() {
    let c = Cloud::start(&[]);
    let a = ec2_run(&c, &[("ClientToken", "tok-1")]);
    let b = ec2_run(&c, &[("ClientToken", "tok-1")]);
    assert_eq!(a.status, 200, "{}", a.body);
    assert_eq!(xml(&a.body, "instanceId"), xml(&b.body, "instanceId"));
    assert_eq!(c.resources()["instances"].as_array().unwrap().len(), 1);
    let other = ec2_run(&c, &[("ClientToken", "tok-2")]);
    assert_ne!(xml(&a.body, "instanceId"), xml(&other.body, "instanceId"));
    // the same token with other parameters is the real error
    let clash = c.ec2(
        "RunInstances",
        &[
            ("ClientToken", "tok-1"),
            ("ImageId", "ami-base0fedora45x86"),
            ("InstanceType", "c7g.xlarge"),
            ("MinCount", "1"),
            ("MaxCount", "1"),
        ],
    );
    assert_eq!(xml(&clash.body, "Code"), "IdempotentParameterMismatch");
}

#[test]
fn untagged_terminate_is_denied_under_the_fixture_policy() {
    let c = Cloud::start(&["--hub", HUB]);
    c.knob(
        "seed",
        json!({"provider": "aws", "id": "i-foreign000000001", "tags": {"Name": "not ours"}}),
    );
    let ours = ec2_run(&c, &[]);
    let ours_id = xml(&ours.body, "instanceId").to_string();

    let denied = c.ec2(
        "TerminateInstances",
        &[("InstanceId.1", "i-foreign000000001")],
    );
    assert_eq!(denied.status, 403, "{}", denied.body);
    assert_eq!(xml(&denied.body, "Code"), "UnauthorizedOperation");
    let denied_dry = c.ec2(
        "TerminateInstances",
        &[("InstanceId.1", "i-foreign000000001"), ("DryRun", "true")],
    );
    assert_eq!(xml(&denied_dry.body, "Code"), "UnauthorizedOperation");

    let ok = c.ec2("TerminateInstances", &[("InstanceId.1", &ours_id)]);
    assert_eq!(ok.status, 200, "{}", ok.body);
    assert_eq!(xml(&ok.body, "name"), "shutting-down");

    // the explicit denies hold whatever the tags say
    let r = c.ec2(
        "ModifyImageAttribute",
        &[("ImageId", "ami-base0fedora45x86")],
    );
    assert_eq!(xml(&r.body, "Code"), "UnauthorizedOperation");
    let r = c.ec2("ModifySnapshotAttribute", &[("SnapshotId", "snap-x")]);
    assert_eq!(xml(&r.body, "Code"), "UnauthorizedOperation");
    let r = ec2_run(&c, &[("IamInstanceProfile.Name", "p")]);
    assert_eq!(xml(&r.body, "Code"), "UnauthorizedOperation");
    // the foreign instance is untouched
    let d = c.ec2(
        "DescribeInstances",
        &[("InstanceId.1", "i-foreign000000001")],
    );
    assert_eq!(xml(&d.body, "name"), "running");
}

#[test]
fn gce_stop_clears_termination_time() {
    let c = Cloud::start(&[]);
    let ins = c.gce(
        "POST",
        &format!("{GCE_ZONE}/instances?requestId=00000000-0000-0000-0000-000000000001"),
        Some(gce_body("drgnx-a")),
    );
    assert_eq!(ins.status, 200, "{}", ins.body);
    let got = c
        .gce("GET", &format!("{GCE_ZONE}/instances/drgnx-a"), None)
        .json();
    assert_eq!(got["scheduling"]["terminationTime"], "2026-11-06T06:00:00Z");
    assert_eq!(got["scheduling"]["instanceTerminationAction"], "DELETE");
    assert_eq!(
        got["scheduling"]["preemptionNoticeDuration"]["seconds"],
        120
    );
    assert_eq!(got["labels"]["drgnx-hub"], HUB);

    let stop = c.gce("POST", &format!("{GCE_ZONE}/instances/drgnx-a/stop"), None);
    assert_eq!(stop.status, 200, "{}", stop.body);
    let got = c
        .gce("GET", &format!("{GCE_ZONE}/instances/drgnx-a"), None)
        .json();
    assert_eq!(got["status"], "TERMINATED");
    assert!(got["scheduling"].get("terminationTime").is_none(), "{got}");
    // time passing the old deadline deletes nothing now
    c.knob("clock", json!({"advance_s": 86400}));
    let got = c.gce("GET", &format!("{GCE_ZONE}/instances/drgnx-a"), None);
    assert_eq!(got.status, 200, "{}", got.body);
}

#[test]
fn gce_request_id_is_idempotent() {
    let c = Cloud::start(&[]);
    let path = format!("{GCE_ZONE}/instances?requestId=00000000-0000-0000-0000-0000000000aa");
    let a = c.gce("POST", &path, Some(gce_body("drgnx-b"))).json();
    let b = c.gce("POST", &path, Some(gce_body("drgnx-b"))).json();
    assert_eq!(a["name"], b["name"], "the same operation comes back");
    assert_eq!(c.resources()["instances"].as_array().unwrap().len(), 1);
    // without the id the same name is a conflict
    let again = c.gce(
        "POST",
        &format!("{GCE_ZONE}/instances"),
        Some(gce_body("drgnx-b")),
    );
    assert_eq!(again.status, 409, "{}", again.body);
}

#[test]
fn a_401_until_the_token_is_accepted() {
    let c = Cloud::start(&[]);
    c.knob("expire", json!({}));
    let r = c.gce_tok(
        "GET",
        "/compute/v1/projects/p1/aggregated/instances",
        None,
        "old",
    );
    assert_eq!(r.status, 401, "{}", r.body);
    let r = c.ec2("DescribeInstances", &[]);
    assert_eq!(r.status, 401, "{}", r.body);
    assert_eq!(xml(&r.body, "Code"), "ExpiredToken");
    // the token the user's command now prints
    c.knob("token", json!({"accept": "fresh-token"}));
    let r = c.gce_tok(
        "GET",
        "/compute/v1/projects/p1/aggregated/instances",
        None,
        "old",
    );
    assert_eq!(r.status, 401, "an old token stays refused");
    let r = c.gce_tok(
        "GET",
        "/compute/v1/projects/p1/aggregated/instances",
        None,
        "fresh-token",
    );
    assert_eq!(r.status, 200, "{}", r.body);
}

#[test]
fn a_spot_notice_shows_in_the_metadata_and_ends_the_instance() {
    let c = Cloud::start(&[]);
    c.knob("spot-notice", json!({"id": "next", "in_s": 600}));
    let r = ec2_run(&c, &[("InstanceMarketOptions.MarketType", "spot")]);
    let id = xml(&r.body, "instanceId").to_string();
    let md = |c: &Cloud, token: Option<&str>| {
        let path = format!("/__metadata/{id}/latest/meta-data/spot/instance-action");
        match token {
            Some(t) => c.raw("GET", &path, &[("X-aws-ec2-metadata-token", t)], ""),
            None => c.raw("GET", &path, &[], ""),
        }
    };
    // IMDSv2: no token, no answer
    assert_eq!(md(&c, None).status, 401);
    let tok = c.raw(
        "PUT",
        &format!("/__metadata/{id}/latest/api/token"),
        &[("X-aws-ec2-metadata-token-ttl-seconds", "60")],
        "",
    );
    assert_eq!(tok.status, 200);
    assert_eq!(md(&c, Some(&tok.body)).status, 404, "no notice yet");
    c.knob("clock", json!({"advance_s": 600}));
    let n = md(&c, Some(&tok.body));
    assert_eq!(n.status, 200, "{}", n.body);
    assert_eq!(n.json()["action"], "terminate");
    // a request that crossed a hop (a container behind the host's network) gets no token
    let hop = c.raw(
        "PUT",
        &format!("/__metadata/{id}/latest/api/token"),
        &[
            ("X-aws-ec2-metadata-token-ttl-seconds", "60"),
            ("X-Mock-Hops", "2"),
        ],
        "",
    );
    assert_eq!(hop.status, 0, "the connection is dropped: {}", hop.body);
    // two minutes later the instance is gone
    c.knob("clock", json!({"advance_s": 120}));
    let d = c.ec2("DescribeInstances", &[("InstanceId.1", &id)]);
    assert_eq!(xml(&d.body, "name"), "terminated");
}

#[test]
fn a_gce_preemption_shows_in_the_metadata() {
    let c = Cloud::start(&[]);
    c.knob("spot-notice", json!({"id": "next", "at": 1_793_926_800u64}));
    c.gce(
        "POST",
        &format!("{GCE_ZONE}/instances"),
        Some(gce_body("drgnx-c")),
    );
    let get = |c: &Cloud| {
        c.raw(
            "GET",
            "/__metadata/drgnx-c/computeMetadata/v1/instance/preempted",
            &[("Metadata-Flavor", "Google")],
            "",
        )
    };
    assert_eq!(get(&c).body, "FALSE");
    c.knob("clock", json!({"set": 1_793_926_800u64}));
    assert_eq!(get(&c).body, "TRUE");
    let bad = c.raw(
        "GET",
        "/__metadata/drgnx-c/computeMetadata/v1/instance/preempted",
        &[],
        "",
    );
    assert_eq!(bad.status, 403);
}

#[test]
fn capacity_and_quota_errors_come_n_times_then_stop() {
    let c = Cloud::start(&[]);
    c.knob("capacity", json!({"times": 2}));
    for _ in 0..2 {
        let r = ec2_run(&c, &[]);
        assert_eq!(xml(&r.body, "Code"), "InsufficientInstanceCapacity");
    }
    assert_eq!(ec2_run(&c, &[]).status, 200);
    c.knob("quota", json!({"times": 1}));
    let r = ec2_run(&c, &[]);
    assert_eq!(xml(&r.body, "Code"), "VcpuLimitExceeded");
    assert_eq!(ec2_run(&c, &[]).status, 200);

    // GCE says it in the operation
    c.knob("capacity", json!({"times": 1}));
    let op = c
        .gce(
            "POST",
            &format!("{GCE_ZONE}/instances"),
            Some(gce_body("drgnx-d")),
        )
        .json();
    assert_eq!(op["status"], "DONE");
    assert_eq!(
        op["error"]["errors"][0]["code"],
        "ZONE_RESOURCE_POOL_EXHAUSTED"
    );
    let ops = c
        .gce(
            "GET",
            &format!("{GCE_ZONE}/operations/{}", op["name"].as_str().unwrap()),
            None,
        )
        .json();
    assert_eq!(
        ops["error"]["errors"][0]["code"],
        "ZONE_RESOURCE_POOL_EXHAUSTED"
    );
    assert_eq!(
        c.gce("GET", &format!("{GCE_ZONE}/instances/drgnx-d"), None)
            .status,
        404
    );
}

#[test]
fn a_timeout_never_answers_and_a_generic_failure_answers() {
    let c = Cloud::start(&[]);
    c.knob("timeout", json!({"op": "DescribeInstances", "times": 1}));
    let mut s = TcpStream::connect(("127.0.0.1", c.port)).unwrap();
    s.set_read_timeout(Some(Duration::from_millis(300)))
        .unwrap();
    let body = "Action=DescribeInstances";
    let req = format!(
        "POST / HTTP/1.1\r\nHost: m\r\nAuthorization: {}\r\nContent-Length: {}\r\n\r\n{body}",
        aws_auth("us-east-1"),
        body.len()
    );
    s.write_all(req.as_bytes()).unwrap();
    let mut buf = [0u8; 16];
    let e = s.read(&mut buf).unwrap_err();
    assert!(
        matches!(
            e.kind(),
            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
        ),
        "{e}"
    );
    drop(s);
    // used up: the next call answers
    assert_eq!(c.ec2("DescribeInstances", &[]).status, 200);

    c.knob("fail", json!({"op": "GetConsoleOutput", "status": 503, "code": "RequestLimitExceeded", "times": 1}));
    let r = c.ec2("GetConsoleOutput", &[("InstanceId.1", "i-x")]);
    assert_eq!(
        (r.status, xml(&r.body, "Code")),
        (503, "RequestLimitExceeded")
    );
}

#[test]
fn boot_delay_stuck_instances_and_the_console() {
    let c = Cloud::start(&[]);
    c.knob("boot-delay", json!({"seconds": 30}));
    let r = ec2_run(&c, &[]);
    let id = xml(&r.body, "instanceId").to_string();
    let state = |c: &Cloud| {
        xml(
            &c.ec2("DescribeInstances", &[("InstanceId.1", &id)]).body,
            "name",
        )
        .to_string()
    };
    assert_eq!(state(&c), "pending");
    // no console before boot, with Latest or without
    let console = |c: &Cloud, latest: bool| {
        let mut p = vec![("InstanceId", id.as_str())];
        if latest {
            p.push(("Latest", "true"));
        }
        c.ec2("GetConsoleOutput", &p)
    };
    assert_eq!(xml(&console(&c, true).body, "output"), "");
    c.knob("clock", json!({"advance_s": 30}));
    assert_eq!(state(&c), "running");
    assert_eq!(
        xml(&console(&c, false).body, "output"),
        "",
        "without Latest there is nothing"
    );
    let out = console(&c, true);
    let text = String::from_utf8(b64_decode(xml(&out.body, "output"))).unwrap();
    assert!(text.contains("BEGIN SSH HOST KEY FINGERPRINTS"), "{text}");
    assert!(text.contains("SHA256:"), "{text}");

    // a stuck instance never leaves pending, and one stuck in the end never leaves shutting-down
    c.knob("stuck", json!({"id": "next", "on": "start"}));
    let s = ec2_run(&c, &[]);
    let sid = xml(&s.body, "instanceId").to_string();
    c.knob("clock", json!({"advance_s": 100000}));
    let d = c.ec2("DescribeInstances", &[("InstanceId.1", &sid)]);
    assert_eq!(xml(&d.body, "name"), "pending");
    c.knob("stuck", json!({"id": id, "on": "end"}));
    c.ec2("TerminateInstances", &[("InstanceId.1", &id)]);
    c.knob("clock", json!({"advance_s": 100000}));
    assert_eq!(state(&c), "shutting-down");
}

#[test]
fn shutdown_attribute_mismatch_and_poweroff() {
    let c = Cloud::start(&[]);
    let r = ec2_run(&c, &[]);
    let id = xml(&r.body, "instanceId").to_string();
    let attr = |c: &Cloud| {
        let r = c.ec2(
            "DescribeInstanceAttribute",
            &[
                ("InstanceId", &id),
                ("Attribute", "instanceInitiatedShutdownBehavior"),
            ],
        );
        xml(&r.body, "value").to_string()
    };
    assert_eq!(attr(&c), "terminate");
    c.knob("shutdown-mismatch", json!({"value": "stop"}));
    assert_eq!(attr(&c), "stop");
    // a poweroff on the instance as it was started ends it
    c.knob("poweroff", json!({"id": id}));
    let d = c.ec2("DescribeInstances", &[("InstanceId.1", &id)]);
    assert_eq!(xml(&d.body, "name"), "terminated");
}

#[test]
fn prices_are_a_knob_and_a_rise_is_visible() {
    let c = Cloud::start(&[]);
    c.knob("prices", json!({"aws": {"spot": {"m7g.large": 0.03}, "ondemand": {"m7g.large": 0.08}}, "gcp": {"spot": {"n2-standard-4": 0.05}}}));
    let h = c.ec2(
        "DescribeSpotPriceHistory",
        &[
            ("InstanceType.1", "m7g.large"),
            ("ProductDescription.1", "Linux/UNIX"),
        ],
    );
    assert_eq!(xml(&h.body, "spotPrice"), "0.030000");
    let p = c.raw("POST", "/", &[("Authorization", &aws_auth("us-east-1")), ("X-Amz-Target", "AWSPriceListService.GetProducts")], &json!({"ServiceCode": "AmazonEC2", "Filters": [{"Type": "TERM_MATCH", "Field": "instanceType", "Value": "m7g.large"}]}).to_string());
    assert_eq!(p.status, 200, "{}", p.body);
    assert!(p.json()["PriceList"][0].as_str().unwrap().contains("0.08"));
    // the overrun: the same call, a higher price
    c.knob("prices", json!({"aws": {"spot": {"m7g.large": 0.9}}}));
    let h = c.ec2(
        "DescribeSpotPriceHistory",
        &[("InstanceType.1", "m7g.large")],
    );
    assert_eq!(xml(&h.body, "spotPrice"), "0.900000");
    let sk = c
        .gce("GET", "/v1/services/6F81-5844-456A/skus", None)
        .json();
    assert!(
        sk["skus"]
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["description"].as_str().unwrap().contains("n2-standard-4")),
        "{sk}"
    );
}

#[test]
fn the_security_group_rule_is_stored_and_tagged() {
    let c = Cloud::start(&["--hub", HUB]);
    let g = c.ec2(
        "CreateSecurityGroup",
        &[
            ("GroupName", "drgnx-hub-1"),
            ("GroupDescription", "ssh"),
            ("TagSpecification.1.ResourceType", "security-group"),
            ("TagSpecification.1.Tag.1.Key", "drgnx-hub"),
            ("TagSpecification.1.Tag.1.Value", HUB),
        ],
    );
    assert_eq!(g.status, 200, "{}", g.body);
    let gid = xml(&g.body, "groupId").to_string();
    let a = c.ec2(
        "AuthorizeSecurityGroupIngress",
        &[
            ("GroupId", &gid),
            ("IpPermissions.1.IpProtocol", "tcp"),
            ("IpPermissions.1.FromPort", "22"),
            ("IpPermissions.1.ToPort", "22"),
            ("IpPermissions.1.IpRanges.1.CidrIp", "0.0.0.0/0"),
            ("IpPermissions.1.Ipv6Ranges.1.CidrIpv6", "::/0"),
        ],
    );
    assert_eq!(a.status, 200, "{}", a.body);
    let d = c.ec2(
        "DescribeSecurityGroups",
        &[
            ("Filter.1.Name", "tag:drgnx-hub"),
            ("Filter.1.Value.1", HUB),
        ],
    );
    assert_eq!(xml(&d.body, "groupId"), gid);
    assert_eq!(xml(&d.body, "fromPort"), "22");
    assert_eq!(xml(&d.body, "cidrIpv6"), "::/0");
}

#[test]
fn requests_the_mock_does_not_know_fail_loudly() {
    let c = Cloud::start(&[]);
    let r = c.ec2("RebootInstances", &[("InstanceId.1", "i-x")]);
    assert_eq!(r.status, 501, "{}", r.body);
    assert!(r.body.contains("RebootInstances"), "{}", r.body);
    let r = c.gce("GET", "/compute/v1/projects/p1/regions", None);
    assert_eq!(r.status, 501, "{}", r.body);
    let r = c.raw("GET", "/nowhere", &[], "");
    assert_eq!(r.status, 501);
    let r = c.raw("POST", "/__mock/nonsense", &[], "{}");
    assert_eq!(r.status, 501);
    let seen = c.resources()["unknown_requests"].as_array().unwrap().len();
    assert_eq!(seen, 4);
}

#[test]
fn gce_serial_output_firewall_images_and_permissions() {
    let c = Cloud::start(&[]);
    c.gce(
        "POST",
        &format!("{GCE_ZONE}/instances"),
        Some(gce_body("drgnx-e")),
    );
    let s = c
        .gce(
            "GET",
            &format!("{GCE_ZONE}/instances/drgnx-e/serialPort?port=1"),
            None,
        )
        .json();
    assert!(s["contents"].as_str().unwrap().contains("SHA256:"), "{s}");
    let agg = c
        .gce(
            "GET",
            "/compute/v1/projects/p1/aggregated/instances?filter=labels.drgnx-hub%3Dhub-1",
            None,
        )
        .json();
    let items = &agg["items"]["zones/us-central1-a"]["instances"];
    assert_eq!(items.as_array().unwrap().len(), 1, "{agg}");
    let none = c
        .gce(
            "GET",
            "/compute/v1/projects/p1/aggregated/instances?filter=labels.drgnx-hub%3Dother",
            None,
        )
        .json();
    assert_eq!(
        none["items"].as_object().map(|o| o.len()).unwrap_or(0),
        0,
        "{none}"
    );

    let fw = json!({"name": "drgnx-ssh", "direction": "INGRESS", "allowed": [{"IPProtocol": "tcp", "ports": ["22"]}], "sourceRanges": ["0.0.0.0/0", "::/0"]});
    assert_eq!(
        c.gce("POST", "/compute/v1/projects/p1/global/firewalls", Some(fw))
            .status,
        200
    );
    let got = c
        .gce(
            "GET",
            "/compute/v1/projects/p1/global/firewalls/drgnx-ssh",
            None,
        )
        .json();
    assert_eq!(got["allowed"][0]["ports"][0], "22");
    assert_eq!(
        c.gce(
            "DELETE",
            "/compute/v1/projects/p1/global/firewalls/drgnx-ssh",
            None
        )
        .status,
        200
    );
    assert_eq!(
        c.gce(
            "GET",
            "/compute/v1/projects/p1/global/firewalls/drgnx-ssh",
            None
        )
        .status,
        404
    );

    let fam = c.gce(
        "GET",
        "/compute/v1/projects/fedora-coreos-cloud/global/images/family/fedora-coreos-stable",
        None,
    );
    assert_eq!(fam.status, 200, "{}", fam.body);
    assert_eq!(fam.json()["family"], "fedora-coreos-stable");

    let perms = json!({"permissions": ["compute.instances.create", "compute.instances.delete"]});
    let p = c
        .gce(
            "POST",
            "/v1/projects/p1:testIamPermissions",
            Some(perms.clone()),
        )
        .json();
    assert_eq!(p["permissions"].as_array().unwrap().len(), 2);
    c.knob(
        "deny-permissions",
        json!({"permissions": ["compute.instances.delete"]}),
    );
    let p = c
        .gce("POST", "/v1/projects/p1:testIamPermissions", Some(perms))
        .json();
    assert_eq!(p["permissions"], json!(["compute.instances.create"]));
}

#[test]
fn a_missing_termination_time_knob_and_the_deadline_deleting() {
    let c = Cloud::start(&[]);
    c.gce(
        "POST",
        &format!("{GCE_ZONE}/instances"),
        Some(gce_body("drgnx-f")),
    );
    // the deadline (2026-11-06T06:00:00Z) passes: DELETE removes the instance
    c.knob("clock", json!({"set": 1_793_944_800u64}));
    assert_eq!(
        c.gce("GET", &format!("{GCE_ZONE}/instances/drgnx-f"), None)
            .status,
        404
    );

    c.knob("no-termination-time", json!({}));
    c.gce(
        "POST",
        &format!("{GCE_ZONE}/instances"),
        Some(gce_body("drgnx-g")),
    );
    let got = c
        .gce("GET", &format!("{GCE_ZONE}/instances/drgnx-g"), None)
        .json();
    assert!(got["scheduling"].get("terminationTime").is_none(), "{got}");
}

#[test]
fn only_our_region_and_our_images_are_listed() {
    let c = Cloud::start(&[]);
    ec2_run(&c, &[]);
    let here = c.ec2_in("us-east-1", "DescribeInstances", &[]);
    assert!(here.body.contains("<instanceId>"), "{}", here.body);
    let there = c.ec2_in("eu-west-1", "DescribeInstances", &[]);
    assert!(!there.body.contains("<instanceId>"), "{}", there.body);

    let img = c.ec2(
        "CreateImage",
        &[("InstanceId", &first_id(&here.body)), ("Name", "drgnx-img")],
    );
    assert_eq!(img.status, 200, "{}", img.body);
    let ami = xml(&img.body, "imageId").to_string();
    let d = c.ec2("DescribeImages", &[("ImageId.1", &ami)]);
    assert_eq!(xml(&d.body, "imageState"), "available");
    assert_eq!(c.ec2("DeregisterImage", &[("ImageId", &ami)]).status, 200);
    assert_eq!(c.ec2("DescribeImages", &[("ImageId.1", &ami)]).status, 400);
    assert_eq!(
        xml(&c.ec2("GetCallerIdentity", &[]).body, "Account"),
        "000000000000"
    );
    assert!(c.ec2("DescribeSubnets", &[]).body.contains("subnet-"));
}

fn first_id(body: &str) -> String {
    xml(body, "instanceId").to_string()
}

fn b64_decode(s: &str) -> Vec<u8> {
    let val = |c: u8| match c {
        b'A'..=b'Z' => c - b'A',
        b'a'..=b'z' => c - b'a' + 26,
        b'0'..=b'9' => c - b'0' + 52,
        b'+' => 62,
        _ => 63,
    };
    let mut out = Vec::new();
    let mut acc = 0u32;
    let mut bits = 0;
    for c in s.bytes().filter(|c| *c != b'=') {
        acc = (acc << 6) | val(c) as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    out
}
