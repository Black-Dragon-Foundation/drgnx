;; Perf budgets (docs/develop/perf.md): (WORKLOAD PATH LIMIT), times in ms, memory in kB.
;; Fixed by the spec: frame p95 < 500 ms, a daemon's server ready < 1000 ms, modules < 1800 ms, RSS < 400 MB.
;; Input (set from the first measurements, 2026-10-17: p95 0.4–7.9 ms, max ≤ 25 ms): p95 within one 60 Hz frame
;; (16 ms), max 50 ms; redisplay p95 16 ms; GC while typing 100 ms; a GC pause p95 50 ms (spec).
;; Any hook function p95 2 ms (spec): judged by `drgnx test --perf --audit'.
;; A row may end in `:report-only STEP': it is reported, never failed, until $DRGNX_PERF_LANDED names STEP (the workers'
;; rows, Task 8; docs/develop/perf.md, "The workers probe").
((frames (:frame :p95) 500)
 (startup (:server_ms :p50) 1000)
 (startup (:modules_ms) 1800)
 (memory (:rss_kb) 409600)
 (typing (:input :p95) 16) (typing (:input :max) 50) (typing (:gc_ms) 100) (typing (:gc_pause :p95) 50)
 (scrolling (:input :p95) 16) (scrolling (:input :max) 50)
 (tabs (:input :p95) 16) (tabs (:input :max) 50)
 (explorer (:input :p95) 16) (explorer (:input :max) 50)
 (agent-typing (:input :p95) 16) (agent-typing (:input :max) 50)
 (code-scrolling (:input :p95) 16) (code-scrolling (:input :max) 50)
 (typing-with-ghost (:input :p95) 16) (typing-with-ghost (:input :max) 50)
 (diff-scrolling (:input :p95) 16) (diff-scrolling (:input :max) 50)
 ;; graphical debugging's breakpoint column (300 marks while scrolling; F9 on 20 lines): input within a frame
 (debug-gutter-scroll (:input :p95) 16) (debug-gutter-scroll (:input :max) 50)
 (debug-breakpoint-click (:input :p95) 16) (debug-breakpoint-click (:input :max) 50)
 (live-view (:input :p95) 16) (live-view (:input :max) 50)
 (agent-settings-open (:draw_ms) 150) (agent-settings-open (:processes) 0)
 ;; the unified settings layer (design 16): read+apply of a 200-entry settings.el 2 ms; the page open 100 ms and a search
 ;; keystroke (worst of the typed name) 16 ms over 5,000 settings; provenance 5 % of a 500-line config.el's load; the
 ;; index of 200 packages 2 s; a file open with the workspace and language layers in against out, per open
 (settings-start (:read_ms) 2)
 (settings-page (:open_ms) 100) (settings-page (:key_max_ms) 16)
 (settings-prov (:prov_pct) 5)
 (settings-sync (:index_ms) 2000)
 (settings-open (:delta_ms) 1)
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
 ;; terminal-typing and terminal-output were first measured on the terminal backend drgnx had before its own (2026-10-18,
 ;; medians of three repeats, load 3-6): terminal-typing p95 1.9-6.4 ms over 16 runs, max 2.5-10.6; terminal-output p95 4.2-8.0.
 ;; terminal-typing's p95 and max rows are the worst measured, rounded up (p95 6.4 -> 7; max 12.5 -> 13); terminal-output's p95
 ;; is the worst measured below load 5.5 (5.2), rounded up.  See docs/develop/perf.md.
 (terminal-typing (:input :p95) 7) (terminal-typing (:input :max) 13)
 (terminal-output (:input :p95) 6)
 ;; drgnx's terminal (the Ghostty design, §8), targets not measurements: judged at the combined gate pass on the desktop
 ;; island.  terminal-echo is end to end (:echo_ms: a key's send to the draw that shows its echo) with 30 agents
 ;; streaming and a flood in a second terminal, on one hub; the flood rows are `cat' of 10 MB and 100 MB; input max under the
 ;; seq loop is 16.  terminal-typing's allocation per key and the 10k terminal's heap
 ;; (terminal-backfill :heap_kb) are recorded first, not gated.
 (terminal-output (:input :max) 16)
 (terminal-echo (:echo_ms :p95) 8) (terminal-echo (:echo_ms :max) 16)
 (terminal-output-10mb (:wall_ms) 250) (terminal-output-10mb (:alloc_rate) 2) (terminal-output-10mb (:draw_kb :p50) 40)
 (terminal-output-10mb (:slice_ms :max) 4)
 (terminal-output-100mb (:alloc_rate) 2) (terminal-output-100mb (:draw_kb :p50) 40) (terminal-output-100mb (:slice_ms :max) 4)
 (terminal-backfill (:slice_ms :max) 4)
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
 ;; on hosted runners).  Workloads that could not run in the container are in `drgnx-perf-run-unseeded'.  Raise a row only
 ;; in the commit that needs it, with the reason.
 ;; The typing workloads' CPU rows (typing, typing-with-ghost, remote-typing) were 350-420 ms at p90 while one key in ten
 ;; spent 100-200 ms (the typing fixture's open list scanned to the end of the file, and Nidhogg's full redisplay after an
 ;; insertion, both fixed).  Seeded again 2026-11-05 from two source runs in the GUI container on the desktop island
 ;; (4 CPUs, Nidhogg 31.1-nidhogg.5): cpu p50 3.9 / 5.9, 4.0 / 6.0, 3.9 / 4.0 ms and p90 5.1 / 7.8, 5.2 / 8.4, 5.2 / 5.3
 ;; ms; the rows are the larger run x 2, rounded up, so a key spike fails the run again.
 (typing (:alloc :p50) 13757) (typing (:cpu_ms :p50) 12) (typing (:cpu_ms :p90) 16) (typing (:rows) 1)
 (scrolling (:alloc :p50) 14840) (scrolling (:cpu_ms :p90) 28.4) (scrolling (:rows) 0)
 (tabs (:alloc :p50) 6234) (tabs (:cpu_ms :p90) 11.2) (tabs (:rows) 0)
 ;; explorer on the hub's rows (plan sja-complete F1, 2026-11-11, pinned, release hub, 3 runs): alloc p50 3286 in each
 ;; (the Lisp listing's was 2509: Sjá's navigation and the tail repaint, docs/develop/perf.md), x 1.25
 (explorer (:alloc :p50) 4108) (explorer (:cpu_ms :p90) 6.0) (explorer (:rows) 0)
 (agent-typing (:alloc :p50) 15008) (agent-typing (:cpu_ms :p90) 23.1) (agent-typing (:rows) 1)
 (code-scrolling (:alloc :p50) 15439) (code-scrolling (:cpu_ms :p90) 26.9) (code-scrolling (:rows) 0)
 (diff-scrolling (:alloc :p50) 6027) (diff-scrolling (:cpu_ms :p90) 26.7) (diff-scrolling (:rows) 0)
 (typing-with-ghost (:alloc :p50) 18385) (typing-with-ghost (:cpu_ms :p50) 12) (typing-with-ghost (:cpu_ms :p90) 17) (typing-with-ghost (:rows) 1)
 ;; replace-typing-rows: typing while the hub searches and streams the rows (its old-path pair, replace-typing, and
 ;; replace-retype went with the Search view's old path, plan sja-complete S2).  alloc 4134 is the render offload's
 ;; target, a tenth of replace-typing's 41340; measured once (2026-11-08, Nidhogg's line image, pinned to 4 CPUs): 5996 objects
 ;; per command (replace-typing in the same session: 6073, the 41340 follows a slow runner's wall clock), cpu p90 3.21 ms, rows 1.
 ;; All three are report-only until the combined pass reads them.
 (replace-typing-rows (:alloc :p50) 4134 :report-only rro-scan) (replace-typing-rows (:cpu_ms :p90) 4.0 :report-only rro-scan)
 (replace-typing-rows (:rows) 1 :report-only rro-scan)
 ;; The whole operation, from the first key to the last row applied (`:complete-kb`, `:complete-cpu_ms`: this process's
 ;; allocation and CPU, the stream's `accept-process-output` included; the per-key rows above stay, report-only).
 ;; Measured once each, old path and hub path in one session (2026-11-08, Nidhogg's line image, 4 CPUs), x 1.25.
 ;; replace-typing (old path) 76189 kB, 391 ms.  replace-typing-rows: 200012 kB, 2887 ms before the hub sent a window of
 ;; the rows (`search/grep-look`) and the model as it doubles; 17771 kB, 353 ms after.
 ;; Model lists as splices and the line height once per pass (2026-11-08, pinned, +nidhogg-workers-framing, three runs): 15249-15410 kB,
 ;; 330-337 ms; the budgets sit at 16800 kB (10 % over, so a return to 17771 fails) and 400 ms.  Without framing (the default until
 ;; gate 26) the same run is 26910 kB, 448 ms, so these rows stay report-only until the combined pass decides the path.
 (replace-typing-rows (:complete-kb) 16800 :report-only rro-scan) (replace-typing-rows (:complete-cpu_ms) 400 :report-only rro-scan)
 ;; The model's lag (a model line's arrival to its drain; plan sja-complete D3, re-measured 2026-11-11 after the pushed
 ;; path, pinned, release hub): p50 20-21.5 ms, x 1.25.  The cadence's bar is one throttle (100 ms).
 (replace-typing-rows (:model_lag_ms :p50) 27 :report-only ot5)
 ;; search-retype: retyping the Search view's query over 10k matches on the hub's rows path, a search per key (plan
 ;; sja-complete S2, the hub-path pair of the retired replace-retype): its keys within the input budget; what the user
 ;; sees: a search's first rows drawn within 50 ms of its start (115 ms while a quiet view's first draw waited the whole
 ;; throttle; 33-35 ms p95 after it waits one frame, 2026-11-10, release hub, pinned, two runs), and the key to the
 ;; search's end with its rows drawn (the 250 ms typing pause included): 337-356 ms p95 then, x 1.25
 (search-retype (:input :p95) 16) (search-retype (:input :max) 50)
 (search-retype (:search_first_ms :p95) 50) (search-retype (:settle_ms :p95) 450)
 ;; search-context: the Search view's context label rows cost at most 10 % on the first rows and 15 % to the end, the
 ;; p50s of 10 searches with labels over 10 without (100 Rust files, 10k matches, 1,000 labels; spec §8)
 (search-context (:first_ratio) 1.10) (search-context (:done_ratio) 1.15)
 ;; search-pattern: the Search view's Pattern toggle over 1,000 Rust files narrowed to 100 by the pattern's name
 ;; (1,000 matches): the first rows within 300 ms and the end within 2 s (spec §8, search view plan A6)
 (search-pattern (:first_ms :p95) 300) (search-pattern (:done_ms :p95) 2000)
 ;; search-lists: the empty Search view's saved (100, 10 pinned) and recent (50) searches drawn within 5 ms (spec §8)
 (search-lists (:draw_ms :p95) 5)
 ;; work-board: 40 moves over a Board of 200 cards on the hub's rows path (plan sja-complete B1).  Its allocation is held
 ;; to its old-path pair's, work-board-old (4750-4752 objects a key; the rows path 1932-1944 before and after the bar,
 ;; 2026-11-10, pinned, two runs each); cpu p90 6.8-11.5 ms (the most, 11.48, before the bar), x 1.25
 (work-board (:input :p95) 16) (work-board (:alloc :p50) 4750) (work-board (:cpu_ms :p90) 14.4) (work-board (:rows) 0)
 (remote-typing (:alloc :p50) 17300) (remote-typing (:cpu_ms :p50) 8) (remote-typing (:cpu_ms :p90) 11) (remote-typing (:rows) 1)
 (window-switch (:alloc :p50) 29638) (window-switch (:cpu_ms :p90) 43.6) (window-switch (:rows) 0)
 ;; Watchdog rows, REPORTED until seeded (`drgnx-perf-watchdog-gated'): no stall in any input
 ;; workload; a collection at most 250 ms; the GC p95 at most 50 ms, judged only over >= 20 collections.
 ;; (:typing :ge16) and (:heap :live_mb) are reported without a budget (the heap row is gated separately).
 (typing (:stalls) 0) (typing (:gc :max) 250) (typing (:gc :p95) 50)
 (scrolling (:stalls) 0) (scrolling (:gc :max) 250) (scrolling (:gc :p95) 50)
 (tabs (:stalls) 0) (tabs (:gc :max) 250) (tabs (:gc :p95) 50)
 (explorer (:stalls) 0) (explorer (:gc :max) 250) (explorer (:gc :p95) 50)
 (agent-typing (:stalls) 0) (agent-typing (:gc :max) 250) (agent-typing (:gc :p95) 50)
 (code-scrolling (:stalls) 0) (code-scrolling (:gc :max) 250) (code-scrolling (:gc :p95) 50)
 (typing-with-ghost (:stalls) 0) (typing-with-ghost (:gc :max) 250) (typing-with-ghost (:gc :p95) 50)
 (diff-scrolling (:stalls) 0) (diff-scrolling (:gc :max) 250) (diff-scrolling (:gc :p95) 50)
 (live-view (:stalls) 0) (live-view (:gc :max) 250) (live-view (:gc :p95) 50)
 (remote-typing (:stalls) 0) (remote-typing (:gc :max) 250) (remote-typing (:gc :p95) 50)
 (window-switch (:stalls) 0) (window-switch (:gc :max) 250) (window-switch (:gc :p95) 50)
 (typing-with-index (:stalls) 0) (typing-with-index (:gc :max) 250) (typing-with-index (:gc :p95) 50)
 (typing-evil (:stalls) 0) (typing-evil (:gc :max) 250) (typing-evil (:gc :p95) 50)
 (motions-evil (:stalls) 0) (motions-evil (:gc :max) 250) (motions-evil (:gc :p95) 50)
 (explorer-evil (:stalls) 0) (explorer-evil (:gc :max) 250) (explorer-evil (:gc :p95) 50)
 (terminal-typing (:stalls) 0) (terminal-typing (:gc :max) 250) (terminal-typing (:gc :p95) 50)
 (terminal-output (:stalls) 0) (terminal-output (:gc :max) 250) (terminal-output (:gc :p95) 50)
 ;; The off-the-main-thread workloads (Task 8; off-the-main-thread design §17.6, harness/drgnx-perf-workloads.el).  Every
 ;; budget is the design's table (V2 §1: 16 ms a key, 50 ms the worst key, 100 ms a stall; or drgnx's existing row), fixed
 ;; here, never taken from a first run.  Report-only until the step that moves the work lands (DRGNX_PERF_LANDED names it).
 ;; :stalls-ge16 / :stalls-ge100 count the watchdog's stalls (DRGNX_PERF_WATCHDOG=16 or on for the 16 ms ones); :ts, :lsp, :image
 ;; and :expand_ms are the workload's own measures.
 (lsp-burst (:input :p95) 16 :report-only ot4) (lsp-burst (:stalls-ge16) 0 :report-only ot4)
 (lsp-burst (:lsp :handler_ms :max) 50 :report-only ot4)       ; a response's handler within 50 ms of its last byte
 (lsp-typing (:input :p95) 16 :report-only ot4) (lsp-typing (:input :max) 50 :report-only ot4)
 (ts-open (:ts :draw_ms) 16 :report-only ot2)                  ; first draw within one frame of the visit's end
 (ts-open (:ts :colored_ms) 500 :report-only ot2)              ; last visible region coloured within 500 ms
 (ts-open (:stalls-ge100) 0 :report-only ot2)
 (ts-paste (:input :p95) 16 :report-only ot2) (ts-paste (:complete-ms) 300 :report-only ot2)
 (ts-typing (:input :p95) 16 :report-only ot2) (ts-typing-unclosed (:input :p95) 16 :report-only ot2)
 (compile-flood (:input :p95) 16 :report-only ot3) (compile-flood (:input :p99) 50 :report-only ot3)
 (compile-flood (:input :max) 50 :report-only ot3)
 (image-open (:stalls-ge16) 0 :report-only ot6)
 (image-open (:image :screenshot_ms) 16 :report-only ot6)      ; first draw within one frame
 (image-open (:image :preview_drawn_ms) 500 :report-only ot6)  ; every picture drawn within 500 ms
 ;; explorer-expand on the hub's rows (plan sja-complete F1 gate: the first file's row within the key's own frame, 10 ms;
 ;; 2026-11-11, pinned, release hub, 3 runs: 4.5, 4.6, 4.3 ms; alloc p50 6565-6670, cpu p90 3.6-3.8: no rows for them
 ;; while it is in `drgnx-perf-run-unseeded' (its step ot8 seeds all three))
 (explorer-expand (:expand_ms) 10 :report-only ot8) (explorer-expand (:stalls-ge16) 0 :report-only ot8)
 (explorer-git-rows (:input :p95) 16 :report-only ot5) (explorer-git-rows (:stalls-ge16) 0 :report-only ot5)
 ;; The render offload's rows (measured x 1.25, rounded up; :rows exact): one source run, GUI container on the desktop,
 ;; 2026-11-07, with Nidhogg's framing and the worktree's test-hooks hub.  explorer-git (the Lisp listing's, gone with
 ;; the Explorer's switch to the hub's rows, plan sja-complete E4): alloc 6844, cpu p90 4.06, rows 1.  quick-open-typing
 ;; (the hub's ranked rows) alloc 3924, cpu 1.1; -old (the stream and completion over 200k names) alloc 6403046, cpu
 ;; 218.63, a key 212 ms at p50.  agents-line-motion (the outline's name) alloc 5495, cpu 3.53; -old
 ;; (`add-log-current-defun' per frame) 5838, 4.15.
 ;; explorer-git-rows (the hub reads the status; the letters are its rows): alloc 856 is a tenth of explorer-git's 8555, the render
 ;; offload's target; measured once (2026-11-08, Nidhogg's line image, 4 CPUs, same session): 6542 objects per command against 6589
 ;; on the old path (the keys are what allocates), cpu p90 3.1, rows 1.  Report-only until the combined pass.
 ;; The target is reset: 856 (a tenth of explorer-git's 8555) was seeded before git status was framed in every locale, when
 ;; the old path cost 10281; the real old-path numbers are 6574 to 6589 objects per command, and the hub path cannot go
 ;; far below them (the key command and redisplay are the cost, the rows are few).  The target is the measured 6542 x 1.25.
 ;; Again on the Explorer's rows path (plan sja-complete F1, 2026-11-11, pinned, release hub, 3 runs): alloc p50 6684-6685,
 ;; cpu p90 3.5-3.7, complete 674-737 kB and 51-64 ms; x 1.25 here and in the two `complete' rows below.
 (explorer-git-rows (:alloc :p50) 8357 :report-only ot5) (explorer-git-rows (:cpu_ms :p90) 4.7 :report-only ot5)
 (explorer-git-rows (:rows) 1 :report-only ot5)
 ;; explorer-git, the whole operation (first key to the letters applied), same session: old path 1549 kB, 47 ms; hub path
 ;; 1640 kB, 54 ms (x 1.25 below).  The hub path is no cheaper here: the rows are few (52 for the 25k-file repository) and
 ;; the cost is the key and its redisplay.
 (explorer-git-rows (:complete-kb) 922 :report-only ot5) (explorer-git-rows (:complete-cpu_ms) 80 :report-only ot5)
 ;; explorer-watch: 50 files made in a folder the Explorer shows, on the hub's rows path (plan sja-complete E1): every row
 ;; drawn within 300 ms of the last write (the hub settles 30-100 ms, then relists the one folder); the design's bar, not
 ;; the measure x 1.25 (2026-11-11, pinned, release hub: 52.2-52.5 ms), since a wall-clock settle on a loaded host varies
 (explorer-watch (:settle_ms) 300)
 ;; trail-long and search-window: a key that pages into the hub's next window (plan sja-complete W1, S1; 2026-11-11,
 ;; pinned, release hub): trail-long page p50 18.4, max 19.0 ms; search-window page p50 24.6, max 29 ms with no
 ;; collection in it; x 1.25.  The design bars (perf.md: key p95 16, page p95 50) hold above them.
 (trail-long (:key_ms :p95) 16 :report-only ot5) (trail-long (:page_ms :p95) 24 :report-only ot5)
 (trail-long (:list_max) 500 :report-only ot5)
 (search-window (:page_nogc_ms :p95) 37 :report-only ot5) (search-window (:list_max) 20000 :report-only ot5)
 (quick-open-typing (:alloc :p50) 4905 :report-only ot5) (quick-open-typing (:cpu_ms :p90) 1.4 :report-only ot5)
 (quick-open-typing (:rows) 0 :report-only ot5)
 (quick-open-typing-old (:alloc :p50) 8003808 :report-only ot5)
 (quick-open-typing-old (:cpu_ms :p90) 273.3 :report-only ot5) (quick-open-typing-old (:rows) 0 :report-only ot5)
 (agents-line-motion (:alloc :p50) 6869 :report-only ot5) (agents-line-motion (:cpu_ms :p90) 4.5 :report-only ot5)
 (agents-line-motion (:rows) 0 :report-only ot5)
 (agents-line-motion-old (:alloc :p50) 7298 :report-only ot5)
 (agents-line-motion-old (:cpu_ms :p90) 5.2 :report-only ot5) (agents-line-motion-old (:rows) 0 :report-only ot5)
 ;; presence-burst, 2026-11-08, pinned to 4 CPUs, 30 agents over 90 files, one change per key.  Before (-old: every
 ;; `agent-presence' event rebuilds the badges, who is here and the status from the cached presence): alloc p50 160832
 ;; objects per key, cpu p90 3.61.  After (the hub's view model, read node by node as the rows name them): alloc p50
 ;; 11832, cpu p90 1.31 (the rows alone, before the model: 10747, 1.11); both 30 agents and 98 badges.  The alloc
 ;; budget is a tenth of before; cpu the rows' 1.11 x 1.25.
 (presence-burst (:alloc :p50) 16084 :report-only ot5) (presence-burst (:cpu_ms :p90) 1.4 :report-only ot5)
 (presence-burst (:rows) 0 :report-only ot5)
 (presence-burst-old (:alloc :p50) 201040 :report-only ot5)
 (presence-burst-old (:cpu_ms :p90) 4.6 :report-only ot5) (presence-burst-old (:rows) 0 :report-only ot5)
 ;; panel-replay, 2026-11-08, pinned to 4 CPUs.  Before (the panel drawing every row in Lisp, the mirror copying its
 ;; transcript per update): alloc p50 20292 (p90 24118) per update, a draw 14.75 kB p50 (63.03 p90), 305 updates over
 ;; 2024 entries, 2560 lines.  After (the hub's rows, the mirror patched in place): alloc p50 98 (p90 323) per update
 ;; over 410 updates (272 of them row patches), 1956 entries, 1956 hub rows, 2152 lines.  The alloc budget is a tenth of
 ;; before.  draw_kb stays at before's: after, the draws ran as 5 slice chains of about 76 kB (only a chain's first slice
 ;; is counted), so it is read in the combined pass.  panel-replay-old (`drgnx-view-old-path`, the paired row): alloc p50
 ;; 20293 (p90 24144), a draw 14.82 kB p50, 305 updates.
 (panel-replay (:alloc :p50) 2030 :report-only ot5) (panel-replay (:draw_kb :p50) 18.5 :report-only ot5)
 (panel-replay-old (:alloc :p50) 25367 :report-only ot5) (panel-replay-old (:draw_kb :p50) 18.5 :report-only ot5)
 (quick-open-large (:complete-ms) 100 :report-only ot5)        ; first candidates within 100 ms
 (quick-open-large (:stalls-ge16) 0 :report-only ot5)
 (autosave-typing (:input :max) 50 :report-only ot8) (autosave-typing (:complete-ms) 1000 :report-only ot8)
 ;; The Extensions view (design §13; harness/drgnx-perf-extensions.el): open 100 ms with no process, a search key 16 ms
 ;; worst and 8 ms p50 over 7,150 rows, the details page 50 ms, the progress reads at most 4 a second (no two under
 ;; 240 ms apart, the last write always read) with typing's p95 within 1 ms of idle, live activation 20 ms, install overhead 3 s.  PROVISIONAL: reported, never failed, until
 ;; $DRGNX_PERF_LANDED names `ext-pass' (the combined gate pass judges them).  The scroll key's 16 ms is the input rule's;
 ;; the 1 ms of typing is a first guess.  refresh-job and list-packages-compare report with no budget (the view must beat
 ;; the package menu on each of its numbers: the :beats_* flags).  The hub's catalog-load and search are the Rust bench.
 (extensions-open (:open_ms) 100 :report-only ext-pass) (extensions-open (:processes) 0 :report-only ext-pass)
 (extensions-search (:key_p50_ms) 8 :report-only ext-pass) (extensions-search (:key_max_ms) 16 :report-only ext-pass)
 (extensions-scroll (:key_max_ms) 16 :report-only ext-pass)
 (extensions-details (:open_ms) 50 :report-only ext-pass)
 (extensions-progress (:reads_too_close) 0 :report-only ext-pass) (extensions-progress (:last_unread) 0 :report-only ext-pass)
 (extensions-progress (:typing_delta_ms) 1 :report-only ext-pass)
 ;; The list on the rows path (the hub's rows and model), 2026-11-08, pinned to 4 CPUs: a tenth of the old path's
 ;; objects on open (167507 for 200 rows) and per job step (the file read's 2624; on the rows path the event's).
 ;; Measured on the rows path: 119930 on open (404 lines: the rows and their summaries), 2073 per step.
 (extensions-open (:alloc) 16751 :report-only ext-pass) (extensions-progress (:alloc_event_step) 262 :report-only ext-pass)
 (activate-live (:activate_ms) 20 :report-only ext-pass)   ; the plan step's repoint of 40 packages
 (activate-live-new (:activate_ms) 20 :report-only ext-pass)   ; a job's end that added a package: it is activated
 (install-overhead (:overhead_ms) 3000 :report-only ext-pass)
 ;; The Work space (design §13; docs/develop/perf.md, "The Work space's workloads"): 30 streaming mock agents in a real
 ;; hub.  The rules between workloads (the map shown at most 1 ms over hidden; the mirror at most 1 ms over `typing')
 ;; are `drgnx-perf-run--relative-fails'.  The Rust rows (vegvisir layout, shell parse, trace) are their crates' tests.
 (work-nav (:input :p95) 16) (work-nav (:frame_kb) 2048) (work-nav (:stalls) 0)
 (work-raster (:raster_ms :p95) 1.5) (work-raster (:chain_ms :max) 6)
 (work-relayout (:relayout :p95) 50) (work-relayout (:stalls) 0)
 (work-live (:draw_ms_s) 40) (work-live (:slice_ms :max) 4) (work-live (:stalls) 0)
 ;; The map on the hub's rows (render offload; read in the combined pass).  work-live's draw is at most 40 kB p50 (it was
 ;; 831 kB, Lisp drawing the frames); work-live-old (`drgnx-view-old-path`, the paired row) reports the same rows.  The
 ;; work-nav and work-relayout allocations are a tenth of as2-fix's (2026-11-07, b1: work-nav p50 11191 objects per key,
 ;; work-relayout p50 128420); their CPU (b1: p90 11.31 and 59.16 ms) and rows (0) are kept as measured.  Both
 ;; workloads still drive the old path (Sjá's keys are `work-nav-rows').
 (work-live (:draw_kb :p50) 40 :report-only ot5) (work-live-old (:draw_kb :p50) 40 :report-only ot5)
 (work-live-old (:slice_ms :max) 4 :report-only ot5) (work-live-old (:draw_ms_s) 40 :report-only ot5)
 (work-nav (:alloc :p50) 1119 :report-only ot5) (work-nav (:cpu_ms :p90) 11.31 :report-only ot5)
 (work-nav (:rows) 0 :report-only ot5)
 (work-relayout (:alloc :p50) 12842 :report-only ot5) (work-relayout (:cpu_ms :p90) 59.16 :report-only ot5)
 (work-relayout (:rows) 0 :report-only ot5)
 (work-typing-shown (:input :p95) 16) (work-typing-shown (:stalls) 0)
 (work-typing-hidden (:input :p95) 16) (work-typing-hidden (:stalls) 0)
 (work-trail (:draw_ms) 100) (work-trail (:append_ms :max) 1)
 ;; the agents in the editor, the panel and pair mode (agent system part 3, "Budget rows"): typing p95 within a frame and no
 ;; freeze over 100 ms; the +1 ms against `agents-typing-none' and the pair writes applied >= 0.80 are `drgnx-perf-run--relative-fails'
 (agents-typing (:input :p95) 16) (agents-typing (:stalls) 0)
 (agents-typing-none (:input :p95) 16) (agents-typing-none (:stalls) 0)
 (agents-follow (:input :p95) 16) (agents-follow (:stalls) 0)
 (agent-panel-stream (:input :p95) 16) (agent-panel-stream (:stalls) 0)
 (pair-typing (:input :p95) 16) (pair-typing (:stalls) 0))
