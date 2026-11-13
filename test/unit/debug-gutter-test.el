;;; debug-gutter-test.el --- batch tests: the breakpoint column -*- lexical-binding: t -*-
;; test-class: det
;; The hub's answers are scripted (`drgnx-hub-call' replaced): what is tested is what the editor asks, sends and draws.
;; The store itself has Rust tests (debug::tests_breakpoints, tests_registry).
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug-gutter" drgnx-dir) nil t)

(defvar debug-gutter-test--calls nil "Every (METHOD . PARAMS) the test's hub was asked, in order.")
(defvar debug-gutter-test--locations nil "What the test's hub answers `debug/breakpoint-locations' with.")

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
                  (funcall cb (pcase method
                                ("debug/breakpoints" (debug-gutter-test--answer params))
                                ("debug/breakpoint-locations" (list :locations debug-gutter-test--locations))
                                (_ t))
                           nil)
                  1))
               ((symbol-function 'drgnx-hub-running-p) (lambda () t))
               ((symbol-function 'drgnx-debug-launch-root) (lambda () dir)))
       ;; the column needs a file, not Python: python-mode's first use would install `after-load' forms for grep and
       ;; ffap for the rest of the process
       (let* ((auto-mode-alist nil) (magic-mode-alist nil) (interpreter-mode-alist nil)
              (buf (find-file-noselect file)))
         (unwind-protect
             (progn (set-window-buffer (selected-window) buf)
                    (with-current-buffer buf (drgnx-debug-gutter-mode 1) ,@body))
           (when (buffer-live-p buf)
             (with-current-buffer buf (set-buffer-modified-p nil) (drgnx-debug-gutter-mode -1))
             (kill-buffer buf))
           (set-window-buffer (selected-window) was)
           (delete-directory dir t))))))

(ert-deftest drgnx-debug-gutter/a-file-opens-when-no-hub-runs ()
  "The column's start asks the hub for the file's breakpoints (from `find-file-hook', `drgnx-debug--gutter-on'): with no
hub (its socket's directory is not there) the column comes up empty and never fails the visit (the GUI rows' find-file
failed \"no hub\" through it).  The hub is not stubbed."
  (let* ((run (make-temp-file "dg-run" t)) (dir (make-temp-file "dg" t)) (file (expand-file-name "a.py" dir))
         (process-environment (cons (concat "XDG_RUNTIME_DIR=" run) process-environment))
         buf)
    (write-region "x = 1\n" nil file nil 'silent)
    (unwind-protect
        (progn (setq buf (let ((auto-mode-alist nil) (magic-mode-alist nil)) (find-file-noselect file)))
               (with-current-buffer buf
                 (drgnx-debug-gutter-mode 1)
                 (should drgnx-debug-gutter-mode)
                 (should-not drgnx-debug-gutter--bps)))
      (when (buffer-live-p buf) (with-current-buffer buf (drgnx-debug-gutter-mode -1)) (kill-buffer buf))
      (delete-directory dir t) (delete-directory run t))))

(defvar debug-gutter-test--store nil "The scripted store: (ID . PLIST) of the file's breakpoints.")
(defvar debug-gutter-test--next 0)
(defvar debug-gutter-test--version 0 "The scripted store's version: up on every answer, as the hub's never goes back.")

(defun debug-gutter-test--answer (params)
  "The scripted hub's `debug/breakpoints': apply PARAMS' op to `debug-gutter-test--store', answer the view."
  (let ((op (plist-get params :op)))
    (pcase (plist-get op :op)
      ("add" (unless (cl-find (list (plist-get op :line) (plist-get op :column)) debug-gutter-test--store
                              :key (lambda (e) (list (plist-get (cdr e) :line) (plist-get (cdr e) :column)))
                              :test #'equal)
               (push (cons (cl-incf debug-gutter-test--next)
                           (list :id debug-gutter-test--next :line (plist-get op :line) :enabled t :verified t
                                 :column (plist-get op :column)
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

(defun debug-gutter-test--posn (line &optional window area)
  "A mouse position on LINE of WINDOW (default: the selected one) in AREA (default: the left margin)."
  (let ((pos (save-excursion (goto-char (point-min)) (forward-line (1- line)) (point))))
    (list (or window (selected-window)) (or area 'left-margin) '(0 . 0) 0 nil pos '(0 . 0) nil '(0 . 0) '(0 . 0))))

(ert-deftest drgnx-debug-gutter/a-drag-moves-the-breakpoint ()
  "Dragged in the column from a mark to another line (in the column or the text), the breakpoint moves there (`move',
its saved line plus the lines dragged); from a line without one, or into another window, nothing.  A press there
starts no text selection."
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--with 10
      (drgnx-debug-gutter-toggle 4)
      (drgnx-debug-gutter-drag (list 'drag-mouse-1 (debug-gutter-test--posn 4) (debug-gutter-test--posn 7)))
      (should (equal (debug-gutter-test--marks) '((7 . bp))))
      (drgnx-debug-gutter-drag (list 'drag-mouse-1 (debug-gutter-test--posn 7) (debug-gutter-test--posn 2 nil 3)))
      (should (equal (debug-gutter-test--marks) '((2 . bp))))
      (drgnx-debug-gutter-drag (list 'drag-mouse-1 (debug-gutter-test--posn 5) (debug-gutter-test--posn 8)))
      (drgnx-debug-gutter-drag (list 'drag-mouse-1 (debug-gutter-test--posn 2)
                                     (debug-gutter-test--posn 9 (minibuffer-window))))
      (should (equal (debug-gutter-test--ops) '(("add" 4) ("move" 1) ("move" 1))))
      (should (equal (delq nil (mapcar (lambda (c) (let ((op (plist-get (cdr c) :op)))
                                                     (and (equal (plist-get op :op) "move") (plist-get op :line))))
                                       debug-gutter-test--calls))
                     '(7 2)))
      (should (eq (lookup-key drgnx-debug-gutter-mode-map [left-margin drag-mouse-1]) #'drgnx-debug-gutter-drag))
      (should (eq (lookup-key drgnx-debug-gutter-mode-map [left-margin down-mouse-1]) #'ignore)))))

(defun debug-gutter-test--inline ()
  "The inline marks: (LINE COLUMN STRING) of each breakpoint overlay with a column, in order."
  (sort (mapcar (lambda (o) (list (line-number-at-pos (overlay-start o))
                                  (1+ (- (overlay-start o) (save-excursion (goto-char (overlay-start o))
                                                                           (line-beginning-position))))
                                  (substring-no-properties (overlay-get o 'before-string))))
                (seq-filter (lambda (o) (and (overlay-get o 'drgnx-debug-bp) (overlay-get o 'drgnx-debug-column)))
                            (overlays-in (point-min) (point-max))))
        (lambda (a b) (< (car a) (car b)))))

(ert-deftest drgnx-debug-gutter/an-inline-breakpoint-sits-at-its-column ()
  "Inline Breakpoint: a breakpoint at point's line and column (`add' with `:column'), drawn as a dot before that
character, not in the column; again there removes it.  The line's own toggle leaves it alone."
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--with 10
      (goto-char (point-min)) (forward-line 2) (forward-char 4)
      (drgnx-debug-inline-breakpoint)
      (should (equal (debug-gutter-test--inline) '((3 5 "●"))))
      (should (equal (plist-get (plist-get (cdr (car (last debug-gutter-test--calls))) :op) :column) 5))
      (drgnx-debug-gutter-toggle 3)
      (should (equal (debug-gutter-test--marks) '((3 . bp) (3 . bp))))
      (drgnx-debug-gutter-toggle 3)
      (should (equal (debug-gutter-test--inline) '((3 5 "●"))))
      (drgnx-debug-inline-breakpoint)
      (should-not (debug-gutter-test--marks))
      (should (equal (debug-gutter-test--ops) '(("add" 3) ("add" 3) ("remove" 2) ("remove" 1)))))))

(ert-deftest drgnx-debug-gutter/inline-candidates-while-stopped ()
  "While this project's session is stopped, each line with a breakpoint shows faint dots where the adapter can stop
(`debug/breakpoint-locations', two or more on the line), but not where one already is (a line breakpoint holds the
first); a click on a dot adds an
inline breakpoint there.  None with the setting off, or once the session runs."
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0)
        (debug-gutter-test--locations (vector (list :line 2 :column 1) (list :line 2 :column 3) (list :line 2 :column 6))))
    (debug-gutter-test--with 10
      (let ((cands (lambda () (sort (mapcar (lambda (o) (1+ (- (overlay-start o) (pos-bol 2))))
                                            (seq-filter (lambda (o) (overlay-get o 'drgnx-debug-candidate))
                                                        (overlays-in (point-min) (point-max))))
                                    #'<))))
        (drgnx-debug-gutter-toggle 2)
        (should-not (funcall cands))
        ;; a session still starting (no caps yet) is not asked
        (drgnx-debug-gutter--event "debug-state" (list :sessions (vector (list :id "s1" :root (drgnx-debug-launch-root)
                                                                               :state "stopped"))))
        (should-not (assoc "debug/breakpoint-locations" debug-gutter-test--calls))
        (drgnx-debug-gutter--event "debug-state" (list :sessions (vector (list :id "s1" :root (drgnx-debug-launch-root)
                                                                               :state "stopped" :caps (list :supportsBreakpointLocationsRequest t)))))
        (should (equal (cdr (assoc "debug/breakpoint-locations" debug-gutter-test--calls))
                       (list :session "s1" :path buffer-file-name :line 2)))
        (should (equal (funcall cands) '(3 6)))
        (let ((o (seq-find (lambda (o) (and (overlay-get o 'drgnx-debug-candidate) (= (overlay-start o) (+ (pos-bol 2) 2))))
                           (overlays-in (point-min) (point-max)))))
          (funcall (overlay-get o 'drgnx-debug-candidate)))
        (should (equal (debug-gutter-test--inline) '((2 3 "●"))))
        (should (equal (funcall cands) '(6)))
        (let ((drgnx-debug-inline-breakpoint-candidates nil))
          (drgnx-debug-gutter--event "debug-state" (list :sessions (vector (list :id "s1" :root (drgnx-debug-launch-root)
                                                                                 :state "stopped" :caps (list :supportsBreakpointLocationsRequest t)))))
          (should-not (funcall cands)))
        (drgnx-debug-gutter--event "debug-state" (list :sessions (vector (list :id "s1" :root (drgnx-debug-launch-root)
                                                                               :state "stopped" :caps (list :supportsBreakpointLocationsRequest t)))))
        (should (funcall cands))
        (drgnx-debug-gutter--event "debug-state" (list :sessions (vector (list :id "s1" :root (drgnx-debug-launch-root)
                                                                               :state "running"))))
        (should-not (funcall cands))))))

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
      (revert-buffer t t t)                 ; auto-revert's way: the modes stay
      (should (equal (debug-gutter-test--marks) '((5 . bp)))))))

(ert-deftest drgnx-debug-gutter/breakpoints-and-the-stop-in-the-overview-ruler ()
  "The column hands the overview ruler its marks (on by default): a breakpoint's place in the middle lane (grey while
disabled), the stopped line's across it; the stop's mark goes with the stop, the ruler with the column."
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--with 10
      (let ((ruler (lambda () (mapcar (lambda (m) (list (line-number-at-pos (car m)) (nth 1 m) (nth 2 m)))
                                      (sort (copy-sequence drgnx-ruler--marks) (lambda (a b) (< (car a) (car b))))))))
        (drgnx-debug-gutter-toggle 5)
        (should drgnx-ruler-mode)
        (should (equal (funcall ruler) '((5 middle drgnx-debug-ruler-breakpoint))))
        (drgnx-debug-gutter--mark-stop "s1" 'top 'stop 'drgnx-debug-stopped-line 7 nil)
        (should (equal (funcall ruler) '((5 middle drgnx-debug-ruler-breakpoint) (7 full drgnx-debug-ruler-stop))))
        (drgnx-debug-gutter-stop-clear "s1")
        (should (equal (funcall ruler) '((5 middle drgnx-debug-ruler-breakpoint))))
        (drgnx-debug-gutter-mode -1)
        (should-not drgnx-ruler-mode)))))

(ert-deftest drgnx-debug-gutter/a-killed-buffer-releases-the-hooks ()
  "Killing a file's buffer with the column on turns the column off first: the margin's window hooks and the column's
global hooks go with the last column."
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--with 3
      (drgnx-debug-gutter-toggle 2)
      (should (memq #'drgnx-debug-gutter--restring drgnx-margins-changed-functions))
      (set-buffer-modified-p nil)
      (kill-buffer)
      (should-not (memq #'drgnx-debug-gutter--restring drgnx-margins-changed-functions))
      (should-not (memq #'drgnx-debug-gutter--event drgnx-hub-event-functions))
      (should-not (memq #'drgnx-margins--window-buffer-changed window-buffer-change-functions)))))

(ert-deftest drgnx-debug-gutter/a-new-major-mode-turns-the-column-off-cleanly ()
  "A revert that sets the major mode again (`normal-mode') kills the buffer's locals: the column turns off first, its
claim on the margin and the margin's window hooks released; the module's `find-file-hook' (here, the fixture's) turns
it on again with the store's lines."
  (let ((debug-gutter-test--store nil) (debug-gutter-test--next 0))
    (debug-gutter-test--with 10
      (drgnx-debug-gutter-toggle 5)
      (goto-char (point-min))
      (insert "new\n")
      (revert-buffer t t)
      (should-not drgnx-debug-gutter-mode)
      (should-not (debug-gutter-test--marks))
      (should-not (memq #'drgnx-margins--window-buffer-changed window-buffer-change-functions))
      (let ((find-file-hook (list (lambda () (drgnx-debug-gutter-mode 1)))))
        (revert-buffer t t))
      (should drgnx-debug-gutter-mode)
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
        (let ((n (length (debug-gutter-test--dots))) (start (window-start)))
          ;; scrolled: the scroll's frames draw no dots (unseen at rest anyway); once the window settles they are
          ;; on the new lines, no more of them
          (set-window-start (selected-window) (save-excursion (goto-char (point-min)) (forward-line 99) (point)))
          (drgnx-debug-gutter--pool-update (selected-window))
          (should-not (debug-gutter-test--dots))
          (should (drgnx-timer-active-p (cons 'debug-hover (selected-window))))
          ;; back where it was before it settled: still none until it does
          (set-window-start (selected-window) start)
          (drgnx-debug-gutter--pool-update (selected-window))
          (should-not (debug-gutter-test--dots))
          (set-window-start (selected-window) (save-excursion (goto-char (point-min)) (forward-line 99) (point)))
          (should (drgnx-timer-active-p (cons 'debug-hover (selected-window))))
          (drgnx-debug-gutter--pool-settle (selected-window) (current-buffer))
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
                ;; now: the split resized w1, which would otherwise wait for it to settle
                (drgnx-debug-gutter--pool-update w1 t)
                (drgnx-debug-gutter--pool-update w2 t)
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
