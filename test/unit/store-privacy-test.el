;;; store-privacy-test.el --- batch tests: the personal-file opt-in and deny commands -*- lexical-binding: t -*-
;; Every test makes its own HOME and config dir under a temp dir (`process-environment'), with fixture files under its
;; org/; nothing reads or writes the real ~.  The hub is a stub of `drgnx-hub-call-sync' that records its calls, and
;; `yes-or-no-p' a stub that records its prompts and says yes.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-hub-client)
(require 'drgnx-store-privacy)

(defvar drgnx-store-privacy-test--calls nil "The hub calls, newest first: (METHOD PARAMS).")
(defvar drgnx-store-privacy-test--prompts nil "The confirmations asked, newest first.")

(defmacro drgnx-store-privacy-test--with (&rest body)
  "BODY with a temp HOME (its org/ holding fixtures) and config dir, the hub and the confirmation stubbed.
In BODY, `org' is the resolved org folder and `config' the config dir."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "drgnx-store-privacy" t))))
          (home (expand-file-name "home" root))
          (org (expand-file-name "org" home))
          (config (expand-file-name "config" root))
          (process-environment (append (list (concat "HOME=" home) (concat "DRGNX_CONFIG_DIR=" config))
                                       process-environment))
          (drgnx-store-privacy-test--calls nil)
          (drgnx-store-privacy-test--prompts nil))
     (ignore config)
     (unwind-protect
         (progn
           (should (equal (expand-file-name "~") home))          ; never the real home
           (make-directory (expand-file-name "sub" org) t)
           (make-directory (expand-file-name "personal" org) t)
           (dolist (f '("reading.org" "notes.org" "board.org" "Journal-2026.org" "personal/x.md" "sub/x.org"))
             (with-temp-file (expand-file-name f org) (insert "* fixture\n")))
           (with-temp-file (expand-file-name "outside.txt" root) (insert "outside\n"))
           (cl-letf (((symbol-function 'drgnx-hub-call-sync)
                      (lambda (method params &optional _timeout)
                        (push (list method params) drgnx-store-privacy-test--calls)
                        (list :added nil :removed nil :ignored nil :excised 0 :backups_holding nil)))
                     ((symbol-function 'yes-or-no-p)
                      (lambda (prompt) (push prompt drgnx-store-privacy-test--prompts) t)))
             ,@body))
       (delete-directory root t))))

(defun drgnx-store-privacy-test--json (name)
  "Config file NAME parsed, or nil when it is missing."
  (let ((file (expand-file-name name (drgnx-user-dir))))
    (and (file-exists-p file)
         (json-parse-string (with-temp-buffer (insert-file-contents file) (buffer-string))
                            :object-type 'alist :array-type 'list))))

(ert-deftest drgnx-store-privacy/allow-writes-the-file-0600-atomically ()
  (drgnx-store-privacy-test--with
    (let ((file (expand-file-name drgnx-store-privacy-allow-file config)))
      ;; a file the user made 0644 by hand: kept entries, mode tightened
      (make-directory config t)
      (with-temp-file file (insert "{\"version\": 1, \"paths\": []}\n"))
      (set-file-modes file #o644)
      (drgnx-store-allow-personal-file (expand-file-name "reading.org" org))
      (should (equal (drgnx-store-privacy-test--json drgnx-store-privacy-allow-file)
                     `((version . 1) (paths ,(expand-file-name "reading.org" org)))))
      (should (= (file-modes file) #o600))
      ;; written through a temp file renamed over it: no temp file is left beside it
      (should (equal (directory-files config nil "\\`[^.]\\|\\`\\.[^.]") (list drgnx-store-privacy-allow-file)))
      ;; it asked first, naming the file
      (should (string-match-p "reading\\.org" (car drgnx-store-privacy-test--prompts)))
      ;; once is enough
      (should-error (drgnx-store-allow-personal-file (expand-file-name "reading.org" org)) :type 'user-error))))

(ert-deftest drgnx-store-privacy/allow-refuses-a-hard-tier-file ()
  (drgnx-store-privacy-test--with
    (dolist (f '("notes.org" "Journal-2026.org" "personal/x.md"))
      (let ((err (should-error (drgnx-store-allow-personal-file (expand-file-name f org)) :type 'user-error)))
        (should (string-match-p "always kept out (personal notes); an opt-in cannot open it" (cadr err)))))
    ;; one of the user's own entries is as hard
    (make-directory config t)
    (with-temp-file (expand-file-name drgnx-store-privacy-deny-file config)
      (insert (format "{\"version\": 1, \"entries\": [{\"kind\": \"folder\", \"path\": %S}]}"
                      (expand-file-name "sub" org))))
    (should-error (drgnx-store-allow-personal-file (expand-file-name "sub/x.org" org)) :type 'user-error)
    (should-not drgnx-store-privacy-test--prompts)
    (should-not drgnx-store-privacy-test--calls)
    (should-not (drgnx-store-privacy-test--json drgnx-store-privacy-allow-file))))

(ert-deftest drgnx-store-privacy/allow-refuses-a-directory-and-outside-org ()
  (drgnx-store-privacy-test--with
    (dolist (f (list (expand-file-name "sub/" org) (expand-file-name "outside.txt" (file-name-directory home))
                     (expand-file-name "board.org" org) (expand-file-name "missing.org" org)))
      (should-error (drgnx-store-allow-personal-file f) :type 'user-error))
    ;; a link into ~/org from elsewhere is judged by where it leads
    (let ((link (expand-file-name "link.org" (file-name-directory home))))
      (make-symbolic-link (expand-file-name "notes.org" org) link)
      (should-error (drgnx-store-allow-personal-file link) :type 'user-error))
    ;; a file with a mistake is never overwritten
    (make-directory config t)
    (with-temp-file (expand-file-name drgnx-store-privacy-allow-file config) (insert "{oops"))
    (should-error (drgnx-store-allow-personal-file (expand-file-name "reading.org" org)) :type 'user-error)
    (should (equal (with-temp-buffer (insert-file-contents (expand-file-name drgnx-store-privacy-allow-file config))
                                     (buffer-string))
                   "{oops"))
    (should-not drgnx-store-privacy-test--prompts)
    (should-not drgnx-store-privacy-test--calls)))

(ert-deftest drgnx-store-privacy/revoke-removes-the-entry ()
  (drgnx-store-privacy-test--with
    (let ((reading (expand-file-name "reading.org" org)) (x (expand-file-name "sub/x.org" org)))
      (drgnx-store-allow-personal-file reading)
      (drgnx-store-allow-personal-file x)
      (setq drgnx-store-privacy-test--prompts nil)
      (drgnx-store-revoke-personal-file (abbreviate-file-name reading))
      (should (equal (alist-get 'paths (drgnx-store-privacy-test--json drgnx-store-privacy-allow-file)) (list x)))
      (should (string-match-p "excised" (car drgnx-store-privacy-test--prompts)))
      (should-error (drgnx-store-revoke-personal-file reading) :type 'user-error))))

(ert-deftest drgnx-store-privacy/both-call-reload ()
  (drgnx-store-privacy-test--with
    (let ((reading (expand-file-name "reading.org" org)))
      (drgnx-store-allow-personal-file reading)
      (should (equal drgnx-store-privacy-test--calls '(("graph/privacy" (:reload t)))))
      (drgnx-store-revoke-personal-file reading)
      (should (equal drgnx-store-privacy-test--calls '(("graph/privacy" (:reload t)) ("graph/privacy" (:reload t)))))
      ;; a hub that does not answer: the file is written all the same (the hub applies it at its next tick)
      (cl-letf (((symbol-function 'drgnx-hub-call-sync) (lambda (&rest _) (error "The drgnx hub did not answer"))))
        (drgnx-store-allow-personal-file reading))
      (should (equal (alist-get 'paths (drgnx-store-privacy-test--json drgnx-store-privacy-allow-file))
                     (list reading))))))

(ert-deftest drgnx-store-privacy/revoke-deletes-held-backups-only-when-confirmed ()
  (drgnx-store-privacy-test--with
    (let ((reading (expand-file-name "reading.org" org))
          (held '("/data/backup/work-pre7-1.db" "/data/work.db.schema5")))
      (drgnx-store-allow-personal-file reading)
      ;; the hub's answer to the revoke lists two backups and an export
      (cl-letf (((symbol-function 'drgnx-hub-call-sync)
                 (lambda (method params &optional _timeout)
                   (push (list method params) drgnx-store-privacy-test--calls)
                   (if (plist-get params :delete_copies)
                       (list :excised 0 :backups_removed (list (car held)))
                     (list :excised 1 :backups_holding held :exports_holding '("/data/export/e.jsonl"))))))
        ;; no: nothing more is asked of the hub
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (prompt) (push prompt drgnx-store-privacy-test--prompts)
                     (not (string-prefix-p "Delete these" prompt)))))
          (setq drgnx-store-privacy-test--calls nil)
          (drgnx-store-revoke-personal-file reading)
          (should (string-match-p "\\`Delete these 2 copies\\? They still hold the revoked file's text"
                                  (car drgnx-store-privacy-test--prompts)))
          (should (equal drgnx-store-privacy-test--calls '(("graph/privacy" (:reload t))))))
        ;; yes: the hub is asked to delete exactly the backups it listed (never the export)
        (drgnx-store-allow-personal-file reading)
        (setq drgnx-store-privacy-test--calls nil)
        (drgnx-store-revoke-personal-file reading)
        (should (equal (car drgnx-store-privacy-test--calls)
                       `("graph/privacy" (:reload t :delete_copies ,(vconcat held)))))
        (should (= (length drgnx-store-privacy-test--calls) 2))))))

(ert-deftest drgnx-store-privacy/deny-adds-an-entry-and-undeny-keeps-the-built-ins ()
  (drgnx-store-privacy-test--with
    (drgnx-store-deny-personal-path (expand-file-name "sub" org))
    (drgnx-store-deny-personal-path "~/docs/*.private")
    (let ((entries (alist-get 'entries (drgnx-store-privacy-test--json drgnx-store-privacy-deny-file))))
      (should (equal (mapcar (lambda (e) (alist-get 'kind e)) entries) '("folder" "glob")))
      (should (equal (alist-get 'path (car entries)) (expand-file-name "sub" org)))
      (should (string-suffix-p "/docs/*.private" (alist-get 'path (cadr entries)))))
    (should (= (file-modes (expand-file-name drgnx-store-privacy-deny-file config)) #o600))
    (should (= (length drgnx-store-privacy-test--calls) 2))
    ;; an opt-in on a path the user keeps out is refused
    (should-error (drgnx-store-allow-personal-file (expand-file-name "sub/x.org" org)) :type 'user-error)
    ;; the built-ins cannot be taken off; the user's own entries can
    (let ((err (should-error (drgnx-store-undeny-personal-path (expand-file-name "notes.org" org)) :type 'user-error)))
      (should (string-match-p "built-in list cannot be shortened" (cadr err))))
    (should-error (drgnx-store-deny-personal-path "~/a*/b") :type 'user-error)
    (drgnx-store-undeny-personal-path (expand-file-name "sub" org))
    (should (equal (mapcar (lambda (e) (alist-get 'kind e))
                           (alist-get 'entries (drgnx-store-privacy-test--json drgnx-store-privacy-deny-file)))
                   '("glob")))
    (should (= (length drgnx-store-privacy-test--calls) 3))
    (drgnx-store-allow-personal-file (expand-file-name "sub/x.org" org))))

;;; store-privacy-test.el ends here
