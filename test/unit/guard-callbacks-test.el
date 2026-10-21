;;; guard-callbacks-test.el --- batch tests: core and wb process callbacks are handed over wrapped -*- lexical-binding: t -*-
;; The lint (lint-guard-test.el) reads the source; these run the code that starts each process and look at the
;; callbacks the process got: every one that does work is a `drgnx-guard-wrap' closure (recorded as the wrapper
;; returns it), not the bare function.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-guard)
(require 'drgnx-acp)
(require 'drgnx-gateway)
(require 'drgnx-hub-client)
(require 'drgnx-job-snapshot)
(require 'drgnx-job-worktree)
(require 'drgnx-sandbox)
(require 'drgnx-sandbox-proxy)
(require 'drgnx-explorer)

(defvar drgnx-guard-callbacks-test--wrapped nil "The closures `drgnx-guard-wrap' returned while recording.")

(defun drgnx-guard-callbacks-test--record (wrapper)
  (push wrapper drgnx-guard-callbacks-test--wrapped)
  wrapper)

(defmacro drgnx-guard-callbacks-test--recording (&rest body)
  "Run BODY with every `drgnx-guard-wrap' result recorded."
  `(let ((drgnx-guard-callbacks-test--wrapped nil))
     (advice-add 'drgnx-guard-wrap :filter-return #'drgnx-guard-callbacks-test--record)
     (unwind-protect (progn ,@body)
       (advice-remove 'drgnx-guard-wrap #'drgnx-guard-callbacks-test--record))))

(defun drgnx-guard-callbacks-test--wrapped-p (callback)
  (and (memq callback drgnx-guard-callbacks-test--wrapped) t))

(defun drgnx-guard-callbacks-test--should-wrap (proc &rest kinds)
  "PROC's filter and/or sentinel (KINDS, `filter' `sentinel') are guard wrappers."
  (dolist (kind kinds)
    (let ((callback (if (eq kind 'filter) (process-filter proc) (process-sentinel proc))))
      (should (drgnx-guard-callbacks-test--wrapped-p callback)))))

(defun drgnx-guard-callbacks-test--kill (&rest procs)
  (dolist (p procs) (when (processp p) (ignore-errors (delete-process p)))))

(ert-deftest drgnx-guard/acp-callbacks-are-wrapped ()
  (drgnx-guard-callbacks-test--recording
   (let ((conn (drgnx-acp-start (list "sleep" "30"))))
     (unwind-protect
         (progn
           (drgnx-guard-callbacks-test--should-wrap (drgnx-acp-conn-process conn) 'filter 'sentinel)
           (drgnx-guard-callbacks-test--should-wrap (drgnx-acp-conn-stderr-process conn) 'filter))
       (drgnx-acp-stop conn)))))

(ert-deftest drgnx-guard/gateway-callbacks-are-wrapped ()
  (drgnx-guard-callbacks-test--recording
   (unwind-protect
       (progn
         (drgnx-gateway-start)
         (drgnx-guard-callbacks-test--should-wrap drgnx-gateway--server 'filter 'sentinel))
     (drgnx-gateway-stop))))

(ert-deftest drgnx-guard/hub-callbacks-are-wrapped ()
  "The hub client's connection hands the caller's filter over wrapped."
  (drgnx-guard-callbacks-test--recording
   (let (args)
     (cl-letf (((symbol-function 'make-network-process) (lambda (&rest a) (setq args a) nil))
               ((symbol-function 'drgnx-hub-socket) (lambda () "/nonexistent/hub.sock"))
               ((symbol-function 'drgnx-hub--untrusted) (lambda (_) nil)))
       (drgnx-hub--connect-socket #'ignore))
     (should (drgnx-guard-callbacks-test--wrapped-p (plist-get args :filter))))))

(ert-deftest drgnx-guard/job-snapshot-callbacks-are-wrapped ()
  (drgnx-guard-callbacks-test--recording
   (let ((p (drgnx-job-snapshot--run default-directory '("sleep" "30") nil #'ignore)))
     (unwind-protect (drgnx-guard-callbacks-test--should-wrap p 'sentinel)
       (drgnx-guard-callbacks-test--kill p)))))

(ert-deftest drgnx-guard/job-worktree-callbacks-are-wrapped ()
  (drgnx-guard-callbacks-test--recording
   (let ((p (drgnx-job-worktree--run default-directory '("sleep" "30") nil #'ignore)))
     (unwind-protect (drgnx-guard-callbacks-test--should-wrap p 'sentinel)
       (drgnx-guard-callbacks-test--kill p)))))

(ert-deftest drgnx-guard/sandbox-callbacks-are-wrapped ()
  (drgnx-guard-callbacks-test--recording
   (let ((p (drgnx-sandbox--spawn "drgnx-guard-callbacks-test" '("sleep" "30") 60 #'ignore)))
     (unwind-protect (drgnx-guard-callbacks-test--should-wrap p 'sentinel)
       (drgnx-guard-callbacks-test--kill p)))))

(ert-deftest drgnx-guard/sandbox-proxy-callbacks-are-wrapped ()
  (drgnx-guard-callbacks-test--recording
   (let (args fake)
     (unwind-protect
         (progn
           (cl-letf (((symbol-function 'make-process)
                      (lambda (&rest a) (setq args a fake (make-pipe-process :name "guard-callbacks-test")))))
             (drgnx-sandbox-proxy-start "guard-test" '("example.com:443") "/nonexistent/proxy.sock"))
           (should (drgnx-guard-callbacks-test--wrapped-p (plist-get args :filter))))
       (drgnx-guard-callbacks-test--kill fake)))))

(ert-deftest drgnx-guard/explorer-callbacks-are-wrapped ()
  (drgnx-guard-callbacks-test--recording
   (let (args)
     (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) "/usr/bin/gio"))
               ((symbol-function 'make-process) (lambda (&rest a) (setq args a) nil)))
       (drgnx-explorer--gio-trash "/nonexistent/file"))
     (should (drgnx-guard-callbacks-test--wrapped-p (plist-get args :sentinel))))))

(provide 'guard-callbacks-test)
;;; guard-callbacks-test.el ends here
