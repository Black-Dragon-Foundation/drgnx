;;; config-fixture.el --- for config tests: drgnx's folders under a fresh temp root per test -*- lexical-binding: t -*-
;; Load with (load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t).
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-config)

(defvar drgnx-test-config-root nil
  "The temp root of the running `drgnx-test-with-config' (a folder name ending in a slash).")

(defvar drgnx-test-config--kept nil
  "The names a library defined while it loaded inside the running `drgnx-test-with-config'.")

(defun drgnx-test-config--note-library-define (orig name &rest args)
  "Around advice of `drgnx-config-define': note NAME when it is defined from a library's top level (a `load')."
  (prog1 (apply orig name args)
    (when load-in-progress (cl-pushnew name drgnx-test-config--kept))))

(defun drgnx-test-config--set-back (saved)
  "Set back the definitions, state and notified table of SAVED (see `drgnx-test-with-config'); the definitions
that libraries loaded inside the fixture made stay, since the library stays loaded and defines them once."
  (let ((defs (nth 0 saved)))
    (dolist (name drgnx-test-config--kept)
      (when-let* ((def (gethash name drgnx-config--defs))) (puthash name def defs)))
    (set 'drgnx-config--defs defs)))

(defmacro drgnx-test-with-config (&rest body)
  "BODY with drgnx's config folder in ROOT/config and its state folder in ROOT/state, ROOT a fresh temp folder
\(`drgnx-test-config-root').  The definitions, the applied state, the problems said and
`drgnx-config-changed-functions' are snapshotted by value and set back afterwards; ROOT is deleted.  A definition a
library made at its top level while it loaded inside BODY is kept: the library stays loaded and defines it once."
  (declare (indent 0) (debug t))
  (let ((saved (make-symbol "saved")) (advised (make-symbol "advised")))
    `(let* ((drgnx-test-config-root (file-name-as-directory (make-temp-file "drgnx-config-test" t)))
            (drgnx-test-config--kept nil)
            (,advised (unless (advice-member-p #'drgnx-test-config--note-library-define 'drgnx-config-define)
                        (advice-add 'drgnx-config-define :around #'drgnx-test-config--note-library-define)
                        t))
            (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" drgnx-test-config-root "config")
                                               (concat "XDG_STATE_HOME=" drgnx-test-config-root "state"))
                                         process-environment))
            (,saved (list (copy-hash-table drgnx-config--defs) (copy-hash-table drgnx-config--state)
                          (copy-hash-table drgnx-config--notified) (copy-sequence drgnx-config-changed-functions))))
       (unwind-protect (progn ,@body)
         (when ,advised (advice-remove 'drgnx-config-define #'drgnx-test-config--note-library-define))
         (drgnx-test-config--set-back ,saved)
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
