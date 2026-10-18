;;; mod-statusbar-test.el --- batch tests: the status bar — segments as data (M12f A3) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-chrome)
(load (expand-file-name "modules/ui/drgnx-face" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-statusbar" drgnx-dir) nil t)

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
    (should (string-match-p "boom" (cdr (car drgnx-statusbar--errors))))))

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
      ;; tests has nothing cached yet; misc has nothing to say in a plain buffer
      (should-not (text 'tests))
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
        (let ((other (split-window-right)))            ; another window selected
          (unwind-protect
              (with-selected-window other
                (drgnx-statusbar--post-command)
                (should (= calls 4)))
            (delete-window other)))))
    ;; the hook is there while the mode is on, and gone when it is off
    (cl-letf (((symbol-function 'drgnx-chrome-apply) #'ignore) ((symbol-function 'force-mode-line-update) #'ignore))
      (unwind-protect
          (progn (drgnx-statusbar-mode 1)
                 (should (memq #'drgnx-statusbar--post-command post-command-hook))
                 (drgnx-statusbar-mode -1)
                 (should-not (memq #'drgnx-statusbar--post-command post-command-hook)))
        (drgnx-statusbar-mode -1)))))

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

(ert-deftest drgnx-statusbar/a-failed-segment-stays-skipped-until-it-is-defined-again ()
  (drgnx-statusbar-test--with
    (let ((calls 0))
      (drgnx-statusbar-define-segment 'b :fn (lambda () (cl-incf calls) (error "boom")))
      (dotimes (_ 50) (drgnx-statusbar-render 60))
      (should (= calls 1))
      (drgnx-statusbar-define-segment 'b :fn (lambda () (cl-incf calls) "B"))
      (should (string-match-p "A · B" (substring-no-properties (drgnx-statusbar-render 60))))
      (should (= calls 2))
      (should-not drgnx-statusbar--errors))))

(ert-deftest drgnx-statusbar/a-failing-bar-is-recorded-once-and-shows-nothing ()
  (drgnx-statusbar-test--with
    (let ((drgnx-statusbar-left 'not-a-list))         ; a bad setting
      (drgnx-statusbar-test--in-buffer #'emacs-lisp-mode
        (dotimes (_ 100) (should-not (drgnx-statusbar-mode-line)))
        (should (= (length drgnx-statusbar--errors) 1))
        (should (eq (car (car drgnx-statusbar--errors)) 'host))))))

(ert-deftest drgnx-statusbar/agent-changes-redraw-only-when-the-counts-change ()
  (require 'drgnx-agents)
  (drgnx-statusbar-test--with
    (drgnx-statusbar--define-defaults)
    (let ((calls 0) (drgnx-statusbar--agents-seen nil)
          (drgnx-agents--sessions (list (drgnx-agents--make :name "a" :status 'busy)
                                        (drgnx-agents--make :name "b" :status 'idle))))
      (cl-letf (((symbol-function 'force-mode-line-update) (lambda (&optional all) (should all) (cl-incf calls))))
        (drgnx-statusbar--agents-changed (car drgnx-agents--sessions))
        (should (= calls 1))
        (drgnx-statusbar--agents-changed (car drgnx-agents--sessions))   ; the same counts: nothing to redraw
        (should (= calls 1))
        (should (equal (substring-no-properties (drgnx-statusbar--seg-agents)) "◎ 1 busy"))
        (setf (drgnx-agent-session-permissions (cadr drgnx-agents--sessions)) '(ask))
        (drgnx-statusbar--agents-changed (cadr drgnx-agents--sessions))
        (should (= calls 2))
        (should (equal (substring-no-properties (drgnx-statusbar--seg-agents)) "◎ 1 busy ◐ 1 waiting on you"))))))

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
