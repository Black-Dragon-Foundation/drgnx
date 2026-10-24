;; Perf budgets (docs/develop/perf.md): (WORKLOAD PATH LIMIT), times in ms, memory in kB.
;; Fixed by the spec: frame p95 < 500 ms, a daemon's server ready < 1000 ms, modules < 1800 ms, RSS < 400 MB.
;; Input (set from the first measurements, 2026-10-17: p95 0.4–7.9 ms, max ≤ 25 ms): p95 within one 60 Hz frame
;; (16 ms), max 50 ms; redisplay p95 16 ms; GC while typing 100 ms; a GC pause p95 50 ms (spec).
;; Any hook function p95 2 ms (spec): judged by `drgnx test --perf --audit'.
((frames (:frame :p95) 500)
 (startup (:server_ms :p50) 1000)
 (startup (:modules_ms) 1800)
 (memory (:rss_kb) 409600)
 (typing (:input :p95) 16) (typing (:input :max) 50) (typing (:gc_ms) 100) (typing (:gc_pause :p95) 50)
 (scrolling (:input :p95) 16) (scrolling (:input :max) 50)
 (tabs (:input :p95) 16) (tabs (:input :max) 50)
 (explorer (:input :p95) 16) (explorer (:input :max) 50)
 (agent-typing (:input :p95) 16) (agent-typing (:input :max) 50)
 (agent-stream (:input :p95) 16) (agent-stream (:input :max) 50)
 ;; cockpit-cards: PROVISIONAL — the job-window rows renamed (M12f, the job window is the cockpit's), measured on a
 ;; busy machine; part C's close (C12) confirms them
 (cockpit-cards (:input :p95) 16) (cockpit-cards (:input :max) 50)
 (code-scrolling (:input :p95) 16) (code-scrolling (:input :max) 50)
 (typing-with-ghost (:input :p95) 16) (typing-with-ghost (:input :max) 50)
 (diff-scrolling (:input :p95) 16) (diff-scrolling (:input :max) 50)
 (replace-typing (:input :p95) 16) (replace-typing (:input :max) 50) (replace-typing (:slice_ms :max) 16)   ; the view draws while 10k matches stream (was a :timing unit test, PERF-MAC-1)
 ;; replace-retype (render pipeline Task 6): a view slice is 4 ms of rows plus the 8-row grain; 6 ms leaves the rest
 (replace-retype (:input :p95) 16) (replace-retype (:input :max) 50) (replace-retype (:slice_ms :max) 6)
 (live-view (:input :p95) 16) (live-view (:input :max) 50)
 (agent-settings-open (:draw_ms) 150) (agent-settings-open (:processes) 0)
 (remote-typing (:input :p95) 16) (remote-typing (:input :max) 50)
 (window-switch (:input :p95) 16) (window-switch (:input :max) 50)
 (redisplay (:redisplay :p95) 16)
 ;; typing-with-index (M10-1): PROVISIONAL.  p95 22 = worst of 3 runs (12.2, 17.2, 21.1), rounded up, measured at load 7-8
 ;; (busy machine; the p95 rose with the load).  The ruled target is typing's 16 ms: a quiet-machine run pins it.
 (typing-with-index (:input :p95) 22) (typing-with-index (:input :max) 50)
 ;; evil (Vim keys), M12d Task 13: the same budgets as the stack without it; the Explorer's keys within the bench's 8 ms.
 ;; PROVISIONAL: these are the values M12d's brief set, not derived from measurements.  Measured on a busy machine
 ;; (load 3-5), worst of 5 runs, all under them: typing-evil p95 13.0 / max 19.9, motions-evil 9.6 / 11.5,
 ;; explorer-evil 6.4 / 6.4 ms.  A quiet-machine run pins them (docs/develop/perf.md).
 ;; typing-evil p95 may also exceed typing p95 by at most 1 ms in the same run (`drgnx-perf-run--relative-fails').
 (typing-evil (:input :p95) 16) (typing-evil (:input :max) 50)
 (motions-evil (:input :p95) 16) (motions-evil (:input :max) 50)
 (explorer-evil (:input :p95) 8) (explorer-evil (:input :max) 50)
 ;; eat (2026-10-18, with the tools/terminal-eat module running, medians of the workload's three repeats, load 3-6; the
 ;; machine was never quiet): terminal-typing p95 1.9-6.4 ms over 16 runs (two above 5, at load 3.9 and 5.8), max 2.5-10.6;
 ;; terminal-output p95 4.2-8.0 (above 5.2 only at load 5.5 and above), max 5-49 with drgnx's early collection
 ;; (`drgnx-terminal-eat-gc-quiet', now `drgnx-gc-gap') over ten runs at load 2.7-6.2, 5-44 over five more at load 3.3-6.6.
 ;; terminal-typing's p95 and max rows are the worst measured, rounded up (p95 6.4 -> 7; max 12.5 in the first measurements -> 13);
 ;; terminal-output's p95 is the worst measured below load 5.5 (5.2), rounded up (the 7.9-8.0 came at load 5.5 and above).
 ;; terminal-output's max is PROVISIONAL: 50 ms is the ceiling, not a measurement (n=10 per arm, a busy machine).  The
 ;; collection no longer lands in a keystroke (that was the failure before: 3 of 10 runs over 50); what is left comes from
 ;; the length of eat's output batches (20-60 ms under load), not from GC: DEFERRED M12e-5-1.  See docs/develop/perf.md.
 (terminal-typing (:input :p95) 7) (terminal-typing (:input :max) 13)
 (terminal-output (:input :p95) 6) (terminal-output (:input :max) 50)
 ;; Glitnir (the compositor) P1, spec §9.2: the popup rows, judged by `--ab-env DRGNX_PERF_GLITNIR=on,off' on the judged
 ;; (Glitnir on) side at n >= 100 (`:compose' n = `(:compose :count)' over its rounds); hides included in popup-churn.
 ;; The popup-typing and popup-churn compose p95 rows are a known failure, GL-POPUP-CHURN-FULL-1 (GTK repaints the whole
 ;; root when a child frame maps or unmaps; fixed by MP-3): reported above 2 ms, failing only above spike (i)'s 4.42 ms
 ;; (popup-typing at 2880x1800 scale 2; the user's call, 2026-10-24).
 ;; The scroll-under-popup compose p95 row is a known failure too, GL-SCROLL-PAGE-COPY-1: each <next>/<prior> repaints
 ;; ~93 % of the root (4.8 M of 5.18 M device px at 2880x1800 scale 2), and that copy is 2.4-2.6 ms with or without the
 ;; popup (per key: 2.37 ms in scrolling, 2.61 with the eldoc-box; the popup adds 0.24 ms); the presenting thread,
 ;; where a scroll is a layer-offset change (design §9.2), removes it.  It fails only above the same A/B's scrolling
 ;; compose p95 + 1 ms (`:fails-above-row'; scrolling runs earlier in the run; the user's call, 2026-10-24).
 ;; scroll-full-window: measured only, no gate.  Stock input p95 / draw p95 (ms, 2026-10-21): 1080p s1 15.9/1.62,
 ;; 2880x1800 s2 21.2/3.47, 4K s1 35.1/5.78, 4K s2 26.7/5.37, 2880x1800 s1.5 26.9/5.91, 2560x1440 s1.25 26.8/5.56,
 ;; 1920x1080 s1.25 19.2/3.22.
 (popup-typing (:compose :compose-ms :p95) 2 :known GL-POPUP-CHURN-FULL-1 :fails-above 4.42)
 (popup-typing (:compose :compose-ms :max) 8) (popup-typing (:input :p95) 16)
 (popup-churn (:compose :compose-ms :p95) 2 :known GL-POPUP-CHURN-FULL-1 :fails-above 4.42)
 (popup-churn (:compose :compose-ms :max) 8) (popup-churn (:input :p95) 16)
 (scroll-under-popup (:compose :compose-ms :p95) 2 :known GL-SCROLL-PAGE-COPY-1
                     :fails-above-row (scrolling (:compose :compose-ms :p95)) :by 1)
 (scroll-under-popup (:compose :compose-ms :max) 8)
 (scroll-under-popup (:input :p95) 16)
;; Gated budgets (Task 16 of the determinism plan), seeded 2026-10-20 from two runs of the perf tier in the Emacs 31.1 GUI
;; container (source, not built: compiled code allocates less): :alloc :p50 = the larger of the runs x 1.25, rounded up;
;; :rows = exact (equal in both runs); :cpu_ms :p90 = the larger of the runs' p90 x 2 (scaled by DRGNX_PERF_CPU_FACTOR; 2
;; on hosted runners).  The CPU rows of the typing workloads are large because about one key in ten spends 100-200 ms of
;; CPU in these runs (DEFERRED PERF-KEYSPIKE-1); they tighten when that is fixed.  Workloads that could not run in the
;; container are in `drgnx-perf-run-unseeded'.  Raise a row only in the commit that needs it, with the reason.
;; replace-typing :alloc :p50 41340 = 33072 x 1.25 (CI's GUI-container run of 83e460be; the seed run was 25252): the number is
;; timing-coupled, not a code cost (docs/develop/perf.md, "Allocation that follows the wall clock").
;; :cpu_ms :p50 (typing, typing-with-ghost, remote-typing) ~30 ms: a normal key, which the p90 (the 1-in-10 spike, PERF-KEYSPIKE-1) does not gate.
 (typing (:alloc :p50) 13757) (typing (:cpu_ms :p50) 30) (typing (:cpu_ms :p90) 420.1) (typing (:rows) 1)
 (scrolling (:alloc :p50) 14840) (scrolling (:cpu_ms :p90) 28.4) (scrolling (:rows) 0)
 (tabs (:alloc :p50) 6234) (tabs (:cpu_ms :p90) 11.2) (tabs (:rows) 0)
 (explorer (:alloc :p50) 5115) (explorer (:cpu_ms :p90) 6.0) (explorer (:rows) 0)
 (agent-typing (:alloc :p50) 15008) (agent-typing (:cpu_ms :p90) 23.1) (agent-typing (:rows) 1)
 (code-scrolling (:alloc :p50) 15439) (code-scrolling (:cpu_ms :p90) 26.9) (code-scrolling (:rows) 0)
 (diff-scrolling (:alloc :p50) 6027) (diff-scrolling (:cpu_ms :p90) 26.7) (diff-scrolling (:rows) 0)
 (typing-with-ghost (:alloc :p50) 18385) (typing-with-ghost (:cpu_ms :p50) 30) (typing-with-ghost (:cpu_ms :p90) 402.9) (typing-with-ghost (:rows) 1)
 (replace-typing (:alloc :p50) 41340) (replace-typing (:cpu_ms :p90) 183.7) (replace-typing (:rows) 1)
 ;; replace-retype seeded 2026-10-20 from two GUI-container runs at --cpus 2 (alloc 4097 / 4097, cpu p90 4.97 / 5.93,
 ;; rows 0 / 0; a third at --cpus 1 gave 4097, 6.22, 0): the keys only edit the field, the rows are patched by timers
 (replace-retype (:alloc :p50) 5122) (replace-retype (:cpu_ms :p90) 11.9) (replace-retype (:rows) 0)
 (remote-typing (:alloc :p50) 17300) (remote-typing (:cpu_ms :p50) 30) (remote-typing (:cpu_ms :p90) 349.0) (remote-typing (:rows) 1)
 (window-switch (:alloc :p50) 29638) (window-switch (:cpu_ms :p90) 43.6) (window-switch (:rows) 0))
