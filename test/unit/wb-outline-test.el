;;; wb-outline-test.el --- batch tests: the Outline section -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-outline)

(defmacro drgnx-outline-test--with (src &rest body)
  "BODY with SRC an elisp buffer in the editor and the Outline shown in the dock."
  (declare (indent 1))
  `(let ((drgnx-wb--sections nil) (drgnx-signal--subscribers nil) (drgnx-signal--editor-window nil)
         (,src (generate-new-buffer "outline-src.el")))
     (delete-other-windows)
     (with-current-buffer ,src
       (insert "(defun alpha () 1)\n(defvar beta 2)\n\n\n(defun gamma () 3)\n")
       (emacs-lisp-mode))
     (switch-to-buffer ,src)
     (setq drgnx-signal--editor-window (selected-window))
     (drgnx-outline-setup)
     (drgnx-wb-show-sidebar)
     (unwind-protect (progn (drgnx-outline-refresh) ,@body)
       (drgnx-wb-hide-sidebar)
       (delete-other-windows)
       (kill-buffer ,src)
       (when (get-buffer drgnx-outline-buffer-name) (kill-buffer drgnx-outline-buffer-name)))))

(defun drgnx-outline-test--names ()
  (with-current-buffer drgnx-outline-buffer-name
    (mapcar (lambda (r) (aref r 0)) drgnx-outline--rows)))

(ert-deftest drgnx-outline/lists-the-definitions-in-order ()
  (drgnx-outline-test--with src
    (let ((names (drgnx-outline-test--names)))
      (should (member "beta" names))
      (should (< (seq-position names "alpha") (seq-position names "gamma"))))))

(ert-deftest drgnx-outline/a-row-jumps-in-the-editor ()
  (drgnx-outline-test--with src
    (let ((editor (selected-window)))
      (with-current-buffer drgnx-outline-buffer-name
        (drgnx-outline-jump (seq-position (drgnx-outline-test--names) "gamma")))
      (should (eq (selected-window) editor))
      (should (equal (with-current-buffer src (save-excursion (goto-char (window-point editor)) (thing-at-point 'line t)))
                     "(defun gamma () 3)\n")))))

(ert-deftest drgnx-outline/no-index-shows-a-notice ()
  (drgnx-outline-test--with src
    (with-current-buffer src (fundamental-mode))
    (drgnx-outline-refresh)
    (should (null (drgnx-outline-test--names)))
    (should (string-match-p "No outline" (with-current-buffer drgnx-outline-buffer-name (buffer-string))))
    (let ((drgnx-outline-max-size 10))
      (with-current-buffer src (emacs-lisp-mode))
      (drgnx-outline-refresh)
      (should (string-match-p "too large" (with-current-buffer drgnx-outline-buffer-name (buffer-string)))))))

(ert-deftest drgnx-outline/an-edit-updates-it-after-a-pause ()
  (drgnx-outline-test--with src
    (with-current-buffer src (goto-char (point-max)) (insert "(defun delta () 4)\n"))
    (should (timerp drgnx-outline--timer))
    (drgnx-outline--idle)                         ; the pause
    (should (member "delta" (drgnx-outline-test--names)))))

(ert-deftest drgnx-outline/an-empty-index-is-a-notice ()
  ;; imenu answers (nil) for an elisp buffer without definitions (*scratch*).
  (drgnx-outline-test--with src
    (with-current-buffer src (erase-buffer) (insert ";; nothing\n"))
    (drgnx-outline-refresh)
    (should (null (drgnx-outline-test--names)))
    (should (string-match-p "No outline" (with-current-buffer drgnx-outline-buffer-name (buffer-string))))))

(ert-deftest drgnx-outline/no-rescan-row ()
  (drgnx-outline-test--with src
    (let ((imenu-auto-rescan nil))
      (should-not (member "*Rescan*" (drgnx-outline-test--names))))))
