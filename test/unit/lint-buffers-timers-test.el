;;; lint-buffers-timers-test.el --- lints: internal buffers skip buffer hooks; no timers in follow paths -*- lexical-binding: t -*-
;; The jank guard (invariant I9) catches a timer that moves windows at run time; these lints keep the
;; two habits behind it in the code: an internal " *…*" buffer is made with `inhibit-buffer-hooks'
;; (no `buffer-list-update-hook', so the bus and every follower never hear of it), and the workbench
;; follows the editor on the bus's edges, never from a `run-with-timer' / `run-at-time'.
(require 'ert)
(require 'seq)
(require 'drgnx-paths)

(defun drgnx-lint-bt--forms (file)
  (with-temp-buffer
    (insert-file-contents file)
    (let (forms)
      (condition-case nil (while t (push (read (current-buffer)) forms)) (end-of-file nil))
      (nreverse forms))))

(defun drgnx-lint-bt--walk (form fn)
  "Call FN on FORM and every list inside it."
  (when (consp form)
    (funcall fn form)
    (let ((x form))
      (while (consp x) (drgnx-lint-bt--walk (car x) fn) (setq x (cdr x))))))

(defun drgnx-lint-bt--files (&rest dirs)
  (seq-mapcat (lambda (d) (directory-files-recursively (expand-file-name d drgnx-dir) "\\.el\\'")) dirs))

(defun drgnx-lint-bt--internal-buffers-with-hooks (file)
  "Calls in FILE that make a buffer named by a literal \" *…\" without `inhibit-buffer-hooks'."
  (let (out)
    (dolist (top (drgnx-lint-bt--forms file))
      (drgnx-lint-bt--walk top (lambda (form)
                                 (pcase form
                                   (`(,(and f (or 'get-buffer-create 'generate-new-buffer)) ,(and name (pred stringp)) . ,rest)
                                    (when (and (string-prefix-p " " name) (not (car rest)))
                                      (push (format "%s %S" f name) out)))))))
    (nreverse out)))

(defconst drgnx-lint-bt--hooked-buffers
  ;; Each one needs no buffer hook (no `kill-buffer-hook' of its own, nobody lists it): they can take
  ;; `inhibit-buffer-hooks' — left for the next change to those files.
  '(("core/drgnx-acp.el" . "generate-new-buffer \" *drgnx-acp-input*\"")           ; an agent's input framing
    ("core/drgnx-projects.el" . "generate-new-buffer \" *drgnx-plan*\"")            ; a plan's text while synced
    ("modules/tools/drgnx-work-ui.el" . "get-buffer-create \" *drgnx work scan*\""))  ; the scan's output
  "Internal buffers made with buffer hooks, allowed: (FILE . CALL).")

(ert-deftest drgnx-lint/internal-buffers-skip-buffer-hooks ()
  (let (bad)
    (dolist (f (drgnx-lint-bt--files "core" "wb" "modules"))
      (let ((rel (file-relative-name f drgnx-dir)))
        (dolist (call (drgnx-lint-bt--internal-buffers-with-hooks f))
          (unless (member (cons rel call) drgnx-lint-bt--hooked-buffers)
            (push (format "%s: %s (pass t: inhibit-buffer-hooks)" rel call) bad)))))
    (should (equal (nreverse bad) nil))))

(ert-deftest drgnx-lint/the-internal-buffer-check-sees-a-hooked-buffer ()
  (let ((f (make-temp-file "drgnx-lint" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert "(defun a () (get-buffer-create \" *a*\") (generate-new-buffer \" *b*\" t) (get-buffer-create \"*c*\"))"))
          (should (equal (drgnx-lint-bt--internal-buffers-with-hooks f) '("get-buffer-create \" *a*\""))))
      (delete-file f))))

(defun drgnx-lint-bt--timer-start-p (form)
  "Non-nil when FORM starts a wall-clock timer: `run-with-timer', `run-at-time', or a
`drgnx-timer-start' / `-soon' / `-debounce' / `-poll' form without `:idle t'."
  (or (memq (car form) '(run-with-timer run-at-time))
      (and (memq (car form) '(drgnx-timer-start drgnx-timer-soon drgnx-timer-debounce drgnx-timer-poll))
           (not (eq (plist-get (nthcdr 4 form) :idle) t)))))

(defun drgnx-lint-bt--timer-callers (file)
  "Names of FILE's top-level definitions (or the head of another top-level form) that start a
wall-clock timer (`drgnx-lint-bt--timer-start-p')."
  (let (out)
    (dolist (top (drgnx-lint-bt--forms file))
      (drgnx-lint-bt--walk top (lambda (form)
                                 (when (drgnx-lint-bt--timer-start-p form)
                                   (let ((name (if (memq (car-safe top) '(defun defmacro cl-defun)) (cadr top) (car-safe top))))
                                     (unless (memq name out) (push name out)))))))
    (nreverse out)))

(defconst drgnx-lint-bt--timer-allowed
  ;; Not a follow path: file-notify events are debounced, then only the changed folders are read
  ;; again — the Explorer's own window, nothing else moves.
  ;; Also: `drgnx-monitors--later' only defers a callback of a monitor query or a move (so it never runs
  ;; inside the caller); it follows nothing and moves no window by itself.
  '(("wb/drgnx-explorer.el" drgnx-explorer--file-event drgnx-explorer--apply-file-events)
    ("wb/drgnx-monitors.el" drgnx-monitors--later))
  "Workbench definitions allowed to start a timer: (FILE NAME…).  Idle timers are not listed: they
run after input, never in the middle of a follow.")

(ert-deftest drgnx-lint/no-timers-in-workbench-follow-paths ()
  (let (bad)
    (dolist (f (drgnx-lint-bt--files "wb"))
      (let ((rel (file-relative-name f drgnx-dir)))
        (dolist (name (drgnx-lint-bt--timer-callers f))
          (unless (memq name (cdr (assoc rel drgnx-lint-bt--timer-allowed)))
            (push (format "%s: %s starts a timer (follow on the bus's edges)" rel name) bad)))))
    (should (equal (nreverse bad) nil))))

(ert-deftest drgnx-lint/the-timer-check-names-the-caller ()
  (let ((f (make-temp-file "drgnx-lint" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert "(defun a () (run-with-timer 1 nil #'ignore))\n(defun b () (run-with-idle-timer 1 nil #'ignore))\n"
                    "(add-hook 'x (lambda () (run-at-time 1 nil #'ignore)))\n"
                    "(defun c () (drgnx-timer-soon 'k 1 #'ignore))\n"
                    "(defun d () (drgnx-timer-soon 'k 1 #'ignore :idle t))\n"
                    "(defun e () (drgnx-timer-poll 'k 1 #'ignore))"))
          (should (equal (drgnx-lint-bt--timer-callers f) '(a add-hook c e))))
      (delete-file f))))

;; Timers in modules/ and wb/ go through the layer (`drgnx-timer-*`, docs/develop/core.md "Timers").
(defconst drgnx-lint-timers--raw-heads
  '(run-at-time run-with-timer run-with-idle-timer timer-set-time timer-set-idle-time)
  "Raw timer starts: allowed only as a deferral with delay 0 and no repeat.")

(defconst drgnx-lint-timers--fn-arg
  '((run-at-time . 3) (run-with-timer . 3) (run-with-idle-timer . 3) (timer-set-function . 2))
  "Position of the function argument (counting the head as 0) of the raw calls that take one.")

(defun drgnx-lint-timers--lambda-p (arg)
  "Non-nil when ARG is a lambda, a closure or an `apply-partially' form (quoted or not)."
  (and (consp arg)
       (or (memq (car arg) '(lambda closure apply-partially))
           (and (eq (car arg) 'function) (consp (cadr arg)) (memq (car (cadr arg)) '(lambda closure))))))

(defun drgnx-lint-timers--drgnx-head-p (head)
  (and (symbolp head) (string-prefix-p "drgnx-timer-" (symbol-name head))
       (not (string-prefix-p "drgnx-timer--" (symbol-name head)))))

(defun drgnx-lint-timers--watched-p (head)
  (or (memq head drgnx-lint-timers--raw-heads) (assq head drgnx-lint-timers--fn-arg)
      (eq head 'timer-create) (drgnx-lint-timers--drgnx-head-p head)))

(defun drgnx-lint-timers--bad-p (form)
  "Non-nil when FORM, a call of a watched head, breaks the rule."
  (let* ((head (car form))
         (tail (if (memq head '(timer-set-time timer-set-idle-time)) (nthcdr 2 form) (cdr form)))
         (zero-nil (and (eql (car tail) 0) (null (cadr tail)))))
    (or (and (cond ((drgnx-lint-timers--drgnx-head-p head) (drgnx-lint-timers--lambda-p (nth 3 form)))
                   ((eq head 'timer-create) (seq-some #'drgnx-lint-timers--lambda-p (cdr form)))
                   ((assq head drgnx-lint-timers--fn-arg)
                    (drgnx-lint-timers--lambda-p (nth (cdr (assq head drgnx-lint-timers--fn-arg)) form))))
             ;; `(run-at-time 0 nil FN …)' passes, lambda or not.
             (not (and (eq head 'run-at-time) zero-nil)))
        (and (memq head drgnx-lint-timers--raw-heads) (not zero-nil)))))

(defun drgnx-lint-timers--violations (file)
  "Violations in FILE: a list of (LINE . FORM-STRING).
A lambda, closure or `apply-partially' as the function of a timer start, and a raw timer start
unless its delay is the literal 0 and its repeat nil or absent (`(run-at-time 0 nil FN …)' passes,
lambda or not)."
  (let (out)
    (with-temp-buffer
      (insert-file-contents file)
      (with-syntax-table emacs-lisp-mode-syntax-table
        (goto-char (point-min))
        (condition-case nil
            (while (progn (forward-comment (buffer-size)) (not (eobp)))
              (let* ((start (point)) (top (read (current-buffer))) (end (point)) (cursor (make-hash-table :test 'eq)))
                (drgnx-lint-bt--walk
                 top
                 (lambda (form)
                   (when (drgnx-lint-timers--watched-p (car form))
                     ;; The form's place: the next "(HEAD" after the previous one of that head, outside a
                     ;; string or a comment (forms are walked in textual order).
                     (let ((from (gethash (car form) cursor start)) (re (concat "(" (regexp-quote (symbol-name (car form))) "\\_>")) hit)
                       (goto-char from)
                       (while (and (not hit) (re-search-forward re end t))
                         (unless (nth 8 (save-excursion (parse-partial-sexp start (match-beginning 0))))
                           (setq hit (match-beginning 0))))
                       (when hit
                         (puthash (car form) (1+ hit) cursor)
                         (when (drgnx-lint-timers--bad-p form)
                           (push (cons (line-number-at-pos hit)
                                       (buffer-substring-no-properties hit (scan-sexps hit 1)))
                                 out)))))))
                (goto-char end)))
          (end-of-file nil))))
    (nreverse out)))

(defconst drgnx-lint-timers--not-yet
  '(("modules/tools/drgnx-agents-ui.el" 3)
    ("modules/tools/drgnx-ai-ui.el" 3)
    ("modules/tools/drgnx-cockpit-cards.el" 3)
    ("modules/tools/drgnx-cockpit-edits.el" 3)
    ("modules/tools/drgnx-cockpit-feed.el" 2)
    ("modules/tools/drgnx-cockpit.el" 2)
    ("modules/tools/drgnx-job-ui.el" 1)
    ("modules/tools/drgnx-live.el" 2)
    ("modules/tools/drgnx-replace.el" 3)
    ("modules/ui/drgnx-quickhelp.el" 5)
    ("modules/ui/drgnx-start.el" 1)
    ("modules/ui/drgnx-statusbar.el" 1)
    ("modules/ui/drgnx-topline.el" 1)
    ("modules/ui/drgnx-tty-fallback-layer.el" 1)
    ("modules/ui/drgnx-tty-popups.el" 1)
    ("wb/drgnx-explorer.el" 4)
    ("wb/drgnx-outline.el" 1)
    ("wb/drgnx-signal.el" 1))
  "Timer sites that do not go through `drgnx-timer-*' yet: (FILE COUNT).
Counts can only fall; teardown's Task 24 needs this list empty.  A branch merged later adds its
files' counts in its merge commit.")

(ert-deftest drgnx-lint/the-timer-lint-sees-each-form ()
  (let ((f (make-temp-file "drgnx-lint" nil ".el"))
        (bad '("(run-at-time 1 nil #'f)" "(run-with-timer 1 nil #'f)" "(run-with-idle-timer 1 nil #'f)"
               "(run-with-timer 0 5 #'f)" "(run-with-timer 0 nil (lambda () 1))" "(timer-set-time tm 5)" "(timer-set-idle-time tm 5)"
               "(run-at-time 1 nil (lambda () 1))"
               "(run-with-idle-timer 1 nil (apply-partially #'f 1))"
               "(timer-set-function tm (lambda () 1))" "(timer-create tm (lambda () 1))"
               "(drgnx-timer-start 'k 1 (lambda () 1))" "(drgnx-timer-soon 'k 1 #'(lambda () 1))"
               "(drgnx-timer-poll 'k 1 (apply-partially #'f 1))"))
        (good '("(run-at-time 0 nil (lambda () 1))" "(run-at-time 0 nil #'f)" "(drgnx-timer-start 'k 1 #'f)"
                "(drgnx-timer-soon 'k 0.1 'f :idle t)")))
    (unwind-protect
        (progn
          (dolist (form bad)
            (with-temp-file f (insert "(defun a ()\n  \"(run-at-time 1 nil #'f) in a string\"\n  ;; (run-at-time 1 nil #'f)\n  " form ")"))
            (should (equal (drgnx-lint-timers--violations f) (list (cons 4 form)))))
          (dolist (form good)
            (with-temp-file f (insert "(defun a () " form ")"))
            (should (equal (drgnx-lint-timers--violations f) nil)))
          ;; The line of each: two forms in one file, the allowed one between the bad ones.
          (with-temp-file f
            (insert "(run-with-timer 1 nil #'f)\n(run-at-time 0 nil #'f)\n\n(defun b ()\n  (run-with-timer 2 nil #'f))"))
          (should (equal (drgnx-lint-timers--violations f)
                         '((1 . "(run-with-timer 1 nil #'f)") (5 . "(run-with-timer 2 nil #'f)")))))
      (delete-file f))))

(ert-deftest drgnx-lint/timers-go-through-the-layer ()
  (let (bad)
    (dolist (f (drgnx-lint-bt--files "modules" "wb"))
      (let* ((rel (file-relative-name f drgnx-dir))
             (found (drgnx-lint-timers--violations f))
             (allowed (or (cadr (assoc rel drgnx-lint-timers--not-yet)) 0)))
        (cond ((> (length found) allowed)
               (push (format "%s: %d raw timer(s), %d allowed — above: a new raw timer, use `drgnx-timer-*' (%s)"
                             rel (length found) allowed
                             (mapconcat (lambda (v) (format "line %d" (car v))) found ", "))
                     bad))
              ((< (length found) allowed)
               (push (format "%s: %d raw timer(s), %d allowed — below: lower the count in `drgnx-lint-timers--not-yet'"
                             rel (length found) allowed)
                     bad)))))
    ;; A not-yet entry for a file that is gone fails as "below" too.
    (dolist (e drgnx-lint-timers--not-yet)
      (unless (file-exists-p (expand-file-name (car e) drgnx-dir))
        (push (format "%s: no such file — below: remove it from `drgnx-lint-timers--not-yet'" (car e)) bad)))
    (should (equal (nreverse bad) nil))))

(provide 'lint-buffers-timers-test)
;;; lint-buffers-timers-test.el ends here
