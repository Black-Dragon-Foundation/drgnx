;;; mod-sticky-hub-test.el --- batch tests: sticky scroll's scopes from a real hub -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; A buffer without tree-sitter gets its scopes from the hub (`outline/scopes', view/outline.rs: the Outline's parse of
;; the file); a real hub as its own process answers, inside the delivery gate (`drgnx-test-gated').  Needs Sjá and the
;; hub's binary; skipped without either.  Each look waits for the header to show what the test did (a condition, never
;; a deadline).  The files are on disk (the hub reads them there), Emacs Lisp: Hrafn's own parse, where the test hub
;; has no tree-sitter grammars (the nesting of other languages: view/outline/tests.rs).  The rest of sticky scroll:
;; mod-sticky-test.el.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/gated-hub-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/memo-alloc-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/editor/drgnx-sticky" drgnx-dir) nil t)
(require 'drgnx-outline)

(defun drgnx-sticky-hub-test--elisp (name)
  "Emacs Lisp: a defun NAME of 40 body lines."
  (concat "(defun " name " ()\n  \"Doc.\"\n"
          (mapconcat (lambda (i) (format "  (message \"line %d\")" i)) (number-sequence 1 40) "\n") ")\n"))

(defmacro drgnx-sticky-hub-test--in (name text &rest body)
  "BODY with a gated hub, NAME written with TEXT in a temp folder and visited in the selected window (`b' its buffer,
`w' the window)."
  (declare (indent 2))
  `(drgnx-test-with-gated-hub
     (drgnx-test-with-state
       (let* ((dir (file-name-as-directory (make-temp-file "drgnx-sticky" t)))
              (f (expand-file-name ,name dir)) b w)
         (unwind-protect
             (progn
               (write-region ,text nil f nil 'silent)
               (setq b (find-file-noselect f))
               (delete-other-windows)
               (setq w (selected-window))
               (set-window-buffer w b)
               ,@body)
           (when (buffer-live-p b) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))
           (delete-directory dir t))))))

(defun drgnx-sticky-hub-test--start (w line)
  "Window W starts at LINE."
  (set-window-start w (with-current-buffer (window-buffer w)
                        (save-excursion (goto-char (point-min)) (forward-line (1- line)) (point)))))

(defun drgnx-sticky-hub-test--shows (w want)
  "Wait until W's segment is WANT (its text): the question goes (a timer of the virtual clock) and the hub answers."
  (drgnx-test-hub-settle (lambda () (drgnx-test-advance 0.01)
                           (equal (substring-no-properties (drgnx-sticky--segment w)) want))
                         (format "the header %S" want)))

(ert-deftest drgnx-sticky-hub/the-enclosing-function-sticks ()
  (drgnx-sticky-hub-test--in "a.el" (drgnx-sticky-hub-test--elisp "drgnx-sticky-test-fn")
    (drgnx-sticky-hub-test--start w 20)
    (drgnx-sticky-hub-test--shows w " › drgnx-sticky-test-fn")))

(ert-deftest drgnx-sticky-hub/no-header-at-the-top ()
  ;; the defun's own first line is on screen: nothing scrolled off
  (drgnx-sticky-hub-test--in "a.el" (drgnx-sticky-hub-test--elisp "drgnx-sticky-test-fn")
    (drgnx-sticky-hub-test--start w 20)
    (drgnx-sticky-hub-test--shows w " › drgnx-sticky-test-fn")
    (drgnx-sticky-hub-test--start w 1)
    (drgnx-sticky-hub-test--shows w "")))

(ert-deftest drgnx-sticky-hub/a-saved-rename-above-the-start-shows-the-new-name ()
  (drgnx-sticky-hub-test--in "a.el" (drgnx-sticky-hub-test--elisp "drgnx-sticky-test-fn")
    (drgnx-sticky-hub-test--start w 20)
    (drgnx-sticky-hub-test--shows w " › drgnx-sticky-test-fn")
    (with-current-buffer b
      (drgnx-sticky-mode 1)                                  ; its edit hook raises the epoch: an edit above the start
      (goto-char (point-min)) (search-forward "drgnx-sticky-test-fn") (replace-match "drgnx-sticky-test-renamed")
      (save-buffer))
    (drgnx-sticky-hub-test--shows w " › drgnx-sticky-test-renamed")))

(ert-deftest drgnx-sticky-hub/one-question-per-start-and-a-kept-answer-allocates-nothing ()
  ;; Typing below the start asks nothing; the same start asks once, and its kept segment comes from the memo
  (drgnx-sticky-hub-test--in "a.el" (drgnx-sticky-hub-test--elisp "drgnx-sticky-test-fn")
    (with-current-buffer b (drgnx-sticky-mode 1))
    (let ((asked 0))
      (cl-letf* ((orig (symbol-function 'drgnx-outline-scopes))
                 ((symbol-function 'drgnx-outline-scopes) (lambda (&rest a) (cl-incf asked) (apply orig a))))
        (drgnx-sticky-hub-test--start w 20)
        (drgnx-sticky-hub-test--shows w " › drgnx-sticky-test-fn")
        (should (= asked 1))
        (let ((s (drgnx-sticky--segment w)))
          (should (eq s (drgnx-sticky--segment w)))
          (should (= 0 (drgnx-memo-fixture-alloc (lambda () (drgnx-sticky--segment w)) 'drgnx-sticky--segment))))
        (with-current-buffer b (goto-char (point-max)) (insert ";; typed\n"))   ; below the window's start
        (drgnx-sticky-hub-test--shows w " › drgnx-sticky-test-fn")
        (should (= asked 1))))))

;;; mod-sticky-hub-test.el ends here
