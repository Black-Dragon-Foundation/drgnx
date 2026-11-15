;;; agent-panel-test.el --- the agent panel: its state, commands and clicks -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  No hub: the panel is fed snapshots and entries by hand, and the hub client's calls are recorded.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(require 'drgnx-history)
;; the panel's revert and fork commands require this library when they run: loaded first, so a test's stub of its
;; functions is not replaced by the library's own definitions mid-test (alone, the revert test waited on the hub)
(require 'drgnx-history-revert)
(load(expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agent-panel))

(declare-function drgnx-agent-panel-composer--bar "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel--composer-of "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel--look-params "drgnx-agent-panel")
(declare-function drgnx-agent-panel--key-at "drgnx-agent-panel")
(defvar drgnx-agent-panel--open)
(defvar drgnx-agent-panel--waiting)
(defvar drgnx-agent-panel--steps)
(defvar drgnx-agent-panel--grants)
(defvar drgnx-agent-panel--subscribed)
(defvar drgnx-hub--events)
(declare-function drgnx-agent-panel-buffer "drgnx-agent-panel")
(declare-function drgnx-agent-panel--take-entries "drgnx-agent-panel")
(declare-function drgnx-agent-panel--take-snapshot "drgnx-agent-panel")
(declare-function drgnx-agent-panel--take-steps "drgnx-agent-panel")
(declare-function drgnx-agent-panel-toggle "drgnx-agent-panel")
(declare-function drgnx-agent-panel--ask "drgnx-agent-panel")
(defvar drgnx-history--buffers)
(declare-function drgnx-history--st-make "drgnx-history")
(declare-function drgnx-agent-panel-reject "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-ledger "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-revert-here "drgnx-agent-panel")
(declare-function drgnx-agent-panel-fork-here "drgnx-agent-panel")
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

(defun drgnx-agent-panel-test--open-types ()
  "The step types the panel tells the hub are open (`agents/panel/look' `open'), sorted."
  (sort (append (plist-get (drgnx-agent-panel--look-params) :open) nil) #'string<))

(defvar drgnx-view-sja-tail)

(ert-deftest drgnx-agent-panel/the-transcript-opens-at-its-end ()
  "The transcript is a view that opens at its tail (`drgnx-view-sja-tail'): its first rows leave point at the end,
where Emacs keeps the latest step in view.  Red first: the panel opened on its first rows (docks plan Task 8,
agent-panel-long l-dark-s2-a: window start 55, the end off the window)."
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (should (local-variable-p 'drgnx-view-sja-tail))
      (should drgnx-view-sja-tail))))

(ert-deftest drgnx-agent-panel/presets-switch-disclosure ()
  "A preset is the step types open in the chat, which the hub hears; a hand fold goes back under the toggles."
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (should-not (drgnx-agent-panel-test--open-types))
      (drgnx-agent-panel-preset 2)
      (should (equal '("edit" "execute") (drgnx-agent-panel-test--open-types)))
      (should (= 2 (plist-get (drgnx-agent-panel--look-params) :lens_on)))
      (drgnx-agent-panel-preset 3)
      (should (equal '("edit" "execute" "fetch" "other" "read" "search" "thinking") (drgnx-agent-panel-test--open-types)))
      (puthash '(:e 0) 'closed drgnx-agent-panel--open)
      (drgnx-agent-panel-preset 1)
      (should-not (drgnx-agent-panel-test--open-types))
      (should (zerop (hash-table-count drgnx-agent-panel--open)))
      ;; one toggle: a type opens on its own
      (drgnx-agent-panel-toggle-type 'read)
      (should (equal '("read") (drgnx-agent-panel-test--open-types))))))

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
      (with-current-buffer (drgnx-agent-panel--composer-of buf) (insert " go on "))
      (drgnx-agent-panel-send)
      ;; one send, and nothing that ends the turn
      (should (equal '(("agents/send" :id "s1" :text "go on")) (reverse drgnx-agent-panel-test--calls)))
      ;; a mode that would cancel is refused, nothing is sent
      (setq drgnx-agent-panel-test--calls nil)
      (drgnx-agent-panel--take-snapshot (list :id "s1" :status "busy" :mode "interrupt"))
      (with-current-buffer (drgnx-agent-panel--composer-of buf) (insert "stop now"))
      (should-error (drgnx-agent-panel-send) :type 'user-error)
      (should-not drgnx-agent-panel-test--calls))))

(ert-deftest drgnx-agent-panel/a-queued-note-is-editable-until-sent ()
  "The queued notes are the hub's rows (`c:q:N'); a row names its number, which the edit and drop commands read at point."
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-snapshot (list :id "s1" :status "busy" :queue (list "first" "second")))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "queued 1  first\n" 'drgnx-agent-panel-queued 0)
                (propertize "queued 2  second\n" 'drgnx-agent-panel-queued 1)))
      (goto-char (point-min))
      (forward-line 1)
      (cl-letf (((symbol-function 'read-string) (lambda (_p &optional init &rest _) (concat init " edited"))))
        (drgnx-agent-panel-edit-queued))
      (should (equal '("agents/do" :id "s1" :op "requeue" :n 1 :text "second edited") (car drgnx-agent-panel-test--calls)))
      (drgnx-agent-panel-drop-queued)
      (should (equal '("agents/do" :id "s1" :op "unqueue" :n 1) (car drgnx-agent-panel-test--calls)))
      ;; not on a note: nothing to edit
      (goto-char (point-max))
      (let ((inhibit-read-only t)) (insert "plain"))
      (goto-char (1- (point-max)))
      (should-error (drgnx-agent-panel-drop-queued) :type 'user-error))))

(ert-deftest drgnx-agent-panel/pair-chip-hidden-without-the-command ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-snapshot (list :id "s1" :status "idle" :paired t :waiting t))
      (should-not (string-match-p "Pair · waiting" (drgnx-agent-panel-composer--bar)))
      (drgnx-command-define 'agents-pair :category "Agents" :title "Pair" :command #'ignore :doc "test")
      (unwind-protect
          (progn (drgnx-agent-panel--take-snapshot (list :id "s1" :status "idle" :paired t :waiting t))
                 (should (string-match-p "Pair · waiting for you" (drgnx-agent-panel-composer--bar))))
        (drgnx-command-undefine 'agents-pair)))))

(declare-function drgnx-agent-panel-allow "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-always "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-reject "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-accept "drgnx-agent-panel-cards")

(defun drgnx-agent-panel-test--on-card (buf card)
  "Put BUF's point on a row that carries CARD (a vector, as the hub's rows do): what the card commands read."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize "a card row" 'drgnx-agent-panel-card card))
      (goto-char (point-min)))))

(ert-deftest drgnx-agent-panel/permission-card-keys ()
  "The permission card is the hub's rows; its keys and buttons answer the request the row names (the id arrives as text)."
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-snapshot
       (list :id "s1" :status "waiting"
             :permissions (list (list :id 7 :title "Run rm -rf build"
                                      :options (list (list :optionId "allow" :kind "allow_once")
                                                     (list :optionId "always" :kind "allow_always")
                                                     (list :optionId "reject" :kind "reject_once"))))))
      (drgnx-agent-panel-test--on-card buf ["perm" "7"])
      (drgnx-agent-panel-allow)
      (should (equal '("agents/permission" :id "s1" :request 7 :option "allow") (car drgnx-agent-panel-test--calls)))
      (drgnx-agent-panel-always)
      (should (equal '("agents/permission" :id "s1" :request 7 :option "always") (assoc "agents/permission" drgnx-agent-panel-test--calls)))
      (drgnx-agent-panel-reject)
      (should (equal '("agents/permission" :id "s1" :request 7 :option "reject") (car drgnx-agent-panel-test--calls)))
      ;; a permission card is not a diff card
      (should-error (drgnx-agent-panel-accept) :type 'user-error))))

(ert-deftest drgnx-agent-panel/a-click-on-a-cards-button-runs-the-cards-command ()
  "The one click dispatcher: a card's button (`card:allow:7', `card:deny:7', `card:accept:PATH:0') runs the command for
the card its row names, point on that row."
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-snapshot
       (list :id "s1" :status "waiting"
             :permissions (list (list :id 7 :title "Run make"
                                      :options (list (list :optionId "allow" :kind "allow_once")
                                                     (list :optionId "reject" :kind "reject_once"))))))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize " Allow " 'drgnx-agent-panel-action "card:allow:7" 'drgnx-agent-panel-card ["perm" "7"])
                (propertize " Deny " 'drgnx-agent-panel-action "card:deny:7" 'drgnx-agent-panel-card ["perm" "7"])))
      (let ((click (drgnx-agent-panel-test--click buf " Deny ")))
        (drgnx-agent-panel-act click))
      (should (equal '("agents/permission" :id "s1" :request 7 :option "reject") (car drgnx-agent-panel-test--calls)))
      (let ((click (drgnx-agent-panel-test--click buf " Allow ")))
        (drgnx-agent-panel-act click))
      (should (equal '("agents/permission" :id "s1" :request 7 :option "allow") (car drgnx-agent-panel-test--calls))))))

(ert-deftest drgnx-agent-panel/accept-and-reject-ask-the-hub-for-the-diff-first ()
  "A diff card's Accept writes the review mark with the hash of the diff the hub holds, and Reject marks the file pending
and queues the take-it-back message: the panel keeps no diffs, so it asks `work/hunks' for the file first."
  (drgnx-agent-panel-test--with
    (load (expand-file-name "modules/tools/drgnx-work-review" drgnx-dir) nil t)
    (let ((diff "@@ -1 +1 @@\n-a\n+b\n"))
      (with-current-buffer buf
        (cl-letf (((symbol-function 'drgnx-hub-call)
                   (lambda (method params cb &rest _)
                     (push (cons method params) drgnx-agent-panel-test--calls)
                     (when (equal method "work/hunks") (funcall cb (list :diff diff) nil))
                     1)))
          (drgnx-agent-panel-test--on-card buf ["diff" "a.txt" 0])
          (drgnx-agent-panel-accept)
          (let ((mark (cdr (assoc "review/mark" drgnx-agent-panel-test--calls))))
            (should (equal "accepted" (plist-get mark :state)))
            (should (equal (secure-hash 'sha1 diff) (plist-get mark :hash))))
          (setq drgnx-agent-panel-test--calls nil)
          (drgnx-agent-panel-reject)
          (should (equal "pending" (plist-get (cdr (assoc "review/mark" drgnx-agent-panel-test--calls)) :state)))
          (should (string-prefix-p "I reject your change to a.txt (the hunk @@ -1 +1 @@)"
                                   (plist-get (cdr (assoc "agents/send" drgnx-agent-panel-test--calls)) :text))))))))

;;;; Task 39: checkpoints (revert and fork at a step)

(defun drgnx-agent-panel-test--with-steps ()
  "Feed buf two tool entries on steps 4 (revertible) and 5 (undone by record 9, not revertible)."
  (drgnx-agent-panel--take-steps (list (list :seq 4 :revertible t) (list :seq 5 :revertible :json-false :undone_by 9)))
  (drgnx-agent-panel--take-entries
   (list (list 0 (drgnx-agent-panel-test--tool "t1" "Edit a.el" "completed" :step 4))
         (list 1 (drgnx-agent-panel-test--tool "t2" "Edit b.el" "completed" :step 5)))))

(defun drgnx-agent-panel-test--on-entry (buf idx)
  "Put BUF's point on a row drawing entry IDX, as the hub's step rows carry it (`drgnx-agent-panel-entry'); IDX nil: a
row that draws no entry."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (if idx (propertize "  ● a step\n" 'drgnx-agent-panel-entry idx) "  a card\n"))
      (goto-char (+ (point-min) 3)))))

(ert-deftest drgnx-agent-panel/revert-here-calls-the-history ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel-test--with-steps)
      (let (called)
        (drgnx-agent-panel-test--on-entry buf 0)
        (should (equal '(:e 0) (drgnx-agent-panel--key-at)))
        (cl-letf (((symbol-function 'drgnx-history-revert-to-here) (lambda (s q) (setq called (list s q)))))
          (drgnx-agent-panel-revert-here)
          (should (equal called '("s1" 4))))
        ;; a step with no history record is refused, and so is a row that is not a step
        (drgnx-agent-panel-test--on-entry buf 1)
        (cl-letf (((symbol-function 'drgnx-history-revert-to-here) (lambda (&rest _) (error "must not be called"))))
          (should-error (drgnx-agent-panel-revert-here) :type 'user-error))
        (drgnx-agent-panel-test--on-entry buf nil)
        (should-not (drgnx-agent-panel--key-at))
        (should-error (drgnx-agent-panel-revert-here) :type 'user-error)))))

(ert-deftest drgnx-agent-panel/fork-here-shows-the-forecast-line ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel-test--with-steps)
      (drgnx-agent-panel-test--on-entry buf 0)
      (let (prompt fork)
        (cl-letf (((symbol-function 'drgnx-forecast-line) (lambda (_) "about $0.40 and 6 min"))
                  ((symbol-function 'drgnx-hub-call-sync)
                   (lambda (method params &rest _)
                     (if (equal method "history/fork") (progn (setq fork params) (list :id "s2")) (list :cost 0.4))))
                  ((symbol-function 'read-string) (lambda (p &rest _) (setq prompt p) "try again")))
          (drgnx-agent-panel-fork-here)
          (should (string-match-p "step 4" prompt))
          (should (string-match-p "about \\$0.40 and 6 min" prompt))
          (should (equal (list (plist-get fork :session) (plist-get fork :seq) (plist-get fork :message))
                         '("s1" 4 "try again"))))))))

(ert-deftest drgnx-agent-panel/an-applied-history-reloads-the-steps ()
  "A revert or fork elsewhere (`history/applied') reloads the steps the panel holds: what revert and fork at point read."
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
        (should (eql 11 (plist-get (gethash 4 drgnx-agent-panel--steps) :undone_by)))
        (should (eq t (plist-get (gethash 5 drgnx-agent-panel--steps) :revertible)))))))

;;;; Task 39a: a paired chat's hunks

(defun drgnx-agent-panel-test--paired (buf)
  "Make BUF a paired chat in /w whose open ledger (the hub's card) shows a hunk line: its text carries the hunk
\(`drgnx-agent-panel-op-hunk': op, path, index) Reject acts on; point is on it."
  (with-current-buffer buf
    (drgnx-agent-panel--take-snapshot (list :id "s1" :name "Pair" :status "idle" :paired t :cwd "/w"))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize " a.el  3–4" 'drgnx-agent-panel-op-hunk (list 7 "a.el" 0)))
      (goto-char (point-min)))))

(ert-deftest drgnx-agent-panel/reject-on-a-paired-hunk-reverts-that-operation ()
  (drgnx-agent-panel-test--with
    (drgnx-agent-panel-test--paired buf)
    (with-current-buffer buf
      (let (asked)
        (cl-letf (((symbol-function 'drgnx-hub-call)
                   (lambda (method params _cb &rest _) (push (cons method params) asked) 1)))
          (drgnx-agent-panel-reject))
        (should (equal (car asked) '("history/revert/hunk" :worktree "/w" :op 7 :path "a.el" :hunk 0)))))))

(ert-deftest drgnx-agent-panel/an-in-buffer-hunk-revert-keeps-later-typing ()
  (drgnx-agent-panel-test--with
    (drgnx-agent-panel-test--paired buf)
    (with-current-buffer buf
      (let ((file (generate-new-buffer " *hunk-file*")) cb)
        (unwind-protect
            (progn
              (with-current-buffer file (insert "NEW typed\n"))
              (puthash file (drgnx-history--st-make :id "b1") drgnx-history--buffers)
              (cl-letf (((symbol-function 'drgnx-hub-call)
                         (lambda (_m _p callback &rest _) (setq cb callback) 1))
                        ((symbol-function 'drgnx-history--hash) (lambda (_b) "h1")))
                (drgnx-agent-panel-reject)
                (funcall cb (list :state "in-buffer" :buffer_id "b1" :version "h1"
                                  :edits (vector (list :start 0 :old_len 3 :inserted "old")))
                         nil)
                (should (equal (with-current-buffer file (buffer-string)) "old typed\n"))
                ;; a buffer that moved on since the hub looked is left alone
                (with-current-buffer file (erase-buffer) (insert "NEW typed\n"))
                (cl-letf (((symbol-function 'drgnx-history--hash) (lambda (_b) "other")))
                  (funcall cb (list :state "in-buffer" :buffer_id "b1" :version "h1"
                                    :edits (vector (list :start 0 :old_len 3 :inserted "old")))
                           nil))
                (should (equal (with-current-buffer file (buffer-string)) "NEW typed\n"))))
          (kill-buffer file))))))

;;;; Huddles on the editor's conflict ranges

(declare-function drgnx-agent-panel-huddle--event "drgnx-agent-panel-huddle")
(declare-function drgnx-agents-editor-draw--conflict-help "drgnx-agents-editor-draw")
(defvar drgnx-agent-panel-huddle--open)

(ert-deftest drgnx-agent-panel/conflict-range-hover-names-the-open-huddle ()
  (drgnx-agent-panel-test--with
    (load (expand-file-name "modules/tools/drgnx-agents-editor-draw" drgnx-dir) nil t)
    (unwind-protect
        (progn
          (should (equal "x" (drgnx-agents-editor-draw--conflict-help 'conflict "x" "s1")))
          (drgnx-agent-panel-huddle--event "huddle" (list :huddle (drgnx-agent-panel-test--huddle)))
          (should (equal "x · huddle open · o opens it" (drgnx-agents-editor-draw--conflict-help 'conflict "x" "s1")))
          (should (equal "x" (drgnx-agents-editor-draw--conflict-help 'changed "x" "s1")))
          (should (equal "x" (drgnx-agents-editor-draw--conflict-help 'conflict "x" "s9")))
          (drgnx-agent-panel-huddle--event "huddle" (list :huddle (plist-put (drgnx-agent-panel-test--huddle) :state "decided")))
          (should (equal "x" (drgnx-agents-editor-draw--conflict-help 'conflict "x" "s1"))))
      (clrhash drgnx-agent-panel-huddle--open))))

;;;; Task 45: the panel replaces the Agents view

(require 'drgnx-work-client)
(load (expand-file-name "modules/tools/drgnx-work-map" drgnx-dir) nil t)
(declare-function drgnx-work--open-agent "drgnx-work-map")
(declare-function drgnx-agent-panel-list-buffer "drgnx-agent-panel-list")
(declare-function drgnx-agent-panel-list-open "drgnx-agent-panel-list")
(declare-function drgnx-agents--make "drgnx-agents")
(declare-function drgnx-agent-panel-open "drgnx-agent-panel")

(ert-deftest drgnx-agent-panel/enter-on-an-agent-card-opens-the-panel ()
  ;; part 2's Enter on an agent card (`drgnx-work--open-agent') opens the hub session's panel, not a transcript
  (let (opened)
    (cl-letf (((symbol-function 'drgnx-agent-panel-open) (lambda (session) (setq opened session))))
      (drgnx-work--open-agent "s1")
      (should (equal "s1" opened)))))

(ert-deftest drgnx-agent-panel/agents-view-lists-panels ()
  (drgnx-agent-panel-test--with
    (let ((sessions (list (drgnx-agents--make :name "alpha" :status 'busy :remote "h1")
                          (drgnx-agents--make :name "beta" :status 'idle :remote "h2")))
          opened list)
      (cl-letf (((symbol-function 'drgnx-agents-sessions) (lambda () sessions))
                ((symbol-function 'drgnx-agent-panel-open) (lambda (session) (setq opened session))))
        (unwind-protect
            (progn
              (setq list (drgnx-agent-panel-list-buffer))
              (let ((text (substring-no-properties (with-current-buffer list (buffer-string)))))
                (should (string-match-p "alpha .*busy" text))
                (should (string-match-p "beta .*idle" text)))
              (with-current-buffer list
                (goto-char (point-min))
                (search-forward "beta")
                (drgnx-agent-panel-list-open))
              (should (equal "h2" opened)))
          (when (buffer-live-p list) (kill-buffer list)))))))

(ert-deftest drgnx-agent-panel/p9-context-map-in-the-panel ()
  ;; the context map (the bar, each part, what /compact frees) is the context chip's popup now
  (drgnx-agent-panel-test--with
    (let* ((ctx (list :used 1200 :size 200000 :compact_frees 300
                      :parts (vector (list :kind "tool-output" :tokens 1000 :items (vector)))))
           (text (substring-no-properties
                  (drgnx-agent-panel-explain--popup-text
                   'context nil (list :id "s1" :panel (list :features [] :context ctx))))))
      (should (string-match-p "[█░]" text))
      (should (string-match-p "tool-output +1000 tokens" text))
      (should (string-match-p "/compact would free 300 tokens" text)))))

(ert-deftest drgnx-agent-panel/a-panel-waits-for-the-hubs-rows ()
  "The panel is the hub's view from the start, the hub up or not; until its first rows are drawn one line says it
waits for the hub, and it draws no row of its own."
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (should (equal "agent-panel/s1" (drgnx-view-patch-view drgnx-view-patch)))
      (should (overlayp drgnx-agent-panel--waiting))
      (should (string-search "Waiting for the hub" (overlay-get drgnx-agent-panel--waiting 'before-string)))
      (should (= (point-min) (point-max)))
      ;; the first rows drawn take the line away
      (run-hook-with-args 'drgnx-view-patch-patched-functions nil '("e:0"))
      (should-not drgnx-agent-panel--waiting))))

(provide 'agent-panel-test)
;;; agent-panel-test.el ends here

;;;; Task 42: why each step was allowed, and what each chip means

(declare-function drgnx-agent-panel-explain--popup-text "drgnx-agent-panel-explain")
(declare-function drgnx-agent-panel-revoke-always "drgnx-agent-panel-explain")

(declare-function drgnx-agent-panel-explain-take-grants "drgnx-agent-panel-explain")

(defun drgnx-agent-panel-test--grant (&optional revoked)
  (list :id "always:s1:read-1" :session "s1" :tool "read" :key "read-1" :title "Run make" :at 1.0
        :revoked (if revoked t :false)))

(ert-deftest drgnx-agent-panel/an-always-answer-asks-the-hub-for-its-grants ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-snapshot
       (list :id "s1" :status "waiting"
             :permissions (list (list :id 7 :title "Run make" :tool (list :id "t1")
                                      :options (list (list :optionId "allow" :kind "allow_once")
                                                     (list :optionId "always" :kind "allow_always"))))))
      (drgnx-agent-panel-test--text buf)
      (drgnx-agent-panel-test--on-card buf ["perm" "7"])
      (drgnx-agent-panel-always)
      (should (assoc "agents/permission" drgnx-agent-panel-test--calls))
      (should (equal '(:id "s1") (cdr (assoc "agents/grants" drgnx-agent-panel-test--calls)))))))

(ert-deftest drgnx-agent-panel/revoke-an-always ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-entries (list (list 0 (drgnx-agent-panel-test--tool "t1" "Run make" "completed"))))
      (drgnx-agent-panel-explain-take-grants (list :grants (list (drgnx-agent-panel-test--grant))))
      (drgnx-agent-panel-test--on-entry buf 0)
      (let (asked forked)
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (setq asked t) "Take back, keep running"))
                  ((symbol-function 'drgnx-history-fork-here) (lambda (&rest a) (setq forked a))))
          (drgnx-agent-panel-revoke-always))
        ;; the hub is asked to take the grant back; the panel does not forget it by itself
        (should asked)
        (should (equal '(:id "s1" :grant "always:s1:read-1") (cdr (assoc "agents/grants/revoke" drgnx-agent-panel-test--calls))))
        (should-not forked)
        (should (equal "always:s1:read-1" (plist-get (car drgnx-agent-panel--grants) :id)))))))

(ert-deftest drgnx-agent-panel/revoke-and-restart-forks-at-the-latest-step ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-steps (list (list :seq 4) (list :seq 9)))
      (drgnx-agent-panel--take-entries (list (list 0 (drgnx-agent-panel-test--tool "t1" "Run make" "completed"))))
      (drgnx-agent-panel-explain-take-grants (list :grants (list (drgnx-agent-panel-test--grant))))
      (drgnx-agent-panel-test--on-entry buf 0)
      (let (forked)
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Take back and restart at the latest step"))
                  ((symbol-function 'drgnx-history-fork-here) (lambda (&rest a) (setq forked a))))
          (drgnx-agent-panel-revoke-always))
        (should (equal '("s1" 9) forked))))))

(ert-deftest drgnx-agent-panel/context-popup-shows-drop-only-when-advertised ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (let* ((ctx (list :used 1200 :size 200000 :compact_frees 300
                        :parts (vector (list :kind "tool-output" :tokens 1000
                                             :items (vector (list :id "i1" :label "Bash ls" :tokens 1000))))))
             (snap (lambda (features) (list :id "s1" :panel (list :features features :context ctx))))
             (facts (list (list :name "used" :value "1200 of 200000 tokens")))
             (text (lambda (features)
                     (substring-no-properties
                      (drgnx-agent-panel-explain--popup-text 'context facts (funcall snap (vconcat features)))))))
        (should (string-match-p "Bash ls" (funcall text '("context"))))
        (should (string-match-p "1200 of 200000 tokens" (funcall text '("context"))))
        (should-not (string-match-p "\\[drop\\]" (funcall text '("context"))))
        (should-not (string-match-p "\\[pin\\]" (funcall text '("context"))))
        (should-not (string-match-p "What /compact keeps" (funcall text '("context"))))
        (should (string-match-p "\\[drop\\]" (funcall text '("context" "drop"))))
        (should (string-match-p "\\[pin\\]" (funcall text '("context" "pin"))))
        (should (string-match-p "What /compact keeps" (funcall text '("context" "compact-preview"))))))))

(ert-deftest drgnx-agent-panel/a-chip-opens-its-facts-from-the-hub ()
  "A chip (the hub's row, its text carrying `drgnx-agent-panel-chip') asks the hub for the facts behind it."
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize " MCP 2 " 'drgnx-agent-panel-chip "mcp"))
        (goto-char (point-min))
        (let ((item (intern (get-text-property (point) 'drgnx-agent-panel-chip))))
          (should (eq item 'mcp))
          (drgnx-agent-panel-chip item)))
      (should (equal '("agents/explain" :id "s1" :item "mcp") (car drgnx-agent-panel-test--calls))))))

;;;; Task 43: subagents and huddle threads

(declare-function drgnx-agent-panel-huddle-buffer "drgnx-agent-panel-huddle")
(declare-function drgnx-agent-panel-huddle--take "drgnx-agent-panel-huddle")
(declare-function drgnx-agent-panel-huddle-send "drgnx-agent-panel-huddle")
(declare-function drgnx-agent-panel-huddle-of "drgnx-agent-panel-huddle")

(defun drgnx-agent-panel-test--huddle ()
  (list :id "huddle:1" :clash "src/a.el" :participants (vector "s1" "s2") :state "open"
        :replies (vector (list :from "s1" :text "I would keep the old API" :proposal "keep")
                         (list :from "s2" :text "I would drop it"))))

(ert-deftest drgnx-agent-panel/huddle-thread-shows-both-positions-quoted ()
  (drgnx-agent-panel-test--with
    (let ((hb (drgnx-agent-panel-huddle-buffer "huddle:1")))
      (unwind-protect
          (progn
            (with-current-buffer hb (drgnx-agent-panel-huddle--take (drgnx-agent-panel-test--huddle)))
            (let ((text (drgnx-agent-panel-test--text hb)))
              (should (string-match-p "▎ I would keep the old API" text))
              (should (string-match-p "▎ I would drop it" text))
              (should (string-match-p "s1" text))
              (should (string-match-p "s2" text))
              (should (string-match-p "src/a.el" text))
              (should (string-match-p "open" text)))
            ;; a thread taking the record also keeps it for the strip and the conflict hover
            (should (equal "huddle:1" (plist-get (drgnx-agent-panel-huddle-of "s1") :id))))
        (clrhash drgnx-agent-panel-huddle--open)
        (kill-buffer hb)))))

(ert-deftest drgnx-agent-panel/composer-in-a-huddle-sends-to-both ()
  (drgnx-agent-panel-test--with
    (let ((hb (drgnx-agent-panel-huddle-buffer "huddle:1")))
      (unwind-protect
          (with-current-buffer hb
            (drgnx-agent-panel-huddle--take (drgnx-agent-panel-test--huddle))
            (drgnx-agent-panel-huddle-send "settle it with a shim")
            (should (equal '(("agents/send" :id "s2" :text "settle it with a shim")
                             ("agents/send" :id "s1" :text "settle it with a shim"))
                           (seq-filter (lambda (c) (equal (car c) "agents/send")) drgnx-agent-panel-test--calls))))
        (kill-buffer hb)))))

;;;; Task 44: session control

(declare-function drgnx-agent-panel--offer-modes "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-move "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-compact "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel--compact-after-preview "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel-start "drgnx-agent-panel-composer")

(ert-deftest drgnx-agent-panel/mode-chip-offers-only-the-allow-list ()
  (drgnx-agent-panel-test--with
    (let (coll)
      (cl-letf (((symbol-function 'completing-read) (lambda (_p c &rest _) (setq coll c) "plan")))
        (drgnx-agent-panel--offer-modes buf (list (list :name "allowed switches" :value "default, plan")))
        (should (equal '("default" "plan") coll))
        (should (equal '("agents/config" :id "s1" :option "mode" :value "plan")
                       (car drgnx-agent-panel-test--calls))))
      ;; a lock that allows none refuses, with the hub's reason
      (setq drgnx-agent-panel-test--calls nil)
      (let ((err (should-error (drgnx-agent-panel--offer-modes
                                buf (list (list :name "allowed switches" :value "none")
                                          (list :name "other modes are refused because" :value "the matrix says so")))
                               :type 'user-error)))
        (should (string-match-p "the matrix says so" (cadr err))))
      (should-not drgnx-agent-panel-test--calls))))

(ert-deftest drgnx-agent-panel/move-to-another-profile ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-snapshot (list :id "s1" :status "idle" :profile "Claude"))
      (let (coll)
        (cl-letf (((symbol-function 'drgnx-agents-profile-names) (lambda () '("Claude" "Gemini")))
                  ((symbol-function 'completing-read) (lambda (_p c &rest _) (setq coll c) "Gemini"))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (drgnx-agent-panel-move)
          (should (equal '("Gemini") coll))
          (should (equal '("agents/move" :id "s1" :profile "Gemini") (car drgnx-agent-panel-test--calls))))))))

(ert-deftest drgnx-agent-panel/compact-shows-the-preview-when-advertised ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        ;; not advertised: a plain /compact after the question
        (drgnx-agent-panel--take-snapshot (list :id "s1" :status "idle"))
        (drgnx-agent-panel-compact)
        (should (equal '("agents/send" :id "s1" :text "/compact") (car drgnx-agent-panel-test--calls)))
        ;; advertised: the preview is asked first, and /compact goes after the answer
        (setq drgnx-agent-panel-test--calls nil)
        (drgnx-agent-panel--take-snapshot (list :id "s1" :status "idle" :panel (list :features (vector "compact-preview"))))
        (drgnx-agent-panel-compact)
        (should (equal '(("agents/compact-preview" :id "s1")) drgnx-agent-panel-test--calls))
        (drgnx-agent-panel--compact-after-preview buf (list :frees 900 :note "kept: the plan"))
        (should (equal '("agents/send" :id "s1" :text "/compact") (car drgnx-agent-panel-test--calls)))
        (kill-buffer "*agent compact preview*")))))

(ert-deftest drgnx-agent-panel/start-a-session-in-this-folder ()
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (drgnx-agent-panel--take-snapshot (list :id "s1" :status "idle" :cwd "/work/p"))
      (cl-letf (((symbol-function 'drgnx-agents-profile-names) (lambda () '("Claude" "Gemini")))
                ((symbol-function 'completing-read) (lambda (&rest _) "Gemini")))
        (drgnx-agent-panel-start)
        (should (equal '("agents/start" :profile "Gemini" :cwd "/work/p") (car drgnx-agent-panel-test--calls)))))))

(ert-deftest drgnx-agent-panel/killed-without-the-hub-asks-nothing ()
  "Pattern D: a subscribed panel killed after the hub went (no events connection) asks the hub nothing and signals
nothing: the subscription went with the connection, and a kill hook never signals."
  (drgnx-test-with-modules '(tools/agent-panel)
    (let ((calls 0) buf)
      (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) (cl-incf calls) 1))
                ((symbol-function 'drgnx-hub--call-on) (lambda (&rest _) (cl-incf calls) 1)))
        (let ((drgnx-hub--events nil))
          (setq buf (drgnx-agent-panel-buffer "gone-hub") calls 0)
          (with-current-buffer buf (setq drgnx-agent-panel--subscribed t))
          (kill-buffer buf))
        (should (zerop calls))))))

;; The audit's G1: the panel opened as a tab of the editor, because nothing loaded the pane kinds' library and the
;; setup's `fboundp' guard skipped the kind
(ert-deftest drgnx-agent-panel/opens-in-the-right-island ()
  "The module's setup defines the pane kind `agent-panel' with its home on the right, so opening a session shows the
panel in the right island (agent-panel.html), not as a tab of the editor."
  (drgnx-test-with-modules '(tools/agent-panel)
    (should (fboundp 'drgnx-pane-show))
    (should (eq 'right (plist-get (drgnx-pane-kind 'agent-panel) :home)))))

(ert-deftest drgnx-agent-panel/prose-in-the-ui-font-output-in-code ()
  "agent-panel.html: the panel's text (header, chips, steps, messages) is in the UI font, a tool's output, the diffs
and code in the code font."
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (should (memq 'drgnx-ui-text (ensure-list (alist-get 'default face-remapping-alist)))))
    (dolist (f '(drgnx-agent-panel-output drgnx-agent-panel-context drgnx-agent-panel-added drgnx-agent-panel-removed
                                          drgnx-agent-panel-code drgnx-agent-panel-md-code))
      (should (facep f))
      (should (drgnx-agent-panel-test--inherits-p f 'drgnx-code-small)))))

(defun drgnx-agent-panel-test--inherits-p (face target)
  "Whether FACE is TARGET or inherits it, through any depth."
  (or (eq face target)
      (and (facep face)
           (seq-some (lambda (p) (drgnx-agent-panel-test--inherits-p p target))
                     (ensure-list (face-attribute face :inherit nil))))))

(defun drgnx-agent-panel-test--face-at (s text)
  "The face list of the first character of TEXT in string S."
  (ensure-list (get-text-property (string-search text s) 'face s)))

(defun drgnx-agent-panel-test--click (buf text)
  "A mouse-1 event on the first TEXT of BUF, shown in the selected window."
  (set-window-buffer (selected-window) buf)
  (list 'mouse-1 (list (selected-window) (with-current-buffer buf (1+ (string-search text (buffer-string))))
                       '(0 . 0) 0)))

(ert-deftest drgnx-agent-panel/a-click-on-the-hubs-header-runs-its-action ()
  "The header and the chips are the hub's rows, whose clickable parts carry `drgnx-agent-panel-action' (`lens:N', `pin',
`more') or `drgnx-agent-panel-chip': one dispatcher runs the part's action; a click on plain text runs nothing."
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (let ((inhibit-read-only t) ran)
        (erase-buffer)
        (insert (propertize " review " 'drgnx-agent-panel-action "lens:2") (propertize " P " 'drgnx-agent-panel-action "pin")
                (propertize " M " 'drgnx-agent-panel-action "more") (propertize " 50% " 'drgnx-agent-panel-chip "context")
                " plain")
        (cl-letf (((symbol-function 'drgnx-agent-panel-preset) (lambda (n) (push (list 'preset n) ran)))
                  ((symbol-function 'drgnx-ui-kit-run) (lambda (c) (push (list 'run c) ran)))
                  ((symbol-function 'drgnx-agent-panel-header-menu) (lambda (_e) (push 'menu ran)))
                  ((symbol-function 'drgnx-agent-panel-chip) (lambda (c) (push (list 'chip c) ran))))
          (dolist (text '("review" "P " "M " "50%" "plain")) (drgnx-agent-panel-act (drgnx-agent-panel-test--click buf text)))
          (should (equal (reverse ran) '((preset 2) (run agents-panel-pin) menu (chip context)))))
        (should (drgnx-commands-get 'agents-panel-act))
        (should-not (drgnx-commands-get 'agents-panel-press))
        (should-not (drgnx-commands-get 'agents-panel-drag))
        (dolist (c (mapcar #'cdr drgnx-agent-panel-header-menu)) (should (drgnx-commands-get c)))))))

(ert-deftest drgnx-agent-panel/the-strips-pills-and-make-default-are-clicks ()
  "The strip is the hub's rows: a pill carries `type:NAME' and \"make default\" `default'; the dispatcher flips the type
or makes the default."
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (let ((inhibit-read-only t) ran)
        (erase-buffer)
        (insert (propertize " edit " 'drgnx-agent-panel-action "type:edit")
                (propertize "make default" 'drgnx-agent-panel-action "default"))
        (cl-letf (((symbol-function 'drgnx-agent-panel-toggle-type) (lambda (ty) (push (list 'type ty) ran)))
                  ((symbol-function 'drgnx-agent-panel-make-default) (lambda () (push 'default ran))))
          (dolist (text '("edit" "make")) (drgnx-agent-panel-act (drgnx-agent-panel-test--click buf text)))
          (should (equal (reverse ran) '((type edit) default))))
        (dolist (face '(drgnx-agent-panel-tag drgnx-agent-panel-tag-on))
          (should (facep face)))
        (should (drgnx-agent-panel-test--inherits-p 'drgnx-agent-panel-tag 'drgnx-pill))
        (should (drgnx-agent-panel-test--inherits-p 'drgnx-agent-panel-tag-on 'drgnx-pill-on))))))

(ert-deftest drgnx-agent-panel/the-composers-bar-has-its-chips-and-buttons ()
  "agent-panel.html `.composer': the bar under the field (the field is the composer's buffer,
agent-panel-composer-test): the model and the mode as chips that switch them, Fork, the pause icon and Send (an
arrow) as buttons."
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (setq drgnx-agent-panel--snap (list :model "opus" :mode "accept edits"))
      (let ((row (drgnx-agent-panel-composer--bar)))
        (should (memq 'drgnx-agent-panel-chip (drgnx-agent-panel-test--face-at row "opus")))
        (should (eq 'drgnx-agent-panel-switch-model
                    (lookup-key (get-text-property (string-search "opus" row) 'keymap row) [mouse-1])))
        (should (eq 'drgnx-agent-panel-switch-mode
                    (lookup-key (get-text-property (string-search "accept edits" row) 'keymap row) [mouse-1])))
        ;; the bar's buttons: Fork, the pause icon (stop after this step), Send as the primary arrow
        (let ((send (string-search (drgnx-face-glyph 'arrow-up) row))
              (pause (string-search (drgnx-face-glyph 'pause) row)))
          (should (memq 'drgnx-ui-button-primary (ensure-list (get-text-property send 'face row))))
          (should (eq 'drgnx-agent-panel-send (lookup-key (get-text-property send 'keymap row) [mouse-1])))
          (should (eq 'drgnx-agent-panel-pause (lookup-key (get-text-property pause 'keymap row) [mouse-1]))))
        (should (eq 'drgnx-agent-panel-fork
                    (lookup-key (get-text-property (string-search "Fork" row) 'keymap row) [mouse-1])))))))

(ert-deftest drgnx-agent-panel/a-preset-tells-the-hub-the-lens ()
  "Picking a preset tells the hub which one is in force (`agents/panel/look' `lens_on'), so its header's lens shows it,
and the presets' names it lays the lens out of."
  (drgnx-agent-panel-test--with
    (with-current-buffer buf
      (let ((params (drgnx-agent-panel--look-params)))
        (should (equal (append (plist-get params :lens) nil) (mapcar (lambda (p) (symbol-name (car p))) drgnx-agent-panel-presets))))
      (drgnx-agent-panel-preset 3)
      (should (= 3 (plist-get (drgnx-agent-panel--look-params) :lens_on))))))
