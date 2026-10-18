# Live view of the agents' browser

Watch the browser your agents drive, live, and take it over when you need to (module `tools/live`, needs the
`websocket` package). It works in any graphical Emacs; it needs no WebKit. For a page an agent visited, or a
Playwright report after a run, see [browser.md](browser.md).

| Command | What it does |
|---|---|
| Live: Start Browser for Agents | Starts one headless Chrome (or Chromium) for agents. Agents drgnx starts from now on drive it. |
| Live: Watch Agents' Browser | The page of that browser, live, in the buffer `*drgnx live*` (starts the browser if it is not running). |
| Live: Take Over / Hand Back | Your clicks, scrolling and typing go to the page, and the agent is told to wait; run it again to hand back. `C-c C-c` in the Live view. |
| Live: Stop Browser for Agents | Stops that browser and deletes its profile. |

Apart from `C-c C-c` in the Live view, these commands have no keys by default; they are in the palette.

## The browser for agents

drgnx starts the browser as a durable job named `live-browser` (Show Job Log, Stop Job), once per Emacs session:

- headless, with `--remote-debugging-address=127.0.0.1 --remote-debugging-port=0`: the debugging port is on this
  machine only, and a random one;
- with a throwaway profile, `live-profile-<pid>` under drgnx's state directory: none of your logins or cookies. It
  is deleted when you stop the browser or quit Emacs; a profile left by an Emacs that crashed is cleaned up (its
  browser stopped) the next time a browser for agents starts;
- capped at 1 GiB of memory (where jobs run under systemd).

The first of `google-chrome`, `google-chrome-stable`, `chromium`, `chromium-browser` and `chrome` on your `PATH` is
used (on macOS also the Chrome and Chromium apps); set `drgnx-live-chrome-programs` to change the list.

Agents drgnx starts while the browser runs get `PLAYWRIGHT_MCP_CDP_ENDPOINT=http://127.0.0.1:PORT` in their
environment, so the Playwright MCP server connects to this browser instead of launching its own. The endpoint gives
full control of that one browser to local processes; that is why it listens on 127.0.0.1 only, on a random port,
with a throwaway profile.

**Not live:** agents started before the browser, agents started outside this Emacs (also those a hub runs), and
`npx playwright test` runs, which launch their own browsers. Use Browser: Agent's Page and Browser: Test Report for
those.

## The Live view

The view shows the page through Chrome DevTools Protocol screencast frames (JPEG, quality 60, as wide as the
window), about ten a second. Frames are drawn from a timer, never while you type; a frame that arrives before the
last one was drawn replaces it, so a busy Emacs drops frames and never queues them. Every frame is acknowledged.

The header line lists the browser's tabs (the watched one in bold) and the watched page's address. When the agent
opens a new tab, the view follows it; when the watched tab closes, it shows another one.

Below the page, the view says what is wrong when something is:

- **No Chrome or Chromium:** the command stops with a message naming the programs it looked for.
- **The browser exits at start or does not open its port** (10 s): a message with the end of its log.
- **The port refuses the connection,** or the browser goes away while you watch: the view says so; `g` connects
  again, and Live: Start Browser for Agents starts a new browser.
- **An agent that does not use this browser:** a running agent started before it (or outside this Emacs) is named,
  and so is an agent whose Playwright opened a page that no tab here shows: its MCP may not read
  `PLAYWRIGHT_MCP_CDP_ENDPOINT`.

Nothing here prompts or waits for the browser, except starting it (Start, or Watch when it is not running), which
waits up to 10 s for its port (`C-g` stops the wait).

## Taking over

**Live: Take Over / Hand Back** (`C-c C-c` in the view) marks the view **DRIVING**. While it is on:

- mouse clicks (left, middle, right, double) and the wheel on the page go to it as `Input.dispatchMouseEvent`, at
  the point you clicked: the coordinates are scaled back from the image's size on screen to the page's;
- printable characters, `RET`, `TAB`, Backspace, Delete, Escape, the arrows, Home, End, PgUp and PgDn go to it as
  `Input.dispatchKeyEvent`; `C-…` and `M-…` keys stay Emacs's, so the palette and `C-c C-c` still work.

Taking over steers every busy agent using this browser with "the user is driving the browser; wait" (through the
agent's usual steering, or queued for the end of its turn when it cannot be steered); handing back steers "the user
handed the browser back". Idle agents are not sent anything.

## For module authors

`drgnx-live-browser` returns `(:port N :ws URL)`, starting the browser when it is not running. Agent environments
are extended through `drgnx-agents-env-functions` (in `core/drgnx-agents.el`): each function gets the session and
returns extra `NAME=value` strings. The tests talk to a CDP stand-in, `test/fixtures/mock-cdp.el`, never to Chrome.
