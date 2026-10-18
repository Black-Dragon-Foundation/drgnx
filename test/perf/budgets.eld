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
 (redisplay (:redisplay :p95) 16)
 ;; evil (Vim keys), M12d Task 13: the same budgets as the stack without it; the Explorer's keys within the bench's 8 ms.
 ;; PROVISIONAL: measured on a busy machine (load 3-5), worst of 5 runs: typing-evil p95 13.0 / max 19.9, motions-evil
 ;; 9.6 / 11.5, explorer-evil 6.4 / 6.4 ms; a quiet-machine run pins them (docs/develop/perf.md).
 ;; typing-evil p95 may also exceed typing p95 by at most 1 ms in the same run (`drgnx-perf-run--relative-fails').
 (typing-evil (:input :p95) 16) (typing-evil (:input :max) 50)
 (motions-evil (:input :p95) 16) (motions-evil (:input :max) 50)
 (explorer-evil (:input :p95) 8) (explorer-evil (:input :max) 50))
