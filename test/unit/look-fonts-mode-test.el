;;; look-fonts-mode-test.el --- font roles: per-mode overrides, ligatures, live preview -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): buffer-local values stand for a `(:mode MODE ...)' section of settings.el, which sets them
;; before `after-change-major-mode-hook'; the preview runs on the manual clock.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-type-faces)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-look-fonts" drgnx-dir) nil t)

(defun drgnx-look-fonts-mode-test--restore ()
  "The faces the tests write to as they were."
  (drgnx-look-fonts-off)
  (dolist (f '(drgnx-ui-text variable-pitch default fixed-pitch))
    (put f 'face-override-spec nil)
    (dolist (fr (frame-list)) (face-spec-recalc f fr))))

(defmacro drgnx-look-fonts-mode-test--clean (&rest body)
  "BODY with the role state empty; the specs undone after."
  (declare (indent 0))
  `(unwind-protect (progn (drgnx-look-fonts-reset) ,@body)
     (drgnx-look-fonts-mode-test--restore)))

(ert-deftest drgnx-look-fonts/mode-remap-only-in-that-mode ()
  "Pattern D: a buffer with its own value of a role gets a remap cookie; another buffer's
`face-remapping-alist' stays nil."
  (drgnx-look-fonts-mode-test--clean
    (with-temp-buffer
      (let ((org (current-buffer)))
        (setq-local drgnx-look-font-code '(:family ui :size 1.1))
        (drgnx-look-fonts-remap-buffer)
        (let ((spec (cdr (assq 'default face-remapping-alist))))
          (should spec)
          (should (equal "Adwaita Sans" (plist-get (car spec) :family)))
          (should (< 1.09 (plist-get (car spec) :height) 1.11)))
        (should (assq 'fixed-pitch face-remapping-alist))
        (with-temp-buffer
          (should-not face-remapping-alist)
          (drgnx-look-fonts-remap-buffer)
          (should-not face-remapping-alist))
        (should (eq org (current-buffer)))))
    (drgnx-look-fonts-on)
    (should (memq 'drgnx-look-fonts--mode-hook after-change-major-mode-hook))))

(ert-deftest drgnx-look-fonts/mode-remap-removed-with-the-override ()
  "Pattern D: when the buffer's own value goes, the cookie goes with it and the alist is empty again; a change of
the setting rewrites the cookie."
  (drgnx-look-fonts-mode-test--clean
    (with-temp-buffer
      (setq-local drgnx-look-font-ui '(:family "Prose Serif"))
      (drgnx-look-fonts-remap-buffer)
      (should (equal "Prose Serif" (plist-get (cadr (assq 'drgnx-ui-text face-remapping-alist)) :family)))
      (setq-local drgnx-look-font-ui '(:family "Other Serif"))
      (drgnx-look-fonts-apply)
      (should (equal "Other Serif" (plist-get (cadr (assq 'drgnx-ui-text face-remapping-alist)) :family)))
      (kill-local-variable 'drgnx-look-font-ui)
      (drgnx-look-fonts-apply)
      (should-not face-remapping-alist))))

(ert-deftest drgnx-look-fonts/ligatures-rules-on-and-off ()
  "Pattern D: `:ligatures t' on the code role adds composition rules for the characters ligatures start with, and
nil takes them away, leaving the table as it was."
  (drgnx-look-fonts-mode-test--clean
    (let ((before (mapcar (lambda (c) (copy-tree (char-table-range composition-function-table c))) '(?= ?- ?>))))
      (let ((drgnx-look-font-code '(:family "JetBrains Mono" :size 1.0 :ligatures t)))
        (drgnx-look-fonts-apply)
        (dolist (c '(?= ?- ?>))
          (let ((rules (char-table-range composition-function-table c)))
            (should (consp rules))
            (should (vectorp (car rules)))
            (should (string-match-p (aref (car rules) 0) "=>")))))
      (let ((drgnx-look-font-code '(:family "JetBrains Mono" :size 1.0 :ligatures nil)))
        (drgnx-look-fonts-apply)
        (should (equal before (mapcar (lambda (c) (char-table-range composition-function-table c)) '(?= ?- ?>))))))))

(ert-deftest drgnx-look-fonts/preview-debounced ()
  "Pattern D, on the manual clock: five changes of a role setting inside 300 ms write the faces once."
  (drgnx-test-with-clock ()
    (let ((n 0))
      (cl-letf (((symbol-function 'drgnx-module-running-p) (lambda (_) t))
                ((symbol-function 'drgnx-look-fonts-apply) (lambda (&rest _) (cl-incf n))))
        (dotimes (_ 5)
          (drgnx-look-fonts--settings-apply)
          (drgnx-test-advance 0.05))
        (should (= 0 n))
        (drgnx-test-advance 0.3)
        (should (= 1 n))))))

(ert-deftest drgnx-look-fonts/fallbacks-name-the-role ()
  "Pattern D: a role whose family is not installed is reported with the family it wanted and the one it got."
  (drgnx-look-fonts-mode-test--clean
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'find-font)
               (lambda (spec &optional _)
                 (and (member (format "%s" (font-get spec :family)) '("Inter" "JetBrains Mono")) spec))))
      (let ((drgnx-look-font-ui '(:family "Missing Sans" :fallback ("Inter" "sans-serif"))))
        (let ((got (drgnx-look-fonts-fallbacks nil)))
          (should (equal '(ui "Missing Sans" "Inter") (assq 'ui got)))
          (should-not (assq 'code got)))))))

(ert-deftest drgnx-look-fonts/doctor-row-names-the-role-and-the-package ()
  "Pattern D: the doctor's `fonts' row warns with the role, the family wanted and the one used, and says how to
install; it is ok when nothing is missing and absent before a graphical display was checked."
  (require 'drgnx-doctor)
  (let ((r (drgnx-doctor-check 'fonts '(:font-fallbacks (:fallbacks ((ui "Missing Sans" "Inter")) :fix "sudo dnf install x")))))
    (should (eq 'warn (car r)))
    (should (string-match-p "ui: Missing Sans is not installed, using Inter" (cadr r)))
    (should (equal "sudo dnf install x" (nth 2 r))))
  (should (eq 'ok (car (drgnx-doctor-check 'fonts '(:font-fallbacks (:fallbacks nil))))))
  (should-not (drgnx-doctor-check 'fonts '(:font-fallbacks nil))))

(provide 'look-fonts-mode-test)
;;; look-fonts-mode-test.el ends here
