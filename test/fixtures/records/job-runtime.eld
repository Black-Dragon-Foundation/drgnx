;; A job's `data' after it ran: the proposal plus what the job keeps in it (drgnx-job.el, drgnx-job-clash.el).
(:plan "/work/repo/docs/plans/p.md" :sha "4f9a" :repo "/work/repo/" :title "Build the parser"
 :tasks ((:n 1 :title "The lexer" :role "implement" :deps nil :body "- [ ] Step 1")
         (:n 2 :title "The tests" :role "test" :deps (1) :body "- [ ] Step 1"))
 :routes ((implement . "claude") (test . "claude") (review . "claude"))
 :estimate (:usd 1.5 :tokens 330000 :unpriced ("claude")) :budget 5 :gate review+accept
 :unpriced-budget ("claude")
 :fails (("job-1/t2" . 1)) :exits (("job-1/t1" . 2)) :nudged (("job-1/t1" . 1)) :in-review-since (("job-1/t2" . 1760000000.5))
 :notes (("job-1/t2" . "the reviewer wants a test"))
 :waiting (("job-1/t1" :sid "agent-2" :back "in-review"))
 :blocked (("job-1/t2" . "blocked")) :profiles (("job-1/t1" . "claude")) :bases (("job-1/t1" . "9f2c1ab"))
 :order ("job-1/t2" "job-1/t1") :clashes ("overlap:1:2"))
