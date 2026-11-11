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
  "The lens bar is the Work space's tab (Work · its name), then Map · Board · Timeline · Flow with the current one
marked, then the lens's own keys as chips with their key badges."
  (let ((s (drgnx-work-lens-string 'flow "drgnx" '(("evidence" . "e") ("rules" . "R")))))
    (should (string-match-p "Work · drgnx.*Map.*Board.*Timeline.*Flow.*evidence.*e.*rules.*R" s))
    (should (eq (get-text-property (string-match "Work · drgnx" s) 'face s) 'drgnx-work-lens-title))
    (should (eq (get-text-property (string-match "Flow" s) 'face s) 'drgnx-work-lens-current))
    (should (eq (get-text-property (string-match "Map" s) 'face s) 'drgnx-work-label))
    (should (eq (get-text-property (string-match "evidence" s) 'face s) 'drgnx-work-chip))
    (should (eq (get-text-property (string-search "R" s (string-search "rules" s)) 'face s) 'drgnx-work-lens-key)))
  ;; no name: the tab says Work alone; no keys: no chips
  (let ((s (drgnx-work-lens-string 'map)))
    (should (string-match-p "Work .*Map" s))
    (should-not (string-match-p "evidence" s))))

(ert-deftest drgnx-work-flow/its-window-shows-the-lens-bar-and-the-map-s-strip ()
  "The Flow's window shows the lens bar as its tab line (the chrome keeps a buffer's own) and the map's strip (what
needs you, the machines' load) as its header."
  (let ((map (generate-new-buffer " map")) (flow (generate-new-buffer " flow")))
    (unwind-protect
        (progn
          (with-current-buffer map (setq-local drgnx-work-map--strip "⚑ T5 held  g1"))
          (with-current-buffer flow
            (drgnx-work-flow-mode)
            (setq drgnx-work-flow--map map)
            (should (local-variable-p 'drgnx-chrome-own-tab-line))
            ;; a mode line drops the faces of a variable's string unless the variable is risky
            (should (get 'drgnx-work-map--lens 'risky-local-variable))
            (should (get 'drgnx-work-map--strip 'risky-local-variable))
            (should drgnx-chrome-own-tab-line)
            ;; the header is an `:eval' form (a batch Emacs formats those as ""): its value is the map's strip
            (should (eq (car header-line-format) :eval))
            (should (string-search "T5 held" (eval (cadr header-line-format) t)))))
      (kill-buffer flow) (kill-buffer map))))

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

(ert-deftest drgnx-work-flow/a-held-task-s-card-is-on-its-row ()
  "The hub puts a held task's `gate' card on its row (`drgnx-work-card'); a needs-you chip names the task alone."
  (with-temp-buffer
    (insert (propertize " ⚑ T5 held: no red " 'drgnx-work-id "J#5") "\n"
            (propertize "T1 search/run" 'drgnx-work-id "J#1") "\n"
            (propertize "T5 Git scopes" 'drgnx-work-id "J#5" 'drgnx-work-card 42) "\n")
    (should (eql (drgnx-work-flow--card-of "J#5") 42))
    (should-not (drgnx-work-flow--card-of "J#1"))
    (should-not (drgnx-work-flow--card-of "J#9"))))

(ert-deftest drgnx-work-flow/the-tile-asks-for-the-selected-task ()
  "The detail tile is the Flow's subscription with `detail': its own view, the map's view, the job and the task."
  (should (equal (drgnx-work-flow--detail-params "flow-1/detail" "map-1" nil "J#5")
                 '(:view "flow-1/detail" :map "map-1" :detail "J#5")))
  (should (equal (drgnx-work-flow--detail-params "flow-1/detail" "map-1" "J" "J#5")
                 '(:view "flow-1/detail" :map "map-1" :detail "J#5" :job "J"))))

(ert-deftest drgnx-work-flow/the-rules-tile-asks-for-the-pack ()
  "The Rules tile is the Flow's subscription with `rules': its own view, the map's view and the job."
  (should (equal (drgnx-work-flow--rules-params "flow-1/rules" "map-1" nil)
                 '(:view "flow-1/rules" :map "map-1" :rules t)))
  (should (equal (drgnx-work-flow--rules-params "flow-1/rules" "map-1" "J")
                 '(:view "flow-1/rules" :map "map-1" :rules t :job "J"))))

(ert-deftest drgnx-work-flow/its-faces-are-the-ui-font-s-and-the-theme-s ()
  "The faces the hub's Flow rows name: the UI font (proportional), colours from the theme's chips and text, no
literal colour."
  (dolist (f '(drgnx-work-flow-text drgnx-work-flow-label drgnx-work-flow-heading drgnx-work-flow-chip-ok
                                    drgnx-work-flow-chip-run drgnx-work-flow-chip-held drgnx-work-flow-chip-err
                                    drgnx-work-flow-chip-wait))
    (should (facep f))
    (let ((spec (face-default-spec f)))
      (should-not (string-match-p "#[0-9a-fA-F]\\{3\\}" (format "%S" spec)))
      (should (string-match-p "drgnx-ui-" (format "%S" spec))))))

(ert-deftest drgnx-work-flow/the-actions-answer-the-gate-card ()
  "Run the red, Tell the agent and Waive once answer the held task's `gate' card (`job/card': merge, retry, waive with
the reason); a waiver without a reason, or a task no gate holds, sends nothing."
  (let (sent (card 42))
    (cl-letf (((symbol-function 'drgnx-work-flow--held-card) (lambda () (or card (user-error "not held"))))
              ((symbol-function 'drgnx-hub-call)
               (lambda (method params _cb &rest _) (push (cons method params) sent))))
      (drgnx-work-flow-run-red)
      (drgnx-work-flow-tell-agent)
      (drgnx-work-flow-waive "a docs change")
      (should-error (drgnx-work-flow-waive "  ") :type 'user-error)
      (setq card nil)
      (should-error (drgnx-work-flow-waive "x") :type 'user-error))
    (should (equal (nreverse sent)
                   '(("job/card" :card 42 :action "merge")
                     ("job/card" :card 42 :action "retry")
                     ("job/card" :card 42 :action "waive" :arg "a docs change"))))))

(ert-deftest drgnx-work-flow/its-keys-are-in-every-profile ()
  "`F' shows the Flow from any view of the lens; `e', `R' and the held task's actions (`r', `s', `w') work in the Flow
only; every profile names them."
  (dolist (id '(work-view-flow work-flow-evidence work-flow-rules work-flow-run-red work-flow-tell-agent
                               work-flow-waive))
    (should (memq id drgnx-work-space-command-ids))
    (dolist (profile '("vscode" "emacs" "vim"))
      (let ((rows (plist-get (with-temp-buffer
                               (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
                               (read (current-buffer)))
                             :bind)))
        (should (assq id rows))))))

(ert-deftest drgnx-work-flow/its-cards-and-rules-are-glitnir-blocks ()
  "Pattern D: the hub's block marks on the rows become `glitnir-blocks' on the window showing the Flow: a card's ring
from its first row to the end of its last, a rule per marked row, colours as faces (Glitnir resolves them again on a
theme change).  The parameter is set when the blocks change, not per patch; a killed Flow leaves no blocks behind."
  (let ((buffer (generate-new-buffer "*flow-blocks*")) (sets 0)
        (setp (symbol-function 'set-window-parameter)))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (add-hook 'kill-buffer-hook #'drgnx-work-flow--unblock nil t)
          (let ((inhibit-read-only t))
            (insert (propertize "T1 row" 'drgnx-work-flow-block ["rule" "task:1" 0 600]) "\n"
                    (propertize "Merge batch" 'drgnx-work-flow-block ["ring" "batch" 0 290])
                    (propertize " Line gate" 'drgnx-work-flow-block ["ring" "line" 300 598]) "\n"
                    (propertize "T2 tip" 'drgnx-work-flow-block ["ring" "batch" 0 290]) "\n"))
          (cl-letf (((symbol-function 'set-window-parameter)
                     (lambda (w p v) (when (eq p 'glitnir-blocks) (cl-incf sets)) (funcall setp w p v))))
            (drgnx-work-flow--patched nil nil)
            (let* ((blocks (window-parameter (selected-window) 'glitnir-blocks))
                   (kinds (mapcar #'car blocks)))
              (should (equal kinds '(rule ring ring)))
              (let ((batch (nth 1 blocks)))
                ;; the batch's ring spans its two rows: from "Merge batch" to the end of "T2 tip"
                (should (= (marker-position (nth 1 batch)) 8))
                (should (= (marker-position (nth 2 batch)) (1- (point-max))))
                (should (equal (plist-get (nthcdr 3 batch) :x1) 290))
                (should (eq (plist-get (nthcdr 3 batch) :ring) 'drgnx-border))
                (should (eq (plist-get (nthcdr 3 batch) :beneath) 'default)))
              (should (eq (plist-get (nthcdr 3 (car blocks)) :ring) 'drgnx-border-subtle))
              (should (equal (plist-get (nthcdr 3 (nth 2 blocks)) :x0) 300))
              ;; the same rows again: the same object, not set again
              (drgnx-work-flow--patched nil nil)
              (should (eq (window-parameter (selected-window) 'glitnir-blocks) blocks))
              (should (= sets 1))))
          (kill-buffer buffer)
          (should-not (window-parameter (selected-window) 'glitnir-blocks)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

;;; work-flow-test.el ends here
