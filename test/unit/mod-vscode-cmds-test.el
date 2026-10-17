;;; mod-vscode-cmds-test.el --- batch tests: the VS Code editing, file, search, code and view commands -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(dolist (m '("core/drgnx-basics" "editor/drgnx-editing" "tools/drgnx-search" "lang/drgnx-lang" "ui/drgnx-look" "extra/drgnx-mc"))
  (load (expand-file-name (concat "modules/" m) drgnx-dir) nil t))

(defmacro drgnx-vsc-test--in (text &rest body)
  "BODY in a text buffer holding TEXT, point at the first | (removed)."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (text-mode)
     (goto-char (point-min))
     (when (search-forward "|" nil t) (delete-char -1))
     ,@body))

(ert-deftest drgnx-vsc/every-command-is-registered ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (dolist (m '(core/basics editor/editing tools/search lang/eglot ui/look))
      (funcall (plist-get (alist-get m drgnx-modules--table) :setup)))
    (dolist (id '(file-save-as file-new file-reopen-tab file-new-window file-close-window
                               go-recent go-symbol-project go-back go-forward search-file search-replace
                               edit-select-all edit-select-line edit-redo edit-comment edit-delete-line edit-move-up edit-move-down
                               edit-duplicate edit-line-below edit-line-above code-quick-fix code-problems code-format
                               view-zoom-in view-zoom-out view-zoom-reset view-escape))
      (should (drgnx-commands-get id)))))

(ert-deftest drgnx-vsc/move-line-up-and-down ()
  (drgnx-vsc-test--in "one\ntw|o\nthree\n"
    (drgnx-editing-move-line-down)
    (should (equal (buffer-string) "one\nthree\ntwo\n"))
    (should (equal (buffer-substring (line-beginning-position) (point)) "tw"))   ; the cursor moves with it
    (drgnx-editing-move-line-up)
    (drgnx-editing-move-line-up)
    (should (equal (buffer-string) "two\none\nthree\n"))
    (drgnx-editing-move-line-up)                                                 ; at the top: nothing
    (should (equal (buffer-string) "two\none\nthree\n"))))

(ert-deftest drgnx-vsc/move-the-selected-lines ()
  (drgnx-vsc-test--in "a\n|b\nc\nd\n"
    (transient-mark-mode 1)
    (push-mark (point) t t)
    (forward-line 1) (end-of-line)                      ; b and c selected
    (drgnx-editing-move-line-down)
    (should (equal (buffer-string) "a\nd\nb\nc\n"))
    (should (region-active-p))                          ; still selected: move again
    (should (equal (buffer-substring (region-beginning) (region-end)) "b\nc"))))

(ert-deftest drgnx-vsc/select-line-extends-when-repeated ()
  (drgnx-vsc-test--in "a|a\nbb\ncc\n"
    (transient-mark-mode 1)
    (drgnx-editing-select-line)
    (should (equal (buffer-substring (region-beginning) (region-end)) "aa\n"))
    (drgnx-editing-select-line)
    (should (equal (buffer-substring (region-beginning) (region-end)) "aa\nbb\n"))))

(ert-deftest drgnx-vsc/new-line-below-and-above ()
  (drgnx-vsc-test--in "fo|o\n"
    (drgnx-editing-line-below)
    (insert "x")
    (drgnx-editing-line-above)
    (insert "y")
    (should (equal (buffer-string) "foo\ny\nx\n"))))

(ert-deftest drgnx-vsc/new-untitled-buffers-are-numbered ()
  (let ((a (drgnx-basics-new-untitled)) (b (drgnx-basics-new-untitled)))
    (unwind-protect
        (progn (should-not (eq a b))
               (should (string-prefix-p "Untitled-" (buffer-name a)))
               (should (string-prefix-p "Untitled-" (buffer-name b)))
               (should (eq (current-buffer) b)))
      (kill-buffer a) (kill-buffer b))))

(ert-deftest drgnx-vsc/reopen-the-last-closed-file ()
  (let* ((f (make-temp-file "drgnx-reopen" nil ".txt")) (drgnx-basics--closed nil)
         (kill-buffer-hook (list #'drgnx-basics--note-closed)))
    (unwind-protect
        (progn
          (kill-buffer (find-file-noselect f))
          (should (equal drgnx-basics--closed (list f)))
          (drgnx-basics-reopen-tab)
          (should (equal (buffer-file-name) f))
          (should-not drgnx-basics--closed)
          (should-error (drgnx-basics-reopen-tab) :type 'user-error))
      (when (get-file-buffer f) (kill-buffer (get-file-buffer f)))
      (delete-file f))))

(ert-deftest drgnx-vsc/search-file-without-consult-is-isearch ()
  (skip-unless (not (fboundp 'consult-line)))
  (cl-letf (((symbol-function 'isearch-forward) (lambda (&rest _) (interactive) 'isearched)))
    (should (eq (drgnx-search-file) 'isearched))))

(ert-deftest drgnx-vsc/quick-fix-needs-a-server ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (should-error (drgnx-lang-quick-fix) :type 'user-error)))

(ert-deftest drgnx-vsc/multiple-cursors-waits-for-its-package ()
  (let ((spec (alist-get 'extra/mc drgnx-modules--table)))
    (should (equal (plist-get spec :packages) '(multiple-cursors)))
    (should (eq (plist-get spec :stage) 'idle))))

;;; mod-vscode-cmds-test.el ends here
