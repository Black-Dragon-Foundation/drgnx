;;; agent-panel-docks-gui-test.el --- GUI tests: the agent panel's windows (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; The agent panel is three windows of the right area: the header (the hub's view agent-panel-top/SESSION, fitted), the
;; transcript (agent-panel/SESSION, a Sjá view Emacs scrolls as any buffer) and the composer.  These rows run a real hub
;; and the mock agent (test/fixtures/panel-replay-fixture.el): the transcript keeps its end in view while the agent
;; streams with no panel code moving the window, and a window scrolled back stays on its row through appends and a
;; reset.  They need Nidhogg's Sjá (`nidhogg-view-rows') and a hub built with test hooks (DRGNX_RATATOSKR_BIN).

(require 'ert)
(require 'cl-lib)

(defconst drgnx-panel-docks-ui-test--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))

(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-panel-docks-ui-test--repo)))
(load (expand-file-name "test/fixtures/rows-demo-fixture" drgnx-panel-docks-ui-test--repo) nil t)

(defvar drgnx-panel-replay-prefix)
(defvar drgnx-panel-replay--mirror)
(declare-function drgnx-panel-replay-up "panel-replay-fixture" (bin &optional old))
(declare-function drgnx-panel-replay-down "panel-replay-fixture" ())
(declare-function drgnx-agents-send "drgnx-agents" (session text))

(defmacro drgnx-panel-docks-ui-test--with (panel prefix &rest body)
  "Run BODY with PANEL bound to the panel of a mock session whose first turn made PREFIX answers and reads, shown in
the frame's only window."
  (declare (indent 2))
  `(progn
     (skip-unless (and (display-graphic-p) (fboundp 'nidhogg-view-rows)))
     (load (expand-file-name "test/fixtures/panel-replay-fixture" drgnx-panel-docks-ui-test--repo) nil t)
     (let* ((load-path (cons (expand-file-name "modules/tools" drgnx-panel-docks-ui-test--repo) load-path))
            (drgnx-view-patch--buffers (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
            (drgnx-view-env--views (make-hash-table :test #'equal)) (drgnx-view-env--sent (make-hash-table :test #'equal))
            (drgnx-view-env--glyphs (make-hash-table :test #'equal)) (drgnx-view-env--hooked nil)
            (drgnx-panel-replay-prefix ,prefix) (,panel nil))
       (unwind-protect
           (save-window-excursion
             (delete-other-windows)
             (setq ,panel (drgnx-panel-replay-up (drgnx-rows-demo--bin)))
             (set-window-buffer (selected-window) ,panel)
             (drgnx-view-env-update (with-current-buffer ,panel (drgnx-view-patch-view drgnx-view-patch)))
             (drgnx-panel-docks-ui-test--settle ,panel)
             ,@body)
         (drgnx-panel-replay-down)
         (drgnx-view-env-teardown)
         (drgnx-view-patch-teardown)))))

(defun drgnx-panel-docks-ui-test--rows (panel)
  "The number of rows PANEL's Sjá view holds."
  (with-current-buffer panel (drgnx-view-row-count nil)))

(defun drgnx-panel-docks-ui-test--settle (panel)
  "Wait for PANEL's rows from the hub (none stale), draw them and redisplay."
  (drgnx-test-wait (lambda () (with-current-buffer panel
                                (and (> (drgnx-panel-docks-ui-test--rows panel) 2)
                                     (not (drgnx-view-patch-stale drgnx-view-patch)))))
                   :secs 30 :what "the hub's rows of the panel")
  (drgnx-rows-demo-settle panel)
  (with-current-buffer panel (drgnx-view-draw-now nil))
  (redisplay t))

(defun drgnx-panel-docks-ui-test--appended (panel n what)
  "Wait for N more rows in PANEL than it has now, then draw them and redisplay."
  (let ((want (+ n (drgnx-panel-docks-ui-test--rows panel))))
    (drgnx-test-wait (lambda () (>= (drgnx-panel-docks-ui-test--rows panel) want)) :secs 30 :what what)
    (with-current-buffer panel (drgnx-view-draw-now nil))
    (redisplay t)))

(defun drgnx-panel-docks-ui-test--start-is (panel window key what)
  "Fail unless the row at WINDOW's start in PANEL is KEY, naming WHAT and where the window and the rows are."
  (with-current-buffer panel
    (let ((got (drgnx-view-key-at (window-start window))))
      (unless (equal key got)
        (ert-fail (list what :want key :got got :start (window-start window) :point (window-point window)
                        :max (point-max) :rows (drgnx-view-row-count nil) :end (window-end window t)
                        :top (save-excursion (goto-char (point-min))
                                             (cl-loop repeat 4 until (eobp)
                                                      collect (prog1 (list (drgnx-view-key-at (point))
                                                                           (buffer-substring-no-properties
                                                                            (point) (min (pos-eol) (+ (point) 30))))
                                                                (forward-line 1))))))))))

(defun drgnx-panel-docks-ui-test--stream ()
  "The mock agent's second turn: the recording streams in, a read every tenth chunk."
  (drgnx-agents-send drgnx-panel-replay--mirror "stream"))

(ert-deftest drgnx-ui-panel-docks/the-transcript-is-a-sja-view-without-the-header ()
  "The panel's main buffer is the Sjá view of agent-panel/SESSION; the header's rows are another view's (the header
window's), so none of them is here."
  (drgnx-panel-docks-ui-test--with panel 3
    (with-current-buffer panel
      (should (drgnx-view-sja-p))
      (should (string-prefix-p "agent-panel/" (drgnx-view-patch-view drgnx-view-patch)))
      (should-not (drgnx-view-sja-row-start "p:head"))
      (should-not (drgnx-view-sja-row-start "p:strip"))
      (should-not (string-match-p "Open:" (buffer-string))))))

(ert-deftest drgnx-ui-panel-docks/a-window-scrolled-back-stays-on-its-row ()
  "A window scrolled up a page stays on the row at its start while steps are appended, and through a reset of the
rows (the text scale: a new display class)."
  (drgnx-panel-docks-ui-test--with panel 40
    (let ((w (selected-window)))
      (set-window-point w (with-current-buffer panel (point-max)))
      (redisplay t)
      ;; back half a window, off the top, with point on the top line, as a reader who scrolled back and clicked there:
      ;; a point at the bottom line would have Emacs scroll to keep it in view once the rows grow (a bigger font)
      (with-selected-window w
        (scroll-down (/ (window-body-height) 2))
        (redisplay t)
        (move-to-window-line 0))
      (redisplay t)
      (let ((key (with-current-buffer panel (drgnx-view-key-at (window-start w)))))
        (should key)
        (should (> (window-start w) (with-current-buffer panel (point-min))))
        (should-not (= (window-point w) (with-current-buffer panel (point-max))))
        (drgnx-panel-docks-ui-test--stream)
        (dotimes (i 10)
          (drgnx-panel-docks-ui-test--appended panel 1 (format "appended row %d" (1+ i)))
          (drgnx-panel-docks-ui-test--start-is panel w key (list :after-append (1+ i))))
        (unwind-protect
            (let ((class (with-current-buffer panel (drgnx-view-patch-class drgnx-view-patch))))
              (with-current-buffer panel (text-scale-increase 1))
              ;; the agent still streams: the reset is done when the new class's rows are in, not when the hub is quiet
              (drgnx-test-wait (lambda () (with-current-buffer panel
                                            (let ((s drgnx-view-patch))
                                              (and (not (equal class (drgnx-view-patch-class s)))
                                                   (not (drgnx-view-patch-stale s)) (not (drgnx-view-patch-resync s))
                                                   (> (drgnx-view-row-count nil) 2)))))
                               :secs 30 :what "the rows of the scaled class")
              (with-current-buffer panel (drgnx-view-draw-now nil))
              (redisplay t)
              (drgnx-panel-docks-ui-test--start-is panel w key :after-reset))
          (with-current-buffer panel (text-scale-set 0)))))))

;;;; The three windows through a resize: the header, the transcript and the composer of the right area, on a frame
;;;; out of fullscreen (a fullscreen frame keeps its output's size).  Every size is checked to have taken
;;;; (`drgnx-test-frame-text-size'): a resize that did not take fails the row.

(defmacro drgnx-panel-docks-ui-test--opened (vars prefix &rest body)
  "Run BODY with VARS, a list (PANEL HEADER TRANSCRIPT COMPOSER), bound to a mock session's panel whose first turn made
PREFIX answers and reads, opened in the right area by its command path, and its three windows, once the header holds
its rows and the companions are fitted; the root frame out of fullscreen, 100 px smaller than its fullscreen size each
way.  No window's point is moved: the transcript is as the panel opened it.  The editor's window is selected, so the
settle's C-l recenters it, never the transcript.  The frame's size and fullscreen state are put back after."
  (declare (indent 2))
  (pcase-let ((`(,panel ,hw ,tw ,cw) vars))
    `(progn
       (skip-unless (and (display-graphic-p) (fboundp 'nidhogg-view-rows)))
       (load (expand-file-name "test/fixtures/panel-replay-fixture" drgnx-panel-docks-ui-test--repo) nil t)
       (let* ((load-path (cons (expand-file-name "modules/tools" drgnx-panel-docks-ui-test--repo) load-path))
              (drgnx-view-patch--buffers (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
              (drgnx-view-env--views (make-hash-table :test #'equal)) (drgnx-view-env--sent (make-hash-table :test #'equal))
              (drgnx-view-env--glyphs (make-hash-table :test #'equal)) (drgnx-view-env--hooked nil)
              (drgnx-panel-replay-prefix ,prefix) (,panel nil)
              (root (drgnx-uitest-root-frame)) (full (frame-parameter root 'fullscreen)) (size nil))
         (unwind-protect
             (save-window-excursion
               ;; out of fullscreen the compositor gives the frame a small default size: the fullscreen one less 100 px
               (setq size (list (frame-text-width root) (frame-text-height root))
                     full (drgnx-test-frame-fullscreen root nil))
               (drgnx-test-frame-text-size root (- (car size) 100) (- (cadr size) 100))
               (delete-other-windows)
               (setq ,panel (drgnx-panel-replay-up (drgnx-rows-demo--bin)))
               (let* ((,tw (get-buffer-window ,panel)) (area (window-parameter ,tw 'drgnx-role)) ,hw ,cw)
                 (should area)
                 (select-window (or (seq-find (lambda (w) (not (window-parameter w 'drgnx-role))) (window-list nil 'nomini))
                                    (error "No editor window beside the panel")))
                 (drgnx-panel-docks-ui-test--settle ,panel)
                 (setq ,hw (drgnx-panel-docks-ui-test--part area 'above) ,cw (drgnx-panel-docks-ui-test--part area 'below))
                 (should (window-live-p ,hw))
                 (should (window-live-p ,cw))
                 ;; the header's rows come from another view, later than the transcript's: its fit then changes the
                 ;; transcript's height
                 (drgnx-test-wait (lambda () (with-current-buffer (window-buffer ,hw) (drgnx-view-sja-row-start "p:head")))
                                  :secs 30 :what "the header's rows")
                 (drgnx-panel-docks-ui-test--settle-area)
                 ,@body))
           (drgnx-panel-replay-down)
           (drgnx-view-env-teardown)
           (drgnx-view-patch-teardown)
           (when size (set-frame-size root (car size) (cadr size) t))
           (drgnx-test-frame-fullscreen root full))))))

(defmacro drgnx-panel-docks-ui-test--in-area (vars prefix &rest body)
  "Run BODY with VARS, a list (PANEL HEADER TRANSCRIPT COMPOSER), bound to a mock session's panel whose first turn made
PREFIX answers and reads, open in the right area, and its three windows; the root frame out of fullscreen, 100 px
smaller than its fullscreen size each way, with point at the transcript's end.  The frame's size and fullscreen state are put back after."
  (declare (indent 2))
  (pcase-let ((`(,panel ,hw ,tw ,cw) vars))
    `(progn
       (skip-unless (and (display-graphic-p) (fboundp 'nidhogg-view-rows)))
       (load (expand-file-name "test/fixtures/panel-replay-fixture" drgnx-panel-docks-ui-test--repo) nil t)
       (let* ((load-path (cons (expand-file-name "modules/tools" drgnx-panel-docks-ui-test--repo) load-path))
              (drgnx-view-patch--buffers (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
              (drgnx-view-env--views (make-hash-table :test #'equal)) (drgnx-view-env--sent (make-hash-table :test #'equal))
              (drgnx-view-env--glyphs (make-hash-table :test #'equal)) (drgnx-view-env--hooked nil)
              (drgnx-panel-replay-prefix ,prefix) (,panel nil)
              (root (drgnx-uitest-root-frame)) (full (frame-parameter root 'fullscreen)) (size nil))
         (unwind-protect
             (save-window-excursion
               ;; out of fullscreen the compositor gives the frame a small default size: the fullscreen one less 100 px
               (setq size (list (frame-text-width root) (frame-text-height root))
                     full (drgnx-test-frame-fullscreen root nil))
               (drgnx-test-frame-text-size root (- (car size) 100) (- (cadr size) 100))
               (delete-other-windows)
               (setq ,panel (drgnx-panel-replay-up (drgnx-rows-demo--bin)))
               (let* ((,tw (get-buffer-window ,panel)) (area (window-parameter ,tw 'drgnx-role)) ,hw ,cw)
                 (should area)
                 ;; the editor's window selected before any settle: the settle's C-l recenters it, never the
                 ;; transcript (a recentred transcript has its end mid-window with point still in view)
                 (select-window (or (seq-find (lambda (w) (not (window-parameter w 'drgnx-role))) (window-list nil 'nomini))
                                    (error "No editor window beside the panel")))
                 (drgnx-panel-docks-ui-test--settle ,panel)
                 (drgnx-panel-docks-ui-test--settle-area)
                 (setq ,hw (drgnx-panel-docks-ui-test--part area 'above) ,cw (drgnx-panel-docks-ui-test--part area 'below))
                 (should (window-live-p ,hw))
                 (should (window-live-p ,cw))
                 (with-current-buffer ,panel (goto-char (point-max)))
                 (set-window-point ,tw (with-current-buffer ,panel (point-max)))
                 (drgnx-panel-docks-ui-test--settle-area)
                 ,@body))
           (drgnx-panel-replay-down)
           (drgnx-view-env-teardown)
           (drgnx-view-patch-teardown)
           (when size (set-frame-size root (car size) (cadr size) t))
           (drgnx-test-frame-fullscreen root full))))))

(defun drgnx-panel-docks-ui-test--part (area part)
  "AREA's window that is its PART (`above', `below'), or nil."
  (seq-find (lambda (w) (and (eq area (window-parameter w 'drgnx-role)) (eq part (window-parameter w 'drgnx-area-part))))
            (window-list nil 'nomini)))

(defun drgnx-panel-docks-ui-test--settle-area ()
  "Let redisplay, the size-change functions and the store's idle calls run until the area's companions stop moving (at
most 5 rounds)."
  (let ((edges nil) (n 0))
    (while (and (< n 5)
                (not (equal edges (setq edges (mapcar #'window-pixel-edges
                                                      (seq-filter (lambda (w) (window-parameter w 'drgnx-area-part))
                                                                  (window-list nil 'nomini)))))))
      (setq n (1+ n))
      (drgnx-uitest-run (drgnx-uitest-key-events "C-l"))
      (drgnx-test-wait-presented))))

(defun drgnx-panel-docks-ui-test--fit (window)
  "WINDOW against its buffer: (:start-at-top :vscroll :body :text), the body and its text in pixels."
  (let ((b (window-buffer window)))
    (list :start-at-top (= (window-start window) (with-current-buffer b (point-min)))
          :vscroll (window-vscroll window t)
          :body (window-body-height window t)
          :text (cdr (window-text-pixel-size window (with-current-buffer b (point-min))
                                             (with-current-buffer b (point-max)))))))

(defun drgnx-panel-docks-ui-test--fitted-p (window)
  "Whether WINDOW starts at its buffer's top, unscrolled, its body its text's height (within a pixel)."
  (let ((f (drgnx-panel-docks-ui-test--fit window)))
    (and (plist-get f :start-at-top) (= 0 (plist-get f :vscroll))
         (<= (abs (- (plist-get f :body) (plist-get f :text))) 1))))

(defun drgnx-panel-docks-ui-test--above-start (window)
  "The pixel height of the screen line before WINDOW's start: what one more row at its top would take."
  (let* ((start (window-start window))
         (prev (with-selected-window window (save-excursion (goto-char start) (vertical-motion -1) (point)))))
    (if (< prev start) (cdr (window-text-pixel-size window prev start)) 0)))

(defun drgnx-panel-docks-ui-test--row-bottom (window y)
  "The bottom edge, in pixels from the top of WINDOW's text, of the screen line redisplay drew at Y in WINDOW (its
height as drawn: a card or an image counted); Y and a default line when redisplay's rows don't tell."
  (let ((n 0) r bottom)
    (while (and (not bottom) (setq r (window-line-height n window)))
      (when (and (<= (nth 2 r) y) (< y (+ (nth 2 r) (car r)))) (setq bottom (+ (nth 2 r) (car r))))
      (setq n (1+ n)))
    (or bottom (+ y (window-default-line-height window)))))

(defun drgnx-panel-docks-ui-test--end-error (panel window)
  "Nil when WINDOW, point at PANEL's end, shows the end whole at its bottom (or the whole transcript, when it fits);
else where the end is.  Emacs scrolls by whole rows: under the end's row (its bottom as redisplay drew it, a card or
an image included) there is less space than the screen line before the start would take, else the window could show
one more row and has blank space."
  (redisplay t)
  (let* ((end (with-current-buffer panel (point-max)))
         (at (pos-visible-in-window-p end window t))
         (body (window-body-height window t))
         (bottom (and at (drgnx-panel-docks-ui-test--row-bottom window (cadr at))))
         (above (and at (> (window-start window) (with-current-buffer panel (point-min)))
                     (drgnx-panel-docks-ui-test--above-start window))))
    (cond ((or (not at) (nth 2 at))
           (list :end-not-shown-whole :at at :body body :start (window-start window)))
          ((and above (>= (- body bottom) above))
           (list :end-not-at-bottom :y (cadr at) :bottom bottom :body body :above above
                 :start (window-start window)
                 :point (window-point window) :max end)))))

(ert-deftest drgnx-ui-panel-docks/through-a-resize-the-end-stays-and-the-docks-fit ()
  "The frame shrunk by 250 px and grown back: after each, the transcript with point at its end shows the end at its
bottom, and the header and the composer are fitted to their text."
  (drgnx-panel-docks-ui-test--in-area (panel hw tw cw) 20
    (let* ((root (window-frame tw)) (size (list (frame-text-width root) (frame-text-height root))))
      (should (> (with-current-buffer panel (- (point-max) (window-start tw))) 0))
      (dolist (step (list (list :shrunk (- (cadr size) 250)) (list :back (cadr size))))
        (drgnx-test-frame-text-size root (car size) (cadr step))
        (drgnx-panel-docks-ui-test--settle-area)
        (should (equal (list (car step) nil t t)
                       (list (car step) (drgnx-panel-docks-ui-test--end-error panel tw)
                             (drgnx-panel-docks-ui-test--fitted-p hw) (drgnx-panel-docks-ui-test--fitted-p cw))))))))

(ert-deftest drgnx-ui-panel-docks/a-short-frame-keeps-the-header-and-the-end ()
  "The frame shrunk until the transcript is two lines tall, or as short as its windows let it be (a window is at least
`window-min-height' lines; the area: the header, the transcript and the composer): the transcript, point at its end,
still shows its end, and the header still holds `p:head', fitted."
  (drgnx-panel-docks-ui-test--in-area (panel hw tw _cw) 20
    (let* ((root (window-frame tw)) (line (window-default-line-height tw))
           (chrome (- (window-pixel-height tw) (window-body-height tw t)))
           ;; the transcript's body: two lines, or its least
           (want (max (* 2 line) (- (window-min-size tw nil nil t) chrome)))
           ;; the frame: shorter by what the transcript gives up, never under its windows' least (and the echo area's)
           (least (+ (window-min-size (frame-root-window root) nil nil t)
                     (- (frame-text-height root) (window-pixel-height (frame-root-window root)))))
           (height (max least (- (frame-text-height root) (- (window-body-height tw t) want)))))
      (drgnx-test-frame-text-size root (frame-text-width root) height)
      (drgnx-panel-docks-ui-test--settle-area)
      (should (<= (window-body-height tw t) (+ want line)))
      (should (pos-visible-in-window-p (with-current-buffer panel (point-max)) tw))
      (should (with-current-buffer (window-buffer hw) (drgnx-view-sja-row-start "p:head")))
      (should (drgnx-panel-docks-ui-test--fitted-p hw)))))

;;;; The end at the bottom when the transcript's window grows: at open (the header's rows come after the transcript's),
;;;; when the composer shrinks after a send, when the header's strip unwraps, and when a tab switch brings the panel
;;;; back.  Emacs scrolls a window whose point leaves it; a window that grows keeps its start, so only Sjá's tail
;;;; anchor (`drgnx-view-sja-tail') puts the end back on the last line.

(defun drgnx-panel-docks-ui-test--long-p (panel window)
  "Whether PANEL's transcript is taller than WINDOW's body: the end at the bottom is then a scrolled window's."
  (> (cdr (window-text-pixel-size window (with-current-buffer panel (point-min)) (with-current-buffer panel (point-max))))
     (window-body-height window t)))

(defun drgnx-panel-docks-ui-test--at-end (panel window what)
  "Fail unless WINDOW's point is PANEL's end and the end is at its bottom, naming WHAT."
  (should (equal (list what t nil)
                 (list what (= (window-point window) (with-current-buffer panel (point-max)))
                       (drgnx-panel-docks-ui-test--end-error panel window)))))

(defun drgnx-panel-docks-ui-test--steps (panel n what)
  "Wait for N draws of PANEL that changed its text, one after another, drawing them as they come: the agent's steps.
Neither the row count nor the buffer's size need grow (the transcript keeps a page of rows: a new one can drop the
oldest; the hub groups reads into one row)."
  (dotimes (i n)
    (let ((was (with-current-buffer panel (buffer-chars-modified-tick))))
      (drgnx-test-wait (lambda () (with-current-buffer panel
                                    (drgnx-view-draw-now nil)
                                    (/= was (buffer-chars-modified-tick))))
                       :secs 30 :what (list what (1+ i)))))
  (redisplay t))

(ert-deftest drgnx-ui-panel-docks/the-panel-opens-at-its-end ()
  "A panel opened in the right area by its command path with a transcript longer than its window opens at its end,
the end on the transcript's last line, after the header's rows came and the header was fitted.  No one moves its point
\(the first rows leave it at the end, `drgnx-view-sja-tail'); the header's fit grows or shrinks the transcript after it
followed its end.  Red first: opened on its first rows (447087a75); then blank space under the end (the header fitted
from its split height once its rows came, the transcript grown with its start kept)."
  (drgnx-panel-docks-ui-test--opened (panel _hw tw _cw) 40
    (should (drgnx-panel-docks-ui-test--long-p panel tw))
    (drgnx-panel-docks-ui-test--at-end panel tw :opened)))

(ert-deftest drgnx-ui-panel-docks/the-transcript-keeps-its-end-in-view-with-no-panel-code ()
  "In the right area with point at the end, each appended step leaves the end at the transcript's bottom: Emacs
scrolls it (the transcript's `scroll-conservatively'), no code of the panel follows the tail; the header refitting
meanwhile (its status) must not leave space under the end."
  (drgnx-panel-docks-ui-test--in-area (panel _hw tw _cw) 40
    (should-not (fboundp 'drgnx-agent-panel--follow-tail))
    (should-not (fboundp 'drgnx-agent-panel--tail-start))
    (should (drgnx-panel-docks-ui-test--long-p panel tw))
    (drgnx-panel-docks-ui-test--stream)
    (dotimes (i 10)
      (drgnx-panel-docks-ui-test--steps panel 1 (list :append (1+ i)))
      (drgnx-panel-docks-ui-test--settle-area)
      (drgnx-panel-docks-ui-test--at-end panel tw (list :after-append (1+ i))))))

(declare-function drgnx-agent-panel-send "drgnx-agent-panel-composer" ())

(ert-deftest drgnx-ui-panel-docks/the-end-stays-when-the-composer-shrinks-after-a-send ()
  "A five-line draft grows the composer and shrinks the transcript (Emacs scrolls: point would leave it); the send
empties the draft, the composer shrinks back and the transcript grows: its end stays on its last line.  The hub's send
is recorded, not made (the mock's script has no third turn)."
  (drgnx-panel-docks-ui-test--in-area (panel _hw tw cw) 40
    (should (drgnx-panel-docks-ui-test--long-p panel tw))
    (let ((comp (window-buffer cw)) (h (window-pixel-height cw)) (sent nil))
      (with-current-buffer comp (goto-char (point-min)) (insert "one\ntwo\nthree\nfour\nfive"))
      (drgnx-panel-docks-ui-test--settle-area)
      (should (> (window-pixel-height cw) h))
      (drgnx-panel-docks-ui-test--at-end panel tw :draft)
      (cl-letf (((symbol-function 'drgnx-agent-panel-composer--send-text) (lambda (text) (push text sent))))
        (with-current-buffer comp (drgnx-agent-panel-send)))
      (should (equal '("one\ntwo\nthree\nfour\nfive") sent))
      (drgnx-panel-docks-ui-test--settle-area)
      (should (= (window-pixel-height cw) h))
      (drgnx-panel-docks-ui-test--at-end panel tw :sent))))

(ert-deftest drgnx-ui-panel-docks/the-end-stays-when-the-header-strip-unwraps ()
  "A bigger font in the header wraps its strip: the header grows, the transcript shrinks; back to the font, the strip
unwraps, the header shrinks and the transcript grows: its end stays on its last line."
  (drgnx-panel-docks-ui-test--in-area (panel hw tw _cw) 40
    (should (drgnx-panel-docks-ui-test--long-p panel tw))
    (let* ((hb (window-buffer hw)) (h (window-pixel-height hw))
           (class (with-current-buffer hb (drgnx-view-patch-class drgnx-view-patch)))
           (rows-of (lambda (want what)
                      (drgnx-test-wait (lambda () (with-current-buffer hb
                                                    (and (funcall want (drgnx-view-patch-class drgnx-view-patch))
                                                         (not (drgnx-view-patch-stale drgnx-view-patch))
                                                         (drgnx-view-sja-row-start "p:head"))))
                                       :secs 20 :what what)
                      (with-current-buffer hb (drgnx-view-draw-now nil))
                      (drgnx-panel-docks-ui-test--settle-area))))
      (unwind-protect
          (progn
            (with-current-buffer hb (text-scale-increase 3))
            (funcall rows-of (lambda (c) (not (equal c class))) "the header's rows at the bigger font")
            (should (> (window-pixel-height hw) h))
            (drgnx-panel-docks-ui-test--at-end panel tw :wrapped))
        (with-current-buffer hb (text-scale-set 0)))
      (funcall rows-of (lambda (c) (equal c class)) "the header's rows at the font again")
      (should (< (abs (- (window-pixel-height hw) h)) 2))
      (drgnx-panel-docks-ui-test--at-end panel tw :unwrapped))))

(declare-function drgnx-pane-show "drgnx-panes" (kind &rest args))
(declare-function drgnx-wb-define-tab "drgnx-area" (area tab &rest keys))
(declare-function drgnx-wb-undefine-tab "drgnx-area" (area tab))
(declare-function drgnx-wb-area-show "drgnx-area" (area &optional tab buffer))

(ert-deftest drgnx-ui-panel-docks/a-tab-switch-back-at-the-end-lands-on-the-new-end ()
  "The transcript at its end, the right area switched to another tab while the agent appends 5 steps, and back: the
transcript's point is the new end and the end is on its last line (Acceptance 2: at its end it follows).  Red first:
the tab came back on the old end's position, which no longer follows."
  (drgnx-panel-docks-ui-test--in-area (panel _hw tw _cw) 40
    (let ((other (get-buffer-create "*drgnx panel-docks other*")))
      (unwind-protect
          (progn
            (drgnx-wb-define-tab 'right 'panel-docks-other :title "Other")
            (drgnx-panel-docks-ui-test--at-end panel tw :before)
            (drgnx-wb-area-show 'right 'panel-docks-other other)
            (drgnx-panel-docks-ui-test--settle-area)
            (should-not (get-buffer-window panel))
            (let ((was (with-current-buffer panel (point-max))))
              (drgnx-panel-docks-ui-test--stream)
              (drgnx-panel-docks-ui-test--steps panel 5 "a step appended while the panel is hidden")
              ;; the end moved: the point the tab left at the old end is no longer the end
              (should (/= (with-current-buffer panel (point-max)) was)))
            (drgnx-pane-show 'agent-panel)
            (drgnx-panel-docks-ui-test--settle-area)
            (let ((tw2 (get-buffer-window panel)))
              (should (window-live-p tw2))
              (drgnx-panel-docks-ui-test--at-end panel tw2 :back)))
        (drgnx-wb-undefine-tab 'right 'panel-docks-other)
        (kill-buffer other)))))

;;; agent-panel-docks-gui-test.el ends here
