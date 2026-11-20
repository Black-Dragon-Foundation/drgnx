;;; grid-drag-test.el --- batch tests: dragging a tile by its grip, dropping it on a zone -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-dir) nil t)
(require 'drgnx-groups)
(require 'drgnx-grid-ops)
(require 'drgnx-chrome)

(defun drgnx-grid-drag-test--posn (window x y &optional area)
  "A posn on WINDOW at frame pixel X, Y: in its text, or in AREA (`tab-line') measured from the window's corner."
  (let ((e (if area (window-pixel-edges window) (window-body-pixel-edges window))))
    (list window (or area 1) (cons (- x (nth 0 e)) (- y (nth 1 e))) 0 nil 1 nil nil nil nil)))

(defun drgnx-grid-drag-test--centre (window)
  (let ((e (drgnx-grid--edges window))) (cons (/ (+ (nth 0 e) (nth 2 e)) 2) (/ (+ (nth 1 e) (nth 3 e)) 2))))

(defmacro drgnx-grid-drag-test--events (events &rest body)
  "BODY with `read-event' and `read-key' (a tab press reads its release with it) answering EVENTS in turn (then a
quit)."
  (declare (indent 1))
  `(let* ((queue ,events)
          (next (lambda (&rest _) (if queue (pop queue) (signal 'quit nil)))))
     (cl-letf (((symbol-function 'read-event) next) ((symbol-function 'read-key) next))
       ,@body)))

(ert-deftest drgnx-grid-drag/zones-pick-the-target ()
  ;; the tile under the pointer, and the zone of it: the outer quarter of a side splits there, the middle stacks
  (drgnx-grid-test--with
    (let* ((one (selected-window)) (two (drgnx-groups-split-right)) (e (drgnx-grid--edges two))
           (w (- (nth 2 e) (nth 0 e))) (h (- (nth 3 e) (nth 1 e)))
           (cx (/ (+ (nth 0 e) (nth 2 e)) 2)) (cy (/ (+ (nth 1 e) (nth 3 e)) 2)))
      (should (equal (drgnx-grid-drop-target nil (+ (nth 0 e) (/ w 10)) cy) (cons two 'left)))
      (should (equal (drgnx-grid-drop-target nil (- (nth 2 e) 1) cy) (cons two 'right)))
      (should (equal (drgnx-grid-drop-target nil cx (+ (nth 1 e) (/ h 10))) (cons two 'above)))
      (should (equal (drgnx-grid-drop-target nil cx (- (nth 3 e) 1)) (cons two 'below)))
      (should (equal (drgnx-grid-drop-target nil cx cy) (cons two 'center)))
      (let ((c (drgnx-grid-drag-test--centre one))) (should (eq (car (drgnx-grid-drop-target nil (car c) (cdr c))) one)))
      ;; past the frame: no tile
      (should-not (drgnx-grid-drop-target nil (+ (frame-pixel-width) 50) cy)))))

(ert-deftest drgnx-grid-drag/a-drop-nowhere-changes-nothing ()
  ;; on the tile itself, on no tile, where there is no room: nothing moves and the echo area says so
  (drgnx-grid-test--with
    (let* ((one (selected-window)) (two (drgnx-groups-split-right)) (before (drgnx-grid-test--edges)) said)
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
        (should-not (drgnx-grid--drop one one 'right))
        (should-not (drgnx-grid--drop one nil nil))
        (let ((drgnx-grid-min-columns 1000)) (should-not (drgnx-grid--drop one two 'right))))
      (should (equal (drgnx-grid-test--edges) before))
      (should (equal said '("Nothing moved" "Nothing moved" "Nothing moved"))))))

(ert-deftest drgnx-grid-drag/feedback-touches-only-the-target-tab-line ()
  (drgnx-grid-test--with
    (let* ((one (selected-window)) (two (drgnx-groups-split-right))
           (lines (lambda () (mapcar (lambda (w) (cons w (window-parameter w 'tab-line-format))) (window-list nil 'nomini))))
           (before (funcall lines)))
      (drgnx-pane-show 'g-term)
      (setq before (funcall lines))
      (drgnx-grid--drag-show two 'right)
      (let ((after (funcall lines)))
        (dolist (b before)
          (unless (eq (car b) two) (should (equal (cdr (assq (car b) after)) (cdr b)))))
        ;; the line is a plain string (`format-mode-line' gives \"\" in batch)
        (let ((s (window-parameter two 'tab-line-format)))
          (should (string-search "drop: split right" s))
          (should (memq 'drgnx-grid-drop (ensure-list (get-text-property (string-search "drop" s) 'face s))))))
      ;; another target: the first gets its line back
      (drgnx-grid--drag-show one 'center)
      (should (equal (window-parameter two 'tab-line-format) (cdr (assq two before))))
      (drgnx-grid--drag-clear)
      (should (equal (funcall lines) before)))))

(ert-deftest drgnx-grid-drag/a-chrome-redraw-during-a-drag-keeps-the-feedback ()
  ;; the chrome sets the tab line again whenever the hub, a theme or a size changes it (a slow start does it mid-drag):
  ;; the drop hint stays, and the line the chrome wanted is what comes back when the drag ends
  (drgnx-grid-test--with
    (let* ((two (drgnx-groups-split-right)))
      (drgnx-grid--drag-show two 'right)
      (drgnx-chrome--set two 'tab-line-format " chrome's new row ")
      (should (string-search "drop: split right" (window-parameter two 'tab-line-format)))
      (drgnx-grid--drag-clear)
      (should (equal (window-parameter two 'tab-line-format) " chrome's new row "))
      (set-window-parameter two 'tab-line-format nil))))

(ert-deftest drgnx-grid-drag/a-docked-area-says-it-on-its-header-line ()
  ;; a docked area's tab row is its header line (no tab line): the feedback goes there, and back after
  (drgnx-grid-test--with
    (let* ((two (drgnx-groups-split-right)) (row " Terminal  Output "))
      (set-window-parameter two 'tab-line-format 'none)
      (set-window-parameter two 'header-line-format row)
      (drgnx-grid--drag-show two 'below)
      (should (eq (window-parameter two 'tab-line-format) 'none))
      (should (string-search "drop: split down" (window-parameter two 'header-line-format)))
      (drgnx-grid--drag-clear)
      (should (eq (window-parameter two 'header-line-format) row))
      (set-window-parameter two 'header-line-format nil))))

(ert-deftest drgnx-grid-drag/esc-cancels ()
  ;; the pointer over the other tile's right edge, then Esc (and, again, C-g): no move, no feedback left
  (drgnx-grid-test--with
    (let* ((one (selected-window)) (two (drgnx-groups-split-right)) (e (drgnx-grid--edges two))
           (over (drgnx-grid-drag-test--posn two (- (nth 2 e) 2) (/ (+ (nth 1 e) (nth 3 e)) 2)))
           (before (drgnx-grid-test--edges)) (line (window-parameter two 'tab-line-format)))
      (dolist (key '(27 7))
        (drgnx-grid-drag-test--events (list (list 'mouse-movement over) key)
          (should-not (drgnx-grid--drag one)))
        (should (equal (drgnx-grid-test--edges) before))
        (should (equal (window-parameter two 'tab-line-format) line)))
      ;; and a release there moves it: the loop does drop
      (drgnx-grid-drag-test--events (list (list 'mouse-movement over) (list 'drag-mouse-1 over over))
        (should (drgnx-grid--drag one)))
      (should-not (equal (drgnx-grid-test--edges) before)))))

(ert-deftest drgnx-grid-drag/an-editor-tab-dragged-out-moves-only-that-file ()
  ;; an editor with tabs a and b: b's tab dropped on the other editor's right edge is a tile of its own there, and a
  ;; leaves; b's tab dropped on its own row's tile again is a click (b shows)
  (drgnx-grid-test--with
    (let* ((a (get-buffer-create "*g-a*")) (b (get-buffer-create "*g-b*"))
           (one (selected-window)) (two (drgnx-groups-split-right)) (e (drgnx-grid--edges two))
           (over (drgnx-grid-drag-test--posn two (- (nth 2 e) 2) (/ (+ (nth 1 e) (nth 3 e)) 2))))
      (set-window-buffer one a)
      (set-window-parameter one 'drgnx-tabs (list a b))
      (let* ((tab (drgnx-grid-drag-test--posn one (+ (nth 0 (window-pixel-edges one)) 2)
                                              (+ (nth 1 (window-pixel-edges one)) 2) 'tab-line))
             clicked)
        (drgnx-grid-drag-test--events (list (list 'mouse-1 tab))
          (drgnx-grid-tab-press (list 'down-mouse-1 tab) b (lambda (_) (setq clicked t))))
        (should clicked)
        (drgnx-grid-drag-test--events (list (list 'mouse-movement over) (list 'drag-mouse-1 tab over))
          (drgnx-grid-tab-press (list 'down-mouse-1 tab) b #'ignore)))
      (let ((moved (get-buffer-window b)))
        (should moved)
        (should-not (memq moved (list one two)))
        (should (= (nth 0 (window-pixel-edges moved)) (nth 2 (window-pixel-edges two))))
        (should (eq (window-buffer one) a))
        (should-not (memq b (window-parameter one 'drgnx-tabs)))))))

(ert-deftest drgnx-grid-drag/off-draws-no-grip-and-drags-nothing ()
  (drgnx-grid-test--with
    (drgnx-pane-show 'g-term)
    (let ((term (drgnx-pane-window 'g-term)))
      (should (string-search (drgnx-face-glyph 'grip-vertical) (drgnx-grid--tab-row term)))
      (let ((drgnx-grid-drag nil))
        (should-not (string-search (drgnx-face-glyph 'grip-vertical) (drgnx-grid--tab-row term)))
        (should-not (drgnx-grid-grip-press (list 'down-mouse-1 (drgnx-grid-drag-test--posn term 1 1 'tab-line))))))))

(provide 'grid-drag-test)
;;; grid-drag-test.el ends here
