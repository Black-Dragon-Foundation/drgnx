;;; ratatoskr-fixture.el --- the real Ratatoskr hub, started for one test -*- lexical-binding: t -*-
;; Only the hub holds provider keys (design §5.6): a test of a feature that hands over a key or asks a keyed provider
;; needs the hub itself, Ratatoskr from DRGNX_RATATOSKR_BIN, never a stand-in.  Without the binary the test skips
;; (test/no-skip.eld lists such tests).
(require 'ert)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)

(defun drgnx-test-ratatoskr-bin ()
  "Ratatoskr: DRGNX_RATATOSKR_BIN when it is an absolute executable, else nil."
  (let ((b (getenv "DRGNX_RATATOSKR_BIN")))
    (and b (file-name-absolute-p b) (file-executable-p b) (not (file-directory-p b)) b)))

(defmacro drgnx-test-with-ratatoskr (root &rest body)
  "BODY with Ratatoskr serving the dirs of this Emacs's environment, its runtime dir under ROOT, and this Emacs
connected to it: the provider table and the keys this Emacs holds handed over, the editor token taken.  Skipped
without the binary."
  (declare (indent 1))
  `(let* ((bin (or (drgnx-test-ratatoskr-bin) (ert-skip "DRGNX_RATATOSKR_BIN is not set")))
          (hub nil)
          (process-environment (append (list (concat "XDG_RUNTIME_DIR=" (file-name-as-directory ,root) "run")
                                             (concat "DRGNX_RATATOSKR_BIN=" bin) "RATATOSKR_SUPERVISOR=none"
                                             (concat "DRGNX_DIR=" (directory-file-name drgnx-dir))
                                             (concat "DRGNX_EMACS=" (expand-file-name invocation-name invocation-directory))
                                             "DRGNX_AI_GATEWAY_URL" "DRGNX_NO_HUB_START"
                                             (format "DRGNX_HUB_PARENT_PID=%d" (emacs-pid)))
                                       process-environment))
          (drgnx-hub--client nil) (drgnx-hub--events nil) (drgnx-hub--subscribing nil)
          (drgnx-hub--pending (make-hash-table)) (drgnx-hub--last-hello nil) (drgnx-hub-client-proves t)
          (drgnx-hub--ensuring nil) (drgnx-hub--binary-version nil) (drgnx-hub--binary-reading nil)
          (drgnx-hub-event-functions nil) (drgnx-hub-disconnect-functions nil) (drgnx-hub-skew-functions nil)
          (drgnx-hub--clear-text-told nil) (drgnx-hub--editor nil) (drgnx-hub--keys-held :unknown) (drgnx-hub--keys-had nil))
     (with-file-modes #o700
       (make-directory (getenv "XDG_RUNTIME_DIR") t)
       (when (getenv "DRGNX_DATA_DIR") (make-directory (getenv "DRGNX_DATA_DIR") t)))
     (unwind-protect
         (progn
           (setq hub (make-process :name "ratatoskr" :noquery t :connection-type 'pipe :buffer (generate-new-buffer " *ratatoskr*")
                                   :sentinel (lambda (p _event) (unless (process-live-p p) (process-put p :done t)))
                                   :command (list bin "serve" "--foreground" "--parent-pid" (number-to-string (emacs-pid)))))
           (drgnx-test-wait #'drgnx-hub-running-p :secs 30 :what "Ratatoskr answers a ping")
           (drgnx-hub-connect)
           (should (drgnx-hub-ensure))                         ; the table and the keys, waited for
           (drgnx-test-wait (lambda () (and drgnx-hub--editor (listp (drgnx-hub-keys-held))))
                            :secs 30 :what "the editor token and the held keys")
           ,@body)
       (drgnx-hub-disconnect)
       (when (process-live-p hub) (signal-process hub 'term))
       (when hub (ignore-errors (drgnx-test-wait (lambda () (process-get hub :done)) :secs 10 :what "Ratatoskr ends")))
       (when (process-live-p hub) (signal-process hub 'kill))
       (when (and hub (buffer-live-p (process-buffer hub))) (kill-buffer (process-buffer hub))))))

(provide 'ratatoskr-fixture)
;;; ratatoskr-fixture.el ends here
