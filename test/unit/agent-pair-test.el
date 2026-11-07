;;; agent-pair-test.el --- batch tests: pair mode's queue, its safe slot, the open set and the save -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: orders
;; The safe slot's gate runs in every order the command loop, the hub's writes and the timer can arrive in
;; (`drgnx-test-every-order', pattern A).  The rest is pattern D: a write is queued as the hub's `pair-apply' event
;; would queue it, in a real buffer visiting a temp file; what the module asks the hub is recorded instead of sent (a
;; stand-in connection), and the apply is replaced where a test needs it to answer a given way.  The shift runs on
;; real buffers with the edit history's drain standing in (`drgnx-agent-pair-test--shifting': its counter is the
;; test's, and each change the test types is handed to the log as the drain would).  Expiry runs on the test clock.
(require 'ert)
(require 'ert-x)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-agent-pair" drgnx-dir) t t)
(defvar nidhogg-history-origin)

(defmacro drgnx-agent-pair-test--with (&rest body)
  "BODY with pair's state fresh, `dir' a temp directory, a stand-in subscribed connection that proved itself (a pipe,
also the events' connection) and what the module asks the hub on it pushed on `sent' ((METHOD PARAMS) ..., newest
first) instead of sent."
  (declare (indent 0))
  `(let* ((conn (make-pipe-process :name "pair-test" :noquery t :buffer nil))
          (drgnx-hub--events conn) (drgnx-hub--event-conn conn)
          (drgnx-agent-pair--pending nil) (drgnx-agent-pair--commands 0) (drgnx-agent-pair--lock nil)
          (drgnx-agent-pair--answers (make-hash-table)) (drgnx-agent-pair--order nil) (drgnx-agent-pair--unacked nil)
          (sent nil) (dir (file-name-as-directory (make-temp-file "pair" t))))
     (ignore sent)
     (process-put conn :drgnx-proven t)
     (cl-letf (((symbol-function 'drgnx-hub--call-on)
                (lambda (_conn method params _callback &rest _keys) (push (list method params) sent) 1)))
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b)))
             (with-current-buffer b (set-buffer-modified-p nil))
             (kill-buffer b)))
         (delete-process conn)
         (delete-directory dir t)))))

(defun drgnx-agent-pair-test--visit (dir name text)
  "A buffer visiting NAME in DIR, a file holding TEXT."
  (let ((f (expand-file-name name dir)))
    (with-temp-file f (insert text))
    (find-file-noselect f)))

(defun drgnx-agent-pair-test--write (id session buffer &optional ttl)
  "The hub's `pair-apply' data for write ID of SESSION to BUFFER's file (TTL ms, default 2000)."
  (list :write id :session session :ordinal id :file (buffer-file-name buffer)
        :edits (list (list :kind "replace" :old "a" :new "b")) :ttl_ms (or ttl 2000)))

(defun drgnx-agent-pair-test--queue (buffer)
  (mapcar (lambda (w) (plist-get w :write)) (buffer-local-value 'drgnx-agent-pair--queue buffer)))

;;;; The safe slot, in every order (pattern A)

(defun drgnx-agent-pair-test--busy-p (st)
  "The oracle: a command runs (its own count of pre and post), or the minibuffer, a recursive edit, a keyboard macro
or isearch is active."
  (or (> (plist-get st :stack) 0) (> (plist-get st :rec) 0) (> (plist-get st :mini) 0)
      (plist-get st :macro) (plist-get st :isearch)))

(defun drgnx-agent-pair-test--step (st ev)
  "The command loop as the hooks see it, the hub's writes and the timer, one event EV on ST: (ST . RAISED)."
  (let* ((st (copy-sequence st))
         (depth (+ (plist-get st :rec) (plist-get st :mini)))
         (raised nil))
    (pcase (car ev)
      ('pre (setq st (plist-put st :n (drgnx-agent-pair-command-step (plist-get st :n) 'pre depth (plist-get st :macro))))
            (setq st (plist-put st :stack (1+ (plist-get st :stack)))))
      ('post (setq st (plist-put st :n (drgnx-agent-pair-command-step (plist-get st :n) 'post depth (plist-get st :macro))))
             (setq st (plist-put st :stack (1- (plist-get st :stack))))
             (setq raised (list '(slot))))
      ('mini-enter (setq st (plist-put st :mini (1+ (plist-get st :mini)))))
      ('mini-exit (setq st (plist-put st :mini (1- (plist-get st :mini)))))
      ('rec-enter (setq st (plist-put st :rec (1+ (plist-get st :rec)))))
      ('rec-exit (setq st (plist-put st :rec (1- (plist-get st :rec)))))
      ('macro-start (setq st (plist-put st :macro t)))
      ('macro-end (setq st (plist-put st :macro nil)))
      ('isearch-start (setq st (plist-put st :isearch t)))
      ('isearch-end (setq st (plist-put st :isearch nil)))
      ('arrive (setq st (plist-put st :queue (append (plist-get st :queue) (list (nth 1 ev))))))
      ('tick (setq raised (list '(slot))))
      ('slot
       (when (drgnx-agent-pair-slot-open-p
              (list :commands (plist-get st :n) :recursion depth :minibuffer (plist-get st :mini)
                    :macro (plist-get st :macro) :isearch (plist-get st :isearch) :resyncing nil :locked nil))
         (when (and (plist-get st :queue) (drgnx-agent-pair-test--busy-p st))
           (setq st (plist-put st :bad (cons (format "applied while busy: %S" st) (plist-get st :bad)))))
         (setq st (plist-put st :applied (append (plist-get st :applied) (plist-get st :queue))))
         (setq st (plist-put st :queue nil)))))
    (cons st raised)))

(ert-deftest drgnx-agent-pair/a-write-during-a-command-waits-for-the-safe-slot ()
  "Pattern A (Review Focus 1).  Writes arrive inside `completing-read' (a command in the minibuffer), a recursive edit
\(`sit-for' and timers run inside a command too), a keyboard macro and isearch, in every order with the command
phases and the timer's ticks: none is applied while any of those runs, and once everything ended both are applied,
in the order they arrived."
  (drgnx-test-every-order
   :kinds '(pre post mini-enter mini-exit rec-enter rec-exit macro-start macro-end isearch-start isearch-end
                arrive tick slot)
   :sources (list (cons 'user '((pre) (mini-enter) (pre) (post) (mini-exit) (post)
                                (pre) (rec-enter) (pre) (post) (rec-exit) (post)
                                (pre) (macro-start) (pre) (post) (macro-end) (post)
                                (pre) (isearch-start) (post) (pre) (isearch-end) (post)))
                  (cons 'hub '((arrive 1) (arrive 2)))
                  (cons 'timer '((tick) (tick))))
   ;; the last tick comes once the user and the hub are done
   :edges '(((user . 23) . (timer . 1)) ((hub . 1) . (timer . 1)))
   :init (lambda () (list :n 0 :stack 0 :rec 0 :mini 0 :macro nil :isearch nil :queue nil :applied nil :bad nil))
   :step #'drgnx-agent-pair-test--step
   :check (lambda (st _order)
            (cond ((plist-get st :bad) (car (plist-get st :bad)))
                  ((plist-get st :queue) (format "still queued at the end: %S" (plist-get st :queue)))
                  ((not (equal (plist-get st :applied) '(1 2))) (format "applied %S" (plist-get st :applied)))))))

;;;; The queue (pattern D)

(ert-deftest drgnx-agent-pair/an-expired-write-is-dropped ()
  "A write that waited past its `ttl_ms' (counted from its arrival, on this Emacs's clock) is dropped when the slot
opens, never applied; one still in time is taken by the apply."
  (drgnx-agent-pair-test--with
    (drgnx-test-with-clock ()
      (let ((buf (drgnx-agent-pair-test--visit dir "a.txt" "a\n")))
        (setq drgnx-agent-pair--commands 1)       ; a command runs: the slot stays shut
        (drgnx-agent-pair--arrived (drgnx-agent-pair-test--write 7 "s1" buf))
        (drgnx-agent-pair--drain)
        (should (equal (drgnx-agent-pair-test--queue buf) '(7)))
        (should-not (drgnx-agent-pair-answer-of 7))
        (drgnx-test-advance 2.5)
        (drgnx-agent-pair--arrived (drgnx-agent-pair-test--write 8 "s1" buf))
        (setq drgnx-agent-pair--commands 0)
        (drgnx-agent-pair--drain)
        (should (equal (plist-get (drgnx-agent-pair-answer-of 7) :result) "dropped"))
        (should (equal (plist-get (drgnx-agent-pair-answer-of 7) :reason) "expired"))
        (should (equal (plist-get (drgnx-agent-pair-answer-of 8) :result) "applied"))
        (should-not (drgnx-agent-pair-test--queue buf))
        (should (equal (with-current-buffer buf (buffer-string)) "b\n"))))))

(ert-deftest drgnx-agent-pair/a-started-apply-is-never-dropped ()
  "Once the slot took a write its apply runs to its end: a `pair-drop' and the deadline passing during it drop only
the writes still queued."
  (drgnx-agent-pair-test--with
    (drgnx-test-with-clock ()
      (let ((buf (drgnx-agent-pair-test--visit dir "a.txt" "a\n")))
        (setq drgnx-agent-pair--commands 1)
        (drgnx-agent-pair--arrived (drgnx-agent-pair-test--write 1 "s1" buf))
        (drgnx-agent-pair--arrived (drgnx-agent-pair-test--write 2 "s1" buf))
        (setq drgnx-agent-pair--commands 0)
        (cl-letf (((symbol-function 'drgnx-agent-pair--apply)
                   (lambda (_write)
                     (drgnx-agent-pair-drop "s1" "pair-off")
                     (drgnx-test-advance 5)
                     (list :result "applied" :version 3))))
          (drgnx-agent-pair--drain))
        (should (equal (plist-get (drgnx-agent-pair-answer-of 1) :result) "applied"))
        (should (equal (plist-get (drgnx-agent-pair-answer-of 2) :result) "dropped"))
        (should (equal (plist-get (drgnx-agent-pair-answer-of 2) :reason) "pair-off"))
        (should-not (drgnx-agent-pair-test--queue buf))))))

(ert-deftest drgnx-agent-pair/reconcile-answers-from-the-applied-record ()
  "`pair-reconcile' is answered from what this Emacs did: an applied write's answer again, a write it never had as
dropped (not applied), and nothing for a write still queued (its answer comes when the slot takes it)."
  (drgnx-agent-pair-test--with
    (let ((buf (drgnx-agent-pair-test--visit dir "a.txt" "a\n")))
      (drgnx-agent-pair--arrived (drgnx-agent-pair-test--write 3 "s1" buf))
      (cl-letf (((symbol-function 'drgnx-agent-pair--apply) (lambda (_w) (list :result "applied" :version 4))))
        (drgnx-agent-pair--drain))
      (setq drgnx-agent-pair--commands 1)
      (drgnx-agent-pair--arrived (drgnx-agent-pair-test--write 5 "s1" buf))
      (setq sent nil)
      (drgnx-agent-pair--reconcile (list :write 3 :file (buffer-file-name buf)))
      (drgnx-agent-pair--reconcile (list :write 99 :file (buffer-file-name buf)))
      (drgnx-agent-pair--reconcile (list :write 5 :file (buffer-file-name buf)))
      (let ((answers (mapcar #'cadr (cl-remove-if-not (lambda (s) (equal (car s) "pair/answer")) sent))))
        (should (= (length answers) 2))
        (should (equal (plist-get (cl-find 3 answers :key (lambda (a) (plist-get a :write))) :result) "applied"))
        (should (equal (plist-get (cl-find 3 answers :key (lambda (a) (plist-get a :write))) :version) 4))
        (should (equal (plist-get (cl-find 99 answers :key (lambda (a) (plist-get a :write))) :result) "dropped"))
        (should-not (cl-find 5 answers :key (lambda (a) (plist-get a :write))))))))

(ert-deftest drgnx-agent-pair/pair-drop-empties-the-sessions-queue ()
  "`pair-drop' answers each queued write of its session `dropped' with the reason; another session's stay queued."
  (drgnx-agent-pair-test--with
    (let ((buf (drgnx-agent-pair-test--visit dir "a.txt" "a\n")))
      (setq drgnx-agent-pair--commands 1)
      (drgnx-agent-pair--arrived (drgnx-agent-pair-test--write 1 "s1" buf))
      (drgnx-agent-pair--arrived (drgnx-agent-pair-test--write 2 "s2" buf))
      (drgnx-agent-pair--arrived (drgnx-agent-pair-test--write 3 "s1" buf))
      (drgnx-agent-pair--event "pair-drop" (list :session "s1" :reason "held"))
      (should (equal (drgnx-agent-pair-test--queue buf) '(2)))
      (dolist (id '(1 3))
        (should (equal (plist-get (drgnx-agent-pair-answer-of id) :result) "dropped"))
        (should (equal (plist-get (drgnx-agent-pair-answer-of id) :reason) "held")))
      (should-not (drgnx-agent-pair-answer-of 2)))))

(ert-deftest drgnx-agent-pair/the-lock-blocks-a-reentrant-drain ()
  "A drain entered again from inside an apply (a filter or a save hook that drains) does nothing; the write that
arrived meanwhile is applied after the first, by the outer drain."
  (drgnx-agent-pair-test--with
    (let ((buf (drgnx-agent-pair-test--visit dir "a.txt" "a\n")) (depth 0) (deepest 0) (order nil))
      (drgnx-agent-pair--arrived (drgnx-agent-pair-test--write 1 "s1" buf))
      (cl-letf (((symbol-function 'drgnx-agent-pair--apply)
                 (lambda (write)
                   (cl-incf depth)
                   (setq deepest (max deepest depth))
                   (push (plist-get write :write) order)
                   (when (= (plist-get write :write) 1)
                     (drgnx-agent-pair--arrived (drgnx-agent-pair-test--write 2 "s1" buf))
                     (drgnx-agent-pair--drain)
                     (should (equal (drgnx-agent-pair-test--queue buf) '(2))))
                   (cl-decf depth)
                   (list :result "applied" :version 1))))
        (drgnx-agent-pair--drain))
      (should (= deepest 1))
      (should (equal (reverse order) '(1 2)))
      (should-not (drgnx-agent-pair-test--queue buf)))))

;;;; The open set

(ert-deftest drgnx-agent-pair/a-rename-moves-the-open-entry ()
  "With the module on, visiting a file sends `pair/open', renaming the buffer's file (`set-visited-file-name', as
`write-file' does) sends `pair/closed' for the old name and `pair/open' for the new, and killing it `pair/closed'."
  (drgnx-agent-pair-test--with
    (drgnx-test-with-modules '(tools/agent-pair)
      (let* ((buf (drgnx-agent-pair-test--visit dir "a.txt" "a\n"))
             (old (buffer-file-name buf)) (new (expand-file-name "b.txt" dir)))
        (should (member (list "pair/open" (list :file old :kind "normal")) sent))
        (setq sent nil)
        (with-current-buffer buf (set-visited-file-name new t))
        (should (equal (reverse sent) (list (list "pair/closed" (list :file old))
                                            (list "pair/open" (list :file new :kind "normal")))))
        (setq sent nil)
        (kill-buffer buf)
        (should (equal sent (list (list "pair/closed" (list :file new)))))))))

;;;; The save after an apply

(defun drgnx-agent-pair-test--apply-one (buf text)
  "Queue one write to BUF and run the slot, the apply putting TEXT at the end: the write's answer."
  (drgnx-agent-pair--arrived (drgnx-agent-pair-test--write 1 "s1" buf))
  (cl-letf (((symbol-function 'drgnx-agent-pair--apply)
             (lambda (_write)
               (save-excursion (goto-char (point-max)) (insert text))
               (list :result "applied" :version (buffer-chars-modified-tick)))))
    (drgnx-agent-pair--drain))
  (drgnx-agent-pair-answer-of 1))

(defun drgnx-agent-pair-test--disk (buf)
  (with-temp-buffer (insert-file-contents (buffer-file-name buf)) (buffer-string)))

(ert-deftest drgnx-agent-pair/a-clean-buffer-is-saved ()
  "A write to a buffer with no unsaved edits is saved in the same slot: the file on disk is the agent's text."
  (drgnx-agent-pair-test--with
    (let ((buf (drgnx-agent-pair-test--visit dir "a.txt" "a\n")))
      (should-not (buffer-modified-p buf))
      (let ((answer (drgnx-agent-pair-test--apply-one buf "agent\n")))
        (should (equal (plist-get answer :result) "applied"))
        (should (eq (plist-get answer :saved) t))
        (should-not (plist-get answer :not_saved)))
      (should-not (buffer-modified-p buf))
      (should (equal (drgnx-agent-pair-test--disk buf) "a\nagent\n")))))

(ert-deftest drgnx-agent-pair/a-dirty-buffer-is-not ()
  "A write to a buffer with your unsaved edits leaves it unsaved: the disk has neither, and the answer says so."
  (drgnx-agent-pair-test--with
    (let ((buf (drgnx-agent-pair-test--visit dir "a.txt" "a\n")))
      (with-current-buffer buf (goto-char (point-min)) (insert "yours\n"))
      (let ((answer (drgnx-agent-pair-test--apply-one buf "agent\n")))
        (should (equal (plist-get answer :result) "applied"))
        (should (eq (plist-get answer :saved) :false)))
      (should (buffer-modified-p buf))
      (should (equal (drgnx-agent-pair-test--disk buf) "a\n")))))

(ert-deftest drgnx-agent-pair/old-versions-question-keeps-them ()
  "With numbered backups past the kept counts and `delete-old-versions' nil, the save would ask whether to delete
them: the guard keeps them instead, without asking, and the save goes through."
  (drgnx-agent-pair-test--with
    (let ((buf (drgnx-agent-pair-test--visit dir "v.txt" "a\n")))
      (dolist (n '(1 2 3))
        (with-temp-file (expand-file-name (format "v.txt.~%d~" n) dir) (insert "old\n")))
      (with-current-buffer buf
        (setq-local make-backup-files t) (setq-local version-control t) (setq-local backup-inhibited nil))
      (let* ((delete-old-versions nil) (kept-old-versions 1) (kept-new-versions 1) (backup-directory-alist nil)
             (backup-enable-predicate #'always)
             (answer (drgnx-agent-pair-test--apply-one buf "agent\n")))
        (should (eq (plist-get answer :saved) t)))
      (should-not (buffer-modified-p buf))
      (dolist (n '(1 2 3 4))
        (should (file-exists-p (expand-file-name (format "v.txt.~%d~" n) dir)))))))

(ert-deftest drgnx-agent-pair/final-newline-ask-becomes-t ()
  "`require-final-newline' `ask' would ask at the save: the guard adds the newline instead."
  (drgnx-agent-pair-test--with
    (let ((buf (drgnx-agent-pair-test--visit dir "n.txt" "a")))
      (with-current-buffer buf (setq-local require-final-newline 'ask))
      (should (eq (plist-get (drgnx-agent-pair-test--apply-one buf "b") :saved) t))
      (should (equal (drgnx-agent-pair-test--disk buf) "ab\n")))))

(ert-deftest drgnx-agent-pair/coding-system-question-becomes-not-saved ()
  "Text the file's coding system cannot encode would make the save ask for another: not saved, with the reason, and
the buffer keeps the text."
  (drgnx-agent-pair-test--with
    (let ((buf (drgnx-agent-pair-test--visit dir "c.txt" "a\n")))
      (with-current-buffer buf (setq buffer-file-coding-system 'iso-latin-1-unix))
      ;; no default coding system is acceptable, so Emacs asks for one (else it would pick UTF-8 by itself)
      (let* ((select-safe-coding-system-accept-default-p #'ignore)
             (answer (drgnx-agent-pair-test--apply-one buf "日本\n")))
        (should (equal (plist-get answer :result) "applied"))
        (should (eq (plist-get answer :saved) :false))
        (should (stringp (plist-get answer :not_saved))))
      (should (buffer-modified-p buf))
      (should (equal (drgnx-agent-pair-test--disk buf) "a\n")))))

(ert-deftest drgnx-agent-pair/a-formatter-that-asks-becomes-not-saved ()
  "`before-save-hook' runs; a formatter there that asks a question leaves the buffer unsaved, with the reason."
  (drgnx-agent-pair-test--with
    (let ((buf (drgnx-agent-pair-test--visit dir "f.txt" "a\n")) (ran nil))
      (with-current-buffer buf
        (add-hook 'before-save-hook (lambda () (setq ran t) (y-or-n-p "Reformat? ")) nil t))
      (let ((answer (drgnx-agent-pair-test--apply-one buf "agent\n")))
        (should ran)
        (should (eq (plist-get answer :saved) :false))
        (should (string-match-p "would have asked" (plist-get answer :not_saved))))
      (should (buffer-modified-p buf))
      (should (equal (drgnx-agent-pair-test--disk buf) "a\n")))))

(ert-deftest drgnx-agent-pair/a-read-char-in-a-save-hook-becomes-not-saved ()
  "A save hook that reads a character never waits for one: not saved, with the reason."
  (drgnx-agent-pair-test--with
    (let ((buf (drgnx-agent-pair-test--visit dir "r.txt" "a\n")))
      (with-current-buffer buf (add-hook 'before-save-hook (lambda () (read-char "Key: ")) nil t))
      (let ((answer (drgnx-agent-pair-test--apply-one buf "agent\n")))
        (should (eq (plist-get answer :saved) :false))
        (should (stringp (plist-get answer :not_saved))))
      (should (buffer-modified-p buf)))))

;;;; The toggle

(ert-deftest drgnx-agent-pair/toggle-explains-why-it-is-off ()
  "The Pair toggle of a chat: turning it off always works; turning it on says why it cannot (the matrix's cell, the
history primitives, an agent whose proof is not green yet, a chat outside a project), and a chat that waits on your
lines says which."
  (let ((off (list :id "s1" :name "Claude" :provider "claude" :paired nil))
        (on (list :id "s1" :name "Claude" :provider "claude" :paired t)))
    (let ((s (drgnx-agent-pair-toggle-state off "never" t)))
      (should-not (plist-get s :can))
      (should (string-match-p "chat.project-edit is never" (plist-get s :why))))
    (let ((s (drgnx-agent-pair-toggle-state off "ask" nil)))
      (should-not (plist-get s :can))
      (should (equal (plist-get s :why) "Pair needs Nidhogg .6 with Glitnir")))
    (let ((s (drgnx-agent-pair-toggle-state (plist-put (copy-sequence off) :provider "codex") "ask" t)))
      (should-not (plist-get s :can))
      (should (string-prefix-p "Pair is not available for this agent yet: " (plist-get s :why))))
    (let ((s (drgnx-agent-pair-toggle-state (list :id "s2" :name "Gemini" :provider "gemini") "allow" t)))
      (should-not (plist-get s :can))
      (should (string-match-p "only for a chat in your project" (plist-get s :why))))
    (let ((s (drgnx-agent-pair-toggle-state off "ask" t)))
      (should (plist-get s :can))
      (should-not (plist-get s :on))
      (should-not (plist-get s :why)))
    (let ((s (drgnx-agent-pair-toggle-state on "never" nil)))
      (should (plist-get s :can))
      (should (plist-get s :on)))
    (let ((s (drgnx-agent-pair-toggle-state
              (append on (list :waiting (list :file "/p/src/main.rs" :lines '(120 124)))) "allow" t)))
      (should (equal (plist-get s :waiting) "Claude is waiting for lines 120–124 of main.rs")))))

;;;; The shift and the guard zone

(defvar-local drgnx-agent-pair-test--ctr 0
  "The stand-in drain counter of a test buffer: one more for every change the test logs.")

(defmacro drgnx-agent-pair-test--shifting (&rest body)
  "BODY with a paired chat \"s1\" in `dir' (inside `drgnx-agent-pair-test--with'), the edit history's drain standing
in: `drgnx-history-drain-now' answers the buffer's `drgnx-agent-pair-test--ctr'."
  (declare (indent 0))
  `(let ((drgnx-agent-pair--paired (make-hash-table :test 'equal)))
     (puthash "s1" (file-name-as-directory dir) drgnx-agent-pair--paired)
     (cl-letf (((symbol-function 'drgnx-history-drain-now)
                (lambda (&optional b) (buffer-local-value 'drgnx-agent-pair-test--ctr (or b (current-buffer))))))
       ,@body)))

(defun drgnx-agent-pair-test--buffer (dir text)
  "A buffer holding TEXT whose file name is in DIR (never saved), its counter 1."
  (let ((b (generate-new-buffer "pair-shift")))
    (with-current-buffer b
      (insert text)
      (setq buffer-file-name (expand-file-name (format "f%d.txt" (random 1000000)) dir))
      (setq drgnx-agent-pair-test--ctr 1))
    b))

(defun drgnx-agent-pair-test--change (buf start old-len text)
  "In BUF, replace OLD-LEN characters at 0-based START with TEXT, as you would type it; the drain logs the change."
  (with-current-buffer buf
    (save-excursion
      (goto-char (1+ start))
      (delete-region (point) (+ (point) old-len))
      (insert text))
    (drgnx-agent-pair--drained buf (cl-incf drgnx-agent-pair-test--ctr)
                               (list (list :start start :old_len old-len :inserted text)))))

(defun drgnx-agent-pair-test--at (buf line-text)
  "The 0-based offset of the start of BUF's line LINE-TEXT."
  (with-current-buffer buf (string-search (concat "\n" line-text "\n") (concat "\n" (buffer-string)))))

(defun drgnx-agent-pair-test--line (text line-text)
  "The 1-based number of the line LINE-TEXT in TEXT."
  (1+ (cl-count ?\n (substring text 0 (string-search (concat "\n" line-text "\n") (concat "\n" text))))))

(defconst drgnx-agent-pair-test--ten "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n")

(defun drgnx-agent-pair-test--rebase-step (st ev)
  "One event EV on ST (:buf :version :read :answer): the agent reads or writes line \"five\", you type above it or
delete a line below it."
  (let ((buf (plist-get st :buf)))
    (pcase (car ev)
      ('read (with-current-buffer buf
               (setq st (plist-put st :version (drgnx-agent-pair-version)))
               (setq st (plist-put st :read (buffer-string)))))
      ('write
       (let ((edit (list :kind "lines" :line (drgnx-agent-pair-test--line (plist-get st :read) (nth 1 ev))
                         :delete 1 :text (nth 2 ev))))
         (with-current-buffer buf
           (setq st (plist-put st :answer (drgnx-agent-pair--apply
                                           (list :edits (list edit) :version (plist-get st :version))))))))
      ('type (drgnx-agent-pair-test--change buf (drgnx-agent-pair-test--at buf (nth 1 ev)) 0 (nth 2 ev)))
      ('delete (drgnx-agent-pair-test--change buf (drgnx-agent-pair-test--at buf (nth 1 ev))
                                              (1+ (length (nth 1 ev))) "")))
    (cons st nil)))

(ert-deftest drgnx-agent-pair/every-order-a-clean-rebase-applies-at-the-shifted-place ()
  "Pattern A.  You type a line above the agent's line and delete one below it, before or after its read, in every
order with its read and its write: the write lands on its own line, shifted past your changes, and the text is the
same in every order."
  (drgnx-agent-pair-test--with
    (drgnx-agent-pair-test--shifting
      (drgnx-test-every-order
       :kinds '(read write type delete)
       :sources (list (cons 'agent '((read) (write "five" "FIVE\n")))
                      (cons 'user '((type "two" "typed\n") (delete "nine") (type "ten" "more\n"))))
       :init (lambda () (list :buf (drgnx-agent-pair-test--buffer dir drgnx-agent-pair-test--ten)))
       :step #'drgnx-agent-pair-test--rebase-step
       :check (lambda (st _order)
                (let ((text (with-current-buffer (plist-get st :buf) (buffer-string))))
                  (kill-buffer (plist-get st :buf))
                  (cond ((not (equal (plist-get (plist-get st :answer) :result) "applied"))
                         (format "not applied: %S" (plist-get st :answer)))
                        ((not (equal text "one\ntyped\ntwo\nthree\nfour\nFIVE\nsix\nseven\neight\nmore\nten\n"))
                         (format "text %S" text)))))))))

(ert-deftest drgnx-agent-pair/an-edit-over-the-users-changes-is-refused-whole ()
  "Pattern A (Review Focus 2).  After the agent's read you type on lines 5 and 6, in every order with your typing above
them; its write of lines 2 and 5–6 is refused whole, naming the lines you are editing, and nothing of it is applied."
  (drgnx-agent-pair-test--with
    (drgnx-agent-pair-test--shifting
      (drgnx-test-every-order
       :kinds '(read write type)
       :sources (list (cons 'agent '((read) (write)))
                      (cons 'user '((type "five" "x") (type "six" "y") (type "one" "z"))))
       :edges '(((agent . 0) . (user . 0)) ((user . 1) . (agent . 1)))
       :init (lambda () (list :buf (drgnx-agent-pair-test--buffer dir drgnx-agent-pair-test--ten)))
       :step (lambda (st ev)
               (if (eq (car ev) 'write)
                   (with-current-buffer (plist-get st :buf)
                     (cons (plist-put st :answer
                                      (drgnx-agent-pair--apply
                                       (list :version (plist-get st :version)
                                             :edits (list (list :kind "lines" :line 2 :delete 1 :text "TWO\n")
                                                          (list :kind "lines" :line 5 :delete 2 :text "FIVE\nSIX\n")))))
                           nil))
                 (drgnx-agent-pair-test--rebase-step st ev)))
       :check (lambda (st _order)
                (let ((text (with-current-buffer (plist-get st :buf) (buffer-string)))
                      (answer (plist-get st :answer)))
                  (kill-buffer (plist-get st :buf))
                  (cond ((not (equal (plist-get answer :reason) "overlap")) (format "answer %S" answer))
                        ((string-search "TWO" text) (format "a part was applied: %S" text))
                        ((not (equal (plist-get answer :lines) [5 6])) (format "lines %S" (plist-get answer :lines))))))))))

(ert-deftest drgnx-agent-pair/a-version-older-than-the-log-is-refused ()
  "The log keeps its last drains (here 3, the hub's floor older than none): a write based on a version before them is
refused \"read it with read_file\" (`gap'), whole; one based on a version it still covers applies."
  (drgnx-agent-pair-test--with
    (drgnx-agent-pair-test--shifting
      (let* ((drgnx-agent-pair-log-size 3) (buf (drgnx-agent-pair-test--buffer dir drgnx-agent-pair-test--ten))
             (old (with-current-buffer buf (drgnx-agent-pair-version))))
        (dotimes (_ 4) (drgnx-agent-pair-test--change buf 0 0 "x"))
        (with-current-buffer buf
          (let ((edit (list :kind "lines" :line 9 :delete 1 :text "NINE\n")))
            (should (equal (drgnx-agent-pair--apply (list :version old :edits (list edit)))
                           (list :result "refused" :reason "gap")))
            (should-not (string-search "NINE" (buffer-string)))
            (let ((v (drgnx-agent-pair-version)))
              (drgnx-agent-pair-test--change buf 0 0 "y")
              (should (equal (plist-get (drgnx-agent-pair--apply (list :version v :edits (list edit))) :result)
                             "applied"))
              (should (string-search "\nNINE\n" (buffer-string))))))
        (kill-buffer buf)))))

(ert-deftest drgnx-agent-pair/a-whole-write-after-30-s-of-typing-elsewhere-applies-shifted ()
  "The agent read the file, you typed at its top for 30 s (300 drains, one every 0.1 s), and its whole-file write (two
hunks) arrives: both hunks land on their own lines, shifted past everything you typed."
  (drgnx-agent-pair-test--with
    (drgnx-agent-pair-test--shifting
      (let* ((buf (drgnx-agent-pair-test--buffer dir drgnx-agent-pair-test--ten))
             (v (with-current-buffer buf (drgnx-agent-pair-version))))
        (dotimes (i 300) (drgnx-agent-pair-test--change buf (if (zerop (% i 50)) 0 (1- (% i 50))) 0
                                                        (if (zerop (% i 50)) "\n" "k")))
        (with-current-buffer buf
          (let ((typed (buffer-substring (point-min) (+ (point-min) (string-search "one" (buffer-string))))))
            (should (equal (plist-get (drgnx-agent-pair--apply
                                       (list :version v
                                             :edits (list (list :kind "lines" :line 3 :delete 1 :text "THREE\n")
                                                          (list :kind "lines" :line 8 :delete 1 :text "EIGHT\n"))))
                                      :result)
                           "applied"))
            (should (equal (buffer-string)
                           (concat typed "one\ntwo\nTHREE\nfour\nfive\nsix\nseven\nEIGHT\nnine\nten\n")))))
        (kill-buffer buf)))))

(ert-deftest drgnx-agent-pair/a-version-before-a-resync-is-refused ()
  "A drain that returned `resync' (Nidhogg's ring lost changes, or the whole text went) is a gap: a write based on a
version before it is refused `gap', even with nothing typed since."
  (drgnx-agent-pair-test--with
    (drgnx-agent-pair-test--shifting
      (let* ((buf (drgnx-agent-pair-test--buffer dir drgnx-agent-pair-test--ten))
             (v (with-current-buffer buf (drgnx-agent-pair-version))))
        (with-current-buffer buf
          (drgnx-agent-pair--drained buf (cl-incf drgnx-agent-pair-test--ctr) 'resync)
          (should (equal (drgnx-agent-pair--apply
                          (list :version v :edits (list (list :kind "lines" :line 1 :delete 1 :text "ONE\n"))))
                         (list :result "refused" :reason "gap")))
          (should (equal (buffer-string) drgnx-agent-pair-test--ten)))
        (kill-buffer buf)))))

(ert-deftest drgnx-agent-pair/no-log-is-kept-without-a-paired-chat ()
  "A buffer keeps no change log while no paired chat works in its folder; a paired chat's snapshot starts it, and
the snapshot that ends the pairing drops it."
  (drgnx-agent-pair-test--with
    (drgnx-agent-pair-test--shifting
      (let ((buf (drgnx-agent-pair-test--buffer dir drgnx-agent-pair-test--ten)))
        (clrhash drgnx-agent-pair--paired)
        (drgnx-agent-pair-test--change buf 0 0 "a")
        (drgnx-agent-pair-test--change buf 0 0 "b")
        (with-current-buffer buf
          (should-not drgnx-agent-pair--log)
          (should-not drgnx-agent-pair--from))
        (drgnx-agent-pair--snapshot "s2" (list :paired t :ordinal 1 :cwd dir))
        (drgnx-agent-pair-test--change buf 0 0 "c")
        (drgnx-agent-pair-test--change buf 0 0 "d")
        (with-current-buffer buf
          (should drgnx-agent-pair--from)
          (should (= (length drgnx-agent-pair--log) 1)))
        (drgnx-agent-pair--snapshot "s2" (list :paired :false :ordinal 1 :cwd dir))
        (with-current-buffer buf
          (should-not drgnx-agent-pair--log)
          (should-not drgnx-agent-pair--from))
        (kill-buffer buf)))))

(ert-deftest drgnx-agent-pair/the-guard-zone-covers-every-window ()
  "The guard zone is the line at point ±1 in every window showing the buffer: a write on the line under another
window's point is refused `guard' with its lines, one away from both applies."
  (drgnx-agent-pair-test--with
    (drgnx-agent-pair-test--shifting
      (let ((buf (drgnx-agent-pair-test--buffer dir drgnx-agent-pair-test--ten)))
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer buf)
          (let ((w2 (split-window)))
            (set-window-buffer w2 buf)
            (set-window-point (selected-window) (with-current-buffer buf (goto-char (point-min)) (point)))
            (set-window-point w2 (with-current-buffer buf (save-excursion (goto-char (point-min)) (forward-line 7) (point))))
            (with-current-buffer buf
              (should (member '(7 . 9) (drgnx-agent-pair--guard)))
              (should (member '(1 . 2) (drgnx-agent-pair--guard)))
              (let ((v (drgnx-agent-pair-version)))
                (should (equal (drgnx-agent-pair--apply
                                (list :version v :edits (list (list :kind "lines" :line 9 :delete 1 :text "NINE\n"))))
                               (list :result "refused" :reason "guard" :lines [9 9])))
                (should (equal (plist-get (drgnx-agent-pair--apply
                                           (list :version v :edits (list (list :kind "lines" :line 5 :delete 1
                                                                               :text "FIVE\n"))))
                                          :result)
                               "applied"))))))
        (kill-buffer buf)))))

(ert-deftest drgnx-agent-pair/the-active-region-is-guarded ()
  "An active region is guarded whole, shown in a window or not; with the mark inactive the same write applies."
  (drgnx-agent-pair-test--with
    (drgnx-agent-pair-test--shifting
      (let ((buf (drgnx-agent-pair-test--buffer dir drgnx-agent-pair-test--ten))
            (edit (list :kind "lines" :line 4 :delete 1 :text "FOUR\n")))
        (with-current-buffer buf
          (goto-char (point-min)) (forward-line 1)
          (push-mark (point) t t)
          (forward-line 5)
          (let ((v (drgnx-agent-pair-version)))
            (should (equal (drgnx-agent-pair--apply (list :version v :edits (list edit)))
                           (list :result "refused" :reason "guard" :lines [4 4])))
            (deactivate-mark t)
            (should (equal (plist-get (drgnx-agent-pair--apply (list :version v :edits (list edit))) :result)
                           "applied"))))
        (kill-buffer buf)))))

;;;; The apply, undo and attribution

(defun drgnx-agent-pair-test--command (&rest cmd)
  "Run CMD as the command loop does: `undo-auto--add-boundary' first (keyboard.c), then the command with its hooks,
`last-command' set from `this-command' after `post-command-hook' (`ert-simulate-command')."
  (undo-auto--add-boundary)
  (ert-simulate-command cmd))

(defun drgnx-agent-pair-test--type (char)
  (let ((last-command-event char)) (drgnx-agent-pair-test--command 'self-insert-command 1 char)))

(defun drgnx-agent-pair-test--replace (id old new)
  "The hub's `pair-apply' data for write ID of \"s1\": OLD becomes NEW."
  (list :write id :session "s1" :step 1 :edits (list (list :kind "replace" :old old :new new))))

(defmacro drgnx-agent-pair-test--undoable (text &rest body)
  "BODY in `buf', a buffer visiting a file holding TEXT with undo on, point at its end, inside the stand-ins."
  (declare (indent 1))
  `(drgnx-agent-pair-test--with
     (drgnx-agent-pair-test--shifting
       (let ((buf (drgnx-agent-pair-test--visit dir "u.txt" ,text)))
         (with-current-buffer buf
           (buffer-enable-undo)
           (setq buffer-undo-list nil last-command nil)
           (goto-char (point-max))
           ,@body)))))

(ert-deftest drgnx-agent-pair/typing-after-an-apply-starts-its-own-undo-group ()
  "Review Focus 3.  type → apply (the timer's slot) → type → undo: only the last typing goes; the agent's text and the
first typing stay."
  (drgnx-agent-pair-test--undoable "one\n"
    (drgnx-agent-pair-test--type ?x)
    (should (equal (plist-get (drgnx-agent-pair--apply (drgnx-agent-pair-test--replace 1 "one" "ONE")) :result)
                   "applied"))
    (should (eq last-command drgnx-pair-apply))
    (drgnx-agent-pair-test--type ?y)
    (drgnx-agent-pair-test--command 'undo)
    (should (equal (buffer-string) "ONE\nx"))))

(ert-deftest drgnx-agent-pair/an-undo-continuation-ends-at-an-apply ()
  "undo → apply → undo: the second undo starts afresh and undoes the agent's group, not your older change."
  (drgnx-agent-pair-test--undoable "one\n"
    (drgnx-agent-pair-test--type ?a)
    (drgnx-agent-pair-test--command 'end-of-line)
    (drgnx-agent-pair-test--type ?b)
    (drgnx-agent-pair-test--command 'undo)
    (should (equal (buffer-string) "one\na"))
    (drgnx-agent-pair--apply (drgnx-agent-pair-test--replace 1 "one" "ONE"))
    (drgnx-agent-pair-test--command 'undo)
    (should (equal (buffer-string) "one\na"))))

(ert-deftest drgnx-agent-pair/an-apply-from-the-post-command-slot-keeps-its-own-group ()
  "Review Focus 3.  A write queued while you type is applied from `post-command-hook' after your keystroke; your next
keystroke and `undo' take only that keystroke away: `this-command' told the loop an apply ran."
  (drgnx-agent-pair-test--undoable "one\n"
    (add-hook 'post-command-hook #'drgnx-agent-pair--post-command nil t)
    (drgnx-agent-pair--arrived (append (drgnx-agent-pair-test--replace 1 "one" "ONE") (list :file buffer-file-name :ttl_ms 2000)))
    (drgnx-agent-pair-test--type ?x)
    (should (equal (plist-get (drgnx-agent-pair-answer-of 1) :result) "applied"))
    (should (eq last-command drgnx-pair-apply))
    (drgnx-agent-pair-test--type ?y)
    (drgnx-agent-pair-test--command 'undo)
    (should (equal (buffer-string) "ONE\nx"))
    (remove-hook 'post-command-hook #'drgnx-agent-pair--post-command t)))

(ert-deftest drgnx-agent-pair/an-agent-group-undoes-alone ()
  "A write of several hunks is one undo step: one undo takes every hunk away and nothing of yours."
  (drgnx-agent-pair-test--undoable "one\ntwo\nthree\n"
    (drgnx-agent-pair-test--type ?z)
    (drgnx-agent-pair--apply (list :write 1 :session "s1" :step 1
                                   :edits (list (list :kind "replace" :old "one" :new "ONE")
                                                (list :kind "replace" :old "three" :new "THREE"))))
    (should (equal (buffer-string) "ONE\ntwo\nTHREE\nz"))
    (drgnx-agent-pair-test--command 'undo)
    (should (equal (buffer-string) "one\ntwo\nthree\nz"))))

(ert-deftest drgnx-agent-pair/point-and-markers-stay-put ()
  "Point and a marker outside the edit stay on their text; inside a replaced line they stay where the text is kept."
  (drgnx-agent-pair-test--undoable "aaa\nbbb ccc\nddd\n"
    (goto-char (point-min)) (forward-line 2)
    (let ((m (copy-marker (save-excursion (goto-char (point-min)) (line-end-position)))))
      (drgnx-agent-pair--apply (drgnx-agent-pair-test--replace 1 "bbb ccc" "bbb\nmore\nccc"))
      (should (looking-at "ddd"))
      (should (= m (save-excursion (goto-char (point-min)) (line-end-position))))
      (set-marker m nil))))

(ert-deftest drgnx-agent-pair/a-changed-on-disk-clean-buffer-reverts-first ()
  "The file changed on disk under a buffer with none of your edits: it is read again first (as the outside world's
change, asking nothing), then the write applies to it.  Under your unsaved edits the write is refused."
  (drgnx-agent-pair-test--undoable "a\nb\n"
    (let ((origin nil))
      (with-temp-file buffer-file-name (insert "a\nb\nc\n"))
      (set-visited-file-modtime (time-subtract (current-time) 100))
      (add-hook 'before-change-functions (lambda (&rest _) (push (bound-and-true-p nidhogg-history-origin) origin)) nil t)
      (should (equal (plist-get (drgnx-agent-pair--apply (drgnx-agent-pair-test--replace 1 "c" "C")) :result)
                     "applied"))
      (should (equal (buffer-string) "a\nb\nC\n"))
      (should (member "external:disk" origin))
      (should (member "agent:s1#1" origin))
      (insert "mine")
      (with-temp-file buffer-file-name (insert "a\nb\nC\nd\n"))
      (set-visited-file-modtime (time-subtract (current-time) 100))
      (should (equal (drgnx-agent-pair--apply (drgnx-agent-pair-test--replace 2 "a" "A"))
                     (list :result "refused" :reason "changed-on-disk")))
      (should (string-prefix-p "a\n" (buffer-string))))))

(ert-deftest drgnx-agent-pair/a-locked-file-refuses ()
  "A file another Emacs has locked, and a read-only buffer, refuse the write whole."
  (drgnx-agent-pair-test--undoable "one\n"
    (cl-letf (((symbol-function 'file-locked-p) (lambda (_f) "someone")))
      (should (equal (drgnx-agent-pair--apply (drgnx-agent-pair-test--replace 1 "one" "ONE"))
                     (list :result "refused" :reason "locked"))))
    (setq buffer-read-only t)
    (should (equal (drgnx-agent-pair--apply (drgnx-agent-pair-test--replace 1 "one" "ONE"))
                   (list :result "refused" :reason "read-only")))
    (setq buffer-read-only nil)
    (should (equal (buffer-string) "one\n"))))

(ert-deftest drgnx-agent-pair/the-ring-is-drained-before-a-resync-can-strip-the-origin ()
  "The write's changes are made with the agent's origin bound, and the history's ring is drained before the apply
returns (the answer's version), so a later resync cannot send them as yours."
  (drgnx-agent-pair-test--undoable "one\n"
    (let ((seen nil) (origin nil))
      (add-hook 'before-change-functions (lambda (&rest _) (push (bound-and-true-p nidhogg-history-origin) origin)) nil t)
      (cl-letf (((symbol-function 'drgnx-history-drain-now)
                 (lambda (&optional _b) (push (buffer-string) seen) 7)))
        (should (equal (drgnx-agent-pair--apply (drgnx-agent-pair-test--replace 1 "one" "ONE"))
                       (list :result "applied" :version 7))))
      (should (equal (delete-dups origin) '("agent:s1#1")))
      (should (equal (car seen) "ONE\n")))))

(ert-deftest drgnx-agent-pair/the-origin-carries-the-agents-step ()
  "A write the hub sent with the agent's step is made with the origin \"agent:SESSION#STEP\", so the edit history
records it under that step."
  (drgnx-agent-pair-test--undoable "one\n"
    (let ((origin nil))
      (add-hook 'before-change-functions (lambda (&rest _) (push (bound-and-true-p nidhogg-history-origin) origin)) nil t)
      (drgnx-agent-pair--apply (plist-put (drgnx-agent-pair-test--replace 1 "one" "ONE") :step 5))
      (should (equal (delete-dups origin) '("agent:s1#5"))))))

;;; agent-pair-test.el ends here
