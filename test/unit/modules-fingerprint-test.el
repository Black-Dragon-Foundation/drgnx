;;; modules-fingerprint-test.el --- batch tests: the global-state fingerprint and its diff -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-modules-fingerprint)
(require 'drgnx-timer)

(defvar drgnx-keys--applied)                  ; let-bound by one test
(defvar drgnx-fp-test-hook nil "A hook the fingerprint reads in these tests.")
(defvar drgnx-fp-test-registry nil "An alist registry the fingerprint reads in these tests.")
(defvar drgnx-fp-test-subscribers nil "An EVENT → functions registry.")

(defun drgnx-fp-test-fn () "A hook function, defined in this file." nil)
(defun drgnx-fp-test-timer-fn () "A timer function, defined in this file." nil)
(defun drgnx-fp-test-target () "A function that gets advised." 1)
(defun drgnx-fp-test-advice (orig &rest args) "Advice, defined in this file." (apply orig args))

(defmacro drgnx-fp-test--with-reads (&rest body)
  "BODY with the fingerprint reading the test hook and registries."
  (declare (indent 0))
  `(let ((drgnx-modules-fingerprint-hooks (cons 'drgnx-fp-test-hook drgnx-modules-fingerprint-hooks))
         (drgnx-modules-fingerprint-registries
          '(drgnx-fp-test-registry (drgnx-fp-test-subscribers . :functions)))
         (drgnx-fp-test-hook nil) (drgnx-fp-test-registry nil) (drgnx-fp-test-subscribers nil))
     ,@body))

(defvar drgnx-fp-test-function nil "A function variable the fingerprint reads in one test.")
(defvar fp-test-other-hook nil "A hook neither list names, and not drgnx's own (no drgnx- prefix).")
(defvar drgnx-fp-test-derived-hook nil "A drgnx hook that only the derived list finds.")
(defvar fp-test-aliased-hook nil "A hook with an obsolete alias.")
(defvaralias 'fp-test-aliased-hooks 'fp-test-aliased-hook)
(defvar fp-test-weird-functions nil "Gets a dotted list.")
(require 'drgnx-paths)                  ; drgnx-dir, let-bound by one test
(require 'drgnx-hooks)
(require 'drgnx-guard)

(defun drgnx-fp-test--whats (diff) (mapcar (lambda (d) (plist-get d :what)) diff))

(defun drgnx-fp-test--ours (diff)
  "DIFF without Emacs's own timers and buffers (the undo boundary timer starts whenever a buffer changes)."
  (cl-remove-if-not (lambda (d) (string-match-p "drgnx-fp" (plist-get d :what))) diff))

(ert-deftest drgnx-fingerprint/same-state-same-fingerprint ()
  (drgnx-fp-test--with-reads
    (should-not (drgnx-modules-fingerprint-diff (drgnx-modules-fingerprint) (drgnx-modules-fingerprint)))
    (should-not (drgnx-modules-fingerprint-diff (drgnx-modules-fingerprint t) (drgnx-modules-fingerprint t)))
    ;; a full one against a cheap one compares the fields both have
    (should-not (drgnx-modules-fingerprint-diff (drgnx-modules-fingerprint) (drgnx-modules-fingerprint t)))))

(ert-deftest drgnx-fingerprint/a-hook-entry-shows-with-its-file ()
  (drgnx-fp-test--with-reads
    (let ((before (drgnx-modules-fingerprint)))
      (setq-default drgnx-fp-test-hook (list #'drgnx-fp-test-fn))
      (let ((diff (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint))))
        (should (equal '("hook drgnx-fp-test-hook +drgnx-fp-test-fn") (drgnx-fp-test--whats diff)))
        (should (string-suffix-p "modules-fingerprint-test.el" (plist-get (car diff) :source))))
      ;; gone is reported too
      (let ((with (drgnx-modules-fingerprint)))
        (setq-default drgnx-fp-test-hook nil)
        (should (equal '("hook drgnx-fp-test-hook -drgnx-fp-test-fn")
                       (drgnx-fp-test--whats (drgnx-modules-fingerprint-diff with (drgnx-modules-fingerprint)))))))))

(ert-deftest drgnx-fingerprint/a-lambda-on-a-hook-shows-without-a-file ()
  (drgnx-fp-test--with-reads
    (let ((before (drgnx-modules-fingerprint)))
      (setq-default drgnx-fp-test-hook (list (lambda () (message "x"))))
      (let ((diff (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint))))
        (should (= 1 (length diff)))
        (should (string-prefix-p "hook drgnx-fp-test-hook +" (plist-get (car diff) :what)))
        (should-not (plist-get (car diff) :source))))))

(ert-deftest drgnx-fingerprint/a-timer-shows-with-its-repeat ()
  (let ((before (drgnx-modules-fingerprint)) (repeating nil) (once nil) (idle nil))
    (unwind-protect
        (progn
          (setq repeating (run-with-timer 1000 5 #'drgnx-fp-test-timer-fn)
                once (run-with-timer 1000 nil #'drgnx-fp-test-timer-fn)
                idle (run-with-idle-timer 1000 t #'drgnx-fp-test-timer-fn))
          (let ((whats (drgnx-fp-test--whats (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint)))))
            (should (member "timer +drgnx-fp-test-timer-fn repeat 5" whats))
            (should (member "timer +drgnx-fp-test-timer-fn once" whats))
            (should (cl-some (lambda (w) (string-match-p "\\`timer idle \\+drgnx-fp-test-timer-fn repeat " w)) whats))
            (should (= 3 (length whats))))
          (should (cl-every (lambda (d) (string-suffix-p "modules-fingerprint-test.el" (plist-get d :source)))
                            (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint)))))
      (mapc (lambda (tm) (when tm (cancel-timer tm))) (list repeating once idle)))
    (should-not (drgnx-fp-test--ours (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint))))))

(ert-deftest drgnx-fingerprint/a-layer-timer-is-named-by-key-and-owner ()
  ;; Every layer timer's Emacs function is `drgnx-timer--fire': the line names the key, the owner and the real function.
  (let ((before (drgnx-modules-fingerprint)))
    (unwind-protect
        (progn
          (drgnx-timer-start 'fp-once 1000 #'drgnx-fp-test-timer-fn)
          (drgnx-timer-start 'fp-rep 1000 #'drgnx-fp-test-timer-fn :repeat 5 :owner :core)
          (drgnx-timer-start 'fp-idle 1000 #'drgnx-fp-test-timer-fn :idle t)
          (let* ((diff (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint)))
                 (whats (drgnx-fp-test--whats diff)))
            (should (= 3 (length whats)))
            (should (member "timer +fp-once (:core) drgnx-fp-test-timer-fn" whats))
            (should (member "timer +fp-rep (:core) drgnx-fp-test-timer-fn repeat 5" whats))
            (should (cl-some (lambda (w) (string-match-p "\\`timer \\+fp-idle (:core) drgnx-fp-test-timer-fn idle" w)) whats))
            (should-not (cl-some (lambda (w) (string-search "drgnx-timer--fire" w)) whats))
            (should (cl-every (lambda (d) (string-suffix-p "modules-fingerprint-test.el" (plist-get d :source))) diff))))
      (dolist (k '(fp-once fp-rep fp-idle)) (drgnx-timer-cancel k)))))

(ert-deftest drgnx-fingerprint/a-registry-key-shows ()
  (drgnx-fp-test--with-reads
    (let ((before (drgnx-modules-fingerprint)))
      (push (cons 'a-command 1) drgnx-fp-test-registry)
      (push (cons "a string key" 2) drgnx-fp-test-registry)
      (push (cons 'click (list #'drgnx-fp-test-fn)) drgnx-fp-test-subscribers)
      (let ((whats (drgnx-fp-test--whats (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint)))))
        (should (member "registry drgnx-fp-test-registry +a-command" whats))
        (should (member "registry drgnx-fp-test-registry +a string key" whats))
        (should (member "registry drgnx-fp-test-subscribers +click drgnx-fp-test-fn" whats))
        (should (= 3 (length whats)))))))

(ert-deftest drgnx-fingerprint/a-hash-table-registry-shows-its-keys ()
  (let ((tbl (make-hash-table :test #'eq))
        (drgnx-modules-fingerprint-registries '(drgnx-fp-test-registry)))
    (let ((drgnx-fp-test-registry tbl))
      (let ((before (drgnx-modules-fingerprint)))
        (puthash 'cmd t tbl)
        (should (equal '("registry drgnx-fp-test-registry +cmd")
                       (drgnx-fp-test--whats (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint)))))))))

(ert-deftest drgnx-fingerprint/a-feature-shows ()
  (let ((before (drgnx-modules-fingerprint)))
    (unwind-protect
        (progn
          (provide 'drgnx-fp-test-feature)
          (should (equal '("feature +drgnx-fp-test-feature")
                         (drgnx-fp-test--whats (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint))))))
      (setq features (delq 'drgnx-fp-test-feature features)))))

(ert-deftest drgnx-fingerprint/an-alist-written-in-place-and-a-global-mode-string-show ()
  (let ((auto-mode-alist (list (cons "\\.fpa\\'" 'text-mode)))
        (default-frame-alist (list (cons 'width 80)))
        (global-mode-string (list "x")))
    (let ((before (drgnx-modules-fingerprint)))
      (setf (alist-get "\\.fpa\\'" auto-mode-alist nil nil #'equal) 'prog-mode) ; the cell changes in place
      (setf (alist-get 'width default-frame-alist) 100)
      (push "[job]" global-mode-string)
      (let ((whats (drgnx-fp-test--whats (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint)))))
        (should (member "auto-mode \\.fpa\\' +prog-mode" whats))
        (should (member "auto-mode \\.fpa\\' -text-mode" whats))
        (should (member "frame-parameter width +100" whats))
        (should (member "mode-string +\"[job]\"" whats))))))

(ert-deftest drgnx-fingerprint/a-global-minor-mode-and-an-after-load-form-show ()
  (let ((global-minor-modes (list 'a-mode))
        (after-load-alist (list (list "drgnx-fp-lib" #'drgnx-fp-test-fn))))
    (let ((before (drgnx-modules-fingerprint)))
      (push 'b-mode global-minor-modes)
      (push (list "drgnx-fp-lib2" #'drgnx-fp-test-fn) after-load-alist)
      (setcdr (car (last after-load-alist)) (list #'drgnx-fp-test-fn #'drgnx-fp-test-timer-fn))
      (let ((whats (drgnx-fp-test--whats (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint)))))
        (should (member "minor-mode +b-mode" whats))
        (should (member "after-load drgnx-fp-lib2 +drgnx-fp-test-fn" whats))
        (should (member "after-load drgnx-fp-lib +drgnx-fp-test-timer-fn" whats))
        (should (= 3 (length whats)))))))

(ert-deftest drgnx-fingerprint/a-buffer-and-a-process-show ()
  (let ((before (drgnx-modules-fingerprint)) buf proc)
    (unwind-protect
        (progn
          (setq buf (generate-new-buffer "drgnx-fp-buffer")
                proc (make-pipe-process :name "drgnx-fp-proc" :noquery t))
          (let ((whats (drgnx-fp-test--whats (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint)))))
            (should (member "buffer +drgnx-fp-buffer" whats))
            (should (member "process +drgnx-fp-proc" whats))))
      (when buf (kill-buffer buf))
      (when proc (delete-process proc))
      (when (get-buffer "drgnx-fp-proc") (kill-buffer "drgnx-fp-proc")))
    (should-not (drgnx-fp-test--ours (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint))))))

(ert-deftest drgnx-fingerprint/applied-keys-and-add-function-on-a-function-variable-show ()
  (let ((drgnx-keys--applied (list '(m k p o)))
        (drgnx-modules-fingerprint-function-variables '(drgnx-fp-test-function))
        (drgnx-fp-test-function nil))
    (let ((before (drgnx-modules-fingerprint)))
      (push '(m2 k2 p2 o2) drgnx-keys--applied)
      (add-function :after (default-value 'drgnx-fp-test-function) #'drgnx-fp-test-fn)
      (let ((whats (drgnx-fp-test--whats (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint)))))
        (should (member "drgnx-keys--applied length 1 -> 2" whats))
        (should (member "function-variable drgnx-fp-test-function +drgnx-fp-test-fn" whats))))))

(ert-deftest drgnx-fingerprint/full-finds-advice-on-any-function ()
  (let ((before (drgnx-modules-fingerprint t)))
    (unwind-protect
        (progn
          (advice-add 'drgnx-fp-test-target :around #'drgnx-fp-test-advice)
          (let ((diff (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint t))))
            (should (equal '("advice drgnx-fp-test-target +drgnx-fp-test-advice") (drgnx-fp-test--whats diff)))
            (should (string-suffix-p "modules-fingerprint-test.el" (plist-get (car diff) :source))))
          ;; the cheap fingerprint does not look at advice
          (should-not (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint))))
      (advice-remove 'drgnx-fp-test-target #'drgnx-fp-test-advice))
    (should-not (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint t)))))

(ert-deftest drgnx-fingerprint/full-finds-a-hook-the-fixed-list-lacks ()
  (let ((before (drgnx-modules-fingerprint t)))
    (unwind-protect
        (progn
          (setq-default fp-test-other-hook (list #'drgnx-fp-test-fn))
          (should-not (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint)))
          (should (equal '("hook fp-test-other-hook +drgnx-fp-test-fn")
                         (drgnx-fp-test--whats (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint t))))))
      (setq-default fp-test-other-hook nil))))

(ert-deftest drgnx-fingerprint/a-leak-in-a-listed-hook-or-an-aliased-hook-is-one-line ()
  (let ((before (drgnx-modules-fingerprint t)))
    (unwind-protect
        (progn
          (add-hook 'find-file-hook #'drgnx-fp-test-fn)
          (add-function :after after-focus-change-function #'drgnx-fp-test-fn)
          (setq-default fp-test-aliased-hook (list #'drgnx-fp-test-fn))
          (let ((whats (drgnx-fp-test--whats (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint t)))))
            (should (equal '("function-variable after-focus-change-function +drgnx-fp-test-fn"
                             "hook find-file-hook +drgnx-fp-test-fn"
                             "hook fp-test-aliased-hook +drgnx-fp-test-fn")
                           (sort (copy-sequence whats) #'string<)))))
      (remove-hook 'find-file-hook #'drgnx-fp-test-fn)
      (remove-function after-focus-change-function #'drgnx-fp-test-fn)
      (setq-default fp-test-aliased-hook nil))))

(ert-deftest drgnx-fingerprint/a-dotted-list-in-a-hook-variable-does-not-stop-the-scan ()
  (let ((before (drgnx-modules-fingerprint t)))
    (unwind-protect
        (progn
          (setq-default fp-test-weird-functions '(a . b))
          (setq-default fp-test-other-hook (list #'drgnx-fp-test-fn))
          (let ((after (drgnx-modules-fingerprint t)))   ; does not signal
            (should (equal '("hook fp-test-other-hook +drgnx-fp-test-fn")
                           (drgnx-fp-test--whats (drgnx-modules-fingerprint-diff before after))))))
      (setq-default fp-test-weird-functions nil fp-test-other-hook nil))))

(ert-deftest drgnx-fingerprint/drgnx-hooks-come-from-the-symbols-not-a-list ()
  (let ((names (drgnx-modules-fingerprint--hook-names)))
    (dolist (h '(drgnx-first-file-hook drgnx-first-input-hook drgnx-guard-prompt-functions
                                       drgnx-fp-test-derived-hook kill-buffer-hook))
      (should (memq h names)))
    (should-not (memq 'fp-test-other-hook names))
    (should (memq 'after-focus-change-function (drgnx-modules-fingerprint--function-variable-names))))
  (let ((before (drgnx-modules-fingerprint)))
    (unwind-protect
        (progn
          (setq-default drgnx-fp-test-derived-hook (list #'drgnx-fp-test-fn))
          (should (equal '("hook drgnx-fp-test-derived-hook +drgnx-fp-test-fn")
                         (drgnx-fp-test--whats (drgnx-modules-fingerprint-diff before (drgnx-modules-fingerprint))))))
      (setq-default drgnx-fp-test-derived-hook nil))))

(ert-deftest drgnx-fingerprint/a-sibling-directory-is-not-inside-drgnx-dir ()
  (let* ((root (file-truename (make-temp-file "fp-root" t)))
         (drgnx-dir (expand-file-name "drgnx" root)))   ; no trailing slash
    (unwind-protect
        (progn
          (make-directory (expand-file-name "drgnx/core" root) t)
          (make-directory (expand-file-name "drgnx-other" root) t)
          (should (equal "core/x.el"
                         (drgnx-modules-fingerprint--normalize-file (expand-file-name "drgnx/core/x.elc" root))))
          (should (equal (expand-file-name "drgnx-other/x.el" root)
                         (drgnx-modules-fingerprint--normalize-file (expand-file-name "drgnx-other/x.el" root)))))
      (delete-directory root t))))

(defun drgnx-fp-test--median-ms (fn &optional n)
  "The median wall time of FN over N runs (default 21), in milliseconds."
  (funcall fn)                                          ; warm up
  (let ((times (cl-loop repeat (or n 21)
                        collect (let ((t0 (float-time))) (funcall fn) (* 1000 (- (float-time) t0))))))
    (nth (/ (length times) 2) (sort times #'<))))

(ert-deftest drgnx-fingerprint/cheap-costs-under-2-ms ()
  :tags '(:timing)
  (let ((ms (drgnx-fp-test--median-ms #'drgnx-modules-fingerprint)))
    (message "cheap fingerprint: %.3f ms (median)" ms)
    (should (< ms 2))))

(ert-deftest drgnx-fingerprint/the-full-scan-runs-compiled ()
  ;; Interpreted the scan costs ~10× more.  In an Emacs that has not loaded bytecomp (Emacs 31's ERT no longer loads
  ;; it), compiling the scan is its first load: a `byte-compile-warnings' bound before it would be lexical, and the
  ;; load fails.  A fresh Emacs, so what this one loaded hides nothing.
  (with-temp-buffer
    (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                  "--batch" "-Q" "-L" (expand-file-name "core" drgnx-dir)
                  "--eval" (prin1-to-string
                            '(progn (require 'drgnx-modules-fingerprint)
                                    (drgnx-modules-fingerprint t)
                                    (princ (format "\nbytecomp=%s compiled=%s" (featurep 'bytecomp)
                                                   (compiled-function-p
                                                    (symbol-function 'drgnx-modules-fingerprint--scan)))))))
    (should (string-search "bytecomp=t compiled=t" (buffer-string)))))

(ert-deftest drgnx-fingerprint/full-costs-under-50-ms ()
  :tags '(:timing)
  (let ((ms (drgnx-fp-test--median-ms (lambda () (drgnx-modules-fingerprint t)) 11)))
    (message "full fingerprint: %.3f ms (median)" ms)
    (should (< ms 50))))

(ert-deftest drgnx-fingerprint/the-first-scan-of-drgnx-symbols-costs-under-20-ms ()
  :tags '(:timing)
  (let ((drgnx-modules-fingerprint--own nil) (t0 (float-time)))
    (drgnx-modules-fingerprint--hook-names)
    (let ((ms (* 1000 (- (float-time) t0))))
      (message "first scan of drgnx-* hooks: %.2f ms" ms)
      (should (< ms 20)))))

(provide 'modules-fingerprint-test)
;;; modules-fingerprint-test.el ends here
