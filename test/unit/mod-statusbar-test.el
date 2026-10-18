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
     (drgnx-statusbar-define-segment 'a :fn (lambda () "A"))
     (drgnx-statusbar-define-segment 'b :fn (lambda () "B"))
     (drgnx-statusbar-define-segment 'c :fn (lambda () "C"))
     ,@body))

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
        (dolist (width '(200 60 30 12))
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
    (let ((w1 (selected-window)) w2)
      (unwind-protect
          (progn
            (delete-other-windows)
            (setq w1 (selected-window) w2 (split-window-right))
            (let ((drgnx-signal--editor-window w2))
              (let ((full (with-selected-window w2 (drgnx-statusbar-mode-line)))
                    (other (with-selected-window w1 (drgnx-statusbar-mode-line))))
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
      ;; tests and misc have nothing cached yet: they render nothing
      (should-not (text 'tests))
      (should-not (text 'misc)))))

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
