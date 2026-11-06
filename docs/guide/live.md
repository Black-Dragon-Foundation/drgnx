# Live view of the agents' browser

The Live view (module `tools/live`, needs the `websocket` package) is waiting for a later drgnx update. Until
then it only opens and says so.

## What changed

drgnx used to start one headless Chrome on your machine for agents and give its debugging port to the agents it
launched. That browser ran outside any sandbox, on your network, with the agent in full control of it, so it is gone:
Live: Start Browser for Agents and Live: Stop Browser for Agents no longer exist, and drgnx starts no browser and
passes no browser endpoint to agents. Agents' browsers now run inside their own sandboxes, behind the permissions of
the sandbox ([agent-browser.md](agent-browser.md)).

## What you can do now

| Command | What it does |
|---|---|
| Live: Watch Agents' Browser | Opens the buffer `*drgnx live*`, which says that watching an agent's browser arrives with a later update. |
| Live: Take Over / Hand Back | For the view's connection, which the update brings; nothing to take over yet. `C-c C-c` in the Live view. |

Both are in the palette; neither has a key by default apart from `C-c C-c` in the Live view. For a page an agent
visited, or a Playwright report after a run, see [browser.md](browser.md).

## What comes next

The view's screencast client (the tabs, the frames, taking over) is kept in the code as it was and is not connected
to anything; the later update replaces it with one that watches the browser inside an agent's sandbox.

The setting `drgnx-agents-start-env-names`, which names the variables an editor module may add to an agent, is now
empty by default ([agents.md](agents.md#what-modules-add-to-a-session)).
