;;; agent-pair-test.el --- batch tests: pair mode's queue, its safe slot, the open set and the save -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: orders
;; The safe slot's gate runs in every order the command loop, the hub's writes and the timer can arrive in
;; (`drgnx-test-every-order', pattern A).  The rest is pattern D: a write is queued as the hub's `pair-apply' event
;; would queue it, in a real buffer visiting a temp file; what the module asks the hub is recorded instead of sent (a
;; stand-in connection), and the apply, which refuses every write until the edit history is here, is replaced
;; where a test needs a write to land.  Expiry runs on the test clock.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-agent-pair" drgnx-dir) t t)

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
        (should (equal (plist-get (drgnx-agent-pair-answer-of 8) :result) "refused"))
        (should (equal (plist-get (drgnx-agent-pair-answer-of 8) :reason) drgnx-agent-pair-needs-history))
        (should-not (drgnx-agent-pair-test--queue buf))
        (should (equal (with-current-buffer buf (buffer-string)) "a\n"))))))

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

;;; agent-pair-test.el ends here
