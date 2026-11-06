;;; agents-hooks-test.el --- batch tests: hook verdict lines, the header and the context map of an agent -*- lexical-binding: t -*-
;; test-class: det

;; SPDX-License-Identifier: GPL-3.0-or-later

;; The hub is not running: events and snapshots are fed to the mirror and the transcript as the hub sends them
;; (decoded JSON), and `drgnx-hub-call' is stubbed where a click asks the hub.  Pure (pattern D): no process, no timer.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-agents)
(require 'drgnx-agents-mirror)
(require 'drgnx-agents-hooks)
(require 'drgnx-records)
(load (expand-file-name "modules/tools/drgnx-agents-ui" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)

(defconst drgnx-agents-hooks-test--deny
  '(:point "before-tool" :at "seam" :tool "Bash" :step 4 :outcome "deny"
           :records ((:source "plugin:deny-rm@0.1#ab12" :verdict "deny" :ms 3 :reason "rm outside the worktree")))
  "A hook row as the hub's `agent-step' event carries it: a plugin denied the step.")

(defmacro drgnx-agents-hooks-test--with-mirror (var &rest body)
  "BODY with VAR a mirror of the hub session \"h1\" holding one tool entry \"t1\", in a fresh notice model."
  (declare (indent 1))
  `(drgnx-notice-test-with-model
     (let ((drgnx-agents--sessions nil) (drgnx-agents-mirror--turns (make-hash-table :test #'equal))
           (drgnx-agents-mirror--seq (make-hash-table :test #'equal))
           (drgnx-agents-mirror--lock (make-hash-table :test #'equal))
           (drgnx-agents-mirror--hub-turns (make-hash-table :test #'equal))
           (drgnx-agents-mirror--hub-entries (make-hash-table :test #'equal)))
       (let ((,var (car (drgnx-agents-mirror--apply-snapshot
                         (drgnx-records-from-json 'drgnx-records-session
                                                  '(:id "h1" :name "a" :status "busy"))))))
         (setf (drgnx-agent-session-entries ,var)
               (list '(:type tool :id "t1" :title "Bash rm -rf /" :status "completed")))
         ,@body))))

(defun drgnx-agents-hooks-test--has-button (string)
  "Non-nil when some character of STRING is part of a text button."
  (seq-some (lambda (i) (get-text-property i 'button string)) (number-sequence 0 (1- (length string)))))

(defun drgnx-agents-hooks-test--text (s)
  (with-temp-buffer (drgnx-agents-ui-render s) (buffer-string)))

;;;; Verdict lines

(ert-deftest drgnx-agents-hooks/a-refused-step-says-who-version-and-why ()
  (let* ((lines (drgnx-agents-hooks-lines (list drgnx-agents-hooks-test--deny)))
         (l (car lines)))
    (should (= (length lines) 1))
    (should (eq (plist-get l :kind) 'refused))
    (should (equal (substring-no-properties (plist-get l :text))
                   (format "%s refused by deny-rm 0.1 · \"rm outside the worktree\"" (drgnx-face-glyph 'refused))))
    (should (eq (get-text-property 0 'face (plist-get l :text)) 'drgnx-agents-hooks-refused))))

(ert-deftest drgnx-agents-hooks/change-note-and-failures-each-have-their-own-mark ()
  (let* ((row '(:point "before-commit" :step 5 :outcome "change"
                       :records ((:source "plugin:rewrite-commit-msg@1.0#cd" :verdict "change" :ms 2)
                                 (:source "rule:quiet" :verdict "allow" :ms 0)
                                 (:source "plugin:slow@2#ee" :verdict "error" :ms 2000 :reason "busy")
                                 (:source "plugin:broken@1#ff" :verdict "error" :ms 1 :reason "trapped"))))
         (lines (drgnx-agents-hooks-lines (list row))))
    (should (equal (mapcar (lambda (l) (plist-get l :kind)) lines) '(changed busy failed)))
    (should (string-match-p "changed by rewrite-commit-msg 1.0\\'" (substring-no-properties (plist-get (nth 0 lines) :text))))
    ;; busy has a mark of its own, apart from other errors
    (should-not (equal (get-text-property 0 'face (plist-get (nth 1 lines) :text))
                       (get-text-property 0 'face (plist-get (nth 2 lines) :text))))
    (should-not (equal (substring (plist-get (nth 1 lines) :text) 0 1) (substring (plist-get (nth 2 lines) :text) 0 1)))
    (let ((note (drgnx-agents-hooks-note-line '(:type note :source "plugin:annotate-edit@1#aa" :text "touches the lockfile" :step 5))))
      (should (equal (substring-no-properties note)
                     (format "%s note by annotate-edit 1 · \"touches the lockfile\"" (drgnx-face-glyph 'note)))))))

(ert-deftest drgnx-agents-hooks/a-hub-tool-step-says-it-is-hooked-at-the-hubs-server ()
  (let ((lines (drgnx-agents-hooks-lines '((:point "before-tool" :at "seam" :tool "mcp__drgnx__merge" :step 2
                                                   :outcome "at-server" :records nil)))))
    (should (equal (mapcar (lambda (l) (plist-get l :kind)) lines) '(at-server)))
    (should (string-match-p "hooked at the hub's server\\'" (substring-no-properties (plist-get (car lines) :text))))))

(ert-deftest drgnx-agents-hooks/provenance-has-source-version-hash-ms-and-the-input ()
  (let ((text (drgnx-agents-hooks-provenance drgnx-agents-hooks-test--deny
                                             (car (plist-get drgnx-agents-hooks-test--deny :records)))))
    (dolist (want '("deny-rm 0.1" "Version:  0.1" "Hash:     ab12" "Verdict:  deny" "rm outside the worktree" "3 ms"
                    "point before-tool" "at the seam" "tool Bash" "step 4"))
      (should (string-search want text)))))

;;;; The transcript

(ert-deftest drgnx-agents-hooks/the-mirror-keeps-an-events-rows-under-the-tool-it-ran-on ()
  (drgnx-agents-hooks-test--with-mirror m
    (drgnx-agents-mirror--event "agent-step" (list :step (list :session "h1" :seq 4 :hooks (list drgnx-agents-hooks-test--deny))))
    (should (equal (mapcar #'car (drgnx-agent-session-hooks m)) '(4)))
    (should (equal (nth 1 (car (drgnx-agent-session-hooks m))) "t1"))
    ;; a later tool entry does not take the rows: the step is seen again and keeps its tool
    (setf (drgnx-agent-session-entries m)
          (append (drgnx-agent-session-entries m) (list '(:type tool :id "t2" :title "Read" :status "completed"))))
    (drgnx-agents-mirror--event "agent-step" (list :step (list :session "h1" :seq 4 :hooks (list drgnx-agents-hooks-test--deny))))
    (should (equal (nth 1 (car (drgnx-agent-session-hooks m))) "t1"))
    (let ((text (drgnx-agents-hooks-test--text m)))
      (should (string-search "refused by deny-rm 0.1" text))
      (should (= 1 (with-temp-buffer (insert text) (goto-char (point-min)) (how-many "refused by")))))
    ;; a step with no hooks changes nothing
    (let ((before (drgnx-agent-session-hooks m)))
      (drgnx-agents-mirror--event "agent-step" (list :step (list :session "h1" :seq 9)))
      (should (eq (drgnx-agent-session-hooks m) before)))))

(ert-deftest drgnx-agents-hooks/ret-on-a-verdict-line-opens-its-provenance ()
  (drgnx-agents-hooks-test--with-mirror m
    (drgnx-agents-mirror--event "agent-step" (list :step (list :session "h1" :seq 4 :hooks (list drgnx-agents-hooks-test--deny))))
    (let (shown)
      (cl-letf (((symbol-function 'drgnx-agents-hooks-show-provenance) (lambda (row rec) (setq shown (list row rec)))))
        (with-temp-buffer
          (drgnx-agents-ui-render m)
          (goto-char (point-min))
          (search-forward "refused by")
          (push-button)))
      (should (equal (plist-get (car shown) :step) 4))
      (should (equal (plist-get (cadr shown) :source) "plugin:deny-rm@0.1#ab12")))))

(ert-deftest drgnx-agents-hooks/a-note-entry-shows-its-line-and-opens-its-hooks-provenance ()
  (drgnx-agents-hooks-test--with-mirror m
    (let ((row '(:point "after-edit" :step 6 :outcome "allow"
                        :records ((:source "plugin:annotate-edit@1#aa" :verdict "annotate" :ms 4 :reason "touches the lockfile")))))
      (drgnx-agents-mirror--event "agent-step" (list :step (list :session "h1" :seq 6 :hooks (list row))))
      (setf (drgnx-agent-session-entries m)
            (append (drgnx-agent-session-entries m)
                    (list '(:type note :source "plugin:annotate-edit@1#aa" :text "touches the lockfile" :step 6))))
      (should (string-search "note by annotate-edit 1" (drgnx-agents-hooks-test--text m)))
      (let (shown)
        (cl-letf (((symbol-function 'drgnx-agents-hooks-show-provenance) (lambda (r rec) (setq shown (list r rec)))))
          (with-temp-buffer (drgnx-agents-ui-render m) (goto-char (point-min)) (search-forward "note by") (push-button)))
        (should (equal (plist-get (cadr shown) :ms) 4))))))

(ert-deftest drgnx-agents-hooks/an-edit-a-hook-refused-after-the-fact-is-marked-on-its-step ()
  (let ((s (drgnx-agents--make :name "a" :remote "h1"
                               :entries (list '(:type tool :id "t1" :title "Edit x.el" :status "completed"
                                                      :refused_by_hook (:hook "deny-edit-x" :reason "x.el is frozen"))))))
    (should (string-search "refused by deny-edit-x · \"x.el is frozen\"" (drgnx-agents-hooks-test--text s)))))

(ert-deftest drgnx-agents-hooks/drawing-the-transcript-never-asks-the-hub ()
  ;; redisplay reads cached state: with every hub entry point refusing, a transcript with rows, a header and a
  ;; breakdown still draws
  (drgnx-agents-hooks-test--with-mirror m
    (setf (drgnx-agent-session-hooked m) '(:unhooked ("read") :why "the agent reads without asking")
          (drgnx-agent-session-panel m) '(:features ("context" "drop") :context (:used 10 :size 100 :parts ((:kind "files" :tokens 10)))))
    (drgnx-agents-mirror--event "agent-step" (list :step (list :session "h1" :seq 4 :hooks (list drgnx-agents-hooks-test--deny))))
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) (error "asked the hub")))
              ((symbol-function 'drgnx-hub-call-sync) (lambda (&rest _) (error "asked the hub")))
              ((symbol-function 'drgnx-hub-ensure) (lambda (&rest _) (error "asked the hub"))))
      (let ((text (drgnx-agents-hooks-test--text m)))
        (should (string-search "not hooked: read" text))
        (should (string-search "refused by" text))))))

(ert-deftest drgnx-agents-hooks/a-new-hook-row-changes-the-tool-rows-signature ()
  ;; the view's diff is by `eq' elements: a row that arrives must make the tool's row draw again
  (drgnx-agents-hooks-test--with-mirror m
    (let* ((drgnx-agents-ui--session m) (tool (car (drgnx-agent-session-entries m)))
           (before (drgnx-agents-ui--sig tool)))
      (drgnx-agents-mirror--event "agent-step" (list :step (list :session "h1" :seq 4 :hooks (list drgnx-agents-hooks-test--deny))))
      (should-not (drgnx-agents-ui--same-sig-p before (drgnx-agents-ui--sig tool))))))

;;;; The header

(ert-deftest drgnx-agents-hooks/the-snapshot-fills-hooked-panel-and-plugins-changed ()
  (drgnx-agents-hooks-test--with-mirror m
    (let ((m2 (car (drgnx-agents-mirror--apply-snapshot
                    (drgnx-records-from-json
                     'drgnx-records-session
                     '(:id "h1" :name "a" :status "busy" :plugins_changed t
                           :hooked (:before_tool ("execute") :by_adapter ("edit") :unhooked ("read") :why "it reads without asking")
                           :panel (:features ("context" "drop") :context (:used 5 :size 10 :parts ((:kind "files" :tokens 5))))))))))
      (should (eq m m2))
      (should (equal (plist-get (drgnx-agent-session-hooked m) :unhooked) '("read")))
      (should (equal (drgnx-agent-session-plugins-changed m) t))
      (should (drgnx-agents-hooks-context m))
      (should (drgnx-agents-hooks-offers-p m "drop"))
      (should-not (drgnx-agents-hooks-offers-p m "pin")))))

(ert-deftest drgnx-agents-hooks/the-header-says-what-the-snapshot-says-and-nothing-more ()
  (drgnx-agents-hooks-test--with-mirror m
    (should-not (drgnx-agents-ui--header-text m))
    (should-not (memq :header (drgnx-agents-ui--keys m)))
    (setf (drgnx-agent-session-hooked m) '(:unhooked ("read" "fetch") :by_adapter ("edit") :why "the agent runs them itself")
          (drgnx-agent-session-plugins-changed m) t)
    (let ((text (substring-no-properties (drgnx-agents-ui--header-text m))))
      (should (string-search "not hooked: read, fetch (the agent runs them itself)" text))
      (should (string-search "hooked by the adapter: edit" text))
      (should (string-search "plugins changed: restart the session" text))
      (should-not (string-search "context" text)))
    (should (eq (car (drgnx-agents-ui--keys m)) :header))))

(ert-deftest drgnx-agents-hooks/the-context-percent-opens-the-breakdown-only-when-the-agent-sends-one ()
  (drgnx-agents-hooks-test--with-mirror m
    (setf (drgnx-agent-session-usage m) '(:used 40 :size 100))
    ;; no breakdown: the percent is plain text, never a button; the command refuses
    (let ((h (drgnx-agents-ui--header-text m)))
      (should (string-search "context 40%" h))
      (should-not (drgnx-agents-hooks-test--has-button h)))
    (should-error (drgnx-agents-ui-context m) :type 'user-error)
    (setf (drgnx-agent-session-panel m) '(:features ("context") :context (:used 60 :size 120 :parts ((:kind "files" :tokens 60)))))
    (let ((h (drgnx-agents-ui--header-text m)))
      (should (string-search "context 50%" h))                       ; the breakdown's own figures
      (should (drgnx-agents-hooks-test--has-button h)))))

;;;; The breakdown

(defconst drgnx-agents-hooks-test--context
  '(:used 60 :size 120 :compact_frees 20
          :parts ((:kind "system" :tokens 10)
                  (:kind "files" :tokens 30 :items ((:id "f1" :label "src/a.rs" :tokens 20) (:id "f2" :label "src/b.rs" :tokens 10)))
                  (:kind "conversation" :tokens 20)))
  "A breakdown as the hub's snapshot carries it.")

(ert-deftest drgnx-agents-hooks/the-bar-has-a-run-per-part-in-its-face-and-the-free-rest ()
  (let ((bar (drgnx-agents-hooks-bar drgnx-agents-hooks-test--context)))
    (should (= (length bar) drgnx-agents-hooks-bar-width))
    (should (eq (get-text-property 0 'face bar) 'drgnx-context-system))
    (should (eq (get-text-property 3 'face bar) 'drgnx-context-system))   ; 10 of 120 tokens: 4 of 48 columns
    (should (eq (get-text-property 4 'face bar) 'drgnx-context-files))
    (should (eq (get-text-property (1- (length bar)) 'face bar) 'drgnx-context-free))
    ;; half the window is free (60 of 120): the last 24 columns
    (should (= 24 (cl-count-if (lambda (i) (eq (get-text-property i 'face bar) 'drgnx-context-free)) (number-sequence 0 (1- (length bar))))))))

(ert-deftest drgnx-agents-hooks/drop-pin-and-compact-preview-appear-only-where-the-agent-offers-them ()
  (let ((s (drgnx-agents--make :name "a" :remote "h1" :panel (list :features '("context") :context drgnx-agents-hooks-test--context))))
    (let ((text (with-temp-buffer (drgnx-agents-hooks-context-insert s) (buffer-string))))
      (should (string-search "src/a.rs" text))
      (should (string-search "/compact would free 20 tokens" text))
      (should-not (string-search "[drop]" text))
      (should-not (string-search "[pin]" text))
      (should-not (string-search "What /compact keeps" text))))
  (let* ((s (drgnx-agents--make :name "a" :remote "h1"
                                :panel (list :features '("context" "drop" "pin" "compact-preview") :context drgnx-agents-hooks-test--context)))
         calls)
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (method params cb &rest _) (push (cons method params) calls) (funcall cb t nil) 1)))
      (with-temp-buffer
        (drgnx-agents-hooks-context-insert s)
        (goto-char (point-min))
        (search-forward "[drop]") (backward-char 2) (push-button)
        (search-forward "[pin]") (backward-char 2) (push-button)
        (goto-char (point-min))
        (search-forward "[unpin]") (backward-char 2) (push-button))
      (should (equal (reverse calls)
                     '(("agents/context-drop" :id "h1" :item "f1")
                       ("agents/context-pin" :id "h1" :item "f1" :pinned t)
                       ("agents/context-pin" :id "h1" :item "f1" :pinned :false)))))))

(ert-deftest drgnx-agents-hooks/what-compact-keeps-asks-the-hub-for-a-preview-and-shows-it ()
  (let ((s (drgnx-agents--make :name "a" :remote "h1"
                               :panel (list :features '("compact-preview") :context drgnx-agents-hooks-test--context)))
        calls)
    (cl-letf (((symbol-function 'drgnx-hub-call)
               (lambda (method params cb &rest _)
                 (push (cons method params) calls)
                 (funcall cb '(:frees 20 :kept ((:id "f1" :label "src/a.rs" :tokens 20)) :note "summarises the chat") nil) 1))
              ((symbol-function 'pop-to-buffer) #'ignore))
      (drgnx-agents-hooks-compact-preview s)
      (should (equal calls '(("agents/compact-preview" :id "h1"))))
      (with-current-buffer "*agent compact preview*"
        (should (string-search "A compaction frees 20 tokens." (buffer-string)))
        (should (string-search "src/a.rs" (buffer-string)))
        (should (string-search "summarises the chat" (buffer-string))))
      (kill-buffer "*agent compact preview*"))))

(provide 'agents-hooks-test)
;;; agents-hooks-test.el ends here
