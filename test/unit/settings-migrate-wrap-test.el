;;; settings-migrate-wrap-test.el --- batch tests: the old wrap setting folds into the new one, once -*- lexical-binding: t -*-
;; test-class: det
;; The wrap addendum's §3.7 (`drgnx-settings-migrate-wrap').  Every test runs under `drgnx-test-with-config' (config and
;; state folders under a temp root, so nothing reaches ~), with `custom-file' in that config folder and `drgnx-notify'
;; recorded.  A user-set value is kept and mapped, drgnx's own value in custom.el is dropped, anything else is reported
;; with its file and line and left as it is; custom.el, the user's Lisp and the project's shared file are never written.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-notice)
(require 'drgnx-settings-migrate)

(defvar drgnx-smw--notices nil "The `drgnx-notify' calls of the running test, newest first.")
(defvar drgnx-user-lisp-files)
(defvar drgnx-settings-workspace--private-list)

(defmacro drgnx-smw--with (&rest body)
  "BODY under `drgnx-test-with-config', `custom-file' in the temp config folder, `inhibit-interaction' t and every
`drgnx-notify' recorded in `drgnx-smw--notices'."
  (declare (indent 0) (debug t))
  `(drgnx-test-with-config
     (let ((custom-file (expand-file-name "custom.el" (drgnx-user-dir)))
           (drgnx-user-lisp-files nil)
           (inhibit-interaction t)
           (drgnx-settings-workspace--private-list nil)
           (drgnx-smw--notices nil))
       (cl-letf (((symbol-function 'drgnx-notify) (lambda (&rest args) (push args drgnx-smw--notices) nil)))
         ,@body))))

(defun drgnx-smw--write (file text)
  "Write TEXT to FILE (UTF-8), making its folder; FILE."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'utf-8-unix)) (write-region text nil file nil 'silent))
  file)

(defun drgnx-smw--text (file)
  "FILE's text, or nil when it is missing."
  (when (file-exists-p file)
    (with-temp-buffer (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file)) (buffer-string))))

(defun drgnx-smw--settings (&rest entries)
  "Write settings.el holding ENTRIES (texts); its path."
  (drgnx-smw--write (drgnx-config-file 'settings)
                    (format "(drgnx-settings\n :version 1\n %s)\n" (string-join entries "\n "))))

(defun drgnx-smw--value (var &optional scope file head)
  "VAR's value in SCOPE of settings FILE (default settings.el) of HEAD, or `none' when it has no entry."
  (let ((e (cl-find-if (lambda (e) (and (eq (drgnx-settings-entry-var e) var) (equal (drgnx-settings-entry-scope e) scope)))
                       (drgnx-settings-doc-entries (drgnx-settings-file-read (or file (drgnx-config-file 'settings))
                                                                             (or head 'drgnx-settings))))))
    (if e (drgnx-settings-entry-value e) 'none)))

(defun drgnx-smw--reported (report file)
  "REPORT's reported items about FILE, as (LINE . TEXT)."
  (cl-loop for i in (plist-get report :reported) when (equal (plist-get i :file) file)
           collect (cons (plist-get i :line) (plist-get i :text))))

(ert-deftest drgnx-settings-migrate-wrap/a-user-set-word-in-settings-survives ()
  (drgnx-smw--with
    (drgnx-smw--settings "(drgnx-face-line-wrap word)")
    (let ((report (drgnx-settings-migrate-wrap)))
      (should (eq (drgnx-smw--value 'drgnx-editing-word-wrap) 'on))
      (should (eq (drgnx-smw--value 'drgnx-face-line-wrap) 'none))
      (should-not (plist-get report :reported))
      (should-not drgnx-smw--notices))))

(ert-deftest drgnx-settings-migrate-wrap/an-untouched-default-becomes-auto ()
  (drgnx-smw--with
    ;; nothing in settings.el; custom.el holds what the old applier wrote (`word', the editing setting unset)
    (let* ((custom (drgnx-smw--write custom-file "(custom-set-variables\n '(drgnx-face-line-wrap 'word))\n"))
           (before (drgnx-smw--text custom))
           (report (drgnx-settings-migrate-wrap)))
      (should (eq (drgnx-smw--value 'drgnx-editing-word-wrap) 'none))
      (should (equal (drgnx-smw--text custom) before))
      (should (cl-find-if (lambda (i) (and (equal (plist-get i :file) custom) (eql (plist-get i :line) 2)
                                           (string-match-p "drgnx's own" (plist-get i :text))))
                          (plist-get report :done)))
      (should-not (plist-get report :reported)))))

(ert-deftest drgnx-settings-migrate-wrap/an-unknown-value-is-reported-and-left ()
  (drgnx-smw--with
    (let* ((settings (drgnx-smw--settings "(drgnx-face-line-wrap nil)" "(:mode text-mode (drgnx-face-line-wrap foo))"))
           (config (drgnx-smw--write (expand-file-name "config.el" (drgnx-user-dir))
                                     ";; mine\n(setq drgnx-face-line-wrap (if (display-graphic-p) 'word 'truncate))\n"))
           (before (list (drgnx-smw--text settings) (drgnx-smw--text config)))
           (report (drgnx-settings-migrate-wrap)))
      (should (equal (list (drgnx-smw--text settings) (drgnx-smw--text config)) before))
      (should (equal (mapcar #'car (drgnx-smw--reported report settings)) '(3 4)))
      (should (equal (mapcar #'car (drgnx-smw--reported report config)) '(2)))
      (should (string-match-p "not guessed" (cdar (drgnx-smw--reported report config))))
      (should (eq (drgnx-smw--value 'drgnx-editing-word-wrap) 'none))
      (should (= (length drgnx-smw--notices) 1)))))

(ert-deftest drgnx-settings-migrate-wrap/custom-truncate-is-the-users-and-custom-el-is-not-written ()
  (drgnx-smw--with
    (let* ((custom (drgnx-smw--write custom-file "(custom-set-variables\n '(drgnx-face-line-wrap 'truncate))\n"))
           (before (drgnx-smw--text custom)))
      (drgnx-settings-migrate-wrap)
      (should (eq (drgnx-smw--value 'drgnx-editing-word-wrap) 'off))
      (should (equal (drgnx-smw--text custom) before)))))

(ert-deftest drgnx-settings-migrate-wrap/a-lisp-setq-goes-to-settings-and-its-line-is-reported ()
  (drgnx-smw--with
    (let* ((config (drgnx-smw--write (expand-file-name "config.el" (drgnx-user-dir))
                                     ";; mine\n\n(setq drgnx-face-line-wrap 'truncate)\n"))
           (before (drgnx-smw--text config))
           (report (drgnx-settings-migrate-wrap)))
      (should (eq (drgnx-smw--value 'drgnx-editing-word-wrap) 'off))
      (should (equal (drgnx-smw--text config) before))
      (let ((r (drgnx-smw--reported report config)))
        (should (equal (mapcar #'car r) '(3)))
        (should (string-match-p (regexp-quote "(setopt drgnx-editing-word-wrap 'off)") (cdar r)))))))

(ert-deftest drgnx-settings-migrate-wrap/mode-and-private-entries-are-rewritten-the-shared-file-is-reported ()
  (drgnx-smw--with
    (let* ((root (file-name-as-directory (expand-file-name "proj" drgnx-test-config-root)))
           (shared (drgnx-smw--write (expand-file-name ".drgnx/settings.el" root)
                                     "(drgnx-workspace-settings\n :version 1\n (drgnx-face-line-wrap truncate))\n"))
           (shared-before (drgnx-smw--text shared))
           (private (drgnx-smw--write (expand-file-name "workspaces/proj.el" (drgnx-user-dir))
                                      (format "(drgnx-workspace-settings\n :version 1\n :roots (%S)\n (drgnx-face-line-wrap word)\n (:mode org-mode (drgnx-face-line-wrap truncate)))\n" root)))
           (_ (drgnx-smw--settings "(:mode org-mode (drgnx-face-line-wrap truncate))"))
           (report (drgnx-settings-migrate-wrap)))
      (should (eq (drgnx-smw--value 'drgnx-editing-word-wrap '((:mode . org-mode))) 'off))
      (should (eq (drgnx-smw--value 'drgnx-face-line-wrap '((:mode . org-mode))) 'none))
      (should (eq (drgnx-smw--value 'drgnx-editing-word-wrap nil private 'drgnx-workspace-settings) 'on))
      (should (eq (drgnx-smw--value 'drgnx-editing-word-wrap '((:mode . org-mode)) private 'drgnx-workspace-settings) 'off))
      (should (eq (drgnx-smw--value 'drgnx-face-line-wrap nil private 'drgnx-workspace-settings) 'none))
      (should (equal (drgnx-smw--text shared) shared-before))
      (should (equal (mapcar #'car (drgnx-smw--reported report shared)) '(3))))))

(ert-deftest drgnx-settings-migrate-wrap/the-editing-entry-wins-a-disagreement-and-it-is-reported ()
  (drgnx-smw--with
    (let* ((settings (drgnx-smw--settings "(drgnx-editing-word-wrap off)" "(drgnx-face-line-wrap word)"))
           (report (drgnx-settings-migrate-wrap)))
      (should (eq (drgnx-smw--value 'drgnx-editing-word-wrap) 'off))
      (should (eq (drgnx-smw--value 'drgnx-face-line-wrap) 'none))
      (should (string-match-p "disagreed" (cdar (drgnx-smw--reported report settings)))))))

(ert-deftest drgnx-settings-migrate-wrap/a-settings-file-with-a-mistake-is-not-written-and-the-step-stays-undone ()
  (drgnx-smw--with
    (let* ((settings (drgnx-smw--write (drgnx-config-file 'settings)
                                       "(drgnx-settings\n :version 1\n (drgnx-face-line-wrap word)\n"))   ; unclosed
           (before (drgnx-smw--text settings))
           (report (drgnx-settings-migrate-wrap)))
      (should (equal (drgnx-smw--text settings) before))
      (should (drgnx-smw--reported report settings))
      (should-not (memq drgnx-settings-migrate-wrap-id (plist-get (drgnx-settings-migrate--steps) :steps)))
      ;; fixed: the next start does it
      (drgnx-smw--settings "(drgnx-face-line-wrap word)")
      (drgnx-settings-migrate-wrap)
      (should (eq (drgnx-smw--value 'drgnx-editing-word-wrap) 'on)))))

(ert-deftest drgnx-settings-migrate-wrap/a-second-start-changes-nothing ()
  (drgnx-smw--with
    (let ((settings (drgnx-smw--settings "(drgnx-face-line-wrap truncate)")))
      (should (drgnx-settings-migrate-wrap))
      (should (memq drgnx-settings-migrate-wrap-id (plist-get (drgnx-settings-migrate--steps) :steps)))
      ;; an old entry that appears after the step is left to Settings (the step is done)
      (drgnx-settings-file-put settings 'drgnx-settings nil 'drgnx-face-line-wrap 'word)
      (let ((again (drgnx-smw--text settings)))
        (should-not (drgnx-settings-migrate-wrap))
        (should (equal (drgnx-smw--text settings) again))))))

(ert-deftest drgnx-settings-migrate-wrap/the-report-shows-the-step ()
  (drgnx-smw--with
    (drgnx-smw--settings "(drgnx-face-line-wrap nil)")
    (drgnx-settings-migrate-wrap)
    (let ((text (drgnx-settings-migrate--report-text (drgnx-settings-migrate-read-report))))
      (should (string-match-p "Word wrap" text))
      (should (string-match-p "Needs you:" text))
      (should-not (string-match-p "Nothing moved" text)))))

;;; settings-migrate-wrap-test.el ends here
