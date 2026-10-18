;;; mod-replace-view-test.el --- batch tests: the Search view in the sidebar and the find bar -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(require 'eglot)
(require 'drgnx-wb)
(load (expand-file-name "test/fixtures/git-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-dir) nil t)
(require 'drgnx-run-ert "run-ert")                     ; `drgnx-run-ert-time-factor'
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defun drgnx-replace-view-test--bind-keys ()
  "Bind the shipped VS Code profile's keys of the replace commands that live in the view's and the bar's keymaps."
  (let ((r (drgnx-keys-resolve :commands (drgnx-commands-all)
                               :profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))
                               :layers '((vscode app editing window)))))
    (dolist (b (plist-get r :bindings))
      (let ((map (symbol-value (cdr (drgnx-commands--keymap-spec (plist-get b :map))))))
        (when (memq map (list drgnx-replace-keys-map drgnx-replace-bar-keys-map))
          (keymap-set map (plist-get b :key) (drgnx-cmd-command (drgnx-commands-get (plist-get b :id)))))))))

(defmacro drgnx-replace-view-test--with (&rest body)
  "BODY with only the Search section and the replace commands defined (their VS Code keys in the view's and the
bar's keymaps), one editor window, no view or bar left over."
  (declare (indent 0))
  `(let ((drgnx-wb--sections nil) (drgnx-signal--editor-window nil)
         (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (drgnx-wb-view-providers (list (cons 'search #'drgnx-replace--provide-view))))   ; what the module's setup registers
     (advice-add 'drgnx-persist-save :before #'drgnx-replace--close-bars)
     (delete-other-windows)
     (set-frame-parameter nil 'drgnx-wb-view nil)
     (drgnx-replace--define-section)
     (drgnx-replace--define-commands)
     (drgnx-replace-view-test--bind-keys)
     (unwind-protect (progn ,@body)
       (advice-remove 'drgnx-persist-save #'drgnx-replace--close-bars)
       (drgnx-replace-bar-close)
       (drgnx-wb-hide-sidebar)
       (delete-other-windows)
       (set-frame-parameter nil 'drgnx-wb-view nil)
       (setcdr drgnx-replace-keys-map nil)
       (setcdr drgnx-replace-bar-keys-map nil)
       (dolist (b (list drgnx-replace-buffer-name drgnx-replace-bar-buffer-name))
         (when (get-buffer b) (kill-buffer b))))))

(defun drgnx-replace-view-test--view () (get-buffer drgnx-replace-buffer-name))

(defun drgnx-replace-view-test--wait (&optional pred)
  "Wait (at most 10 s) until PRED holds, by default until the view is idle (no timer, search or drawing pending)."
  (let ((pred (or pred (lambda () (with-current-buffer (drgnx-replace-view-test--view) (not (drgnx-replace--busy-p))))))
        (deadline (+ (float-time) 10)))
    (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.02))
    (should (funcall pred))))

(defun drgnx-replace-view-test--set (name value)
  "Type VALUE into the view's field NAME (as the user would: the field's change hooks run)."
  (with-current-buffer (drgnx-replace-view-test--view)
    (widget-value-set (drgnx-replace--widget name) value)))

(defun drgnx-replace-view-test--count ()
  (with-current-buffer (drgnx-replace-view-test--view) (length drgnx-replace--matches)))

(defun drgnx-replace-view-test--rows ()
  "The view's matches as (FILE LINE), FILE as given (no directory only when below the view's root), sorted: a wrong
count says which rows."
  (with-current-buffer (drgnx-replace-view-test--view)
    (sort (mapcar (lambda (m) (list (file-relative-name (plist-get m :file) drgnx-replace--root) (plist-get m :line)))
                  drgnx-replace--matches)
          (lambda (a b) (string< (format "%S" a) (format "%S" b))))))

(defun drgnx-replace-view-test--files ()
  "The files the view lists, by name, sorted (ripgrep sends files in any order)."
  (with-current-buffer (drgnx-replace-view-test--view)
    (let ((out nil) (pos (point-min)))
      (while (setq pos (text-property-not-all pos (point-max) 'drgnx-replace-file nil))
        (push (file-name-nondirectory (get-text-property pos 'drgnx-replace-file)) out)
        (setq pos (or (next-single-property-change pos 'drgnx-replace-file) (point-max))))
      (sort out #'string<))))

(defun drgnx-replace-view-test--press-box (pred)
  "Press the tick box of the first row (a match plist) or header (a file name) PRED accepts."
  (with-current-buffer (drgnx-replace-view-test--view)
    (let ((pos (point-min)) (found nil))
      (while (and (not found) (setq pos (next-single-property-change pos 'drgnx-replace-box)))
        (let ((v (get-text-property pos 'drgnx-replace-box)))
          (when (and v (funcall pred v)) (setq found pos))))
      (should found)
      (push-button found))))

(defun drgnx-replace-view-test--box-at (pred)
  "The tick box text (\"[x]\", \"[-]\" or \"[ ]\") of the first row or header PRED accepts."
  (with-current-buffer (drgnx-replace-view-test--view)
    (let ((pos (point-min)) (found nil))
      (while (and (not found) (setq pos (next-single-property-change pos 'drgnx-replace-box)))
        (let ((v (get-text-property pos 'drgnx-replace-box)))
          (when (and v (funcall pred v)) (setq found pos))))
      (buffer-substring-no-properties found (+ found 3)))))

(defun drgnx-replace-view-test--visit (repo file pos)
  "Show FILE of REPO in the editor window (selected), point at POS."
  (select-window (drgnx-wb-editor-window))
  (let ((buf (find-file-noselect (expand-file-name file repo))))
    (set-window-buffer (selected-window) buf)
    (set-buffer buf)
    (goto-char pos)
    buf))

(defun drgnx-replace-view-test--read (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest drgnx-replace/view-fields-drive-a-search ()
  (drgnx-replace-view-test--with
    (drgnx-git-test-with-repo
      (drgnx-git-test-write repo "src/a.el" "needle one\nneedle two\n")
      (drgnx-git-test-write repo "src/b.md" "needle\n")
      (drgnx-git-test-write repo "test/c.el" ";; a needle\n")
      (drgnx-replace-view-test--visit repo "test/c.el" 7)
      (drgnx-replace-in-files)
      ;; the Search view in the sidebar, focused on the find field, with the word at point
      (should (eq (drgnx-wb-sidebar-view) 'search))
      (should (eq (window-buffer (drgnx-wb-section-window 'search)) (drgnx-replace-view-test--view)))
      (should (eq (selected-window) (drgnx-wb-section-window 'search)))
      (with-current-buffer (drgnx-replace-view-test--view)
        (should (derived-mode-p 'drgnx-replace-mode))
        (should (equal (widget-value (drgnx-replace--widget 'find)) "needle"))
        (should (eq (drgnx-replace--opt :scope) 'project))
        (should (eq (widget-field-at (point)) (drgnx-replace--widget 'find))))
      (drgnx-replace-view-test--wait)
      (should (= (drgnx-replace-view-test--count) 4))
      (should (equal (drgnx-replace-view-test--files) '("a.el" "b.md" "c.el")))
      ;; typing waits for a pause, then searches
      (drgnx-replace-view-test--set 'include "src/**")
      (with-current-buffer (drgnx-replace-view-test--view)
        (should (timerp drgnx-replace--search-timer))
        (should (= (length drgnx-replace--matches) 4)))
      (drgnx-replace-view-test--wait)
      (should (equal (drgnx-replace-view-test--files) '("a.el" "b.md")))
      (drgnx-replace-view-test--set 'exclude "*.md")
      (drgnx-replace-view-test--wait)
      (should (= (drgnx-replace-view-test--count) 2))
      ;; the toggles
      (with-current-buffer (drgnx-replace-view-test--view) (drgnx-replace--toggle :case))
      (drgnx-replace-view-test--set 'find "NEEDLE")
      (drgnx-replace-view-test--wait)
      (should (= (drgnx-replace-view-test--count) 0))
      (with-current-buffer (drgnx-replace-view-test--view)
        (drgnx-replace--toggle :case)
        (drgnx-replace--toggle :regexp))
      (drgnx-replace-view-test--set 'find "need(le)? (one|two)")
      (drgnx-replace-view-test--wait)
      (should (= (drgnx-replace-view-test--count) 2))
      (with-current-buffer (drgnx-replace-view-test--view)
        (drgnx-replace--toggle :regexp)
        (drgnx-replace--toggle :word))
      (drgnx-replace-view-test--set 'find "need")
      (drgnx-replace-view-test--wait)
      (should (= (drgnx-replace-view-test--count) 0))
      (drgnx-replace-view-test--set 'find "needle")
      (drgnx-replace-view-test--wait)
      (should (= (drgnx-replace-view-test--count) 2))
      ;; scope This file: the file the view was opened from, globs do not apply
      (with-current-buffer (drgnx-replace-view-test--view) (drgnx-replace--set-scope 'file))
      (drgnx-replace-view-test--wait)
      (should (equal (drgnx-replace-view-test--files) '("c.el")))
      ;; the replace field: old → new on every row
      (drgnx-replace-view-test--set 'replace "pin")
      (drgnx-replace-view-test--wait)
      (with-current-buffer (drgnx-replace-view-test--view)
        (goto-char (point-min))
        (should (search-forward "needlepin" nil t))
        (should (eq (get-text-property (- (point) 1) 'face) 'drgnx-replace-new))
        (should (eq (get-text-property (- (point) 4) 'face) 'drgnx-replace-old))))))

(ert-deftest drgnx-replace/view-search-puts-point-in-the-find-field ()
  ;; VS Code's Ctrl+Shift+F: the Search view, focused, the cursor in its query field, wherever it was before.
  (drgnx-replace-view-test--with
    (call-interactively #'drgnx-wb-view-search)
    (let ((w (drgnx-wb-section-window 'search)))
      (should (eq (selected-window) w))
      (with-selected-window w (goto-char (point-max)))  ; the cursor left in the results
      (select-window (drgnx-wb-editor-window))
      (call-interactively #'drgnx-wb-view-search)
      (should (eq (selected-window) w))
      (with-current-buffer (drgnx-replace-view-test--view)
        (should (eq (widget-field-at (window-point w)) (drgnx-replace--widget 'find)))))))

(ert-deftest drgnx-replace/view-search-before-the-module-set-up ()
  ;; C-S-f in the first second (the module sets up at idle): the view is set up then, not "No search view".
  (drgnx-replace-view-test--with
    (setq drgnx-wb--sections nil)
    (cl-letf (((symbol-function 'drgnx-module-disabled-p) (lambda (_) nil)))
      (call-interactively #'drgnx-wb-view-search))
    (should (eq (selected-window) (drgnx-wb-section-window 'search)))
    (with-current-buffer (drgnx-replace-view-test--view)
      (should (eq (widget-field-at (point)) (drgnx-replace--widget 'find)))))
  ;; the module turned off: no view
  (drgnx-replace-view-test--with
    (setq drgnx-wb--sections nil)
    (cl-letf (((symbol-function 'drgnx-module-disabled-p) (lambda (m) (eq m 'tools/replace))))
      (should-error (call-interactively #'drgnx-wb-view-search) :type 'user-error))))

(ert-deftest drgnx-replace/ticks-choose-what-is-written ()
  (drgnx-replace-view-test--with
    (drgnx-git-test-with-repo
      (drgnx-git-test-write repo "a.txt" "foo 1\nfoo 2\n")
      (drgnx-git-test-write repo "b.txt" "foo 3\n")
      (drgnx-git-test-write repo "c.txt" "foo 4\n")
      (drgnx-replace-view-test--visit repo "a.txt" 1)
      (drgnx-replace-in-files)
      (drgnx-replace-view-test--set 'replace "bar")
      (drgnx-replace-view-test--wait)
      ;; (macOS CI once listed 7 here; the rows say which)
      (should (equal (drgnx-replace-view-test--rows) '(("a.txt" 1) ("a.txt" 2) ("b.txt" 1) ("c.txt" 1))))
      (let ((a (expand-file-name "a.txt" repo)) (b (expand-file-name "b.txt" repo)) (c (expand-file-name "c.txt" repo))
            (row (lambda (file line) (lambda (v) (and (consp v) (equal (plist-get v :file) file) (= (plist-get v :line) line))))))
        ;; untick a match, then a whole file
        (drgnx-replace-view-test--press-box (funcall row a 2))
        (should (equal (drgnx-replace-view-test--box-at (funcall row a 2)) "[ ]"))
        (should (equal (drgnx-replace-view-test--box-at (lambda (v) (equal v a))) "[-]"))
        (drgnx-replace-view-test--press-box (lambda (v) (equal v b)))
        (should (equal (drgnx-replace-view-test--box-at (funcall row b 1)) "[ ]"))
        (should (equal (drgnx-replace-view-test--box-at (lambda (v) (equal v b))) "[ ]"))
        ;; Replace All writes only the ticked ones
        (with-current-buffer (drgnx-replace-view-test--view) (drgnx-replace-all))
        (should (equal (drgnx-replace-view-test--read a) "bar 1\nfoo 2\n"))
        (should (equal (drgnx-replace-view-test--read b) "foo 3\n"))
        (should (equal (drgnx-replace-view-test--read c) "bar 4\n"))
        (with-current-buffer (drgnx-replace-view-test--view)
          (should (string-match-p "Replaced 2 in 2 files" drgnx-replace--status)))
        ;; one Undo puts both files back
        (with-current-buffer (drgnx-replace-view-test--view) (drgnx-replace-view-undo))
        (should (equal (drgnx-replace-view-test--read a) "foo 1\nfoo 2\n"))
        (should (equal (drgnx-replace-view-test--read c) "foo 4\n"))
        (drgnx-replace-view-test--wait)
        ;; a single match from its row, ticked or not
        (should (= (drgnx-replace-view-test--count) 4))
        (with-current-buffer (drgnx-replace-view-test--view)
          (goto-char (text-property-any (point-min) (point-max) 'drgnx-replace-box
                                        (seq-find (lambda (m) (equal (plist-get m :file) b)) drgnx-replace--matches)))
          (drgnx-replace-this))
        (should (equal (drgnx-replace-view-test--read b) "bar 3\n"))
        (should (equal (drgnx-replace-view-test--read a) "foo 1\nfoo 2\n"))
        (should (= (drgnx-replace-view-test--count) 3))))))

(ert-deftest drgnx-replace/f2-opens-with-symbol-on ()
  (drgnx-replace-view-test--with
    (drgnx-git-test-with-repo
      (drgnx-git-test-write repo "a.el" "(defun foo () (foo))\n;; foo in a comment\n")
      (drgnx-git-test-write repo "b.el" "(foo)\n")
      (let* ((a (expand-file-name "a.el" repo)) (b (expand-file-name "b.el" repo))
             (edit (lambda (line char) (list :range (list :start (list :line line :character char)
                                                          :end (list :line line :character (+ char 3)))
                                             :newText "foo_drgnx_rename")))
             (reply (list :changes (list (intern (concat ":" (eglot-path-to-uri a)))
                                         (vector (funcall edit 0 7) (funcall edit 0 15))
                                         (intern (concat ":" (eglot-path-to-uri b)))
                                         (vector (funcall edit 0 1)))))
             (server 'fake) (requests 0))
        ;; visited before the fake server exists (visiting under it would start eglot)
        (find-file-noselect a) (find-file-noselect b)
        (cl-letf (((symbol-function 'eglot-current-server) (lambda () server))
                  ((symbol-function 'eglot-server-capable) (lambda (&rest f) (equal f '(:renameProvider))))
                  ((symbol-function 'eglot--signal-textDocument/didChange) #'ignore)
                  ((symbol-function 'jsonrpc-request) (lambda (&rest _) (cl-incf requests) reply)))
          (drgnx-replace-view-test--visit repo "a.el" 9)
          (drgnx-replace-rename-symbol)
          (should (eq (drgnx-wb-sidebar-view) 'search))
          (drgnx-replace-view-test--wait)
          (with-current-buffer (drgnx-replace-view-test--view)
            (should (drgnx-replace--opt :symbol))
            (should (equal (widget-value (drgnx-replace--widget 'find)) "foo"))
            ;; the server's edits only: the comment's foo is not one
            (should (= (length drgnx-replace--matches) 3))
            (should (eq (widget-field-at (point)) (drgnx-replace--widget 'replace)))
            ;; globs and the text toggles do not apply: greyed out
            (dolist (w '(include exclude :case :word :regexp))
              (should-not (widget-apply (drgnx-replace--widget w) :active))))
          (should (= requests 1))
          ;; typing the new name redraws the previews; it never asks the server again
          (drgnx-replace-view-test--set 'replace "bar")
          (drgnx-replace-view-test--wait)
          (should (= requests 1))
          (with-current-buffer (drgnx-replace-view-test--view)
            (goto-char (point-min))
            (should (search-forward "foobar" nil t))
            (drgnx-replace-all))
          (should (equal (drgnx-replace-view-test--read a) "(defun bar () (bar))\n;; foo in a comment\n"))
          (should (equal (drgnx-replace-view-test--read b) "(bar)\n"))
          ;; Symbol off: the toggles come back
          (with-current-buffer (drgnx-replace-view-test--view)
            (drgnx-replace--toggle :symbol)
            (should-not (drgnx-replace--opt :symbol))
            (should (widget-apply (drgnx-replace--widget :case) :active)))
          ;; Replace in Files turns Symbol on by itself at a name the server can rename, not without a server
          (drgnx-replace-view-test--visit repo "b.el" 3)
          (drgnx-replace-in-files)
          (drgnx-replace-view-test--wait)
          (with-current-buffer (drgnx-replace-view-test--view) (should (drgnx-replace--opt :symbol)))
          (setq server nil)
          (drgnx-replace-view-test--visit repo "b.el" 3)
          (drgnx-replace-in-files)
          (drgnx-replace-view-test--wait)
          (with-current-buffer (drgnx-replace-view-test--view) (should-not (drgnx-replace--opt :symbol))))))))

(defun drgnx-replace-view-test--bar () (get-buffer drgnx-replace-bar-buffer-name))

(defun drgnx-replace-view-test--key (key)
  "Press KEY in the find bar, point in its find field."
  (select-window (get-buffer-window (drgnx-replace-view-test--bar)))
  (with-current-buffer (drgnx-replace-view-test--bar)
    (goto-char (widget-field-start (drgnx-replace--widget 'find)))
    (execute-kbd-macro (kbd key))))

(defun drgnx-replace-view-test--current (buf)
  "Where the bar's current match starts in BUF."
  (let ((ov (seq-find (lambda (o) (eq (overlay-get o 'face) 'drgnx-replace-current)) (overlays-in (point-min) (point-max)))))
    (with-current-buffer buf (and ov (overlay-start ov)))))

(ert-deftest drgnx-replace/bar-highlights-and-steps ()
  (drgnx-replace-view-test--with
    (drgnx-git-test-with-repo
      (drgnx-git-test-write repo "f.txt" "foo bar foo\nFoo baz\nfoo\n")
      (let* ((buf (drgnx-replace-view-test--visit repo "f.txt" 1))
             (editor (selected-window))
             (matches (lambda () (with-current-buffer buf
                                   (sort (mapcar #'overlay-start
                                                 (seq-filter (lambda (o) (memq (overlay-get o 'face) '(drgnx-replace-match drgnx-replace-current)))
                                                             (overlays-in (point-min) (point-max))))
                                         #'<))))
             (current (lambda () (with-current-buffer buf (drgnx-replace-view-test--current buf)))))
        (drgnx-replace-in-file)
        ;; a two-line window above the editor
        (let ((w (get-buffer-window (drgnx-replace-view-test--bar))))
          (should (window-live-p w))
          (should (eq (window-in-direction 'below w) editor))
          (should (<= (window-body-height w) 2))
          (should-not (drgnx-signal-editor-window-p w)))
        (with-current-buffer (drgnx-replace-view-test--bar)
          (should (derived-mode-p 'drgnx-replace-bar-mode))
          (should (equal (widget-value (drgnx-replace--widget 'find)) "foo")))
        ;; every match highlighted (Aa off: Foo too), the one at point current
        (should (equal (funcall matches) '(1 9 13 21)))
        (should (equal (funcall current) 1))
        (drgnx-replace-view-test--key "RET")
        (should (equal (funcall current) 9))
        (should (= (window-point editor) 9))
        (drgnx-replace-view-test--key "RET")
        (drgnx-replace-view-test--key "S-<return>")
        (should (equal (funcall current) 9))
        (drgnx-replace-next)
        (should (equal (funcall current) 13))
        (drgnx-replace-prev)
        (drgnx-replace-prev)
        (drgnx-replace-prev)
        (should (equal (funcall current) 21))      ; wraps
        ;; Aa: case matters
        (with-current-buffer (drgnx-replace-view-test--bar) (drgnx-replace--toggle :case))
        (should (equal (funcall matches) '(1 9 21)))
        ;; C-RET replaces all, one undo step
        (with-current-buffer (drgnx-replace-view-test--bar)
          (widget-value-set (drgnx-replace--widget 'replace) "X"))
        (with-current-buffer buf (undo-boundary))
        (drgnx-replace-view-test--key "C-<return>")
        (should (equal (with-current-buffer buf (buffer-string)) "X bar X\nFoo baz\nX\n"))
        (should (buffer-modified-p buf))
        (should (equal (drgnx-replace-view-test--read (expand-file-name "f.txt" repo)) "foo bar foo\nFoo baz\nfoo\n"))
        (with-current-buffer buf (undo-boundary) (let ((last-command nil)) (undo)))
        (should (equal (with-current-buffer buf (buffer-string)) "foo bar foo\nFoo baz\nfoo\n"))
        ;; ESC closes the bar and its highlights
        (drgnx-replace-view-test--key "<escape>")
        (should-not (get-buffer-window (drgnx-replace-view-test--bar)))
        (should-not (funcall matches))
        (should (eq (selected-window) editor))))))

(ert-deftest drgnx-replace/bar-moves-to-the-sidebar ()
  (drgnx-replace-view-test--with
    (drgnx-git-test-with-repo
      (drgnx-git-test-write repo "f.txt" "foo food\nfoo\n")
      (drgnx-git-test-write repo "g.txt" "foo\n")
      (drgnx-replace-view-test--visit repo "f.txt" 1)
      (drgnx-replace-in-file)
      (with-current-buffer (drgnx-replace-view-test--bar)
        (drgnx-replace--toggle :word)
        (widget-value-set (drgnx-replace--widget 'replace) "bar")
        (drgnx-replace-bar-show-all))
      (should-not (get-buffer-window (drgnx-replace-view-test--bar)))
      (should (eq (drgnx-wb-sidebar-view) 'search))
      (with-current-buffer (drgnx-replace-view-test--view)
        (should (equal (widget-value (drgnx-replace--widget 'find)) "foo"))
        (should (equal (widget-value (drgnx-replace--widget 'replace)) "bar"))
        (should (drgnx-replace--opt :word))
        (should (eq (drgnx-replace--opt :scope) 'file)))
      (drgnx-replace-view-test--wait)
      (should (equal (drgnx-replace-view-test--files) '("f.txt")))
      (should (= (drgnx-replace-view-test--count) 2)))))

(ert-deftest drgnx-replace/ten-thousand-matches-stream ()
  :tags '(:timing)                                      ; wall-clock: a quiet machine
  (drgnx-replace-view-test--with
    (drgnx-git-test-with-repo
      (let ((text (apply #'concat (make-list 100 "a needle in the haystack, line after line\n"))))
        (dotimes (i 100) (drgnx-git-test-write repo (format "d/f%03d.txt" i) text)))
      (drgnx-replace-view-test--visit repo "d/f000.txt" 3)
      ;; three runs, each judged by its worst slice; the budgets hold for the median run: one slice the machine
      ;; stole (macOS CI: 32.1 ms once, 17.6 and 20.5 before) is not the view's, a slow slice in every run is
      (let* ((drawn (lambda () (with-current-buffer (drgnx-replace-view-test--view) drgnx-replace--drawn)))
             (watch (lambda (t0)
                      ;; until the view is idle: (FIRST-ROW-AFTER WORST-SLICE), from T0
                      (let ((first nil) (worst 0))
                        (while (and (with-current-buffer (drgnx-replace-view-test--view) (drgnx-replace--busy-p))
                                    (< (- (float-time) t0) 20))
                          (let ((s (float-time)) (gc gc-elapsed))
                            (accept-process-output nil 0.001)
                            ;; time spent in our filter, timers and drawing; a garbage collection is the GC
                            ;; policy's business
                            (setq worst (max worst (- (float-time) s (- gc-elapsed gc)))))
                          (when (and (not first) (> (funcall drawn) 0)) (setq first (- (float-time) t0))))
                        (list first worst))))
             (median (lambda (xs) (nth 1 (sort (copy-sequence xs) #'<))))
             (factor (drgnx-run-ert-time-factor))
             (firsts nil) (streams nil) (redraws nil))
        (dotimes (i 3)
          ;; each run the same: a new view, no replacement typed yet
          (when (> i 0) (kill-buffer (drgnx-replace-view-test--view)) (select-window (drgnx-wb-editor-window)))
          (let ((t0 (progn (garbage-collect) (float-time))))
            (drgnx-replace-in-files)              ; searches at once (no typing to wait for)
            (pcase-let ((`(,first ,worst) (funcall watch t0)))
              (should (= (funcall drawn) 10000))
              (should (= (drgnx-replace-view-test--count) 10000))
              (push first firsts)
              (push worst streams)))
          ;; typing a replacement draws all 10000 rows again (new previews): in slices too
          (drgnx-replace-view-test--set 'replace "pin")
          (push (cadr (funcall watch (float-time))) redraws)
          (should (= (funcall drawn) 10000)))
        (message "ten thousand matches: first row %S s, worst slice %S s streaming, %S s redrawing (factor %s)"
                 firsts streams redraws factor)
        (should (< (funcall median firsts) (* 0.1 factor)))
        (should (< (funcall median streams) (* 0.016 factor)))
        (should (< (funcall median redraws) (* 0.016 factor)))))))


;; fix round 1

(defun drgnx-replace-view-test--reply (a b)
  "A rename reply for foo: two uses in A's first line, one in B's (never A's comment)."
  (let ((edit (lambda (line char) (list :range (list :start (list :line line :character char)
                                                     :end (list :line line :character (+ char 3)))
                                        :newText "foo_drgnx_rename"))))
    (list :changes (list (intern (concat ":" (eglot-path-to-uri a))) (vector (funcall edit 0 7) (funcall edit 0 15))
                         (intern (concat ":" (eglot-path-to-uri b))) (vector (funcall edit 0 1))))))

(defmacro drgnx-replace-view-test--with-server (server requests reply &rest body)
  "BODY with a fake language server while SERVER (a variable) is non-nil, counting REQUESTS, answering REPLY."
  (declare (indent 3))
  `(cl-letf (((symbol-function 'eglot-current-server) (lambda () ,server))
             ((symbol-function 'eglot-server-capable) (lambda (&rest f) (equal f '(:renameProvider))))
             ((symbol-function 'eglot--signal-textDocument/didChange) #'ignore)
             ((symbol-function 'jsonrpc-request) (lambda (&rest _) (cl-incf ,requests) ,reply)))
     ,@body))

(defun drgnx-replace-view-test--highlights (buf)
  "Where the find bar's highlights start in BUF."
  (with-current-buffer buf
    (sort (mapcar #'overlay-start
                  (seq-filter (lambda (o) (memq (overlay-get o 'face) '(drgnx-replace-match drgnx-replace-current)))
                              (overlays-in (point-min) (point-max))))
          #'<)))

(ert-deftest drgnx-replace/bar-renames-the-symbol-in-its-file ()
  (drgnx-replace-view-test--with
    (drgnx-git-test-with-repo
      (drgnx-git-test-write repo "a.el" "(defun foo () (foo))\n;; foo in a comment\n")
      (drgnx-git-test-write repo "b.el" "(foo)\n")
      (let* ((a (expand-file-name "a.el" repo)) (b (expand-file-name "b.el" repo))
             (reply (drgnx-replace-view-test--reply a b)) (server 'fake) (requests 0)
             (buf (find-file-noselect a)))
        (find-file-noselect b)            ; visited before the fake server exists
        (drgnx-replace-view-test--with-server server requests reply
          (drgnx-replace-view-test--visit repo "a.el" 9)
          (drgnx-replace-in-file)
          (with-current-buffer (drgnx-replace-view-test--bar)
            (should (drgnx-replace--opt :symbol))
            (should (equal (widget-value (drgnx-replace--widget 'find)) "foo")))
          ;; the server's edits in this file are highlighted: not the comment's foo
          (should (equal (drgnx-replace-view-test--highlights buf) '(8 16)))
          (with-current-buffer (drgnx-replace-view-test--bar)
            (widget-value-set (drgnx-replace--widget 'replace) "bar"))
          (drgnx-replace-view-test--key "C-<return>")
          (should (equal (with-current-buffer buf (buffer-string)) "(defun bar () (bar))\n;; foo in a comment\n"))
          (should (equal (drgnx-replace-view-test--read b) "(foo)\n")))))))

(ert-deftest drgnx-replace/an-edited-buffer-refreshes-its-rows ()
  (drgnx-replace-view-test--with
    (drgnx-git-test-with-repo
      (drgnx-git-test-write repo "a.txt" "foo 1\nfoo 2\n")
      (drgnx-git-test-write repo "b.txt" "foo 3\n")
      (let* ((a (expand-file-name "a.txt" repo)) (buf (drgnx-replace-view-test--visit repo "a.txt" 1))
             (row (lambda (after) (lambda (v) (and (consp v) (equal (plist-get v :file) a) (equal (plist-get v :after) after)))))
             (view nil))
        (drgnx-replace-in-files)
        (setq view (drgnx-replace-view-test--view))
        (drgnx-replace-view-test--wait)
        (should (= (drgnx-replace-view-test--count) 3))
        (drgnx-replace-view-test--press-box (funcall row " 2"))
        ;; an unsaved edit above: after a pause the file's rows follow the buffer; the unticked match stays unticked
        (with-current-buffer buf (goto-char (point-min)) (insert "foo 0\nfoo 0b\n"))
        (with-current-buffer view (should (timerp drgnx-replace--refresh-timer)))
        (drgnx-replace-view-test--wait)
        (should (= (drgnx-replace-view-test--count) 5))
        (should (equal (drgnx-replace-view-test--box-at (funcall row " 2")) "[ ]"))
        (should (equal (drgnx-replace-view-test--box-at (funcall row " 1")) "[x]"))
        (should (= 4 (plist-get (with-current-buffer view (seq-find (funcall row " 2") drgnx-replace--matches)) :line)))
        ;; Replace All writes the buffer as it is now (left unsaved: it held the user's edits)
        (drgnx-replace-view-test--set 'replace "bar")
        (drgnx-replace-view-test--wait)
        (with-current-buffer view (drgnx-replace-all))
        (should (equal (with-current-buffer buf (buffer-string)) "bar 0\nbar 0b\nbar 1\nfoo 2\n"))
        (should (equal (drgnx-replace-view-test--read (expand-file-name "b.txt" repo)) "bar 3\n"))))))

(ert-deftest drgnx-replace/a-file-changed-on-disk-refreshes-its-rows ()
  (let ((watches nil) (removed nil) (n 0))
    ;; file-notify events do not reach a batch Emacs: the watches are recorded, their callbacks called by hand
    (cl-letf (((symbol-function 'file-notify-add-watch) (lambda (dir _flags cb) (push (list (cl-incf n) dir cb) watches) n))
              ((symbol-function 'file-notify-rm-watch) (lambda (d) (push d removed))))
      (drgnx-replace-view-test--with
        (drgnx-git-test-with-repo
          (drgnx-git-test-write repo "a.txt" "foo 1\n")
          (drgnx-git-test-write repo "sub/b.txt" "foo 2\n")
          (drgnx-replace-view-test--visit repo "a.txt" 1)
          (drgnx-replace-in-files)
          (drgnx-replace-view-test--wait)
          (should (= (drgnx-replace-view-test--count) 2))
          ;; the listed files' folders are watched
          (should (equal (sort (mapcar (lambda (w) (file-relative-name (nth 1 w) repo)) watches) #'string<) '("./" "sub/")))
          ;; an agent writes sub/b.txt
          (let ((b (expand-file-name "sub/b.txt" repo)))
            (write-region "foo 2\nfoo 3 foo\n" nil b nil 'silent)
            (dolist (w watches) (funcall (nth 2 w) (list (car w) 'changed b))))
          (drgnx-replace-view-test--wait)
          (should (= (drgnx-replace-view-test--count) 4))
          ;; a new search drops the watches (and watches again)
          (let ((ids (mapcar #'car watches)))
            (drgnx-replace-view-test--set 'find "fo")
            (drgnx-replace-view-test--wait)
            (should (cl-subsetp ids removed)))
          ;; so does killing the view, with the edit hook
          (let* ((view (drgnx-replace-view-test--view)) (ids (with-current-buffer view drgnx-replace--watches)))
            (should ids)
            (kill-buffer view)
            (should (cl-subsetp ids removed))
            (should-not (memq #'drgnx-replace--buffer-changed (default-value 'after-change-functions)))))))))

(ert-deftest drgnx-replace/symbol-falls-back-to-text ()
  (drgnx-replace-view-test--with
    (drgnx-git-test-with-repo
      (drgnx-git-test-write repo "a.el" "(defun foo () (foo))\n;; foo in a comment\n")
      (drgnx-git-test-write repo "b.el" "(foo)\n")
      (let* ((a (expand-file-name "a.el" repo)) (b (expand-file-name "b.el" repo))
             (reply (drgnx-replace-view-test--reply a b)) (server nil) (requests 0)
             (abuf (find-file-noselect a)))
        (find-file-noselect b)
        (drgnx-replace-view-test--with-server server requests reply
          ;; no server: pressing Symbol says why, and the text is searched
          (drgnx-replace-view-test--visit repo "a.el" 9)
          (drgnx-replace-in-files)
          (drgnx-replace-view-test--wait)
          (with-current-buffer (drgnx-replace-view-test--view)
            (should-not (drgnx-replace--opt :symbol))
            (drgnx-replace--toggle :symbol)
            (should-not (drgnx-replace--opt :symbol))
            (should (string-match-p "No language server" drgnx-replace--status)))
          (drgnx-replace-view-test--wait)
          (should (= (drgnx-replace-view-test--count) 4))
          (with-current-buffer (drgnx-replace-view-test--view)
            (should (string-match-p "No language server" drgnx-replace--status)))
          ;; a server: Rename Symbol lists its edits
          (setq server 'fake)
          (drgnx-replace-view-test--visit repo "a.el" 9)
          (drgnx-replace-rename-symbol)
          (drgnx-replace-view-test--wait)
          (should (= (drgnx-replace-view-test--count) 3))
          (should (= requests 1))
          ;; the code changes under it: the list says so and the server is not asked
          (with-current-buffer abuf (goto-char (point-max)) (insert ";; more\n"))
          (drgnx-replace-view-test--wait)
          (with-current-buffer (drgnx-replace-view-test--view)
            (should drgnx-replace--stale)
            (should (string-match-p "The code changed" drgnx-replace--status)))
          (should (= requests 1))
          ;; other text in Find: Symbol off, a text search
          (drgnx-replace-view-test--set 'find "foo in")
          (with-current-buffer (drgnx-replace-view-test--view)
            (should-not (drgnx-replace--opt :symbol))
            (should (widget-apply (drgnx-replace--widget :case) :active)))
          (drgnx-replace-view-test--wait)
          (should (= (drgnx-replace-view-test--count) 1))
          (should (= requests 1)))))))

(ert-deftest drgnx-replace/the-find-bar-is-never-saved-with-the-workbench ()
  ;; wb/drgnx-persist.el saves the main area with `window-state-get': the bar must not be in it
  (require 'drgnx-persist)
  (drgnx-replace-view-test--with
    (drgnx-git-test-with-repo
      (drgnx-git-test-write repo "f.txt" "foo\n")
      (let ((drgnx-persist-file (expand-file-name "state.eld" tmp)))
        (drgnx-replace-view-test--visit repo "f.txt" 1)
        (drgnx-replace-in-file)
        (should (get-buffer-window (drgnx-replace-view-test--bar)))
        (drgnx-persist-save)
        (should-not (get-buffer-window (drgnx-replace-view-test--bar)))
        (should-not (string-search drgnx-replace-bar-buffer-name (drgnx-replace-view-test--read drgnx-persist-file)))))))

(ert-deftest drgnx-replace/a-save-that-writes-nothing-leaves-the-find-bar-open ()
  ;; Save Workbench Layout in a terminal window does nothing, so it must not close the bar either
  (require 'drgnx-persist)
  (drgnx-replace-view-test--with
    (drgnx-git-test-with-repo
      (drgnx-git-test-write repo "f.txt" "foo\n")
      (let ((drgnx-persist-file (expand-file-name "state.eld" tmp)))
        (drgnx-replace-view-test--visit repo "f.txt" 1)
        (drgnx-replace-in-file)
        (should (get-buffer-window (drgnx-replace-view-test--bar)))
        (cl-letf (((symbol-function 'terminal-name) (lambda (&optional _) "/dev/pts/9"))
                  ((symbol-function 'message) #'ignore))
          (drgnx-persist-save))
        (should (get-buffer-window (drgnx-replace-view-test--bar)))
        (should-not (file-exists-p drgnx-persist-file))))))

(ert-deftest drgnx-replace/a-client-closing-saves-the-graphical-windows-and-closes-the-bar-from-a-terminal-selection ()
  ;; the save when a client's last graphical windows close passes them explicitly: a terminal window being the
  ;; selected frame does not stop it, nor the bar closing before it
  (require 'drgnx-persist)
  (drgnx-replace-view-test--with
    (drgnx-git-test-with-repo
      (drgnx-git-test-write repo "f.txt" "foo\n")
      (let ((drgnx-persist-file (expand-file-name "state.eld" tmp)) (drgnx-persist--saved-at-exit nil))
        (drgnx-replace-view-test--visit repo "f.txt" 1)
        (drgnx-replace-in-file)
        (should (get-buffer-window (drgnx-replace-view-test--bar)))
        (set-frame-parameter nil 'client 'proc)
        (unwind-protect
            (cl-letf (((symbol-function 'terminal-name) (lambda (&optional _) "/dev/pts/9"))
                      ((symbol-function 'display-graphic-p) (lambda (&optional f) (and f t))))   ; the selected frame is text, the saved ones not
              (drgnx-persist--before-client-delete 'proc))
          (set-frame-parameter nil 'client nil))
        (should-not (get-buffer-window (drgnx-replace-view-test--bar)))
        (should (file-exists-p drgnx-persist-file))))))

(ert-deftest drgnx-replace/an-error-closing-the-bar-never-stops-the-save ()
  ;; The find bar's `drgnx-persist-save' advice runs on every exit: it must not make the save fail.
  (require 'drgnx-persist)
  (drgnx-replace-view-test--with
    (let ((drgnx-persist-file (expand-file-name "state.eld" (make-temp-file "drgnx-replace-save" t))))
      (unwind-protect
          (progn
            (get-buffer-create drgnx-replace-bar-buffer-name)
            (cl-letf (((symbol-function 'drgnx-replace--bar-clear) (lambda () (error "the bar is broken"))))
              (should (file-exists-p (drgnx-persist-save))))
            (should (drgnx-persist--read drgnx-persist-file)))
        (when (get-buffer drgnx-replace-bar-buffer-name) (kill-buffer drgnx-replace-bar-buffer-name))
        (delete-directory (file-name-directory drgnx-persist-file) t)))))

(ert-deftest drgnx-replace/show-all-is-the-bars-button-not-a-command ()
  ;; It needs the find bar and is reached by its button: not an interactive command outside the registry.
  (should-not (commandp 'drgnx-replace-bar-show-all)))

;;; mod-replace-view-test.el ends here

(ert-deftest drgnx-replace/setup-registers-and-off-takes-it-all-back ()
  ;; The view provider, the persist advice and the Vim-profile hook were top-level forms; now the module's own.
  (let ((evil (length (cdr (assoc 'evil after-load-alist)))))
    (drgnx-test-with-modules '(tools/replace) :strict t
                             (should (eq (alist-get 'search drgnx-wb-view-providers) #'drgnx-replace--provide-view))
                             (should (advice-member-p #'drgnx-replace--close-bars 'drgnx-persist-save))
                             (should (= (length (cdr (assoc 'evil after-load-alist))) (1+ evil))))
    (should-not (alist-get 'search drgnx-wb-view-providers))
    (should-not (advice-member-p #'drgnx-replace--close-bars 'drgnx-persist-save))
    (should (= (length (cdr (assoc 'evil after-load-alist))) evil))))
