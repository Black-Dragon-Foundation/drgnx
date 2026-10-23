;;; areas-fixture.el --- for the tests of the folded-in areas: settings.el under a temp config, set back afterwards -*- lexical-binding: t -*-
;; Load with (load (expand-file-name "test/fixtures/areas-fixture" drgnx-dir) nil t).  Keys, modules, the colour theme,
;; large files and the session are settings now; their writers push values into theme `drgnx', so a test sets them back.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-settings-area)
(require 'drgnx-settings-migrate)
(require 'drgnx-keys)
(require 'drgnx-modules)
(require 'drgnx-session)

(defconst drgnx-test-areas-vars
  '(drgnx-keys-layers drgnx-keys-pending-layers drgnx-keys-bind drgnx-keys-unbind drgnx-keys-mac-option
                      drgnx-keys-tty-fallback drgnx-modules-disabled drgnx-modules-enabled drgnx-modules-flags drgnx-modules-external
                      drgnx-look-theme drgnx-large-files-ask-above drgnx-large-files-chunks-above drgnx-large-files-chunk-size
                      drgnx-session-keep-running)
  "The settings of the folded-in areas; a test may touch any of them.")

(defun drgnx-test-areas-reset ()
  "Take drgnx's values of the area settings away and put each at its standard value; forget what settings.el gave."
  (dolist (var drgnx-test-areas-vars)
    (drgnx-settings-teardown var)
    (when (get var 'standard-value)
      (set-default var (eval (car (get var 'standard-value)) t))))
  (setq drgnx-settings-area--cache nil))

(defmacro drgnx-test-with-areas (&rest body)
  "BODY under a temp config and state folder (`drgnx-test-with-config') with settings.el not applied in this process
\(as in a batch command) and the area settings at their standard values; both are set back afterwards."
  (declare (indent 0) (debug t))
  `(drgnx-test-with-config
     (let ((drgnx-settings-apply--entries nil) (drgnx-settings-apply-problems nil)
           (drgnx-settings-apply-durations nil) (drgnx-settings-package-settings-off nil))
       (drgnx-test-areas-reset)
       (unwind-protect (progn ,@body)
         (drgnx-test-areas-reset)))))

(defun drgnx-test-areas-put (text)
  "settings.el holds TEXT, as an editor would write it (a new file renamed over it)."
  (drgnx-test-config-put 'settings text))

(defun drgnx-test-areas-put-entries (entries)
  "settings.el holds ENTRIES, an alist (VAR . VALUE), in a plain file."
  (drgnx-test-areas-put (concat "(drgnx-settings\n :version 1"
                                (mapconcat (lambda (e) (format "\n (%S %S)" (car e) (cdr e))) entries "")
                                ")\n")))

(defun drgnx-test-areas-put-old (name text)
  "settings.el holds, for the old config file NAME (keys, modules, session or large-files) written as TEXT would have
been (a plist), the entries its keys map to (`drgnx-settings-migrate-table'); the other entries stay.  Each is written
as it is, valid or not."
  (let ((data (car (read-from-string text))) (file (drgnx-config-file 'settings)))
    (pcase-dolist (`(,key . ,var) (drgnx-settings-migrate--rows name))
      (if (and (proper-list-p data) (plist-member data key))
          (drgnx-settings-file-put file 'drgnx-settings nil var (plist-get data key))
        (drgnx-settings-file-remove file 'drgnx-settings nil var)))))

(defun drgnx-test-areas-old-plist (name)
  "What the entries of settings.el give for the old config file NAME, as the plist it held (only keys that have an
entry), or nil when none has."
  (drgnx-settings-migrate--assemble name (ignore-errors (drgnx-settings-area--file-values))))

(defun drgnx-test-areas-file-value (file var)
  "VAR's value in the settings file FILE (a copy of a config folder's, say), or nil."
  (let* ((doc (drgnx-settings-file-read file 'drgnx-settings))
         (e (and (not (drgnx-settings-doc-failed doc)) (drgnx-settings-area--entry doc var))))
    (and e (drgnx-settings-entry-value e))))

(defun drgnx-test-areas-text ()
  "settings.el's text, or nil when it is missing."
  (drgnx-test-config-text 'settings))

(provide 'areas-fixture)
;;; areas-fixture.el ends here
