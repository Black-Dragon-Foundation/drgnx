# Editor features vs VS Code, Zed and Cursor

What drgnx has of the editor features people know from VS Code, Zed and Cursor, where each is described, and how it
is checked: a GUI test on a graphical frame (`drgnx test --ui`, with screenshots) and, where typing or scrolling could
suffer, a perf workload with a budget (`drgnx test --perf`, [perf.md](../develop/perf.md)). Keys are the VS Code
profile's; every command is also in the palette.

| Feature | In drgnx | Guide | GUI test | Perf workload |
|---|---|---|---|---|
| Language support (tree-sitter grammars, installed when asked) | `lang/*` modules | [editing.md](editing.md) | — (batch: `mod-grammars-test.el`) | — |
| Faster language servers | `extra/booster` (eglot through emacs-lsp-booster) | [editing.md](editing.md) | — (batch: `mod-amenities-test.el`) | — |
| Format on save | `extra/format` (apheleia) | [editing.md](editing.md) | — (batch: `mod-amenities-test.el`) | — |
| Debugging | `extra/debug` (dape) | [editing.md](editing.md) | — (batch: `mod-amenities-test.el`) | — |
| Sticky scroll | `editor/sticky` | [editing.md](editing.md) | `drgnx-ui-code/sticky-guides-smooth` | code-scrolling |
| Indent guides | `extra/guides` | [editing.md](editing.md) | `drgnx-ui-code/sticky-guides-smooth` | code-scrolling |
| Smooth scrolling | `ui/smooth` | [editing.md](editing.md) | `drgnx-ui-code/sticky-guides-smooth` | code-scrolling |
| Markdown preview, Mermaid | `lang/markdown` | [editing.md](editing.md) | — (batch: `mod-markdown-test.el`) | — |
| Diff view (split or unified) | `tools/diff` | [git.md](git.md) | `drgnx-ui-git/diff-blame-review-prs` | diff-scrolling |
| Inline blame | `extra/blame` | [git.md](git.md) | `drgnx-ui-git/diff-blame-review-prs` | — |
| AI commit message | `tools/commit-message` | [git.md](git.md) | — (batch: `mod-commit-message-test.el`) | — |
| Review Branch | `tools/review` | [git.md](git.md) | `drgnx-ui-git/diff-blame-review-prs` | — |
| Pull Requests tab | `tools/prs` | [git.md](git.md) | `drgnx-ui-git/diff-blame-review-prs` | — |
| Search and replace in files (include / exclude, tick boxes, one Undo) | Replace in Files `C-S-h` | [replace.md](replace.md) | `drgnx-ui-m11c1/replace-layouts-shortcuts` | replace-typing |
| Rename a symbol (the language server's edits, reviewed first) | Rename Symbol `F2` | [replace.md](replace.md) | — (batch: `mod-replace-view-test.el`) | — |
| Find and replace in a file (the find bar) | Replace in File `C-h` | [replace.md](replace.md) | `drgnx-ui-m11c1/replace-layouts-shortcuts` | — |
| Sidebar views: Explorer, Search | View: Explorer `C-S-e`, View: Search `C-S-f` | [workbench.md](workbench.md) | `drgnx-ui-m11c1/replace-layouts-shortcuts` | explorer |
| Layouts (Agent, Editor, Zen, Browser, your own) | Next Layout `C-k C-l` | [layouts.md](layouts.md) | `drgnx-ui-m11c1/replace-layouts-shortcuts` | — |
| A web page beside the editor; Playwright reports | `tools/browser` | [browser.md](browser.md) | `drgnx-ui-m11c1/replace-layouts-shortcuts` (without WebKit) | — |
| Watch and take over the agents' browser | `tools/live` | [live.md](live.md) | `drgnx-ui-m11c1/replace-layouts-shortcuts` (a mock browser) | live-view |
| Edit on another machine (ssh hosts, podman containers), a status-line segment, Reconnect | `tools/remote` | [remote.md](remote.md) | `drgnx-ui-m11c2/agent-settings-and-remote` (a podman container) | remote-typing |
| Agent settings pages (Claude Code, Codex, Gemini, Kimi Code): routes, MCP servers, hooks, skills, Test | `tools/agent-settings` | [agent-settings.md](agent-settings.md) | `drgnx-ui-m11c2/agent-settings-and-remote` (mock MCP servers) | agent-settings-open |
| Keyboard Shortcuts editor (record chords, conflicts, filters) | Keyboard Shortcuts `C-k C-s` | [shortcuts.md](shortcuts.md) | `drgnx-ui-m11c1/replace-layouts-shortcuts` | — |
| Vim editing (states, leader keys, ex commands, panels, Vim next to VS Code's keys) | `editor/evil`, chosen with Keyboard Profile… | [keys.md](keys.md#vim-keys) | `drgnx-ui-modal/*` and `drgnx-live-modal/quit-keeps-the-daemon` (live tier, own sessions) | typing-evil, motions-evil, explorer-evil |

Not yet: VS Code settings import, Reopen Closed Tab, agent modes and
checkpoints, @-context, side chats — they come in the next milestones.
