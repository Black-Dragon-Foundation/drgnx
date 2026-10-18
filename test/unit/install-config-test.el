;;; install-config-test.el --- batch tests: install.sh and the config dir that travels -*- lexical-binding: t -*-
;; install.sh's functions run alone in bash with a temp HOME: never the user's ~/.config or ~/.local.
(require 'ert)

(defconst drgnx-install-config-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-install-config-test--function (name env script)
  "Run install.sh's function NAME's definition, then SCRIPT, in bash with ENV (\"K=V\" strings, a bare name
unsets it); return (EXIT . OUTPUT)."
  (let ((process-environment (append env process-environment))
        (default-directory drgnx-install-config-test--root))
    (with-temp-buffer
      (cons (call-process "bash" nil t nil "-c"
                          (format "source <(sed -n '/^%s()/,/^}/p' install.sh); warn() { echo \"warn: $*\"; }; %s"
                                  name script))
            (buffer-string)))))

(ert-deftest drgnx-install-config/remember-emacs-writes-the-data-dir ()
  ;; The Emacs's path is this machine's: it goes to the data dir, so the config dir can travel as it is.
  (let ((home (make-temp-file "drgnx-install-config" t)))
    (unwind-protect
        (let ((emacs (expand-file-name "bin/emacs" home)))
          (make-directory (file-name-directory emacs))
          (write-region "#!/bin/sh\n" nil emacs)
          (set-file-modes emacs #o755)
          (let ((r (drgnx-install-config-test--function
                    "remember_emacs" (list (concat "HOME=" home) "DRGNX_DATA_DIR" "XDG_DATA_HOME" "DRGNX_CONFIG_DIR")
                    (concat "EMACS_BIN=" (shell-quote-argument emacs) "; remember_emacs"))))
            (should (equal r '(0 . ""))))
          (should (equal (with-temp-buffer (insert-file-contents (expand-file-name ".local/share/drgnx/emacs" home))
                                           (buffer-string))
                         (concat emacs "\n")))
          (should-not (file-exists-p (expand-file-name ".config/drgnx" home)))
          ;; $XDG_DATA_HOME, then $DRGNX_DATA_DIR, as drgnx-data-dir reads them
          (let ((r (drgnx-install-config-test--function
                    "remember_emacs" (list (concat "HOME=" home) (concat "XDG_DATA_HOME=" home "/xdg") "DRGNX_DATA_DIR")
                    (concat "EMACS_BIN=" (shell-quote-argument emacs) "; remember_emacs"))))
            (should (= (car r) 0))
            (should (file-exists-p (expand-file-name "xdg/drgnx/emacs" home))))
          (let ((r (drgnx-install-config-test--function
                    "remember_emacs" (list (concat "HOME=" home) (concat "DRGNX_DATA_DIR=" home "/own data"))
                    (concat "EMACS_BIN=" (shell-quote-argument emacs) "; remember_emacs"))))
            (should (= (car r) 0))
            (should (file-exists-p (expand-file-name "own data/emacs" home)))))
      (delete-directory home t))))

;;; install-config-test.el ends here
