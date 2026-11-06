;;; live-session-fixture.el --- a child drgnx session for the live-activation tests -*- lexical-binding: t -*-
;; Started by extensions-live-test.el with `-L core -L modules/tools -l' this file, in a package sandbox (pkg-fixture.el's
;; `drgnx-pkg-child-env').  It activates the packages directory as drgnx does at startup (`drgnx-pkg-activate': the
;; quickstart file `drgnx sync' wrote), sets up live activation (`drgnx-extensions-live-setup'), then serves the test:
;; it announces `ready-N' and parks (handshake-fixture.el); after GO it reads the form in
;; DRGNX_TEST_SESSION_DIR/in-N+1.el, evaluates it, writes (:ok VALUE) or (:error MESSAGE) to out-N+1.eld and announces
;; `ready-N+1'.  A form that calls `kill-emacs' ends it (`kill-emacs-hook' runs).
(require 'drgnx-paths)
(require 'drgnx-pkg-activate)
(require 'drgnx-handshake-fixture (expand-file-name "handshake-fixture" (file-name-directory (or load-file-name (macroexp-file-name)))))

(drgnx-pkg-activate)
(require 'drgnx-extensions-live)
(drgnx-extensions-live-setup)

(let ((dir (file-name-as-directory (getenv "DRGNX_TEST_SESSION_DIR"))) (n 0))
  (while t
    (drgnx-test-child-announce (format "ready-%d" n))
    (setq n (1+ n))
    (let* ((form (with-temp-buffer (insert-file-contents (format "%sin-%d.el" dir n)) (read (current-buffer))))
           (out (condition-case err (list :ok (eval form t)) (error (list :error (error-message-string err))))))
      (with-temp-file (format "%sout-%d.eld" dir n)
        (let ((print-length nil) (print-level nil)) (prin1 out (current-buffer)))))))

;;; live-session-fixture.el ends here
