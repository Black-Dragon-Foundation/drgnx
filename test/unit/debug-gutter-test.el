;;; debug-gutter-test.el --- batch tests: the breakpoint column -*- lexical-binding: t -*-
;; test-class: det
;; The hub's answers are scripted (`drgnx-hub-call' replaced): what is tested is what the editor asks, sends and draws.
;; The store itself has Rust tests (debug::tests_breakpoints, tests_registry).
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug-gutter" drgnx-dir) nil t)

(defvar debug-gutter-test--calls nil "Every (METHOD . PARAMS) the test's hub was asked, in order.")

(defmacro debug-gutter-test--with (lines &rest body)
  "BODY in a file buffer of LINES numbered lines, shown in the selected window, with the hub scripted: a
`debug/breakpoints' call is answered by `debug-gutter-test--answer' (PARAMS → the view), others with t."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "dg" t)) (file (expand-file-name "a.py" dir))
          (debug-gutter-test--calls nil) (debug-gutter-test--version 0) (was (window-buffer (selected-window))))
     (with-temp-file file (dotimes (i ,lines) (insert (format "line %d\n" (1+ i)))))
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params cb &rest _)
                  (setq debug-gutter-test--calls (append debug-gutter-test--calls (list (cons method params))))
                  (funcall cb (if (equal method "debug/breakpoints") (debug-gutter-test--answer params) t) nil)
                  1))
               ((symbol-function 'drgnx-hub-running-p) (lambda () t))
               ((symbol-function 'drgnx-debug-launch-root) (lambda () dir)))
       (let ((buf (find-file-noselect file)))
         (unwind-protect
             (progn (set-window-buffer (selected-window) buf)
                    (with-current-buffer buf (drgnx-debug-gutter-mode 1) ,@body))
           (with-current-buffer buf (set-buffer-modified-p nil) (drgnx-debug-gutter-mode -1))
           (set-window-buffer (selected-window) was)
           (kill-buffer buf)
           (delete-directory dir t))))))

(defvar debug-gutter-test--store nil "The scripted store: (ID . PLIST) of the file's breakpoints.")
(defvar debug-gutter-test--next 0)
(defvar debug-gutter-test--version 0 "The scripted store's version: up on every answer, as the hub's never goes back.")

(defun debug-gutter-test--answer (params)
  "The scripted hub's `debug/breakpoints': apply PARAMS' op to `debug-gutter-test--store', answer the view."
  (let ((op (plist-get params :op)))
    (pcase (plist-get op :op)
      ("add" (unless (cl-find (plist-get op :line) debug-gutter-test--store
                              :key (lambda (e) (plist-get (cdr e) :line)))
               (push (cons (cl-incf debug-gutter-test--next)
                           (list :id debug-gutter-test--next :line (plist-get op :line) :enabled t :verified t
                                 :log (plist-get op :log) :condition (plist-get op :condition)))
                     debug-gutter-test--store)))
      ("edit" (let ((bp (cdr (assq (plist-get op :id) debug-gutter-test--store))))
                (dolist (k '(:enabled :condition :hit :log))
                  (when (plist-member op k)
                    (let ((v (plist-get op k)))
                      (setq bp (plist-put bp k (if (equal v "") nil (if (eq v :false) nil v)))))))
                (setcdr (assq (plist-get op :id) debug-gutter-test--store) bp)))
      ("remove" (setq debug-gutter-test--store (assq-delete-all (plist-get op :id) debug-gutter-test--store)))
      ("move" (plist-put (cdr (assq (plist-get op :id) debug-gutter-test--store)) :line (plist-get op :line)))))
  (list :root "/r" :path (or (plist-get (plist-get params :op) :path) (plist-get params :path))
        :version (cl-incf debug-gutter-test--version)
        :breakpoints (mapcar #'cdr (reverse debug-gutter-test--store))))

(defun debug-gutter-test--marks ()
  "The column's marks: (LINE . KIND) of each breakpoint overlay, in line order."
  (sort (mapcar (lambda (o) (cons (line-number-at-pos (overlay-start o)) (overlay-get o 'drgnx-debug-kind)))
                (seq-filter (lambda (o) (overlay-get o 'drgnx-debug-bp)) (overlays-in (point-min) (point-max))))
        (lambda (a b) (< (car a) (car b)))))

(defun debug-gutter-test--ops ()
  "The ops sent with `debug/breakpoints', as (OP ID-OR-LINE)."
  (delq nil (mapcar (lambda (c) (when-let* ((op (plist-get (cdr c) :op)))
                                  (list (plist-get op :op) (or (plist-get op :id) (plist-get op :line)))))
                    debug-gutter-test--calls)))

(ert-deftest drgnx-debug-gutter/the-kind-of-each-breakpoint ()
  (should (equal (drgnx-debug-gutter--kind '(:enabled t :verified t)) 'bp))
  (should (equal (drgnx-debug-gutter--kind '(:enabled t :verified nil)) 'unverified))
  (should (equal (drgnx-debug-gutter--kind '(:enabled t :verified t :condition "x > 1")) 'cond))
  (should (equal (drgnx-debug-gutter--kind '(:enabled t :verified t :hit "3")) 'cond))
  (should (equal (drgnx-debug-gutter--kind '(:enabled t :verified t :log "x={x}")) 'log))
  (should (equal (drgnx-debug-gutter--kind '(:enabled nil :verified t :log "x")) 'off)))

(ert-deftest drgnx-debug-gutter/every-glyph-of-the-legend ()
  ;; the mockup's ten states: SVGs on a graphical frame, characters in a terminal (ASCII where it is not UTF-8)
  (dolist (k '(bp unverified cond off log hover stop stop-bp frame exception))
    (let ((svg (drgnx-debug-gutter--svg k 16 18 "#ff0000" "#888888" "#ffaa00" "#00ff00" "#101010")))
      (should (string-prefix-p "<svg" svg))
      (should (string-match-p "viewBox" svg))))
  (should (string-match-p "opacity" (drgnx-debug-gutter--svg 'hover 16 18 "#f00" "#888" "#fa0" "#0f0" "#111")))
  (should (equal (mapcar (lambda (k) (drgnx-debug-gutter--char k nil)) '(bp off log cond stop frame))
                 '("●" "○" "◆" "◐" "▶" "▷")))
  (should (equal (mapcar (lambda (k) (drgnx-debug-gutter--char k t)) '(bp off log cond stop frame))
                 '("B" "o" "L" "C" ">" "-"))))

(ert-deftest drgnx-debug-gutter/a-click-toggles-through-the-hub ()
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--with 10
      (drgnx-debug-gutter-toggle 4)
      (should (equal (debug-gutter-test--marks) '((4 . bp))))
      (drgnx-debug-gutter-toggle 4)
      (should-not (debug-gutter-test--marks))
      (should (equal (debug-gutter-test--ops) '(("add" 4) ("remove" 1)))))))

(ert-deftest drgnx-debug-gutter/the-column-shows-when-the-file-has-breakpoints ()
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0) (drgnx-debug-gutter-show 'auto))
    (debug-gutter-test--with 10
      (should-not (drgnx-margins-offset 'debug))
      (drgnx-debug-gutter-toggle 2)
      (should (drgnx-margins-offset 'debug))
      (should (> (car (window-margins)) 0))
      (drgnx-debug-gutter-toggle 2)
      (should-not (drgnx-margins-offset 'debug))
      (let ((drgnx-debug-gutter-show 'always))
        (drgnx-debug-gutter--claim)
        (should (drgnx-margins-offset 'debug)))
      (let ((drgnx-debug-gutter-show 'never))
        (drgnx-debug-gutter-toggle 3)
        (should-not (drgnx-margins-offset 'debug))))))

(ert-deftest drgnx-debug-gutter/moves-are-drafts-until-save ()
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--with 10
      (drgnx-debug-gutter-toggle 5)
      (drgnx-debug-gutter-toggle 8)
      (goto-char (point-min))
      (insert "new 1\nnew 2\n")
      ;; the marks move with the text; nothing is sent yet
      (should (equal (debug-gutter-test--marks) '((7 . bp) (10 . bp))))
      (should (equal (debug-gutter-test--ops) '(("add" 5) ("add" 8))))
      ;; a hub event while the buffer has drafts keeps them where the text put them
      (drgnx-debug-gutter--event "debug-breakpoints"
                                 (list :root "/r" :path buffer-file-name :version 2
                                       :breakpoints (mapcar #'cdr (reverse debug-gutter-test--store))))
      (should (equal (debug-gutter-test--marks) '((7 . bp) (10 . bp))))
      ;; delete line 10 (the second breakpoint's), then save: one move, one removal
      (goto-char (point-min)) (forward-line 9)
      (delete-region (point) (progn (forward-line 1) (point)))
      (save-buffer)
      (should (equal (cddr (debug-gutter-test--ops)) '(("move" 1) ("remove" 2))))
      (should (equal (debug-gutter-test--marks) '((7 . bp)))))))

(ert-deftest drgnx-debug-gutter/revert-puts-the-saved-lines-back ()
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--with 10
      (drgnx-debug-gutter-toggle 5)
      (goto-char (point-min))
      (insert "new\n")
      (should (equal (debug-gutter-test--marks) '((6 . bp))))
      (revert-buffer t t)
      (should (equal (debug-gutter-test--marks) '((5 . bp)))))))

(ert-deftest drgnx-debug-gutter/a-moved-line-from-the-hub-moves-the-mark ()
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--with 10
      (drgnx-debug-gutter-toggle 5)
      (drgnx-debug-gutter--event "debug-breakpoints"
                                 (list :root "/r" :path buffer-file-name :version 3
                                       :breakpoints (list (list :id 1 :line 5 :enabled t :verified t :bound_line 6))))
      (should (equal (debug-gutter-test--marks) '((6 . bp)))))))

(ert-deftest drgnx-debug-gutter/terminal-characters-follow-the-claim ()
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--with 10
      (drgnx-debug-gutter-toggle 3)
      (let* ((o (car (seq-filter (lambda (o) (overlay-get o 'drgnx-debug-bp)) (overlays-in (point-min) (point-max)))))
             (spec (get-text-property 0 'display (overlay-get o 'before-string))))
        (should (equal (car spec) '(margin left-margin)))
        ;; batch Emacs is a terminal frame: the mark is a character (ASCII when the terminal is not UTF-8), after the
        ;; pad of its claim
        (should (string-suffix-p (drgnx-debug-gutter--char 'bp (drgnx-ui-ascii-frame-p))
                                 (substring-no-properties (cadr spec))))))))

(ert-deftest drgnx-debug-gutter/a-graphical-mark-is-an-image-in-the-margin ()
  ;; a margin string's own display property is not drawn: the image is the margin spec itself, the claim's pad drawn
  ;; into it
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'image-type-available-p) (lambda (_) t))
            ((symbol-function 'drgnx-margins-offset) (lambda (&rest _) 2)))
    (let* ((s (drgnx-debug-gutter--margin-string 'bp "Breakpoint"))
           (spec (get-text-property 0 'display s)))
      (should (equal (car spec) '(margin left-margin)))
      (should (eq (car-safe (cadr spec)) 'image))
      (let ((svg (plist-get (cdr (cadr spec)) :data)))
        (should (string-match "width='\\([0-9]+\\)'" svg))
        (should (= (string-to-number (match-string 1 svg))
                   (* (frame-char-width) (+ 2 (drgnx-debug-gutter--columns)))))))))

;; the menu's items: (LABEL . COMMAND-SYMBOL) of `drgnx-debug-gutter--menu-items' as labels only
(defun debug-gutter-test--labels (line)
  (mapcar #'car (drgnx-debug-gutter--menu-items line)))

(ert-deftest drgnx-debug-gutter/the-menu-follows-the-line ()
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--with 10
      (let ((drgnx-debug-gutter--sessions nil))
        (should (equal (debug-gutter-test--labels 3)
                       '("Add Breakpoint" "Add Conditional Breakpoint…" "Add Logpoint…")))
        (drgnx-debug-gutter-toggle 3)
        (should (equal (debug-gutter-test--labels 3)
                       '("Remove Breakpoint" "Edit Condition…" "Edit Hit Count…" "Edit Log Message…"
                         "Disable Breakpoint")))
        (funcall (cdr (assoc "Disable Breakpoint" (drgnx-debug-gutter--menu-items 3))))
        (should (equal (debug-gutter-test--marks) '((3 . off))))
        (should (member "Enable Breakpoint" (debug-gutter-test--labels 3))))
      ;; a session in the project adds Run to Cursor
      (let ((drgnx-debug-gutter--sessions (list (list :id "s1" :root (drgnx-debug-launch-root)))))
        (should (member "Run to Cursor" (debug-gutter-test--labels 5)))
        (funcall (cdr (assoc "Run to Cursor" (drgnx-debug-gutter--menu-items 5))))
        (should (equal (car (last debug-gutter-test--calls))
                       (list "debug/run-to-cursor" :session "s1" :path buffer-file-name :line 5)))))))

(ert-deftest drgnx-debug-gutter/the-prompt-edits-and-empty-clears ()
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--with 10
      ;; on an empty line it adds a conditional breakpoint
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "x > 1")))
        (drgnx-debug-gutter-edit 4 'condition))
      (should (equal (debug-gutter-test--marks) '((4 . cond))))
      ;; the prompt starts from the current text; empty clears it
      (let (initial)
        (cl-letf (((symbol-function 'read-string) (lambda (_p init &rest _) (setq initial init) "")))
          (drgnx-debug-gutter-edit 4 'condition))
        (should (equal initial "x > 1")))
      (should (equal (debug-gutter-test--marks) '((4 . bp))))
      (should (equal (car (last (debug-gutter-test--ops))) '("edit" 1))))))

;; The hover pool: a dot on each shown line without a mark, lit by the pointer (Nidhogg's margin `mouse-face').  Batch
;; Emacs is a terminal without the patch, so these rows say the frame has it and give the colours.

(defconst debug-gutter-test--bg "#1e1f22" "The scripted margin background.")
(defconst debug-gutter-test--bp "#e5484d" "The scripted breakpoint colour.")

(defmacro debug-gutter-test--hovering (&rest body)
  "BODY with the frame lighting margin mouse faces and the column's colours scripted."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'drgnx-debug-gutter--hover-p) (lambda (&rest _) t))
             ((symbol-function 'drgnx-debug-gutter--hover-colours)
              (lambda () (cons debug-gutter-test--bg debug-gutter-test--bp))))
     (let ((drgnx-debug-gutter-show 'always))
       ,@body)))

(defun debug-gutter-test--dots (&optional window)
  "The lines of WINDOW's hover dots (default the selected window), in order."
  (let ((window (or window (selected-window))))
    (sort (mapcar (lambda (o) (line-number-at-pos (overlay-start o)))
                  (seq-filter (lambda (o) (eq (overlay-get o 'drgnx-debug-hover) window))
                              (overlays-in (point-min) (point-max))))
          #'<)))

(defun debug-gutter-test--shown (window)
  "The lines WINDOW shows, from its start: as many as its body is high, up to the buffer's last."
  (with-current-buffer (window-buffer window)
    (let ((first (line-number-at-pos (window-start window))))
      (number-sequence first (min (+ first (window-body-height window) -1)
                                  (line-number-at-pos (point-max)))))))

(ert-deftest drgnx-debug-gutter/the-hover-dot-hides-in-the-margin-and-shows-faint ()
  ;; at rest the dot is the margin's own background; the pointer turns it the breakpoint colour at 38 % over it
  (cl-letf (((symbol-function 'drgnx-margins-pad) (lambda (&rest _) " ")))
    (let* ((s (drgnx-debug-gutter--hover-string debug-gutter-test--bg debug-gutter-test--bp))
           (spec (get-text-property 0 'display s))
           (dot (cadr spec)) (i (1- (length dot))))
      (should (equal (car spec) '(margin left-margin)))
      (should (equal (substring-no-properties dot) " ●"))
      ;; in the UI font: its dot is the mockup's 10 px at 13 px (the code font's is 8) and its line is no taller
      (should (equal (get-text-property i 'face dot) (list :inherit 'drgnx-ui-text :foreground debug-gutter-test--bg)))
      (should (equal (get-text-property i 'mouse-face dot)
                     (list :inherit 'drgnx-ui-text
                           :foreground (drgnx-color-over debug-gutter-test--bp debug-gutter-test--bg 0.38))))
      (should (equal (get-text-property i 'help-echo dot) "Click to add a breakpoint"))
      ;; the pad lights nothing
      (should-not (get-text-property 0 'mouse-face dot)))))

(ert-deftest drgnx-debug-gutter/the-margin-background-is-the-buffers-default ()
  ;; the margin draws in `default' as the buffer remaps it
  (with-temp-buffer
    (should (equal (drgnx-debug-gutter--margin-background) (face-background 'default nil t)))
    (face-remap-add-relative 'default :background debug-gutter-test--bg)
    (should (equal (drgnx-debug-gutter--margin-background) debug-gutter-test--bg))))

(ert-deftest drgnx-debug-gutter/the-hover-pool-covers-the-shown-lines-without-a-mark ()
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--hovering
      (debug-gutter-test--with 200
        (drgnx-debug-gutter-toggle 3)
        (drgnx-debug-gutter--pool-update (selected-window))
        (should (equal (debug-gutter-test--dots) (remq 3 (debug-gutter-test--shown (selected-window)))))
        ;; every dot is this window's and at its line's start
        (dolist (o (overlays-in (point-min) (point-max)))
          (when (overlay-get o 'drgnx-debug-hover)
            (should (= (overlay-start o) (save-excursion (goto-char (overlay-start o)) (line-beginning-position))))))
        ;; a breakpoint added takes its line's dot; removed, gives it back
        (drgnx-debug-gutter-toggle 5)
        (drgnx-debug-gutter--pool-update (selected-window))
        (should-not (memq 5 (debug-gutter-test--dots)))
        (drgnx-debug-gutter-toggle 5)
        (drgnx-debug-gutter--pool-update (selected-window))
        (should (memq 5 (debug-gutter-test--dots)))))))

(ert-deftest drgnx-debug-gutter/the-hover-pool-follows-scroll-and-typing ()
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--hovering
      (debug-gutter-test--with 200
        (drgnx-debug-gutter--pool-update (selected-window))
        (let ((n (length (debug-gutter-test--dots))))
          ;; scrolled: the dots move to the new lines, no more of them
          (set-window-start (selected-window) (save-excursion (goto-char (point-min)) (forward-line 99) (point)))
          (drgnx-debug-gutter--pool-update (selected-window))
          (should (equal (debug-gutter-test--dots) (debug-gutter-test--shown (selected-window))))
          (should (= (length (debug-gutter-test--dots)) n))
          ;; typing that adds lines on screen: one dot per line still, none doubled
          (goto-char (window-start))
          (insert "a\nb\nc\n")
          (drgnx-debug-gutter--pool-update (selected-window))
          (should (equal (debug-gutter-test--dots) (debug-gutter-test--shown (selected-window)))))))))

(ert-deftest drgnx-debug-gutter/the-hover-pool-is-per-window ()
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--hovering
      (debug-gutter-test--with 200
        (let ((w1 (selected-window)) (w2 (split-window)))
          (unwind-protect
              (progn
                (set-window-start w2 (save-excursion (goto-char (point-min)) (forward-line 49) (point)))
                (drgnx-debug-gutter--pool-update w1)
                (drgnx-debug-gutter--pool-update w2)
                (should (equal (debug-gutter-test--dots w1) (debug-gutter-test--shown w1)))
                (should (equal (debug-gutter-test--dots w2) (debug-gutter-test--shown w2)))
                ;; a closed window's pool goes with the next update
                (delete-window w2)
                (drgnx-debug-gutter--pool-update w1)
                (should-not (debug-gutter-test--dots w2)))
            (when (window-live-p w2) (delete-window w2))))))))

(ert-deftest drgnx-debug-gutter/the-hover-pool-skips-folded-lines ()
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--hovering
      (debug-gutter-test--with 200
        ;; lines 6 to 8 folded away (as outline and hideshow do, with an invisible overlay from line 5's end)
        (let ((o (make-overlay (save-excursion (goto-char (point-min)) (forward-line 4) (line-end-position))
                               (save-excursion (goto-char (point-min)) (forward-line 7) (line-end-position)))))
          (overlay-put o 'invisible t)
          (drgnx-debug-gutter--pool-update (selected-window))
          (let ((dots (debug-gutter-test--dots)))
            (should (memq 5 dots)) (should (memq 9 dots))
            (should-not (or (memq 6 dots) (memq 7 dots) (memq 8 dots)))))))))

(ert-deftest drgnx-debug-gutter/no-hover-pool-without-the-margin-mouse-face ()
  ;; a terminal, or an Emacs whose margins light nothing: no pool; the column alone
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0) (drgnx-debug-gutter-show 'always))
    (debug-gutter-test--with 50
      (drgnx-debug-gutter--pool-update (selected-window))
      (should-not (debug-gutter-test--dots))))
  ;; the mode off takes the pool out
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--hovering
      (debug-gutter-test--with 50
        (drgnx-debug-gutter--pool-update (selected-window))
        (should (debug-gutter-test--dots))
        (drgnx-debug-gutter-mode -1)
        (should-not (debug-gutter-test--dots))
        (should-not (memq #'drgnx-debug-gutter--pool-update pre-redisplay-functions))))))

;;; debug-gutter-test.el ends here
