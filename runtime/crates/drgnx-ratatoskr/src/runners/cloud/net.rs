//! The network rule (design §6.7.1): one security group per region, tagged with the hub id, inbound TCP 22 only.
//!
//! The hub sits behind carrier NAT and its address changes, so the rule names no source: TCP 22 from anywhere, IPv4
//! and IPv6. sshd in the image takes certificates only. The group is in the account's default VPC, named
//! [`group_name`], tagged `drgnx-hub=<hub id>` when it is made (the policy allows the security-group calls only on
//! resources with that tag). A group of ours found again is used as it is when it holds exactly that rule, given the
//! rule when it holds none (a crash between the two calls), and refused when it allows anything else.

use super::CloudError;
use super::aws::{Aws, El, HUB_TAG};

/// The group's name in the region: `drgnx-<hub id>-ssh`.
pub fn group_name(hub_id: &str) -> String {
    format!("drgnx-{hub_id}-ssh")
}

fn pairs(p: &[(&str, &str)]) -> Vec<(String, String)> {
    p.iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

/// Whether PERM is the rule: TCP 22, from 0.0.0.0/0 and ::/0 only.
fn is_ours(perm: &El) -> bool {
    let all = |path: &str, leaf: &str| -> Vec<String> {
        perm.find_all(path)
            .into_iter()
            .filter_map(|i| i.text_at(leaf).map(str::to_string))
            .collect()
    };
    perm.text_at("ipProtocol") == Some("tcp")
        && perm.text_at("fromPort") == Some("22")
        && perm.text_at("toPort") == Some("22")
        && all("ipRanges/item", "cidrIp") == ["0.0.0.0/0"]
        && all("ipv6Ranges/item", "cidrIpv6") == ["::/0"]
}

/// This hub's security group in AWS's region, made and given its rule when missing: its id.
pub async fn ensure_rule(aws: &Aws) -> Result<String, CloudError> {
    let hub = aws.hub_id().to_string();
    let name = group_name(&hub);
    let tag = format!("tag:{HUB_TAG}");
    let found = aws
        .ec2(
            "DescribeSecurityGroups",
            pairs(&[
                ("Filter.1.Name", &tag),
                ("Filter.1.Value.1", &hub),
                ("Filter.2.Name", "group-name"),
                ("Filter.2.Value.1", &name),
            ]),
        )
        .await?;
    let id = match found.find_all("securityGroupInfo/item").first() {
        Some(g) => {
            let id = g.text_at("groupId").unwrap_or_default().to_string();
            let perms = g.find_all("ipPermissions/item");
            match perms.as_slice() {
                [] => id,
                [p] if is_ours(p) => return Ok(id),
                _ => {
                    return Err(CloudError::Other(format!(
                        "the security group {id} ({name}) allows more than SSH in; drgnx uses it only with TCP 22 \
                         alone: remove its other rules, or delete it for drgnx to make it again"
                    )));
                }
            }
        }
        None => {
            let made = aws
                .ec2(
                    "CreateSecurityGroup",
                    pairs(&[
                        ("GroupName", &name),
                        ("GroupDescription", "drgnx runners: SSH in"),
                        ("TagSpecification.1.ResourceType", "security-group"),
                        ("TagSpecification.1.Tag.1.Key", HUB_TAG),
                        ("TagSpecification.1.Tag.1.Value", &hub),
                    ]),
                )
                .await?;
            made.text_at("groupId")
                .filter(|g| !g.is_empty())
                .ok_or_else(|| CloudError::Other("CreateSecurityGroup answered no group".into()))?
                .to_string()
        }
    };
    aws.ec2(
        "AuthorizeSecurityGroupIngress",
        pairs(&[
            ("GroupId", &id),
            ("IpPermissions.1.IpProtocol", "tcp"),
            ("IpPermissions.1.FromPort", "22"),
            ("IpPermissions.1.ToPort", "22"),
            ("IpPermissions.1.IpRanges.1.CidrIp", "0.0.0.0/0"),
            ("IpPermissions.1.Ipv6Ranges.1.CidrIpv6", "::/0"),
        ]),
    )
    .await?;
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runners::cloud::testmock::{HUB, Mock};
    use serde_json::{Value, json};

    // [B] the mock models the fixture policy: a group made without the hub's tag would be refused
    #[tokio::test]
    async fn the_rule_is_port_22_only_and_tagged() {
        let m = Mock::start();
        let aws = m.aws();
        let id = ensure_rule(&aws).await.unwrap();
        assert!(id.starts_with("sg-"), "{id}");
        assert_eq!(
            ensure_rule(&aws).await.unwrap(),
            id,
            "one group, found again"
        );
        let r = m.resources().await;
        let groups: Vec<&Value> = r["resources"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|x| x["kind"] == "sg")
            .collect();
        assert_eq!(groups.len(), 1, "{r}");
        let g = groups[0];
        assert_eq!(g["id"], id.as_str());
        assert_eq!(g["tags"]["drgnx-hub"], HUB);
        assert_eq!(g["data"]["name"], group_name(HUB));
        assert_eq!(
            g["data"]["rules"],
            json!([{"proto": "tcp", "from": "22", "to": "22", "cidr": ["0.0.0.0/0"], "cidr6": ["::/0"]}]),
            "TCP 22 only, IPv4 and IPv6"
        );
        assert_eq!(
            r["unknown_requests"],
            json!([]),
            "every call is one the mock knows"
        );
    }
}
