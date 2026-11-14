# Fixture fonts

The fonts the hub's fitter (`runtime/crates/drgnx-rows`, `fit`) and the GUI fit rows (`test/ui/rows-fit-gui-test.el`)
measure, so both read the same files. Each is under the SIL Open Font License 1.1 (its licence file is beside it).

| File | Font | Version | Why |
|---|---|---|---|
| `Inter-Regular.ttf` | Inter (rsms) | 4.1 (Fedora `rsms-inter-fonts`) | the UI role's default family |
| `JetBrainsMono-Regular.otf` | JetBrains Mono | 2.304 (Fedora `jetbrains-mono-fonts`) | the code role's default family (CFF outlines) |
| `Vazirmatn-wght.ttf` | Vazirmatn, variable (`wght` 100-900) | Fedora `vazirmatn-vf-fonts` | a variable font with HVAR |
