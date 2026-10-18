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
 (job-window (:input :p95) 16) (job-window (:input :max) 50)
 (code-scrolling (:input :p95) 16) (code-scrolling (:input :max) 50)
 (typing-with-ghost (:input :p95) 16) (typing-with-ghost (:input :max) 50)
 (diff-scrolling (:input :p95) 16) (diff-scrolling (:input :max) 50)
 (replace-typing (:input :p95) 16) (replace-typing (:input :max) 50)
 (live-view (:input :p95) 16) (live-view (:input :max) 50)
 ;; eat (2026-10-18, with the tools/terminal-eat module running, medians of the workload's three repeats, load 3-6; the
 ;; machine was never quiet): terminal-typing p95 1.9-6.4 ms over 16 runs (two above 5, at load 3.9 and 5.8), max 2.5-10.6;
 ;; terminal-output p95 4.2-8.0 (above 5.2 only at load 5.5 and above), max 5-49 with drgnx's early collection
 ;; (`drgnx-terminal-eat-gc-quiet') over ten runs at load 2.7-6.2, 5-44 over five more at load 3.3-6.6.
 ;; The p95 rows are the worst measured at load below 6, rounded up; terminal-typing's max the worst measured, rounded up.
 ;; terminal-output's max is PROVISIONAL: 50 ms is the ceiling, not a measurement (n=10 per arm, a busy machine).  The
 ;; collection no longer lands in a keystroke (that was the failure before: 3 of 10 runs over 50); what is left comes from
 ;; the length of eat's output batches (20-60 ms under load), not from GC: DEFERRED M12e-5-1.  See docs/develop/perf.md.
 (terminal-typing (:input :p95) 6) (terminal-typing (:input :max) 13)
 (terminal-output (:input :p95) 6) (terminal-output (:input :max) 50)
 (redisplay (:redisplay :p95) 16))
