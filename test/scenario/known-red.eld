;; Scenarios expected to fail, per configuration.  Each entry is explained by its trace in
;; docs/scenarios.md; the drgnx workbench (M3) must turn them green.
((gryphn
  drgnx-scenario/explorer-click-stays
  drgnx-scenario/explorer-expand-stays
  drgnx-scenario/explorer-hold-is-a-click
  drgnx-scenario/explorer-keys-stay
  drgnx-scenario/explorer-keys-during-churn
  drgnx-scenario/explorer-keys-then-background-event
  drgnx-scenario/explorer-cross-project-keeps-root
  drgnx-scenario/buffers-header-survives-refresh
  drgnx-scenario/buffers-scroll-kept
  drgnx-scenario/buffers-close-hits-row))
