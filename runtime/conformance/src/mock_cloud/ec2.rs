//! The EC2 Query subset (XML), STS `GetCallerIdentity` and the Pricing API's `GetProducts` on the same endpoint.
//!
//! The fixture policy (with `--hub ID`): `RunInstances` needs the instance tag `drgnx-hub=<id>`, IMDSv2 required and
//! no instance profile; terminate, `CreateImage`, `DeregisterImage`, `DeleteSnapshot`, `CreateSecurityGroup` and the
//! security-group calls need the target (or, for creation, the request) tagged; `ModifyImageAttribute` and
//! `ModifySnapshotAttribute` are always denied. A denied call answers `UnauthorizedOperation` (also under `DryRun`);
//! an allowed `DryRun` answers `DryRunOperation`.

use super::instances::{Instance, Provider, St, iso};
use super::{Api, Gate, Out, Params, Req, Res, State, b64, error, esc, unknown};
use serde_json::json;
use std::collections::BTreeMap;

const KNOWN: &[&str] = &[
    "RunInstances",
    "DescribeInstances",
    "DescribeInstanceAttribute",
    "TerminateInstances",
    "GetConsoleOutput",
    "DescribeSpotPriceHistory",
    "DescribeImages",
    "CreateImage",
    "DeregisterImage",
    "DeleteSnapshot",
    "ModifyImageAttribute",
    "ModifySnapshotAttribute",
    "CreateSecurityGroup",
    "AuthorizeSecurityGroupIngress",
    "DeleteSecurityGroup",
    "DescribeSecurityGroups",
    "DescribeSubnets",
    "GetCallerIdentity",
];

fn reply(action: &str, inner: &str) -> Out {
    Out::xml(
        200,
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<{action}Response xmlns=\"http://ec2.amazonaws.com/doc/2016-11-15/\"><requestId>mock-request</requestId>{inner}</{action}Response>"
        ),
    )
}

fn denied() -> Out {
    error(
        Api::Ec2,
        403,
        "UnauthorizedOperation",
        "You are not authorized to perform this operation.",
    )
}

fn not_found(code: &str, what: &str) -> Out {
    error(
        Api::Ec2,
        400,
        code,
        &format!("The ID '{what}' does not exist"),
    )
}

/// The answer a denied call or a `DryRun` gets, or none when the call goes ahead.
fn dry(p: &Params, allowed: bool) -> Option<Out> {
    if !allowed {
        return Some(denied());
    }
    p.flag("DryRun").then(|| {
        error(
            Api::Ec2,
            412,
            "DryRunOperation",
            "Request would have succeeded, but DryRun flag is set.",
        )
    })
}

fn region_of(req: &Req) -> String {
    req.header("authorization")
        .and_then(|a| a.split("Credential=").nth(1))
        .and_then(|c| c.split('/').nth(2))
        .unwrap_or("us-east-1")
        .to_string()
}

fn tag_set(tags: &BTreeMap<String, String>) -> String {
    let items: String = tags
        .iter()
        .map(|(k, v)| {
            format!(
                "<item><key>{}</key><value>{}</value></item>",
                esc(k),
                esc(v)
            )
        })
        .collect();
    format!("<tagSet>{items}</tagSet>")
}

fn owned(st: &State, tags: &BTreeMap<String, String>) -> bool {
    match &st.hub {
        None => true,
        Some(h) => tags.get("drgnx-hub") == Some(h),
    }
}

fn instance_xml(i: &Instance) -> String {
    let (code, name) = i.aws_state();
    let spot = if i.spot {
        "<instanceLifecycle>spot</instanceLifecycle>"
    } else {
        ""
    };
    let token = i
        .client_token
        .as_deref()
        .map(|t| format!("<clientToken>{}</clientToken>", esc(t)))
        .unwrap_or_default();
    format!(
        "<item><instanceId>{}</instanceId><imageId>{}</imageId><instanceState><code>{code}</code><name>{name}</name></instanceState>\
         <dnsName>{}</dnsName><instanceType>{}</instanceType><launchTime>{}</launchTime>\
         <placement><availabilityZone>{}</availabilityZone></placement>{spot}{token}{}\
         <metadataOptions><httpTokens>{}</httpTokens><httpPutResponseHopLimit>{}</httpPutResponseHopLimit></metadataOptions></item>",
        i.id,
        esc(&i.image),
        i.id,
        esc(&i.itype),
        iso(i.created),
        i.zone,
        tag_set(&i.tags),
        if i.tokens_required {
            "required"
        } else {
            "optional"
        },
        i.hop_limit,
    )
}

/// `Filter.N.Name` / `Filter.N.Value.M`.
fn filters(p: &Params) -> Vec<(String, Vec<String>)> {
    p.indices("Filter")
        .into_iter()
        .map(|n| {
            (
                p.get(&format!("Filter.{n}.Name")).unwrap_or("").to_string(),
                p.list(&format!("Filter.{n}.Value")),
            )
        })
        .collect()
}

/// Some(match) for a filter over tags, none for another name.
fn tag_match(name: &str, vals: &[String], tags: &BTreeMap<String, String>) -> Option<bool> {
    if let Some(k) = name.strip_prefix("tag:") {
        return Some(tags.get(k).is_some_and(|v| vals.contains(v)));
    }
    (name == "tag-key").then(|| tags.keys().any(|k| vals.contains(k)))
}

pub(crate) fn handle(st: &mut State, req: &Req) -> Out {
    if let Some(target) = req.header("x-amz-target") {
        return pricing(st, req, target);
    }
    let p = req.form();
    let Some(action) = p.get("Action").map(str::to_string) else {
        return unknown(st, req, "a POST to / with no Action");
    };
    if !KNOWN.contains(&action.as_str()) {
        return unknown(st, req, &format!("EC2 action {action}"));
    }
    match st.gate(req, Api::Ec2, &action) {
        Gate::Pass | Gate::OperationError(..) => {}
        Gate::Out(o) => return o,
    }
    let region = region_of(req);
    match action.as_str() {
        "RunInstances" => run_instances(st, &p, &region),
        "DescribeInstances" => describe_instances(st, &p, &region),
        "DescribeInstanceAttribute" => describe_attribute(st, &p),
        "TerminateInstances" => terminate(st, &p),
        "GetConsoleOutput" => console(st, &p),
        "DescribeSpotPriceHistory" => spot_prices(st, &p, &region),
        "GetCallerIdentity" => reply(
            "GetCallerIdentity",
            "<GetCallerIdentityResult><Arn>arn:aws:iam::000000000000:user/mock</Arn><UserId>MOCKUSER</UserId><Account>000000000000</Account></GetCallerIdentityResult>",
        ),
        "DescribeSubnets" => reply(
            "DescribeSubnets",
            &format!(
                "<subnetSet><item><subnetId>subnet-0default0000001</subnetId><vpcId>vpc-0default0000001</vpcId><availabilityZone>{region}a</availabilityZone><defaultForAz>true</defaultForAz></item></subnetSet>"
            ),
        ),
        "ModifyImageAttribute" | "ModifySnapshotAttribute" => match dry(&p, st.hub.is_none()) {
            Some(o) => o,
            None => reply(&action, "<return>true</return>"),
        },
        _ => resources(st, &action, &p),
    }
}

fn run_instances(st: &mut State, p: &Params, region: &str) -> Out {
    let specs = p.tag_specs();
    let itags: BTreeMap<String, String> = specs
        .iter()
        .filter(|(t, _)| t == "instance")
        .flat_map(|(_, t)| t.clone())
        .collect();
    let ok = st.hub.is_none()
        || (owned(st, &itags)
            && p.get("MetadataOptions.HttpTokens") == Some("required")
            && !p.0.iter().any(|(k, _)| k.starts_with("IamInstanceProfile")));
    if let Some(o) = dry(p, ok) {
        return o;
    }
    let image = p.get("ImageId").unwrap_or("").to_string();
    let itype = p.get("InstanceType").unwrap_or("").to_string();
    let token = p.get("ClientToken").map(str::to_string);
    if let Some(id) = token.as_ref().and_then(|t| st.tokens.get(t)).cloned() {
        let i = st.instances.iter().find(|i| i.id == id).unwrap();
        if i.image != image || i.itype != itype {
            return error(
                Api::Ec2,
                400,
                "IdempotentParameterMismatch",
                "the token was used with other parameters",
            );
        }
        return reply(
            "RunInstances",
            &format!(
                "<reservationId>r-mock</reservationId><ownerId>000000000000</ownerId><instancesSet>{}</instancesSet>",
                instance_xml(i)
            ),
        );
    }
    if !st.res.iter().any(|r| r.kind == "image" && r.id == image) {
        return not_found("InvalidAMIID.NotFound", &image);
    }
    let id = format!("i-{:017x}", st.next_id() * 0x9e37_79b1);
    let zone = p
        .get("Placement.AvailabilityZone")
        .map(str::to_string)
        .unwrap_or(format!("{region}a"));
    let mut i = Instance::new(Provider::Aws, &id, &id, &zone, st.now);
    i.image = image;
    i.itype = itype;
    i.tags = itags;
    i.client_token = token.clone();
    i.spot = p.get("InstanceMarketOptions.MarketType") == Some("spot");
    i.shutdown_requested = p
        .get("InstanceInitiatedShutdownBehavior")
        .unwrap_or("stop")
        .to_string();
    i.tokens_required = p.get("MetadataOptions.HttpTokens") == Some("required");
    i.hop_limit = p
        .get("MetadataOptions.HttpPutResponseHopLimit")
        .and_then(|h| h.parse().ok())
        .unwrap_or(1);
    let n = st.add_instance(i);
    if let Some(t) = token {
        st.tokens.insert(t, id);
    }
    st.settle();
    reply(
        "RunInstances",
        &format!(
            "<reservationId>r-mock</reservationId><ownerId>000000000000</ownerId><instancesSet>{}</instancesSet>",
            instance_xml(&st.instances[n])
        ),
    )
}

fn describe_instances(st: &State, p: &Params, region: &str) -> Out {
    let ids = p.list("InstanceId");
    let fs = filters(p);
    for id in &ids {
        if !st
            .instances
            .iter()
            .any(|i| i.provider == Provider::Aws && &i.id == id)
        {
            return not_found("InvalidInstanceID.NotFound", id);
        }
    }
    let mut out = String::new();
    for i in st
        .instances
        .iter()
        .filter(|i| i.provider == Provider::Aws && i.region() == region)
    {
        if !ids.is_empty() && !ids.contains(&i.id) {
            continue;
        }
        let mut keep = true;
        for (name, vals) in &fs {
            let m = match name.as_str() {
                "instance-state-name" => vals.iter().any(|v| v == i.aws_state().1),
                "instance-id" => vals.contains(&i.id),
                "client-token" => i.client_token.as_ref().is_some_and(|t| vals.contains(t)),
                n => match tag_match(n, vals, &i.tags) {
                    Some(m) => m,
                    None => {
                        return error(
                            Api::Ec2,
                            400,
                            "InvalidParameterValue",
                            &format!("mock: filter {n} is not modelled"),
                        );
                    }
                },
            };
            keep &= m;
        }
        if keep {
            out += &format!(
                "<item><reservationId>r-mock</reservationId><ownerId>000000000000</ownerId><instancesSet>{}</instancesSet></item>",
                instance_xml(i)
            );
        }
    }
    reply(
        "DescribeInstances",
        &format!("<reservationSet>{out}</reservationSet>"),
    )
}

fn describe_attribute(st: &State, p: &Params) -> Out {
    let id = p.get("InstanceId").unwrap_or("");
    let Some(i) = st
        .instances
        .iter()
        .find(|i| i.provider == Provider::Aws && i.id == id)
    else {
        return not_found("InvalidInstanceID.NotFound", id);
    };
    match p.get("Attribute") {
        Some("instanceInitiatedShutdownBehavior") => {
            let v = st
                .shutdown_mismatch
                .clone()
                .unwrap_or(i.shutdown_requested.clone());
            reply(
                "DescribeInstanceAttribute",
                &format!(
                    "<instanceId>{id}</instanceId><instanceInitiatedShutdownBehavior><value>{v}</value></instanceInitiatedShutdownBehavior>"
                ),
            )
        }
        a => error(
            Api::Ec2,
            400,
            "InvalidParameterValue",
            &format!("mock: attribute {a:?} is not modelled"),
        ),
    }
}

fn terminate(st: &mut State, p: &Params) -> Out {
    let ids = p.list("InstanceId");
    let mut allowed = true;
    for id in &ids {
        match st
            .instances
            .iter()
            .find(|i| i.provider == Provider::Aws && &i.id == id)
        {
            None => return not_found("InvalidInstanceID.NotFound", id),
            Some(i) => allowed &= owned(st, &i.tags),
        }
    }
    if let Some(o) = dry(p, allowed) {
        return o;
    }
    let now = st.now;
    let mut out = String::new();
    for id in &ids {
        let i = st.instances.iter_mut().find(|i| &i.id == id).unwrap();
        let prev = i.aws_state();
        if matches!(i.state, St::Pending | St::Running | St::Stopped) {
            i.state = St::Ending;
            i.end_at = Some(now);
        }
        let cur = i.aws_state();
        out += &format!(
            "<item><instanceId>{id}</instanceId><currentState><code>{}</code><name>{}</name></currentState><previousState><code>{}</code><name>{}</name></previousState></item>",
            cur.0, cur.1, prev.0, prev.1
        );
    }
    reply(
        "TerminateInstances",
        &format!("<instancesSet>{out}</instancesSet>"),
    )
}

fn console(st: &State, p: &Params) -> Out {
    let id = p.get("InstanceId").unwrap_or("");
    let Some(i) = st
        .instances
        .iter()
        .find(|i| i.provider == Provider::Aws && i.id == id)
    else {
        return not_found("InvalidInstanceID.NotFound", id);
    };
    // without Latest the real service may hand back nothing on a fresh machine: the mock does, so a client that forgets it is caught
    let text = if p.flag("Latest") {
        i.console_text()
    } else {
        String::new()
    };
    let out = if text.is_empty() {
        String::new()
    } else {
        b64(text.as_bytes())
    };
    reply(
        "GetConsoleOutput",
        &format!(
            "<instanceId>{id}</instanceId><timestamp>{}</timestamp><output>{out}</output>",
            iso(st.now)
        ),
    )
}

fn spot_prices(st: &State, p: &Params, region: &str) -> Out {
    let want = p.list("InstanceType");
    let mut out = String::new();
    for (k, price) in &st.prices {
        let Some(ty) = k.strip_prefix("aws/spot/") else {
            continue;
        };
        if !want.is_empty() && !want.iter().any(|w| w == ty) {
            continue;
        }
        out += &format!(
            "<item><instanceType>{ty}</instanceType><productDescription>Linux/UNIX</productDescription><spotPrice>{price:.6}</spotPrice><availabilityZone>{region}a</availabilityZone><timestamp>{}</timestamp></item>",
            iso(st.now)
        );
    }
    reply(
        "DescribeSpotPriceHistory",
        &format!("<spotPriceHistorySet>{out}</spotPriceHistorySet>"),
    )
}

fn pricing(st: &mut State, req: &Req, target: &str) -> Out {
    if target != "AWSPriceListService.GetProducts" {
        return unknown(st, req, &format!("AWS target {target}"));
    }
    match st.gate(req, Api::AwsJson, "GetProducts") {
        Gate::Pass | Gate::OperationError(..) => {}
        Gate::Out(o) => return o,
    }
    let b = req.json();
    let want: Vec<String> = b["Filters"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|f| f["Field"] == "instanceType")
        .filter_map(|f| f["Value"].as_str().map(str::to_string))
        .collect();
    let list: Vec<String> = st
        .prices
        .iter()
        .filter_map(|(k, price)| Some((k.strip_prefix("aws/ondemand/")?, price)))
        .filter(|(ty, _)| want.is_empty() || want.iter().any(|w| w == ty))
        .map(|(ty, price)| {
            json!({
                "product": {"attributes": {"instanceType": ty, "operatingSystem": "Linux", "tenancy": "Shared"}},
                "terms": {"OnDemand": {"t": {"priceDimensions": {"t.d": {"unit": "Hrs", "pricePerUnit": {"USD": price.to_string()}}}}}},
            })
            .to_string()
        })
        .collect();
    Out::json(200, json!({"FormatVersion": "aws_v1", "PriceList": list}))
}

/// Images, snapshots and security groups.
fn resources(st: &mut State, action: &str, p: &Params) -> Out {
    match action {
        "DescribeImages" => {
            let ids = p.list("ImageId");
            let fs = filters(p);
            let mut out = String::new();
            for id in &ids {
                if !st.res.iter().any(|r| r.kind == "image" && &r.id == id) {
                    return not_found("InvalidAMIID.NotFound", id);
                }
            }
            for r in st.res.iter().filter(|r| r.kind == "image") {
                if !ids.is_empty() && !ids.contains(&r.id) {
                    continue;
                }
                if fs
                    .iter()
                    .any(|(n, v)| tag_match(n, v, &r.tags) == Some(false))
                {
                    continue;
                }
                out += &format!(
                    "<item><imageId>{}</imageId><name>{}</name><imageState>available</imageState><architecture>{}</architecture>\
                     <blockDeviceMapping><item><deviceName>/dev/sda1</deviceName><ebs><snapshotId>{}</snapshotId><encrypted>true</encrypted></ebs></item></blockDeviceMapping>{}</item>",
                    r.id,
                    esc(r.data["name"].as_str().unwrap_or("")),
                    r.data["arch"].as_str().unwrap_or("x86_64"),
                    r.data["snapshot"].as_str().unwrap_or(""),
                    tag_set(&r.tags),
                );
            }
            reply(action, &format!("<imagesSet>{out}</imagesSet>"))
        }
        "CreateImage" => {
            let id = p.get("InstanceId").unwrap_or("");
            let Some(i) = st
                .instances
                .iter()
                .find(|i| i.provider == Provider::Aws && i.id == id)
            else {
                return not_found("InvalidInstanceID.NotFound", id);
            };
            if let Some(o) = dry(p, owned(st, &i.tags)) {
                return o;
            }
            let specs = p.tag_specs();
            let tags_for = |ty: &str| -> BTreeMap<String, String> {
                specs
                    .iter()
                    .filter(|(t, _)| t == ty)
                    .flat_map(|(_, t)| t.clone())
                    .collect()
            };
            let n = st.next_id() * 0x9e37_79b1;
            let (ami, snap) = (format!("ami-{n:017x}"), format!("snap-{n:017x}"));
            st.res.push(Res {
                kind: "snapshot",
                id: snap.clone(),
                tags: tags_for("snapshot"),
                data: json!({}),
            });
            st.res.push(Res {
                kind: "image",
                id: ami.clone(),
                tags: tags_for("image"),
                data: json!({"name": p.get("Name").unwrap_or(""), "arch": "x86_64", "snapshot": snap}),
            });
            reply(action, &format!("<imageId>{ami}</imageId>"))
        }
        "DeregisterImage" | "DeleteSnapshot" | "DeleteSecurityGroup" => {
            let (key, kind) = match action {
                "DeregisterImage" => ("ImageId", "image"),
                "DeleteSnapshot" => ("SnapshotId", "snapshot"),
                _ => ("GroupId", "sg"),
            };
            let id = p.get(key).unwrap_or("");
            let Some(pos) = st.res.iter().position(|r| r.kind == kind && r.id == id) else {
                return not_found("InvalidParameterValue", id);
            };
            if let Some(o) = dry(p, owned(st, &st.res[pos].tags)) {
                return o;
            }
            st.res.remove(pos);
            reply(action, "<return>true</return>")
        }
        "CreateSecurityGroup" => {
            let tags: BTreeMap<String, String> = p
                .tag_specs()
                .into_iter()
                .filter(|(t, _)| t == "security-group")
                .flat_map(|(_, t)| t)
                .collect();
            if let Some(o) = dry(p, owned(st, &tags)) {
                return o;
            }
            let name = p.get("GroupName").unwrap_or("").to_string();
            if st
                .res
                .iter()
                .any(|r| r.kind == "sg" && r.data["name"] == name.as_str())
            {
                return error(
                    Api::Ec2,
                    400,
                    "InvalidGroup.Duplicate",
                    "the security group already exists",
                );
            }
            let id = format!("sg-{:017x}", st.next_id() * 0x9e37_79b1);
            st.res.push(Res {
                kind: "sg",
                id: id.clone(),
                tags,
                data: json!({"name": name, "description": p.get("GroupDescription").unwrap_or(""), "rules": []}),
            });
            reply(
                action,
                &format!("<return>true</return><groupId>{id}</groupId>"),
            )
        }
        "AuthorizeSecurityGroupIngress" => {
            let id = p.get("GroupId").unwrap_or("");
            let Some(pos) = st.res.iter().position(|r| r.kind == "sg" && r.id == id) else {
                return not_found("InvalidGroup.NotFound", id);
            };
            if let Some(o) = dry(p, owned(st, &st.res[pos].tags)) {
                return o;
            }
            let rules = st.res[pos].data["rules"].as_array_mut().unwrap();
            for n in p.indices("IpPermissions") {
                let k = format!("IpPermissions.{n}");
                let rule = json!({
                    "proto": p.get(&format!("{k}.IpProtocol")).unwrap_or(""),
                    "from": p.get(&format!("{k}.FromPort")).unwrap_or(""),
                    "to": p.get(&format!("{k}.ToPort")).unwrap_or(""),
                    "cidr": (1..=9).filter_map(|m| p.get(&format!("{k}.IpRanges.{m}.CidrIp"))).collect::<Vec<_>>(),
                    "cidr6": (1..=9).filter_map(|m| p.get(&format!("{k}.Ipv6Ranges.{m}.CidrIpv6"))).collect::<Vec<_>>(),
                });
                if rules.contains(&rule) {
                    return error(
                        Api::Ec2,
                        400,
                        "InvalidPermission.Duplicate",
                        "the rule already exists",
                    );
                }
                rules.push(rule);
            }
            reply(action, "<return>true</return>")
        }
        _ => {
            // DescribeSecurityGroups
            let ids = p.list("GroupId");
            let fs = filters(p);
            let mut out = String::new();
            for r in st.res.iter().filter(|r| r.kind == "sg") {
                if !ids.is_empty() && !ids.contains(&r.id) {
                    continue;
                }
                let mut keep = true;
                for (n, v) in &fs {
                    keep &= match n.as_str() {
                        "group-name" => v.iter().any(|x| r.data["name"] == x.as_str()),
                        "group-id" => v.contains(&r.id),
                        n => match tag_match(n, v, &r.tags) {
                            Some(m) => m,
                            None => {
                                return error(
                                    Api::Ec2,
                                    400,
                                    "InvalidParameterValue",
                                    &format!("mock: filter {n} is not modelled"),
                                );
                            }
                        },
                    };
                }
                if !keep {
                    continue;
                }
                let perms: String = r.data["rules"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|x| {
                        let list = |k: &str, tag: &str| -> String {
                            x[k].as_array().into_iter().flatten().filter_map(|c| c.as_str()).map(|c| format!("<item><{tag}>{c}</{tag}></item>")).collect()
                        };
                        format!(
                            "<item><ipProtocol>{}</ipProtocol><fromPort>{}</fromPort><toPort>{}</toPort><ipRanges>{}</ipRanges><ipv6Ranges>{}</ipv6Ranges></item>",
                            x["proto"].as_str().unwrap_or(""),
                            x["from"].as_str().unwrap_or(""),
                            x["to"].as_str().unwrap_or(""),
                            list("cidr", "cidrIp"),
                            list("cidr6", "cidrIpv6"),
                        )
                    })
                    .collect();
                out += &format!(
                    "<item><groupId>{}</groupId><groupName>{}</groupName><groupDescription>{}</groupDescription><ipPermissions>{perms}</ipPermissions>{}</item>",
                    r.id,
                    esc(r.data["name"].as_str().unwrap_or("")),
                    esc(r.data["description"].as_str().unwrap_or("")),
                    tag_set(&r.tags),
                );
            }
            reply(
                "DescribeSecurityGroups",
                &format!("<securityGroupInfo>{out}</securityGroupInfo>"),
            )
        }
    }
}
