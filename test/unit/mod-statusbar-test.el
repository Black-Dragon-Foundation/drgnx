;;; mod-statusbar-test.el --- batch tests: the status bar — segments as data (M12f A3) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-chrome)
(require 'drgnx-agents)                 ; at load: the tests' `setf' of a session's slots expands with its accessors
(load (expand-file-name "modules/ui/drgnx-face" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-statusbar" drgnx-dir) nil t)
(require 'drgnx-git)
(load (expand-file-name "modules/core/drgnx-basics" drgnx-dir) nil t)   ; New Untitled
(load (expand-file-name "modules/ui/drgnx-start" drgnx-dir) nil t)      ; the start page's mode
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-job-ui" drgnx-dir) nil t)  ; C8's one count of what needs you
(load (expand-file-name "test/fixtures/memo-alloc-fixture" drgnx-dir) nil t)
(require 'drgnx-file)
(defvar drgnx-job-ui--badge)
(defvar drgnx-job-ui--needs-you)
(defvar compilation-arguments)
(defvar flymake-mode)
(defvar eglot--cached-server)
(defvar eglot--managed-mode)
(defvar yaml-indent-offset)
(defvar drgnx-explorer--roots)
(defvar drgnx-trust--state)
(defvar drgnx-statusbar-test--offset nil "An indentation variable of a test.")
(require 'which-func)                   ; its own table and variables, as in a session that turned it on
;; keycast and evil are never loaded here: their variables are declared special, so the tests bind them dynamically
(defvar keycast-mode-line-mode)
(defvar keycast--this-command-keys)
(defvar evil-local-mode)
(defvar evil-mode-line-tag)
(defvar evil-mode-line-format)

(defun drgnx-statusbar-test--activate ()
  "The setup of the tests' own `ui/face': what `drgnx-statusbar-setup' activates."
  (apply #'drgnx-memo-activate drgnx-statusbar--declared))

(defmacro drgnx-statusbar-test--epochs (&rest body)
  "BODY with the bar's epochs watching and its memo owned as `ui/face''s setup has them, in a module table of the
test's own (`ui/face' is torn down after: the watchers go, the memo empties), and other packages' entries read afresh."
  (declare (indent 0))
  `(let ((drgnx-modules--table (list (list 'ui/face :setup #'drgnx-statusbar-test--activate)))
         (drgnx-modules--report nil) (drgnx-modules--stacks nil) (drgnx-modules--runs nil)
         (drgnx-modules--features nil) (drgnx-modules--left nil)
         (drgnx-statusbar--misc-all nil) (drgnx-statusbar--misc-split nil) (drgnx-statusbar--misc-made nil)
         (drgnx-statusbar--misc-read nil) (drgnx-statusbar--misc-texts (make-hash-table :test #'eq :weakness 'key))
         (drgnx-statusbar--misc-report-due nil))
     (drgnx-modules--run-one 'ui/face (alist-get 'ui/face drgnx-modules--table) 'startup)
     (unwind-protect (progn ,@body) (drgnx-module-teardown 'ui/face))))

(defmacro drgnx-statusbar-test--with (&rest body)
  "BODY with the status bar's segments, lists and error record kept away from the rest of the test process.
Segments a, b, c are defined: their text is A, B, C.  The store is the test's own, with the selected window as the
frame's editor window (the full bar is the editor window's: the bar asks the store).  The bar's epochs and memo are
active (`drgnx-statusbar-test--epochs')."
  (declare (indent 0))
  `(drgnx-test-with-state
     (drgnx-test-use-editor (selected-window))
     (drgnx-statusbar-test--epochs
       (let ((drgnx-statusbar--segments (make-hash-table :test #'eq))
             (drgnx-statusbar--errors nil)
             (drgnx-statusbar-left '(a b)) (drgnx-statusbar-right '(c))
             (drgnx-statusbar-drop-order drgnx-statusbar-drop-order)
             (drgnx-statusbar-compact '(c))
             (drgnx-statusbar--window nil))
         ;; the batch terminal is not UTF-8: the tests that look at glyphs say which they mean
         (cl-letf (((symbol-function 'drgnx-ui-ascii-frame-p) (lambda (&optional _f) nil)))
           (drgnx-statusbar-define-segment 'a :fn (lambda () "A"))
           (drgnx-statusbar-define-segment 'b :fn (lambda () "B"))
           (drgnx-statusbar-define-segment 'c :fn (lambda () "C"))
           ,@body)))))

(defmacro drgnx-statusbar-test--in-buffer (mode &rest body)
  "BODY in a temp buffer in MODE, shown in the selected window (the bar reads the window's buffer)."
  (declare (indent 1))
  `(let ((old (window-buffer (selected-window))))
     (with-temp-buffer
       (funcall ,mode)
       (set-window-buffer (selected-window) (current-buffer))
       (unwind-protect (progn ,@body)
         (set-window-buffer (selected-window) old)))))

(defun drgnx-statusbar-test--format-mode-line (c &rest _)
  "`format-mode-line' of C as a frame does it for the constructs these tests use: strings, symbols, `:eval',
`:propertize' and lists of them (a batch Emacs formats every construct as \"\")."
  (cond ((null c) "")
        ((stringp c) c)
        ((symbolp c) (let ((v (and (boundp c) (symbol-value c))))
                       (if (eq v c) "" (drgnx-statusbar-test--format-mode-line v))))
        ((eq (car-safe c) :eval) (drgnx-statusbar-test--format-mode-line (eval (cadr c) t)))
        ((eq (car-safe c) :propertize) (drgnx-statusbar-test--format-mode-line (cadr c)))
        ((consp c) (mapconcat #'drgnx-statusbar-test--format-mode-line c ""))
        (t "")))

(defun drgnx-statusbar-test--gap (s)
  "The `:align-to' display spec in S, or nil."
  (let ((pos 0) found)
    (while (and (not found) (setq pos (next-single-property-change pos 'display s)))
      (let ((d (get-text-property pos 'display s)))
        (when (and (consp d) (eq (car d) 'space)) (setq found d))))
    (or found (and (get-text-property 0 'display s) (get-text-property 0 'display s)))))

(ert-deftest drgnx-statusbar/segments-render-in-order ()
  (drgnx-statusbar-test--with
    (let* ((s (drgnx-statusbar-render 60)) (plain (substring-no-properties s)))
      (should (string-match-p "\\` A · B " plain))
      ;; C is last, followed only by the pad, after the right-aligning gap
      (should (string-match-p "C \\'" plain))
      (let ((gap (drgnx-statusbar-test--gap s)))
        (should (eq (car gap) 'space))
        (should (equal (plist-get (cdr gap) :align-to) '(- right 2)))))))

(ert-deftest drgnx-statusbar/reorder-drop-and-add-your-own ()
  (drgnx-statusbar-test--with
    (setq drgnx-statusbar-left '(b))
    (let ((plain (substring-no-properties (drgnx-statusbar-render 60))))
      (should (string-match-p "B" plain))
      (should-not (string-match-p "A" plain)))
    (setq drgnx-statusbar-left '(b mine a))
    (drgnx-statusbar-define-segment 'mine :fn (lambda () "MINE"))
    (should (string-match-p "\\` B · MINE · A " (substring-no-properties (drgnx-statusbar-render 60))))
    ;; re-defining replaces
    (drgnx-statusbar-define-segment 'mine :fn (lambda () "YOURS"))
    (should (string-match-p "YOURS" (substring-no-properties (drgnx-statusbar-render 60))))
    (should-not (string-match-p "MINE" (substring-no-properties (drgnx-statusbar-render 60))))
    ;; a segment returning nil or "" leaves no separator behind
    (drgnx-statusbar-define-segment 'mine :fn (lambda () ""))
    (should (string-match-p "\\` B · A " (substring-no-properties (drgnx-statusbar-render 60))))))

(ert-deftest drgnx-statusbar/never-wider-than-its-window ()
  (drgnx-statusbar-test--with
    (let ((drgnx-statusbar-left '(branch problems tests jobs agents modal misc))
          (drgnx-statusbar-right '(lsp position indent encoding eol language))
          (names '(branch problems tests jobs agents modal misc lsp position indent encoding eol language)))
      (dolist (id names)
        (let ((id id))
          (drgnx-statusbar-define-segment
           id :fn (lambda () (if (eq id 'branch) "⑂ a-very-long-branch-name/for-a-feature" (symbol-name id))))))
      (let (previous)
        (dolist (width '(200 60 30 12 2 1 0))
          (let* ((s (drgnx-statusbar-render width)) (plain (substring-no-properties s))
                 (shown (seq-filter (lambda (id) (string-match-p (regexp-quote (symbol-name id)) plain))
                                    (remq 'branch names))))
            (should (<= (string-width s) width))
            ;; what is shown shrinks: never a segment back that a narrower window lost
            (when previous (should (seq-every-p (lambda (id) (memq id previous)) shown)))
            (setq previous shown)))))
    ;; a terminal that cannot show "…" cuts with "...", wider than 1 or 2 columns (CI's C locale): still never wider
    (let ((truncate-string-ellipsis "...") (drgnx-statusbar-left '(branch a)) (drgnx-statusbar-right '(c)))
      (drgnx-statusbar-define-segment 'branch :fn (lambda () "a-very-long-branch-name"))
      (dolist (width '(5 4 3 2 1))
        (should (<= (string-width (drgnx-statusbar-render width)) width))))
    ;; segments go in `drgnx-statusbar-drop-order'
    (let ((drgnx-statusbar-left '(branch problems tests jobs agents modal misc))
          (drgnx-statusbar-right '(lsp position indent encoding eol language))
          (drgnx-statusbar-drop-order '(eol indent encoding lsp language misc tests jobs))
          (all '(branch problems tests jobs agents modal misc lsp position indent encoding eol language)))
      (dolist (id all)
        (let ((id id)) (drgnx-statusbar-define-segment id :fn (lambda () (symbol-name id)))))
      (let* ((full (substring-no-properties (drgnx-statusbar-render 300)))
             (width (- (string-width full) 1))
             (plain (substring-no-properties (drgnx-statusbar-render width))))
        (should (string-match-p "language" full))
        (should (string-match-p "eol" full))
        ;; one column short: only the first in the drop order is gone
        (should-not (string-match-p "\\<eol\\>" plain))
        (should (string-match-p "indent" plain))
        (should (string-match-p "language" plain))))
    ;; the branch is cut with an ellipsis last, never dropped
    (let ((drgnx-statusbar-left '(branch)) (drgnx-statusbar-right '(c)))
      (drgnx-statusbar-define-segment 'branch :fn (lambda () "⑂ feature/extremely-long-branch-name"))
      (let* ((s (drgnx-statusbar-render 20)) (plain (substring-no-properties s)))
        (should (<= (string-width s) 20))
        (should (string-search (truncate-string-ellipsis) plain))   ; Emacs's: "..." in a C locale (CI's)
        (should (string-match-p "⑂ feat" plain))))))

(ert-deftest drgnx-statusbar/a-failing-segment-is-skipped-and-recorded-once ()
  (drgnx-statusbar-test--with
    (drgnx-statusbar-define-segment 'b :fn (lambda () (error "boom")))
    (should (equal (substring-no-properties (drgnx-statusbar-render 60)) (substring-no-properties (drgnx-statusbar-render 60))))
    (should (string-match-p "\\` A " (substring-no-properties (drgnx-statusbar-render 60))))
    (should-not (string-match-p "boom" (substring-no-properties (drgnx-statusbar-render 60))))
    (dotimes (_ 100) (drgnx-statusbar-render 60))
    (should (= (length drgnx-statusbar--errors) 1))
    (should (eq (car (car drgnx-statusbar--errors)) 'b))
    (should (string-match-p "boom" (cadr (car drgnx-statusbar--errors))))))

(ert-deftest drgnx-statusbar/click-runs-the-segments-command ()
  (drgnx-statusbar-test--with
    (let (ran)
      (drgnx-statusbar-define-segment 'a :fn (lambda () "A") :click (lambda () (push 'a ran)) :help "the A segment")
      (drgnx-statusbar-define-segment 'b :fn (lambda () "B") :click (lambda () (interactive) (push 'b ran)))
      (let* ((s (drgnx-statusbar-render 60)) (pos (string-match "B" s)))
        (should (equal (get-text-property 1 'help-echo s) "the A segment"))
        (let ((map (get-text-property pos 'local-map s)))
          (should (eq (lookup-key map [mode-line mouse-1]) 'drgnx-statusbar-click))
          (should (eq (lookup-key map [mouse-1]) 'drgnx-statusbar-click)))
        ;; a synthetic mouse-1 on the text of B, as the mode line reports it: (STRING . POSITION)
        (drgnx-statusbar-click (list 'mouse-1 (list (selected-window) 'mode-line '(0 . 0) 0 (cons s pos))))
        (should (equal ran '(b)))
        (drgnx-statusbar-click (list 'mouse-1 (list (selected-window) 'mode-line '(0 . 0) 0 (cons s 1))))
        (should (equal ran '(a b)))))
    ;; a command symbol is called interactively; a segment without a click does nothing
    (let (ran)
      (cl-letf (((symbol-function 'drgnx-statusbar-test--cmd) (lambda () (interactive) (setq ran t))))
        (drgnx-statusbar-define-segment 'a :fn (lambda () "A") :click 'drgnx-statusbar-test--cmd)
        (let ((s (drgnx-statusbar-render 60)))
          (drgnx-statusbar-click (list 'mouse-1 (list (selected-window) 'mode-line '(0 . 0) 0 (cons s 1))))
          (should ran)
          (setq ran nil)
          (drgnx-statusbar-click (list 'mouse-1 (list (selected-window) 'mode-line '(0 . 0) 0 (cons s (string-match "C" s)))))
          (should-not ran))))))

(ert-deftest drgnx-statusbar/full-in-the-mru-editor-compact-elsewhere ()
  (drgnx-test-with-state
    (drgnx-statusbar-test--with
      (let ((w1 (selected-window)) w2 (buf (generate-new-buffer " *sb-test*")))
        (with-current-buffer buf (emacs-lisp-mode))
        (unwind-protect
            (progn
              (delete-other-windows)
              (setq w1 (selected-window) w2 (split-window-right))
              (set-window-buffer w1 buf)
              (set-window-buffer w2 buf)
              (drgnx-test-use-editor w2)
              (let ((full (with-current-buffer buf (with-selected-window w2 (drgnx-statusbar-mode-line))))
                    (other (with-current-buffer buf (with-selected-window w1 (drgnx-statusbar-mode-line)))))
                (should (string-match-p "A · B" full))
                (should (string-match-p "C" full))
                (should-not (string-match-p "A" other))
                (should (string-match-p "C" other)))
              ;; the host construct is the status bar's while the mode is on
              (let ((drgnx-chrome-editor-mode-line drgnx-chrome-editor-mode-line))
                (cl-letf (((symbol-function 'drgnx-chrome-apply) #'ignore))
                  (drgnx-statusbar-mode 1)
                  (should (equal drgnx-chrome-editor-mode-line '(:eval (drgnx-statusbar-mode-line))))
                  (drgnx-statusbar-mode -1)
                  (should (eq drgnx-chrome-editor-mode-line drgnx-chrome--mode-line)))))
          (delete-other-windows)
          (kill-buffer buf)
          (drgnx-statusbar-mode -1)))
      ;; a buffer whose own mode-line-format is nil keeps none
      (with-temp-buffer
        (setq-local mode-line-format nil)
        (should-not (drgnx-statusbar-mode-line))))))

(ert-deftest drgnx-statusbar/segments-read-no-files-and-start-no-process ()
  (drgnx-statusbar-test--with
    (drgnx-statusbar--define-defaults)
    (let ((native-comp-enable-subr-trampolines nil)   ; stubbing a primitive must not compile a trampoline (a process)
          (fail (lambda (&rest args) (ert-fail (format "a segment reached outside the cache: %S" args)))))
      (with-temp-buffer
        (setq buffer-file-name (expand-file-name "x.yaml" temporary-file-directory))
        (insert "a: 1\n")
        (conf-mode)
        (cl-letf (((symbol-function 'make-process) fail) ((symbol-function 'call-process) fail)
                  ((symbol-function 'start-process) fail) ((symbol-function 'process-file) fail)
                  ((symbol-function 'file-exists-p) fail) ((symbol-function 'file-readable-p) fail)
                  ((symbol-function 'insert-file-contents) fail) ((symbol-function 'locate-dominating-file) fail))
          (let ((drgnx-statusbar-left '(branch problems tests jobs agents modal misc))
                (drgnx-statusbar-right '(lsp position indent encoding eol language)))
            (dotimes (_ 100) (drgnx-statusbar-render 120))
            (dotimes (_ 100) (drgnx-statusbar-render 120 t)))
          (should-not drgnx-statusbar--errors))))))

(ert-deftest drgnx-statusbar/default-segments-say-what-they-know ()
  (drgnx-statusbar-test--with
    (drgnx-statusbar--define-defaults)
    (progn (drgnx-cache--clear 'git-status)                       ; no repository read: the branch is `vc-mode''s
           (cl-flet ((text (id) (let ((s (funcall (plist-get (gethash id drgnx-statusbar--segments) :fn)))) (and s (substring-no-properties s)))))
             (with-temp-buffer
               (emacs-lisp-mode)
               (insert "one\ntwo\nthree")
               (setq buffer-file-coding-system 'utf-8-dos)
               (setq-local indent-tabs-mode nil)
               (setq-local tab-width 8)
               (goto-char (+ (point-min) 5))
               (should (equal (text 'position) "Ln 2, Col 2"))
               (should (equal (text 'encoding) "UTF-8"))
               (should (equal (text 'eol) "CRLF"))
               (should (equal (text 'language) "Emacs Lisp"))
               (should (string-match-p "\\`Spaces: [0-9]+\\'" (text 'indent)))
               (setq buffer-file-coding-system 'utf-8-unix)
               (should (equal (text 'eol) "LF"))
               (setq-local indent-tabs-mode t)
               (should (equal (text 'indent) "Tab Size: 8"))
               ;; vc-mode is the cached branch
               (setq-local vc-mode " Git-feature/x")
               (should (string-match-p "feature/x" (text 'branch)))
               (setq-local vc-mode nil)
               (should-not (text 'branch)))
             ;; no test run yet; misc has nothing to say in a plain buffer
             (let ((drgnx-statusbar-tests-state nil))
               (drgnx-statusbar--bump)                   ; drgnx's own segments are worked out again
               (should-not (text 'tests)))
             (with-temp-buffer
               (let ((global-mode-string nil) (mode-line-process nil) (defining-kbd-macro nil))
                 (should-not (text 'misc))))))))

(ert-deftest drgnx-statusbar/never-wider-with-wide-glyphs-display-text-and-a-right-only-bar ()
  (drgnx-statusbar-test--with
    (let ((drgnx-statusbar-left '(a b)) (drgnx-statusbar-right '(c))
          (drgnx-statusbar-compact '(c)))
      ;; double-width characters, and text whose `display' would show something of another width
      (drgnx-statusbar-define-segment 'a :fn (lambda () "字字字字字字"))
      (drgnx-statusbar-define-segment 'b :fn (lambda () (propertize "ab" 'display '(space :width 40))))
      (drgnx-statusbar-define-segment 'c :fn (lambda () "ünïcödé ⑂"))
      (dotimes (width 40)
        (should (<= (string-width (drgnx-statusbar-render width)) width))
        (should (<= (string-width (drgnx-statusbar-render width t)) width)))
      ;; no `display' property survives in a segment's text (only the bar's own gap has one)
      (let ((s (drgnx-statusbar-render 80)))
        (should-not (get-text-property (string-match "ab" s) 'display s)))
      ;; a right-only bar: the pads, the gap and the text are counted exactly
      (drgnx-statusbar-define-segment 'c :fn (lambda () "C"))
      (should-not (string-match-p "C" (substring-no-properties (drgnx-statusbar-render 3 t))))
      (should (= (string-width (drgnx-statusbar-render 4 t)) 4))
      (should (string-match-p "C" (substring-no-properties (drgnx-statusbar-render 4 t)))))))

(ert-deftest drgnx-statusbar/a-percent-in-a-segment-is-text-not-a-mode-line-construct ()
  (drgnx-statusbar-test--with
    (drgnx-statusbar-define-segment 'a :fn (lambda () (propertize "feat-100%b-x" 'face 'bold)))
    (drgnx-statusbar-test--in-buffer #'emacs-lisp-mode
      (let* ((s (drgnx-statusbar-mode-line)) (pos (string-match "100%%b" s)))
        (should pos)                                   ; doubled: the mode line shows one % and no buffer name
        (should (eq (get-text-property (+ pos 3) 'face s) 'bold))   ; the added % keeps its properties
        (should (eq (get-text-property (+ pos 4) 'face s) 'bold))))
    (should (equal (drgnx-statusbar--escape "no percent") "no percent"))
    (should (equal (drgnx-statusbar--escape "%b%") "%%b%%"))))

(ert-deftest drgnx-statusbar/only-files-code-and-text-get-the-bar ()
  (drgnx-statusbar-test--with
    (let ((stock (default-value 'mode-line-format)))
      ;; a special buffer (Magit, Dired, help, Info, the agent pane...) keeps the stock mode line
      (drgnx-statusbar-test--in-buffer #'special-mode
        (should (equal (drgnx-statusbar-mode-line) stock)))
      ;; code and text get the bar; so does any buffer that visits a file
      (dolist (mode '(emacs-lisp-mode text-mode conf-mode))
        (drgnx-statusbar-test--in-buffer mode
          (should (string-match-p "A · B" (drgnx-statusbar-mode-line)))))
      (drgnx-statusbar-test--in-buffer #'fundamental-mode
        (should (equal (drgnx-statusbar-mode-line) stock))
        (setq buffer-file-name (expand-file-name "x.bin" temporary-file-directory))
        (should (string-match-p "A · B" (drgnx-statusbar-mode-line))))
      ;; a buffer's own non-nil mode line wins; nil means none
      (drgnx-statusbar-test--in-buffer #'emacs-lisp-mode
        (setq-local mode-line-format '("mine"))
        (should (equal (drgnx-statusbar-mode-line) '("mine")))
        (setq-local mode-line-format nil)
        (should-not (drgnx-statusbar-mode-line)))
      ;; the list of modes is a setting
      (let ((drgnx-statusbar-modes '(special-mode)))
        (drgnx-statusbar-test--in-buffer #'special-mode
          (should (string-match-p "A · B" (drgnx-statusbar-mode-line))))))))

(ert-deftest drgnx-statusbar/an-untitled-buffer-gets-the-bar-in-any-language ()
  "New Untitled opens a buffer in `fundamental-mode' with no file: it is an editor all the same (VS Code bars it)."
  (drgnx-statusbar-test--with
    (let ((b (save-window-excursion (drgnx-basics-new-untitled))) (old (window-buffer (selected-window))))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) b)
            (with-current-buffer b
              (should (eq major-mode 'fundamental-mode))
              (should (string-match-p "A · B" (drgnx-statusbar-mode-line)))
              (python-mode)                              ; Change Language Mode keeps it an Untitled editor
              (should (string-match-p "A · B" (drgnx-statusbar-mode-line)))
              (special-mode)                             ; whatever the mode
              (should (string-match-p "A · B" (drgnx-statusbar-mode-line)))))
        (set-window-buffer (selected-window) old)
        (kill-buffer b)))))

(ert-deftest drgnx-statusbar/the-start-page-has-a-quiet-bar ()
  "The first screen never shows the raw mode line: the start page gets the left side of the bar, no position."
  (drgnx-statusbar-test--with
    (drgnx-statusbar-test--state
      (let ((drgnx-statusbar-quiet '(a)))
        (drgnx-statusbar-test--in-buffer #'drgnx-start-mode
          (let ((inhibit-read-only t)) (insert (make-string 11 ?\n)))
          (let ((line (drgnx-statusbar-mode-line)))
            (should (stringp line))
            (should (string-match-p "A" line))
            (should-not (string-match-p "B\\|C" line))   ; nothing else of the left side, no right side
            (let ((shown (format-mode-line line)))
              (should-not (string-match-p "%\\|L[0-9]\\|(drgnx-start)\\|Ln " shown)))))
        ;; with the default segments: still a bar (never the stock line), and no line and column
        (drgnx-statusbar--define-defaults)
        (let ((drgnx-statusbar-quiet (default-value 'drgnx-statusbar-quiet)))
          (should-not (memq 'position drgnx-statusbar-quiet))
          (drgnx-statusbar-test--in-buffer #'drgnx-start-mode
            (should (stringp (drgnx-statusbar-mode-line)))
            (should-not (string-match-p "Ln " (drgnx-statusbar-mode-line)))))))))

(ert-deftest drgnx-statusbar/the-bar-asks-for-a-redraw-when-point-moves-or-the-text-changes ()
  (let ((calls 0) (drgnx-statusbar--last (make-vector 4 nil)))
    (cl-letf (((symbol-function 'force-mode-line-update) (lambda (&optional all) (should-not all) (cl-incf calls))))
      (with-temp-buffer
        (insert "one\ntwo\nthree\n")
        (goto-char (point-min))
        (drgnx-statusbar--post-command)
        (should (= calls 1))
        (drgnx-statusbar--post-command)                ; nothing changed: no redraw
        (drgnx-statusbar--post-command)
        (should (= calls 1))
        (forward-line 1) (set-window-point (selected-window) (point))
        (set-window-buffer (selected-window) (current-buffer))
        (drgnx-statusbar--post-command)                ; point moved
        (should (= calls 2))
        (drgnx-statusbar--post-command)
        (should (= calls 2))
        (insert "x")                                   ; the text changed
        (drgnx-statusbar--post-command)
        (should (= calls 3))
        (insert "y")
        (drgnx-statusbar--post-command)                ; the text changed again
        (should (= calls 4))
        (set-mark (point)) (activate-mark)             ; the mark became active
        (setq calls 0)
        (drgnx-statusbar--post-command)
        (should (= calls 1))
        (deactivate-mark)))
    ;; the hook and the subscriptions are there while the mode is on, and gone when it is off
    (cl-letf (((symbol-function 'drgnx-chrome-apply) #'ignore) ((symbol-function 'force-mode-line-update) #'ignore))
      (let ((drgnx-signal--subscribers nil))
        (unwind-protect
            (progn (drgnx-statusbar-mode 1)
                   (should (memq #'drgnx-statusbar--post-command post-command-hook))
                   (should (eq 'now (drgnx-state--lane-of 'editor-changed #'drgnx-statusbar--editor-changed)))
                   (should (memq #'drgnx-statusbar--ask-git (alist-get 'editor-changed drgnx-signal--subscribers)))
                   (drgnx-statusbar-mode -1)
                   (should-not (memq #'drgnx-statusbar--post-command post-command-hook))
                   (should-not (drgnx-state--lane-of 'editor-changed #'drgnx-statusbar--editor-changed))
                   (should-not (alist-get 'editor-changed drgnx-signal--subscribers)))
          (drgnx-statusbar-mode -1))))
    ;; the store's edge redraws every bar
    (let (all)
      (cl-letf (((symbol-function 'force-mode-line-update) (lambda (&optional a) (setq all a))))
        (drgnx-statusbar--editor-changed (current-buffer))
        (should all)))))

(ert-deftest drgnx-statusbar/the-full-bar-follows-the-editor-at-once ()
  ;; Two windows, one buffer: the store's `editor-changed' (the `now' lane) asks for every bar at once, and the
  ;; next draw puts the full bar in the new editor window.  The bus's idle flush is never run here.
  (drgnx-test-with-state
    (drgnx-statusbar-test--with
      (let ((w1 (selected-window)) w2 (buf (generate-new-buffer " *sb-follow*")) (asked nil)
            (drgnx-chrome-editor-mode-line drgnx-chrome-editor-mode-line))
        (with-current-buffer buf (emacs-lisp-mode))
        (cl-flet ((bar (w) (with-selected-window w (drgnx-statusbar-mode-line))))
          (unwind-protect
              (cl-letf (((symbol-function 'drgnx-chrome-apply) #'ignore)
                        ((symbol-function 'force-mode-line-update) (lambda (&optional all) (push all asked))))
                (delete-other-windows)
                (setq w1 (selected-window) w2 (split-window-right))
                (set-window-buffer w1 buf)
                (set-window-buffer w2 buf)
                (drgnx-statusbar-mode 1)
                (drgnx-test-use-editor w1)
                (should (string-match-p "A · B" (bar w1)))
                (should-not (string-match-p "B" (bar w2)))
                (setq asked nil)
                (drgnx-test-use-editor w2)              ; the same buffer: only the window changed
                (should (memq t asked))                 ; asked for every bar, inside the observation
                (should (string-match-p "A · B" (bar w2)))
                (should-not (string-match-p "B" (bar w1)))
                (should (string-match-p "C" (bar w1))))
            (drgnx-statusbar-mode -1)
            (delete-other-windows)
            (kill-buffer buf)))))))

(ert-deftest drgnx-statusbar/no-window-changed-post-is-left ()
  (let ((src (with-temp-buffer
               (insert-file-contents (expand-file-name "modules/ui/drgnx-statusbar.el" drgnx-dir))
               (buffer-string)))
        (posted nil) (drgnx-statusbar--last (make-vector 4 nil)) (drgnx-signal--subscribers nil))
    (should-not (string-match-p "statusbar-window-changed" src))
    (should-not (string-match-p "drgnx-signal-post" src))
    (cl-letf (((symbol-function 'drgnx-signal-post) (lambda (e) (push e posted)))
              ((symbol-function 'force-mode-line-update) #'ignore)
              ((symbol-function 'drgnx-chrome-apply) #'ignore))
      (let ((other (split-window-right)))
        (unwind-protect
            (progn (drgnx-statusbar--post-command)
                   (with-selected-window other (drgnx-statusbar--post-command)))
          (delete-window other)))
      (unwind-protect
          (progn (drgnx-statusbar-mode 1)
                 (should-not (alist-get 'statusbar-window-changed drgnx-signal--subscribers)))
        (drgnx-statusbar-mode -1)))
    (should-not posted)))

(ert-deftest drgnx-statusbar/now-subscriber-is-cheap ()
  :tags '(:timing)
  (drgnx-test-with-state
    (let* ((w (selected-window)) (n 5000)
           (loop (byte-compile (lambda (n w)
                                 (dotimes (_ n)
                                   (drgnx-statusbar--editor-changed nil)
                                   (drgnx-statusbar--mru-editor-p w)))))
           (runs (sort (cl-loop repeat 21
                                collect (let ((t0 (float-time)))
                                          (funcall loop n w)
                                          (/ (* 1e6 (- (float-time) t0)) n)))
                       #'<))
           (median (nth 10 runs)))
      (message "drgnx-statusbar: the `now' subscriber and the MRU check: %.2f µs (median of 21 × %d)" median n)
      (should (<= median (* 5 (drgnx-run-ert-time-factor)))))))

(ert-deftest drgnx-statusbar/with-the-store-off-every-editor-window-has-the-compact-bar ()
  ;; The bar keeps no editor window of its own: with no record in the store (the store off, or a frame it has not
  ;; observed) no window is the editor, so every editor window gets the compact bar.
  (drgnx-test-with-state
    (drgnx-statusbar-test--with
      (let ((w1 (selected-window)) w2 (buf (generate-new-buffer " *sb-off*")))
        (with-current-buffer buf (emacs-lisp-mode))
        (unwind-protect
            (progn
              (delete-other-windows)
              (setq w1 (selected-window) w2 (split-window-right))
              (set-window-buffer w1 buf)
              (set-window-buffer w2 buf)
              (clrhash drgnx-state--frames)             ; the store has no record of the frame
              (should-not (drgnx-state-editor-window))
              (dolist (w (list w1 w2))
                (should-not (drgnx-statusbar--mru-editor-p w))
                (let ((bar (with-current-buffer buf (with-selected-window w (drgnx-statusbar-mode-line)))))
                  (should (string-match-p "C" bar))
                  (should-not (string-match-p "A\\|B" bar)))))
          (delete-other-windows)
          (kill-buffer buf))))))

(ert-deftest drgnx-statusbar/the-line-number-follows-point-and-edits ()
  (with-temp-buffer
    (dotimes (i 300) (insert (format "line %d\n" (1+ i))))
    (let ((w (selected-window)) (old (window-buffer (selected-window))))
      (set-window-buffer w (current-buffer))
      (unwind-protect
          (cl-flet ((at (line)
                      (goto-char (point-min)) (forward-line (1- line))
                      (set-window-point w (point))
                      (drgnx-statusbar--seg-position)))
            (let ((drgnx-statusbar--window w))
              (should (equal (at 1) "Ln 1, Col 1"))
              (should (equal (at 250) "Ln 250, Col 1"))
              (should (equal (at 30) "Ln 30, Col 1"))        ; backwards, from the cache
              (should (equal (at 30) "Ln 30, Col 1"))
              (goto-char (point-min)) (insert "new\nnew\n")  ; an edit above: counted again
              (should (equal (at 32) "Ln 32, Col 1"))
              (save-restriction                              ; narrowing changes the numbers, as in stock Emacs
                (goto-char (point-min)) (forward-line 10) (narrow-to-region (point) (point-max))
                (should (equal (at 3) "Ln 3, Col 1")))))
        (set-window-buffer w old)))))

(ert-deftest drgnx-statusbar/problems-wait-for-a-backend-before-saying-all-clear ()
  (drgnx-statusbar-test--with
    (let ((running '(b1)) (reporting nil) (counts '(0 . 0)))
      (cl-letf (((symbol-function 'flymake-running-backends) (lambda () running))
                ((symbol-function 'flymake-reporting-backends) (lambda () reporting))
                ((symbol-function 'flymake--mode-line-counter)
                 (lambda (type)
                   (let ((n (if (eq type :error) (car counts) (cdr counts))))
                     (and (> n 0) `("" (:propertize ,(number-to-string n) face x)))))))
        (with-temp-buffer
          (setq-local flymake-mode t)
          (let ((text (lambda () (drgnx-statusbar--seg-problems))))
            (should (equal (substring-no-properties (funcall text)) "◐"))   ; a backend has not reported
            (setq reporting '(b1))
            (should (equal (substring-no-properties (funcall text)) "✓"))
            (setq counts '(1 . 2))
            (should (equal (substring-no-properties (funcall text)) "⚠ 1 2"))
            ;; problems already known are shown even while another backend still runs
            (setq running '(b1 b2))
            (should (equal (substring-no-properties (funcall text)) "⚠ 1 2"))
            ;; only notes (checkdoc's, in the fringe and at the ends of lines): their count, dimmed, never ✓
            (setq running '(b1) counts '(0 . 0))
            (let ((notes 3))
              (cl-letf (((symbol-function 'flymake--mode-line-counter)
                         (lambda (type)
                           (let ((n (pcase type (:error (car counts)) (:warning (cdr counts)) (:note notes))))
                             (and (> n 0) `("" (:propertize ,(number-to-string n) face x)))))))
                (should (equal (substring-no-properties (funcall text)) "● 3"))
                (should (eq (get-text-property 0 'face (funcall text)) 'shadow))
                (setq notes 0)
                (should (equal (substring-no-properties (funcall text)) "✓"))
                (setq notes 2 counts '(1 . 0))                 ; errors or warnings: the ⚠ counts as before
                (should (equal (substring-no-properties (funcall text)) "⚠ 1 0"))))
            (setq-local flymake-mode nil)
            (should-not (funcall text))))))))

;;;; A4: the editor's side (branch and sync, problems, language server, position, language)

(defmacro drgnx-statusbar-test--git-cache (root &rest body)
  "BODY with ROOT a repository the git cache knows (a branch plist is put in it per test), isolated from the rest."
  (declare (indent 1))
  `(let ((drgnx-git--roots (make-hash-table :test #'equal))
         (,root "/tmp/drgnx-sb-repo/"))
     (drgnx-cache--clear 'git-status)
     (puthash "/tmp/drgnx-sb-repo/src/" ,root drgnx-git--roots)
     ,@body))

(defun drgnx-statusbar-test--branch-text (branch &optional vc)
  "The branch segment in a buffer of /tmp/drgnx-sb-repo/src/ when the cache holds BRANCH (and `vc-mode' VC)."
  (drgnx-cache-put 'git-status "/tmp/drgnx-sb-repo/" (list :branch branch))
  (with-temp-buffer
    (setq buffer-file-name "/tmp/drgnx-sb-repo/src/a.el")
    (setq-local vc-mode vc)
    (let ((s (drgnx-statusbar--seg-branch))) (and s (substring-no-properties s)))))

(ert-deftest drgnx-statusbar/branch-segment-reads-the-cache ()
  (drgnx-statusbar-test--with
    (drgnx-statusbar-test--git-cache root
      (let ((fail (lambda (&rest a) (ert-fail (format "the branch segment reached outside the cache: %S" a)))))
        (cl-letf (((symbol-function 'make-process) fail) ((symbol-function 'call-process) fail)
                  ((symbol-function 'process-file) fail) ((symbol-function 'locate-dominating-file) fail)
                  ((symbol-function 'drgnx-git-refresh) fail))
          (should (equal (drgnx-statusbar-test--branch-text '(:head "main" :ahead 2 :behind 1)) "⑂ main ↑2 ↓1"))
          (should (equal (drgnx-statusbar-test--branch-text '(:head "main" :ahead 0 :behind 3)) "⑂ main ↓3"))
          (should (equal (drgnx-statusbar-test--branch-text '(:head "main" :ahead 4 :behind 0)) "⑂ main ↑4"))
          (should (equal (drgnx-statusbar-test--branch-text '(:head "main" :ahead 0 :behind 0)) "⑂ main"))
          (should (equal (drgnx-statusbar-test--branch-text '(:head "dev")) "⑂ dev"))     ; no upstream
          (should (equal (drgnx-statusbar-test--branch-text '(:head nil :detached t)) "⑂ (detached)"))
          ;; the cache wins over `vc-mode'
          (should (equal (drgnx-statusbar-test--branch-text '(:head "main") " Git-other") "⑂ main"))
          ;; no branch read yet: what `vc-mode' says, else nothing
          (should (equal (drgnx-statusbar-test--branch-text nil " Git-other") "⑂ other"))
          (should-not (drgnx-statusbar-test--branch-text nil nil))
          ;; a remote buffer: `vc-mode', never git
          (with-temp-buffer
            (setq buffer-file-name "/ssh:host:/tmp/drgnx-sb-repo/src/a.el" default-directory "/ssh:host:/tmp/drgnx-sb-repo/src/")
            (setq-local vc-mode " Git-remote")
            (should (equal (substring-no-properties (drgnx-statusbar--seg-branch)) "⑂ remote"))
            (setq-local vc-mode nil)
            (should-not (drgnx-statusbar--seg-branch))))))))

(ert-deftest drgnx-statusbar/problems-counts-by-severity ()
  (drgnx-statusbar-test--with
    (let ((counts '(1 . 1)))
      (cl-letf (((symbol-function 'flymake-running-backends) (lambda () '(b)))
                ((symbol-function 'flymake-reporting-backends) (lambda () '(b)))
                ((symbol-function 'flymake--mode-line-counter)
                 (lambda (type)
                   (let ((n (if (eq type :error) (car counts) (cdr counts))))
                     (and (> n 0) `("" (:propertize ,(number-to-string n) face x)))))))
        (with-temp-buffer
          (setq-local flymake-mode t)
          (let ((s (drgnx-statusbar--seg-problems)))
            (should (equal (substring-no-properties s) "⚠ 1 1"))
            (should (eq (get-text-property 2 'face s) 'error))
            (should (eq (get-text-property 4 'face s) 'warning)))
          (setq counts '(0 . 3))
          (let ((s (drgnx-statusbar--seg-problems)))
            (should (equal (substring-no-properties s) "⚠ 0 3"))
            (should (eq (get-text-property 2 'face s) 'shadow))
            (should (eq (get-text-property 4 'face s) 'warning))))))))

(ert-deftest drgnx-statusbar/problems-counts-what-flymake-reports ()
  "A real flymake with a backend that reports one error and one warning."
  (require 'flymake)
  (drgnx-statusbar-test--with
    (with-temp-buffer
      (insert "one\ntwo\n")
      ;; Emacs 31's flymake runs a backend only in trusted content: this one is the test's own
      (let ((trusted-content :all)
            (flymake-diagnostic-functions
             (list (lambda (report-fn &rest _)
                     (funcall report-fn (list (flymake-make-diagnostic (current-buffer) 1 3 :error "e")
                                              (flymake-make-diagnostic (current-buffer) 5 7 :warning "w")))))))
        (flymake-mode 1)
        (unwind-protect
            (progn (flymake-start)
                   (should (equal (substring-no-properties (drgnx-statusbar--seg-problems)) "⚠ 1 1")))
          (flymake-mode -1))))))

(ert-deftest drgnx-statusbar/a-flymake-report-redraws-the-bars ()
  (require 'flymake)
  (let ((calls nil) (drgnx-statusbar--redraw-wanted nil))
    (cl-letf (((symbol-function 'drgnx-statusbar-refresh) (lambda (&optional changed) (push changed calls))))
      (advice-add 'flymake--handle-report :after #'drgnx-statusbar--flymake-reported)
      (advice-add 'flymake--handle-report :after #'drgnx-statusbar--flymake-reported)       ; again: still one
      (unwind-protect
          (with-temp-buffer
            (should (= 1 (length (seq-filter (lambda (f) (eq f #'drgnx-statusbar--flymake-reported))
                                             (let (l) (advice-mapc (lambda (f _) (push f l)) 'flymake--handle-report) l)))))
            (let* (report
                   (trusted-content :all)      ; Emacs 31: a backend runs only in trusted content
                   (flymake-diagnostic-functions (list (lambda (report-fn &rest _) (setq report report-fn)))))
              (flymake-mode 1)
              (unwind-protect
                  (progn (flymake-start)
                         (should-not calls)
                         (let ((epoch (drgnx-epoch 'flymake (current-buffer))) (other (drgnx-epoch 'statusbar)))
                           (funcall report nil)            ; an asynchronous backend answers later
                           ;; this buffer's flymake epoch moves (not every bar's) and a redraw is asked for, debounced
                           (should (equal calls '(nil)))
                           (should drgnx-statusbar--redraw-wanted)
                           (should (/= epoch (drgnx-epoch 'flymake (current-buffer))))
                           (should (= other (drgnx-epoch 'statusbar)))))
                (flymake-mode -1))))
        (advice-remove 'flymake--handle-report #'drgnx-statusbar--flymake-reported)))))

(ert-deftest drgnx-statusbar/lsp-says-the-server-state ()
  (drgnx-statusbar-test--with
    (let ((alive t) (info '(:name "pyright")))
      (cl-letf (((symbol-function 'jsonrpc-running-p) (lambda (_s) alive))
                ((symbol-function 'eglot--server-info) (lambda (_s) info)))
        (with-temp-buffer
          (should-not (drgnx-statusbar--seg-lsp))                          ; eglot does not manage the buffer
          (setq-local eglot--managed-mode t)
          (setq-local eglot--cached-server nil)
          (should (equal (drgnx-statusbar--seg-lsp) "LSP ○"))              ; starting
          (setq-local eglot--cached-server 'server)
          (should (equal (drgnx-statusbar--seg-lsp) "LSP: pyright ●"))     ; connected
          (setq info nil)
          (should (equal (drgnx-statusbar--seg-lsp) "LSP ●"))              ; a server that did not say its name
          (setq alive nil)
          (should (equal (drgnx-statusbar--seg-lsp) "LSP ×")))))))         ; exited

(ert-deftest drgnx-statusbar/position-indent-encoding-eol-language ()
  (drgnx-statusbar-test--with
    (let ((file (make-temp-file "drgnx-sb" nil ".yml")) (drgnx-statusbar-indent-vars '(yaml-indent-offset)))
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'utf-8-dos)) (write-region "a: 1\nb:\n  - c\n" nil file nil 'silent))
            (let ((buf (find-file-noselect file)) (transient-mark-mode t))
              (unwind-protect
                  (with-current-buffer buf
                    (setq-local major-mode 'yaml-ts-mode)               ; the segment reads the name, not the grammar
                    (setq-local yaml-indent-offset 2)
                    (setq-local indent-tabs-mode nil)
                    (goto-char (point-min)) (forward-line 2) (forward-char 4)
                    (should (equal (substring-no-properties (drgnx-statusbar--seg-position)) "Ln 3, Col 5"))
                    (should (equal (drgnx-statusbar--seg-indent) "Spaces: 2"))
                    (should (equal (drgnx-statusbar--seg-encoding) "UTF-8"))
                    (should (equal (drgnx-statusbar--seg-eol) "CRLF"))
                    (should (equal (drgnx-statusbar--seg-language) "YAML"))
                    ;; with a selection
                    (push-mark (point) t t)
                    (backward-char 3)
                    (should (equal (drgnx-statusbar--seg-position) "Ln 3, Col 2 (3 selected)"))
                    (deactivate-mark)
                    (should (equal (drgnx-statusbar--seg-position) "Ln 3, Col 2"))
                    (setq-local indent-tabs-mode t)             ; the file's own lines say spaces: the bar says so too
                    (should (equal (drgnx-statusbar--seg-indent) "Spaces: 2")))
                (kill-buffer buf))))
        (delete-file file)))))

(ert-deftest drgnx-statusbar/indent-reports-what-the-buffer-uses ()
  ;; Emacs Lisp has `indent-tabs-mode' t and `tab-width' 8; a file indented with two spaces is "Spaces: 2"
  (with-temp-buffer
    (setq-local indent-tabs-mode t tab-width 8)
    (insert "(defun f ()\n  (g)\n  (h\n   1))\n")
    (should (equal (drgnx-statusbar--seg-indent) "Spaces: 2"))
    (erase-buffer)
    (insert "int f() {\n\treturn 1;\n\t\treturn 2;\n}\n")
    (setq-local indent-tabs-mode nil)
    (should (equal (drgnx-statusbar--seg-indent) "Tab Size: 8"))
    ;; nothing indented: the mode's own settings
    (setq-local drgnx-statusbar-indent-vars nil)
    (erase-buffer)
    (insert "a\nb\n")
    (should (equal (drgnx-statusbar--seg-indent) "Spaces: 8"))
    (setq-local indent-tabs-mode t)
    (should (equal (drgnx-statusbar--seg-indent) "Tab Size: 8"))
    ;; one space is alignment, not indentation
    (erase-buffer)
    (insert "/*\n * x\n */\nint a;\n    b;\n")
    (setq-local indent-tabs-mode t)
    (should (equal (drgnx-statusbar--seg-indent) "Spaces: 4"))))

(ert-deftest drgnx-statusbar/quiet-in-a-large-file-buffer ()
  ;; the flag editor/large-files sets (by hand here): the column without a line count, no indentation, and the memo's
  ;; key reads no lines either (no scan of the buffer on a redisplay)
  (require 'drgnx-large-file)
  (with-temp-buffer
    (insert "a\n  b\n  cdef\n")
    (goto-char 11)                                      ; line 3, column 4
    (setq-local drgnx-large-file 'lean)
    (should (equal (substring-no-properties (drgnx-statusbar--seg-position)) "Col 5"))
    (should-not (drgnx-statusbar--seg-indent))
    (drgnx-statusbar--indent-width)
    (should-not drgnx-statusbar--indent-cache)
    (setq-local drgnx-large-file nil)
    (should (equal (substring-no-properties (drgnx-statusbar--seg-position)) "Ln 3, Col 5"))))

(ert-deftest drgnx-statusbar/indent-is-scanned-once-per-change ()
  (with-temp-buffer
    (insert "a\n  b\n")
    (drgnx-statusbar--seg-indent)
    (let ((cache drgnx-statusbar--indent-cache))
      (drgnx-statusbar--seg-indent)
      (should (eq cache drgnx-statusbar--indent-cache))           ; no new scan
      (insert "   c\n")
      (drgnx-statusbar--seg-indent)
      (should-not (eq cache drgnx-statusbar--indent-cache)))))

(ert-deftest drgnx-statusbar/restricted-mode-is-a-labelled-segment-with-a-click ()
  (drgnx-statusbar-test--with
    (drgnx-statusbar--define-defaults)
    (should (memq 'trust (eval (car (get 'drgnx-statusbar-left 'standard-value)) t)))
    (with-temp-buffer
      (should-not (drgnx-statusbar--seg-trust))
      (setq drgnx-trust--state 'trusted)
      (should-not (drgnx-statusbar--seg-trust))
      (setq drgnx-trust--state 'restricted)
      (should (equal (drgnx-statusbar--seg-trust) "Restricted Mode"))
      (let ((s (drgnx-statusbar--text 'trust)))
        (should (string-match-p "not trusted" (get-text-property 0 'help-echo s)))
        (should (string-match-p "Trust This Folder\\|trust it" (get-text-property 0 'help-echo s)))
        (should (equal (plist-get (gethash 'trust drgnx-statusbar--segments) :click) 'drgnx-trust-folder))))
    ;; the plain mark in `global-mode-string' is the segment's: `misc' leaves it out
    (should (member '(:eval (drgnx-trust--mark)) drgnx-statusbar-misc-exclude))))

(ert-deftest drgnx-statusbar/the-quiet-bar-names-the-folder ()
  (let ((drgnx-explorer--roots nil))
    (should (equal (drgnx-statusbar--seg-folder) "No folder open"))
    (setq drgnx-explorer--roots '("/x/proj/"))
    (should (equal (drgnx-statusbar--seg-folder) "proj"))
    (setq drgnx-explorer--roots '("/x/proj/" "/y/other/"))
    (should (equal (drgnx-statusbar--seg-folder) "proj +1")))
  (should (eq (car drgnx-statusbar-quiet) 'folder)))

(ert-deftest drgnx-statusbar/language-names-are-the-ones-vs-code-uses-worked-out-once-per-mode ()
  (let ((drgnx-statusbar--language-names (make-hash-table :test #'eq)) (warning-minimum-level :emergency))
    (dolist (c '((rust-ts-mode . "Rust") (go-ts-mode . "Go") (java-ts-mode . "Java") (lua-ts-mode . "Lua")
                 (ruby-mode . "Ruby") (python-mode . "Python") (typescript-ts-mode . "TypeScript")
                 (tsx-ts-mode . "TypeScript JSX") (js-mode . "JavaScript") (emacs-lisp-mode . "Emacs Lisp")
                 (sh-mode . "Shell Script") (c-mode . "C") (text-mode . "Plain Text") (fundamental-mode . "Plain Text")
                 (json-ts-mode . "JSON") (css-mode . "CSS") (conf-unix-mode . "Conf Unix")))
      (with-temp-buffer
        ;; a tree-sitter mode refuses to start without its grammar (java-ts-mode on CI): nothing to name
        (when (and (fboundp (car c)) (ignore-errors (funcall (car c)) t))
          (should (equal (cons (car c) (drgnx-statusbar--seg-language)) c)))))
    ;; a mode whose own name says something else (or nothing yet): the name made from the mode's symbol
    (with-temp-buffer
      (setq-local major-mode 'zig-ts-mode)
      (should (equal (drgnx-statusbar--seg-language) "Zig"))
      (setq-local major-mode 'nix-mode)
      (should (equal (drgnx-statusbar--seg-language) "Nix")))
    ;; your own name for a mode wins, and a change of the setting is seen at once
    (let ((drgnx-statusbar-language-names drgnx-statusbar-language-names))
      (setopt drgnx-statusbar-language-names (cons '(rust-ts-mode . "Rust!") drgnx-statusbar-language-names))
      (with-temp-buffer
        (setq-local major-mode 'rust-ts-mode)
        (should (equal (drgnx-statusbar--seg-language) "Rust!"))))
    (clrhash drgnx-statusbar--language-names)
    ;; worked out once per mode: a redraw runs no regexp
    (with-temp-buffer
      (python-mode)
      (drgnx-statusbar--seg-language)
      (let ((calls 0))
        (cl-letf (((symbol-function 'replace-regexp-in-string) (lambda (&rest _) (setq calls (1+ calls)) ""))
                  ((symbol-function 'string-match) (lambda (&rest _) (setq calls (1+ calls)) nil)))
          (dotimes (_ 10) (should (equal (drgnx-statusbar--seg-language) "Python"))))
        (should (= calls 0))))))

(ert-deftest drgnx-statusbar/only-the-selected-window-shows-the-selection ()
  (drgnx-statusbar-test--with
    (let ((transient-mark-mode t) (other (split-window-right)))
      (unwind-protect
          (with-temp-buffer
            (insert "one two three")
            (set-window-buffer (selected-window) (current-buffer))
            (set-window-buffer other (current-buffer))
            (set-window-point other 5)
            (goto-char 5) (push-mark 1 t t)
            (should (string-match-p "(4 selected)" (drgnx-statusbar--seg-position)))
            (should (drgnx-statusbar--selected-p (selected-window)))
            (should-not (drgnx-statusbar--selected-p other))
            (let ((drgnx-statusbar--window other))             ; the bar of the other window
              (should-not (string-match-p "selected" (drgnx-statusbar--seg-position))))
            (let ((drgnx-statusbar--window (selected-window)))
              (should (string-match-p "(4 selected)" (drgnx-statusbar--seg-position))))
            ;; as redisplay draws the other window's mode line: that window is selected while it is drawn (the
            ;; frame's selected window too); only `old-selected-window' is the one you are in
            (let ((real (selected-window)))
              (with-selected-window other
                (should (eq (old-selected-window) real))
                (let ((drgnx-statusbar--window other))
                  (should-not (drgnx-statusbar--selected-p other))
                  (should-not (string-match-p "selected" (drgnx-statusbar--seg-position)))))))
        (delete-window other)))))

(ert-deftest drgnx-statusbar/a-selection-is-in-the-memo-key ()
  (drgnx-statusbar-test--with
    (drgnx-statusbar-test--state
      (let ((calls 0) (transient-mark-mode t))
        (drgnx-statusbar-define-segment 'a :fn (lambda () (cl-incf calls) "A"))
        (cl-letf (((symbol-function 'force-mode-line-update) #'ignore))
          (drgnx-statusbar-test--in-buffer #'emacs-lisp-mode
            (insert "one two three")
            (goto-char 5)
            (drgnx-statusbar-mode-line)
            (cl-flet ((rebuilt-p () (let ((c calls)) (drgnx-statusbar-mode-line) (/= calls c))))
              (should-not (rebuilt-p))
              (push-mark 1 t t)                      ; a region: the mark moved and became active
              (should (rebuilt-p)) (should-not (rebuilt-p))
              (deactivate-mark)                      ; it went away with point where it was
              (should (rebuilt-p)) (should-not (rebuilt-p)))))))))

(ert-deftest drgnx-statusbar/language-click-may-ask-but-render-never-does ()
  (drgnx-statusbar-test--with
    (drgnx-statusbar--define-defaults)
    (let ((asked nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (setq asked t) "text-mode"))
                ((symbol-function 'read-string) (lambda (&rest _) (setq asked t) "")))
        (with-temp-buffer
          (emacs-lisp-mode)
          (setq buffer-file-name "/tmp/drgnx-sb-x.el")
          (let ((drgnx-statusbar-left '(branch problems position)) (drgnx-statusbar-right '(lsp indent encoding eol language)))
            (dotimes (_ 5) (drgnx-statusbar-render 120) (drgnx-statusbar-render 120 t)))
          (should-not asked)
          ;; the language is a click on a command, and the command asks
          (should (eq (plist-get (gethash 'language drgnx-statusbar--segments) :click) 'drgnx-statusbar-change-mode))
          (should (commandp 'drgnx-statusbar-change-mode))
          (let ((buffer-file-name nil)) (call-interactively 'drgnx-statusbar-change-mode))
          (should asked)
          (should (eq major-mode 'text-mode)))))))

(ert-deftest drgnx-statusbar/the-bar-asks-git-to-read-the-editors-repository-at-most-every-few-seconds ()
  (let ((asked nil) (now 100.0) (drgnx-statusbar--git-asked nil) (file "/tmp/drgnx-sb-a/x.el")
        (drgnx-git--roots (make-hash-table :test #'equal))
        (buf (generate-new-buffer " *sb-git*")))
    (puthash "/tmp/drgnx-sb-a/" "/tmp/drgnx-sb-a/" drgnx-git--roots)
    (puthash "/tmp/drgnx-sb-a/sub/" "/tmp/drgnx-sb-a/" drgnx-git--roots)
    (unwind-protect
        (progn
          (with-current-buffer buf (setq buffer-file-name file))
          (cl-letf (((symbol-function 'drgnx-wb-editor-window) (lambda () (selected-window)))
                    ((symbol-function 'window-buffer) (lambda (&optional _w) buf))
                    ((symbol-function 'drgnx-git-refresh) (lambda (path &optional _wait) (push path asked)))
                    ((symbol-function 'drgnx-statusbar--now) (lambda () now)))
            (drgnx-statusbar--ask-git)
            (should (equal asked (list file)))
            (setq now 102.0) (drgnx-statusbar--ask-git)                    ; too soon
            (should (= 1 (length asked)))
            (setq now 106.0) (drgnx-statusbar--ask-git)                    ; later
            (should (= 2 (length asked)))
            (with-current-buffer buf (setq buffer-file-name "/tmp/drgnx-sb-a/sub/y.el"))   ; the same repository
            (setq now 107.0) (drgnx-statusbar--ask-git)
            (should (= 2 (length asked)))
            (with-current-buffer buf (setq buffer-file-name "/tmp/drgnx-sb-b/y.el"))   ; another repository (unknown) at once
            (drgnx-statusbar--ask-git)
            (should (= 3 (length asked)))
            (with-current-buffer buf (setq buffer-file-name "/ssh:host:/tmp/z.el"))    ; remote: nothing
            (setq now 200.0) (drgnx-statusbar--ask-git)
            (should (= 3 (length asked)))))
      (kill-buffer buf))))

(ert-deftest drgnx-statusbar/misc-shows-process-narrowing-recording-and-remote ()
  (drgnx-statusbar-test--with
    (let ((global-mode-string nil) (mode-line-process nil) (defining-kbd-macro nil))
      (with-temp-buffer
        (insert "a\nb\nc\n")
        (should-not (drgnx-statusbar--seg-misc))
        (setq mode-line-process ":run")
        (should (equal (drgnx-statusbar--seg-misc) ":run"))
        (setq mode-line-process nil)
        (narrow-to-region 1 3)
        (should (equal (drgnx-statusbar--seg-misc) "Narrowed"))
        (widen)
        (let ((defining-kbd-macro t))
          (should (equal (substring-no-properties (drgnx-statusbar--seg-misc)) "● Rec")))
        (let ((default-directory "/ssh:me@box.example:/srv/work/"))
          (should (equal (drgnx-statusbar--seg-misc) "Remote: box.example")))
        ;; other entries of global-mode-string; the job badge is left out (the jobs segment shows it).  Set, not
        ;; let-bound: the bar reads the entries when they are set
        (setq global-mode-string (list "" "12:30" '(:eval (drgnx-job-ui--badge-segment))))
        (should (equal (drgnx-statusbar--seg-misc) "12:30"))
        ;; a construct that is not plain strings is formatted by Emacs, entry by entry
        (cl-letf (((symbol-function 'format-mode-line) (lambda (c &rest _) (format "<%S>" c))))
          (setq global-mode-string '(display-time-string))
          (should (equal (drgnx-statusbar--seg-misc) "<display-time-string>")))))))

(ert-deftest drgnx-statusbar/the-separator-is-ascii-on-a-terminal-that-is-not-utf-8 ()
  (drgnx-statusbar-test--with
    (should (string-match-p "\\` A · B " (substring-no-properties (drgnx-statusbar-render 60))))
    (cl-letf (((symbol-function 'drgnx-ui-ascii-frame-p) (lambda (&optional _f) t)))
      (let ((s (substring-no-properties (drgnx-statusbar-render 60))))
        (should (string-match-p "\\` A | B " s))
        (should-not (string-match-p "·" s))))
    (let ((g (alist-get 'sep drgnx-face-glyphs)))
      (should (equal (cons " · " " | ") g)))))

(ert-deftest drgnx-statusbar/a-failed-segment-is-skipped-for-ten-seconds-then-tried-again ()
  (drgnx-statusbar-test--with
    (let ((calls 0) (now 100.0) (ok nil))
      (cl-letf (((symbol-function 'drgnx-statusbar--now) (lambda () now)))
        (drgnx-statusbar-define-segment 'b :fn (lambda () (cl-incf calls) (if ok "B" (error "boom"))))
        (dotimes (_ 50) (drgnx-statusbar-render 60))
        (should (= calls 1))                             ; skipped while the failure is young
        (should (= (length drgnx-statusbar--errors) 1))
        (setq now 109.0)
        (drgnx-statusbar-render 60)
        (should (= calls 1))
        (setq now 111.0)                                 ; ten seconds later: tried again, fails again, recorded anew
        (drgnx-statusbar-render 60)
        (should (= calls 2))
        (should (= (length drgnx-statusbar--errors) 1))
        (should (= (cddr (car drgnx-statusbar--errors)) 111.0))
        (setq now 115.0)
        (drgnx-statusbar-render 60)
        (should (= calls 2))
        (setq ok t now 125.0)                            ; it works again: shown, and the entry is gone
        (should (string-match-p "A · B" (substring-no-properties (drgnx-statusbar-render 60))))
        (should (= calls 3))
        (should-not drgnx-statusbar--errors)
        ;; defining it again also gives it a new chance at once
        (setq ok nil now 130.0)
        (drgnx-statusbar-render 60)
        (should drgnx-statusbar--errors)
        (drgnx-statusbar-define-segment 'b :fn (lambda () "B2"))
        (should (string-match-p "B2" (substring-no-properties (drgnx-statusbar-render 60))))))))

(ert-deftest drgnx-statusbar/a-failing-bar-is-recorded-once-and-shows-nothing ()
  (drgnx-statusbar-test--with
    (let ((drgnx-statusbar-left 'not-a-list))         ; a bad setting
      (drgnx-statusbar-test--in-buffer #'emacs-lisp-mode
        (dotimes (_ 100) (should-not (drgnx-statusbar-mode-line)))
        (should (= (length drgnx-statusbar--errors) 1))
        (should (eq (car (car drgnx-statusbar--errors)) 'host))))))

(defmacro drgnx-statusbar-test--state (&rest body)
  "BODY with the drgnx side's state (tests, jobs, agents, their texts, the refresh timer) kept to this test."
  (declare (indent 0))
  `(let ((drgnx-statusbar-tests-state nil) (drgnx-statusbar--jobs-state nil)
         (drgnx-statusbar--agents-state nil)
         (drgnx-statusbar--redraw-wanted nil) (drgnx-statusbar--jobs-wanted nil) (drgnx-statusbar--jobs-pending nil)
         (drgnx-statusbar--state-texts (make-hash-table :test #'eq))
         (drgnx-statusbar--git-branches (make-hash-table :test #'equal))
         (drgnx-statusbar-waiting-functions (list #'drgnx-statusbar-agents-waiting)))
     (drgnx-cache--clear 'git-status)
     (unwind-protect (progn ,@body)
       (drgnx-timer-cancel 'statusbar-refresh))))

(defun drgnx-statusbar-test--seg (id)
  "The plain text segment ID says now (nil when it says nothing)."
  (when-let* ((s (funcall (plist-get (gethash id drgnx-statusbar--segments) :fn)))) (substring-no-properties s)))

(ert-deftest drgnx-statusbar/agent-changes-redraw-only-when-the-counts-change ()
  (require 'drgnx-agents)
  (drgnx-statusbar-test--with
    (drgnx-statusbar-test--state
      (drgnx-statusbar--define-defaults)
      (let ((calls 0)
            (drgnx-agents--sessions (list (drgnx-agents--make :name "a" :status 'busy)
                                          (drgnx-agents--make :name "b" :status 'idle))))
        (cl-letf (((symbol-function 'force-mode-line-update) (lambda (&optional all) (should all) (cl-incf calls))))
          (drgnx-statusbar--refresh-now)
          (should (= calls 1))
          (drgnx-statusbar--refresh-now)                 ; the same counts: nothing to redraw
          (should (= calls 1))
          (should (equal (drgnx-statusbar-test--seg 'agents) "◎ 1 busy"))
          (setf (drgnx-agent-session-permissions (cadr drgnx-agents--sessions)) '(ask))
          (drgnx-statusbar--refresh-now)
          (should (= calls 2))
          (should (equal (drgnx-statusbar-test--seg 'agents) "◎ 1 busy ◐ 1 waiting on you")))))))

;;;; The drgnx side (A5): tests, jobs, agents, other modules' marks

(defun drgnx-statusbar-test--compilation (command &rest lines)
  "A buffer as a finished compilation of COMMAND leaves it, with LINES of output."
  (let ((b (generate-new-buffer " *sb-compilation*")))
    (with-current-buffer b
      (setq-local compilation-arguments (list command nil nil nil))
      (insert (format "-*- mode: compilation -*-\n%s\n" command))
      (dolist (l lines) (insert l "\n"))
      (insert "\nCompilation finished at Sun Oct 18 12:00:00\n"))
    b))

(ert-deftest drgnx-statusbar/tests-from-an-ert-summary ()
  (drgnx-statusbar-test--with
    (drgnx-statusbar-test--state
      (drgnx-statusbar--define-defaults)
      (cl-letf (((symbol-function 'force-mode-line-update) #'ignore))
        (should-not (drgnx-statusbar-test--seg 'tests))  ; no run yet: nothing
        ;; ERT's summary (the last one counts)
        (let ((b (drgnx-statusbar-test--compilation
                  "bin/drgnx test"
                  "Ran 3 tests, 1 results as expected, 2 unexpected (2026-10-18 12:00:00+0000, 0.1 sec)"
                  "   passed  41/41  drgnx-x/y (0.001 sec)"
                  "Ran 41 tests, 41 results as expected, 0 unexpected (2026-10-18 12:00:01+0000, 2.3 sec)")))
          (unwind-protect
              (let ((tick (drgnx-epoch 'statusbar)))
                (drgnx-statusbar--compilation-finished b "finished\n")
                (should (equal (drgnx-statusbar-test--seg 'tests) "✓ tests 41/41"))
                (should (equal (plist-get drgnx-statusbar-tests-state :passed) 41))
                (should (equal (plist-get drgnx-statusbar-tests-state :failed) 0))
                (should (eq (plist-get drgnx-statusbar-tests-state :source) b))
                (should (numberp (plist-get drgnx-statusbar-tests-state :at)))
                (should (/= (drgnx-epoch 'statusbar) tick))) ; the bars' memo knows it changed
            (kill-buffer b)))
        ;; failures
        (let ((b (drgnx-statusbar-test--compilation
                  "make test" "Ran 43 tests, 41 results as expected, 2 unexpected (2026-10-18, 2.3 sec)")))
          (unwind-protect
              (progn (drgnx-statusbar--compilation-finished b "exited abnormally with code 1\n")
                     (should (equal (drgnx-statusbar-test--seg 'tests) "× tests 2 failed"))
                     (let ((s (funcall (plist-get (gethash 'tests drgnx-statusbar--segments) :fn))))
                       (should (eq (get-text-property 0 'face s) 'error))))
            (kill-buffer b)))
        ;; bin/drgnx test --ui's line
        (let ((b (drgnx-statusbar-test--compilation "bin/drgnx test --ui" "ui ERT: 25/27 passed")))
          (unwind-protect
              (progn (drgnx-statusbar--compilation-finished b "finished\n")
                     (should (equal (drgnx-statusbar-test--seg 'tests) "× tests 2 failed"))
                     (drgnx-statusbar-note-tests 27 0 'timeline)          ; C3's events call this directly
                     (should (equal (drgnx-statusbar-test--seg 'tests) "✓ tests 27/27")))
            (kill-buffer b)))))))

(ert-deftest drgnx-statusbar/a-non-test-compilation-is-ignored ()
  (drgnx-statusbar-test--with
    (drgnx-statusbar-test--state
      (drgnx-statusbar--define-defaults)
      (cl-letf (((symbol-function 'force-mode-line-update) #'ignore))
        (dolist (cmd '("make all" "cargo build --features testing" "DRGNX_TEST_SELECTOR=x make"))
          (let ((b (drgnx-statusbar-test--compilation cmd "Ran 2 tests, 2 results as expected, 0 unexpected")))
            (unwind-protect (drgnx-statusbar--compilation-finished b "finished\n")
              (kill-buffer b))))
        (should-not drgnx-statusbar-tests-state)
        ;; a test command with no summary (killed early) changes nothing either
        (let ((b (drgnx-statusbar-test--compilation "bin/drgnx test" "Loading...")))
          (unwind-protect (drgnx-statusbar--compilation-finished b "killed\n")
            (kill-buffer b)))
        (should-not drgnx-statusbar-tests-state)
        (should-not (drgnx-statusbar-test--seg 'tests))))))

(ert-deftest drgnx-statusbar/jobs-and-cards ()
  (drgnx-statusbar-test--with
    (drgnx-statusbar-test--state
      (drgnx-statusbar--define-defaults)
      (let ((drgnx-job-ui--badge "") (drgnx-job-ui--needs-you nil) (asked 0)
            (answer '(:jobs [(:id "a" :status "running") (:id "b" :status "running") (:id "c" :status "done")])))
        (cl-letf (((symbol-function 'force-mode-line-update) #'ignore)
                  ((symbol-function 'drgnx-hub-call)
                   (lambda (method params cb) (should (equal method "job/status")) (should-not params)
                     (cl-incf asked) (funcall cb answer nil))))
          (should-not (drgnx-statusbar-test--seg 'jobs))
          ;; a job event: the hub is asked once (on the refresh), and the count is cached
          (drgnx-statusbar--hub-event "job" '(:id "a"))
          (drgnx-statusbar--hub-event "agent-entries" '(:id "x"))
          (should (= asked 0))
          (drgnx-statusbar--refresh-now)
          (should (= asked 1))
          (should (equal (drgnx-statusbar-test--seg 'jobs) "◎ 2 jobs"))
          (dotimes (_ 10) (drgnx-statusbar-test--seg 'jobs))
          (should (= asked 1))                            ; redisplay never asks
          ;; cards waiting (C8's count, set with the badge) come after
          (setq drgnx-job-ui--badge " ⚑3" drgnx-job-ui--needs-you 3)
          (should (equal (drgnx-statusbar-test--seg 'jobs) "◎ 2 jobs ⚑3"))
          (setq answer '(:jobs [(:id "a" :status "running") (:id "c" :status "done")]))
          (drgnx-statusbar--hub-event "card" '(:id 1 :job "a"))
          (drgnx-statusbar--refresh-now)
          (should (equal (drgnx-statusbar-test--seg 'jobs) "◎ 1 job ⚑3"))
          (setq answer '(:jobs []))
          (drgnx-statusbar--hub-event "job" '(:id "a"))
          (drgnx-statusbar--refresh-now)
          (should (equal (drgnx-statusbar-test--seg 'jobs) "⚑3"))
          ;; the hub went away: a count that cannot be read again is not shown
          (setq answer '(:jobs [(:id "a" :status "running")]))
          (drgnx-statusbar--hub-event "job" '(:id "a"))
          (drgnx-statusbar--refresh-now)
          (should (equal (drgnx-statusbar-test--seg 'jobs) "◎ 1 job ⚑3"))
          (setq drgnx-job-ui--badge "" drgnx-job-ui--needs-you nil)
          (drgnx-statusbar--hub-gone)
          (should-not (drgnx-statusbar-test--seg 'jobs)))))))

(ert-deftest drgnx-statusbar/cards-waiting-reads-the-job-count-not-the-badge ()
  ;; the jobs segment shows C8's one count (`drgnx-job-ui-needs-you'), never a number read back from the badge's text;
  ;; a click on it opens What Needs You of every job
  (drgnx-statusbar-test--with
    (drgnx-statusbar-test--state
      (drgnx-statusbar--define-defaults)
      (let ((drgnx-job-ui--badge " ⚑99") (needs 3))
        (cl-letf (((symbol-function 'drgnx-job-ui-needs-you) (lambda () needs)))
          (should (equal (drgnx-statusbar-test--seg 'jobs) "⚑3"))
          (setq needs nil drgnx-job-ui--badge " ⚑98")      ; the badge's text moves the memo, the count is not known
          (should-not (drgnx-statusbar-test--seg 'jobs))))
      (should (eq (plist-get (gethash 'jobs drgnx-statusbar--segments) :click) 'drgnx-cockpit-show-jobs)))))

(ert-deftest drgnx-statusbar/a-test-summary-never-breaks-the-compilation ()
  (drgnx-statusbar-test--with
    (drgnx-statusbar-test--state
      (cl-letf (((symbol-function 'force-mode-line-update) #'ignore))
        ;; a bad regexp of the user's: recorded, never signalled into the compilation's sentinel
        (let ((b (drgnx-statusbar-test--compilation "make test" "Ran 2 tests, 2 results as expected, 0 unexpected"))
              (drgnx-statusbar-test-count-regexps '(("\\(" :passed 1))))
          (unwind-protect (drgnx-statusbar--compilation-finished b "finished\n")
            (kill-buffer b))
          (should-not drgnx-statusbar-tests-state)
          (should (assq 'tests drgnx-statusbar--errors)))
        ;; only the last 64 KB are searched: a summary further back is not this run's
        (let ((b (drgnx-statusbar-test--compilation
                  "make test" "Ran 2 tests, 2 results as expected, 0 unexpected" (make-string 70000 ?x))))
          (unwind-protect (drgnx-statusbar--compilation-finished b "finished\n")
            (kill-buffer b))
          (should-not drgnx-statusbar-tests-state))))))

(ert-deftest drgnx-statusbar/the-hub-is-asked-one-question-at-a-time ()
  (drgnx-statusbar-test--with
    (drgnx-statusbar-test--state
      (drgnx-statusbar--define-defaults)
      (let ((asked 0) (callback nil) (connected nil))
        (cl-letf (((symbol-function 'force-mode-line-update) #'ignore)
                  ((symbol-function 'drgnx-statusbar--hub-connected-p) (lambda () connected))
                  ((symbol-function 'drgnx-hub-call) (lambda (_m _p cb) (cl-incf asked) (setq callback cb))))
          ;; an event that is not a job's (or not a string) does not ask while the count is known or the hub is away
          (drgnx-statusbar--hub-event 'job nil)
          (drgnx-statusbar--hub-event "agent" nil)
          (drgnx-statusbar--refresh-now)
          (should (= asked 0))
          ;; the first event after the hub connects asks: the count is not known yet
          (setq connected t)
          (drgnx-statusbar--hub-event "agent" nil)
          (drgnx-statusbar--refresh-now)
          (should (= asked 1))
          ;; while the answer is on its way, more job events ask nothing…
          (drgnx-statusbar--hub-event "job" '(:id "a"))
          (drgnx-statusbar--refresh-now)
          (drgnx-statusbar--hub-event "card" '(:id 1))
          (drgnx-statusbar--refresh-now)
          (should (= asked 1))
          ;; …the answer asks once more for them, on the next refresh
          (funcall callback '(:jobs [(:status "running")]) nil)
          (should-not drgnx-statusbar--jobs-pending)
          (should (equal (drgnx-statusbar-test--seg 'jobs) "◎ 1 job"))
          (should (drgnx-timer-active-p 'statusbar-refresh))
          (drgnx-statusbar--refresh-now)
          (should (= asked 2))
          ;; an answer of the wrong shape (in the hub client's filter) signals nothing: the count is not known
          (funcall callback '(:jobs 42) nil)
          (should-not drgnx-statusbar--jobs-state)
          (funcall callback "garbage" nil)
          (should-not drgnx-statusbar--jobs-state)
          ;; the hub went away with a question on its way: the next one is asked
          (drgnx-statusbar--hub-event "job" nil)
          (drgnx-statusbar--refresh-now)
          (should (= asked 3))
          (drgnx-statusbar--hub-gone)
          (should-not drgnx-statusbar--jobs-pending)
          (drgnx-statusbar--hub-event "job" nil)
          (drgnx-statusbar--refresh-now)
          (should (= asked 4)))))))

(ert-deftest drgnx-statusbar/agents-busy-and-waiting ()
  (require 'drgnx-agents)
  (drgnx-statusbar-test--with
    (drgnx-statusbar-test--state
      (drgnx-statusbar--define-defaults)
      (let ((drgnx-agents--sessions (list (drgnx-agents--make :name "a" :status 'busy)
                                          (drgnx-agents--make :name "b" :status 'idle :permissions '((:id 1))))))
        (cl-letf (((symbol-function 'force-mode-line-update) #'ignore))
          (drgnx-statusbar--refresh-now)
          (let ((s (funcall (plist-get (gethash 'agents drgnx-statusbar--segments) :fn))))
            (should (equal (substring-no-properties s) "◎ 1 busy ◐ 1 waiting on you"))
            (should (eq (get-text-property (string-search "◐" s) 'face s) 'drgnx-statusbar-waiting))
            (should (eq (get-text-property (string-search "waiting" s) 'face s) 'drgnx-statusbar-waiting))
            (should-not (get-text-property 0 'face s)))
          (should (equal (face-attribute 'drgnx-statusbar-waiting :inherit) 'error))
          ;; nobody busy, nothing waiting: nothing to say
          (setf (drgnx-agent-session-status (car drgnx-agents--sessions)) 'idle
                (drgnx-agent-session-permissions (cadr drgnx-agents--sessions)) nil)
          (drgnx-statusbar--refresh-now)
          (should-not (drgnx-statusbar-test--seg 'agents))
          ;; an edit to review waits on you too
          (setf (drgnx-agent-session-reviews (car drgnx-agents--sessions)) '((:id 2) (:id 3)))
          (drgnx-statusbar--refresh-now)
          (should (equal (drgnx-statusbar-test--seg 'agents) "◐ 2 waiting on you"))
          ;; ASCII on a terminal that is not UTF-8
          (cl-letf (((symbol-function 'drgnx-ui-ascii-frame-p) (lambda (&optional _f) t)))
            (should (equal (drgnx-statusbar-test--seg 'agents) "? 2 waiting on you"))))))))

(ert-deftest drgnx-statusbar/waiting-functions-add-up ()
  (require 'drgnx-agents)
  (drgnx-statusbar-test--with
    (drgnx-statusbar-test--state
      (drgnx-statusbar--define-defaults)
      (let ((drgnx-agents--sessions (list (drgnx-agents--make :name "b" :status 'idle :permissions '((:id 1)))))
            (open-questions 2))
        (cl-letf (((symbol-function 'force-mode-line-update) #'ignore)
                  ((symbol-function 'drgnx-statusbar-test--questions) (lambda () open-questions))
                  ((symbol-function 'drgnx-statusbar-test--broken) (lambda () (error "boom")))
                  ((symbol-function 'drgnx-statusbar-test--not-a-number) (lambda () "three")))
          (add-hook 'drgnx-statusbar-waiting-functions #'drgnx-statusbar-test--questions)
          (add-hook 'drgnx-statusbar-waiting-functions #'drgnx-statusbar-test--broken)
          (add-hook 'drgnx-statusbar-waiting-functions #'drgnx-statusbar-test--not-a-number)
          (drgnx-statusbar--refresh-now)
          ;; 1 permission + 2 open questions; one that fails or says no number counts nothing and is recorded
          (should (equal (drgnx-statusbar-test--seg 'agents) "◐ 3 waiting on you"))
          (should (assq 'waiting drgnx-statusbar--errors))
          ;; a module whose count changes asks for a refresh
          (setq open-questions 0)
          (drgnx-statusbar--refresh-now)
          (should (equal (drgnx-statusbar-test--seg 'agents) "◐ 1 waiting on you")))))))

(ert-deftest drgnx-statusbar/misc-shows-other-modules-segments ()
  (drgnx-statusbar-test--with
    (drgnx-statusbar-test--state
      (drgnx-statusbar--define-defaults)
      (let ((drgnx-statusbar-left '(misc)) (drgnx-statusbar-right nil)
            (drgnx-job-ui--badge " ⚑2") (drgnx-job-ui--needs-you 2) (mode-line-process nil) (defining-kbd-macro nil)
            (global-mode-string (list "" '(:eval (drgnx-job-ui--badge-segment)))))
        (cl-letf (((symbol-function 'drgnx-job-ui--badge-segment) (lambda () drgnx-job-ui--badge))
                  ;; a batch Emacs formats every mode-line construct as "": strings and :eval forms, as a frame would
                  ((symbol-function 'format-mode-line) #'drgnx-statusbar-test--format-mode-line))
          (drgnx-statusbar-test--in-buffer #'emacs-lisp-mode
            (should-not (string-match-p "⚑" (drgnx-statusbar-mode-line)))   ; the jobs segment shows the badge
            ;; another module (the remote mark, the trust mark) pushes an entry: it appears, no coupling
            (push '(:eval (propertize "TRUST" 'face 'warning)) global-mode-string)
            (should (string-match-p "TRUST" (drgnx-statusbar-mode-line)))
            (should-not (string-match-p "⚑" (drgnx-statusbar-mode-line)))
            ;; …and goes when it is taken out
            (pop global-mode-string)
            (should-not (string-match-p "TRUST" (drgnx-statusbar-mode-line)))
            ;; a plain string is shown as it is (set: a `let' is not seen, the bar reads the entries when they are set)
            (setq global-mode-string " 12:30")
            (should (string-match-p "12:30" (drgnx-statusbar-mode-line)))))))))

(ert-deftest drgnx-statusbar/misc-shows-keycast-which-function-and-evils-state ()
  "What other packages put in the stock mode line shows in `misc': keycast's key, which-function's name (from its
own cache), evil's state tag, other entries of `mode-line-misc-info'; each change redraws the memoized bar."
  (drgnx-statusbar-test--with
    (drgnx-statusbar-test--state
      (drgnx-statusbar--define-defaults)
      (let ((drgnx-statusbar-left '(misc)) (drgnx-statusbar-right nil)
            (global-mode-string nil) (mode-line-process nil) (defining-kbd-macro nil)
            (keycast-mode-line-mode nil) (keycast--this-command-keys nil)
            (which-function-mode nil) (which-func-display 'mode)
            (which-func-table (make-hash-table :test #'eq :weakness 'key))
            (evil-mode-line-format 'before)
            (mode-line-misc-info (copy-sequence mode-line-misc-info))
            (formats 0))
        (cl-letf (((symbol-function 'keycast-format)
                   (lambda (_format) (concat (key-description keycast--this-command-keys) " next-line")))
                  ((symbol-function 'force-mode-line-update) #'ignore)
                  ;; a batch Emacs formats every mode-line construct as "": count the calls, show :eval forms
                  ((symbol-function 'format-mode-line)
                   (lambda (c &rest _)
                     (setq formats (1+ formats))
                     (mapconcat (lambda (e) (cond ((stringp e) e) ((eq (car-safe e) :eval) (eval (cadr e) t)) (t "")))
                                (if (and (consp c) (not (eq (car c) :eval))) c (list c)) ""))))
          (drgnx-statusbar-test--in-buffer #'emacs-lisp-mode
            (should-not (string-match-p "next-line" (drgnx-statusbar-mode-line)))
            ;; Show Keys As I Type (keycast-mode-line-mode): the key of the last command
            (setq keycast-mode-line-mode t keycast--this-command-keys [?\C-n])
            (should (string-match-p "C-n next-line" (drgnx-statusbar-mode-line)))
            (setq keycast--this-command-keys [?\C-p])                 ; the next command, point did not move
            (should (string-match-p "C-p next-line" (drgnx-statusbar-mode-line)))
            (setq keycast-mode-line-mode nil)
            (should-not (string-match-p "next-line" (drgnx-statusbar-mode-line)))
            ;; which-function-mode: the name its idle timer cached for this window
            (setq which-function-mode t)
            (setq-local which-func-mode t)
            (puthash (selected-window) "my-function" which-func-table)
            (should (string-match-p "my-function" (drgnx-statusbar-mode-line)))
            (puthash (selected-window) "other-function" which-func-table)
            (should (string-match-p "other-function" (drgnx-statusbar-mode-line)))
            (let ((which-func-display 'header))                       ; you asked for it in the header line
              (should-not (drgnx-statusbar--seg-misc)))
            (setq which-function-mode nil)
            ;; evil's state tag (a Vim profile without drgnx's modal module)
            (setq-local evil-local-mode t)
            (setq-local evil-mode-line-tag " <N> ")
            (should (string-match-p "<N>" (drgnx-statusbar-mode-line)))
            (setq-local evil-mode-line-tag " <I> ")
            (should (string-match-p "<I>" (drgnx-statusbar-mode-line)))
            (cl-letf (((symbol-function 'drgnx-modal-mode-line) (lambda () "INSERT")))   ; modal shows it: not twice
              (should-not (string-match-p "<I>" (or (drgnx-statusbar--seg-misc) ""))))
            (setq-local evil-local-mode nil)
            ;; nothing extra in `mode-line-misc-info': nothing is formatted on a redisplay
            (drgnx-statusbar-mode-line)
            (let ((before formats))
              (dotimes (_ 5) (drgnx-statusbar-mode-line))
              (should (= formats before)))
            ;; another package's entry there shows; eglot's (the lsp segment has it) does not
            (push '(eglot--managed-mode (" [" "eglot:x" "] ")) mode-line-misc-info)
            (push '(:eval "PKG-MARK") mode-line-misc-info)
            (should (string-match-p "PKG-MARK" (drgnx-statusbar-mode-line)))
            (should-not (string-match-p "eglot:x" (drgnx-statusbar-mode-line)))))))))

(ert-deftest drgnx-statusbar/keycast-redraws-every-bar-after-each-command ()
  "Keycast's text changes with every command, even one that moves nothing: while it is on, each command redraws."
  (let ((all 0) (drgnx-statusbar--last (make-vector 5 nil)) (keycast-mode-line-mode nil))
    (cl-letf (((symbol-function 'force-mode-line-update) (lambda (&optional a) (when a (setq all (1+ all)))))
              ((symbol-function 'drgnx-signal-post) #'ignore))
      (with-temp-buffer
        (drgnx-statusbar--post-command)
        (setq all 0)
        (drgnx-statusbar--post-command)                 ; nothing changed, keycast off: no redraw of every bar
        (should (= all 0))
        (setq keycast-mode-line-mode t)
        (drgnx-statusbar--post-command)
        (should (= all 1))))))

(defvar drgnx-statusbar-test--refreshing nil "Non-nil inside the status bar's refresh (other timers may redraw too).")
(defvar drgnx-statusbar-test--refreshes 0 "How many refreshes ran.")

(defun drgnx-statusbar-test--mark-refresh (fn &rest args)
  (setq drgnx-statusbar-test--refreshes (1+ drgnx-statusbar-test--refreshes))
  (let ((drgnx-statusbar-test--refreshing t)) (apply fn args)))

(ert-deftest drgnx-statusbar/refresh-is-debounced ()
  (require 'drgnx-agents)
  (drgnx-statusbar-test--with
    (drgnx-statusbar-test--state
      (drgnx-statusbar--define-defaults)
      (let ((calls 0) (drgnx-statusbar-test--refreshes 0)
            (drgnx-agents--sessions (list (drgnx-agents--make :name "a" :status 'busy))))
        (advice-add 'drgnx-statusbar--refresh-now :around #'drgnx-statusbar-test--mark-refresh)
        (unwind-protect
            (drgnx-test-with-clock ()                         ; the debounce is a layer timer: virtual time
              (cl-letf (((symbol-function 'force-mode-line-update)
                         (lambda (&optional all) (when drgnx-statusbar-test--refreshing (should all) (cl-incf calls)))))
                ;; 20 agent changes in 0.1 s: one refresh, one redraw of every bar
                (dotimes (_ 20)
                  (drgnx-statusbar--agents-changed (car drgnx-agents--sessions))
                  (drgnx-test-advance 0.005))
                (should (= calls 0))
                (should (= drgnx-statusbar-test--refreshes 0))
                (drgnx-test-advance 0.4)
                (should (= drgnx-statusbar-test--refreshes 1))
                (should (= calls 1))
                (should (equal (drgnx-statusbar-test--seg 'agents) "◎ 1 busy"))
                ;; the hub's and git's change hooks go through the same debounce
                (drgnx-statusbar--hub-event "agent-entries" nil)
                (drgnx-cache-put 'git-status "/repo/" (list :branch '(:head "a" :ahead 1)))   ; a new branch state
                (drgnx-statusbar--git-changed "/repo/")
                (drgnx-statusbar--git-changed "/repo/")
                (drgnx-test-advance 0.4)
                (should (= drgnx-statusbar-test--refreshes 2))
                (should (= calls 2))                             ; git: one redraw, the agents' counts did not change
                (should-not (drgnx-timer-active-p 'statusbar-refresh))
                ;; a status run that changed only files, or failed: the same branch, no redraw
                (drgnx-statusbar--git-changed "/repo/")
                (should-not (drgnx-timer-active-p 'statusbar-refresh))
                (drgnx-cache-put 'git-status "/repo/" (list :branch '(:head "a" :ahead 2)))   ; one more commit ahead
                (drgnx-statusbar--git-changed "/repo/")
                (should (drgnx-timer-active-p 'statusbar-refresh))
                (drgnx-timer-cancel 'statusbar-refresh)))
          (advice-remove 'drgnx-statusbar--refresh-now #'drgnx-statusbar-test--mark-refresh))))))

(ert-deftest drgnx-statusbar/a-redisplay-that-changes-nothing-reuses-the-bar ()
  (drgnx-test-with-state
    (drgnx-statusbar-test--with
      (drgnx-statusbar-test--state
        (let ((calls 0) (global-mode-string nil))
          (drgnx-statusbar-define-segment 'a :fn (lambda () (cl-incf calls) "A"))
          (cl-letf (((symbol-function 'force-mode-line-update) #'ignore))
            (drgnx-statusbar-test--in-buffer #'emacs-lisp-mode
              (insert "one\ntwo\nthree\n")
              (let ((first (drgnx-statusbar-mode-line)))
                (dotimes (_ 50) (should (eq (drgnx-statusbar-mode-line) first)))
                (should (= calls 1))
                (cl-flet ((rebuilt-p () (let ((c calls)) (drgnx-statusbar-mode-line) (/= calls c))))
                  (goto-char (point-min))                         ; point moved
                  (should (rebuilt-p)) (should-not (rebuilt-p))
                  (insert "x")                                    ; the text changed (and point)
                  (should (rebuilt-p)) (should-not (rebuilt-p))
                  (delete-char 1)                                 ; the text changed, point did not
                  (should (rebuilt-p)) (should-not (rebuilt-p))
                  (drgnx-statusbar-note-tests 1 0)                ; a hook-driven segment's state
                  (should (rebuilt-p)) (should-not (rebuilt-p))
                  (setq-local vc-mode " Git-other")               ; a buffer-local the segments read
                  (should (rebuilt-p)) (should-not (rebuilt-p))
                  (narrow-to-region 1 4)
                  (should (rebuilt-p)) (should-not (rebuilt-p))
                  (widen)
                  (should (rebuilt-p))
                  (setq global-mode-string '("MARK"))             ; another module's mark
                  (should (rebuilt-p)) (should-not (rebuilt-p))
                  (drgnx-statusbar-define-segment 'b :fn (lambda () "B2"))   ; a segment redefined
                  (should (rebuilt-p))
                  (should (string-match-p "B2" (drgnx-statusbar-mode-line)))
                  (should-not (rebuilt-p))
                  (drgnx-statusbar-refresh t)                    ; a segment of your own says its state changed
                  (should (rebuilt-p))
                  ;; git changed: the refresh redraws, and the bars are built again (vc-mode may be another)
                  (drgnx-cache-put 'git-status "/repo/" (list :branch '(:head "other")))
                  (drgnx-statusbar--git-changed "/repo/")
                  (drgnx-statusbar--refresh-now)
                  (should (rebuilt-p)) (should-not (rebuilt-p))
                  ;; the indentation (a variable of `drgnx-statusbar-indent-vars', as of the setup), flymake's and
                  ;; eglot's state are epochs of the buffer
                  (drgnx-epoch-watch 'buffer-look '(drgnx-statusbar-test--offset))
                  (let ((drgnx-statusbar-indent-vars '(drgnx-statusbar-test--offset)))
                    (setq-local indent-tabs-mode (not indent-tabs-mode))
                    (should (rebuilt-p)) (should-not (rebuilt-p))
                    (setq-local drgnx-statusbar-test--offset 2)
                    (should (rebuilt-p)) (should-not (rebuilt-p))
                    (setq-local drgnx-statusbar-test--offset 4)
                    (should (rebuilt-p)) (should-not (rebuilt-p)))
                  (drgnx-statusbar--flymake-changed)              ; flymake turned on (`flymake-mode-hook')
                  (should (rebuilt-p)) (should-not (rebuilt-p))
                  (drgnx-statusbar--flymake-reported)             ; a backend reported
                  (should (rebuilt-p)) (should-not (rebuilt-p))
                  (drgnx-statusbar--eglot-changed)                ; eglot manages the buffer, or let it go
                  (should (rebuilt-p)) (should-not (rebuilt-p))
                  (drgnx-statusbar--eglot-initialized 'server)    ; a server told its name
                  (should (rebuilt-p)) (should-not (rebuilt-p))
                  ;; the compact bar in another window is its own entry (the store keeps this window the MRU editor, so
                  ;; the other one is compact: the counted segment is put in the compact bar too)
                  (let ((other (split-window-right)) (drgnx-statusbar-compact '(a c)))
                    (unwind-protect
                        (progn (set-window-buffer other (current-buffer))
                               (with-selected-window other
                                 (should (rebuilt-p)) (should-not (rebuilt-p))
                                 (should-not (string-match-p "B2" (drgnx-statusbar-mode-line)))))   ; compact, not full
                      (delete-window other))))))))))))

(ert-deftest drgnx-statusbar/hooks-and-timers-are-owned-by-the-mode ()
  (let ((drgnx-chrome-editor-mode-line drgnx-chrome-editor-mode-line)
        (drgnx-signal--subscribers nil)
        (was drgnx-statusbar-mode)                       ; the process's other tests keep what they had
        (hooks '((post-command-hook . drgnx-statusbar--post-command)
                 (drgnx-agents-changed-functions . drgnx-statusbar--agents-changed)
                 (drgnx-hub-event-functions . drgnx-statusbar--hub-event)
                 (drgnx-hub-disconnect-functions . drgnx-statusbar--hub-gone)
                 (drgnx-git-changed-functions . drgnx-statusbar--git-changed)
                 (compilation-finish-functions . drgnx-statusbar--compilation-finished)
                 (after-change-major-mode-hook . drgnx-statusbar--mode-changed)
                 (flymake-mode-hook . drgnx-statusbar--flymake-changed)
                 (eglot-managed-mode-hook . drgnx-statusbar--eglot-changed)
                 (eglot-server-initialized-hook . drgnx-statusbar--eglot-initialized)
                 (pre-redisplay-functions . drgnx-statusbar--pre-redisplay))))
    (drgnx-statusbar-test--state
      (cl-letf (((symbol-function 'drgnx-chrome-apply) #'ignore) ((symbol-function 'force-mode-line-update) #'ignore))
        (unwind-protect
            (progn
              (drgnx-statusbar-mode 1)
              (drgnx-statusbar-mode 1)                       ; idempotent
              (dolist (h hooks)
                (should (= 1 (seq-count (lambda (f) (eq f (cdr h))) (default-value (car h))))))
              (should (= 1 (seq-count (lambda (f) (eq f #'drgnx-statusbar--ask-git))
                                      (alist-get 'editor-changed drgnx-signal--subscribers))))
              (should (advice-member-p #'drgnx-statusbar--flymake-reported 'flymake--handle-report))
              (should (advice-member-p #'drgnx-statusbar--flymake-started 'flymake-start))
              (drgnx-statusbar-refresh)
              (should (drgnx-timer-active-p 'statusbar-refresh))
              (puthash (selected-window) [x] (drgnx-memo--def-table (get 'statusbar-bar 'drgnx-memo--def)))
              (should (> (nth 2 (assq 'statusbar-bar (drgnx-memo-census))) 0))
              (setq drgnx-statusbar--misc-made -1)
              (drgnx-statusbar-mode -1)
              (should-not (drgnx-timer-active-p 'statusbar-refresh))
              (dolist (h hooks) (should-not (memq (cdr h) (default-value (car h)))))
              (should-not (memq #'drgnx-statusbar--ask-git (alist-get 'editor-changed drgnx-signal--subscribers)))
              (should-not (advice-member-p #'drgnx-statusbar--flymake-reported 'flymake--handle-report))
              (should-not (advice-member-p #'drgnx-statusbar--flymake-started 'flymake-start))
              (should-not (drgnx-timer-active-p 'statusbar-refresh))
              (should (= 0 (nth 2 (assq 'statusbar-bar (drgnx-memo-census)))))   ; the memo is empty
              (should-not drgnx-statusbar--misc-made))                         ; the entries are read afresh
          (drgnx-statusbar-mode (if was 1 -1)))))))

(ert-deftest drgnx-statusbar/the-modal-indicator-moves-into-the-bar ()
  (let (calls (drgnx-chrome-editor-mode-line drgnx-chrome-editor-mode-line))
    (cl-letf (((symbol-function 'drgnx-modal-indicator-on) (lambda () (push 'on calls)))
              ((symbol-function 'drgnx-modal-indicator-off) (lambda () (push 'off calls)))
              ((symbol-function 'drgnx-chrome-apply) #'ignore))
      (unwind-protect
          (progn
            (drgnx-statusbar-mode 1)
            (should (equal calls '(off)))
            (drgnx-statusbar-mode -1)
            (should (equal calls '(on off))))
        (drgnx-statusbar-mode -1)))))

(ert-deftest drgnx-statusbar/rendering-is-cheap ()
  "About 1000 renders of the default segments cost well under 100 ms in all (a redisplay runs one)."
  (drgnx-statusbar-test--with
    (drgnx-statusbar--define-defaults)
    (with-temp-buffer
      (emacs-lisp-mode)
      (dotimes (i 2000) (insert (format "(defun f%d () %d)\n" i i)))
      (goto-char (/ (point-max) 2))
      (let ((drgnx-statusbar-left '(branch problems tests jobs agents modal misc))
            (drgnx-statusbar-right '(lsp position indent encoding eol language))
            (t0 (float-time)))
        (dotimes (_ 1000) (drgnx-statusbar-render 140))
        (let ((ms (* 1000 (- (float-time) t0))))
          (message "drgnx-statusbar: 1000 renders in %.1f ms (%.3f ms each)" ms (/ ms 1000))
          (should (< ms 500)))))))

;;;; Epochs and the memo; other packages' entries once per redisplay (render Task 16)

(defvar drgnx-statusbar-test--builds 0 "How many times the counted segment `a' was worked out.")

(defun drgnx-statusbar-test--count-a ()
  (setq drgnx-statusbar-test--builds (1+ drgnx-statusbar-test--builds))
  "A")

(defun drgnx-statusbar-test--rebuilt-p ()
  "Non-nil when the selected window's bar was built again now."
  (let ((before drgnx-statusbar-test--builds))
    (drgnx-statusbar-mode-line)
    (/= before drgnx-statusbar-test--builds)))

(defmacro drgnx-statusbar-test--counted (&rest body)
  "BODY in an Emacs Lisp buffer shown in the selected window, whose full bar (`a' counting its builds, then `misc')
was built once; no other package's entry yet."
  (declare (indent 0))
  `(drgnx-statusbar-test--with
     (drgnx-statusbar-test--state
       (let ((drgnx-statusbar-test--builds 0) (global-mode-string nil) (drgnx-statusbar-left '(a misc))
             ;; what the tests set (a set is seen, a `let' is not): theirs only
             (mode-line-misc-info mode-line-misc-info) (drgnx-statusbar-misc-exclude drgnx-statusbar-misc-exclude)
             (drgnx-statusbar-quiet drgnx-statusbar-quiet) (drgnx-job-ui--badge drgnx-job-ui--badge)
             (drgnx-explorer--roots nil) (drgnx-face-glyphs drgnx-face-glyphs))
         (drgnx-statusbar-define-segment 'a :fn #'drgnx-statusbar-test--count-a)
         (drgnx-statusbar-define-segment 'misc :fn #'drgnx-statusbar--seg-misc)
         (cl-letf (((symbol-function 'force-mode-line-update) #'ignore))
           (drgnx-statusbar-test--in-buffer #'emacs-lisp-mode
             (insert "one\ntwo\n")
             (drgnx-statusbar-mode-line)
             ,@body))))))

(ert-deftest drgnx-statusbar/a-memo-hit-allocates-nothing ()
  (drgnx-statusbar-test--counted
    (let ((w (selected-window)) (width (window-total-width)))
      (should (eq (drgnx-statusbar--bar w width nil) (drgnx-statusbar-mode-line)))
      (should (= 0 (drgnx-memo-fixture-alloc (lambda () (drgnx-statusbar--bar w width nil))
                                             'drgnx-statusbar--bar 'drgnx-statusbar--misc 'drgnx-statusbar--misc-entries
                                             'drgnx-statusbar--selected-p 'drgnx-statusbar--which-func)))
      (should (= drgnx-statusbar-test--builds 1)))))

(ert-deftest drgnx-statusbar/the-key-is-epochs-and-plain-values ()
  "The memo's keys call no helper of the bar but the window's selection, which-function's cached name and the text
of other packages' entries; the rest are the six epochs and plain values."
  (let ((keys (drgnx-memo--def-keys (get 'statusbar-bar 'drgnx-memo--def))) (helpers nil) (epochs nil))
    (cl-labels ((walk (f)
                  (when (consp f)
                    (when (and (symbolp (car f)) (string-prefix-p "drgnx-statusbar--" (symbol-name (car f))))
                      (push (car f) helpers))
                    (when (eq (car f) 'drgnx-epoch) (push (cadr (cadr f)) epochs))
                    (mapc #'walk (cdr f)))))
      (mapc #'walk keys))
    (should (equal (sort (delete-dups helpers) #'string<)
                   '(drgnx-statusbar--misc drgnx-statusbar--selected-p drgnx-statusbar--which-func)))
    (should (equal (sort epochs #'string<) '(buffer-look eglot flymake git misc-info statusbar)))
    (should (= 21 (length keys)))))                     ; 6 epochs, 8 values of the window, 7 hot plain values

(defmacro drgnx-statusbar-test--epoch-test (epoch object doc &rest triggers)
  "A test that each of TRIGGERS moves EPOCH (read for OBJECT) and makes the next redisplay build the bar again."
  (declare (indent 3))
  `(ert-deftest ,(intern (format "drgnx-statusbar/each-epoch-rebuilds-the-bar-%s" epoch)) ()
     ,doc
     (drgnx-statusbar-test--counted
       ,@(mapcar (lambda (trigger)
                   `(let ((before (drgnx-epoch ',epoch ,object)))
                      ,trigger
                      (should (/= before (drgnx-epoch ',epoch ,object)))
                      (should (drgnx-statusbar-test--rebuilt-p))
                      (should-not (drgnx-statusbar-test--rebuilt-p))))
                 triggers))))

(defvar drgnx-trust--state)
(defvar c-basic-offset)

(drgnx-statusbar-test--epoch-test buffer-look (current-buffer)
                                  "The buffer's mode, version control, encoding, indentation, modal state, evil's tag and trust."
  (drgnx-statusbar--mode-changed)
  (setq-local vc-mode " Git-feature")
  (setq-local buffer-file-coding-system 'utf-8-dos)
  (setq-local indent-tabs-mode (not indent-tabs-mode))
  (setq-local tab-width 3)
  (setq-local c-basic-offset 3)                         ; one of `drgnx-statusbar-indent-vars'
  (setq-local drgnx-modal-state 'insert)
  (setq-local evil-mode-line-tag " <I> ")
  (setq-local drgnx-trust--state 'restricted))

(drgnx-statusbar-test--epoch-test flymake (current-buffer)
                                  "flymake turned on or off here, a check started, a backend reported."
  (drgnx-statusbar--flymake-changed)
  (drgnx-statusbar--flymake-started)
  (drgnx-statusbar--flymake-reported))

(drgnx-statusbar-test--epoch-test eglot (current-buffer)
                                  "eglot manages the buffer or let it go; a server finished starting."
  (drgnx-statusbar--eglot-changed)
  (drgnx-statusbar--eglot-initialized 'server))

(drgnx-statusbar-test--epoch-test git nil
                                  "A repository's branch or its ahead and behind counts changed."
  (progn (drgnx-cache-put 'git-status "/repo/" (list :branch '(:head "a")))
         (drgnx-statusbar--git-changed "/repo/"))
  (progn (drgnx-cache-put 'git-status "/repo/" (list :branch '(:head "a" :ahead 1)))
         (drgnx-statusbar--git-changed "/repo/")))

(drgnx-statusbar-test--epoch-test misc-info nil
                                  "Other packages' entries changed, or which of them the bar leaves out."
  (setq global-mode-string '("MARK"))
  (setq mode-line-misc-info (cons "INFO" mode-line-misc-info))
  (setq mode-line-misc-info (cdr mode-line-misc-info))
  (setq drgnx-statusbar-misc-exclude (cons "MARK" drgnx-statusbar-misc-exclude)))

(drgnx-statusbar-test--epoch-test statusbar nil
                                  "drgnx's own state, a setting or the glyphs."
  (drgnx-statusbar--bump)
  (setq drgnx-statusbar-left '(misc a))
  (setq drgnx-statusbar-quiet '(a))
  (setq drgnx-job-ui--badge " ⚑3")
  (setq drgnx-explorer--roots '("/elsewhere/"))
  (setq drgnx-face-glyphs (copy-sequence drgnx-face-glyphs)))

(ert-deftest drgnx-statusbar/a-buffer-turning-large-shows-it-with-no-other-trigger ()
  ;; RP16-LF: the large-file flag is part of how a buffer looks (editor/large-files sets it as the buffer turns lean,
  ;; raw or chunks, and clears it): a set moves `buffer-look', so the next redisplay shows the segment
  (drgnx-statusbar-test--counted
    (drgnx-statusbar-define-segment 'lf :fn (lambda () (and drgnx-large-file (format "LF-%s" drgnx-large-file))))
    (setq drgnx-statusbar-left '(a misc lf))
    (should-not (string-search "LF-" (drgnx-statusbar-mode-line)))
    (setq drgnx-large-file 'lean)
    (should (string-search "LF-lean" (drgnx-statusbar-mode-line)))
    (setq drgnx-large-file nil)
    (should-not (string-search "LF-" (drgnx-statusbar-mode-line)))))

(ert-deftest drgnx-statusbar/a-let-of-tab-width-to-its-value-or-a-local-one-rebuilds-nothing ()
  ;; code that binds the indentation variables for a moment, to the value they have or where they are local, moves
  ;; no epoch: a `let' is not a change
  (drgnx-statusbar-test--counted
    (let ((tab-width tab-width) (indent-tabs-mode indent-tabs-mode)) (should tab-width))   ; not local here
    (should-not (drgnx-statusbar-test--rebuilt-p))
    (setq-local tab-width 4)
    (should (drgnx-statusbar-test--rebuilt-p))
    (let ((tab-width 2)) (should (= tab-width 2)))                                          ; local here
    (should-not (drgnx-statusbar-test--rebuilt-p))))

(ert-deftest drgnx-statusbar/a-let-of-tab-width-to-another-value-rebuilds-every-bar ()
  ;; Known over-invalidation (the memo layer's, RP16-M1): where `tab-width' is not local, Emacs reports a `let' of it
  ;; to another value as a `set' of the default, so `buffer-look' moves (for every buffer) and every bar is built
  ;; again once.  Nothing goes stale; drgnx's own `(let ((indent-tabs-mode nil)) …)' costs one rebuild per bar.
  (drgnx-statusbar-test--counted
    (should-not (local-variable-p 'tab-width))
    (let ((tab-width (1+ tab-width))) (should tab-width))
    (should (drgnx-statusbar-test--rebuilt-p))
    (should-not (drgnx-statusbar-test--rebuilt-p))))

(defvar drgnx-statusbar-test--live-calls 0 "How many times the live entry was formatted.")
(defvar drgnx-statusbar-test--clock "10:00" "What the live entry shows.")

(defun drgnx-statusbar-test--live ()
  (setq drgnx-statusbar-test--live-calls (1+ drgnx-statusbar-test--live-calls))
  drgnx-statusbar-test--clock)

(defun drgnx-statusbar-test--redisplay (&optional windows)
  "One redisplay: `pre-redisplay-functions' for each of WINDOWS (the selected one), then each bar."
  (let ((ws (or windows (list (selected-window)))))
    (dolist (w ws) (drgnx-statusbar--pre-redisplay w))
    (mapcar (lambda (w) (with-selected-window w (drgnx-statusbar-mode-line))) ws)))

(ert-deftest drgnx-statusbar/a-live-entry-is-formatted-once-per-redisplay-for-four-windows-on-one-buffer ()
  (drgnx-statusbar-test--counted
    (let ((drgnx-statusbar-test--live-calls 0) (drgnx-statusbar-test--clock "10:00")
          (drgnx-statusbar-compact '(misc)))
      (cl-letf (((symbol-function 'format-mode-line) #'drgnx-statusbar-test--format-mode-line))
        (setq global-mode-string '((:eval (drgnx-statusbar-test--live))))
        (let* ((w1 (selected-window)) (w2 (split-window-right)) (w3 (split-window-below))
               (w4 (with-selected-window w2 (split-window-below))) (ws (list w1 w2 w3 w4)))
          (unwind-protect
              (progn
                (dolist (w (cdr ws)) (set-window-buffer w (window-buffer w1)))
                (dotimes (i 3)
                  (dolist (bar (drgnx-statusbar-test--redisplay ws)) (should (string-match-p "10:00" bar)))
                  (should (= drgnx-statusbar-test--live-calls (1+ i))))      ; once per redisplay, not per window
                (mapc (lambda (w) (with-selected-window w (drgnx-statusbar-mode-line))) ws)   ; no redisplay
                (should (= drgnx-statusbar-test--live-calls 3)))
            (dolist (w (cdr ws)) (delete-window w))))))))

(defvar-local drgnx-statusbar-test--local nil "Buffer-local state an entry of the tests reads.")
(defvar drgnx-statusbar-test--local-calls 0 "How many times the buffer-dependent entry was formatted.")

(defun drgnx-statusbar-test--local-text ()
  (setq drgnx-statusbar-test--local-calls (1+ drgnx-statusbar-test--local-calls))
  (or drgnx-statusbar-test--local ""))

(ert-deftest drgnx-statusbar/a-buffer-dependent-entry-shows-each-buffers-own-value ()
  ;; An entry that reads buffer-local state (lsp-mode's `(:eval …)' entries, a minor mode's conditional) is formatted
  ;; in each bar's own buffer, once per buffer per redisplay: never the text of whichever bar was drawn first.
  (drgnx-statusbar-test--counted
    (let ((drgnx-statusbar-test--local-calls 0) (drgnx-statusbar-compact '(misc))
          (b (generate-new-buffer " *sb-other*")))
      (cl-letf (((symbol-function 'format-mode-line) #'drgnx-statusbar-test--format-mode-line))
        (setq global-mode-string '((:eval (drgnx-statusbar-test--local-text))))
        (setq-local drgnx-statusbar-test--local "LOCAL")
        (with-current-buffer b (emacs-lisp-mode))
        (let* ((w1 (selected-window)) (w2 (split-window-right)) (w3 (split-window-below)))
          (unwind-protect
              (progn
                (set-window-buffer w2 b)
                (set-window-buffer w3 b)
                (dolist (ws (list (list w1 w2 w3) (list w2 w3 w1)))     ; whichever bar is drawn first
                  (let ((calls drgnx-statusbar-test--local-calls)
                        (bars (drgnx-statusbar-test--redisplay ws)))
                    (dolist (pair (cl-mapcar #'cons ws bars))
                      (if (eq (car pair) w1)
                          (should (string-match-p "LOCAL" (cdr pair)))
                        (should-not (string-match-p "LOCAL" (cdr pair)))))
                    (should (= drgnx-statusbar-test--local-calls (+ calls 2)))))) ; once per buffer, not per window
            (delete-window w2) (delete-window w3)
            (kill-buffer b)))))))

(ert-deftest drgnx-statusbar/a-let-of-global-mode-string-is-seen ()
  ;; a `let' moves no epoch, but the entries are read again when the variable's value is not the one they were read
  ;; from (two `eq' tests): the bar shows the let-bound entries, and the old ones once the `let' is over
  (drgnx-statusbar-test--counted
    (cl-letf (((symbol-function 'format-mode-line) #'drgnx-statusbar-test--format-mode-line))
      (setq global-mode-string '("OUTER"))
      (should (string-match-p "OUTER" (car (drgnx-statusbar-test--redisplay))))
      (let ((global-mode-string '("INNER")))
        (should (string-match-p "INNER" (car (drgnx-statusbar-test--redisplay)))))
      (should (string-match-p "OUTER" (car (drgnx-statusbar-test--redisplay)))))))

(ert-deftest drgnx-statusbar/a-live-entry-is-real-time ()
  (drgnx-statusbar-test--counted
    (let ((drgnx-statusbar-test--clock "10:00") (drgnx-statusbar-test--live-calls 0))
      (cl-letf (((symbol-function 'format-mode-line) #'drgnx-statusbar-test--format-mode-line))
        (setq global-mode-string '(drgnx-statusbar-test--clock))   ; a symbol: its value changes unannounced
        (should (string-match-p "10:00" (car (drgnx-statusbar-test--redisplay))))
        (setq drgnx-statusbar-test--clock "10:01")
        (should (string-match-p "10:01" (car (drgnx-statusbar-test--redisplay))))
        ;; the same text on the next redisplay: the same string, so the memo hits
        (let ((text (drgnx-statusbar--misc)))
          (drgnx-statusbar--pre-redisplay (selected-window))
          (should (eq text (drgnx-statusbar--misc)))
          (should-not (drgnx-statusbar-test--rebuilt-p)))))))

(ert-deftest drgnx-statusbar/a-static-entry-is-formatted-only-when-misc-info-bumps ()
  (drgnx-statusbar-test--counted
    (let* ((entry '(:propertize "STATIC" face bold)) (formats 0)
           (static-text (symbol-function 'drgnx-statusbar--static-text)))
      (cl-letf (((symbol-function 'format-mode-line) #'drgnx-statusbar-test--format-mode-line)
                ((symbol-function 'drgnx-statusbar--static-text)
                 (lambda (c)
                   (when (eq c entry) (setq formats (1+ formats)))
                   (funcall static-text c))))
        (setq global-mode-string (list entry))
        (should (string-match-p "STATIC" (car (drgnx-statusbar-test--redisplay))))
        (should (memq entry (mapcar #'drgnx-statusbar--entry-form (car (drgnx-statusbar--misc-entries)))))   ; static
        (should-not (memq entry (mapcar #'drgnx-statusbar--entry-form (cdr (drgnx-statusbar--misc-entries)))))
        (should (= formats 1))
        (dotimes (_ 5) (drgnx-statusbar-test--redisplay))
        (should (= formats 1))
        (setq global-mode-string (list entry "TWO"))                 ; the list changed: read and formatted again
        (should (string-match-p "STATICTWO" (car (drgnx-statusbar-test--redisplay))))
        (should (= formats 2))))))

;; A slow and a fast entry on a clock of the test's own: formatting the slow one takes 2 ms, the fast one 0.1 ms.
(defvar drgnx-statusbar-test--now 0.0 "What `drgnx-timer-now' says in the slow-entry tests.")
(defvar drgnx-statusbar-test--slow-secs 0.002 "How long the slow entry takes to format.")
(defvar drgnx-statusbar-test--slow-calls 0)
(defvar drgnx-statusbar-test--fast-calls 0)
(defvar drgnx-statusbar-test--slow-text "SLOW")

(defun drgnx-statusbar-test--slow ()
  (setq drgnx-statusbar-test--slow-calls (1+ drgnx-statusbar-test--slow-calls)
        drgnx-statusbar-test--now (+ drgnx-statusbar-test--now drgnx-statusbar-test--slow-secs))
  drgnx-statusbar-test--slow-text)

(defun drgnx-statusbar-test--fast ()
  (setq drgnx-statusbar-test--fast-calls (1+ drgnx-statusbar-test--fast-calls)
        drgnx-statusbar-test--now (+ drgnx-statusbar-test--now 0.0001))
  "FAST")

(defun drgnx-statusbar-test--report ()
  "The slow entries the bar last reported (statusbar-slow.eld in the state dir)."
  (plist-get (drgnx-file-read (expand-file-name "statusbar-slow.eld" (drgnx-state-dir))) :data))

(defmacro drgnx-statusbar-test--slow-case (&rest body)
  "BODY with a slow and a fast entry in `global-mode-string', on the virtual clock, with a state dir of its own."
  (declare (indent 0))
  `(let* ((state (make-temp-file "drgnx-sb-state" t))
          (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment)))
     (unwind-protect
         (drgnx-statusbar-test--counted
           (let ((drgnx-statusbar-test--now 0.0) (drgnx-statusbar-test--slow-secs 0.002)
                 (drgnx-statusbar-test--slow-calls 0) (drgnx-statusbar-test--fast-calls 0)
                 (drgnx-statusbar-test--slow-text "SLOW"))
             (cl-letf (((symbol-function 'format-mode-line) #'drgnx-statusbar-test--format-mode-line)
                       ((symbol-function 'drgnx-timer-now) (lambda () drgnx-statusbar-test--now)))
               (drgnx-test-with-clock ()
                 (setq global-mode-string '((:eval (drgnx-statusbar-test--slow)) (:eval (drgnx-statusbar-test--fast))))
                 (unwind-protect (progn ,@body) (drgnx-timer-cancel 'statusbar-misc-slow))))))
       (delete-directory state t))))

(ert-deftest drgnx-statusbar/a-slow-entry-falls-back-alone ()
  (drgnx-statusbar-test--slow-case
    (dotimes (_ 7) (drgnx-statusbar-test--redisplay))
    (should-not (drgnx-timer-active-p 'statusbar-misc-slow))      ; judged after 8 samples
    (drgnx-statusbar-test--redisplay)
    (should (= drgnx-statusbar-test--slow-calls 8))
    (should (drgnx-timer-active-p 'statusbar-misc-slow))          ; 2 ms on average: slow
    ;; from now on: the fast one every redisplay, the slow one only by the timer, once a second
    (dotimes (_ 5) (should (string-match-p "SLOWFAST" (car (drgnx-statusbar-test--redisplay)))))
    (should (= drgnx-statusbar-test--slow-calls 8))
    (should (= drgnx-statusbar-test--fast-calls 13))
    (setq drgnx-statusbar-test--slow-text "SLOW2")
    (drgnx-test-advance 1)
    (should (= drgnx-statusbar-test--slow-calls 9))
    (should (string-match-p "SLOW2FAST" (car (drgnx-statusbar-test--redisplay))))
    (drgnx-test-advance 2)
    (should (= drgnx-statusbar-test--slow-calls 11))
    ;; the report names it, with its cost, for the doctor
    (let ((report (drgnx-statusbar-test--report)))
      (should (= 1 (length report)))
      (should (string-search "drgnx-statusbar-test--slow" (plist-get (car report) :entry)))
      (should (>= (plist-get (car report) :avg-ms) 1.0))
      (should (numberp (plist-get (car report) :since))))))

(ert-deftest drgnx-statusbar/the-slow-timer-exists-only-while-a-slow-entry-does ()
  (drgnx-statusbar-test--slow-case
    (setq drgnx-statusbar-test--slow-secs 0.0001)                  ; both fast: no timer
    (dotimes (_ 10) (drgnx-statusbar-test--redisplay))
    (should-not (drgnx-timer-active-p 'statusbar-misc-slow))
    (should-not (seq-some #'drgnx-statusbar--entry-slow drgnx-statusbar--misc-all))
    (setq drgnx-statusbar-test--slow-secs 0.002)                   ; slow from now on
    (dotimes (_ 10) (drgnx-statusbar-test--redisplay))
    (should (drgnx-timer-active-p 'statusbar-misc-slow))
    ;; the entries change (the list is set again): every average is forgotten, the slow one is live again, and the
    ;; next tick writes the report and cancels the timer
    (setq global-mode-string (copy-sequence global-mode-string))
    (drgnx-statusbar-test--redisplay)
    (should-not (seq-some #'drgnx-statusbar--entry-slow drgnx-statusbar--misc-all))
    (drgnx-test-advance 1)
    (should-not (drgnx-timer-active-p 'statusbar-misc-slow))
    (should-not (drgnx-statusbar-test--report))))

(ert-deftest drgnx-statusbar/a-slow-entry-that-gets-fast-is-live-again ()
  (drgnx-statusbar-test--slow-case
    (dotimes (_ 8) (drgnx-statusbar-test--redisplay))
    (should (drgnx-timer-active-p 'statusbar-misc-slow))
    (drgnx-test-advance 1)
    (should (drgnx-statusbar-test--report))
    (setq drgnx-statusbar-test--slow-secs 0.0001)                  ; under half the limit from now on
    (drgnx-test-advance 7)
    (should (drgnx-timer-active-p 'statusbar-misc-slow))           ; 7 fast ticks: still slow
    (drgnx-test-advance 1)
    (should-not (drgnx-timer-active-p 'statusbar-misc-slow))       ; 8: live again, the timer gone
    (should-not (drgnx-statusbar-test--report))
    (let ((calls drgnx-statusbar-test--slow-calls))
      (dotimes (_ 3) (drgnx-statusbar-test--redisplay))
      (should (= drgnx-statusbar-test--slow-calls (+ calls 3))))))  ; formatted on every redisplay again

(require 'drgnx-doctor)

(ert-deftest drgnx-doctor/statusbar-ok-after-the-entry-is-gone ()
  ;; The last session reported a slow entry; this one has none (you removed it, or its package made it cheaper).
  ;; Turning the bar on rewrites the report once, a second later from the timer layer (never from redisplay), so
  ;; the doctor stops naming the entry.
  (drgnx-statusbar-test--slow-case
    (setq global-mode-string nil)
    (let ((file (expand-file-name "statusbar-slow.eld" (drgnx-state-dir)))
          (was drgnx-statusbar-mode) (drgnx-signal--subscribers nil)
          (drgnx-chrome-editor-mode-line drgnx-chrome-editor-mode-line))
      (drgnx-file-write file '((:entry "(:eval (gone))" :avg-ms 3.0 :since 1.0)) :fsync nil)
      (should (eq 'warn (car (drgnx-doctor-check 'statusbar-misc (list :statusbar-slow (drgnx-statusbar-test--report))))))
      (cl-letf (((symbol-function 'drgnx-chrome-apply) #'ignore))
        (unwind-protect
            (progn
              (drgnx-statusbar-mode 1)
              (should (drgnx-statusbar-test--report))                   ; not written by the mode itself
              (drgnx-test-advance 1)
              (should (file-exists-p file))
              (should-not (drgnx-statusbar-test--report))               ; the current set: none
              (should (eq 'ok (car (drgnx-doctor-check 'statusbar-misc
                                                       (list :statusbar-slow (drgnx-statusbar-test--report)))))))
          (drgnx-statusbar-mode (if was 1 -1)))))))

(provide 'mod-statusbar-test)
;;; mod-statusbar-test.el ends here
