;;; config-fixture.el --- for config tests: drgnx's folders under a fresh temp root per test -*- lexical-binding: t -*-
;; Load with (load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t).
(require 'ert)
(require 'drgnx-config)

(defvar drgnx-test-config-root nil
  "The temp root of the running `drgnx-test-with-config' (a folder name ending in a slash).")

(defmacro drgnx-test-with-config (&rest body)
  "BODY with drgnx's config folder in ROOT/config and its state folder in ROOT/state, ROOT a fresh temp folder
\(`drgnx-test-config-root').  The definitions, the applied state, the problems said and
`drgnx-config-changed-functions' are snapshotted by value and set back afterwards; ROOT is deleted."
  (declare (indent 0) (debug t))
  (let ((saved (make-symbol "saved")))
    `(let* ((drgnx-test-config-root (file-name-as-directory (make-temp-file "drgnx-config-test" t)))
            (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" drgnx-test-config-root "config")
                                               (concat "XDG_STATE_HOME=" drgnx-test-config-root "state"))
                                         process-environment))
            (,saved (list (copy-hash-table drgnx-config--defs) (copy-hash-table drgnx-config--state)
                          (copy-hash-table drgnx-config--notified) (copy-sequence drgnx-config-changed-functions))))
       (unwind-protect (progn ,@body)
         (set 'drgnx-config--defs (nth 0 ,saved))
         (set 'drgnx-config--state (nth 1 ,saved))
         (set 'drgnx-config--notified (nth 2 ,saved))
         (set 'drgnx-config-changed-functions (nth 3 ,saved))
         (delete-directory drgnx-test-config-root t)))))

(defun drgnx-test-config-put (name text &optional root)
  "Make config file NAME (ROOT for a project file) hold TEXT, as an editor would: a new file renamed over it, so its
stamp always changes."
  (let* ((file (drgnx-config-file name root))
         (tmp (concat file ".test-new")))
    (make-directory (file-name-directory file) t)
    (let ((coding-system-for-write 'utf-8-unix)) (write-region text nil tmp nil 'silent))
    (rename-file tmp file t)
    file))

(defun drgnx-test-config-text (name &optional root)
  "Config file NAME's text (ROOT for a project file), or nil when it is missing."
  (let ((file (drgnx-config-file name root)))
    (when (file-exists-p file)
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
        (buffer-string)))))

(provide 'config-fixture)
;;; config-fixture.el ends here
