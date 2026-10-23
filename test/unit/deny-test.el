;;; deny-test.el --- batch tests: the personal-notes deny-list, Lisp side (one table with norn's deny.rs) -*- lexical-binding: t -*-
;; Each case runs in its own temp HOME and config dir; nothing here reaches the real ~ or the user's notes.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-deny)

(defmacro drgnx-deny-test--with-home (home &rest body)
  "BODY with HOME (no trailing slash) a fresh temp HOME, its config directory beside it, and no rules cached."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "drgnx-deny" t))))
          (,home (concat root "home"))
          (process-environment (append (list (concat "HOME=" ,home) (concat "DRGNX_CONFIG_DIR=" root "config")) process-environment))
          (drgnx-deny--cache nil))
     (unwind-protect
         (progn (make-directory ,home t) (make-directory (concat root "config") t) ,@body)
       (delete-directory root t))))

(defun drgnx-deny-test--write (file text &optional mode)
  (make-directory (file-name-directory file) t)
  (write-region text nil file nil 'silent)
  (set-file-modes file (or mode #o600)))

(defun drgnx-deny-test--config (name spec home)
  "Write the config file NAME from SPEC (an alist: json, raw, mode)."
  (let ((text (if (alist-get 'raw spec)
                  (alist-get 'raw spec)
                (json-serialize (alist-get 'json spec)))))
    (drgnx-deny-test--write (expand-file-name name (drgnx-paths-dir 'config)) (string-replace "$HOME" home text)
                            (if (alist-get 'mode spec) (string-to-number (alist-get 'mode spec) 8) #o600))))

(defun drgnx-deny-test--case (c)
  "Run table case C; the number of probes checked."
  (drgnx-deny-test--with-home home
    (dolist (d (append (alist-get 'dirs c) nil)) (make-directory (concat home "/" d) t))
    (dolist (f (append (alist-get 'files c) nil)) (drgnx-deny-test--write (concat home "/" f) "fixture\n"))
    (dolist (l (append (alist-get 'links c) nil))
      (let ((at (concat home "/" (aref l 0))))
        (make-directory (file-name-directory at) t)
        (make-symbolic-link (string-replace "$HOME" home (aref l 1)) at)))
    (when (alist-get 'deny c) (drgnx-deny-test--config drgnx-deny-deny-file (alist-get 'deny c) home))
    (when (alist-get 'allow c) (drgnx-deny-test--config drgnx-deny-allow-file (alist-get 'allow c) home))
    (let* ((path (string-replace "$HOME" home (alist-get 'check c)))
           (verdict (alist-get 'verdict c))
           (want (pcase verdict
                   ("allowed" nil) ("board" 'board) ("opted-in" 'opted-in)
                   ("denied" (intern (alist-get 'tier c)))))
           (got (drgnx-deny-classify path)))
      (should (equal (list (alist-get 'name c) got) (list (alist-get 'name c) want)))
      ;; the public check: denied unless allowed, the board or an opt-in
      (should (eq (and (drgnx-deny-path-p path) t) (and (memq want '(hard soft)) t))))
    1))

(ert-deftest drgnx-deny/the-shared-table ()
  ;; test/fixtures/deny-cases.json is norn::deny's table too; the root and record probes are Rust's (the door's input)
  (let* ((json (with-temp-buffer
                 (insert-file-contents (expand-file-name "test/fixtures/deny-cases.json" drgnx-dir))
                 (json-parse-buffer :object-type 'alist)))
         (os (if (eq system-type 'darwin) "macos" "linux"))
         (ran 0))
    (seq-doseq (c (alist-get 'cases json))
      (when (and (alist-get 'check c) (member (alist-get 'os c) (list nil os)))
        (cl-incf ran (drgnx-deny-test--case c))))
    (should (> ran 35))))

(ert-deftest drgnx-deny/a-hard-tier-opt-in-is-still-denied ()
  (drgnx-deny-test--with-home home
    (drgnx-deny-test--write (concat home "/org/notes.org") "n")
    (drgnx-deny-test--write (concat home "/org/Journal-2026.org") "j")
    (drgnx-deny-test--write (concat home "/org/personal/x.md") "p")
    (drgnx-deny-test--write (expand-file-name drgnx-deny-allow-file (drgnx-paths-dir 'config))
                            (format "{\"version\": 1, \"paths\": [\"%s/org/notes.org\", \"%s/org/Journal-2026.org\", \"%s/org/personal/x.md\"]}"
                                    home home home))
    (dolist (f '("notes.org" "Journal-2026.org" "personal/x.md"))
      (should (eq (drgnx-deny-path-p (concat home "/org/" f)) 'hard)))))

(ert-deftest drgnx-deny/hard-only-ignores-opt-ins ()
  (drgnx-deny-test--with-home home
    (drgnx-deny-test--write (concat home "/org/reading.org") "r")
    (drgnx-deny-test--write (expand-file-name drgnx-deny-allow-file (drgnx-paths-dir 'config))
                            (format "{\"version\": 1, \"paths\": [\"%s/org/reading.org\"]}" home))
    (should-not (drgnx-deny-path-p (concat home "/org/reading.org")))          ; opted in: open
    (should (drgnx-deny-path-p (concat home "/org/reading.org") t))             ; the code indexer: not
    (should (drgnx-deny-path-p (concat home "/org/other.org")))
    (should-not (drgnx-deny-path-p (concat home "/org/board.org") t))))         ; the board is always read

(ert-deftest drgnx-deny/a-bad-opt-in-file-is-ignored ()
  (dolist (spec '(("[\"x\"]" . #o600)                                           ; not {"version": 1, "paths": [...]}
                  ("{not json" . #o600)
                  ("{\"version\": 1, \"paths\": [\"$HOME/org/reading.org\"]}" . #o666)   ; writable by others
                  ("{\"version\": 2, \"paths\": [\"$HOME/org/reading.org\"]}" . #o600)))
    (drgnx-deny-test--with-home home
      (drgnx-deny-test--write (concat home "/org/reading.org") "r")
      (drgnx-deny-test--write (expand-file-name drgnx-deny-allow-file (drgnx-paths-dir 'config))
                              (string-replace "$HOME" home (car spec)) (cdr spec))
      (should (eq (drgnx-deny-path-p (concat home "/org/reading.org")) 'soft)))))

(provide 'deny-test)
;;; deny-test.el ends here
