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

;;;; One frame classifier
;; `drgnx-state-frame-kind' (core/drgnx-frame-kind.el) is the only place that decides what a frame is.  No other
;; library compares a terminal's name with "initial_terminal".  The rows below are sites not moved yet; each
;; names the task that moves it and how many strings it still holds.  A library with more fails, and so does
;; one with fewer: a task that migrates its sites lowers or removes its row.

(defconst drgnx-lint-state--classifier-home "core/drgnx-frame-kind.el"
  "The one library that may hold the terminal-name test.")

(defconst drgnx-lint-state--classifier-allowed
  '(("wb/drgnx-persist.el" 1 "ST-T15-1, DEFERRED pass")
    ("core/drgnx-timer.el" 1 "the debugger test: a core library no store task owns")
    ("core/drgnx-modal-choose.el" 1 "the daemon's own terminal cannot ask: a core library no store task owns"))
  "Rows (FILE COUNT WHO): FILE, relative to the checkout root, still holds COUNT of the string.")

(defun drgnx-lint-state--count-string (form string)
  "How many times the string STRING is an atom of FORM."
  (cond ((stringp form) (if (equal form string) 1 0))
        ((consp form) (let ((n 0) (x form))
                        (while (consp x) (setq n (+ n (drgnx-lint-state--count-string (car x) string)) x (cdr x)))
                        (+ n (if x (drgnx-lint-state--count-string x string) 0))))
        (t 0)))

(defun drgnx-lint-state--classifier-strings (&optional root)
  "Alist (FILE . COUNT) of the libraries in core/, wb/ and modules/ under ROOT that hold the string
\"initial_terminal\" as code, FILE relative to ROOT."
  (let ((root (or root drgnx-dir)) out)
    (dolist (dir '("core" "wb" "modules"))
      (dolist (f (directory-files-recursively (expand-file-name dir root) "\\.el\\'"))
        (let ((n (apply #'+ (mapcar (lambda (form) (drgnx-lint-state--count-string form "initial_terminal"))
                                    (drgnx-lint-state--forms f)))))
          (when (> n 0) (push (cons (file-relative-name f root) n) out)))))
    (nreverse out)))

(defun drgnx-lint-state--classifier-excess (found allowed)
  "Strings of FOUND (alist FILE . COUNT) beyond the home library and the ALLOWED rows: \"FILE: COUNT\" each."
  (let (bad)
    (dolist (c found)
      (let ((most (if (equal (car c) drgnx-lint-state--classifier-home) most-positive-fixnum
                    (or (nth 1 (assoc (car c) allowed)) 0))))
        (when (> (cdr c) most) (push (format "%s: %d" (car c) (cdr c)) bad))))
    ;; the count can only fall, and a row says so: a library under its row's count has a row to lower
    (dolist (row allowed)
      (let ((n (or (cdr (assoc (car row) found)) 0)))
        (when (< n (nth 1 row)) (push (format "%s: %d, row says %d" (car row) n (nth 1 row)) bad))))
    (nreverse bad)))

(ert-deftest drgnx-lint/one-frame-classifier ()
  (should (equal (drgnx-lint-state--classifier-excess (drgnx-lint-state--classifier-strings)
                                                      drgnx-lint-state--classifier-allowed)
                 nil)))

(ert-deftest drgnx-lint/the-classifier-lint-sees-a-second-classifier ()
  (let* ((allowed '(("core/a.el" 2 "Task X") ("core/b.el" 1 "Task Y")))
         (found '(("core/drgnx-frame-kind.el" . 1) ("modules/ui/drgnx-x.el" . 1) ("core/a.el" . 3) ("core/b.el" . 1))))
    ;; a new place, and a row exceeded, fail
    (should (equal (drgnx-lint-state--classifier-excess found allowed) '("modules/ui/drgnx-x.el: 1" "core/a.el: 3")))
    ;; exactly the rows (and the home) pass
    (should-not (drgnx-lint-state--classifier-excess '(("core/drgnx-frame-kind.el" . 4) ("core/a.el" . 2) ("core/b.el" . 1)) allowed))
    ;; fewer than a row says, or none, fail: the row is lowered or removed
    (should (equal (drgnx-lint-state--classifier-excess '(("core/a.el" . 1) ("core/b.el" . 1)) allowed) '("core/a.el: 1, row says 2")))
    (should (equal (drgnx-lint-state--classifier-excess '(("core/a.el" . 2)) allowed) '("core/b.el: 0, row says 1")))
    (drgnx-lint-state--with-source "(defun a (f) (equal (terminal-name f) \"initial_terminal\")) ; \"initial_terminal\"\n(defun b () \"the initial_terminal\")"
      (should (equal (drgnx-lint-state--count-string (car (drgnx-lint-state--forms file)) "initial_terminal") 1))
      (should (equal (drgnx-lint-state--count-string (cadr (drgnx-lint-state--forms file)) "initial_terminal") 0)))))

;;; lint-state-test.el ends here
