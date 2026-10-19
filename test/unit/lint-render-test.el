;;; lint-render-test.el --- lints: live views mark rows instead of erasing; only the GC owner collects -*- lexical-binding: t -*-
;; Two habits behind the render pipeline (docs/develop/core.md "Views", "Mark, don't erase"):
;;  - a live view is never redrawn by erasing its buffer: `erase-buffer', `tabulated-list-print' without
;;    UPDATE and `delete-region' to `(point-max)' throw away every row, its scroll position and its
;;    selection.  A view marks the rows that changed and draws those.
;;  - one owner collects garbage (core/drgnx-gc.el): a module that calls `garbage-collect' or adds to
;;    `post-gc-hook' fights it.
;; Today's sites are listed in test/lint-render-allowed.eld, counted per (file, defun, call), so the list can
;; only shrink: the task that rewrites a site deletes its entry.
(require 'ert)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)

(defconst drgnx-lint-render--erase-whats '(erase-buffer tabulated-list-print delete-region)
  "The calls the erase lint watches, in `wb/' and `modules/'.")

(defconst drgnx-lint-render--gc-whats '(garbage-collect post-gc-hook)
  "The calls the GC lint watches: `garbage-collect' and an addition to `post-gc-hook'.")

(defconst drgnx-lint-render--kinds '(document listing job-window migrate recovery)
  "The reasons a site may stay.
`document': drawn once on a user action.  `listing': Explorer and Buffers (jit-lock styling; a spec non-goal).
`job-window': retired by C8.  `migrate': a live view, with its task in `:until'.
`recovery': the view core's own reset after a foreign edit (it is the thing that replaces the erase).")

(defconst drgnx-lint-render--gc-skip
  '("core/drgnx-gc.el" "harness/" "test/" ".claude/" ".git/")
  "Where the GC lint does not look: the owner, the harness and the tests (a prefix, or the file).")

(defun drgnx-lint-render--forms (file)
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

(defun drgnx-lint-render--def-name (form)
  "The name FORM defines when it is a definition, else nil."
  (and (proper-list-p form) (symbolp (car form)) (symbolp (cadr form)) (cadr form)
       (string-match-p "\\`\\(cl-\\)?\\(def\\(un\\|macro\\|subst\\|method\\|generic\\)\\|define-.*mode\\)\\'"
                       (symbol-name (car form)))
       (cadr form)))

(defun drgnx-lint-render--hits (form in fn)
  "Call FN with (WHAT DEFUN) for each watched call in FORM, IN being the innermost definition so far."
  (when (consp form)
    (let ((in (or (drgnx-lint-render--def-name form) in))
          (head (car form)))
      (when (and (symbolp head) (proper-list-p form))
        (let ((what (drgnx-lint-render--what form)))
          (when what (funcall fn what in))))
      (let ((x form))
        (while (consp x)
          (drgnx-lint-render--hits (car x) in fn)
          (setq x (cdr x)))))))

(defun drgnx-lint-render--post-gc-hook-p (arg)
  (or (eq arg 'post-gc-hook) (equal arg '(quote post-gc-hook)) (equal arg '(function post-gc-hook))))

(defun drgnx-lint-render--what (form)
  "The watched call FORM is (a symbol from the two whats lists), else nil."
  (pcase (car form)
    ('erase-buffer 'erase-buffer)
    ('tabulated-list-print (and (< (length form) 3) 'tabulated-list-print)) ; no UPDATE: it erases and reprints
    ('delete-region (and (equal (nth 2 form) '(point-max)) 'delete-region))
    ('garbage-collect 'garbage-collect)
    ((or 'add-hook 'setq 'setq-default 'push 'add-to-list 'cl-pushnew 'setf 'set)
     (and (seq-some #'drgnx-lint-render--post-gc-hook-p (cdr form)) 'post-gc-hook))))

(defun drgnx-lint-render--sites (root files whats)
  "The watched calls in FILES (relative to ROOT): a list of (FILE DEFUN WHAT), one per call.
WHATS limits which calls count."
  (let (out)
    (dolist (rel files)
      (dolist (top (drgnx-lint-render--forms (expand-file-name rel root)))
        (drgnx-lint-render--hits top 'top-level
                                 (lambda (what in) (when (memq what whats) (push (list rel in what) out))))))
    (nreverse out)))

(defun drgnx-lint-render--el-files (root dirs)
  "The .el files under the directories DIRS of ROOT, relative to ROOT, sorted."
  (sort (seq-mapcat (lambda (d)
                      (let ((dir (expand-file-name d root)))
                        (and (file-directory-p dir)
                             (mapcar (lambda (f) (file-relative-name f root))
                                     (directory-files-recursively dir "\\.el\\'")))))
                    dirs)
        #'string<))

(defun drgnx-lint-render--gc-files (root)
  "Every .el file under ROOT outside the GC owner, the harness and the tests."
  (seq-remove (lambda (rel) (seq-some (lambda (p) (string-prefix-p p rel)) drgnx-lint-render--gc-skip))
              (drgnx-lint-render--el-files root '("."))))

(defun drgnx-lint-render--allowed (&optional file)
  "The allowlist entries of FILE (default test/lint-render-allowed.eld)."
  (with-temp-buffer
    (insert-file-contents (or file (expand-file-name "test/lint-render-allowed.eld" drgnx-dir)))
    (goto-char (point-min))
    (read (current-buffer))))

(defun drgnx-lint-render--count (sites file in what)
  (seq-count (lambda (s) (and (equal (nth 0 s) file) (eq (nth 1 s) in) (eq (nth 2 s) what))) sites))

(defun drgnx-lint-render--allowed-n (entries file in what)
  (apply #'+ (mapcar (lambda (e) (or (plist-get e :n) 1))
                     (seq-filter (lambda (e) (and (equal (plist-get e :file) file) (eq (plist-get e :in) in)
                                                  (eq (plist-get e :what) what)))
                                 entries))))

(defun drgnx-lint-render--over (sites entries)
  "Problems: a (file, defun, call) with more sites than ENTRIES allow."
  (let (bad seen)
    (dolist (s sites)
      (unless (member s seen)
        (push s seen)
        (let ((found (drgnx-lint-render--count sites (nth 0 s) (nth 1 s) (nth 2 s)))
              (allowed (drgnx-lint-render--allowed-n entries (nth 0 s) (nth 1 s) (nth 2 s))))
          (when (> found allowed)
            (push (format "%s, in %s: %d x %s, %d allowed — mark the rows that changed instead (docs/develop/core.md \"Mark, don't erase\"; GC: only core/drgnx-gc.el collects)"
                          (nth 0 s) (nth 1 s) found (nth 2 s) allowed)
                  bad)))))
    (nreverse bad)))

(defun drgnx-lint-render--stale (sites entries whats)
  "Problems: an entry (with a :what in WHATS) that matches fewer sites than its count."
  (let (bad)
    (dolist (e entries)
      (when (memq (plist-get e :what) whats)
        (let ((file (plist-get e :file)) (in (plist-get e :in)) (what (plist-get e :what)))
          (when (< (drgnx-lint-render--count sites file in what)
                   (drgnx-lint-render--allowed-n entries file in what))
            (push (format "%s, in %s: allowlist entry for %s matches %d site(s), %d listed — delete it or lower :n"
                          file in what (drgnx-lint-render--count sites file in what)
                          (drgnx-lint-render--allowed-n entries file in what))
                  bad)))))
    (delete-dups (nreverse bad))))

(defun drgnx-lint-render--erase-sites (root)
  (drgnx-lint-render--sites root (drgnx-lint-render--el-files root '("wb" "modules")) drgnx-lint-render--erase-whats))

(defun drgnx-lint-render--gc-sites (root)
  (drgnx-lint-render--sites root (drgnx-lint-render--gc-files root) drgnx-lint-render--gc-whats))

(defun drgnx-lint-render--entries-for (entries whats)
  (seq-filter (lambda (e) (memq (plist-get e :what) whats)) entries))

(ert-deftest drgnx-lint/views-never-erase ()
  (should (equal (drgnx-lint-render--over
                  (drgnx-lint-render--erase-sites drgnx-dir)
                  (drgnx-lint-render--entries-for (drgnx-lint-render--allowed) drgnx-lint-render--erase-whats))
                 nil)))

(ert-deftest drgnx-lint/garbage-collect-only-in-the-gc-owner ()
  (should (equal (drgnx-lint-render--over
                  (drgnx-lint-render--gc-sites drgnx-dir)
                  (drgnx-lint-render--entries-for (drgnx-lint-render--allowed) drgnx-lint-render--gc-whats))
                 nil)))

(ert-deftest drgnx-lint/no-stale-render-allowlist-entries ()
  (let ((entries (drgnx-lint-render--allowed)))
    (should (equal (append (drgnx-lint-render--stale (drgnx-lint-render--erase-sites drgnx-dir) entries
                                                     drgnx-lint-render--erase-whats)
                           (drgnx-lint-render--stale (drgnx-lint-render--gc-sites drgnx-dir) entries
                                                     drgnx-lint-render--gc-whats))
                   nil))))

(ert-deftest drgnx-lint/the-render-allowlist-is-well-formed ()
  (let (bad)
    (dolist (e (drgnx-lint-render--allowed))
      (let ((kind (plist-get e :kind)) (n (plist-get e :n)))
        (unless (and (stringp (plist-get e :file)) (symbolp (plist-get e :in)) (plist-get e :in)
                     (memq (plist-get e :what) (append drgnx-lint-render--erase-whats drgnx-lint-render--gc-whats))
                     (memq kind drgnx-lint-render--kinds)
                     (stringp (plist-get e :why)) (not (string-empty-p (plist-get e :why)))
                     (or (null n) (and (integerp n) (> n 1)))
                     (if (eq kind 'migrate) (stringp (plist-get e :until)) (null (plist-get e :until)))
                     (file-exists-p (expand-file-name (plist-get e :file) drgnx-dir)))
          (push (format "%S" e) bad))))
    (should (equal (nreverse bad) nil))))

(defmacro drgnx-lint-render--with-scratch (files &rest body)
  "BODY with ROOT bound to a temp checkout holding FILES, a list of (RELATIVE-NAME . TEXT)."
  (declare (indent 1))
  `(let ((root (make-temp-file "drgnx-lint-render" t)))
     (unwind-protect
         (progn
           (dolist (f ,files)
             (let ((path (expand-file-name (car f) root)))
               (make-directory (file-name-directory path) t)
               (with-temp-file path (insert (cdr f)))))
           ,@body)
       (delete-directory root t))))

(ert-deftest drgnx-lint/the-render-lints-bite ()
  ;; A scratch file in modules/ is reported with its defun, and an allowlist entry silences exactly its count.
  (drgnx-lint-render--with-scratch
      '(("modules/x/drgnx-scratch.el" . "(defun scratch-draw ()\n  (erase-buffer)\n  (tabulated-list-print t)\n  (tabulated-list-print t t)\n  (delete-region (point-min) (point-max))\n  (delete-region (point-min) 10)\n  (insert \"x\"))\n(defun other () (garbage-collect) (add-hook 'post-gc-hook #'ignore) (remove-hook 'post-gc-hook #'ignore))\n")
        ("harness/h.el" . "(defun h () (garbage-collect))\n")
        ("core/drgnx-gc.el" . "(defun gc () (garbage-collect))\n")
        ("core/other.el" . "(defun other-core () (setq post-gc-hook nil))\n")
        ("wb/drgnx-ok.el" . "(defun ok () (tabulated-list-print t t) (delete-region 1 (point-max)))\n"))
    (let* ((erase (drgnx-lint-render--erase-sites root))
           (gc (drgnx-lint-render--gc-sites root))
           (entry (lambda (file in what) (list :file file :in in :what what :kind 'document :why "x"))))
      (should (equal erase '(("modules/x/drgnx-scratch.el" scratch-draw erase-buffer)
                             ("modules/x/drgnx-scratch.el" scratch-draw tabulated-list-print)
                             ("modules/x/drgnx-scratch.el" scratch-draw delete-region)
                             ("wb/drgnx-ok.el" ok delete-region))))
      (should (equal gc '(("core/other.el" other-core post-gc-hook)
                          ("modules/x/drgnx-scratch.el" other garbage-collect)
                          ("modules/x/drgnx-scratch.el" other post-gc-hook))))
      ;; Reported with the defun.
      (let ((msgs (drgnx-lint-render--over erase nil)))
        (should (= (length msgs) 4))
        (should (string-match-p "modules/x/drgnx-scratch.el, in scratch-draw: 1 x erase-buffer" (car msgs))))
      ;; Listed: silent.  One entry removed: that site is red again.
      (let ((all (list (funcall entry "modules/x/drgnx-scratch.el" 'scratch-draw 'erase-buffer)
                       (funcall entry "modules/x/drgnx-scratch.el" 'scratch-draw 'tabulated-list-print)
                       (funcall entry "modules/x/drgnx-scratch.el" 'scratch-draw 'delete-region)
                       (funcall entry "wb/drgnx-ok.el" 'ok 'delete-region))))
        (should (equal (drgnx-lint-render--over erase all) nil))
        (should (equal (drgnx-lint-render--stale erase all drgnx-lint-render--erase-whats) nil))
        (should (= (length (drgnx-lint-render--over erase (cdr all))) 1))
        ;; Counted: a second erase in the same defun is a new site.
        (should (= (length (drgnx-lint-render--over (append erase (list (car erase))) all)) 1))
        ;; A bogus entry, a gone defun, and a count above the sites are stale.
        (should (= (length (drgnx-lint-render--stale
                            erase (cons (funcall entry "modules/x/nowhere.el" 'f 'erase-buffer) all)
                            drgnx-lint-render--erase-whats))
                   1))
        (should (= (length (drgnx-lint-render--stale
                            erase (cons (funcall entry "modules/x/drgnx-scratch.el" 'gone 'erase-buffer) all)
                            drgnx-lint-render--erase-whats))
                   1))
        (should (= (length (drgnx-lint-render--stale
                            erase (cons (append (funcall entry "modules/x/drgnx-scratch.el" 'scratch-draw 'erase-buffer) '(:n 2)) (cdr all))
                            drgnx-lint-render--erase-whats))
                   1)))
      ;; The GC lint skips its owner and the harness, and sees any other file.
      (should (equal (drgnx-lint-render--over gc nil)
                     (list (format "core/other.el, in other-core: 1 x post-gc-hook, 0 allowed — %s"
                                   "mark the rows that changed instead (docs/develop/core.md \"Mark, don't erase\"; GC: only core/drgnx-gc.el collects)")
                           (format "modules/x/drgnx-scratch.el, in other: 1 x garbage-collect, 0 allowed — %s"
                                   "mark the rows that changed instead (docs/develop/core.md \"Mark, don't erase\"; GC: only core/drgnx-gc.el collects)")
                           (format "modules/x/drgnx-scratch.el, in other: 1 x post-gc-hook, 0 allowed — %s"
                                   "mark the rows that changed instead (docs/develop/core.md \"Mark, don't erase\"; GC: only core/drgnx-gc.el collects)")))))))

(provide 'lint-render-test)
;;; lint-render-test.el ends here
