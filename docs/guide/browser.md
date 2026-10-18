# Browser pane

A web page in a pane beside the editor (module `tools/browser`): watch a localhost app, a Playwright run or an agent's
browser, or search the web, without leaving Emacs. The Browser layout ([layouts.md](layouts.md)) is the editor with
this pane on its right.

| Command | What it does |
|---|---|
| Browser: Open URL… | A page in the pane. A full address stays as typed; `localhost:3000`, `host:3000` and IP addresses get `http://`; a name with a dot gets `https://`; anything else is a web search. |
| Browser: Test Report | The newest Playwright HTML report (or trace) of this project, served and shown in the pane. |
| Browser: Agent's Page | The page an agent's Playwright session is on, with its latest screenshot below the pane. |
| Browser: Go to Address… | In the page: another address or search (`RET` in the page's pane, or click the address on its header line). |

The pane's header line holds back, forward and reload buttons and the page's address. Click the address to go
elsewhere. Opening a page again reuses the pane. None of these commands has a key by default; they are in the palette.

## Needs WebKit

The pane is an `xwidget-webkit` session, which needs an Emacs built with WebKit (xwidgets). Without it, drgnx
opens every page in your system browser (`browse-url`) and says why once; the Browser layout shows a short note
instead of a page. Test Report and Agent's Page work the same way: they start the server and open the address, in
whichever browser applies.

## Test Report

**Browser: Test Report** looks in the project (not into `node_modules` or dot-directories) for the newest
`playwright-report/index.html` and the newest `trace.zip`, whichever changed last. A report is served by
`npx playwright show-report DIR --port 0`; a trace is opened with `npx playwright show-trace FILE --port 0`.
The server runs as a durable job named `playwright` (Show Job Log, Stop Job), so it lives on while you work; the page
opens in the pane as soon as the server prints its address. Running it again while the server runs reuses the
server; a server for another report or trace of the same project is stopped when the new one starts, and a server
that prints no address within a minute is stopped. If `npx` is missing, or there is no report or trace, a message says so; nothing prompts or waits.

## Agent's Page

**Browser: Agent's Page** reads the selected agent's tool calls (the agent in the chat you are in, or the only
session there is, else it asks) and takes the last one that navigated: a Playwright tool call with a `url` in its input.
It opens that page in the pane, and shows the latest image any tool of that agent returned (a Playwright
screenshot) in the side buffer `*drgnx: agent screenshot*`. An agent with no such call gets a message saying so.
This is the same page, not a live view: the agent's own browser is its own.

## For module authors

`drgnx-browser-open` takes a URL. `drgnx-browser-newest` returns the newest report or trace under a directory as
`(:kind report|trace :path PATH)`. `drgnx-browser-agent-url` and `drgnx-browser-agent-screenshot` read a session's tool
calls (each tool entry keeps the `:url` of its raw input, nothing else of it). The module registers the layouts shape `editor+browser`
in `drgnx-layouts-shapes`.

The GUI test `test/ui/editor-m11c1-test.el` shows the Browser layout without WebKit (a screenshot).
