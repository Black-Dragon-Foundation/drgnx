;;; agent-panel-test.el --- the agent panel: rows, steps, patches, chips -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  No hub: the panel is fed snapshots and entries by hand, and the hub client's calls are recorded.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agent-panel))

(defvar drgnx-agent-panel--stats-render)
(declare-function drgnx-agent-panel-buffer "drgnx-agent-panel")
(declare-function drgnx-agent-panel--take-entries "drgnx-agent-panel")
(declare-function drgnx-agent-panel--take-snapshot "drgnx-agent-panel")
(declare-function drgnx-agent-panel--take-steps "drgnx-agent-panel")
(declare-function drgnx-agent-panel-toggle "drgnx-agent-panel")
(declare-function drgnx-agent-panel--ask "drgnx-agent-panel")
(declare-function drgnx-agent-panel-revert-here "drgnx-agent-panel")
(declare-function drgnx-agent-panel-fork-here "drgnx-agent-panel")
(declare-function drgnx-history-revert-to-here "drgnx-history-revert")
(declare-function drgnx-forecast-line "drgnx-forecast")

(defvar drgnx-agent-panel-test--calls nil)

(defmacro drgnx-agent-panel-test--with (&rest body)
  "BODY with the module set up, the hub's calls recorded in `drgnx-agent-panel-test--calls' (METHOD . PARAMS) and
unanswered, and panel \"s1\" as `buf'."
  (declare (indent 0))
  `(let ((drgnx-agent-panel-test--calls nil) buf)
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params _cb &rest _) (push (cons method params) drgnx-agent-panel-test--calls) 1)))
       (drgnx-test-with-modules '(tools/agent-panel)
         (unwind-protect
             (progn (setq buf (drgnx-agent-panel-buffer "s1"))
                    ,@body)
           (when (buffer-live-p buf) (kill-buffer buf)))))))

(defun drgnx-agent-panel-test--text (buf)
  (with-current-buffer buf
    (drgnx-view-draw-now drgnx-view)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun drgnx-agent-panel-test--tool (id title status &rest more)
  (append (list :type "tool" :id id :title title :kind "read" :status status) more))

(ert-deftest drgnx-agent-panel/appends-and-patches-never-rerenders ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-entries (list (list 0 (list :type "user" :text "go"))
                                             (list 1 (drgnx-agent-panel-test--tool "t1" "Read a.el" "pending"))))
      (drgnx-agent-panel-test--text buf)
      (let ((rendered nil))
        (cl-letf* ((orig (symbol-function 'drgnx-agent-panel--render))
                   ((symbol-function 'drgnx-agent-panel--render)
                    (lambda (key) (push key rendered) (funcall orig key))))
          ;; an entry appended: only its row is drawn
          (drgnx-agent-panel--take-entries (list (list 2 (drgnx-agent-panel-test--tool "t2" "Read b.el" "pending"))))
          (drgnx-agent-panel-test--text buf)
          (should (equal '((:e 2)) rendered))
          ;; an entry changed in place: only its row is drawn again
          (setq rendered nil)
          (drgnx-agent-panel--take-entries (list (list 1 (drgnx-agent-panel-test--tool "t1" "Read a.el" "completed"))))
          (drgnx-agent-panel-test--text buf)
          (should (equal '((:e 1)) rendered))
          ;; the same entry again changes nothing
          (setq rendered nil)
          (drgnx-agent-panel--take-entries (list (list 1 (drgnx-agent-panel-test--tool "t1" "Read a.el" "completed"))))
          (drgnx-agent-panel-test--text buf)
          (should-not rendered)))
      (should (string-match-p "Read a.el" (drgnx-agent-panel-test--text buf)))
      (should (string-match-p "Read b.el" (drgnx-agent-panel-test--text buf))))))

(defun drgnx-agent-panel-test--block (n kind &rest spans)
  (list :block n :kind kind :spans (vconcat (mapcar (lambda (s) (list :text (car s) :style (cdr s))) spans))))

(ert-deftest drgnx-agent-panel/markdown-patches-draw-only-their-blocks ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-entries
       (list (list 0 (list :type "agent" :text "# Title\n\npara"
                           :blocks (vector (drgnx-agent-panel-test--block 0 "heading" '("Title" . "h1"))
                                           (drgnx-agent-panel-test--block 1 "paragraph" '("para" . "text")))))))
      (let ((text (drgnx-agent-panel-test--text buf)) (rendered nil))
        (should (string-match-p "Title\n  para" text))
        (cl-letf* ((orig (symbol-function 'drgnx-agent-panel--render))
                   ((symbol-function 'drgnx-agent-panel--render)
                    (lambda (key) (push key rendered) (funcall orig key))))
          ;; a patch: block 1 grows and takes a style; block 2 is new (its `kind' creates it); block 0 is not drawn
          (drgnx-agent-panel--take-entries
           (list (list 0 (list :type "agent" :text "# Title\n\npara more\n\n```\nx"
                               :patch (vector (drgnx-agent-panel-test--block 1 "paragraph" '("para " . "text") '("more" . "strong"))
                                              (drgnx-agent-panel-test--block 2 "code" '("x" . "code")))))))
          (setq text (drgnx-agent-panel-test--text buf))
          (should (equal '((:b 0 2) (:b 0 1)) (sort rendered (lambda (a b) (> (nth 2 a) (nth 2 b))))))
          (should (string-match-p "para more\n  x" text))
          ;; an event with neither blocks nor patch keeps the blocks it has, and draws nothing
          (setq rendered nil)
          (drgnx-agent-panel--take-entries (list (list 0 (list :type "agent" :text "# Title\n\npara more\n\n```\nx"))))
          (drgnx-agent-panel-test--text buf)
          (should-not rendered))
        (goto-char (point-min))
        (search-forward "more")
        (should (memq 'drgnx-agent-panel-md-strong (ensure-list (get-text-property (1- (point)) 'face))))
        (goto-char (point-min))
        (search-forward "Title")
        (should (memq 'drgnx-agent-panel-md-heading (ensure-list (get-text-property (1- (point)) 'face))))))))

(ert-deftest drgnx-agent-panel/a-message-without-blocks-falls-back-to-its-text ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      ;; a message with blocks is drawn from them, not from its raw text
      (drgnx-agent-panel--take-entries
       (list (list 0 (list :type "agent" :text "raw *source*"
                           :blocks (vector (drgnx-agent-panel-test--block 0 "paragraph" '("styled" . "emph")))))))
      ;; one without draws its text
      (drgnx-agent-panel--take-entries (list (list 1 (list :type "agent" :text "plain words"))))
      (let ((text (drgnx-agent-panel-test--text buf)))
        (should (string-match-p "styled" text))
        (should-not (string-match-p "raw \\*source\\*" text))
        (should (string-match-p "plain words" text))))))

(ert-deftest drgnx-agent-panel/a-chip-without-a-feed-is-hidden ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-snapshot (list :id "s1" :name "Claude" :status "idle" :profile "Claude" :mode "queue"))
      (let ((text (drgnx-agent-panel-test--text buf)))
        (should (string-match-p "queue" text))
        (should-not (string-match-p "MCP" text))
        (should-not (string-match-p "checkpoints" text))
        (should-not (string-match-p "\\$" text))
        (should-not (string-match-p "files" text)))
      (drgnx-agent-panel--take-snapshot (list :id "s1" :name "Claude" :status "idle" :profile "Claude" :mode "queue"
                                              :usage (list :used 50 :size 100 :cost 0.25) :files_edited 3 :mcp 2))
      (let ((text (drgnx-agent-panel-test--text buf)))
        (should (string-match-p "50%" text))
        (should (string-match-p "\\$0.25" text))
        (should (string-match-p "3 files" text))
        (should (string-match-p "MCP 2" text))))))

(ert-deftest drgnx-agent-panel/thinking-folds-under-its-step ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-entries
       (list (list 0 (drgnx-agent-panel-test--tool "t1" "Grep foo" "completed"))
             (list 1 (list :type "thought" :text "first idea\nsecond idea"))))
      (let ((text (drgnx-agent-panel-test--text buf)))
        (should (string-match-p "▸ thinking · 2 lines" text))
        (should-not (string-match-p "first idea" text))
        ;; the thought is not a row of its own
        (should-not (drgnx-view-row-start drgnx-view '(:e 1))))
      (goto-char (drgnx-view-row-start drgnx-view '(:e 0)))
      (drgnx-agent-panel-toggle)
      (should (string-match-p "first idea" (drgnx-agent-panel-test--text buf)))
      ;; a thought that arrives later patches its step's row
      (drgnx-agent-panel--take-entries (list (list 2 (list :type "thought" :text "third"))))
      (should (string-match-p "third" (drgnx-agent-panel-test--text buf)))
      ;; a thought with no step before it is a row
      (drgnx-agent-panel--take-entries (list (list 3 (list :type "user" :text "x")) (list 4 (list :type "thought" :text "alone"))))
      (drgnx-agent-panel-test--text buf)
      (should (with-current-buffer buf (drgnx-view-row-start drgnx-view '(:e 4)))))))

(ert-deftest drgnx-agent-panel/time-and-cost-are-in-warn-when-slow-or-dear ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-steps (list (list :seq 1 :start 0.0 :end 0.5 :cost 0.01)
                                           (list :seq 2 :start 0.0 :end 30.0 :cost 2.0)))
      (drgnx-agent-panel--take-entries
       (list (list 0 (drgnx-agent-panel-test--tool "t1" "Quick" "completed" :step 1))
             (list 1 (drgnx-agent-panel-test--tool "t2" "Slow" "completed" :step 2))))
      (let ((text (drgnx-agent-panel-test--text buf)))
        (should (string-match-p "500 ms" text))
        (should (string-match-p "\\$2.00" text)))
      (let* ((s (with-current-buffer buf (buffer-string)))
             (pos (string-search "30.0 s" s)))
        (should (memq 'drgnx-agent-panel-warn (ensure-list (get-text-property pos 'face s))))
        (should-not (memq 'drgnx-agent-panel-warn (ensure-list (get-text-property (string-search "500 ms" s) 'face s))))))))

(ert-deftest drgnx-agent-panel/off-leaves-no-panel-and-no-hooks ()
  (let ((before (list window-buffer-change-functions drgnx-hub-event-functions drgnx-hub-connected-functions)))
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) 1)))
      (drgnx-test-with-modules '(tools/agent-panel)
        (drgnx-agent-panel-buffer "s9")
        (should (get-buffer "*drgnx agent: s9*"))))
    (should-not (get-buffer "*drgnx agent: s9*"))
    (should (equal before (list window-buffer-change-functions drgnx-hub-event-functions drgnx-hub-connected-functions)))))

(defvar drgnx-agent-panel-disclosure)
(defvar drgnx-agent-panel--disclosure)
(declare-function drgnx-agent-panel-preset "drgnx-agent-panel-steps")
(declare-function drgnx-agent-panel-make-default "drgnx-agent-panel-steps")
(declare-function drgnx-agent-panel-toggle-type "drgnx-agent-panel-steps")

(ert-deftest drgnx-agent-panel/a-failed-step-opens ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-entries
       (list (list 0 (drgnx-agent-panel-test--tool "t1" "Run ok" "completed" :content (list (list :text "r\nfine output"))))
             (list 1 (drgnx-agent-panel-test--tool "t2" "Run bad" "failed" :content (list (list :text "r\nboom output"))))))
      (let ((text (drgnx-agent-panel-test--text buf)))
        (should (string-match-p "boom output" text))
        (should-not (string-match-p "fine output" text)))
      ;; folding a failed step by hand wins over the outcome
      (goto-char (drgnx-view-row-start drgnx-view '(:e 1)))
      (drgnx-agent-panel-toggle)
      (should-not (string-match-p "boom output" (drgnx-agent-panel-test--text buf))))))

(ert-deftest drgnx-agent-panel/presets-switch-disclosure ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-entries
       (list (list 0 (drgnx-agent-panel-test--tool "t1" "Read it" "completed" :content (list (list :text "r\nread body"))))
             (list 1 (list :type "tool" :id "t2" :title "Edit it" :kind "edit" :status "completed" :content (list (list :text "r\nedit body"))))
             (list 2 (list :type "thought" :text "deep thought"))))
      (should-not (string-match-p "body" (drgnx-agent-panel-test--text buf)))
      (drgnx-agent-panel-preset 2)
      (let ((text (drgnx-agent-panel-test--text buf)))
        (should (string-match-p "edit body" text))
        (should-not (string-match-p "read body" text))
        (should-not (string-match-p "deep thought" text)))
      (drgnx-agent-panel-preset 3)
      (let ((text (drgnx-agent-panel-test--text buf)))
        (should (string-match-p "read body" text))
        (should (string-match-p "deep thought" text)))
      (drgnx-agent-panel-preset 1)
      (should-not (string-match-p "body" (drgnx-agent-panel-test--text buf)))
      ;; one toggle: a type opens on its own
      (drgnx-agent-panel-toggle-type 'read)
      (should (string-match-p "read body" (drgnx-agent-panel-test--text buf))))))

(ert-deftest drgnx-agent-panel/make-default-persists ()
  (drgnx-agent-panel-test--with
    (let ((saved nil) (drgnx-agent-panel-disclosure nil))
      (require 'drgnx-settings-editors nil t)
      (cl-letf (((symbol-function 'drgnx-settings-editors-commit)
                 (lambda (var tab root value) (push (list var tab root value) saved) value)))
        (with-current-buffer buf
          (drgnx-agent-panel-preset 2)
          (drgnx-agent-panel-make-default)))
      (should (equal '((drgnx-agent-panel-disclosure user nil (edit execute))) saved))
      (should (equal '(edit execute) drgnx-agent-panel-disclosure))
      ;; a panel made afterwards starts with it
      (let ((other (drgnx-agent-panel-buffer "s2")))
        (unwind-protect (should (equal '(edit execute) (buffer-local-value 'drgnx-agent-panel--disclosure other)))
          (kill-buffer other))))))

(declare-function drgnx-agent-panel-send "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-edit-queued "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-drop-queued "drgnx-agent-panel-composer")
(declare-function drgnx-command-define "drgnx-registry")

(ert-deftest drgnx-agent-panel/send-queues-while-the-agent-works ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-snapshot (list :id "s1" :status "busy" :mode "queue"))
      (setq drgnx-agent-panel-test--calls nil)
      (cl-letf (((symbol-function 'drgnx-agent-panel-composer--read) (lambda (_) " go on ")))
        (drgnx-agent-panel-send))
      ;; one send, and nothing that ends the turn
      (should (equal '(("agents/send" :id "s1" :text "go on")) (reverse drgnx-agent-panel-test--calls)))
      ;; a mode that would cancel is refused, nothing is sent
      (setq drgnx-agent-panel-test--calls nil)
      (drgnx-agent-panel--take-snapshot (list :id "s1" :status "busy" :mode "interrupt"))
      (cl-letf (((symbol-function 'drgnx-agent-panel-composer--read) (lambda (_) "stop now")))
        (should-error (drgnx-agent-panel-send) :type 'user-error))
      (should-not drgnx-agent-panel-test--calls))))

(ert-deftest drgnx-agent-panel/a-queued-note-is-editable-until-sent ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-snapshot (list :id "s1" :status "busy" :queue (list "first" "second")))
      (let ((text (drgnx-agent-panel-test--text buf)))
        (should (string-match-p "queued 1  first" text))
        (should (string-match-p "queued 2  second" text)))
      (goto-char (drgnx-view-row-start drgnx-view '(:q 1)))
      (cl-letf (((symbol-function 'read-string) (lambda (_p &optional init &rest _) (concat init " edited"))))
        (drgnx-agent-panel-edit-queued))
      (should (equal '("agents/do" :id "s1" :op "requeue" :n 1 :text "second edited") (car drgnx-agent-panel-test--calls)))
      (drgnx-agent-panel-drop-queued)
      (should (equal '("agents/do" :id "s1" :op "unqueue" :n 1) (car drgnx-agent-panel-test--calls)))
      ;; the hub's next snapshot is what the queue shows: the note is edited in place, the other is gone
      (drgnx-agent-panel--take-snapshot (list :id "s1" :status "busy" :queue (list "second edited")))
      (let ((text (drgnx-agent-panel-test--text buf)))
        (should (string-match-p "queued 1  second edited" text))
        (should-not (string-match-p "queued 2" text))))))

(ert-deftest drgnx-agent-panel/pair-chip-hidden-without-the-command ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-snapshot (list :id "s1" :status "idle" :paired t :waiting t))
      (should-not (string-match-p "Pair · waiting" (drgnx-agent-panel-test--text buf)))
      (drgnx-command-define 'agents-pair :category "Agents" :title "Pair" :command #'ignore :doc "test")
      (unwind-protect
          (progn (drgnx-agent-panel--take-snapshot (list :id "s1" :status "idle" :paired t :waiting t))
                 (should (string-match-p "Pair · waiting for you" (drgnx-agent-panel-test--text buf))))
        (drgnx-command-undefine 'agents-pair)))))

(declare-function drgnx-agent-panel-allow "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-always "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-reject "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-accept "drgnx-agent-panel-cards")

(ert-deftest drgnx-agent-panel/permission-card-keys ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-snapshot
       (list :id "s1" :status "waiting"
             :permissions (list (list :id 7 :title "Run rm -rf build"
                                      :options (list (list :optionId "allow" :kind "allow_once")
                                                     (list :optionId "always" :kind "allow_always")
                                                     (list :optionId "reject" :kind "reject_once"))))))
      (should (string-match-p "↵ Allow · A Always · D Deny" (drgnx-agent-panel-test--text buf)))
      (goto-char (drgnx-view-row-start drgnx-view '(:perm 7)))
      (should (eq 'drgnx-agent-panel-ring (get-text-property (point) 'face)))
      (drgnx-agent-panel-allow)
      (should (equal '("agents/permission" :id "s1" :request 7 :option "allow") (car drgnx-agent-panel-test--calls)))
      (drgnx-agent-panel-always)
      (should (equal '("agents/permission" :id "s1" :request 7 :option "always") (car drgnx-agent-panel-test--calls)))
      (drgnx-agent-panel-reject)
      (should (equal '("agents/permission" :id "s1" :request 7 :option "reject") (car drgnx-agent-panel-test--calls)))
      ;; a permission card is not a diff card
      (should-error (drgnx-agent-panel-accept) :type 'user-error)
      ;; answered: the hub's next snapshot has no request and the card goes
      (drgnx-agent-panel--take-snapshot (list :id "s1" :status "busy"))
      (should-not (string-match-p "Allow" (drgnx-agent-panel-test--text buf))))))

;; pattern D: pure rendering of a made-up entry
(ert-deftest drgnx-agent-panel/large-output-shows-head-and-tail ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (let ((text (mapconcat (lambda (i) (format "line %d" i)) (number-sequence 1 100) "\n")))
        (drgnx-agent-panel--take-entries
         (list (list 0 (drgnx-agent-panel-test--tool "t1" "Run it" "completed" :content (list (list :text text))))))
        (with-current-buffer buf (drgnx-agent-panel-preset-3))
        (let ((shown (drgnx-agent-panel-test--text buf)))
          (should (string-match-p "line 1$" shown))
          (should (string-match-p "line 10$" shown))
          (should (string-match-p "line 91$" shown))
          (should (string-match-p "line 100$" shown))
          (should-not (string-match-p "line 11$" shown))
          (should-not (string-match-p "line 90$" shown))
          (should (string-match-p "80 lines hidden · / search · O open in a buffer" shown)))
        ;; the hub kept only the ends of a huge output: the count is an estimate
        (drgnx-agent-panel--take-entries
         (list (list 0 (drgnx-agent-panel-test--tool "t1" "Run it" "completed" :content (list (list :text text))
                                                     :outputBytes (* 10 (string-bytes text))))))
        (should (string-match-p "~980 lines hidden" (drgnx-agent-panel-test--text buf)))
        ;; a short output is shown whole, with nothing hidden
        (drgnx-agent-panel--take-entries
         (list (list 0 (drgnx-agent-panel-test--tool "t1" "Run it" "completed" :content (list (list :text "a\nb\nc"))))))
        (let ((shown (drgnx-agent-panel-test--text buf)))
          (should (string-match-p "c$" shown))
          (should-not (string-match-p "hidden" shown)))))))

;;;; Task 39: checkpoints (revert and fork at a step)

(defun drgnx-agent-panel-test--with-steps ()
  "Feed buf two tool entries on steps 4 (revertible) and 5 (undone by record 9, not revertible)."
  (drgnx-agent-panel--take-steps (list (list :seq 4 :revertible t) (list :seq 5 :revertible :json-false :undone_by 9)))
  (drgnx-agent-panel--take-entries
   (list (list 0 (drgnx-agent-panel-test--tool "t1" "Edit a.el" "completed" :step 4))
         (list 1 (drgnx-agent-panel-test--tool "t2" "Edit b.el" "completed" :step 5)))))

(ert-deftest drgnx-agent-panel/revert-here-calls-the-history ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel-test--with-steps)
      (let (called)
        (cl-letf (((symbol-function 'drgnx-view-key-at) (lambda (&rest _) '(:e 0)))
                  ((symbol-function 'drgnx-history-revert-to-here) (lambda (s q) (setq called (list s q)))))
          (drgnx-agent-panel-revert-here)
          (should (equal called '("s1" 4))))
        ;; a step with no history record is refused, and so is a row that is not a step
        (cl-letf (((symbol-function 'drgnx-view-key-at) (lambda (&rest _) '(:e 1)))
                  ((symbol-function 'drgnx-history-revert-to-here) (lambda (&rest _) (error "must not be called"))))
          (should-error (drgnx-agent-panel-revert-here) :type 'user-error))
        (cl-letf (((symbol-function 'drgnx-view-key-at) (lambda (&rest _) '(:strip))))
          (should-error (drgnx-agent-panel-revert-here) :type 'user-error))))))

(ert-deftest drgnx-agent-panel/fork-here-shows-the-forecast-line ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel-test--with-steps)
      (let (prompt fork)
        (cl-letf (((symbol-function 'drgnx-view-key-at) (lambda (&rest _) '(:e 0)))
                  ((symbol-function 'drgnx-forecast-line) (lambda (_) "about $0.40 and 6 min"))
                  ((symbol-function 'drgnx-hub-call-sync)
                   (lambda (method params &rest _)
                     (if (equal method "history/fork") (progn (setq fork params) (list :id "s2")) (list :cost 0.4))))
                  ((symbol-function 'read-string) (lambda (p &rest _) (setq prompt p) "try again")))
          (drgnx-agent-panel-fork-here)
          (should (string-match-p "step 4" prompt))
          (should (string-match-p "about \\$0.40 and 6 min" prompt))
          (should (equal (list (plist-get fork :session) (plist-get fork :seq) (plist-get fork :message))
                         '("s1" 4 "try again"))))))))

(ert-deftest drgnx-agent-panel/undone-steps-are-marked ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel-test--with-steps)
      (let ((lines (split-string (drgnx-agent-panel-test--text buf) "\n")))
        (should (string-match-p "undone" (seq-find (lambda (l) (string-match-p "Edit b.el" l)) lines)))
        (should-not (string-match-p "undone" (seq-find (lambda (l) (string-match-p "Edit a.el" l)) lines)))))))

(ert-deftest drgnx-agent-panel/checkpoints-chip-names-the-restore-level ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-snapshot (list :id "s1" :name "Claude" :status "idle" :checkpoints 3 :restore_level "message"))
      (should (string-match-p "3 checkpoints · message" (drgnx-agent-panel-test--text buf)))
      (drgnx-agent-panel--take-snapshot (list :id "s1" :name "Claude" :status "idle" :checkpoints 3))
      (let ((text (drgnx-agent-panel-test--text buf)))
        (should (string-match-p "3 checkpoints" text))
        (should-not (string-match-p "checkpoints ·" text))))))

(ert-deftest drgnx-agent-panel/an-applied-history-reloads-the-step-rows ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel-test--with-steps)
      (let (asked cb)
        (cl-letf (((symbol-function 'drgnx-hub-call)
                   (lambda (method params callback &rest _) (push (cons method params) asked) (setq cb callback) 1)))
          (drgnx-agent-panel--event "history/applied" (list :op 9 :paths ["a.el"] :worktree "/w"))
          ;; one reload per event, of this panel's session, over the steps it holds
          (should (equal (length asked) 1))
          (should (equal (car (car asked)) "timeline/get"))
          (should (equal (plist-get (cdr (car asked)) :id) "s1"))
          (funcall cb (list :steps (vector (list :seq 4 :revertible :json-false :undone_by 11)
                                           (list :seq 5 :revertible t)))
                   nil))
        (let ((lines (split-string (drgnx-agent-panel-test--text buf) "\n")))
          (should (string-match-p "undone" (seq-find (lambda (l) (string-match-p "Edit a.el" l)) lines)))
          (should-not (string-match-p "undone" (seq-find (lambda (l) (string-match-p "Edit b.el" l)) lines))))))))

(provide 'agent-panel-test)
;;; agent-panel-test.el ends here
