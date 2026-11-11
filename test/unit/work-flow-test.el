;;; work-flow-test.el --- batch tests: the Flow lens's Lisp side on fixture feeds -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; No hub and no Sjá: the lens's words, what the Flow asks the hub, a task's evidence (as `orch/evidence' answers it)
;; drawn as lines, and its keys in every profile.  The rows themselves are the hub's (work::trail::flow, tested there).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-map" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-work-flow" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(ert-deftest drgnx-work-flow/the-lens-names-the-flow ()
  "The lens is Map · Board · Timeline · Flow; the current one is bold."
  (let ((s (drgnx-work-lens-string 'flow)))
    (should (string-match-p "Map .*Board .*Timeline .*Flow" s))
    (should (eq (get-text-property (string-match "Flow" s) 'face s) 'bold))
    (should (eq (get-text-property (string-match "Map" s) 'face s) 'drgnx-work-label))))

(ert-deftest drgnx-work-flow/it-asks-the-hub-for-the-job-s-flow ()
  "The Flow asks `work/flow/subscribe' with its view, its map's view and the job (none: the hub picks the newest
running job)."
  (let (asked)
    (cl-letf (((symbol-function 'drgnx-work-client--call)
               (lambda (method params _cb) (push (cons method params) asked) t)))
      (drgnx-work-flow--ask "flow-1" "map-1" nil)
      (drgnx-work-flow--ask "flow-1" "map-1" "J7"))
    (should (equal (nreverse asked)
                   '(("work/flow/subscribe" :view "flow-1" :map "map-1")
                     ("work/flow/subscribe" :view "flow-1" :map "map-1" :job "J7"))))))

(defconst drgnx-work-flow-test--evidence
  [(:kind "red" :task "task:J#5" :job "4411"
          :facts (:tree_key "a90e3f1c" :env_stamp "e" :platform "linux-x86_64/local" :selector "runtime\ncargo test -p x")
          :rows [(:name "x::a" :verdict "fail" :class "assert") (:name "x::b" :verdict "pass")]
          :truncated :false :at 10.0)
   (:kind "green" :task "task:J#5" :job "4412"
          :facts (:tree_key "7d21c0e9" :env_stamp "e" :platform "linux-x86_64/local" :selector "runtime\ncargo test -p x")
          :rows [(:name "x::a" :verdict "pass") (:name "x::b" :verdict "pass")]
          :truncated :false :at 20.0)
   (:kind "waiver" :task "task:J#5" :job ""
          :facts (:tree_key "7d21c0e9" :env_stamp "" :platform "" :selector "")
          :rows [] :truncated :false :at 30.0 :note "a docs change")]
  "A task's evidence as `orch/evidence' answers it (parsed as plists): a red, a green, the user's waiver.")

(ert-deftest drgnx-work-flow/a-task-s-evidence-is-a-line-per-record ()
  "Each record is a line: its kind, job, tree and selector's command, then its failing rows or its pass count; a waiver
says its reason."
  (let ((lines (drgnx-work-flow--evidence-lines drgnx-work-flow-test--evidence)))
    (should (= (length lines) 3))
    (should (string-match-p "\\`red +job 4411 +a90e3f1 +cargo test -p x +1 failed: x::a\\'" (nth 0 lines)))
    (should (string-match-p "\\`green +job 4412 +7d21c0e +cargo test -p x +2 pass\\'" (nth 1 lines)))
    (should (string-match-p "\\`waiver +7d21c0e +by you: a docs change\\'" (nth 2 lines)))
    (should (equal (drgnx-work-flow--evidence-lines []) '("No evidence yet.")))))

(ert-deftest drgnx-work-flow/its-keys-are-in-every-profile ()
  "`F' shows the Flow from any view of the lens; `e' and `R' work in the Flow only; every profile names them."
  (dolist (id '(work-view-flow work-flow-evidence work-flow-rules))
    (should (memq id drgnx-work-space-command-ids))
    (dolist (profile '("vscode" "emacs" "vim"))
      (let ((rows (plist-get (with-temp-buffer
                               (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
                               (read (current-buffer)))
                             :bind)))
        (should (assq id rows))))))

;;; work-flow-test.el ends here
