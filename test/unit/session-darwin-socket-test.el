;;; session-darwin-socket-test.el --- batch tests: on macOS the server socket ignores XDG_RUNTIME_DIR -*- lexical-binding: t -*-
;; M12a-31.  The platform is a stub (`system-type'); nothing here needs a Mac.
(require 'ert)
(require 'server)
(require 'drgnx)
(require 'drgnx-session)

(defmacro drgnx-session-darwin-socket-test--env (&rest body)
  "BODY with XDG_RUNTIME_DIR and TMPDIR set, a config dir of its own and `server-socket-dir' as Emacs set it."
  `(let* ((dir (make-temp-file "drgnx-session-socket" t))
          (process-environment (append (list "XDG_RUNTIME_DIR=/xdg/run" "TMPDIR=/some/tmp"
                                             (concat "DRGNX_CONFIG_DIR=" dir))
                                       process-environment))
          (server-socket-dir "/xdg/run/emacs"))
     (unwind-protect (progn ,@body) (delete-directory dir t))))

(ert-deftest drgnx-session/darwin-socket-dir-is-emacs-default-without-xdg ()
  (drgnx-session-darwin-socket-test--env
   (should (equal (drgnx-session--darwin-socket-dir) (format "/some/tmp/emacs%d" (user-uid))))))

(ert-deftest drgnx-session/darwin-socket-dir-falls-back-to-tmp ()
  (drgnx-session-darwin-socket-test--env
   (let ((process-environment (cons "TMPDIR" process-environment)))
     (should (equal (drgnx-session--darwin-socket-dir) (format "/tmp/emacs%d" (user-uid)))))))

(ert-deftest drgnx-session/setup-pins-the-socket-dir-on-darwin-only ()
  (drgnx-session-darwin-socket-test--env
   (let ((system-type 'darwin))
     (drgnx-session-setup)
     (should (equal server-socket-dir (format "/some/tmp/emacs%d" (user-uid))))))
  (drgnx-session-darwin-socket-test--env
   (let ((system-type 'gnu/linux))
     (drgnx-session-setup)
     (should (equal server-socket-dir "/xdg/run/emacs")))))
