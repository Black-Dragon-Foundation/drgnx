;;; session-home-test.el --- GUI test: a session's home is its run's -*- lexical-binding: t -*-
;; test-class: cond
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

(ert-deftest drgnx-ui-ui/a-session-leaves-no-newer-file-in-the-real-homes-drgnx-and-emacs-directories ()
  ;; The real home is the account's (`~USER' comes from the password database, not HOME).  Nothing under the
  ;; directories drgnx and Emacs write to may be newer than the session's run directory, which the session's
  ;; harness made before it started; the harness's own state root, where the caller kept it there, is left out.
  (let* ((run (getenv "DRGNX_UI_RUN"))
         (since (file-attribute-modification-time (file-attributes (expand-file-name "init" run))))
         (real (file-name-as-directory (expand-file-name (concat "~" (user-login-name)))))
         (skip (expand-file-name "ui" (expand-file-name ".local/state/drgnx" real)))
         newer)
    (should-not (equal real (file-name-as-directory (expand-file-name "~"))))
    (dolist (rel '(".config/drgnx" ".local/share/drgnx" ".local/state/drgnx" ".cache/drgnx" ".emacs.d" ".config/emacs"))
      (let ((dir (expand-file-name rel real)))
        (when (file-directory-p dir)
          (dolist (f (directory-files-recursively dir "" nil
                                                  (lambda (d) (not (string-prefix-p skip d)))))
            (when (and (not (string-prefix-p skip f))
                       (time-less-p since (file-attribute-modification-time (file-attributes f))))
              (push f newer))))))
    (should-not newer)))
