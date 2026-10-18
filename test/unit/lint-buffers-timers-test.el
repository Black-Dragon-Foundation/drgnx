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

(defun drgnx-lint-bt--timer-callers (file)
  "Names of FILE's top-level definitions (or the head of another top-level form) that start a
`run-with-timer' or `run-at-time'."
  (let (out)
    (dolist (top (drgnx-lint-bt--forms file))
      (drgnx-lint-bt--walk top (lambda (form)
                                 (when (memq (car form) '(run-with-timer run-at-time))
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
                    "(add-hook 'x (lambda () (run-at-time 1 nil #'ignore)))"))
          (should (equal (drgnx-lint-bt--timer-callers f) '(a add-hook))))
      (delete-file f))))

(provide 'lint-buffers-timers-test)
;;; lint-buffers-timers-test.el ends here
