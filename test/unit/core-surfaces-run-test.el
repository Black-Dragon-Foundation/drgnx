;;; core-surfaces-run-test.el --- batch tests: the run hook and the palette counter -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-surfaces)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defvar drgnx-test--run-ran nil)
(defun drgnx-test--run-cmd () (interactive) (setq drgnx-test--run-ran t))

(defmacro drgnx-test--with-usage (&rest body)
  "Run BODY with an empty command table, an empty counter and a temp state dir."
  `(let* ((dir (make-temp-file "drgnx-usage" t))
          (process-environment (cons (concat "XDG_STATE_HOME=" dir) process-environment))
          (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
          (drgnx-commands-problems nil)
          (drgnx-surfaces--usage nil) (drgnx-surfaces--usage-dirty nil)
          (drgnx-surfaces--usage-saved nil) (drgnx-surfaces--usage-bad nil))
     (unwind-protect
         (progn
           (drgnx-command-define 'run-cmd :title "Run" :category "Test" :command #'drgnx-test--run-cmd)
           ,@body)
       (drgnx-timer-cancel 'surfaces-usage)
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
     (should (drgnx-timer-active-p 'surfaces-usage))
     ;; The idle flush writes id -> (count . ((day . n) ...)).
     (drgnx-surfaces--usage-flush)
     (should (equal (car (drgnx-surfaces--usage-read file)) `(run-cmd 3 (,today . 3))))
     (should-not drgnx-surfaces--usage-dirty)
     ;; At most once a minute: a flush right after another waits, and writes nothing yet.
     (drgnx-surfaces-run 'run-cmd)
     (drgnx-surfaces--usage-flush)
     (should (equal (cadr (car (drgnx-surfaces--usage-read file))) 3))
     (should drgnx-surfaces--usage-dirty)
     (should (drgnx-timer-active-p 'surfaces-usage))
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

(ert-deftest drgnx-surfaces/usage-is-written-once-per-pause ()
  (drgnx-test-with-clock ()
    (drgnx-test--with-usage
     (let ((file (drgnx-shortcuts-usage-file)))
       (dotimes (_ 3) (drgnx-surfaces-run 'run-cmd))
       (should (equal (drgnx-timer-pending) '((surfaces-usage :core soon))))   ; three runs, one timer
       (should (= 1 (length timer-idle-list)))
       (drgnx-test-idle 2)                                  ; the first pause writes
       (should (= 3 (cadr (assq 'run-cmd (drgnx-surfaces--usage-read file)))))
       (should-not (drgnx-timer-active-p 'surfaces-usage))
       ;; more runs: nothing is written inside the minute, and still one timer, set for what is left of it
       (drgnx-surfaces-run 'run-cmd)
       (drgnx-surfaces-run 'run-cmd)
       (should (= 1 (length timer-idle-list)))
       (drgnx-test-idle 30)
       (should (= 3 (cadr (assq 'run-cmd (drgnx-surfaces--usage-read file)))))
       (should (drgnx-timer-active-p 'surfaces-usage))
       (drgnx-test-idle 61)                                 ; the next pause past the minute writes
       (should (= 5 (cadr (assq 'run-cmd (drgnx-surfaces--usage-read file)))))
       (should-not (drgnx-timer-active-p 'surfaces-usage))))))

;; A hand-written file with bad entries: the good parts load, counting and the readers work, the next write
;; keeps the bad file as a .bak and leaves a clean one.
(ert-deftest drgnx-shortcuts/usage-bad-file-is-cleaned-and-kept ()
  (drgnx-test--with-usage
   (let ((file (drgnx-shortcuts-usage-file)) (today (time-to-days nil)))
     (make-directory (file-name-directory file) t)
     (with-temp-file file
       (insert (format "((a-cmd 3 . 4) (b-cmd 5 (zzz . 2) (%d . 2) (%d . -1)) (c-cmd 2 (foo)) (d-cmd -1) (\"x\" 1) 7 (run-cmd 4 (%d . 4)))"
                       today today today)))
     (should (= 3 (drgnx-surfaces-usage-count 'a-cmd)))
     (should (= 0 (drgnx-surfaces-usage-week 'a-cmd)))
     (should (= 5 (drgnx-surfaces-usage-count 'b-cmd)))
     (should (= 2 (drgnx-surfaces-usage-week 'b-cmd)))
     (should (= 0 (drgnx-surfaces-usage-week 'c-cmd)))
     (should (= 0 (drgnx-surfaces-usage-count 'd-cmd)))
     (dolist (id '(a-cmd b-cmd c-cmd run-cmd)) (drgnx-surfaces--count-run id))
     (should (= 4 (drgnx-surfaces-usage-count 'a-cmd)))
     (should (= 3 (drgnx-surfaces-usage-week 'b-cmd)))
     (should (= 5 (drgnx-surfaces-usage-week 'run-cmd)))
     (drgnx-surfaces--usage-flush)
     (should (directory-files (file-name-directory file) nil "\\`command-usage\\.eld\\.bak-"))
     (let ((back (drgnx-surfaces--usage-read file)))
       (should-not drgnx-surfaces--usage-bad)
       (should (equal (cdr (assq 'a-cmd back)) `(4 (,today . 1)))))
     ;; No temp files left behind.
     (should-not (directory-files (file-name-directory file) nil "\\`command-usage\\.eld\\.[^b]")))))

(ert-deftest drgnx-shortcuts/usage-unparsable-file-counts-from-zero-and-is-kept ()
  (drgnx-test--with-usage
   (let ((file (drgnx-shortcuts-usage-file)))
     (make-directory (file-name-directory file) t)
     (with-temp-file file (insert "((a-cmd 3 "))
     (should (= 0 (drgnx-surfaces-usage-count 'a-cmd)))
     (drgnx-surfaces--count-run 'run-cmd)
     (drgnx-surfaces--usage-flush)
     (should (directory-files (file-name-directory file) nil "\\`command-usage\\.eld\\.bak-"))
     (should (= 1 (cadr (assq 'run-cmd (drgnx-surfaces--usage-read file))))))))

(ert-deftest drgnx-shortcuts/usage-forced-flush-at-exit-cancels-the-idle-timer ()
  (drgnx-test--with-usage
   (let ((file (drgnx-shortcuts-usage-file)))
     (should (memq #'drgnx-surfaces--usage-flush-at-exit kill-emacs-hook))
     (drgnx-surfaces--count-run 'run-cmd)
     (should (drgnx-timer-active-p 'surfaces-usage))
     (setq drgnx-surfaces--usage-saved (float-time))   ; a write a moment ago: only the exit may write now
     (drgnx-surfaces--usage-flush-at-exit)
     (should-not (drgnx-timer-active-p 'surfaces-usage))
     (should (= 1 (cadr (assq 'run-cmd (drgnx-surfaces--usage-read file))))))))

;;; core-surfaces-run-test.el ends here
