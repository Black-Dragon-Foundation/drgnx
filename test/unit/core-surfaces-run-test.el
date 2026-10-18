;;; core-surfaces-run-test.el --- batch tests: the run hook and the palette counter -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-surfaces)

(defvar drgnx-test--run-ran nil)
(defun drgnx-test--run-cmd () (interactive) (setq drgnx-test--run-ran t))

(defmacro drgnx-test--with-usage (&rest body)
  "Run BODY with an empty command table, an empty counter and a temp state dir."
  `(let* ((dir (make-temp-file "drgnx-usage" t))
          (process-environment (cons (concat "XDG_STATE_HOME=" dir) process-environment))
          (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
          (drgnx-commands-problems nil)
          (drgnx-surfaces--usage nil) (drgnx-surfaces--usage-dirty nil)
          (drgnx-surfaces--usage-saved nil) (drgnx-surfaces--usage-timer nil))
     (unwind-protect
         (progn
           (drgnx-command-define 'run-cmd :title "Run" :category "Test" :command #'drgnx-test--run-cmd)
           ,@body)
       (when (timerp drgnx-surfaces--usage-timer) (cancel-timer drgnx-surfaces--usage-timer))
       (delete-directory dir t))))

(ert-deftest drgnx-surfaces/run-hook-gets-the-id ()
  (drgnx-test--with-usage
   (let* ((seen nil) (drgnx-test--run-ran nil)
          (drgnx-surfaces-run-functions (list (lambda (id) (push (cons id drgnx-test--run-ran) seen)))))
     (drgnx-surfaces-run 'run-cmd)
     ;; Called once, with the id, after the command ran.
     (should (equal seen '((run-cmd . t)))))))

(ert-deftest drgnx-surfaces/run-hook-error-does-not-break-the-command ()
  (drgnx-test--with-usage
   (let ((drgnx-test--run-ran nil)
         (drgnx-surfaces-run-functions (list (lambda (_) (error "boom")))))
     (drgnx-surfaces-run 'run-cmd)
     (should drgnx-test--run-ran))))

(ert-deftest drgnx-shortcuts/usage-counted-and-saved-at-idle ()
  (drgnx-test--with-usage
   (let ((file (drgnx-shortcuts-usage-file)) (today (time-to-days nil)))
     (should (equal file (expand-file-name "drgnx/command-usage.eld" (getenv "XDG_STATE_HOME"))))
     (dotimes (_ 3) (drgnx-surfaces-run 'run-cmd))
     ;; Counted in memory, nothing written yet (no file write per command), a flush waits for idle.
     (should (= 3 (drgnx-surfaces-usage-count 'run-cmd)))
     (should (= 3 (drgnx-surfaces-usage-week 'run-cmd)))
     (should (= 0 (drgnx-surfaces-usage-count 'other)))
     (should-not (file-exists-p file))
     (should (timerp drgnx-surfaces--usage-timer))
     ;; The idle flush writes id -> (count . ((day . n) ...)).
     (drgnx-surfaces--usage-flush)
     (should (equal (car (drgnx-surfaces--usage-read file)) `(run-cmd 3 (,today . 3))))
     (should-not drgnx-surfaces--usage-dirty)
     ;; At most once a minute: a flush right after another waits, and writes nothing yet.
     (drgnx-surfaces-run 'run-cmd)
     (drgnx-surfaces--usage-flush)
     (should (equal (cadr (car (drgnx-surfaces--usage-read file))) 3))
     (should drgnx-surfaces--usage-dirty)
     (should (timerp drgnx-surfaces--usage-timer))
     ;; A minute later (or at exit) it is saved.
     (setq drgnx-surfaces--usage-saved (- (float-time) 61))
     (drgnx-surfaces--usage-flush)
     (should (equal (cadr (car (drgnx-surfaces--usage-read file))) 4))
     ;; A new session reads it back.
     (setq drgnx-surfaces--usage nil)
     (should (= 4 (drgnx-surfaces-usage-count 'run-cmd))))))

(ert-deftest drgnx-shortcuts/usage-week-drops-old-days ()
  (drgnx-test--with-usage
   (let ((today (time-to-days nil)))
     (setq drgnx-surfaces--usage (make-hash-table :test #'eq))
     (puthash 'run-cmd `(20 (,(- today 8) . 12) (,(- today 6) . 5) (,today . 3)) drgnx-surfaces--usage)
     (should (= 20 (drgnx-surfaces-usage-count 'run-cmd)))
     (should (= 8 (drgnx-surfaces-usage-week 'run-cmd)))
     ;; Counting today prunes what fell out of the week.
     (drgnx-surfaces--count-run 'run-cmd)
     (should (equal (gethash 'run-cmd drgnx-surfaces--usage)
                    `(21 (,(- today 6) . 5) (,today . 4)))))))

(ert-deftest drgnx-shortcuts/usage-save-failure-is-silent ()
  (drgnx-test--with-usage
   ;; The state dir's parent is a file, so writing fails; it must neither signal nor prompt.
   (let ((process-environment (cons (concat "XDG_STATE_HOME=" (expand-file-name "x" dir))
                                    process-environment)))
     (write-region "" nil (expand-file-name "x" dir))
     (drgnx-surfaces--count-run 'run-cmd)
     (drgnx-surfaces--usage-flush)
     (should drgnx-surfaces--usage-dirty))))

;;; core-surfaces-run-test.el ends here
