;;; lint-guard-test.el --- lint: drgnx's process callbacks run inside the guard -*- lexical-binding: t -*-
;; A process filter or sentinel is called from C: nothing tells it apart from a command, so a prompt there would
;; wait for an answer nobody gives, and an error there is shown as Emacs's own "error in process filter".  Every
;; callback drgnx hands to a process is `(drgnx-guard-wrap FN LABEL)' (docs/develop/core.md "No prompts in
;; automatic paths").  The lint reads `core/', `wb/' and `modules/' with the Lisp reader (comments never count).
;; Today's sites are listed in test/lint-guard-allowed.eld, one row per site, so the list can only shrink: the task
;; that wraps a site deletes its row; what is left is the hub-protocol runner's (the sites it moves to
;; `drgnx-proc-start', which wraps its own callbacks).
(require 'ert)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)

(defconst drgnx-lint-guard--makers '(make-process make-network-process make-pipe-process make-serial-process)
  "Calls that take a callback as `:filter' or `:sentinel'.")

(defconst drgnx-lint-guard--setters '(set-process-filter set-process-sentinel)
  "Calls that take a callback as their second argument.")

(defconst drgnx-lint-guard--dirs '("core" "wb" "modules") "Where the lint looks.")

(defun drgnx-lint-guard--forms (file)
  "The top-level forms of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (with-syntax-table emacs-lisp-mode-syntax-table
      (let (forms)
        (goto-char (point-min))
        (condition-case nil
            (while (progn (forward-comment (buffer-size)) (not (eobp)))
              (push (read (current-buffer)) forms))
          (end-of-file nil))
        (nreverse forms)))))

(defun drgnx-lint-guard--def-name (form)
  "The name FORM defines when it is a definition, else nil."
  (and (proper-list-p form) (symbolp (car form)) (cadr form) (symbolp (cadr form))
       (string-match-p "\\`\\(cl-\\)?\\(def\\(un\\|macro\\|subst\\|method\\|generic\\)\\|define-.*mode\\)\\'"
                       (symbol-name (car form)))
       (cadr form)))

(defun drgnx-lint-guard--guarded-p (value)
  "Non-nil when VALUE, a callback form, needs no guard: `(drgnx-guard-wrap …)', nil, `ignore' or the default
sentinel."
  (or (null value)
      (and (consp value) (eq (car value) 'drgnx-guard-wrap))
      (member value '((function ignore) (quote ignore)
                      (function internal-default-process-sentinel) (quote internal-default-process-sentinel)))))

(defun drgnx-lint-guard--unguarded-p (form)
  "Non-nil when FORM is a watched call that hands a process a callback outside the guard."
  (let ((head (car form)))
    (cond ((memq head drgnx-lint-guard--makers)
           (seq-some (lambda (key)
                       (let ((tail (memq key (cdr form))))
                         (and tail (not (drgnx-lint-guard--guarded-p (cadr tail))))))
                     '(:filter :sentinel)))
          ((memq head drgnx-lint-guard--setters)
           (not (drgnx-lint-guard--guarded-p (nth 2 form)))))))

(defun drgnx-lint-guard--hits (form near fn)
  "Call FN with (KIND NEAR) for each unguarded site in FORM, NEAR being the innermost definition's name so far."
  (when (consp form)
    (let ((near (or (drgnx-lint-guard--def-name form) near)))
      (when (and (symbolp (car form)) (proper-list-p form) (drgnx-lint-guard--unguarded-p form))
        (funcall fn (car form) near))
      (let ((x form))
        (while (consp x)
          (drgnx-lint-guard--hits (car x) near fn)
          (setq x (cdr x)))))))

(defun drgnx-lint-guard--sites (root)
  "The unguarded sites under ROOT's `drgnx-lint-guard--dirs': a list of (FILE KIND NEAR), one per call, in file
order.  FILE is relative to ROOT, KIND the call's symbol, NEAR the name of the definition holding it (a string,
\"top-level\" outside any)."
  (let (out)
    (dolist (rel (drgnx-lint-guard--files root))
      (dolist (top (drgnx-lint-guard--forms (expand-file-name rel root)))
        (drgnx-lint-guard--hits top 'top-level
                                (lambda (kind near) (push (list rel kind (symbol-name near)) out)))))
    (nreverse out)))

(defun drgnx-lint-guard--files (root)
  "The .el files under ROOT's `drgnx-lint-guard--dirs', relative to ROOT, sorted."
  (sort (seq-mapcat (lambda (d)
                      (let ((dir (expand-file-name d root)))
                        (and (file-directory-p dir)
                             (mapcar (lambda (f) (file-relative-name f root))
                                     (directory-files-recursively dir "\\.el\\'")))))
                    drgnx-lint-guard--dirs)
        #'string<))

(defun drgnx-lint-guard--allowed (&optional file)
  "The rows of FILE (default test/lint-guard-allowed.eld)."
  (with-temp-buffer
    (insert-file-contents (or file (expand-file-name "test/lint-guard-allowed.eld" drgnx-dir)))
    (goto-char (point-min))
    (read (current-buffer))))

(defun drgnx-lint-guard--key (row)
  "ROW's site, in the shape of a site: (FILE KIND NEAR)."
  (list (plist-get row :file) (plist-get row :form) (plist-get row :near)))

(defun drgnx-lint-guard--count (site list)
  (seq-count (lambda (s) (equal s site)) list))

(defun drgnx-lint-guard--over (sites rows)
  "Problems: a site (FILE KIND NEAR) found more often than ROWS list it."
  (let ((keys (mapcar #'drgnx-lint-guard--key rows)) bad seen)
    (dolist (s sites)
      (unless (member s seen)
        (push s seen)
        (let ((found (drgnx-lint-guard--count s sites)) (allowed (drgnx-lint-guard--count s keys)))
          (when (> found allowed)
            (push (format "%s, in %s: %d x %s with a callback outside the guard, %d allowed — wrap it: (drgnx-guard-wrap #'FN \"LABEL\") (docs/develop/core.md \"No prompts in automatic paths\")"
                          (nth 0 s) (nth 2 s) found (nth 1 s) allowed)
                  bad)))))
    (nreverse bad)))

(defun drgnx-lint-guard--well-formed-p (row)
  (let ((until (plist-get row :until)))
    (and (stringp (plist-get row :file))
         (memq (plist-get row :form) (append drgnx-lint-guard--makers drgnx-lint-guard--setters))
         (stringp (plist-get row :near)) (not (string-empty-p (plist-get row :near)))
         (stringp (plist-get row :why)) (not (string-empty-p (plist-get row :why)))
         (equal until "runner"))))

(defun drgnx-lint-guard--stale (sites rows)
  "Problems: a row that is not well formed, or a site listed more often than it is found."
  (let ((keys (mapcar #'drgnx-lint-guard--key rows)) bad)
    (dolist (row rows)
      (if (not (drgnx-lint-guard--well-formed-p row))
          (push (format "%S: not a row (:file F :form KIND :near DEFUN :why WHY :until \"runner\")" row) bad)
        (let* ((k (drgnx-lint-guard--key row))
               (found (drgnx-lint-guard--count k sites)) (listed (drgnx-lint-guard--count k keys)))
          (when (< found listed)
            (push (format "%s, in %s: %d row(s) for %s, %d site(s) — delete the row of the site that is guarded now"
                          (nth 0 k) (nth 2 k) listed (nth 1 k) found)
                  bad)))))
    (delete-dups (nreverse bad))))

(ert-deftest drgnx-lint/process-callbacks-are-guarded ()
  (should (equal (drgnx-lint-guard--over (drgnx-lint-guard--sites drgnx-dir) (drgnx-lint-guard--allowed)) nil)))

(ert-deftest drgnx-lint/no-stale-guard-allowlist-entries ()
  (should (equal (drgnx-lint-guard--stale (drgnx-lint-guard--sites drgnx-dir) (drgnx-lint-guard--allowed)) nil)))

(ert-deftest drgnx-lint/the-guard-lint-sees-each-form ()
  (let ((root (make-temp-file "drgnx-lint-guard" t)))
    (unwind-protect
        (let ((file (expand-file-name "modules/x/drgnx-scratch.el" root)))
          (make-directory (file-name-directory file) t)
          (with-temp-file file
            (insert ";; (make-process :filter #'f) in a comment is not a site\n"
                    "(defun scratch-a ()\n"
                    "  (make-process :name \"a\" :command '(\"true\") :filter #'scratch-filter)\n"
                    "  (make-network-process :name \"b\" :sentinel (lambda (_p _e) nil))\n"
                    "  (make-pipe-process :name \"c\" :filter #'f :sentinel (drgnx-guard-wrap #'s \"c\"))\n"
                    "  (make-serial-process :port \"/dev/x\" :sentinel #'s)\n"
                    "  (set-process-filter p #'scratch-filter)\n"
                    "  (set-process-sentinel p (lambda (_p _e) nil)))\n"
                    "(defun scratch-guarded ()\n"
                    "  (make-process :name \"d\" :filter (drgnx-guard-wrap #'f \"d\") :sentinel #'ignore)\n"
                    "  (make-process :name \"e\" :filter nil :sentinel #'internal-default-process-sentinel)\n"
                    "  (make-process :name \"f\" :command '(\"true\"))\n"
                    "  (set-process-filter p nil) (set-process-sentinel p #'ignore)\n"
                    "  (set-process-sentinel p (drgnx-guard-wrap #'s \"p\"))\n"
                    "  (drgnx-proc-start \"g\" '(\"true\") :deadline 1 :on-done #'done))\n"
                    "(set-process-sentinel q #'top)\n"))
          (make-directory (expand-file-name "harness" root))
          (with-temp-file (expand-file-name "harness/h.el" root) (insert "(set-process-filter p #'f)\n"))
          (let* ((f "modules/x/drgnx-scratch.el")
                 (sites (drgnx-lint-guard--sites root))
                 (row (lambda (kind near) (list :file f :form kind :near near :why "x" :until "runner")))
                 (rows (list (funcall row 'make-process "scratch-a") (funcall row 'make-network-process "scratch-a")
                             (funcall row 'make-pipe-process "scratch-a") (funcall row 'make-serial-process "scratch-a")
                             (funcall row 'set-process-filter "scratch-a") (funcall row 'set-process-sentinel "scratch-a")
                             (funcall row 'set-process-sentinel "top-level"))))
            ;; Each form, each in its definition; guarded values, the runner and the harness are not sites.
            (should (equal sites (mapcar #'drgnx-lint-guard--key rows)))
            (should (string-match-p "modules/x/drgnx-scratch.el, in scratch-a: 1 x make-process"
                                    (car (drgnx-lint-guard--over sites nil))))
            (should (= (length (drgnx-lint-guard--over sites nil)) 7))
            ;; Listed: silent.  One row removed: its site is red again.
            (should (equal (drgnx-lint-guard--over sites rows) nil))
            (should (equal (drgnx-lint-guard--stale sites rows) nil))
            (should (= (length (drgnx-lint-guard--over sites (cdr rows))) 1))
            ;; A bogus row, a second row for one site and a malformed row are stale.
            (should (= (length (drgnx-lint-guard--stale sites (cons (funcall row 'make-process "gone") rows))) 1))
            (should (= (length (drgnx-lint-guard--stale sites (cons (car rows) rows))) 1))
            (should (= (length (drgnx-lint-guard--stale sites (cons (list :file f :form 'make-process :near "scratch-a"
                                                                          :why "x" :until "later")
                                                                    (cdr rows))))
                       1))))
      (delete-directory root t))))

(provide 'lint-guard-test)
;;; lint-guard-test.el ends here
