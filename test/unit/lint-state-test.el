;;; lint-state-test.el --- lint: modules subscribe to the workbench state instead of hooking windows -*- lexical-binding: t -*-
;; A module that wants to know when windows changed, resized or showed a buffer subscribes to the
;; workbench state store (`drgnx-state-subscribe'); it does not add its own function to a window-change
;; hook, and does not ask `get-buffer-window' whether a buffer shows somewhere (second argument non-nil).
;; Each such site in `modules/' is named in `test/lint-state-allowed.eld' with the task that moves it;
;; the task removes its line, and `drgnx-lint/no-stale-allowlist-entries' fails while a line outlives its site.
(require 'ert)
(require 'seq)
(require 'cl-lib)
(require 'drgnx-paths)

(defconst drgnx-lint-state--hooks
  '(window-buffer-change-functions window-size-change-functions window-state-change-functions
                                   window-configuration-change-hook)
  "The window-change hooks a module does not add to.")

(defun drgnx-lint-state--forms (file)
  (with-temp-buffer
    (insert-file-contents file)
    (let (forms)
      (condition-case nil (while t (push (read (current-buffer)) forms)) (end-of-file nil))
      (nreverse forms))))

(defun drgnx-lint-state--walk (form fn)
  "Call FN on every symbol and every call in FORM; a `remove-hook' call is skipped, it adds nothing."
  (cond ((consp form)
         (unless (memq (car form) '(remove-hook drgnx-module-unhook))
           (funcall fn form)
           (let ((x form))
             (while (consp x) (drgnx-lint-state--walk (car x) fn) (setq x (cdr x)))
             (when x (drgnx-lint-state--walk x fn)))))
        ((symbolp form) (funcall fn form))))

(defun drgnx-lint-state--sites (file)
  "The names in FILE that the lint flags: each window-change hook the code mentions (quoted or not, outside a
`remove-hook'), and `get-buffer-window' when called with a second argument other than a literal nil.  Comments
and strings are not code and never count.  Each name is listed once."
  (let (out)
    (dolist (top (drgnx-lint-state--forms file))
      (drgnx-lint-state--walk
       top (lambda (x)
             (cond ((and (symbolp x) (memq x drgnx-lint-state--hooks))
                    (cl-pushnew (symbol-name x) out :test #'equal))
                   ((and (consp x) (eq (car x) 'get-buffer-window) (cddr x) (car (cddr x)))
                    (cl-pushnew "get-buffer-window" out :test #'equal))))))
    (nreverse out)))

(defun drgnx-lint-state--files ()
  (directory-files-recursively (expand-file-name "modules" drgnx-dir) "\\.el\\'"))

(defun drgnx-lint-state--allowed (&optional file)
  "The allowlist: a list of plists (:file F :what W :why STRING :until TASK)."
  (with-temp-buffer
    (insert-file-contents (or file (expand-file-name "test/lint-state-allowed.eld" drgnx-dir)))
    (let (rows)
      (condition-case nil (while t (push (read (current-buffer)) rows)) (end-of-file nil))
      (nreverse rows))))

(defun drgnx-lint-state--rel (file) (file-relative-name file drgnx-dir))

(defun drgnx-lint-state--unlisted (allowed)
  "Sites under `modules/' that the ALLOWED rows do not name: strings \"FILE: WHAT\"."
  (let (bad)
    (dolist (f (drgnx-lint-state--files))
      (let ((rel (drgnx-lint-state--rel f)))
        (dolist (what (drgnx-lint-state--sites f))
          (unless (seq-some (lambda (r) (and (equal (plist-get r :file) rel) (equal (plist-get r :what) what))) allowed)
            (push (format "%s: %s" rel what) bad)))))
    (nreverse bad)))

(defun drgnx-lint-state--stale (allowed)
  "Rows of ALLOWED whose file no longer has the site."
  (seq-remove (lambda (r)
                (let ((f (expand-file-name (or (plist-get r :file) "") drgnx-dir)))
                  (and (file-exists-p f) (member (plist-get r :what) (drgnx-lint-state--sites f)))))
              allowed))

(ert-deftest drgnx-lint/modules-subscribe-instead-of-window-hooks ()
  (should (equal (drgnx-lint-state--unlisted (drgnx-lint-state--allowed)) nil)))

(ert-deftest drgnx-lint/no-stale-allowlist-entries ()
  (should (equal (drgnx-lint-state--stale (drgnx-lint-state--allowed)) nil)))

(ert-deftest drgnx-lint/every-allowlist-entry-says-why-and-until-when ()
  (dolist (r (drgnx-lint-state--allowed))
    (should (stringp (plist-get r :file)))
    (should (stringp (plist-get r :what)))
    (should (and (stringp (plist-get r :why)) (> (length (plist-get r :why)) 0)))
    (should (and (stringp (plist-get r :until)) (> (length (plist-get r :until)) 0)))))

(ert-deftest drgnx-lint/the-allowlist-has-no-duplicates ()
  (let ((keys (mapcar (lambda (r) (cons (plist-get r :file) (plist-get r :what))) (drgnx-lint-state--allowed))))
    (should (equal keys (delete-dups (copy-sequence keys))))))

(defmacro drgnx-lint-state--with-source (text &rest body)
  "Run BODY with `file' naming a temporary library whose text is TEXT."
  (declare (indent 1))
  `(let ((file (make-temp-file "drgnx-lint-state" nil ".el")))
     (unwind-protect (progn (with-temp-file file (insert ,text)) ,@body)
       (delete-file file))))

(ert-deftest drgnx-lint/the-state-check-sees-each-kind-of-site ()
  (drgnx-lint-state--with-source
      (concat "(defun a () (add-hook 'window-buffer-change-functions #'x nil t))\n"
              "(defun b () (add-hook 'window-size-change-functions #'x))\n"
              "(defun c (f) (my-helper t 'window-state-change-functions #'x))\n"
              "(defun d () (setq-local window-configuration-change-hook (list #'x)))\n"
              "(defun e (b) (get-buffer-window b t))\n"
              "(defun f (b) (get-buffer-window b 'visible))\n")
    (should (equal (sort (drgnx-lint-state--sites file) #'string<)
                   '("get-buffer-window" "window-buffer-change-functions" "window-configuration-change-hook"
                     "window-size-change-functions" "window-state-change-functions")))))

(ert-deftest drgnx-lint/the-state-check-ignores-what-is-not-an-addition ()
  (drgnx-lint-state--with-source
      (concat ";; `window-size-change-functions' in a comment\n"
              "(defun a () \"on `window-buffer-change-functions'\" (remove-hook 'window-size-change-functions #'x))\n"
              "(defun b (w) (get-buffer-window w) (get-buffer-window w nil) (get-buffer-window-list w nil t))\n"
              "(defun c () (add-hook 'window-selection-change-functions #'x))\n")
    (should (equal (drgnx-lint-state--sites file) nil))))

(ert-deftest drgnx-lint/a-site-that-is-not-listed-fails-and-a-listed-one-passes ()
  (let* ((rows (drgnx-lint-state--allowed))
         (row (car rows)))
    (should row)
    (should (member (format "%s: %s" (plist-get row :file) (plist-get row :what))
                    (drgnx-lint-state--unlisted (cdr rows))))
    (should (equal (drgnx-lint-state--unlisted rows) nil))))

(ert-deftest drgnx-lint/an-entry-that-matches-nothing-is-stale ()
  (let ((bogus '(:file "modules/tools/drgnx-live.el" :what "window-state-change-functions" :why "x" :until "Task 0"))
        (gone '(:file "modules/tools/no-such-file.el" :what "get-buffer-window" :why "x" :until "Task 0")))
    (should (equal (drgnx-lint-state--stale (list bogus gone)) (list bogus gone)))
    (should (equal (drgnx-lint-state--stale (drgnx-lint-state--allowed)) nil))))

;;; lint-state-test.el ends here
