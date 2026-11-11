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

;;; debug-gutter-test.el ends here
