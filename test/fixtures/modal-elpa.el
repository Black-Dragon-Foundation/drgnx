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

;;; Tests that load evil run in their own Emacs.  Loading evil cannot be undone in a process (its hooks and advice on
;;; `keyboard-quit', `select-window', `read-key-sequence' stay), and `drgnx-evil/' sorts before most of the suite, so
;;; the files under test/unit/isolated/ (no `-test.el' suffix: the main run skips them) run in a fresh batch Emacs,
;;; started by one in-suite test per file.

(defvar drgnx-dir)

(defun drgnx-modal-test-run-isolated (file selector)
  "Run the tests of FILE (relative to the checkout) chosen by SELECTOR in a fresh batch Emacs through the runner.
Memory-capped by systemd-run when it works.  Returns (EXIT-CODE . OUTPUT)."
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (dir (file-name-as-directory (expand-file-name drgnx-dir)))
         (args (list "--batch" "-Q" "--eval" "(setq load-prefer-newer t)"
                     "-L" (concat dir "harness") "-L" (concat dir "core") "-L" (concat dir "wb")
                     "-l" (concat dir "harness/run-ert.el") "-f" "drgnx-run-ert-batch"
                     (expand-file-name file dir)))
         (process-environment (append (list (concat "DRGNX_TEST_SELECTOR=" (prin1-to-string selector)) "DRGNX_TEST_RESULTS")
                                      process-environment))
         (cap (and (executable-find "systemd-run")
                   (zerop (call-process "systemd-run" nil nil nil "--user" "--scope" "-q" "true"))
                   '("systemd-run" "--user" "--scope" "-q" "-p" "MemoryMax=1G" "-p" "MemorySwapMax=0" "--"))))
    (with-temp-buffer
      (let ((code (apply #'call-process (if cap (car cap) emacs) nil t nil
                         (append (cdr cap) (and cap (list emacs)) args))))
        (cons code (buffer-string))))))

(defun drgnx-modal-test-isolated-result (file selector)
  "Run FILE's tests (SELECTOR) in their own Emacs; nil when they passed, else the child's output (the tail of it)."
  (pcase-let ((`(,code . ,out) (drgnx-modal-test-run-isolated file selector)))
    (cond ((not (eql code 0)) (format "exit %S\n%s" code (if (> (length out) 8000)
                                                             (concat (substring out 0 3000) "\n[…]\n" (substring out -5000))
                                                           out)))
          ((string-match-p "Ran 0 tests" out) (format "no test ran\n%s" out))
          (t nil))))

(provide 'modal-elpa)
;;; modal-elpa.el ends here
