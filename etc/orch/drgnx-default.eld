;;; drgnx-default.eld --- the rule pack drgnx ships  -*- mode: lisp-data -*-
;; The gates a plan run meets unless its plan names another pack (`**Pack:** FILE'): docs/develop/orchestration.md,
;; "The rule pack".  Read as data (huginn), never evaluated; frozen with the job when the user approves it.
(:name "drgnx-default" :version 1
 :rules ((:id "red-first" :kind "enforced"
          :doc "A task's first commit is its tests; they fail at that commit (an assertion, or a build error naming a symbol the task adds) and pass at the tip, unchanged.")
         (:id "author-check" :kind "enforced"
          :doc "The tip's tree builds and its own tests and the rule tests pass, through the queue, before it is ready to merge.")
         (:id "affected-groups" :kind "enforced"
          :doc "A merge batch runs the test groups its combined diff can affect, read from the base's test/affected.eld.")
         (:id "push-gate" :kind "enforced"
          :doc "A push needs one full run of every tier on the exact commit, with the current env stamp."))
 :test-globs ("test/*" "*/tests/*" "*_test.rs" "*/tests.rs")
 :compile-fail-reds ("rust" "elisp")
 :batch-size 3
 :author-check ((:name "build" :run ("bin/drgnx" "build")))
 :rule-tests ((:name "rules" :run ("env" "DRGNX_TEST_SELECTOR=^drgnx-build/\\|^drgnx-keys/\\|^drgnx-lint/\\|^drgnx-teardown/"
                                   "bin/drgnx" "test" "--container")))
 :push-tiers ((:name "unit" :run ("bin/drgnx" "test" "--container"))
              (:name "rust" :dir "runtime" :run ("cargo" "test" "--workspace" "--features" "drgnx-ratatoskr/test-hooks,drgnx-px/test-hooks"))
              (:name "ui" :run ("bin/drgnx" "test" "--container" "--ui"))
              (:name "scenario" :run ("bin/drgnx" "test" "--container" "--scenario")))
 :groups ("bin/drgnx" "test" "--affected" "%r" "--json")
 :no-cache ("--perf" "--soak" "--day" "--stress")
 :shared-paths ("core/drgnx-registry*" "settings/*" "keys/*" "*/migrate*" "runtime/protocol/*")
 :context-share 120000)
