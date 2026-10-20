;;; mod-tty-popups-test.el --- batch tests: ui/terminal-popups — borders, ASCII terminals -*- lexical-binding: t -*-
;; Batch Emacs has no terminal: the terminal's coding system and the frame kind are stubbed; the tty tier
;; (test/tty/popups-test.el) runs the real thing.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-tty-popups" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defmacro drgnx-tty-popups-test--terminal (coding &rest body)
  "BODY with the selected frame a terminal frame whose terminal writes CODING."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil))
             ((symbol-function 'frame-terminal) (lambda (&optional _) 'kx-a))
             ((symbol-function 'terminal-coding-system) (lambda (&optional _) ,coding)))
     ,@body))

(defun drgnx-tty-popups-test--glyphs (table)
  "The characters in TABLE's six single-line border slots (vertical, horizontal, down-right, down-left,
up-right, up-left)."
  (mapcar (lambda (slot) (glyph-char (display-table-slot table slot))) drgnx-tty-popups-box-slots))

(ert-deftest drgnx-tty-popups/borders-follow-the-coding-system ()
  ;; a UTF-8 terminal draws a child frame's border with box-drawing characters, any other with ASCII
  (drgnx-tty-popups-test--terminal 'utf-8-unix
    (should-not (drgnx-tty-popups-ascii-p)))
  (drgnx-tty-popups-test--terminal 'utf-8
    (should-not (drgnx-tty-popups-ascii-p)))
  (dolist (coding '(us-ascii iso-latin-1-unix iso-8859-15 undecided-unix))
    (drgnx-tty-popups-test--terminal coding
      (should (drgnx-tty-popups-ascii-p))))
  ;; a graphical frame has no terminal coding to ask
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t)))
    (should-not (drgnx-tty-popups-ascii-p)))
  ;; the slots of the standard display table
  (progn
    (let ((standard-display-table nil))
      (drgnx-tty-popups--borders nil)
      (should (equal (drgnx-tty-popups-test--glyphs standard-display-table) '(?│ ?─ ?┌ ?┐ ?└ ?┘)))
      (drgnx-tty-popups--borders t)
      (should (equal (drgnx-tty-popups-test--glyphs standard-display-table) '(?| ?- ?+ ?+ ?+ ?+))))
    ;; one terminal that cannot show box drawing makes the (shared) table ASCII for all of them
    (let ((standard-display-table nil)
          (frames '(a b)))
      (cl-letf (((symbol-function 'frame-live-p) (lambda (_) t))
                ((symbol-function 'display-graphic-p) (lambda (&optional _) nil))
                ((symbol-function 'frame-terminal) (lambda (&optional f) f))
                ((symbol-function 'terminal-coding-system)
                 (lambda (&optional term) (if (eq term 'b) 'us-ascii 'utf-8-unix)))
                ((symbol-function 'drgnx-tty-popups--tty-frames) (lambda () frames)))
        (drgnx-tty-popups--update-borders)
        (should (equal (drgnx-tty-popups-test--glyphs standard-display-table) '(?| ?- ?+ ?+ ?+ ?+)))
        (setq frames '(a))
        (drgnx-tty-popups--update-borders)
        (should (equal (drgnx-tty-popups-test--glyphs standard-display-table) '(?│ ?─ ?┌ ?┐ ?└ ?┘)))))))

(ert-deftest drgnx-tty-popups/an-ascii-terminal-gets-ascii-marks-for-the-chrome-glyphs ()
  ;; the tab line's × and ●, the breadcrumb's ›, the Explorer's chevrons and guides, the dash and the ellipsis
  (let ((table (drgnx-tty-popups--ascii-table)))
    (dolist (pair '((?× . "x") (?● . "*") (?› . ">") (?▾ . "v") (?▸ . ">") (?│ . "|") (?— . "-") (?… . "...")))
      (should (equal (concat (mapcar (lambda (g) (if (consp g) (car g) g)) (aref table (car pair))))
                     (cdr pair)))))
  ;; plain ASCII is never touched
  (should-not (aref (drgnx-tty-popups--ascii-table) ?a)))

(ert-deftest drgnx-tty-popups/ascii-marks-keep-the-text-properties ()
  ;; the tab line and the headers are strings with faces and keymaps: only the glyph changes
  (let* ((s (concat (propertize " a.txt ●" 'face 'bold) (propertize " ×" 'local-map 'm 'face 'italic)))
         (out (drgnx-tty-popups--ascii-string s)))
    (should (equal out " a.txt * x"))
    (should (eq (get-text-property 7 'face out) 'bold))
    (should (eq (get-text-property 9 'local-map out) 'm))
    (should (eq (get-text-property 9 'face out) 'italic)))
  (let ((plain " a.txt x")) (should (eq plain (drgnx-tty-popups--ascii-string plain))))
  ;; a glyph with no mark of its own is left (Emacs shows it as it can)
  (should (equal (drgnx-tty-popups--ascii-string "é ×") "é x")))

(ert-deftest drgnx-tty-popups/the-chrome-strings-of-a-window-are-written-in-ascii ()
  ;; the tab line, the header line and the mode line; a list format (an :eval form) is not a string and stays
  (let ((params (list (cons 'tab-line-format " a.txt ● × ") (cons 'header-line-format " home › user")
                      (cons 'mode-line-format '(:eval (foo))) (cons 'other "keep ×")))
        (set nil))
    (cl-letf (((symbol-function 'window-parameter) (lambda (_w p) (cdr (assq p params))))
              ((symbol-function 'set-window-parameter) (lambda (_w p v) (push (cons p v) set))))
      (drgnx-tty-popups--ascii-chrome-window 'w)
      (should (equal (sort set (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b)))))
                     '((header-line-format . " home > user") (tab-line-format . " a.txt * x ")))))))

(ert-deftest drgnx-tty-popups/the-ascii-table-follows-the-terminal-not-the-session ()
  ;; a window of an ASCII terminal gets the table; a window of a UTF-8 terminal (or a graphical one) keeps none
  (let (set)
    (cl-letf (((symbol-function 'window-list) (lambda (&optional _f _m) '(w1 w2)))
              ((symbol-function 'window-display-table) (lambda (w) (and (eq w 'w2) 'theirs)))
              ((symbol-function 'set-window-display-table) (lambda (w tbl) (push (cons w tbl) set))))
      (drgnx-tty-popups--ascii-windows 'f)
      ;; w1 had none: ours; w2 has a table of its own: left alone
      (should (equal set (list (cons 'w1 (drgnx-tty-popups--ascii-table))))))))

(defmacro drgnx-tty-popups-test--hooks (&rest body)
  "BODY with the hooks the module adds and removes bound to nil, and the chrome advice taken off afterwards."
  `(let ((pre-redisplay-functions nil) (window-configuration-change-hook nil)
         (drgnx-modules--runs (list (list 'ui/terminal-popups 'ui/terminal-popups))))   ; the module is on
     (unwind-protect (progn ,@body)
       (advice-remove 'drgnx-chrome--set #'drgnx-tty-popups--chrome-set))))

(defun drgnx-tty-popups-test--sync (frames ascii)
  "The hooks (pre-redisplay wcch chrome-advice) present after a sync with FRAMES terminal frames, ASCII
of them non-UTF-8."
  (cl-letf (((symbol-function 'drgnx-tty-popups--tty-frames) (lambda () frames))
            ((symbol-function 'drgnx-tty-popups--ascii-frame-p) (lambda (f) (memq f ascii))))
    (drgnx-tty-popups--sync)
    (list (and (memq 'drgnx-tty-popups--pre-redisplay pre-redisplay-functions) t)
          (and (memq 'drgnx-tty-popups--windows-changed window-configuration-change-hook) t)
          (and (advice-member-p #'drgnx-tty-popups--chrome-set 'drgnx-chrome--set) t))))

(ert-deftest drgnx-tty-popups/a-session-without-ascii-terminals-pays-nothing ()
  ;; the hooks that cost something on every redisplay or command are there only while a terminal needs them
  (drgnx-tty-popups-test--hooks
   ;; graphical only, no terminal frame, or UTF-8 terminals: nothing
   (should (equal (drgnx-tty-popups-test--sync nil nil) '(nil nil nil)))
   (should (equal (drgnx-tty-popups-test--sync '(a) nil) '(nil nil nil)))
   ;; a non-UTF-8 terminal: the ASCII hooks, and they go with it
   (should (equal (drgnx-tty-popups-test--sync '(a b) '(b)) '(t t t)))
   (should (equal (drgnx-tty-popups-test--sync '(a) nil) '(nil nil nil)))))

(ert-deftest drgnx-tty-popups/chrome-values-in-lists-are-written-in-ascii ()
  ;; sticky scroll's header is a list (breadcrumb and a tail); strings in it are rewritten, :eval forms are not
  (let* ((crumb (propertize "a › b" 'face 'bold))
         (value (list crumb '(:propertize "×" face italic) '(:eval (concat "›" "x")) 'sym "plain")))
    (let ((out (drgnx-tty-popups--ascii-value value)))
      (should (equal (car out) "a > b"))
      (should (eq (get-text-property 0 'face (car out)) 'bold))
      (should (equal (nth 1 out) '(:propertize "x" face italic)))
      (should (equal (nth 2 out) '(:eval (concat "›" "x"))))   ; computed at draw time: left as it is
      (should (eq (nth 3 out) 'sym))))
  ;; nothing to rewrite: the very same object, so a comparison with it still holds
  (let ((same (list "ascii" '(:eval foo) 'x)))
    (should (eq (drgnx-tty-popups--ascii-value same) same)))
  (should (eq (drgnx-tty-popups--ascii-value 'none) 'none)))

(ert-deftest drgnx-tty-popups/chrome-sets-the-rewritten-value-so-a-redundant-set-is-skipped ()
  ;; drgnx-chrome--set compares the window's parameter with what it wants; on an ASCII frame the parameter holds the
  ;; rewritten string, so it is given the rewritten one too
  (drgnx-tty-popups-test--hooks
   (let (got)
     (cl-letf (((symbol-function 'window-frame) (lambda (w) (if (eq w 'ascii-win) 'af 'uf)))
               ((symbol-function 'drgnx-tty-popups--ascii-frame-p) (lambda (f) (eq f 'af))))
       (let ((orig (lambda (w param value) (push (list w param value) got))))
         (drgnx-tty-popups--chrome-set orig 'ascii-win 'tab-line-format " a ● × ")
         (drgnx-tty-popups--chrome-set orig 'utf-win 'tab-line-format " a ● × ")
         (should (equal (nreverse got) '((ascii-win tab-line-format " a * x ") (utf-win tab-line-format " a ● × ")))))))))

(ert-deftest drgnx-tty-popups/setup-is-for-terminal-frames-only ()
  (let (called)
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'frame-live-p) (lambda (_) t))
              ((symbol-function 'drgnx-tty-popups--update-borders) (lambda () (setq called t))))
      (drgnx-tty-popups-setup 'gui)
      (should-not called))))

(ert-deftest drgnx-tty-popups/turning-it-off-takes-what-the-terminals-got ()
  ;; a terminal frame's setup runs from ui/terminal's hooks, after this module's setup: nothing recorded the hooks
  ;; it keeps, the ASCII table of its windows or the box slots; the module's teardown takes them (a window's own
  ;; display table stays)
  (let ((frame (selected-frame)) (window (selected-window))
        (standard-display-table (and standard-display-table (copy-sequence standard-display-table))))
    (unwind-protect
        (progn
          (drgnx-test-with-modules '(ui/terminal-popups) :strict t
                                   (set-frame-parameter frame 'drgnx-tty-ascii t)
                                   (set-window-display-table window (drgnx-tty-popups--ascii-table))
                                   (drgnx-tty-popups--hook t 'pre-redisplay-functions #'drgnx-tty-popups--pre-redisplay)
                                   (advice-add 'drgnx-chrome--set :around #'drgnx-tty-popups--chrome-set)
                                   (drgnx-tty-popups--borders t))
          (should-not (frame-parameter frame 'drgnx-tty-ascii))
          (should-not (window-display-table window))
          (should-not (memq #'drgnx-tty-popups--pre-redisplay (default-value 'pre-redisplay-functions)))
          (should-not (advice-member-p #'drgnx-tty-popups--chrome-set 'drgnx-chrome--set))
          (should-not (display-table-slot standard-display-table 'box-vertical)))
      (set-frame-parameter frame 'drgnx-tty-ascii nil)
      (set-window-display-table window nil)
      (remove-hook 'pre-redisplay-functions #'drgnx-tty-popups--pre-redisplay)
      (advice-remove 'drgnx-chrome--set #'drgnx-tty-popups--chrome-set))))

;;; mod-tty-popups-test.el ends here

(ert-deftest drgnx-tty-popups/a-killed-terminal-s-frames-are-dead-when-the-delete-hook-runs ()
  ;; Killing a terminal runs `delete-frame-functions' with frames that are already dead, and `frame-parent'
  ;; signals on those.  Batch Emacs cannot make a dead frame, so `frame-live-p' and `frame-parent' are
  ;; stubbed the way Emacs behaves for one.
  (let ((dead (list 'dead-frame)) (scheduled nil))
    (cl-letf (((symbol-function 'frame-live-p) (lambda (f) (not (eq f dead))))
              ((symbol-function 'frame-parent)
               (lambda (&optional f) (if (eq f dead) (signal 'wrong-type-argument (list 'frame-live-p f)) nil)))
              ((symbol-function 'run-at-time) (lambda (&rest _) (setq scheduled t))))
      (should-not (condition-case err (progn (drgnx-tty-popups--frame-deleted dead) nil) (error err)))
      ;; a live top-level frame still schedules the update
      (drgnx-tty-popups--frame-deleted (selected-frame))
      (should scheduled))))
