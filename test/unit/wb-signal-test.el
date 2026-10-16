;;; wb-signal-test.el --- batch tests: the change bus -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-signal)

(defmacro drgnx-signal-test--with (events-var &rest body)
  "BODY with a fresh bus; every emission is pushed onto EVENTS-VAR as (EVENT . DATA)."
  (declare (indent 1))
  `(let ((drgnx-signal--subscribers nil) (drgnx-signal--state nil) (drgnx-signal-errors nil)
         (,events-var nil)
         (dir (make-temp-file "drgnx-signal" t)))
     (unwind-protect
         (progn
           (dolist (e '(editor-changed buffer-set-changed modified-changed))
             (let ((e e)) (drgnx-signal-subscribe e (lambda (data) (push (cons e data) ,events-var)))))
           (drgnx-signal--flush)                   ; the starting state is not an edge
           (setq ,events-var nil)
           ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
       (delete-directory dir t))))

(defun drgnx-signal-test--file (dir name)
  (let ((f (expand-file-name name dir))) (write-region "x\n" nil f nil 'silent) (find-file-noselect f)))

(ert-deftest drgnx-signal/edges-only ()
  (drgnx-signal-test--with events
    (drgnx-signal--flush)
    (should (null events))                          ; nothing changed, nothing emitted
    (let ((a (drgnx-signal-test--file dir "a.txt")))
      (drgnx-signal--flush)
      (should (assq 'buffer-set-changed events))
      (setq events nil)
      (switch-to-buffer a)
      (drgnx-signal--flush)
      (should (equal (cdr (assq 'editor-changed events)) a))
      (setq events nil)
      (drgnx-signal--flush)
      (should (null events)))))

(ert-deftest drgnx-signal/coalesces-into-one-flush ()
  (drgnx-signal-test--with events
    (dotimes (i 10) (drgnx-signal-test--file dir (format "f%d.txt" i)))
    (drgnx-signal--flush)
    (should (= 1 (seq-count (lambda (e) (eq (car e) 'buffer-set-changed)) events)))
    (should (= 10 (length (seq-filter (lambda (b) (string-prefix-p dir (or (buffer-file-name b) "")))
                                      (cdr (assq 'buffer-set-changed events))))))))

(ert-deftest drgnx-signal/internal-buffers-never-count ()
  (drgnx-signal-test--with events
    (kill-buffer (generate-new-buffer " *drgnx internal*"))
    (get-buffer-create " *drgnx other internal*")
    (drgnx-signal--flush)
    (kill-buffer " *drgnx other internal*")
    (should (null events))))

(ert-deftest drgnx-signal/modified-edges ()
  (drgnx-signal-test--with events
    (let ((a (drgnx-signal-test--file dir "a.txt")))
      (drgnx-signal--flush)
      (setq events nil)
      (with-current-buffer a (insert "more"))
      (drgnx-signal--flush)
      (should (equal (cdr (assq 'modified-changed events)) (list a)))
      (setq events nil)
      (with-current-buffer a (insert "and more"))
      (drgnx-signal--flush)
      (should (null events))                        ; still modified: no edge
      (with-current-buffer a (save-buffer))
      (drgnx-signal--flush)
      (should (equal (cdr (assq 'modified-changed events)) (list a))))))

(ert-deftest drgnx-signal/a-failing-subscriber-does-not-stop-the-others ()
  (drgnx-signal-test--with events
    (drgnx-signal-subscribe 'buffer-set-changed (lambda (_) (error "Subscriber broke")))
    (drgnx-signal-test--file dir "a.txt")
    (drgnx-signal--flush)
    (should (assq 'buffer-set-changed events))
    (should (seq-find (lambda (m) (string-search "Subscriber broke" m)) drgnx-signal-errors))))

(ert-deftest drgnx-signal/raw-hooks-only-schedule ()
  ;; Raw hooks do no work: they arm one idle flush.
  (let ((drgnx-signal--timer nil))
    (unwind-protect
        (progn (drgnx-signal--schedule)
               (let ((armed drgnx-signal--timer))
                 (should (timerp armed))
                 (should (memq armed timer-idle-list))
                 (drgnx-signal--schedule)
                 (should (eq drgnx-signal--timer armed))))
      (when (timerp drgnx-signal--timer) (cancel-timer drgnx-signal--timer)))))
