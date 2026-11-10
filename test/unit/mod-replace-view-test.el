;;; mod-replace-view-test.el --- batch tests: the Search view in the sidebar and the find bar -*- lexical-binding: t -*-
;; test-class: cond
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx)
(require 'eglot)
(require 'drgnx-wb)
(load (expand-file-name "test/fixtures/git-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/view-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
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
  `(drgnx-test-with-state
     (let ((drgnx-wb--sections nil)
           (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
           (drgnx-replace-view-test--types drgnx-view--types)) ; the section defines the rows' view type
       (advice-add 'drgnx-persist-save :before #'drgnx-replace--close-bars)   ; the module's setup does
       (delete-other-windows)
       (set-frame-parameter nil 'drgnx-wb-view nil)
       (drgnx-replace--define-section)
       (drgnx-replace--define-commands)
       (drgnx-state-define-role 'bar)                  ; the module's setup does (`drgnx-replace/setup-defines-the-bar-role')
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
           (when (get-buffer b) (kill-buffer b)))
         (setq drgnx-view--types drgnx-replace-view-test--types)))))

(defun drgnx-replace-view-test--view () (get-buffer drgnx-replace-buffer-name))

(defun drgnx-replace-view-test--wait (&optional pred)
  "Wait (`drgnx-test-wait') until PRED holds, by default until the view is idle (no timer, search or drawing pending)."
  (should (drgnx-test-wait (or pred (lambda () (with-current-buffer (drgnx-replace-view-test--view) (not (drgnx-replace--busy-p)))))
                           :what "the Search view's condition")))

(defun drgnx-replace-view-test--set (name value)
  "Type VALUE into the view's field NAME (as the user would: the field's change hooks run)."
  (with-current-buffer (drgnx-replace-view-test--view)
    (widget-value-set (drgnx-replace--widget name) value)))

(defun drgnx-replace-view-test--count ()
  (with-current-buffer (drgnx-replace-view-test--view) (length drgnx-replace--matches)))

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

(ert-deftest drgnx-replace/setup-defines-the-bar-role ()
  "The find bar's role is the module's: its setup defines `bar' in the store's role table, its teardown removes it."
  (drgnx-test-with-state
    (let* ((cfg (make-temp-file "drgnx-cfg" t))
           (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
           (drgnx-modules--report nil) (drgnx-modules--state nil) (drgnx-modules--stacks nil) (drgnx-modules--runs nil)
           (drgnx-module--claims (make-hash-table :test 'equal))
           (drgnx-wb--sections nil)
           (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
      (unwind-protect
          (progn
            (drgnx-state-undefine-role 'bar)
            (should-not (drgnx-modules--run-setup 'tools/replace (plist-get (alist-get 'tools/replace drgnx-modules--table) :setup)))
            (drgnx-modules--record 'tools/replace 'idle 0 'ok)
            (should (assq 'bar drgnx-state--roles))
            (should-not (drgnx-module-teardown 'tools/replace))
            (should-not (assq 'bar drgnx-state--roles)))
        (delete-directory cfg t)))))

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

(ert-deftest drgnx-replace/view-search-works-as-soon-as-the-startup-stage-ran ()
  ;; C-S-f in the first second: the module sets up in the startup stage, so the view exists (no provider, no
  ;; "No search view").  Strict: the opened view and the bar are the module's :teardown's to take away.
  (delete-other-windows)
  (set-frame-parameter nil 'drgnx-wb-view nil)
  (drgnx-test-with-modules '(tools/replace) :strict t
                           (should (eq (plist-get (cdr (assq 'tools/replace drgnx-modules--table)) :stage) 'startup))
                           (call-interactively #'drgnx-wb-view-search)
                           (should (eq (selected-window) (drgnx-wb-section-window 'search)))
                           (with-current-buffer (drgnx-replace-view-test--view)
                             (should (eq (widget-field-at (point)) (drgnx-replace--widget 'find))))
                           (drgnx-git-test-with-repo
                             (drgnx-git-test-write repo "f.txt" "foo\n")
                             (drgnx-replace-view-test--visit repo "f.txt" 1)
                             (drgnx-replace-in-file)
                             (should (get-buffer-window (drgnx-replace-view-test--bar)))))
  (should-not (get-buffer drgnx-replace-buffer-name))
  (should-not (get-buffer drgnx-replace-bar-buffer-name))
  (set-frame-parameter nil 'drgnx-wb-view nil)
  (delete-other-windows))

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
      ;; the view searches (the hub's search/run: replace-rows-test.el); the hub is not up here
      (with-current-buffer (drgnx-replace-view-test--view)
        (should (or drgnx-replace--waiting (not (fboundp 'nidhogg-view--call))))))))

;;;; The rows on a view (wb/drgnx-view.el), on the virtual clock

(defvar drgnx-replace-view-test--reads 0 "How many times the replaced `drgnx-timer-now' was read.")

(defmacro drgnx-replace-view-test--ticking (step &rest body)
  "BODY with `drgnx-timer-now' returning 1000 + STEP × the reads so far: each read costs STEP seconds."
  (declare (indent 1))
  `(let ((drgnx-replace-view-test--reads 0))
     (cl-letf (((symbol-function 'drgnx-timer-now)
                (lambda () (prog1 (+ 1000.0 (* drgnx-replace-view-test--reads ,step))
                             (setq drgnx-replace-view-test--reads (1+ drgnx-replace-view-test--reads))))))
       ,@body)))

(defmacro drgnx-replace-view-test--fed (&rest body)
  "BODY on the virtual clock with the Search view shown in the sidebar and empty: `dir' its root (a temp folder),
`view' its buffer, `v' its view: the view's own rows, as Symbol mode lists the server's edits.  Nothing searches:
BODY feeds matches through `drgnx-replace--add'."
  (declare (indent 0))
  `(drgnx-replace-view-test--with
     (let ((dir (file-name-as-directory (make-temp-file "drgnx-replace-view" t))) (drgnx-view--deadline nil))
       (unwind-protect
           (drgnx-test-with-clock (:allow-pending t)
             (let* ((view (drgnx-replace--view-buffer)) (v (buffer-local-value 'drgnx-view view)))
               (ignore v)
               (drgnx-wb-show-view 'search)
               (with-current-buffer view (setq drgnx-replace--root dir))
               ,@body))
         (delete-directory dir t)))))

(defun drgnx-replace-view-test--matches (dir from to lines &optional text)
  "LINES matches of TEXT (default: a needle line) in each of the files DIR/d/fNNN.txt, NNN from FROM below TO, in
file order, as a search sends them."
  (let ((text (or text "a needle in the haystack, line after line")) (out nil))
    (dotimes (k (- to from))
      (let ((file (expand-file-name (format "d/f%03d.txt" (+ from k)) dir)))
        (dotimes (l lines) (push (drgnx-replace--match file (1+ l) text 2 8) out))))
    (nreverse out)))

(defun drgnx-replace-view-test--feed (view ms)
  "MS come to VIEW's own rows in one batch."
  (with-current-buffer view (drgnx-replace--add (copy-sequence ms))))

(defun drgnx-replace-view-test--fresh-p (view)
  "VIEW's rows are what a fresh render of its keys gives, and its starts are right."
  (with-current-buffer view
    (should-not (drgnx-view--check drgnx-view))
    (should (equal (drgnx-view-test--expected drgnx-view) (drgnx-view-test--text drgnx-view)))))

(defun drgnx-replace-view-test--stat (v name) (plist-get (drgnx-view-stats v) name))

(defun drgnx-replace-view-test--keys (v)
  "VIEW V's row keys, in order."
  (let (out) (dotimes (i (drgnx-view-row-count v)) (push (aref (drgnx-view--keys v) i) out)) (nreverse out)))

(ert-deftest drgnx-replace/ten-thousand-matches-stream ()
  ;; REPLACE-REDRAW-1 (the macOS CI failure): typing a replacement erased all 10k rows in one `delete-region' and
  ;; drew them again.  Now, on the virtual clock, each `drgnx-timer-now' read costing 0.056 ms (8 rows at the
  ;; probe's 7 µs): no slice draws more than 576 rows, the retype patches exactly the 10,000 match rows in place
  ;; (headers untouched, no full draw), and the rows the window shows are in its first slice.
  (drgnx-replace-view-test--fed
    (let* ((ms (drgnx-replace-view-test--matches dir 0 100 100)) (slices nil) (w (get-buffer-window view))
           (orig (symbol-function 'drgnx-replace--rows-drawn)))
      (cl-letf (((symbol-function 'drgnx-replace--rows-drawn)
                 (lambda (vw keys) (push keys slices) (funcall orig vw keys))))
        (drgnx-replace-view-test--ticking 0.000056
          ;; 100 batches, each across two files (a search's output chunks), time passing between them
          (let ((start 0) (rest ms))
            (dolist (end (append (number-sequence 50 9850 100) (list 10000)))
              (drgnx-replace-view-test--feed view (take (- end start) rest))
              (setq rest (nthcdr (- end start) rest) start end)
              (drgnx-test-advance 0.01)))
          (should (= 10100 (drgnx-view-row-count v)))      ; 100 headers, 10,000 rows
          (should-not (drgnx-view-pending-p v))
          (should (= 0 (drgnx-replace-view-test--stat v :full-draws)))
          (drgnx-replace-view-test--fresh-p view)
          ;; the window halfway down the list; then a replacement is typed
          (set-window-start w (drgnx-view-row-start v (nth 5000 ms)))
          (let ((drawn (drgnx-replace-view-test--stat v :rows-drawn))
                (visible (let (out)
                           (pcase-dolist (`(,from . ,to) (drgnx-view--visible-ranges v))
                             (cl-loop for i from from below (min to (drgnx-view-row-count v))
                                      for key = (aref (drgnx-view--keys v) i)
                                      unless (eq (car key) 'drgnx-replace-file) do (push key out)))
                           out)))
            (should visible)
            (setq slices nil)
            (drgnx-replace-view-test--set 'replace "pin")
            (drgnx-test-advance drgnx-replace-delay)        ; the pause, then every slice at once
            (should (= 10000 (- (drgnx-replace-view-test--stat v :rows-drawn) drawn)))
            (should (= 0 (drgnx-replace-view-test--stat v :full-draws)))
            (should (<= (drgnx-replace-view-test--stat v :max-slice-rows) 576))
            (should (> (length slices) 1))
            (let ((first (car (last slices))))
              (dolist (key visible) (should (memq key first))))
            (should-not (drgnx-view-pending-p v))
            (drgnx-replace-view-test--fresh-p view)
            (with-current-buffer view
              (should (string-search "needlepin" (buffer-substring-no-properties (window-start w) (point-max)))))))))))

(ert-deftest drgnx-replace/a-late-match-joins-its-file ()
  ;; a match of a file listed already goes after that file's last row, not at the end
  (drgnx-replace-view-test--fed
    (let ((a (drgnx-replace-view-test--matches dir 0 1 3)) (b (drgnx-replace-view-test--matches dir 1 2 2)))
      (drgnx-replace-view-test--feed view (append (take 2 a) b))
      (drgnx-test-advance 0.01)
      (drgnx-replace-view-test--feed view (last a))
      (drgnx-test-advance 0.01)
      (let ((keys (drgnx-replace-view-test--keys v)))
        (should (= 7 (length keys)))
        (should (equal (cdr (take 4 keys)) a))
        (should (equal (nthcdr 5 keys) b)))
      (drgnx-replace-view-test--fresh-p view))))

(ert-deftest drgnx-replace/a-new-search-resets-in-slices ()
  (drgnx-replace-view-test--fed
    (drgnx-replace-view-test--ticking 0.000056
      (drgnx-replace-view-test--feed view (drgnx-replace-view-test--matches dir 0 20 100))
      (drgnx-test-advance 0.01)
      (should (= 2020 (drgnx-view-row-count v)))
      ;; a new search: the rows go a slice at a time, never in one erase
      (with-current-buffer view
        (drgnx-replace--clear)
        (drgnx-replace--add (drgnx-replace-view-test--matches dir 50 51 3 "another needle")))
      (drgnx-view--draw-buffer view)
      (let ((removed (drgnx-replace-view-test--stat v :removed)))
        (should (> removed 0))
        (should (< removed 2020)))
      (with-current-buffer view (should-not (drgnx-view--check drgnx-view)))
      (drgnx-test-advance 0)
      (should (= 2020 (drgnx-replace-view-test--stat v :removed)))
      (should (= 0 (drgnx-replace-view-test--stat v :full-draws)))
      (should (<= (drgnx-replace-view-test--stat v :max-slice-rows) 576))
      (should (= 4 (drgnx-view-row-count v)))
      (drgnx-replace-view-test--fresh-p view))))

(ert-deftest drgnx-replace/the-view-keeps-its-place-when-rows-above-change ()
  (drgnx-replace-view-test--fed
    (let ((ms (drgnx-replace-view-test--matches dir 0 10 10)) (w (get-buffer-window view)))
      (drgnx-replace-view-test--feed view ms)
      (drgnx-test-advance 0.01)
      (let ((key (nth 75 ms)))
        (set-window-start w (drgnx-view-row-start v key))
        (set-window-point w (+ 4 (drgnx-view-row-start v key)))
        ;; rows arrive above it (file 0's), and file 1's rows go: the window stays on its row
        (drgnx-replace-view-test--feed view (list (drgnx-replace--match (plist-get (car ms) :file) 99 "needle late" 0 6)))
        (with-current-buffer view (drgnx-view-remove drgnx-view (take 10 (nthcdr 10 ms))))
        (drgnx-test-advance 0.01)
        (should (= (window-start w) (drgnx-view-row-start v key)))
        (should (= (window-point w) (+ 4 (drgnx-view-row-start v key))))
        (with-current-buffer view (should (eq (drgnx-view-key-at (window-start w)) key)))))))

(defun drgnx-replace-view-test--markers (buffer)
  "How many markers into BUFFER its buffer-local variables reach (through conses, vectors, records, hash tables)."
  (let ((seen (make-hash-table :test #'eq)) (found (make-hash-table :test #'eq))
        (stack (mapcar (lambda (b) (if (consp b) (cdr b) nil)) (buffer-local-variables buffer))))
    (while stack
      (let ((x (pop stack)))
        (unless (or (null x) (symbolp x) (numberp x) (stringp x) (bufferp x) (gethash x seen))
          (puthash x t seen)
          (cond ((markerp x) (when (eq (marker-buffer x) buffer) (puthash x t found)))
                ((consp x) (push (car x) stack) (push (cdr x) stack))
                ((or (vectorp x) (recordp x))
                 (let ((i 0)) (while (ignore-errors (progn (push (aref x i) stack) t)) (setq i (1+ i)))))
                ((hash-table-p x) (maphash (lambda (k val) (push k stack) (push val stack)) x))))))
    (hash-table-count found)))

(ert-deftest drgnx-replace/no-marker-per-file ()
  ;; the view's START is its only marker: 30 files listed add none to what the fields and the status line hold
  (drgnx-replace-view-test--fed
    (let ((before (drgnx-replace-view-test--markers view)))
      (drgnx-replace-view-test--feed view (drgnx-replace-view-test--matches dir 0 30 2))
      (drgnx-test-advance 0.01)
      (should (= 90 (drgnx-view-row-count v)))
      (should (= before (drgnx-replace-view-test--markers view))))))

(ert-deftest drgnx-replace/a-hidden-view-catches-up-when-shown ()
  (drgnx-replace-view-test--fed
    (drgnx-view-test-store-on)                          ; views follow the store, as in the workbench
    (drgnx-wb-hide-sidebar)
    (drgnx-state-sync)                                  ; what a command's end runs
    (should-not (get-buffer-window view))
    (drgnx-replace-view-test--feed view (drgnx-replace-view-test--matches dir 0 5 4))
    (drgnx-test-advance 0.01)
    ;; hidden: nothing drawn
    (should (= 0 (drgnx-replace-view-test--stat v :rows-drawn)))
    (should (= 0 (drgnx-view-row-count v)))
    (should (drgnx-view-pending-p v))
    ;; shown again: the store sees it (a command's end or redisplay observes; batch Emacs has neither)
    (drgnx-wb-show-view 'search)
    (drgnx-state-sync)
    (drgnx-test-advance 0)
    (should (= 25 (drgnx-view-row-count v)))
    (should-not (drgnx-view-pending-p v))
    (drgnx-replace-view-test--fresh-p view)))


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
          ;; no server: pressing Symbol says why, and the text is searched (through the hub, which is not up here)
          (drgnx-replace-view-test--visit repo "a.el" 9)
          (drgnx-replace-in-files)
          (drgnx-replace-view-test--wait)
          (with-current-buffer (drgnx-replace-view-test--view)
            (should-not (drgnx-replace--opt :symbol))
            (drgnx-replace--toggle :symbol)
            (should-not (drgnx-replace--opt :symbol))
            (should (string-match-p "No language server" drgnx-replace--status)))
          (drgnx-replace-view-test--wait)
          (with-current-buffer (drgnx-replace-view-test--view)
            (should (string-match-p "No language server" drgnx-replace--status))
            (should (or drgnx-replace--waiting (not (fboundp 'nidhogg-view--call)))))
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
          (should (= (drgnx-replace-view-test--count) 0))         ; the server's edits are gone; the hub has the text
          (with-current-buffer (drgnx-replace-view-test--view)
            (should (or drgnx-replace--waiting (not (fboundp 'nidhogg-view--call)))))
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
        (let ((proc (make-pipe-process :name "drgnx-test-client" :noquery t)))
          (process-put proc 'frame (selected-frame))     ; the client made a frame, as server.el records it
          (set-frame-parameter nil 'client proc)
          (unwind-protect
              (cl-letf (((symbol-function 'terminal-name) (lambda (&optional _) "/dev/pts/9"))
                        ((symbol-function 'display-graphic-p) (lambda (&optional f) (and f t))))   ; the selected frame is text, the saved ones not
                (drgnx-persist--before-client-delete proc))
            (set-frame-parameter nil 'client nil)
            (delete-process proc)))
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

(ert-deftest drgnx-replace/setup-registers-and-off-takes-it-all-back ()
  ;; The persist advice and the Vim-profile initial states were top-level forms; now the module's own, and
  ;; the states go back also when evil had loaded (the Vim profile).
  (let ((states (list (cons 'drgnx-replace-mode 'normal))))
    (unwind-protect
        (cl-letf (((symbol-function 'evil-initial-state) (lambda (m &rest _) (alist-get m states)))
                  ((symbol-function 'evil-set-initial-state) (lambda (m s) (setf (alist-get m states) s))))
          (provide 'evil)
          (drgnx-test-with-modules '(tools/replace) :strict t
                                   (should (advice-member-p #'drgnx-replace--close-bars 'drgnx-persist-save))
                                   (should (eq (alist-get 'drgnx-replace-mode states) 'emacs))
                                   (should (eq (alist-get 'drgnx-replace-bar-mode states) 'emacs)))
          (should-not (advice-member-p #'drgnx-replace--close-bars 'drgnx-persist-save))
          (should (eq (alist-get 'drgnx-replace-mode states) 'normal))
          (should-not (alist-get 'drgnx-replace-bar-mode states)))
      (setq features (delq 'evil features)))))

;;; mod-replace-view-test.el ends here
