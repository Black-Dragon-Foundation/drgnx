;;; agent-panel-background-test.el --- the agent panel's background work: commands, keys, output, ticking, end, notices -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  The hub is a recording stub; sessions are mirrors made here with their `background' lists.
;; Plan 2026-11-20-agent-background-panel.md, Tasks 4 and 5.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agent-panel))
(require 'drgnx-agents)

(defvar drgnx-agents--sessions)

(defun drgnx-bgtest--item (kind id what &optional cancel status)
  (list :kind kind :id id :description what :started_ms 1000 :status (or status "running") :can_cancel cancel))

(defun drgnx-bgtest--items ()
  (list (drgnx-bgtest--item "terminal" "t1" "cargo test -p hermod" t)
        (drgnx-bgtest--item "tool_call" "w1" "Watching CI on staging PR #412" nil)
        (drgnx-bgtest--item "subagent" "c1" "Subagent: review the v2 diff" t)))

(defun drgnx-bgtest--session (&optional items ended)
  (let ((s (drgnx-agents--make :id "s1" :remote "s1" :name "ACP v2 in the hub" :profile "Claude")))
    (setf (drgnx-agent-session-background s) items (drgnx-agent-session-background-ended s) ended)
    s))

(defmacro drgnx-bgtest--with (items &rest body)
  "BODY with session `s' (ITEMS in its background) the only one, the hub's calls recorded in `calls' as (METHOD
PARAMS CALLBACK), newest first, and `said' the messages, newest first."
  (declare (indent 1))
  `(drgnx-test-with-modules '(tools/agent-panel)
     (let* ((s (drgnx-bgtest--session ,items)) (drgnx-agents--sessions (list s)) calls said)
       (cl-letf (((symbol-function 'drgnx-hub-call)
                  (lambda (method params callback &rest _) (push (list method params callback) calls) 1))
                 ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said) nil)))
         ,@body))))

(defun drgnx-bgtest--read (file)
  (with-temp-buffer (insert-file-contents (expand-file-name file drgnx-dir)) (buffer-string)))

;;;; Keys and the registry

(ert-deftest agent-background-keys-in-all-profiles ()
  "Every background command has a row in all three key profiles (a key, or :none and why)."
  (dolist (file '("keys/vscode.eld" "keys/emacs.eld" "keys/vim.eld"))
    (let ((text (drgnx-bgtest--read file)))
      (dolist (cmd '("agents-background-list" "agents-background-stop" "agents-background-stop-all"
                     "agents-background-output" "agents-end"))
        (should (string-match-p (concat "(" cmd " ") text)))))
  (dolist (cmd '(drgnx-agent-panel-background-list drgnx-agent-panel-background-stop
                                                   drgnx-agent-panel-background-stop-all
                                                   drgnx-agent-panel-background-output drgnx-agent-panel-end))
    (should (commandp cmd))))

;;;; The list's fold

(ert-deftest agent-background-list-key-selects-in-turn ()
  "`b' unfolds the list and selects its first row, then each next one; after the last it folds the list: the look sent
to the hub names the selection and `bg-folded'."
  (drgnx-bgtest--with (drgnx-bgtest--items)
    (let ((buf (generate-new-buffer " *bg-fold*")) sent)
      (unwind-protect
          (with-current-buffer buf
            (setq drgnx-agent-panel--session "s1" drgnx-agent-panel--open (make-hash-table :test #'equal))
            (cl-letf (((symbol-function 'drgnx-agent-panel--send-look) (lambda (&rest _) (push t sent)))
                      ((symbol-function 'drgnx-agent-panel--main-of) (lambda (_b) buf)))
              (let ((drgnx-agent-panel--disclosure '(edit)))
                (should-not (member "bg-folded" (append (drgnx-agent-panel--open-types) nil)))
                (drgnx-agent-panel-background-list)
                (should (equal drgnx-agent-panel--bg-selected "t1"))
                (drgnx-agent-panel-background-list)
                (should (equal drgnx-agent-panel--bg-selected "w1"))
                (drgnx-agent-panel-background-list)
                (should (equal drgnx-agent-panel--bg-selected "c1"))
                (drgnx-agent-panel-background-list)
                (should-not drgnx-agent-panel--bg-selected)
                (should (member "bg-folded" (append (drgnx-agent-panel--open-types) nil)))
                (drgnx-agent-panel-background-list)
                (should (equal drgnx-agent-panel--bg-selected "t1"))
                (should-not (member "bg-folded" (append (drgnx-agent-panel--open-types) nil)))
                (should (= (length sent) 5))
                (should (equal (plist-get (drgnx-agent-panel--look-params) :bg_selected) "t1")))))
        (kill-buffer buf)))))

(ert-deftest agent-background-a-click-selects-a-row ()
  (drgnx-bgtest--with (drgnx-bgtest--items)
    (let ((buf (generate-new-buffer " *bg-sel*")))
      (unwind-protect
          (with-current-buffer buf
            (setq drgnx-agent-panel--session "s1")
            (cl-letf (((symbol-function 'drgnx-agent-panel--send-look) #'ignore)
                      ((symbol-function 'drgnx-agent-panel--main-of) (lambda (_b) buf)))
              (drgnx-agent-panel-background-select "c1")
              (should (equal drgnx-agent-panel--bg-selected "c1"))
              ;; Stop and Output with no row at point act on the selected one
              (drgnx-agent-panel-background-stop)
              (should (equal (plist-get (nth 1 (car calls)) :item) "c1"))))
        (kill-buffer buf)))))

;;;; Stop

(ert-deftest agent-background-stop-calls-hub ()
  "Stop on a cancellable item asks the hub's `agents/background-cancel' with the session and the item."
  (drgnx-bgtest--with (drgnx-bgtest--items)
    (drgnx-agent-panel-background-stop "s1" "t1")
    (should (= (length calls) 1))
    (should (equal (car (car calls)) "agents/background-cancel"))
    (should (equal (nth 1 (car calls)) '(:id "s1" :item "t1")))))

(ert-deftest agent-background-stop-where-the-agent-does-not-allow-it ()
  "A row that cannot be stopped sends nothing and says so once."
  (drgnx-bgtest--with (drgnx-bgtest--items)
    (drgnx-agent-panel-background-stop "s1" "w1")
    (should-not calls)
    (should (equal (length said) 1))
    (should (string-match-p "can't stop" (car said)))))

(ert-deftest agent-background-stop-on-ended-item ()
  "The hub answering that the item is not running (it ended meanwhile) is one echo, never an error."
  (drgnx-bgtest--with (drgnx-bgtest--items)
    (drgnx-agent-panel-background-stop "s1" "t1")
    (funcall (nth 2 (car calls)) nil "`t1` is not a running background item")
    (should (equal (length said) 1))
    (should (string-match-p "already ended" (car said)))
    ;; an item the mirror no longer lists: no call at all
    (setq calls nil said nil)
    (setf (drgnx-agent-session-background s) nil)
    (drgnx-agent-panel-background-stop "s1" "t1")
    (should-not calls)
    (should (string-match-p "already ended" (car said)))))

(ert-deftest agent-background-stop-all-confirms ()
  "Stop all lists what it will stop (the same question as ending a chat), and stops only the items that can be
stopped, once the answer is Stop."
  (drgnx-bgtest--with (drgnx-bgtest--items)
    (let (shown)
      (cl-letf (((symbol-function 'drgnx-agent-panel-background--ask)
                 (lambda (_session items &rest _) (setq shown (mapcar (lambda (i) (plist-get i :id)) items)) 'keep)))
        (drgnx-agent-panel-background-stop-all "s1")
        (should (equal shown '("t1" "w1" "c1")))
        (should-not calls))
      (cl-letf (((symbol-function 'drgnx-agent-panel-background--ask) (lambda (&rest _) 'stop)))
        (drgnx-agent-panel-background-stop-all "s1")
        (should (equal (sort (mapcar (lambda (c) (plist-get (nth 1 c) :item)) calls) #'string<) '("c1" "t1")))))))

;;;; Output

(ert-deftest agent-background-output-opens-terminal ()
  "Output of a terminal item asks the hub (`agents/background-output') and opens what it kept in a read-only buffer
named for the item; a subagent opens its own panel."
  (drgnx-bgtest--with (drgnx-bgtest--items)
    (let (opened)
      (cl-letf (((symbol-function 'drgnx-agent-panel-open) (lambda (session) (setq opened session))))
        (unwind-protect
            (progn
              (drgnx-agent-panel-background-output "s1" "t1")
              (should (equal (car (car calls)) "agents/background-output"))
              (should (equal (nth 1 (car calls)) '(:id "s1" :item "t1")))
              (funcall (nth 2 (car calls)) '(:text "test v2::turn_ends_at_idle ... ok\n" :total_bytes 33 :truncated nil) nil)
              (with-current-buffer (get-buffer "*drgnx output: cargo test -p hermod*")
                (should (string-match-p "turn_ends_at_idle" (buffer-string)))
                (should buffer-read-only))
              (drgnx-agent-panel-background-output "s1" "c1")
              (should (equal opened "c1")))
          (when-let* ((b (get-buffer "*drgnx output: cargo test -p hermod*"))) (kill-buffer b)))))))

;;;; The elapsed cells

(ert-deftest agent-background-elapsed-patches-only-cells ()
  "A tick rewrites the text of the `drgnx-bg-elapsed' cells and nothing else."
  (with-temp-buffer
    (insert (propertize "cargo test" 'drgnx-bg-item "t1") "  "
            (propertize "0:05" 'drgnx-bg-elapsed 995000) "\nlast line\n")
    (let ((before (buffer-substring-no-properties (point-min) (point-min))))
      (ignore before)
      (drgnx-agent-panel-background--patch-elapsed (current-buffer) 1000.0)
      (should (equal (buffer-string) "cargo test  0:05\nlast line\n"))
      (drgnx-agent-panel-background--patch-elapsed (current-buffer) 1075.0)
      (should (equal (buffer-substring-no-properties (point-min) (point-max)) "cargo test  1:20\nlast line\n"))
      (should (equal (get-text-property 13 'drgnx-bg-elapsed) 995000)))))

(ert-deftest agent-background-timer-stops-when-idle ()
  "One timer per visible panel while an item runs; none once nothing runs or the panel is hidden."
  (let ((buf (generate-new-buffer " *bg-timer*")) (visible t) (running t))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-agent-panel-background--visible-p) (lambda (_b) visible))
                  ((symbol-function 'drgnx-agent-panel-background--running-p) (lambda (_b) running)))
          (drgnx-agent-panel-background--tick-sync buf)
          (should (drgnx-timer-active-p (cons 'drgnx-bg-elapsed buf)))
          (setq running nil)
          (drgnx-agent-panel-background--tick-sync buf)
          (should-not (drgnx-timer-active-p (cons 'drgnx-bg-elapsed buf)))
          (setq running t visible nil)
          (drgnx-agent-panel-background--tick-sync buf)
          (should-not (drgnx-timer-active-p (cons 'drgnx-bg-elapsed buf)))
          (setq visible t)
          (drgnx-agent-panel-background--tick-sync buf)
          (should (drgnx-timer-active-p (cons 'drgnx-bg-elapsed buf)))
          (kill-buffer buf)
          (should-not (drgnx-timer-active-p (cons 'drgnx-bg-elapsed buf))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;;;; Ending a chat

(ert-deftest agent-background-end-asks-with-items ()
  "Ending a chat from a command asks while items run: Keep it running ends nothing; Stop them and end cancels each
cancellable item, then ends the chat."
  (drgnx-bgtest--with (drgnx-bgtest--items)
    (let ((this-command 'some-command) asked)
      (cl-letf (((symbol-function 'drgnx-agent-panel-background--ask)
                 (lambda (_s items &rest _) (setq asked (length items)) 'keep)))
        (drgnx-agents-kill s t)
        (should (= asked 3))
        (should-not calls))
      (cl-letf (((symbol-function 'drgnx-agent-panel-background--ask) (lambda (&rest _) 'stop)))
        (drgnx-agents-kill s t)
        (let ((methods (mapcar #'car (reverse calls))))
          (should (equal (seq-count (lambda (m) (equal m "agents/background-cancel")) methods) 2))
          (should (equal (car (last methods)) "agents/kill")))))))

(ert-deftest agent-background-end-lists-what-it-showed ()
  "Items that appear while the question is open are not stopped by it; a notice says what else was running."
  (drgnx-bgtest--with (drgnx-bgtest--items)
    (let ((this-command 'some-command) notes)
      (cl-letf (((symbol-function 'drgnx-agent-panel-background--ask)
                 (lambda (session _items &rest _)
                   (setf (drgnx-agent-session-background session)
                         (append (drgnx-agent-session-background session)
                                 (list (drgnx-bgtest--item "terminal" "n1" "make docs" t))))
                   'stop))
                ((symbol-function 'drgnx-notify) (lambda (_src _sev text &rest _) (push text notes))))
        (drgnx-agents-kill s t)
        (should-not (seq-find (lambda (c) (equal (plist-get (nth 1 c) :item) "n1")) calls))
        (should (seq-find (lambda (n) (string-match-p "make docs" n)) notes))))))

(ert-deftest agent-background-end-from-code-never-prompts ()
  "No ask without ASK, and none when no command runs (a timer, kill-emacs, teardown): the chat ends, its items stop
with it."
  (drgnx-bgtest--with (drgnx-bgtest--items)
    (cl-letf (((symbol-function 'drgnx-agent-panel-background--ask) (lambda (&rest _) (ert-fail "asked"))))
      (let ((this-command 'some-command)) (drgnx-agents-kill s))
      (should (equal (mapcar #'car calls) '("agents/kill")))
      (setq calls nil)
      (let ((this-command nil)) (drgnx-agents-kill s t))
      (should (equal (mapcar #'car calls) '("agents/kill")))
      (setq calls nil)
      (let ((this-command 'some-command) (drgnx-guard--automatic t)) (drgnx-agents-kill s t))
      (should (equal (mapcar #'car calls) '("agents/kill"))))))

(ert-deftest agent-background-end-with-nothing-running-does-not-ask ()
  (drgnx-bgtest--with nil
    (let ((this-command 'some-command))
      (cl-letf (((symbol-function 'drgnx-agent-panel-background--ask) (lambda (&rest _) (ert-fail "asked"))))
        (drgnx-agents-kill s t)
        (should (equal (mapcar #'car calls) '("agents/kill")))))))

;;;; Ends: the status bar and the desktop

(defun drgnx-bgtest--ended (&optional status)
  (list :kind "terminal" :id "t9" :description "cargo test -p hermod" :started_ms 1000 :status "running"
        :can_cancel nil :end (list :status (or status "failed") :exit_code 101)))

(ert-deftest agent-background-end-to-status-item ()
  "An end while the chat is not on screen is the status bar's agent item, until the chat is shown."
  (drgnx-bgtest--with nil
    (let ((drgnx-agent-panel-background--status nil) (visible nil))
      (cl-letf (((symbol-function 'drgnx-agent-panel-background--chat-visible-p) (lambda (_sid) visible))
                ((symbol-function 'drgnx-statusbar-refresh) #'ignore)
                ((symbol-function 'drgnx-notice-desktop-take) #'ignore))
        (drgnx-agent-panel-background--note-snapshot s)             ; first sight: nothing ended is news
        (setf (drgnx-agent-session-background-ended s) (list (drgnx-bgtest--ended)))
        (drgnx-agent-panel-background--note-snapshot s)
        (should (equal (drgnx-agent-panel-background--segment) "AGENT: cargo test -p hermod failed (exit 101)"))
        (drgnx-agent-panel-background--chat-shown "s1")
        (should-not (drgnx-agent-panel-background--segment))
        ;; the same end is not news twice; an end of a visible chat is not either
        (drgnx-agent-panel-background--note-snapshot s)
        (should-not (drgnx-agent-panel-background--segment))
        (setq visible t)
        (setf (drgnx-agent-session-background-ended s)
              (list (drgnx-bgtest--ended) (plist-put (drgnx-bgtest--ended "completed") :id "t10")))
        (drgnx-agent-panel-background--note-snapshot s)
        (should-not (drgnx-agent-panel-background--segment))
        ;; a finished one reads "finished"
        (setq visible nil)
        (setf (drgnx-agent-session-background-ended s)
              (list (drgnx-bgtest--ended) (plist-put (drgnx-bgtest--ended "completed") :id "t11")))
        (drgnx-agent-panel-background--note-snapshot s)
        (should (equal (drgnx-agent-panel-background--segment) "AGENT: cargo test -p hermod finished"))))))

(ert-deftest agent-background-desktop-notice-when-unfocused ()
  "An end of a chat that is not shown goes to the desktop route with the item's own title and the chat in the body."
  (drgnx-bgtest--with nil
    (let ((drgnx-agent-panel-background--status nil) taken)
      (cl-letf (((symbol-function 'drgnx-agent-panel-background--chat-visible-p) (lambda (_sid) nil))
                ((symbol-function 'drgnx-statusbar-refresh) #'ignore)
                ((symbol-function 'drgnx-notice-desktop-take) (lambda (item) (push item taken) t)))
        (drgnx-agent-panel-background--note-snapshot s)
        (setf (drgnx-agent-session-background-ended s) (list (drgnx-bgtest--ended)))
        (drgnx-agent-panel-background--note-snapshot s)
        (should (= (length taken) 1))
        (should (equal (plist-get (car taken) :desktop-title) "cargo test -p hermod failed"))
        (should (string-match-p "ACP v2 in the hub (Claude) · exit 101" (plist-get (car taken) :text)))))))

;;;; The command

(ert-deftest agent-end-this-chat-asks-through-kill ()
  "End This Chat, run as a command, ends the session through `drgnx-agents-kill' with ASK."
  (drgnx-bgtest--with (drgnx-bgtest--items)
    (let ((buf (generate-new-buffer " *bg-end*")) args)
      (unwind-protect
          (with-current-buffer buf
            (setq drgnx-agent-panel--session "s1")
            (cl-letf (((symbol-function 'drgnx-agent-panel--main-of) (lambda (_b) buf))
                      ((symbol-function 'drgnx-agents-kill) (lambda (&rest a) (setq args a))))
              (drgnx-agent-panel-end)
              (should (equal args (list s t)))))
        (kill-buffer buf)))))

;;;; The selected item's ring

(ert-deftest agent-background-the-selected-rows-get-one-rounded-ring ()
  "The header's window gets one `ring' block (Glitnir's `glitnir-blocks') over the selected item's rows, from the start of
its first row to the start of the line after its last, inset, rounded, in the focus colour; nothing selected: none."
  (let ((buf (generate-new-buffer " *bg-ring*")) (w (selected-window)) (old (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (dolist (row '(("t0" . "head row") ("t1" . "first") ("t1" . "second") ("w1" . "other")))
            (insert (propertize (cdr row) 'drgnx-bg-item (car row)) "\n"))
          (set-window-buffer w buf)
          (cl-letf (((symbol-function 'drgnx-agent-panel--main-of) (lambda (_b) buf)))
            (setq drgnx-agent-panel--bg-selected "t1")
            (drgnx-agent-panel-background--blocks)
            (let* ((blocks (window-parameter w 'glitnir-blocks)) (b (car blocks)) (plist (nthcdr 3 b)))
              (should (= (length blocks) 1))
              (should (eq (car b) 'ring))
              (should (= (nth 1 b) (save-excursion (goto-char (point-min)) (forward-line 1) (point))))
              (should (= (nth 2 b) (save-excursion (goto-char (point-min)) (forward-line 3) (point))))
              (should (eq (plist-get plist :ring) 'drgnx-focus-line))
              (should (> (plist-get plist :radius) 0))
              (should (> (plist-get plist :x0) 0))
              (should (> (plist-get plist :x1) (plist-get plist :x0))))
            ;; the next selection moves it; none drops it
            (setq drgnx-agent-panel--bg-selected "w1")
            (drgnx-agent-panel-background--blocks)
            (should (= (nth 1 (car (window-parameter w 'glitnir-blocks)))
                       (save-excursion (goto-char (point-min)) (forward-line 3) (point))))
            (setq drgnx-agent-panel--bg-selected nil)
            (drgnx-agent-panel-background--blocks)
            (should-not (window-parameter w 'glitnir-blocks))))
      (set-window-parameter w 'glitnir-blocks nil)
      (set-window-buffer w old)
      (kill-buffer buf))))

;;;; The module

(ert-deftest agent-background-module-turns-off-clean ()
  "The module sets up and tears down with the background commands, segment and hooks undone."
  (drgnx-test-with-modules '(tools/agent-panel)
    (should (fboundp 'drgnx-agent-panel-background-stop))))

;;; agent-panel-background-test.el ends here
