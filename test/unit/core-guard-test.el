;;; core-guard-test.el --- batch tests: no prompts in automatic paths -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-guard)
(require 'drgnx-timer)

(defun drgnx-test--fake-prompt (&rest _) 'answered)

(defmacro drgnx-test--with-guard (&rest body)
  `(let ((drgnx-guard-prompt-functions '(drgnx-test--fake-prompt)))
     (drgnx-guard-mode 1)
     (unwind-protect (progn ,@body) (drgnx-guard-mode -1))))

(ert-deftest drgnx-guard/commands-may-prompt ()
  (drgnx-test--with-guard
   (should (eq (drgnx-test--fake-prompt "q") 'answered))))

(ert-deftest drgnx-guard/timers-may-not ()
  (drgnx-test--with-guard
   (let ((drgnx-guard--timer-fn 'some-timer))
     (should-error (drgnx-test--fake-prompt "q") :type 'drgnx-prompt-in-automatic-path))))

(ert-deftest drgnx-guard/automatic-blocks-may-not ()
  (drgnx-test--with-guard
   (should-error (drgnx-automatic (drgnx-test--fake-prompt "q")) :type 'drgnx-prompt-in-automatic-path)))

(ert-deftest drgnx-guard/daemon-startup-may-not ()
  (drgnx-test--with-guard
   (cl-letf (((symbol-function 'drgnx-guard--daemon-starting-p) (lambda () t)))
     (should-error (drgnx-test--fake-prompt "q") :type 'drgnx-prompt-in-automatic-path))))

(ert-deftest drgnx-guard/error-names-the-prompt ()
  (drgnx-test--with-guard
   (let ((err (should-error (drgnx-automatic (drgnx-test--fake-prompt "Delete everything? "))
                            :type 'drgnx-prompt-in-automatic-path)))
     (should (string-search "Delete everything?" (error-message-string err))))))

(ert-deftest drgnx-guard/off-means-off ()
  (let ((drgnx-guard-prompt-functions '(drgnx-test--fake-prompt)))
    (drgnx-guard-mode 1) (drgnx-guard-mode -1)
    (should (eq (drgnx-automatic (drgnx-test--fake-prompt "q")) 'answered))))

;;;; Deferred fixes (M2-1)

(ert-deftest drgnx-guard/the-other-prompts-are-guarded ()
  ;; read-multiple-choice, read-answer, read-key and read-char-choice ask too; read-event does not
  ;; (sit-for uses it).
  (dolist (fn '(read-multiple-choice read-answer read-key read-char-choice))
    (should (memq fn drgnx-guard-prompt-functions)))
  (should-not (memq 'read-event drgnx-guard-prompt-functions)))

(ert-deftest drgnx-guard/daemon-start-lasts-until-window-setup ()
  ;; after-init-hook and emacs-startup-hook run after after-init-time is set: still nobody to answer.
  (let ((after-init-time nil) (window-setup-hook nil) (drgnx-guard--started nil))
    (cl-letf (((symbol-function 'daemonp) (lambda () t)))
      (drgnx-test--with-guard
       (should-error (drgnx-test--fake-prompt "q") :type 'drgnx-prompt-in-automatic-path)
       (setq after-init-time (current-time))          ; after-init-hook, emacs-startup-hook
       (should-error (drgnx-test--fake-prompt "q") :type 'drgnx-prompt-in-automatic-path)
       (run-hooks 'window-setup-hook)                  ; the last of startup
       (should (eq (drgnx-test--fake-prompt "q") 'answered))))))

(ert-deftest drgnx-guard/turned-on-after-startup-the-daemon-may-ask ()
  (let ((after-init-time (current-time)) (window-setup-hook nil) (drgnx-guard--started nil))
    (cl-letf (((symbol-function 'daemonp) (lambda () t)))
      (drgnx-test--with-guard
       (should (eq (drgnx-test--fake-prompt "q") 'answered))))))

(defun drgnx-guard-test--named () nil)

(ert-deftest drgnx-guard/a-layer-timer-is-named-by-its-function ()
  (drgnx-test--with-guard
   (let ((raw (run-with-timer 3600 nil #'drgnx-guard-test--named)))
     (unwind-protect
         (progn
           (drgnx-timer-start 'guard-k 3600 #'drgnx-guard-test--named)
           (let ((tm (drgnx-timer--entry-timer (gethash 'guard-k drgnx-timer--table))))
             (should (eq 'drgnx-guard-test--named (drgnx-guard--timer (lambda (_) drgnx-guard--timer-fn) tm)))
             (should (eq 'drgnx-guard-test--named (drgnx-guard--timer (lambda (_) drgnx-guard--timer-fn) raw)))))   ; a raw timer as before
       (drgnx-timer-cancel 'guard-k)
       (cancel-timer raw)))))

;;;; The wrapper for process callbacks and hooks (notices Task 5)

(require 'seq)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)

(defmacro drgnx-guard-test--with-mode (&rest body)
  "BODY with `drgnx-guard-mode' on over the real prompt functions; afterwards the mode is as it was."
  `(let ((was drgnx-guard-mode))
     (drgnx-guard-mode 1)
     (unwind-protect (progn ,@body) (unless was (drgnx-guard-mode -1)))))

(defun drgnx-guard-test--guard-notice (label)
  "The `guard' event with id LABEL, or nil."
  (seq-find (lambda (n) (equal (plist-get n :id) label)) (drgnx-notices :source 'guard)))

(ert-deftest drgnx-guard/wrap-returns-a-function-that-runs-fn ()
  (drgnx-notice-test-with-model
    (let ((f (drgnx-guard-wrap (lambda (a b) (list a b (drgnx-guard-automatic-p))) "pair")))
      (should (functionp f))
      (should (equal (funcall f 1 2) '(1 2 t)))   ; FN's value, as automatic code
      (should-not (drgnx-notices :source 'guard)))))

(ert-deftest drgnx-guard/a-prompt-in-a-wrapped-sentinel-is-refused-and-recorded ()
  (drgnx-notice-test-with-model
    (drgnx-guard-test--with-mode
     (let* ((done nil) (answered nil)
            (p (make-process :name "drgnx-guard-test" :command '("true") :connection-type 'pipe :noquery t :buffer nil
                             :sentinel (drgnx-guard-wrap (lambda (p _e)
                                                           (unless (process-live-p p)
                                                             (setq done t)
                                                             (y-or-n-p "Delete everything? ")
                                                             (setq answered t)))
                                                         "test sentinel"))))
       (should p)
       (drgnx-test-wait (lambda () done) :what "the sentinel")
       (should-not answered)                           ; refused before it asked
       (let ((n (drgnx-guard-test--guard-notice "test sentinel")))
         (should n)
         (should (eq (plist-get n :severity) 'fail))
         (should (equal (plist-get n :text)
                        "test sentinel asked a question from a process callback; drgnx refused (it would freeze Emacs)")))))))

(ert-deftest drgnx-guard/other-errors-are-warn-events ()
  (drgnx-notice-test-with-model
    (should-not (funcall (drgnx-guard-wrap (lambda () (error "Disk full")) "writer")))   ; not signalled again
    (let ((n (drgnx-guard-test--guard-notice "writer")))
      (should (eq (plist-get n :severity) 'warn))
      (should (eq (plist-get n :life) 'event))
      (should (equal (plist-get n :text) "writer: Disk full")))))

(ert-deftest drgnx-guard/a-repeat-counts ()
  (drgnx-notice-test-with-model
    (let ((f (drgnx-guard-wrap (lambda () (error "Disk full")) "writer")))
      (funcall f) (funcall f)
      (should (= (length (drgnx-notices :source 'guard)) 1))
      (should (= (plist-get (drgnx-guard-test--guard-notice "writer") :count) 2)))))

(ert-deftest drgnx-guard/the-first-catch-of-a-label-is-said ()
  ;; S4: Emacs said a failed filter; the guard says the first catch per label in the echo area (repeats only count)
  (drgnx-notice-test-with-model
    (let ((said 0))
      (add-hook 'drgnx-notice-functions
                (lambda (c) (when (and (eq (plist-get c :op) 'post) (plist-get (plist-get c :notice) :echo))
                              (setq said (1+ said)))))
      (let ((f (drgnx-guard-wrap (lambda () (error "Disk full")) "writer")))
        (funcall f) (funcall f))
      (should (= said 1))
      (funcall (drgnx-guard-wrap (lambda () (error "Disk gone")) "writer"))   ; another error, the same label
      (should (= said 1))
      (funcall (drgnx-guard-wrap (lambda () (error "Boom")) "reader"))
      (should (= said 2)))))

(defvar drgnx-guard-test--hook nil)
(defvar drgnx-guard-test--heard nil)
(defun drgnx-guard-test--fails (&rest _) (error "Boom"))
(defun drgnx-guard-test--hears (&rest args) (push (cons (drgnx-guard-automatic-p) args) drgnx-guard-test--heard))

(ert-deftest drgnx-guard/run-hook-wraps-each-function ()
  (drgnx-notice-test-with-model
    (let ((drgnx-guard-test--hook (list #'drgnx-guard-test--fails #'drgnx-guard-test--hears))
          (drgnx-guard-test--heard nil))
      (should-not (drgnx-guard-run-hook 'drgnx-guard-test--hook 1 2))
      (should (equal drgnx-guard-test--heard '((t 1 2))))   ; the next function still ran, as automatic code
      (let ((n (drgnx-guard-test--guard-notice "drgnx-guard-test--hook drgnx-guard-test--fails")))
        (should (eq (plist-get n :severity) 'warn))
        (should (equal (plist-get n :text) "drgnx-guard-test--hook drgnx-guard-test--fails: Boom"))))))

(ert-deftest drgnx-guard/no-debugger-in-batch ()
  ;; ERT turns `debug-on-error' on; in batch (or a daemon with no client frame) the guard still catches.
  (drgnx-notice-test-with-model
    (let ((debug-on-error t))
      (should-not (funcall (drgnx-guard-wrap (lambda () debug-on-error) "d")))
      (should-not (funcall (drgnx-guard-wrap (lambda () (error "Boom")) "e")))
      (should (drgnx-guard-test--guard-notice "e"))
      ;; with a frame the debugger could show itself in, it may
      (cl-letf (((symbol-function 'drgnx-timer--debugger-p) (lambda () t)))
        (should (funcall (drgnx-guard-wrap (lambda () debug-on-error) "d")))))))

(provide 'core-guard-test)
;;; core-guard-test.el ends here
