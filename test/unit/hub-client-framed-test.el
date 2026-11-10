;;; hub-client-framed-test.el --- the hub client's connections framed by Nidhogg's reader, against the real Ratatoskr -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The delivery gate replaces a connection's filter, which turns Nidhogg's framing off (docs/develop/harness.md), so no
;; gated row can run the framed path.  This file does: `nidhogg-workers-framing' is on when the client connects, the
;; hub is the real binary (DRGNX_RATATOSKR_BIN, skipped without it), and every wait is on what the hub announces by
;; its own answers (the subscription's, then each call's), never on a clock.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-timer)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)

(defvar nidhogg-workers-framing)
(declare-function nidhogg-process-framing "nidhogg-io.c")

(defmacro drgnx-hub-client-framed-test--with (framing &rest body)
  "BODY with Ratatoskr serving a temp root, this Emacs connected to it with `nidhogg-workers-framing' FRAMING."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-hf" t)))
          (nidhogg-workers-framing ,framing)
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") (concat "XDG_RUNTIME_DIR=" root "run")
                                             (concat "XDG_DATA_HOME=" root "xdg-data") (concat "XDG_CONFIG_HOME=" root "xdg-config")
                                             (concat "XDG_CACHE_HOME=" root "cache") (concat "HOME=" root "home")
                                             "OPENROUTER_API_KEY" "DRGNX_JOBS_LAUNCHER=detached" "DRGNX_NO_HUB_START")
                                       process-environment))
          (drgnx-hub--asked-disconnect nil) (drgnx-hub--resubscribe-since nil) (drgnx-hub--resubscribe-delay 1)
          (drgnx-hub--presence-sent :unknown) (drgnx-hub-editor-token-hook nil))
     (dolist (d '("run" "home" "config" "data")) (with-file-modes #o700 (make-directory (concat root d) t)))
     (unwind-protect (drgnx-test-with-ratatoskr root ,@body)
       (delete-directory root t))))

(defun drgnx-hub-client-framed-test--burst (n)
  "N `ping' calls at once; the list of their results once all N answered (the hub's order)."
  (let ((results nil))
    (dotimes (_ n)
      (drgnx-hub-call "ping" nil (lambda (r e) (push (list r e) results))))
    (drgnx-test-wait (lambda () (= (length results) n)) :secs 30 :what "every answer of the burst")
    results))

(defun drgnx-hub-client-framed-test--check (framing)
  "Connect with FRAMING; the subscription and a burst of calls work, and the connections are framed iff FRAMING."
  (drgnx-hub-client-framed-test--with framing
    (should drgnx-hub--events)                                  ; the subscription answered (the fixture waited)
    (should drgnx-hub--editor)                                  ; and the editor token came on a call connection
    (let ((results (drgnx-hub-client-framed-test--burst 50)))
      (should (= (length results) 50))
      (dolist (r results)
        (should-not (nth 1 r))
        (should (natnump (plist-get (nth 0 r) :pid)))))
    (dolist (conn (list drgnx-hub--events drgnx-hub--client))
      (should (process-get conn :drgnx-proven))
      (if framing
          (should (nidhogg-process-framing conn))
        (should-not (nidhogg-process-framing conn))))))

(ert-deftest drgnx-hub-client-framed/subscribe-and-a-burst-with-framing-on ()
  (skip-unless (drgnx-test-ratatoskr-bin))
  ;; the client frames with `:raw-prefix', which came with Sjá's queue: an older nh-io refuses it and stays unframed
  (require 'nidhogg-views nil t)
  (drgnx-test-require-nidhogg (and (fboundp 'nidhogg-set-process-framing) (fboundp 'nidhogg-view-push))
                              ":raw-prefix framing (with nidhogg-view-push)")
  (drgnx-hub-client-framed-test--check t))

(ert-deftest drgnx-hub-client-framed/subscribe-and-a-burst-with-framing-off ()
  (skip-unless (drgnx-test-ratatoskr-bin))
  (drgnx-hub-client-framed-test--check nil))

;;; hub-client-framed-test.el ends here
