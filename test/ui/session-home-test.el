;;; session-home-test.el --- GUI test: a session's home is its run's -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)

(ert-deftest drgnx-ui-ui/a-session-writes-nothing-under-the-real-home ()
  ;; HOME in this session is under its run directory; the caller's real directories are not its own.
  (let ((run (getenv "DRGNX_UI_RUN")))
    (should (string-prefix-p (file-name-as-directory run) (file-name-as-directory (getenv "HOME"))))
    (should (string-prefix-p run (expand-file-name "~")))
    (dolist (d '("XDG_CONFIG_HOME" "XDG_DATA_HOME" "XDG_CACHE_HOME" "XDG_STATE_HOME"))
      (when (getenv d) (should (string-prefix-p run (getenv d)))))
    (should (string-prefix-p run (expand-file-name user-emacs-directory)))))
