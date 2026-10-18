;;; face-state-test.el --- batch tests: face.eld — what the face remembers -*- lexical-binding: t -*-
;; Everything runs in a temp state directory: never the user's ~/.local/state, desktop file or systemd unit.
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-face-state)
(require 'drgnx-pkg)

(defmacro drgnx-face-state-test--with (tmp &rest body)
  "BODY with TMP a temp directory that is the whole state directory."
  (declare (indent 1))
  `(let* ((,tmp (file-name-as-directory (make-temp-file "drgnx-face-state" t)))
          (process-environment (cons (concat "XDG_STATE_HOME=" ,tmp) process-environment)))
     (unwind-protect (progn ,@body)
       (delete-directory ,tmp t))))

(ert-deftest drgnx-face-state/round-trip-and-gtk-theme ()
  (drgnx-face-state-test--with tmp
    (should-not (drgnx-face-state-read))
    (should-not (drgnx-face-state-gtk-theme))
    (drgnx-face-state-write '(:variant dark :gtk-theme "Adwaita"))
    (should (equal (drgnx-face-state-read) '(:variant dark :gtk-theme "Adwaita")))
    (should (equal (drgnx-face-state-gtk-theme) "Adwaita:dark"))
    (drgnx-face-state-write '(:variant light :gtk-theme "Adwaita"))
    (should (equal (drgnx-face-state-gtk-theme) "Adwaita:light"))
    ;; `system': the module writes no variant, so nothing is forced on GTK
    (drgnx-face-state-write '(:variant nil :gtk-theme "Adwaita"))
    (should-not (drgnx-face-state-gtk-theme))
    (drgnx-face-state-write '(:gtk-theme "Adwaita"))
    (should-not (drgnx-face-state-gtk-theme))
    ;; no theme name, or one that is not a plain name (it ends up in a unit file and in the launcher's environment)
    (drgnx-face-state-write '(:variant dark :gtk-theme ""))
    (should-not (drgnx-face-state-gtk-theme))
    (drgnx-face-state-write '(:variant dark :gtk-theme "Bad Name\nExecStart=x"))
    (should-not (drgnx-face-state-gtk-theme))
    ;; unreadable: nil, no error
    (with-temp-file (drgnx-face-state-file) (insert "(:variant dark :gtk-theme"))
    (should-not (drgnx-face-state-read))
    (should-not (drgnx-face-state-gtk-theme))
    (with-temp-file (drgnx-face-state-file) (insert "(:variant dark :gtk-theme 7)"))
    (should-not (drgnx-face-state-gtk-theme))))

(ert-deftest drgnx-face-state/service-unit-carries-gtk-theme ()
  (drgnx-face-state-test--with tmp
    (should-not (string-match-p "GTK_THEME" (drgnx-pkg-service-unit)))
    (drgnx-face-state-write '(:variant dark :gtk-theme "Adwaita"))
    (let ((unit (drgnx-pkg-service-unit)))
      (should (string-match-p "^\\[Service\\]\n\\(.*\n\\)*Environment=GTK_THEME=Adwaita:dark\n" unit))
      (should (string-match-p "\\[Install\\]" (substring unit (string-match "Environment=GTK_THEME" unit)))))
    ;; written to the directory asked for, never installed
    (drgnx-pkg-service-unit (concat tmp "units"))
    (should (string-search "Environment=GTK_THEME=Adwaita:dark"
                           (with-temp-buffer (insert-file-contents (concat tmp "units/drgnx.service")) (buffer-string))))
    (drgnx-face-state-write '(:variant nil :gtk-theme "Adwaita"))
    (should-not (string-match-p "GTK_THEME" (drgnx-pkg-service-unit)))))

(defvar drgnx-face-state-test--evil nil)

(ert-deftest drgnx-face-state/reading-never-evaluates ()
  (drgnx-face-state-test--with tmp
    (make-directory (file-name-directory (drgnx-face-state-file)) t)
    (with-temp-file (drgnx-face-state-file)
      (insert "(:variant dark :gtk-theme #.(setq drgnx-face-state-test--evil t))"))
    (should-not (drgnx-face-state-read))
    (should-not drgnx-face-state-test--evil)))

;;; face-state-test.el ends here
