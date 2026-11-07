//! `agents/config {id, option, value}` (Task 40): the user's mode and model switches, only inside the provider's lock.

#[cfg(test)]
mod tests {
    use crate::agents::lock::allowed_modes;
    use crate::settings::profiles::Provider;

    #[test]
    fn allow_list_per_provider() {
        assert_eq!(allowed_modes(Provider::Claude), ["default", "plan"]);
        assert_eq!(allowed_modes(Provider::Gemini), ["default"]);
        assert_eq!(allowed_modes(Provider::Kimi), ["default"]);
        assert!(allowed_modes(Provider::Codex).is_empty());
        assert!(allowed_modes(Provider::DeepSeek).is_empty());
    }
}
