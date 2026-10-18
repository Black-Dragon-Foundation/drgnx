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
 ;; eat (2026-10-18, load 3-5, medians of three runs of the workload's own three repeats): terminal-typing p95 4.2-4.8 ms,
 ;; max 6.4-12.5; terminal-output p95 4.4-6.0, max 23-68 (a GC of ~46 ms lands in the typing: 9-10 collections per run).
 ;; The p95 rows are the measured p95 rounded up; terminal-typing's max is the worst measured, rounded up.
 ;; terminal-output's max is PROVISIONAL: the ceiling (50 ms), which the measurements straddle: a perf finding (eat's
 ;; output garbage), not a budget; see docs/develop/perf.md.
 (terminal-typing (:input :p95) 5) (terminal-typing (:input :max) 13)
 (terminal-output (:input :p95) 6) (terminal-output (:input :max) 50)
 (redisplay (:redisplay :p95) 16))
