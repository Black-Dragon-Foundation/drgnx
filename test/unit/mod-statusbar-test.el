;;; mod-statusbar-test.el --- batch tests: the status bar — segments as data (M12f A3) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-chrome)
(load (expand-file-name "modules/ui/drgnx-face" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-statusbar" drgnx-dir) nil t)
(defvar drgnx-job-ui--badge)
(defvar compilation-arguments)
(defvar flymake-mode)
(defvar eglot--cached-server)
(defvar drgnx-statusbar-test--offset nil "An indentation variable of a test.")

(defmacro drgnx-statusbar-test--with (&rest body)
  "BODY with the status bar's segments, lists and error record kept away from the rest of the test process.
Segments a, b, c are defined: their text is A, B, C."
  (declare (indent 0))
  `(let ((drgnx-statusbar--segments (make-hash-table :test #'eq))
         (drgnx-statusbar--errors nil)
         (drgnx-statusbar-left '(a b)) (drgnx-statusbar-right '(c))
         (drgnx-statusbar-drop-order drgnx-statusbar-drop-order)
         (drgnx-statusbar-compact '(c))
         (drgnx-statusbar--window nil))
     ;; the batch terminal is not UTF-8: the tests that look at glyphs say which they mean
     (cl-letf (((symbol-function 'drgnx-face--ascii-frame-p) (lambda (_frame) nil)))
       (drgnx-statusbar-define-segment 'a :fn (lambda () "A"))
       (drgnx-statusbar-define-segment 'b :fn (lambda () "B"))
       (drgnx-statusbar-define-segment 'c :fn (lambda () "C"))
       ,@body)))

(defmacro drgnx-statusbar-test--in-buffer (mode &rest body)
  "BODY in a temp buffer in MODE, shown in the selected window (the bar reads the window's buffer)."
  (declare (indent 1))
  `(let ((old (window-buffer (selected-window))))
     (with-temp-buffer
       (funcall ,mode)
       (set-window-buffer (selected-window) (current-buffer))
       (unwind-protect (progn ,@body)
         (set-window-buffer (selected-window) old)))))

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
        (should (string-match-p "…" plain))
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
  (drgnx-statusbar-test--with
    (let ((w1 (selected-window)) w2 (buf (generate-new-buffer " *sb-test*")))
      (with-current-buffer buf (emacs-lisp-mode))
      (unwind-protect
          (progn
            (delete-other-windows)
            (setq w1 (selected-window) w2 (split-window-right))
            (set-window-buffer w1 buf)
            (set-window-buffer w2 buf)
            (let ((drgnx-signal--editor-window w2))
              (let ((full (with-current-buffer buf (with-selected-window w2 (drgnx-statusbar-mode-line))))
                    (other (with-current-buffer buf (with-selected-window w1 (drgnx-statusbar-mode-line)))))
                (should (string-match-p "A · B" full))
                (should (string-match-p "C" full))
                (should-not (string-match-p "A" other))
                (should (string-match-p "C" other))))
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
      (should-not (drgnx-statusbar-mode-line)))))

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
      (let ((drgnx-statusbar-tests-state nil) (drgnx-statusbar--tick (1+ drgnx-statusbar--tick)))
        (should-not (text 'tests)))
      (with-temp-buffer
        (let ((global-mode-string nil) (mode-line-process nil) (defining-kbd-macro nil))
          (should-not (text 'misc)))))))

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

(ert-deftest drgnx-statusbar/the-bar-asks-for-a-redraw-when-point-moves-or-the-text-changes ()
  (let ((calls 0) (posted nil) (drgnx-statusbar--last (make-vector 4 nil)))
    (cl-letf (((symbol-function 'force-mode-line-update) (lambda (&optional all) (should-not all) (cl-incf calls)))
              ((symbol-function 'drgnx-signal-post) (lambda (e) (push e posted))))
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
        (setq posted nil)
        (let ((other (split-window-right)))            ; another window selected
          (unwind-protect
              (with-selected-window other
                (drgnx-statusbar--post-command)
                (should (= calls 4))
                ;; the bus is asked to say when the most recently used editor window is settled
                (should (equal posted '(statusbar-window-changed))))
            (delete-window other)))))
    ;; the hook and the bus subscriptions are there while the mode is on, and gone when it is off
    (cl-letf (((symbol-function 'drgnx-chrome-apply) #'ignore) ((symbol-function 'force-mode-line-update) #'ignore))
      (let ((drgnx-signal--subscribers nil))
        (unwind-protect
            (progn (drgnx-statusbar-mode 1)
                   (should (memq #'drgnx-statusbar--post-command post-command-hook))
                   (should (memq #'drgnx-statusbar--editor-changed (alist-get 'editor-changed drgnx-signal--subscribers)))
                   (should (memq #'drgnx-statusbar--editor-changed
                                 (alist-get 'statusbar-window-changed drgnx-signal--subscribers)))
                   (drgnx-statusbar-mode -1)
                   (should-not (memq #'drgnx-statusbar--post-command post-command-hook))
                   (should-not (alist-get 'editor-changed drgnx-signal--subscribers))
                   (should-not (alist-get 'statusbar-window-changed drgnx-signal--subscribers)))
          (drgnx-statusbar-mode -1))))
    ;; the bus edge redraws every bar
    (let (all)
      (cl-letf (((symbol-function 'force-mode-line-update) (lambda (&optional a) (setq all a))))
        (drgnx-statusbar--editor-changed (current-buffer))
        (should all)))))

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
            (should (equal (substring-no-properties (funcall text)) "⚠ 1 ⚠ 2"))
            ;; problems already known are shown even while another backend still runs
            (setq running '(b1 b2))
            (should (equal (substring-no-properties (funcall text)) "⚠ 1 ⚠ 2"))
            (setq-local flymake-mode nil)
            (should-not (funcall text))))))))

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
        ;; other entries of global-mode-string; the job badge is left out (the jobs segment shows it)
        (let ((global-mode-string (list "" "12:30" '(:eval (drgnx-job-ui--badge-segment)))))
          (should (equal (drgnx-statusbar--seg-misc) "12:30")))
        ;; a construct that is not plain strings is formatted by Emacs
        (cl-letf (((symbol-function 'format-mode-line) (lambda (c &rest _) (format "<%S>" c))))
          (let ((global-mode-string '(display-time-string)))
            (should (equal (drgnx-statusbar--seg-misc) "<(display-time-string)>"))))))))

(ert-deftest drgnx-statusbar/the-separator-is-ascii-on-a-terminal-that-is-not-utf-8 ()
  (drgnx-statusbar-test--with
    (should (string-match-p "\\` A · B " (substring-no-properties (drgnx-statusbar-render 60))))
    (cl-letf (((symbol-function 'drgnx-face--ascii-frame-p) (lambda (_frame) t)))
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
  "BODY with the drgnx side's state (ticks, tests, jobs, agents, the refresh timer, the memo) kept to this test."
  (declare (indent 0))
  `(let ((drgnx-statusbar--tick 0) (drgnx-statusbar-tests-state nil) (drgnx-statusbar--jobs-state nil)
         (drgnx-statusbar--agents-state nil) (drgnx-statusbar--refresh-timer nil)
         (drgnx-statusbar--redraw-wanted nil) (drgnx-statusbar--jobs-wanted nil) (drgnx-statusbar--jobs-pending nil)
         (drgnx-statusbar--state-texts (make-hash-table :test #'eq))
         (drgnx-statusbar--memo (make-hash-table :test #'eq :weakness 'key))
         (drgnx-statusbar-waiting-functions (list #'drgnx-statusbar-agents-waiting)))
     (unwind-protect (progn ,@body)
       (when (timerp drgnx-statusbar--refresh-timer) (cancel-timer drgnx-statusbar--refresh-timer)))))

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
              (let ((tick drgnx-statusbar--tick))
                (drgnx-statusbar--compilation-finished b "finished\n")
                (should (equal (drgnx-statusbar-test--seg 'tests) "✓ tests 41/41"))
                (should (equal (plist-get drgnx-statusbar-tests-state :passed) 41))
                (should (equal (plist-get drgnx-statusbar-tests-state :failed) 0))
                (should (eq (plist-get drgnx-statusbar-tests-state :source) b))
                (should (numberp (plist-get drgnx-statusbar-tests-state :at)))
                (should (> drgnx-statusbar--tick tick))) ; the bars' memo knows it changed
            (kill-buffer b)))
        ;; failures
        (let ((b (drgnx-statusbar-test--compilation
                  "make test" "Ran 43 tests, 41 results as expected, 2 unexpected (2026-10-18, 2.3 sec)")))
          (unwind-protect
              (progn (drgnx-statusbar--compilation-finished b "exited abnormally with code 1\n")
                     (should (equal (drgnx-statusbar-test--seg 'tests) "✕ tests 2 failed"))
                     (let ((s (funcall (plist-get (gethash 'tests drgnx-statusbar--segments) :fn))))
                       (should (eq (get-text-property 0 'face s) 'error))))
            (kill-buffer b)))
        ;; bin/drgnx test --ui's line
        (let ((b (drgnx-statusbar-test--compilation "bin/drgnx test --ui" "ui ERT: 25/27 passed")))
          (unwind-protect
              (progn (drgnx-statusbar--compilation-finished b "finished\n")
                     (should (equal (drgnx-statusbar-test--seg 'tests) "✕ tests 2 failed"))
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
      (let ((drgnx-job-ui--badge "") (asked 0)
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
          ;; cards waiting (the job badge's count) come after
          (setq drgnx-job-ui--badge " ⚑3")
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
          (setq drgnx-job-ui--badge "")
          (drgnx-statusbar--hub-gone)
          (should-not (drgnx-statusbar-test--seg 'jobs)))))))

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
          (should (timerp drgnx-statusbar--refresh-timer))
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
          (cl-letf (((symbol-function 'drgnx-face--ascii-frame-p) (lambda (_frame) t)))
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
            (drgnx-job-ui--badge " ⚑2") (mode-line-process nil) (defining-kbd-macro nil)
            (global-mode-string (list "" '(:eval (drgnx-job-ui--badge-segment)))))
        (cl-letf (((symbol-function 'drgnx-job-ui--badge-segment) (lambda () drgnx-job-ui--badge))
                  ;; a batch Emacs formats every mode-line construct as "": strings and :eval forms, as a frame would
                  ((symbol-function 'format-mode-line)
                   (lambda (c &rest _)
                     (mapconcat (lambda (e) (cond ((stringp e) e) ((eq (car-safe e) :eval) (eval (cadr e) t)) (t "")))
                                c ""))))
          (drgnx-statusbar-test--in-buffer #'emacs-lisp-mode
            (should-not (string-match-p "⚑" (drgnx-statusbar-mode-line)))   ; the jobs segment shows the badge
            ;; another module (the remote mark, the trust mark) pushes an entry: it appears, no coupling
            (push '(:eval (propertize "TRUST" 'face 'warning)) global-mode-string)
            (should (string-match-p "TRUST" (drgnx-statusbar-mode-line)))
            (should-not (string-match-p "⚑" (drgnx-statusbar-mode-line)))
            ;; …and goes when it is taken out
            (pop global-mode-string)
            (should-not (string-match-p "TRUST" (drgnx-statusbar-mode-line)))
            ;; a plain string is shown as it is
            (let ((global-mode-string " 12:30")) (should (string-match-p "12:30" (drgnx-statusbar-mode-line))))))))))

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
            (cl-letf (((symbol-function 'force-mode-line-update)
                       (lambda (&optional all) (when drgnx-statusbar-test--refreshing (should all) (cl-incf calls)))))
              ;; 20 agent changes in 0.1 s: one refresh, one redraw of every bar
              (dotimes (_ 20)
                (drgnx-statusbar--agents-changed (car drgnx-agents--sessions))
                (sleep-for 0.005))
              (should (= calls 0))
              (should (= drgnx-statusbar-test--refreshes 0))
              (sleep-for 0.4)
              (should (= drgnx-statusbar-test--refreshes 1))
              (should (= calls 1))
              (should (equal (drgnx-statusbar-test--seg 'agents) "◎ 1 busy"))
              ;; the hub's and git's change hooks go through the same debounce
              (drgnx-statusbar--hub-event "agent-entries" nil)
              (drgnx-statusbar--git-changed "/repo/")
              (drgnx-statusbar--git-changed "/repo/")
              (sleep-for 0.4)
              (should (= drgnx-statusbar-test--refreshes 2))
              (should (= calls 2))                             ; git: one redraw, the agents' counts did not change
              (should-not drgnx-statusbar--refresh-timer))
          (advice-remove 'drgnx-statusbar--refresh-now #'drgnx-statusbar-test--mark-refresh))))))

(ert-deftest drgnx-statusbar/a-redisplay-that-changes-nothing-reuses-the-bar ()
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
                (drgnx-statusbar--git-changed "/repo/")
                (drgnx-statusbar--refresh-now)
                (should (rebuilt-p)) (should-not (rebuilt-p))
                ;; the indentation width, flymake's backends and eglot's server state are in the key
                (let ((drgnx-statusbar-indent-vars '(drgnx-statusbar-test--offset)))
                  (setq-local indent-tabs-mode nil)
                  (setq-local drgnx-statusbar-test--offset 2)
                  (should (rebuilt-p)) (should-not (rebuilt-p))
                  (setq-local drgnx-statusbar-test--offset 4)
                  (should (rebuilt-p)) (should-not (rebuilt-p)))
                (let ((running '(b1)) (reporting nil) (alive t))
                  (cl-letf (((symbol-function 'flymake-running-backends) (lambda () running))
                            ((symbol-function 'flymake-reporting-backends) (lambda () reporting))
                            ((symbol-function 'jsonrpc-running-p) (lambda (_s) alive)))
                    (setq-local flymake-mode t)
                    (should (rebuilt-p)) (should-not (rebuilt-p))
                    (setq reporting '(b1))                     ; the backend reported
                    (should (rebuilt-p)) (should-not (rebuilt-p))
                    (setq-local eglot--cached-server 'server)
                    (should (rebuilt-p)) (should-not (rebuilt-p))
                    (setq alive nil)                           ; the server exited
                    (should (rebuilt-p)) (should-not (rebuilt-p))
                    (setq-local flymake-mode nil)
                    (setq-local eglot--cached-server nil)))
                ;; the compact bar in another window is its own entry
                (let ((other (split-window-right)))
                  (unwind-protect
                      (progn (set-window-buffer other (current-buffer))
                             (with-selected-window other (should (rebuilt-p)) (should-not (rebuilt-p))))
                    (delete-window other)))))))))))

(ert-deftest drgnx-statusbar/hooks-and-timers-are-owned-by-the-mode ()
  (let ((drgnx-chrome-editor-mode-line drgnx-chrome-editor-mode-line)
        (drgnx-signal--subscribers nil)
        (was drgnx-statusbar-mode)                       ; the process's other tests keep what they had
        (hooks '((post-command-hook . drgnx-statusbar--post-command)
                 (drgnx-agents-changed-functions . drgnx-statusbar--agents-changed)
                 (drgnx-hub-event-functions . drgnx-statusbar--hub-event)
                 (drgnx-hub-disconnect-functions . drgnx-statusbar--hub-gone)
                 (drgnx-git-changed-functions . drgnx-statusbar--git-changed)
                 (compilation-finish-functions . drgnx-statusbar--compilation-finished))))
    (drgnx-statusbar-test--state
      (cl-letf (((symbol-function 'drgnx-chrome-apply) #'ignore) ((symbol-function 'force-mode-line-update) #'ignore))
        (unwind-protect
            (progn
              (drgnx-statusbar-mode 1)
              (drgnx-statusbar-mode 1)                       ; idempotent
              (dolist (h hooks)
                (should (= 1 (seq-count (lambda (f) (eq f (cdr h))) (default-value (car h))))))
              (drgnx-statusbar-refresh)
              (should (timerp drgnx-statusbar--refresh-timer))
              (puthash (selected-window) [x] drgnx-statusbar--memo)
              (let ((timer drgnx-statusbar--refresh-timer))
                (drgnx-statusbar-mode -1)
                (should-not (memq timer timer-list)))
              (dolist (h hooks) (should-not (memq (cdr h) (default-value (car h)))))
              (should-not drgnx-statusbar--refresh-timer)
              (should (= 0 (hash-table-count drgnx-statusbar--memo))))
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

(provide 'mod-statusbar-test)
;;; mod-statusbar-test.el ends here
