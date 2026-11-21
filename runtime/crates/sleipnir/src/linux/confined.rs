//! Confined SELinux logins. A login mapped to `user_u` runs in the domain `user_t`, which the stock policy keeps from
//! running setuid helpers: rootless podman needs `newuidmap` for a namespace with subordinate ids, and without them its
//! single-id namespace is denied too. So no container job can start for such a login, and drgnx refuses them with the
//! cause and what an admin would change, at `drgnx doctor`, at the hub's job start, in a runner's probe and at a
//! runner's job start. Detection reads the process's own context: nothing prompts, nothing is cached.

/// Whether CONTEXT (`user:role:type[:level]`, as `/proc/self/attr/current` reads) is in the domain `user_t`.
pub fn is_user_t(context: &str) -> bool {
    context.trim_end_matches(['\0', '\n']).split(':').nth(2) == Some("user_t")
}

/// This process's SELinux context, or none (no SELinux, or an LSM whose context is not SELinux's).
pub fn context() -> Option<String> {
    let c = std::fs::read_to_string("/proc/self/attr/current").ok()?;
    let c = c.trim_end_matches(['\0', '\n']);
    (c.split(':').count() >= 3).then(|| c.to_string())
}

/// Why container jobs are refused for a login in CONTEXT, or none when they aren't.
pub fn refusal_for(context: &str) -> Option<String> {
    is_user_t(context).then(|| {
        format!(
            "this login runs as the confined SELinux user user_u (domain user_t, context {}): rootless podman needs \
             newuidmap, which the stock policy denies user_t, so container jobs are refused here. An admin can map the \
             login to another SELinux user (`semanage login -m -s staff_u LOGIN`, then log in again), or give it a \
             subuid and subgid range and a local policy module that lets user_t run newuidmap",
            context.trim_end_matches(['\0', '\n'])
        )
    })
}

/// Why container jobs are refused for this process's login, or none.
pub fn refusal() -> Option<String> {
    context().as_deref().and_then(refusal_for)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// [D] Only `user_t` is refused: `staff_t`, `unconfined_t` and a host without SELinux (or with AppArmor, whose
    /// context has no type field) are not; the reason names the cause and both of an admin's fixes.
    #[test]
    fn only_a_user_t_login_is_refused_and_the_reason_says_what_to_change() {
        let why = refusal_for("user_u:user_r:user_t:s0\0").expect("refused");
        for part in [
            "user_u",
            "user_t",
            "newuidmap",
            "semanage login",
            "subuid",
            "policy module",
        ] {
            assert!(why.contains(part), "{part}: {why}");
        }
        assert!(!why.contains('\0'));
        for not in [
            "staff_u:staff_r:staff_t:s0-s0:c0.c1023",
            "unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023",
            "system_u:system_r:container_t:s0:c1,c2",
            "unconfined",
            "",
        ] {
            assert_eq!(refusal_for(not), None, "{not}");
        }
    }
}
