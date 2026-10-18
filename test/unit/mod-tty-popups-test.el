;;; mod-tty-popups-test.el --- batch tests: ui/terminal-popups — borders, ASCII terminals, completion in the lane -*- lexical-binding: t -*-
;; Batch Emacs has no terminal: the terminal's coding system and the frame kind are stubbed; the tty tier
;; (test/tty/popups-test.el) runs the real thing on 30.2 and 31.1.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/ui/drgnx-tty-popups" drgnx-dir) nil t)
(defvar corfu-mode)
(defvar corfu-auto)
(defvar corfu-auto-prefix)
(defvar corfu-auto-commands)

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
        (let ((completion-in-region-mode t) (drgnx-tty-popups--ours t)) (should (drgnx-tty-popups--wanted-p)))))))

(ert-deftest drgnx-tty-popups/setup-is-for-terminal-frames-only ()
  (let (called)
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'frame-live-p) (lambda (_) t))
              ((symbol-function 'drgnx-tty-popups--update-borders) (lambda () (setq called t))))
      (drgnx-tty-popups-setup 'gui)
      (should-not called))))

;;; mod-tty-popups-test.el ends here
