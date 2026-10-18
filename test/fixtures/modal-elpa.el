;;; modal-elpa.el --- for the modal tests: evil and its requirements from DRGNX_MODAL_ELPA, read-only -*- lexical-binding: t -*-

;; The tests of drgnx's modal editing run against the real evil.  Its packages come from a package directory the
;; environment names (docs/develop/harness.md, "Modal tests"); without one, the tests that need evil skip.

(require 'ert)
(require 'cl-lib)

(defvar drgnx-modal-test-elpa
  (let ((dir (getenv "DRGNX_MODAL_ELPA")))
    (and dir (not (string-empty-p dir)) (expand-file-name dir)))
  "The package directory the modal tests load evil from (DRGNX_MODAL_ELPA), or nil.")

(defun drgnx-modal-test--package-dir (name)
  "The directory of the package NAME (NAME-VERSION) in `drgnx-modal-test-elpa', or nil."
  (when (and drgnx-modal-test-elpa (file-directory-p drgnx-modal-test-elpa))
    (car (directory-files drgnx-modal-test-elpa t (concat "\\`" (regexp-quote name) "-[0-9]")))))

(defun drgnx-modal-test-evil-dirs ()
  "The package directories of evil, goto-chg, evil-collection and annalist (when this evil-collection needs it)
in `drgnx-modal-test-elpa'; nil when evil, goto-chg or evil-collection is absent."
  (let ((dirs (mapcar #'drgnx-modal-test--package-dir '("evil" "goto-chg" "evil-collection"))))
    (when (cl-every #'identity dirs)
      (delq nil (append dirs (list (drgnx-modal-test--package-dir "annalist")))))))

(defun drgnx-modal-test--listing ()
  "Every file under `drgnx-modal-test-elpa' with its modification time: what a write there would change."
  (mapcar (lambda (f) (cons f (file-attribute-modification-time (file-attributes f))))
          (sort (directory-files-recursively drgnx-modal-test-elpa "" t) #'string<)))

(defmacro drgnx-modal-test-with-evil (&rest body)
  "Run BODY with evil's package directories on `load-path'; skip the test when `drgnx-modal-test-elpa' has none.
Nothing is written there."
  (declare (indent 0))
  `(let ((dirs (drgnx-modal-test-evil-dirs)))
     (unless dirs
       (ert-skip "evil is not available: set DRGNX_MODAL_ELPA to a package directory with evil, goto-chg and evil-collection"))
     (let ((load-path (append dirs load-path)))
       ,@body)))

(provide 'modal-elpa)
;;; modal-elpa.el ends here
