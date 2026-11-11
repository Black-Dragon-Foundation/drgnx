# A Mac as a runner: the macOS host checks

A Mac runner (the user's own Mac, reached over ssh like any runner: `docs/develop/sleipnir.md`) is tested on a macOS
CI host, since the project has no Mac of its own. `runtime.yml`'s `mac-runner` job runs on demand only:

```
gh workflow run runtime.yml --ref <branch> -f only=rt-macrunner
```

The CI user (passwordless `sudo`) plays the hub. A fresh standard account, `drgnx-runner`, plays the runner: the job
creates it, turns Remote Login on, and lets a throwaway key (made in the job, never uploaded) log in to it over a
localhost `sshd`. Nobody is logged in to that account, as on a real Mac.

## The spikes (`spike.sh`)

| Step | What it decides |
|---|---|
| `up` | the account, Remote Login, the key; the runner root `~/.drgnx-runner.noindex` (mode 0700, excluded from Time Machine); whether the CI user has an Aqua session |
| `s1` | whether a job started over ssh outlives the link: a launchd job (`launchctl bootstrap user/<uid>` of a plist in the attempt folder) and the `setsid` launcher (`mrspike detach`), each through a stopped ssh master and killed sshd sessions; what `bootout` leaves of a job's children |
| `s3` | the memory watchdog prototype (`mrspike watch`): a 512 MiB grant against a job whose child left its session, the time from crossing the grant to every process dead, and the watchdog's own CPU idle and during a 16-way compile |
| `s2-ert`, `s2-build` | drgnx ERT selectors, then a Nidhogg build with Naglfar, as the runner account under the draft build profile (Gleipnir's Seatbelt base plus the build addition) |
| `denials` | every Seatbelt denial the unified log shows, counted by operation and path |

`s1` and `s3` are decided (a launchd job can't be bootstrapped from an ssh login's Background session: `bootstrap`
fails with error 5, so runners use the `setsid` launcher; the watchdog kills a job and its escaped child within 20 ms
of the grant, at under 1 % CPU) and run again only with `-f only='rt-macrunner rt-macrunner-all'`. `s2-ert` runs the
tests in their own session and stops them after 15 minutes with the session's process list and stacks. The job also
builds the Mac runner bundle (`drgnx build runner-bundle --target aarch64-apple-darwin`, signed) and runs sleipnir's
`darwin` rows, the probe's live read among them.

`mrspike.rs` is std only, built with a bare `rustc -O` on the host. The results land in the `mac-runner-spikes`
artifact (`results.md` and the logs).
