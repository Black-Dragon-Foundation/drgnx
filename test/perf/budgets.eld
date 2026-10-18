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
 ;; cockpit-cards: PROVISIONAL — the job-window rows renamed (M12f, the job window is the cockpit's), measured on a
 ;; busy machine; part C's close (C12) confirms them
 (cockpit-cards (:input :p95) 16) (cockpit-cards (:input :max) 50)
 (code-scrolling (:input :p95) 16) (code-scrolling (:input :max) 50)
 (typing-with-ghost (:input :p95) 16) (typing-with-ghost (:input :max) 50)
 (diff-scrolling (:input :p95) 16) (diff-scrolling (:input :max) 50)
 (replace-typing (:input :p95) 16) (replace-typing (:input :max) 50)
 (live-view (:input :p95) 16) (live-view (:input :max) 50)
 (agent-settings-open (:draw_ms) 150) (agent-settings-open (:processes) 0)
 (remote-typing (:input :p95) 16) (remote-typing (:input :max) 50)
 (redisplay (:redisplay :p95) 16)
 ;; typing-with-index (M10-1): PROVISIONAL.  p95 22 = worst of 3 runs (12.2, 17.2, 21.1), rounded up, measured at load 7-8
 ;; (busy machine; the p95 rose with the load).  The ruled target is typing's 16 ms: a quiet-machine run pins it.
 (typing-with-index (:input :p95) 22) (typing-with-index (:input :max) 50))
