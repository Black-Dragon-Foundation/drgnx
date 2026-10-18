;;; mod-tty-popups-test.el --- batch tests: ui/terminal-popups — borders, ASCII terminals, completion in the lane -*- lexical-binding: t -*-
;; Batch Emacs has no terminal: the terminal's coding system and the frame kind are stubbed; the tty tier
;; (test/tty/popups-test.el) runs the real thing on 30.2 and 31.1.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-tty-popups" drgnx-dir) nil t)
(defvar corfu-mode)
(defvar corfu-auto)
(defvar corfu-auto-prefix)
(defvar corfu-auto-commands)
(defvar corfu-auto-delay)

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
  ;; the slots of the standard display table (Emacs 31 has them; 30.2 has no tty child frames to draw with them)
  (when (drgnx-tty-popups--slots-p)
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

(ert-deftest drgnx-tty-popups/the-30-2-fallback-only-in-terminals ()
  ;; completion as you type goes to the popup lane in a terminal frame of an Emacs without tty child frames;
  ;; a graphical frame keeps corfu's popup, and so does a terminal frame that has child frames (31.1)
  (cl-letf (((symbol-function 'drgnx-tty-popups--child-frames-p) (lambda () nil)))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t)))
      (should-not (drgnx-tty-popups--lane-p)))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil)))
      (should (drgnx-tty-popups--lane-p))))
  (cl-letf (((symbol-function 'drgnx-tty-popups--child-frames-p) (lambda () t))
            ((symbol-function 'display-graphic-p) (lambda (&optional _) nil)))
    (should-not (drgnx-tty-popups--lane-p))))

(ert-deftest drgnx-tty-popups/completion-as-you-type-needs-corfu-auto-and-a-prefix ()
  ;; only where the user asked for it (corfu-mode with corfu-auto), after a self-inserting command, with
  ;; enough characters before point; never in a read-only buffer, a macro or the minibuffer
  (cl-letf (((symbol-function 'drgnx-tty-popups--lane-p) (lambda () t)))
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert "(with-")
      (let ((corfu-mode t) (corfu-auto t) (corfu-auto-prefix 2) (corfu-auto-commands '("self-insert-command\\'"))
            (this-command 'self-insert-command) (completion-in-region-mode nil))
        (should (drgnx-tty-popups--wanted-p))
        (let ((this-command 'forward-char)) (should-not (drgnx-tty-popups--wanted-p)))
        (let ((corfu-auto nil)) (should-not (drgnx-tty-popups--wanted-p)))
        (let ((corfu-mode nil)) (should-not (drgnx-tty-popups--wanted-p)))
        (let ((corfu-auto-prefix 9)) (should-not (drgnx-tty-popups--wanted-p)))
        (let ((defining-kbd-macro t)) (should-not (drgnx-tty-popups--wanted-p)))
        (let ((buffer-read-only t)) (should-not (drgnx-tty-popups--wanted-p)))
        ;; a list of our own showing is refreshed, one somebody else started is left alone
        (let ((completion-in-region-mode t) (drgnx-tty-popups--ours nil)) (should-not (drgnx-tty-popups--wanted-p)))
        (let ((completion-in-region-mode t) (drgnx-tty-popups--ours (cons (current-buffer) 'f))) (should (drgnx-tty-popups--wanted-p)))
        ;; the user can turn the shim off without touching corfu-auto
        (let ((drgnx-tty-popups-auto-completions nil)) (should-not (drgnx-tty-popups--wanted-p)))))))

(defmacro drgnx-tty-popups-test--hooks (&rest body)
  "BODY with the hooks the module adds and removes bound to nil, and the chrome advice taken off afterwards."
  `(let ((pre-redisplay-functions nil) (window-configuration-change-hook nil) (post-command-hook nil)
         (drgnx-modules--runs (list (list 'ui/terminal-popups 'ui/terminal-popups)))   ; the module is on
         (drgnx-tty-popups--ours nil))
     (unwind-protect (progn ,@body)
       (drgnx-timer-cancel 'tty-popups-show)
       (advice-remove 'drgnx-chrome--set #'drgnx-tty-popups--chrome-set))))

(defun drgnx-tty-popups-test--sync (frames ascii &optional child-frames)
  "The hooks (pre-redisplay wcch post-command chrome-advice) present after a sync with FRAMES terminal frames, ASCII
of them non-UTF-8."
  (cl-letf (((symbol-function 'drgnx-tty-popups--tty-frames) (lambda () frames))
            ((symbol-function 'drgnx-tty-popups--ascii-frame-p) (lambda (f) (memq f ascii)))
            ((symbol-function 'drgnx-tty-popups--child-frames-p) (lambda () child-frames)))
    (drgnx-tty-popups--sync)
    (list (and (memq 'drgnx-tty-popups--pre-redisplay pre-redisplay-functions) t)
          (and (memq 'drgnx-tty-popups--windows-changed window-configuration-change-hook) t)
          (and (memq 'drgnx-tty-popups--post-command post-command-hook) t)
          (and (advice-member-p #'drgnx-tty-popups--chrome-set 'drgnx-chrome--set) t))))

(ert-deftest drgnx-tty-popups/a-session-without-ascii-terminals-pays-nothing ()
  ;; the hooks that cost something on every redisplay or command are there only while a terminal needs them
  (drgnx-tty-popups-test--hooks
   ;; graphical only, or no terminal frame: nothing
   (should (equal (drgnx-tty-popups-test--sync nil nil) '(nil nil nil nil)))
   ;; a UTF-8 terminal on 30.2: only the completion shim
   (should (equal (drgnx-tty-popups-test--sync '(a) nil) '(nil nil t nil)))
   ;; …on 31.1: nothing (corfu has its child frame)
   (should (equal (drgnx-tty-popups-test--sync '(a) nil t) '(nil nil nil nil)))
   ;; a non-UTF-8 terminal: the ASCII hooks too, and they go with it
   (should (equal (drgnx-tty-popups-test--sync '(a b) '(b)) '(t t t t)))
   (should (equal (drgnx-tty-popups-test--sync '(a) nil) '(nil nil t nil)))
   (should (equal (drgnx-tty-popups-test--sync nil nil) '(nil nil nil nil)))
   ;; the option turns the shim off
   (let ((drgnx-tty-popups-auto-completions nil))
     (should (equal (drgnx-tty-popups-test--sync '(a) nil) '(nil nil nil nil))))))

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

(ert-deftest drgnx-tty-popups/typing-arms-a-timer-and-the-next-key-pushes-it-back ()
  (drgnx-tty-popups-test--hooks
   (drgnx-test-with-clock ()
     (let (shown)
       (cl-letf (((symbol-function 'drgnx-tty-popups--show) (lambda (&rest args) (push args shown)))
                 ((symbol-function 'drgnx-tty-popups--wanted-p) (lambda () t)))
         (let ((corfu-auto-delay 0.3))
           (with-temp-buffer
             (drgnx-tty-popups--post-command)
             (should (equal (car (drgnx-timer-pending)) '(tty-popups-show ui/terminal-popups debounce)))
             ;; the next command pushes the pause back: one list, 0.3 s after the last key
             (drgnx-test-advance 0.2)
             (drgnx-tty-popups--post-command)
             (drgnx-test-advance 0.2)
             (should-not shown)
             (drgnx-test-advance 0.15)
             (should (equal (mapcar #'car shown) (list (current-buffer))))
             ;; a command that wants nothing only cancels
             (drgnx-tty-popups--post-command)
             (cl-letf (((symbol-function 'drgnx-tty-popups--wanted-p) (lambda () nil)))
               (drgnx-tty-popups--post-command))
             (should-not (drgnx-timer-active-p 'tty-popups-show)))))))))

(ert-deftest drgnx-tty-popups/the-timer-shows-the-list-without-prompting-and-notes-it-is-ours ()
  (drgnx-tty-popups-test--hooks
   (let (interactive-allowed)
     (cl-letf (((symbol-function 'drgnx-tty-popups--lane-p) (lambda () t))
               ((symbol-function 'completion-help-at-point)
                (lambda () (setq interactive-allowed inhibit-interaction) (setq completion-in-region-mode t)))
               ((symbol-function 'completion-in-region-mode) (lambda (arg) (setq completion-in-region-mode (> arg 0)))))
       (with-temp-buffer
         (let ((completion-in-region-mode nil))
           (switch-to-buffer (current-buffer))
           (let ((tick (drgnx-tty-popups--tick)))
             ;; typing went on meanwhile: nothing
             (drgnx-tty-popups--show (current-buffer) (list 'stale))
             (should-not completion-in-region-mode)
             (drgnx-tty-popups--show (current-buffer) tick)
             (should completion-in-region-mode)
             (should (equal drgnx-tty-popups--ours (cons (current-buffer) (selected-frame))))
             ;; a timer never prompts
             (should (eq interactive-allowed t)))))))))

(ert-deftest drgnx-tty-popups/an-interrupted-lookup-leaves-no-list-mode-behind ()
  ;; typing went on in the middle of a slow completion-at-point function: the mode it had turned on is turned off,
  ;; or later refreshes would be refused
  (drgnx-tty-popups-test--hooks
   (cl-letf (((symbol-function 'drgnx-tty-popups--lane-p) (lambda () t))
             ((symbol-function 'completion-help-at-point)
              (lambda () (setq completion-in-region-mode t) (throw throw-on-input t)))
             ((symbol-function 'completion-in-region-mode) (lambda (arg) (setq completion-in-region-mode (> arg 0)))))
     (with-temp-buffer
       (let ((completion-in-region-mode nil))
         (switch-to-buffer (current-buffer))
         (drgnx-tty-popups--show (current-buffer) (drgnx-tty-popups--tick))
         (should-not completion-in-region-mode)
         (should-not drgnx-tty-popups--ours))))))

(ert-deftest drgnx-tty-popups/a-list-somebody-else-started-is-not-taken-over ()
  (drgnx-tty-popups-test--hooks
   (let (called)
     (cl-letf (((symbol-function 'drgnx-tty-popups--lane-p) (lambda () t))
               ((symbol-function 'completion-help-at-point) (lambda () (setq called t))))
       (with-temp-buffer
         (switch-to-buffer (current-buffer))
         (let ((completion-in-region-mode t))        ; TAB started it
           (drgnx-tty-popups--show (current-buffer) (drgnx-tty-popups--tick))
           (should-not called)))))))

(ert-deftest drgnx-tty-popups/our-list-goes-when-the-selected-buffer-or-frame-changes ()
  (drgnx-tty-popups-test--hooks
   (cl-letf (((symbol-function 'completion-in-region-mode) (lambda (arg) (setq completion-in-region-mode (> arg 0))))
             ((symbol-function 'drgnx-tty-popups--wanted-p) (lambda () nil)))
     (let ((completion-in-region-mode t))
       (with-temp-buffer
         (let ((here (current-buffer)))
           ;; still where it started: stays
           (setq drgnx-tty-popups--ours (cons here (selected-frame)))
           (drgnx-tty-popups--post-command)
           (should completion-in-region-mode)
           ;; the selected buffer is another one: closed
           (setq drgnx-tty-popups--ours (cons (get-buffer-create " *other*") (selected-frame)))
           (drgnx-tty-popups--post-command)
           (should-not completion-in-region-mode)
           (should-not drgnx-tty-popups--ours)
           (kill-buffer " *other*")))))))

(ert-deftest drgnx-tty-popups/setup-is-for-terminal-frames-only ()
  (let (called)
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'frame-live-p) (lambda (_) t))
              ((symbol-function 'drgnx-tty-popups--update-borders) (lambda () (setq called t))))
      (drgnx-tty-popups-setup 'gui)
      (should-not called))))

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
