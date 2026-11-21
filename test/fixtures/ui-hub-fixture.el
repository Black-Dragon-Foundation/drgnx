;;; ui-hub-fixture.el --- a hub for a GUI test: a Ratatoskr of its own, this session connected -*- lexical-binding: t -*-
;;
;; (drgnx-ui-hub-start REPO)   start `ratatoskr serve' (DRGNX_RATATOSKR_BIN, else REPO's own debug build) on a temp
;;                             configuration, wait until it answers, connect this session; the hub's rows then reach
;;                             the panels that ask (the Buffers panel, the Explorer)
;; (drgnx-ui-hub-stop)         disconnect, end the hub, drop its folder
;;
;; A GUI session does not inherit the test runner's variables, so the binary falls back to the checkout's build.  The
;; wait's deadline only bounds a failure (`drgnx-test-wait').
(require 'cl-lib)
(require 'drgnx-hub-client)
(load (expand-file-name "wait-fixture" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(defvar drgnx-ui-hub--process nil "The hub `drgnx-ui-hub-start' started, or nil.")
(defvar drgnx-ui-hub--dir nil "Its temp configuration folder, or nil.")

(defun drgnx-ui-hub--sentinel (process _event)
  "PROCESS (the hub) ended: mark it done, the flag the stop waits for."
  (unless (process-live-p process) (process-put process :done t)))

(defun drgnx-ui-hub-bin (repo)
  "The hub's binary: DRGNX_RATATOSKR_BIN, else REPO's debug build; the test fails without one."
  (let ((bin (or (getenv "DRGNX_RATATOSKR_BIN") (expand-file-name "runtime/target/debug/ratatoskr" repo))))
    (unless (file-executable-p bin) (ert-fail (format "needs a ratatoskr built in the checkout (%s)" bin)))
    bin))

(defun drgnx-ui-hub-start (repo)
  "Start a hub of REPO's binary on a temp configuration and connect this session to it."
  (setq drgnx-ui-hub--dir (make-temp-file "drgnx-ui-hub" t))
  (let ((process-environment (append (list (concat "DRGNX_CONFIG_DIR=" drgnx-ui-hub--dir) "RATATOSKR_SUPERVISOR=none"
                                           (concat "DRGNX_DIR=" (directory-file-name repo)))
                                     process-environment)))
    (setq drgnx-ui-hub--process
          (make-process :name "ratatoskr-ui" :noquery t :connection-type 'pipe
                        :buffer (generate-new-buffer " *ratatoskr-ui*") :sentinel #'drgnx-ui-hub--sentinel
                        :command (list (drgnx-ui-hub-bin repo) "serve" "--foreground"
                                       "--parent-pid" (number-to-string (emacs-pid))))))
  (drgnx-test-wait #'drgnx-hub-running-p :what "the hub answering a ping")
  (drgnx-hub-connect)
  (drgnx-test-wait (lambda () (and drgnx-hub--events (eq (process-status drgnx-hub--events) 'open)))
                   :what "the subscribed connection"))

(defun drgnx-ui-hub-stop ()
  "Disconnect, end the hub `drgnx-ui-hub-start' started and drop its folder."
  (ignore-errors (drgnx-hub-disconnect))
  (when (process-live-p drgnx-ui-hub--process)
    (signal-process drgnx-ui-hub--process 'term)
    (ignore-errors (drgnx-test-wait (lambda () (process-get drgnx-ui-hub--process :done)) :secs 10 :what "the hub's end"))
    (when (process-live-p drgnx-ui-hub--process) (signal-process drgnx-ui-hub--process 'kill)))
  (when (and drgnx-ui-hub--process (buffer-live-p (process-buffer drgnx-ui-hub--process)))
    (kill-buffer (process-buffer drgnx-ui-hub--process)))
  (when drgnx-ui-hub--dir (delete-directory drgnx-ui-hub--dir t))
  (setq drgnx-ui-hub--process nil drgnx-ui-hub--dir nil))

(provide 'ui-hub-fixture)
;;; ui-hub-fixture.el ends here
