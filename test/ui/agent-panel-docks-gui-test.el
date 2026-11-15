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

(ert-deftest drgnx-ui-panel-docks/the-transcript-keeps-its-end-in-view-with-no-panel-code ()
  "With point at the end, each appended step leaves the end in the window: Emacs scrolls it (the transcript's
`scroll-conservatively'), no code of the panel follows the tail."
  (drgnx-panel-docks-ui-test--with panel 40
    (should-not (fboundp 'drgnx-agent-panel--follow-tail))
    (should-not (fboundp 'drgnx-agent-panel--tail-start))
    (let ((w (selected-window)))
      (should (> (drgnx-panel-docks-ui-test--rows panel) (window-body-height w)))
      (set-window-point w (with-current-buffer panel (point-max)))
      (redisplay t)
      (drgnx-panel-docks-ui-test--stream)
      (dotimes (i 10)
        (drgnx-panel-docks-ui-test--appended panel 1 (format "appended row %d" (1+ i)))
        (should (= (window-point w) (with-current-buffer panel (point-max))))
        (should (pos-visible-in-window-p (with-current-buffer panel (point-max)) w))))))

(ert-deftest drgnx-ui-panel-docks/the-panel-opens-at-its-end ()
  "A panel shown with a transcript longer than its window opens at its end, with no one moving its point: the first
rows leave point at the end (`drgnx-view-sja-tail').  Red first: it opened on its first rows (the long scene's
l-dark-s2-a, window start 55)."
  (drgnx-panel-docks-ui-test--with panel 40
    (let ((w (selected-window)))
      (should (> (drgnx-panel-docks-ui-test--rows panel) (window-body-height w)))
      (should (= (window-point w) (with-current-buffer panel (point-max))))
      (should (pos-visible-in-window-p (with-current-buffer panel (point-max)) w))
      (should (> (window-start w) (with-current-buffer panel (point-min)))))))

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

;;; agent-panel-docks-gui-test.el ends here
