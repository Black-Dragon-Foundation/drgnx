;;; debug-console-test.el --- batch tests: the debug console inserts the hub's lines and evaluates -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; The hub's `debug-output' events are fed to the module's handler as the hub client parses them (arrays as lists); what the console asks of the
;; hub is recorded and answered here.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug" drgnx-dir) nil t)

(defmacro debug-console-test--with (&rest body)
  "BODY with one stopped session `s1' (\"Python: app\") in /p and a fresh console; CALLS holds what was asked of the hub
\(newest first) as (METHOD PARAMS CALLBACK)."
  (declare (indent 0))
  `(let ((drgnx-debug--sessions nil) (drgnx-debug--focus nil) (drgnx-debug-console--names nil) (calls nil))
     (when (get-buffer drgnx-debug-console-buffer-name) (kill-buffer drgnx-debug-console-buffer-name))
     (cl-letf (((symbol-function 'drgnx-debug-launch-root) (lambda () "/p"))
               ((symbol-function 'drgnx-debug-toolbar-sync) #'ignore)
               ((symbol-function 'drgnx-hub-call) (lambda (method params cb &rest _) (push (list method params cb) calls))))
       (unwind-protect
           (progn (drgnx-debug--event "debug-state" (list :sessions (vector (list :id "s1" :name "Python: app" :root "/p"
                                                                                  :state "stopped"
                                                                                  :caps (list :supportsCompletionsRequest t)))))
                  ,@body)
         (drgnx-debug-session-mode -1)
         (when (get-buffer drgnx-debug-console-buffer-name)
           (let ((kill-buffer-query-functions nil)) (kill-buffer drgnx-debug-console-buffer-name)))))))

(defun debug-console-test--output (&rest lines)
  (drgnx-debug--event "debug-output" (list :session "s1" :lines lines)))

(defun debug-console-test--text ()
  "The console's output, without its input line."
  (with-current-buffer drgnx-debug-console-buffer-name
    (buffer-substring-no-properties (point-min) drgnx-debug-console--end)))

(ert-deftest drgnx-debug-console/inserts-the-hubs-lines ()
  "Lines are inserted as they come: the hub's face runs, the category's face, the group's indent, the count, a
logpoint's source, a structured value's chevron; a line that continues the last one adds to its count."
  (debug-console-test--with
    (debug-console-test--output (list :text "plain" :category "stdout" :count 1)
                                (list :text "red bold" :category "stdout" :count 1
                                      :runs '((0 3 "drgnx-debug-console-red")))
                                (list :text "oops" :category "stderr" :count 3)
                                (list :text "inside" :category "stdout" :count 1 :depth 1)
                                (list :text "hit 3" :category "console" :count 1 :source (list :path "/p/a.py" :line 12))
                                (list :text "obj" :category "stdout" :count 1 :node (list :reference 9)))
    (should (equal (debug-console-test--text) "plain\nred bold\noops ×3\n  inside\nhit 3  a.py:12\n▸ obj\n"))
    (with-current-buffer drgnx-debug-console-buffer-name
      (goto-char (point-min))
      (search-forward "red")
      (should (memq 'drgnx-debug-console-red (ensure-list (get-text-property (1- (point)) 'face))))
      (search-forward "oops")
      (should (memq 'drgnx-debug-console-stderr (ensure-list (get-text-property (1- (point)) 'face))))
      (search-forward "▸ obj")
      (should (equal "s1" (plist-get (get-text-property (1- (point)) 'drgnx-debug-console-node) :session))))
    (debug-console-test--output (list :text "obj" :category "stdout" :count 1 :node (list :reference 9))
                                (list :text "tick" :category "stdout" :count 1))
    (debug-console-test--output (list :text "tick" :category "stdout" :count 2 :more t))
    (should (string-suffix-p "▸ obj\ntick ×3\n" (debug-console-test--text)))))

(ert-deftest drgnx-debug-console/keeps-the-last-lines ()
  "Past `drgnx-debug-console-max-lines' the oldest lines go; skipped lines are said."
  (debug-console-test--with
    (let ((drgnx-debug-console-max-lines 100))
      (dotimes (b 3)
        (apply #'debug-console-test--output
               (mapcar (lambda (i) (list :text (format "line %d" (+ (* b 50) i)) :category "stdout" :count 1))
                       (number-sequence 0 49))))
      (drgnx-debug--event "debug-output" (list :session "s1" :skipped 7 :lines nil))
      (let ((text (debug-console-test--text)))
        (should (= 100 (with-current-buffer drgnx-debug-console-buffer-name drgnx-debug-console--lines)))
        (should (= 100 (cl-count ?\n text)))
        (should (string-prefix-p "line 51\n" text))
        (should (string-suffix-p "line 149\n7 lines skipped\n" text))))))

(ert-deftest drgnx-debug-console/evaluates-and-opens-in-place ()
  "RET evaluates the input in the session's selected frame (`repl'); S-RET adds a line; the result's chevron opens
its children below it (`debug/children' of its stop) and closes them; a value of a stop that is over turns stale."
  (debug-console-test--with
    (with-current-buffer (drgnx-debug-console--buffer)
      (goto-char (point-max))
      (insert "len(")
      (drgnx-debug-console-newline)
      (insert "xs)")
      (drgnx-debug-console-send)
      (pcase-let ((`(,method ,params ,cb) (car calls)))
        (should (equal method "debug/evaluate"))
        (should (equal params (list :session "s1" :expr "len(\nxs)" :context "repl")))
        (funcall cb (list :result "[1, 2]" :reference 5 :epoch 4) nil))
      (should (equal (debug-console-test--text) "len(\nxs)\n▸ [1, 2]\n"))
      (should (equal "" (drgnx-debug-console--input)))
      (goto-char (point-min))
      (search-forward "[1, 2")
      (drgnx-debug-console-toggle)
      (pcase-let ((`(,method ,params ,cb) (car calls)))
        (should (equal method "debug/children"))
        (should (equal params (list :session "s1" :reference 5 :epoch 4)))
        (funcall cb (list :variables (vector (list :name "0" :value "1") (list :name "1" :value "2" :reference 6))) nil))
      (should (equal (debug-console-test--text) "len(\nxs)\n▾ [1, 2]\n  0: 1\n  ▸ 1: 2\n"))
      (goto-char (point-min))
      (search-forward "[1, 2")
      (drgnx-debug-console-toggle)
      (should (equal (debug-console-test--text) "len(\nxs)\n▸ [1, 2]\n"))
      (drgnx-debug-console-toggle)
      (funcall (nth 2 (car calls)) nil "stop 4 is over; its variables are gone")
      (should-not (get-text-property (point) 'drgnx-debug-console-node))
      (should (memq 'drgnx-debug-console-stale (ensure-list (get-text-property (point) 'face)))))))

(defun debug-console-test--shown ()
  "The output as it shows: the text no fold hides."
  (with-current-buffer drgnx-debug-console-buffer-name
    (let ((s "") (p (point-min)) (end (marker-position drgnx-debug-console--end)))
      (while (< p end)
        (let ((next (min end (next-single-char-property-change p 'invisible))))
          (unless (invisible-p p) (setq s (concat s (buffer-substring-no-properties p next))))
          (setq p next)))
      s)))

(ert-deftest drgnx-debug-console/groups-fold ()
  "A group's first line (`:group') has a chevron and folds what it holds (the lines whose `:within' names it), a
collapsed one (`:collapsed') starts folded; TAB or RET on it opens or closes it; an inner fold stays as it was."
  (debug-console-test--with
    (debug-console-test--output (list :text "Group A" :category "stdout" :count 1 :group 1)
                                (list :text "child" :category "stdout" :count 1 :depth 1 :within '(1))
                                (list :text "inner" :category "stdout" :count 1 :depth 1 :within '(1) :group 2
                                      :collapsed t)
                                (list :text "deep" :category "stdout" :count 1 :depth 2 :within '(1 2))
                                (list :text "out" :category "stdout" :count 1))
    (should (equal (debug-console-test--text) "▾ Group A\n  child\n  ▸ inner\n    deep\nout\n"))
    (should (equal (debug-console-test--shown) "▾ Group A\n  child\n  ▸ inner\nout\n"))
    (with-current-buffer drgnx-debug-console-buffer-name
      (goto-char (point-min))
      (search-forward "Group")
      (drgnx-debug-console-toggle)
      (should (equal (debug-console-test--shown) "▸ Group A\nout\n"))
      (drgnx-debug-console-toggle)
      (should (equal (debug-console-test--shown) "▾ Group A\n  child\n  ▸ inner\nout\n"))
      (search-forward "inner")
      (drgnx-debug-console-toggle)
      (should (equal (debug-console-test--shown) "▾ Group A\n  child\n  ▾ inner\n    deep\nout\n")))))

(defun debug-console-test--prefixes ()
  "Each output line's `line-prefix' (the timestamp), or nil."
  (with-current-buffer drgnx-debug-console-buffer-name
    (let (out)
      (save-excursion
        (goto-char (point-min))
        (while (< (point) drgnx-debug-console--end)
          (push (let ((p (get-text-property (point) 'line-prefix))) (and p (substring-no-properties p))) out)
          (forward-line 1)))
      (nreverse out))))

(ert-deftest drgnx-debug-console/timestamps ()
  "With `drgnx-debug-console-timestamps', each line shows the hub's time (`:time', ms) in a 12-character column
before it, a line without one an empty column; the text itself stays the output.  Turning it off or on re-shows the
lines already there."
  (debug-console-test--with
    (let ((drgnx-debug-console-timestamps nil)
          (t0 (+ (* 1000 (float-time (encode-time (list 11 2 14 13 11 2026 nil -1 nil)))) 204)))
      (debug-console-test--output (list :text "first" :category "stdout" :count 1 :time t0)
                                  (list :text "later" :category "stdout" :count 1 :time (+ t0 1176)))
      (should (equal (debug-console-test--prefixes) '(nil nil)))
      (customize-set-variable 'drgnx-debug-console-timestamps t)
      (should (equal (debug-console-test--prefixes) '("14:02:11.204 " "14:02:12.380 ")))
      (drgnx-debug-console--insert (list (list :text "no time" :category "console" :count 1)))
      (should (equal (car (last (debug-console-test--prefixes))) "             "))
      (should (equal (debug-console-test--text) "first\nlater\nno time\n"))
      ;; a quiet column: the subtle text, as the mockup's
      (should (eq (face-attribute 'drgnx-debug-console-time :inherit) 'drgnx-text-disabled))   ; the mockup's --disabled
      (customize-set-variable 'drgnx-debug-console-timestamps nil)
      (should (equal (debug-console-test--prefixes) '(nil nil nil))))))

(ert-deftest drgnx-debug-console/evaluates-from-the-editor ()
  "`drgnx-debug-console-evaluate': EXPR evaluated as if typed (echoed, in the history, `repl'), what the input held
kept; the tab shown without the focus, or selected with SELECT."
  (debug-console-test--with
    (let ((shown nil) (here (selected-window)))
      (cl-letf (((symbol-function 'drgnx-wb-area-show)
                 (lambda (area tab buffer) (push (list area tab (buffer-name buffer)) shown) here)))
        (with-current-buffer (drgnx-debug-console--buffer)
          (goto-char (point-max))
          (insert "half typed"))
        (with-temp-buffer
          (let ((b (current-buffer)))
            (drgnx-debug-console-evaluate "items[0]")
            (should (eq (current-buffer) b))
            (should (eq (selected-window) here)))
          (should (equal shown (list (list 'panel 'debug-console drgnx-debug-console-buffer-name))))
          (pcase-let ((`(,method ,params ,cb) (car calls)))
            (should (equal method "debug/evaluate"))
            (should (equal params (list :session "s1" :expr "items[0]" :context "repl")))
            (funcall cb (list :result "3") nil)))
        (should (equal (debug-console-test--text) "items[0]\n3\n"))
        (with-current-buffer drgnx-debug-console-buffer-name
          (should (equal "half typed" (drgnx-debug-console--input)))
          (should (equal '("items[0]") drgnx-debug-console--history)))
        (let ((selected nil))
          (cl-letf (((symbol-function 'select-window) (lambda (w &rest _) (setq selected w))))
            (drgnx-debug-console-evaluate "n" t))
          (should (eq selected here)))))))

(ert-deftest drgnx-debug-console/completes-from-the-adapter ()
  "TAB-less completion at point in the input: the adapter's targets for the input and point (`debug/completions'),
the span a target names replaced, else the word before point; their types as annotations; none outside the input,
nor when the adapter has not said it completes (`debug-state' caps)."
  (debug-console-test--with
    (let ((asked nil)
          (answer (list :targets (vector (list :label "items" :type "variable") (list :label "iter" :type "function")))))
      (cl-letf (((symbol-function 'drgnx-hub-call-sync)
                 (lambda (method params &optional _timeout) (push (list method params) asked) answer)))
        (with-current-buffer (drgnx-debug-console--buffer)
          (goto-char (point-max))
          (insert "len(it")
          (pcase-let ((`(,beg ,end ,table . ,props) (run-hook-with-args-until-success 'completion-at-point-functions)))
            (should (equal (car asked) (list "debug/completions" (list :session "s1" :text "len(it" :column 6))))
            (should (equal (buffer-substring-no-properties beg end) "it"))
            (should (equal (all-completions "it" table) '("items" "iter")))
            (should (equal (funcall (plist-get props :annotation-function) "iter") " function")))
          ;; a target that names its span: it replaces from there
          (setq answer (list :targets (vector (list :label "len(items)" :start 0 :length 6))))
          (pcase-let ((`(,beg ,end . ,_) (run-hook-with-args-until-success 'completion-at-point-functions)))
            (should (equal (buffer-substring-no-properties beg end) "len(it")))
          (goto-char (point-min))
          (should-not (run-hook-with-args-until-success 'completion-at-point-functions))
          ;; an adapter without completions (or not said yet) is not asked
          (goto-char (point-max))
          (setq asked nil)
          (let ((drgnx-debug--sessions (list (list :id "s1" :name "Python: app" :root "/p" :state "stopped"))))
            (should-not (run-hook-with-args-until-success 'completion-at-point-functions)))
          (should-not asked))))))

(ert-deftest drgnx-debug-console/history-per-profile ()
  "The input's history: back and forth through what was evaluated; the keys in the three profiles."
  (debug-console-test--with
    (with-current-buffer (drgnx-debug-console--buffer)
      (dolist (e '("a" "b"))
        (goto-char (point-max)) (insert e) (drgnx-debug-console-send))
      (drgnx-debug-console-history-previous)
      (should (equal "b" (drgnx-debug-console--input)))
      (drgnx-debug-console-history-previous)
      (should (equal "a" (drgnx-debug-console--input)))
      (drgnx-debug-console-history-next)
      (drgnx-debug-console-history-next)
      (should (equal "" (drgnx-debug-console--input)))))
  (dolist (f '("keys/vscode.eld" "keys/emacs.eld" "keys/vim.eld"))
    (let ((text (with-temp-buffer (insert-file-contents (expand-file-name f drgnx-dir)) (buffer-string))))
      (should (string-match-p "(debug-console-history-previous \"" text))
      (should (string-match-p "(debug-console-history-next \"" text)))))

(ert-deftest drgnx-debug-console/kept-after-the-end-and-cleared-at-the-next-start ()
  "The output stays when the session ends; the next start of the same configuration clears it (the setting)."
  (debug-console-test--with
    (debug-console-test--output (list :text "first run" :category "stdout" :count 1))
    (drgnx-debug--event "debug-state" (list :sessions []))
    (should (equal (debug-console-test--text) "first run\n"))
    (drgnx-debug--event "debug-state" (list :sessions (vector (list :id "s2" :name "Other" :root "/p" :state "running"))))
    (should (equal (debug-console-test--text) "first run\n"))
    (drgnx-debug--event "debug-state" (list :sessions []))
    (drgnx-debug--event "debug-state" (list :sessions (vector (list :id "s3" :name "Python: app" :root "/p"
                                                                    :state "running"))))
    (should (equal (debug-console-test--text) ""))
    (let ((drgnx-debug-console-clear-on-restart nil))
      (debug-console-test--output (list :text "second run" :category "stdout" :count 1))
      (drgnx-debug--event "debug-state" (list :sessions []))
      (drgnx-debug--event "debug-state" (list :sessions (vector (list :id "s4" :name "Python: app" :root "/p"
                                                                      :state "running"))))
      (should (equal (debug-console-test--text) "second run\n")))))
