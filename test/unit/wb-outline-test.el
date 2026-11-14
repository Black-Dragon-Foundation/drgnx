;;; wb-outline-test.el --- batch tests: the Outline section, its rows from a real hub -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; A real hub as its own process outlines the file (`outline/set', view/outline.rs) and Sjá draws the rows; this
;; Emacs plays the editor inside the delivery gate (`drgnx-test-gated').  Needs Sjá (a Nidhogg with
;; `nidhogg-view-push') and the hub's binary; skipped without either.  Nothing of the hub's side is stubbed: each look
;; waits for the section to show what the test did (a condition, never a deadline).  The files are on disk (the hub
;; reads them there; the edit history's mirror of unsaved text: test/conformance/view/outline-follows-edits.jsonl).
;; The section with the hub down: wb-outline-edge-test.el.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/gated-hub-fixture" drgnx-dir) nil t)
(require 'drgnx-outline)

(defun drgnx-outline-test--visit (dir name text)
  "NAME under DIR, written with TEXT, visited: its buffer."
  (let ((f (expand-file-name name dir)))
    (write-region text nil f nil 'silent)
    (find-file-noselect f)))

(defun drgnx-outline-test--settle (pred what)
  "Flush the bus, then wait until PRED holds in the Outline's buffer: before each look the hub's lines are released
and what came is drawn.  PRED's value."
  (drgnx-signal--flush)
  (drgnx-test-hub-settle
   (lambda () (when-let* ((b (get-buffer drgnx-outline-buffer-name)))
                (with-current-buffer b (drgnx-view-draw-now nil) (funcall pred))))
   what))

(defun drgnx-outline-test--names ()
  "The Outline's rows, as their text trimmed."
  (with-current-buffer drgnx-outline-buffer-name
    (mapcar #'string-trim (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n" t))))

(defun drgnx-outline-test--marked ()
  "The text of the Outline's marked row, or nil."
  (with-current-buffer drgnx-outline-buffer-name
    (when-let* ((o (seq-find (lambda (o) (overlay-get o 'drgnx-outline-current)) (overlays-in (point-min) (point-max)))))
      (buffer-substring-no-properties (overlay-start o) (overlay-end o)))))

(defun drgnx-outline-test--row (name)
  "Where the Outline's row of NAME starts."
  (with-current-buffer drgnx-outline-buffer-name
    (save-excursion (goto-char (point-min)) (re-search-forward (concat "^ *" (regexp-quote name) "$")) (pos-bol))))

(defun drgnx-outline-test--show (src)
  "Show SRC in the editor; the Outline follows (the bus's `editor-changed' edge)."
  (set-window-buffer (drgnx-wb-editor-window) src)
  (drgnx-outline-refresh))

(defmacro drgnx-outline-test--with (dir src &rest body)
  "BODY with a gated hub this Emacs is connected to, a fresh bus, SRC an Emacs Lisp file (alpha, beta, gamma on lines
1, 2 and 5) under the temp DIR in the editor, and the Outline shown in the dock, its first rows drawn."
  (declare (indent 2))
  `(drgnx-test-with-gated-hub
     (drgnx-test-with-state
       (let* ((,dir (file-name-as-directory (make-temp-file "drgnx-outline" t)))
              (drgnx-wb--sections nil) (drgnx-wb--collapsed (list (cons 'outline nil)))   ; open: not its fold
              (drgnx-outline--source nil) (drgnx-outline--sent :none) (drgnx-outline--reveal nil)
              (drgnx-outline--mark nil) (drgnx-outline--waiting nil)
              (,src (drgnx-outline-test--visit ,dir "a.el" "(defun alpha () 1)\n(defvar beta 2)\n\n\n(defun gamma () 3)\n")))
         (unwind-protect
             (progn
               (delete-other-windows)
               (switch-to-buffer ,src)
               (drgnx-test-use-editor (selected-window))
               (drgnx-outline-setup)
               (drgnx-wb-show-sidebar)
               ;; a batch Emacs never redisplays, so `window-buffer-change-functions' do not run: the env of the
               ;; class the dock shows the section in goes as a shown window would send it
               (drgnx-view-env-update drgnx-outline-hub-view)
               (drgnx-outline-refresh)
               (drgnx-outline-test--settle (lambda () (member "gamma" (drgnx-outline-test--names))) "the first rows")
               ,@body)
           (drgnx-outline--watch nil)
           (drgnx-wb-hide-sidebar)
           (delete-other-windows)
           (dolist (b (buffer-list))
             (when (and (buffer-file-name b) (string-prefix-p ,dir (buffer-file-name b)))
               (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
           (when (get-buffer drgnx-outline-buffer-name) (kill-buffer drgnx-outline-buffer-name))
           (delete-directory ,dir t))))))

(ert-deftest drgnx-outline/lists-the-definitions-in-order ()
  (drgnx-outline-test--with dir src
    (should (equal (drgnx-outline-test--names) '("alpha" "beta" "gamma")))))

(ert-deftest drgnx-outline/a-row-jumps-in-the-editor ()
  ;; The row's line is the hub's (the model's `line' field): the editor goes there, the Outline keeps its point.
  (drgnx-outline-test--with dir src
    (let ((at (drgnx-outline-test--row "gamma")))
      (with-current-buffer drgnx-outline-buffer-name
        (should (= 5 (drgnx-outline-line-at at)))
        (drgnx-outline-jump (drgnx-outline-line-at at)))
      (should (= 5 (with-current-buffer src (line-number-at-pos (window-point (drgnx-wb-editor-window)))))))))

(ert-deftest drgnx-outline/a-file-with-nothing-to-outline-shows-a-notice ()
  (drgnx-outline-test--with dir src
    (drgnx-outline-test--show (drgnx-outline-test--visit dir "notes.txt" "nothing to outline here\n"))
    (drgnx-outline-test--settle (lambda () (string-match-p "No outline for this file" (buffer-string))) "the notice")
    (should-not (drgnx-outline-test--marked))))

(ert-deftest drgnx-outline/a-file-past-a-megabyte-shows-a-notice ()
  ;; The hub's one size check (`too_large', view/outline.rs) at the Lisp Outline's limit: the definitions in a file
  ;; past it are not parsed, the section says why.
  (drgnx-outline-test--with dir src
    (let ((large-file-warning-threshold nil))
      (drgnx-outline-test--show
       (drgnx-outline-test--visit dir "big.el" (concat "(defun kept () 1)\n;; " (make-string (* 1024 1024) ?x) "\n"))))
    (drgnx-outline-test--settle (lambda () (string-match-p "This file is too large for an outline" (buffer-string)))
                                "the notice")
    (should-not (member "kept" (drgnx-outline-test--names)))))

(ert-deftest drgnx-outline/a-remote-file-is-not-sent ()
  ;; The hub reads only local files: a remote one goes as no file, and the section says it has no outline.
  (drgnx-outline-test--with dir src
    (let ((other (drgnx-outline-test--visit dir "b.el" "(defun delta () 4)\n")))
      (cl-letf (((symbol-function 'file-remote-p) (lambda (f &rest _) (and (stringp f) (string-prefix-p "/ssh:" f)))))
        (with-current-buffer other (setq buffer-file-name "/ssh:nobody@example.invalid:/b.el"))
        (unwind-protect
            (progn
              (drgnx-outline-test--show other)
              (should-not drgnx-outline--sent)
              (drgnx-outline-test--settle (lambda () (string-match-p "No outline for this file" (buffer-string)))
                                          "the notice"))
          (with-current-buffer other (setq buffer-file-name nil)))))))

(ert-deftest drgnx-outline/a-save-outlines-the-file-again ()
  ;; Nothing goes to the hub per keystroke; a save sends the file again and its new definition comes.
  (drgnx-outline-test--with dir src
    (with-current-buffer src
      (goto-char (point-max))
      (insert "(defun delta () 4)\n")
      (save-buffer))
    (drgnx-outline-test--settle (lambda () (equal (drgnx-outline-test--names) '("alpha" "beta" "gamma" "delta")))
                                "the saved definition")))

(ert-deftest drgnx-outline/follows-current-symbol ()
  ;; The definition the editor's point is in is marked (Sjá's `at-line' over the hub's lines); the Outline's own
  ;; point (the user's selection in it) never moves.
  (drgnx-outline-test--with dir src
    (let ((editor (drgnx-wb-editor-window))
          (pt (with-current-buffer drgnx-outline-buffer-name (point))))
      (dolist (c '((5 . "gamma") (3 . "beta") (1 . "alpha")))
        (set-window-point editor (with-current-buffer src (save-excursion (goto-char (point-min))
                                                                          (forward-line (1- (car c))) (point))))
        (drgnx-outline--mark-current)
        (should (equal (string-trim (drgnx-outline-test--marked)) (cdr c))))
      (should (= pt (with-current-buffer drgnx-outline-buffer-name (point)))))))

(ert-deftest drgnx-outline/another-file-shows-the-current-definition ()
  ;; A new file's first rows show the definition the editor is in, with a third of the window above it.
  (drgnx-outline-test--with dir src
    (let ((big (drgnx-outline-test--visit
                dir "big.el" (mapconcat (lambda (i) (format "(defun fn-%d () %d)\n" i i)) (number-sequence 0 199) ""))))
      (with-current-buffer big (goto-char (point-min)) (forward-line 150))
      (drgnx-outline-test--show big)
      (set-window-point (drgnx-wb-editor-window) (with-current-buffer big (point)))
      (drgnx-outline-test--settle (lambda () (equal (string-trim (or (drgnx-outline-test--marked) "")) "fn-150")) "the current definition")
      (let ((w (get-buffer-window drgnx-outline-buffer-name t)))
        (should (= (window-point w) (drgnx-outline-test--row "fn-150")))
        (should (> (window-start w) (point-min)))))))

;;; wb-outline-test.el ends here
