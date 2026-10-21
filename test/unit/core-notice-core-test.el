;;; core-notice-core-test.el --- batch tests: core producers (hooks, commands, timers, terminal) post notices -*- lexical-binding: t -*-
;; The keys producer's tests are in core-keys-test.el (they need its registry fixture); all have the prefix
;; `drgnx-notice-core/'.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-hooks)
(require 'drgnx-timer)
(require 'drgnx-tty-fallback)
(require 'drgnx-registry)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defvar drgnx-notice-core-test-hook nil "A staged hook for the tests.")
(defun drgnx-notice-core-test--boom (&rest _) (error "Boom"))
(defun drgnx-notice-core-test--ok (&rest _) nil)

(ert-deftest drgnx-notice-core/a-hook-error-is-a-warn-event ()
  (drgnx-notice-test-with-model
    (let ((drgnx-notice-core-test-hook nil) (drgnx-hooks--done nil))
      (add-hook 'drgnx-notice-core-test-hook #'drgnx-notice-core-test--boom)
      (drgnx-hooks-run-once 'drgnx-notice-core-test-hook)
      (let ((ns (drgnx-notices :source 'hooks)))
        (should (= (length ns) 1))
        (should (eq (plist-get (car ns) :severity) 'warn))
        (should (eq (plist-get (car ns) :life) 'event))
        (should (equal (plist-get (car ns) :id) '(drgnx-notice-core-test-hook . drgnx-notice-core-test--boom)))
        (should (equal (plist-get (car ns) :text)
                       "drgnx-notice-core-test-hook: drgnx-notice-core-test--boom: Boom"))))))

(ert-deftest drgnx-notice-core/commands-problems-is-gone ()
  (should-not (boundp 'drgnx-commands-problems))
  (should-not (special-variable-p 'drgnx-commands-problems)))

(defmacro drgnx-notice-core-test--timers (&rest body)
  "BODY on the virtual clock, a fresh notice model, a state dir of its own and no recorded timer errors."
  `(drgnx-notice-test-with-model
     (let* ((state (make-temp-file "drgnx-nc-state" t))
            (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
            (drgnx-timer-errors nil))
       (unwind-protect (drgnx-test-with-clock () ,@body)
         (delete-directory state t)))))

(ert-deftest drgnx-notice-core/a-stopped-timer-is-a-warn-condition ()
  (drgnx-notice-core-test--timers
   (drgnx-timer-start 'nc-k 1 #'drgnx-notice-core-test--boom :repeat 1)
   (drgnx-test-advance 2)
   (should-not (drgnx-notices :source 'timers))          ; two failures: still running
   (drgnx-test-advance 1)
   (let ((ns (drgnx-notices :source 'timers)))
     (should (= (length ns) 1))
     (should (eq (plist-get (car ns) :severity) 'warn))
     (should (eq (plist-get (car ns) :life) 'condition))
     (should (eq (plist-get (car ns) :id) 'nc-k))
     (should (equal (plist-get (car ns) :text)
                    "timer nc-k (drgnx-notice-core-test--boom) stopped after 3 failures: Boom"))
     (should (string-search "report the error" (plist-get (car ns) :fix))))))

(ert-deftest drgnx-notice-core/a-restarted-timer-clears-it ()
  (drgnx-notice-core-test--timers
   (drgnx-timer-start 'nc-k 1 #'drgnx-notice-core-test--boom :repeat 1)
   (drgnx-test-advance 3)
   (should (drgnx-notices :source 'timers))
   (drgnx-timer-start 'nc-k 1 #'drgnx-notice-core-test--ok :repeat 1)
   (should-not (drgnx-notices :source 'timers))
   (drgnx-timer-cancel 'nc-k)))

(ert-deftest drgnx-notice-core/terminal-fallback-problems-are-conditions ()
  (drgnx-notice-test-with-model
    (let ((table '(("C-S-p" :alt nil :prefix "<f6> p" :rejected ("M-j" . "M-j is bound")))))
      (drgnx-tty-fallback-notify "/dev/pts/7" table)
      (let ((ns (drgnx-notices :source 'terminal)))
        (should (= (length ns) 1))
        (should (eq (plist-get (car ns) :severity) 'warn))
        (should (eq (plist-get (car ns) :life) 'condition))
        (should (equal (plist-get (car ns) :id)
                       (cons "/dev/pts/7" (car (drgnx-tty-fallback-problems table)))))
        (should (equal (plist-get (car ns) :text) (car (drgnx-tty-fallback-problems table)))))
      ;; the same terminal with no problem any more: the condition goes; another terminal's stays
      (drgnx-tty-fallback-notify "/dev/pts/8" table)
      (drgnx-tty-fallback-notify "/dev/pts/7" nil)
      (let ((ns (drgnx-notices :source 'terminal)))
        (should (= (length ns) 1))
        (should (equal (car (plist-get (car ns) :id)) "/dev/pts/8"))))))

(provide 'core-notice-core-test)
;;; core-notice-core-test.el ends here
