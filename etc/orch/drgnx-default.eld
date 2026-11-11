;;; drgnx-default.eld --- the rule pack drgnx ships  -*- mode: lisp-data -*-
;; The gates a plan run meets unless its plan names another pack (`**Pack:** FILE'): docs/develop/orchestration.md,
;; "The rule pack".  Read as data (huginn), never evaluated; frozen with the job when the user approves it.
;; It is for any project, so it names no project's commands: the author check is the task's own tests at the tip
;; (red first's run); a project's own pack adds its build, rule tests, groups command and push tiers.
(:name "drgnx-default" :version 1
 :rules ((:id "red-first" :kind "enforced"
          :doc "A task's first commit is its tests; they fail at that commit (an assertion, or a build error naming a symbol the task adds) and pass at the tip, unchanged.")
         (:id "author-check" :kind "enforced"
          :doc "The tip's own tests, and the project's author-check commands and rule tests when its pack names them, pass through the queue before it is ready to merge.")
         (:id "affected-groups" :kind "enforced"
          :doc "A merge batch runs the test groups its combined diff can affect, read from the base's test/affected.eld.")
         (:id "push-gate" :kind "enforced"
          :doc "A push needs one full run of every tier on the exact commit, with the current env stamp."))
 :test-globs ("test/*" "*/tests/*" "*_test.rs" "*/tests.rs")
 :compile-fail-reds ("rust" "elisp")
 :batch-size 3
 :no-cache ("--perf" "--soak" "--day" "--stress" "--bench")
 :context-share 120000)
