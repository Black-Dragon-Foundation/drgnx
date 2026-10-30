;;; explorer-test.el --- Scenarios: the Explorer (file tree) -*- lexical-binding: t -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; The reference is VS Code's Explorer.  See docs/develop/scenarios.md.

(require 'ert)
(require 'drgnx-scenario)
(require 'drgnx-uitest)

(defmacro drgnx-scn--with-explorer (root &rest body)
  "Fresh fixture ROOT, its main.py open, the sidebar shown and the Explorer focused, then BODY."
  (declare (indent 1))
  `(drgnx-scenario-settling
    (drgnx-scenario-load-driver)
    (drgnx-scenario-with-fixture (,root 'basic)
      (drgnx-driver-reset)
      (drgnx-driver-open-file (expand-file-name "src/app/main.py" ,root))
      (drgnx-driver-show-sidebar)
      (drgnx-uitest-run nil)
      (drgnx-uitest-run (drgnx-uitest-key-events drgnx-driver-focus-explorer-keys))
      (drgnx-uitest-run nil)
      ,@body)))

(defun drgnx-scn--explorer-line ()
  "Text of the Explorer row at point."
  (let ((w (drgnx-driver-explorer-window)))
    (with-current-buffer (window-buffer w)
      (save-excursion (goto-char (window-point w))
                      (string-trim (buffer-substring-no-properties (pos-bol) (pos-eol)))))))

(defun drgnx-scn--click (text &optional count hold)
  "Click the Explorer row showing TEXT; return the jank report."
  (let ((xy (drgnx-uitest-target-xy drgnx-driver-explorer-target text)))
    (drgnx-uitest-run (drgnx-uitest-click-events (drgnx-uitest-posn (car xy) (cdr xy)) 1 count hold))))

(defun drgnx-scn--click-folder-stays ()
  (let* ((r (drgnx-scn--click "docs"))
         (line (drgnx-scn--explorer-line)))
    (drgnx-scenario-check
     (and (string-search "docs" line) (= (plist-get r :oscillations) 0))
     (format "a single click on a folder must keep the selection on it; after %d snap-back(s) it is on %S"
             (plist-get r :oscillations) line)
     r)))

(ert-deftest drgnx-scenario/explorer-click-stays ()
  "Single click on a folder: the selection stays on that folder."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-click-stays)
  (drgnx-scn--with-explorer root
    (drgnx-scn--click-folder-stays)))

(ert-deftest drgnx-scenario/explorer-follow-override ()
  "The override experiment: with the configuration's Explorer follow switched off, the
click-stays scenario passes — so the follow is what breaks it."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-follow-override)
  (drgnx-scenario-load-driver)
  (unless (fboundp 'drgnx-driver-disable-follow) (ert-skip "this configuration has no follow to switch off"))
  (drgnx-driver-disable-follow)
  (drgnx-scenario-settling
   (unwind-protect
       (drgnx-scn--with-explorer root
         (drgnx-scn--click-folder-stays))
     (drgnx-driver-enable-follow))))

(defun drgnx-scn--explorer-has (text)
  (with-current-buffer (window-buffer (drgnx-driver-explorer-window))
    (save-excursion (goto-char (point-min)) (and (search-forward text nil t) t))))

(ert-deftest drgnx-scenario/explorer-expand-stays ()
  "Double click on a collapsed folder: it expands; the selection and the view stay."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-expand-stays)
  (drgnx-scn--with-explorer root
    (let* ((w (drgnx-driver-explorer-window))
           (start (window-start w))
           (r (drgnx-scn--click "docs" 2))
           (line (drgnx-scn--explorer-line))
           (expanded (drgnx-scn--explorer-has "guide.md")))
      (drgnx-scenario-check
       (and expanded (string-search "docs" line) (= (window-start w) start) (= (plist-get r :oscillations) 0))
       (format "a double click must expand the folder and keep selection and view: expanded %s, selection on %S, view %s, %d snap-back(s)"
               expanded line (if (= (window-start w) start) "kept" "moved") (plist-get r :oscillations))
       r))))

(ert-deftest drgnx-scenario/explorer-hold-is-a-click ()
  "Press, hold 300 ms, release without moving the mouse: a click on the row pressed — even if
something reveals the editor's file meanwhile.  (A tree that moves under a held button turns
the release into a drag; with drag-to-move on, that moves files.)"
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-hold-is-a-click)
  (drgnx-scn--with-explorer root
    (let ((w (drgnx-driver-explorer-window)))
      ;; Collapse src/app (above `tests'): revealing main.py would expand it again.
      (drgnx-driver-explorer-collapse "src/app")
      (drgnx-uitest-run nil)
      (drgnx-scenario-require (not (drgnx-scn--explorer-has "util.py")) "src/app collapsed")
      (let* ((events nil)
             (record (lambda () (when (mouse-event-p last-input-event)
                                  (push (car last-input-event) events))))
             (r (progn (add-hook 'pre-command-hook record)
                       (unwind-protect (drgnx-scn--click "tests" 1 0.3)
                         (remove-hook 'pre-command-hook record))))
             (line (drgnx-scn--explorer-line))
             (drag (seq-find (lambda (e) (string-prefix-p "drag-" (symbol-name e))) events)))
        (drgnx-scenario-check
         (and (not drag) (string-search "tests" line) (= (plist-get r :oscillations) 0))
         (format "press-hold-release on a row must be a click on that row: input arrived as %s, selection on %S, %d snap-back(s)"
                 (reverse events) line (plist-get r :oscillations))
         r)))))

(ert-deftest drgnx-scenario/explorer-keys-during-churn ()
  "Moving through the Explorer with keys while buffers come and go in the background: only
the keys move the selection."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-keys-during-churn)
  (drgnx-scn--with-explorer root
    (let* ((w (drgnx-driver-explorer-window))
           (line0 (with-current-buffer (window-buffer w) (line-number-at-pos (window-point w))))
           (churn (run-with-timer 0 0.1 (lambda () (kill-buffer (generate-new-buffer "drgnx-churn"))))))
      (drgnx-scenario-require (timerp churn) "a churn timer")
      (drgnx-uitest-run (drgnx-uitest-key-events (format "%s %s" drgnx-driver-explorer-down-key drgnx-driver-explorer-down-key)))
      ;; Look again after the churn stops: a follower starved during it may fire then.
      (cancel-timer churn)
      (let* ((r (drgnx-uitest-run nil))
             (line (with-current-buffer (window-buffer w) (line-number-at-pos (window-point w)))))
        (drgnx-scenario-check
         (= line (+ line0 2))
         (format "two %s during background churn must leave the selection two rows down (%d → %d); after the churn it is on row %d (%S)" drgnx-driver-explorer-down-key
                 line0 (+ line0 2) line (drgnx-scn--explorer-line))
         r)))))

(ert-deftest drgnx-scenario/explorer-cross-project-keeps-root ()
  "Opening a file of another project keeps the Explorer's root (VS Code keeps its workspace)."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-cross-project-keeps-root)
  (drgnx-scn--with-explorer root
    (drgnx-scenario-with-fixture (other 'second)
      (let* ((roots0 (drgnx-driver-explorer-roots))
             (_ (drgnx-scenario-require (member (file-name-as-directory root) roots0)
                                        "the Explorer showing the fixture before the other project's file opens"))
             (_ (drgnx-driver-open-file (expand-file-name "lib/other.py" other)))
             (r (drgnx-uitest-run nil))
             (roots (drgnx-driver-explorer-roots)))
        (drgnx-scenario-check
         (member (file-name-as-directory root) roots)
         (format "opening a file of another project must not replace the Explorer's root: %S became %S"
                 (mapcar #'file-name-nondirectory (mapcar #'directory-file-name roots0))
                 (mapcar #'file-name-nondirectory (mapcar #'directory-file-name roots)))
         r)))))

(ert-deftest drgnx-scenario/explorer-keys-stay ()
  "Moving through the Explorer with keys: the selection stays where the keys put it."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-keys-stay)
  (drgnx-scn--with-explorer root
    (let* ((w (drgnx-driver-explorer-window))
           (line0 (with-current-buffer (window-buffer w) (line-number-at-pos (window-point w))))
           (r (drgnx-uitest-run (drgnx-uitest-key-events (format "%s %s" drgnx-driver-explorer-down-key drgnx-driver-explorer-down-key))))
           (line (with-current-buffer (window-buffer w) (line-number-at-pos (window-point w)))))
      (drgnx-scenario-check
       (= line (+ line0 2))
       (format "after two %s the selection must be two rows down (row %d); it is on row %d (%S)" drgnx-driver-explorer-down-key
               (+ line0 2) line (drgnx-scn--explorer-line))
       r))))

(ert-deftest drgnx-scenario/explorer-keys-then-background-event ()
  "After browsing with keys, something unrelated creates a buffer in the background (an
agent or status poll): the selection stays where it is."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-keys-then-background-event)
  (drgnx-scn--with-explorer root
    (let ((w (drgnx-driver-explorer-window)))
      (with-selected-window w (forward-line 2))   ; setup: two rows down, without commands
      (drgnx-uitest-run nil)
      (let ((line0 (with-current-buffer (window-buffer w) (line-number-at-pos (window-point w)))))
        (run-with-timer 0.05 nil (lambda () (kill-buffer (generate-new-buffer "drgnx-background"))))
        (let* ((r (drgnx-uitest-run nil))
               (line (with-current-buffer (window-buffer w) (line-number-at-pos (window-point w)))))
          (drgnx-scenario-check
           (= line line0)
           (format "a background buffer event must not move the Explorer selection: row %d became row %d (%S)"
                   line0 line (drgnx-scn--explorer-line))
           r))))))

(ert-deftest drgnx-scenario/explorer-change-during-hold-is-still-a-click ()
  "A folder appears above the row while its button is held (a build, git, another program): the
release is still a click on the row pressed — the tree does not change under a held button."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-change-during-hold-is-still-a-click)
  (drgnx-scn--with-explorer root
    (let* ((events nil)
           (record (lambda () (when (mouse-event-p last-input-event) (push (car last-input-event) events))))
           (_ (run-with-timer 0.1 nil (lambda () (make-directory (expand-file-name "aaa-new" root)))))
           (r (progn (add-hook 'pre-command-hook record)
                     (unwind-protect (drgnx-scn--click "tests" 1 0.4)
                       (remove-hook 'pre-command-hook record))))
           (line (drgnx-scn--explorer-line))
           (drag (seq-find (lambda (e) (string-prefix-p "drag-" (symbol-name e))) events)))
      (drgnx-scenario-check
       (and (not drag) (string-search "tests" line))
       (format "a change during the hold must not turn the click into a drag or move the selection: input %s, selection on %S"
               (reverse events) line)
       r))))

(ert-deftest drgnx-scenario/explorer-external-change-keeps-the-selection ()
  "Browsing with keys, a new folder appears above the selected row: the selection stays on its entry."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-external-change-keeps-the-selection)
  (drgnx-scn--with-explorer root
    (drgnx-uitest-run (drgnx-uitest-key-events (format "%s %s" drgnx-driver-explorer-down-key drgnx-driver-explorer-down-key)))
    (let ((line0 (drgnx-scn--explorer-line)))
      (make-directory (expand-file-name "aaa-new" root))
      (let* ((r (drgnx-uitest-run nil))
             (line (drgnx-scn--explorer-line)))
        (drgnx-scenario-check
         (and (equal line line0) (drgnx-scn--explorer-has "aaa-new"))
         (format "a new folder must appear without moving the selection: shown %s; selection was on %S, now on %S"
                 (drgnx-scn--explorer-has "aaa-new") line0 line)
         r)))))

;;;; The click model (M3a-8): double click, drag, the pressed flag, a partly visible bottom row

(defun drgnx-scn--click-model-only ()
  "These scenarios state drgnx's own click model (docs/guide/explorer.md); other configurations skip them."
  (drgnx-scenario-load-driver)
  (unless (eq (drgnx-scenario-config) 'drgnx) (ert-skip "the click model is drgnx's own")))

(defun drgnx-scn--editor-file ()
  (buffer-file-name (window-buffer (drgnx-driver-editor-window))))

(ert-deftest drgnx-scenario/explorer-double-click-opens-a-file ()
  "Double click on a file: it opens in the editor and the editor takes the focus."
  (drgnx-scn--click-model-only)
  (drgnx-scn--with-explorer root
    (let* ((r (drgnx-scn--click "util.py" 2))
           (file (drgnx-scn--editor-file)))
      (drgnx-scenario-check
       (and file (string-suffix-p "src/app/util.py" file)
            (eq (selected-window) (drgnx-driver-editor-window)))
       (format "a double click on a file must open it and focus the editor: the editor shows %S, the selected window is the %s"
               (and file (file-name-nondirectory file))
               (if (eq (selected-window) (drgnx-driver-editor-window)) "editor" "Explorer or another window"))
       r))))

(defun drgnx-scn--drag (from to)
  "Press on the row showing FROM and release on the row showing TO (one drag); return the jank report."
  (let* ((a (drgnx-uitest-target-xy drgnx-driver-explorer-target from))
         (b (drgnx-uitest-target-xy drgnx-driver-explorer-target to))
         (pa (drgnx-uitest-posn (car a) (cdr a)))
         (pb (drgnx-uitest-posn (car b) (cdr b))))
    (drgnx-uitest-run (list (list 'down-mouse-1 pa) (list 'drag-mouse-1 pa pb)))))

(ert-deftest drgnx-scenario/explorer-drag-does-nothing ()
  "Press on one row, release on another: nothing opens, nothing toggles, no file moves."
  (drgnx-scn--click-model-only)
  (drgnx-scn--with-explorer root
    (let* ((before (directory-files-recursively root "" t (lambda (d) (not (string-match-p "/\\.git\\'" d)))))
           (file0 (drgnx-scn--editor-file))
           (r (drgnx-scn--drag "tests" "README.md"))
           (after (directory-files-recursively root "" t (lambda (d) (not (string-match-p "/\\.git\\'" d))))))
      (drgnx-scenario-check
       (and (equal (drgnx-scn--editor-file) file0)
            (not (drgnx-scn--explorer-has "test_main.py"))
            (equal (sort before #'string<) (sort after #'string<))
            (not (drgnx-driver-explorer-pressed-p)))
       (format "a drag must not open, toggle or move anything: the editor shows %S (was %S), tests %s, files %s, button %s"
               (and (drgnx-scn--editor-file) (file-name-nondirectory (drgnx-scn--editor-file)))
               (and file0 (file-name-nondirectory file0))
               (if (drgnx-scn--explorer-has "test_main.py") "expanded" "collapsed")
               (if (equal (sort before #'string<) (sort after #'string<)) "unchanged" "changed")
               (if (drgnx-driver-explorer-pressed-p) "still held" "released"))
       r))))

(ert-deftest drgnx-scenario/explorer-pressed-flag-clears-after-release ()
  "The Explorer counts the button as held from the press to the release — after a click, a
double click or a drag it does not."
  (drgnx-scn--click-model-only)
  (drgnx-scn--with-explorer root
    (let* ((xy (drgnx-uitest-target-xy drgnx-driver-explorer-target "tests"))
           (posn (drgnx-uitest-posn (car xy) (cdr xy)))
           (r0 (drgnx-uitest-run (list (list 'down-mouse-1 posn))))
           (held (drgnx-driver-explorer-pressed-p))
           states)
      (drgnx-scenario-require held "the Explorer to count the pressed button as held before the release")
      (drgnx-uitest-run (list (list 'mouse-1 posn)))
      (push (cons "click" (drgnx-driver-explorer-pressed-p)) states)
      (drgnx-scn--click "util.py" 2)
      (push (cons "double click" (drgnx-driver-explorer-pressed-p)) states)
      (drgnx-scn--drag "util.py" "README.md")
      (push (cons "drag" (drgnx-driver-explorer-pressed-p)) states)
      (drgnx-scenario-check
       (not (seq-some #'cdr states))
       (format "the pressed flag must clear on release; still set after: %s"
               (mapconcat #'car (seq-filter #'cdr (reverse states)) ", "))
       r0))))

(defun drgnx-scn--partial-bottom-row (window)
  "(POS . VISIBILITY) of the row at the bottom of WINDOW that shows only in part, or nil.
VISIBILITY is `pos-visible-in-window-p's (X Y RTOP RBOT ROWH VPOS)."
  (with-current-buffer (window-buffer window)
    (save-excursion
      (goto-char (window-start window))
      (let (found)
        (while (and (not found) (not (eobp)) (<= (point) (window-end window t)))
          (let ((v (pos-visible-in-window-p (point) window t)))
            (when (and (consp v) (nth 3 v) (> (nth 3 v) 0)) (setq found (cons (point) v))))
          (forward-line 1))
        found))))

(ert-deftest drgnx-scenario/explorer-click-on-a-partly-visible-bottom-row ()
  "Click on the bottom row of the Explorer when only part of it shows: the click selects and
opens that row, and the view does not scroll under the pointer."
  (drgnx-scn--click-model-only)
  (drgnx-scn--with-explorer root
    (dotimes (i 80) (write-region "" nil (expand-file-name (format "zz-%02d.txt" i) root) nil 'silent))
    (drgnx-driver-explorer-refresh)
    (drgnx-uitest-run nil)
    (let* ((w (drgnx-driver-explorer-window))
           (_ (with-current-buffer (window-buffer w) (set-window-start w (point-min))))
           (_ (drgnx-uitest-run nil))
           (frame (window-frame w))
           (height (frame-text-height frame))
           (row (or (drgnx-scn--partial-bottom-row w)
                    ;; The window's height is a whole number of rows: the frame half a row shorter, as a user's
                    ;; window is (a vscroll would not do: redisplay drops it once point enters the half row)
                    (let ((frame-resize-pixelwise t))
                      (set-frame-height frame (- height (/ (default-line-height) 2)) nil t)
                      (drgnx-uitest-run nil)
                      (with-current-buffer (window-buffer w) (set-window-start w (point-min)))
                      (drgnx-uitest-run nil)
                      (drgnx-scn--partial-bottom-row w))))
           (start (window-start w)))
      (unwind-protect
          (progn
            (drgnx-scenario-require row "a partly visible bottom row in the Explorer")
            (let* ((v (cdr row))
                   (origin (drgnx-uitest--text-origin w))
                   (top (posn-x-y (posn-at-point (car row) w)))      ; text-area pixels of the row's top left
                   (x (+ (car origin) (car top) 6))
                   (y (+ (cdr origin) (cdr top) (/ (nth 4 v) 2)))    ; ROWH: the part of the row that shows
                   (name (with-current-buffer (window-buffer w)
                           (string-trim (buffer-substring-no-properties (car row) (save-excursion (goto-char (car row)) (pos-eol))))))
                   (posn (drgnx-uitest-posn x y))
                   (_ (drgnx-scenario-require
                       (and (eq (posn-window posn) w) (eql (posn-point posn) (car row)))
                       (format "the pixel %d,%d (row %S: %S) to land on the bottom row, it landed on %S at %S"
                               x y name v (posn-window posn) (posn-point posn))))
                   (r (drgnx-uitest-run (drgnx-uitest-click-events posn)))
                   (file (drgnx-scn--editor-file)))
              (drgnx-scenario-check
               (and file (string-suffix-p name file) (= (window-start w) start))
               (format "a click on the partly visible bottom row %S must open it without scrolling: the editor shows %S, view %s"
                       name (and file (file-name-nondirectory file)) (if (= (window-start w) start) "kept" "scrolled"))
               r)))
        (unless (= (frame-text-height frame) height)        ; the next scenario's frame as it was
          (let ((frame-resize-pixelwise t)) (set-frame-height frame height nil t))
          (drgnx-uitest-run nil))))))
