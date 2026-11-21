//! `agents/config {id, option, value}` (Task 40): the user's mode and model switches, only inside the provider's lock.
//!
//! A mode is switched only to one on [`allowed_modes`] (the lock's own allow-list); any other is refused with the
//! reason ([`why_outside`]). A model is free within the profile (the agent refuses a model it does not have). The agent
//! is asked by `session/set_config_option`; one that lacks the method (`-32601`) gets `session/set_mode` or
//! `session/set_model` instead.

use super::lock::allowed_modes;
use crate::settings::profiles::Provider;

/// The provider's name as its profile writes it.
pub fn provider_name(p: Provider) -> &'static str {
    match p {
        Provider::Claude => "claude",
        Provider::Codex => "codex",
        Provider::Gemini => "gemini",
        Provider::Kimi => "kimi",
        Provider::DeepSeek => "deepseek",
    }
}

/// Why a mode off [`allowed_modes`] is not offered.
pub fn why_outside(p: Provider) -> &'static str {
    match p {
        Provider::Claude => {
            "its other modes (`acceptEdits`, `bypassPermissions`, `dontAsk`) run tools without asking, which skips the hub's matrix"
        }
        Provider::Codex => {
            "its lock pins the `read-only` preset, and every other preset runs tools without the hub's answer"
        }
        Provider::Gemini => {
            "its lock holds only in `default`; its other approval modes skip the admin policy's asks"
        }
        Provider::Kimi => {
            "its lock holds only in `default`; plan mode writes its plan file without asking the hooks"
        }
        Provider::DeepSeek => "it has no modes, and its lock is not proven yet",
    }
}

/// Whether the user may set OPTION to VALUE on a session locked as PROVIDER; the refusal says why.
pub fn check(provider: Option<Provider>, option: &str, value: &str) -> Result<(), String> {
    match option {
        "model" => Ok(()),
        "mode" => {
            let Some(p) = provider else {
                return Err("this agent has no lock, so its mode cannot be switched".into());
            };
            if allowed_modes(p).contains(&value) {
                return Ok(());
            }
            let allowed = allowed_modes(p);
            let offered = if allowed.is_empty() {
                "none".to_owned()
            } else {
                allowed.join(", ")
            };
            Err(format!(
                "mode `{value}` is outside {}'s lock (allowed: {offered}): {}",
                provider_name(p),
                why_outside(p)
            ))
        }
        other => Err(format!(
            "`{other}` is not a switchable option (mode, model)"
        )),
    }
}

/// Asks the agent to set OPTION to VALUE: `session/set_config_option`, else (an agent without the method) the older
/// `session/set_mode` or `session/set_model`.
pub async fn apply(
    conn: &hermod::Conn,
    sid: &hermod::SessionId,
    option: &str,
    value: &str,
) -> Result<(), hermod::Error> {
    match conn.set_config_option(sid, option, value).await {
        Err(hermod::Error::Rpc { code: -32601, .. }) => match option {
            "mode" => conn.set_mode(sid, value).await,
            _ => conn.set_model(sid, value).await,
        },
        r => r,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allow_list_per_provider() {
        assert_eq!(allowed_modes(Provider::Claude), ["default", "plan"]);
        assert_eq!(allowed_modes(Provider::Gemini), ["default"]);
        assert_eq!(allowed_modes(Provider::Kimi), ["default"]);
        assert!(allowed_modes(Provider::Codex).is_empty());
        assert!(allowed_modes(Provider::DeepSeek).is_empty());
        // the switch obeys the list
        assert!(check(Some(Provider::Claude), "mode", "plan").is_ok());
        let e = check(Some(Provider::Claude), "mode", "bypassPermissions").unwrap_err();
        assert!(
            e.contains("bypassPermissions") && e.contains("default, plan") && e.contains("matrix"),
            "{e}"
        );
        let e = check(Some(Provider::Codex), "mode", "auto").unwrap_err();
        assert!(
            e.contains("allowed: none") && e.contains("read-only"),
            "{e}"
        );
        assert!(
            check(Some(Provider::Kimi), "mode", "plan")
                .unwrap_err()
                .contains("plan")
        );
        assert!(
            check(None, "mode", "default")
                .unwrap_err()
                .contains("no lock")
        );
        // models are free within the profile, other options are not switchable
        assert!(check(Some(Provider::Codex), "model", "gpt-x").is_ok());
        assert!(check(Some(Provider::Claude), "thought_level", "high").is_err());
    }
}
