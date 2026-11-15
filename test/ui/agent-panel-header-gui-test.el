;;; agent-panel-header-gui-test.el --- GUI tests: the agent panel's header window (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; A real hub and a mock agent (test/fixtures/panel-replay-fixture.el) and the panel open in the right area.  The
;; header is the area's window above the transcript: the hub's view agent-panel-top/SESSION (the header row, the chips
;; and the strip) in a Sjá buffer of its own, fitted to its rows and carrying the area's tab row.  Scrolling the
;; transcript never moves it; its lens, pin and pills run on the session's state; a strip that wraps refits it.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-panel-header--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-panel-header--repo)))
(require 'drgnx-keys)
(load (expand-file-name "test/fixtures/rows-demo-fixture" drgnx-ui-panel-header--repo) nil t)

(defvar drgnx-panel-replay-prefix)
(defvar drgnx-view-patch--buffers)
(defvar drgnx-view-patch--hooked)
(defvar drgnx-view-env--views)
(defvar drgnx-view-env--sent)
(defvar drgnx-view-env--glyphs)
(defvar drgnx-view-env--hooked)
(defvar drgnx-agent-panel--session)
(defvar drgnx-agent-panel--disclosure)
(defvar drgnx-agent-panel--pins)
(declare-function drgnx-panel-replay-up "panel-replay-fixture" (bin &optional old))
(declare-function drgnx-panel-replay-down "panel-replay-fixture" ())
(declare-function drgnx-rows-demo--bin "rows-demo-fixture" ())
(declare-function drgnx-view-env-teardown "drgnx-view-env" ())
(declare-function drgnx-view-patch-teardown "drgnx-view" ())
(declare-function drgnx-view-row-count "drgnx-view" (view))
(declare-function drgnx-view-key-at "drgnx-view" (&optional pos))
(declare-function drgnx-view-sja-p "drgnx-view-sja" (&optional buffer))
(declare-function drgnx-area--tab-row "drgnx-area" (area))
(declare-function drgnx-keys-use "drgnx-keys" (layers &optional save))
(declare-function drgnx-keys--restore "drgnx-keys" ())

(defvar drgnx-ui-panel-header--prefix 3 "The mock turn's answers and reads at once (`drgnx-panel-replay-prefix').")

(defmacro drgnx-ui-panel-header--with (vars &rest body)
  "Run BODY with VARS, a list (PANEL HEADER-WINDOW TRANSCRIPT-WINDOW AREA), bound for a mock session's panel open in
the right area, its header's rows in."
  (declare (indent 1))
  (pcase-let ((`(,panel ,hw ,tw ,area) vars))
    `(progn
       (skip-unless (and (display-graphic-p) (fboundp 'nidhogg-view-rows)))
       (load (expand-file-name "test/fixtures/panel-replay-fixture" drgnx-ui-panel-header--repo) nil t)
       (let* ((load-path (cons (expand-file-name "modules/tools" drgnx-ui-panel-header--repo) load-path))
              (drgnx-view-patch--buffers (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
              (drgnx-view-env--views (make-hash-table :test #'equal)) (drgnx-view-env--sent (make-hash-table :test #'equal))
              (drgnx-view-env--glyphs (make-hash-table :test #'equal)) (drgnx-view-env--hooked nil)
              (drgnx-panel-replay-prefix drgnx-ui-panel-header--prefix) (,panel nil))
         (unwind-protect
             (save-window-excursion
               (setq ,panel (drgnx-panel-replay-up (drgnx-rows-demo--bin)))
               (let* ((,tw (get-buffer-window ,panel)) (,area (window-parameter ,tw 'drgnx-role)) (,hw nil))
                 (drgnx-ui-panel-header--settle ,area)
                 (setq ,hw (drgnx-ui-panel-header--part ,area 'above))
                 (should (window-live-p ,hw))
                 (drgnx-ui-panel-header--rows-in (window-buffer ,hw))
                 (drgnx-ui-panel-header--settle ,area)
                 ,@body))
           (drgnx-panel-replay-down)
           (drgnx-view-env-teardown)
           (drgnx-view-patch-teardown))))))

(defun drgnx-ui-panel-header--part (area part)
  "AREA's window that is its PART (`above', `below'), or nil."
  (seq-find (lambda (w) (and (eq area (window-parameter w 'drgnx-role)) (eq part (window-parameter w 'drgnx-area-part))))
            (window-list nil 'nomini)))

(defun drgnx-ui-panel-header--settle (area)
  "Let redisplay, the size-change functions and the store's idle calls run until AREA's companions stop moving (at
most 5 rounds)."
  (let ((edges nil) (n 0))
    (while (and (< n 5)
                (not (equal edges (setq edges (mapcar #'window-pixel-edges
                                                      (seq-filter (lambda (w) (and (eq area (window-parameter w 'drgnx-role))
                                                                                   (window-parameter w 'drgnx-area-part)))
                                                                  (window-list nil 'nomini)))))))
      (setq n (1+ n))
      (drgnx-uitest-run (drgnx-uitest-key-events "C-l"))
      (drgnx-test-wait-presented))))

(defun drgnx-ui-panel-header--rows-in (buffer)
  "Wait for BUFFER's rows from the hub (the header row among them, none stale) and draw them."
  (drgnx-test-wait (lambda () (with-current-buffer buffer
                                (and (> (drgnx-view-row-count nil) 0)
                                     (not (drgnx-view-patch-stale drgnx-view-patch))
                                     (drgnx-ui-panel-header--keys buffer))))
                   :secs 20 :what "the header's rows from the hub")
  (with-current-buffer buffer (drgnx-view-draw-now nil)))

(defun drgnx-ui-panel-header--keys (buffer)
  "BUFFER's row keys, top to bottom, a key once."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let (keys)
        (while (not (eobp))
          (let ((k (drgnx-view-key-at (point)))) (unless (or (null k) (equal k (car keys))) (push k keys)))
          (forward-line 1))
        (nreverse keys)))))

(defun drgnx-ui-panel-header--fit (w)
  "Window W's body height against its text's pixel height: (BODY TEXT)."
  (list (window-body-height w t)
        (cdr (window-text-pixel-size w (with-current-buffer (window-buffer w) (point-min))
                                     (with-current-buffer (window-buffer w) (point-max))))))

(defun drgnx-ui-panel-header--fitted-p (w)
  "Whether W's body is its text's height, to a pixel."
  (pcase-let ((`(,body ,text) (drgnx-ui-panel-header--fit w))) (<= (abs (- body text)) 1)))

(defun drgnx-ui-panel-header--facts (w area)
  "W's fit in AREA as a plist, for `drgnx-ui-panel-header--fitted-or-capped-p' (and the failure's report): BODY and
TEXT (`drgnx-ui-panel-header--fit'), its PIXEL height, its default LINE height, the CAP (the most of the area's
height a companion is fitted to: the plan's 45%, not read from the product, so a wrong cap there fails) and whether its
START is its buffer's start."
  (pcase-let ((`(,body ,text) (drgnx-ui-panel-header--fit w))
              (total (apply #'+ (mapcar #'window-pixel-height
                                        (seq-filter (lambda (x) (eq area (window-parameter x 'drgnx-role)))
                                                    (window-list (window-frame w) 'nomini))))))
    (list :body body :text text :pixel (window-pixel-height w) :line (window-default-line-height w)
          :cap (* 0.45 total)
          :start (= (window-start w) (with-current-buffer (window-buffer w) (point-min))))))

(defun drgnx-ui-panel-header--fitted-or-capped-p (facts)
  "Whether FACTS (`drgnx-ui-panel-header--facts') are a window no taller than the cap (to a pixel's rounding) and
either fitted to its text to a pixel, or with text taller than the cap and at the cap (another line would pass it),
its first row at its start."
  (let ((body (plist-get facts :body)) (text (plist-get facts :text)))
    (and (<= (plist-get facts :pixel) (1+ (plist-get facts :cap)))
         (or (<= (abs (- body text)) 1)
             (and (> text body)
                  (> (+ (plist-get facts :pixel) (plist-get facts :line)) (plist-get facts :cap))
                  (plist-get facts :start))))))

(defun drgnx-ui-panel-header--longer-p (window)
  "Whether WINDOW's buffer's text is taller than its body (the transcript is longer than its window, wherever it is
scrolled to: it opens at its end)."
  (let ((body (window-body-height window t)))
    (> (cdr (with-current-buffer (window-buffer window)
              (window-text-pixel-size window (point-min) (point-max) nil (1+ body))))
       body)))

(defun drgnx-ui-panel-header--entry-pos (panel window &optional n)
  "The position in WINDOW, which shows PANEL, of the Nth (from 0, default 0) step's row (`drgnx-agent-panel-entry')
from its start, or nil."
  (with-current-buffer panel
    (let ((pos (window-start window)) (end (min (point-max) (or (window-end window t) (point-max))))
          (n (or n 0)) (found nil))
      (while (and pos (< pos end) (not found))
        (if (and (get-text-property pos 'drgnx-agent-panel-entry) (< (cl-decf n) 0))
            (setq found pos)
          (setq pos (next-single-property-change pos 'drgnx-agent-panel-entry nil end))))
      found)))

(defun drgnx-ui-panel-header--preset-differs-p (n panel)
  "Whether the lens's preset N is not PANEL's disclosure now (so a click on it shows a change)."
  (not (equal (sort (mapcar #'symbol-name (cdr (nth (1- n) (symbol-value 'drgnx-agent-panel-presets)))) #'string<)
              (sort (mapcar #'symbol-name (buffer-local-value 'drgnx-agent-panel--disclosure panel)) #'string<))))

(defun drgnx-ui-panel-header--target (window pred)
  "The first posn in WINDOW over text whose `drgnx-agent-panel-action' satisfies PRED, found as a pointer would."
  (catch 'found
    (cl-loop for y from 2 below (window-body-height window t) by 3
             do (cl-loop for x from 4 below (window-body-width window t) by 4
                         do (let* ((p (posn-at-x-y x y window)) (pos (posn-point p)))
                              (when (and pos (eq window (posn-window p))
                                         (funcall pred (get-text-property pos 'drgnx-agent-panel-action
                                                                          (window-buffer window))))
                                (throw 'found p)))))
    nil))

(ert-deftest drgnx-ui-panel-header/a-window-above-the-transcript-holds-the-hubs-top-rows-fitted ()
  (drgnx-ui-panel-header--with (panel hw tw area)
    (let ((hb (window-buffer hw)) (sid (buffer-local-value 'drgnx-agent-panel--session panel)))
      ;; the area's window right above the transcript, its width
      (should (eq area (window-parameter hw 'drgnx-role)))
      (should (= (nth 3 (window-pixel-edges hw)) (nth 1 (window-pixel-edges tw))))
      (should (= (window-pixel-width hw) (window-pixel-width tw)))
      ;; the hub's top view in Sjá: the header row first, then the strip; the transcript holds neither
      (should (drgnx-view-sja-p hb))
      (should (equal (concat "agent-panel-top/" sid) (drgnx-view-patch-view (buffer-local-value 'drgnx-view-patch hb))))
      (let ((keys (drgnx-ui-panel-header--keys hb)))
        (should (equal "p:head" (car keys)))
        (should (member "p:strip" keys)))
      (should-not (member "p:head" (drgnx-ui-panel-header--keys panel)))
      ;; fitted to its rows; the tab row is its header line, and the transcript has none
      (should (drgnx-ui-panel-header--fitted-p hw))
      (should (equal (drgnx-area--tab-row area) (window-parameter hw 'header-line-format)))
      (should (eq 'none (window-parameter tw 'header-line-format))))))

(ert-deftest drgnx-ui-panel-header/scrolling-the-transcript-never-moves-the-header ()
  (drgnx-ui-panel-header--with (panel hw tw area)
    (let* ((hb (window-buffer hw)) (text (with-current-buffer hb (buffer-string)))
           (top (nth 1 (window-pixel-edges hw))))
      (with-selected-window tw
        (goto-char (point-min))
        (set-window-start tw (point-min))
        (redisplay t)
        (goto-char (point-max))
        (recenter -1)
        (redisplay t))
      (drgnx-ui-panel-header--settle area)
      (should (= (window-start hw) (with-current-buffer hb (point-min))))
      (should (= top (nth 1 (window-pixel-edges hw))))
      (should (equal text (with-current-buffer hb (buffer-string))))
      (should (drgnx-ui-panel-header--fitted-p hw)))))

(ert-deftest drgnx-ui-panel-header/its-pin-lens-and-pills-run-on-the-sessions-state ()
  (drgnx-ui-panel-header--with (panel hw tw area)
    (drgnx-keys-use '((vscode app editing window)))   ; the profile binds mouse-1 to the panel's dispatcher
    (unwind-protect
        (let ((pin (drgnx-ui-panel-header--target hw (lambda (a) (equal a "pin")))))
          (should pin)
          ;; mouse-1 in the header is the panel's dispatcher (the profile binds it in the panel's map, the header's parent)
          (should (eq 'drgnx-agent-panel-act (with-current-buffer (window-buffer hw) (key-binding [mouse-1]))))
          ;; the pin: the step at the transcript window's point is pinned, in the session's state (the panel's).  That
          ;; step is the window's second, not its first row's; the transcript is not the selected window and the panel
          ;; buffer's own point is on its first row, so only the window's point names it
          (let* ((first (drgnx-ui-panel-header--entry-pos panel tw))
                 (pos (drgnx-ui-panel-header--entry-pos panel tw 1))
                 (key (and pos (list :e (get-text-property pos 'drgnx-agent-panel-entry panel)))))
            (should first)
            (should pos)
            (should-not (equal key (list :e (get-text-property first 'drgnx-agent-panel-entry panel))))
            (select-window hw)
            (with-current-buffer panel (goto-char (point-min)))
            (set-window-point tw pos)
            (should-not (eq tw (selected-window)))
            (should-not (= pos (with-current-buffer panel (point))))
            (should-not (assoc key (buffer-local-value 'drgnx-agent-panel--pins panel)))
            (drgnx-uitest-run (drgnx-uitest-click-events pin))
            (should (equal (list key) (mapcar #'car (buffer-local-value 'drgnx-agent-panel--pins panel)))))
          ;; a pill (found again: the hub redrew the header for the pin): its type's detail opens in the session's state
          (drgnx-ui-panel-header--rows-in (window-buffer hw))
          (drgnx-ui-panel-header--settle area)
          (let* ((pill (drgnx-ui-panel-header--target hw (lambda (a) (and (stringp a) (string-prefix-p "type:" a)))))
                 (action (and pill (get-text-property (posn-point pill) 'drgnx-agent-panel-action (window-buffer hw))))
                 (type (and action (intern (substring action 5))))
                 (was (memq type (buffer-local-value 'drgnx-agent-panel--disclosure panel))))
            (should pill)
            (drgnx-uitest-run (drgnx-uitest-click-events pill))
            (should (eq (not was) (and (memq type (buffer-local-value 'drgnx-agent-panel--disclosure panel)) t))))
          ;; a lens segment (found again) whose preset is not the disclosure now: after the click it is
          (drgnx-ui-panel-header--rows-in (window-buffer hw))
          (drgnx-ui-panel-header--settle area)
          (let* ((lens (drgnx-ui-panel-header--target
                        hw (lambda (a) (and (stringp a) (string-prefix-p "lens:" a)
                                            (drgnx-ui-panel-header--preset-differs-p (string-to-number (substring a 5))
                                                                                     panel)))))
                 (action (and lens (get-text-property (posn-point lens) 'drgnx-agent-panel-action (window-buffer hw))))
                 (n (and action (string-to-number (substring action 5)))))
            (should lens)
            (should (drgnx-ui-panel-header--preset-differs-p n panel))
            (drgnx-uitest-run (drgnx-uitest-click-events lens))
            (should-not (drgnx-ui-panel-header--preset-differs-p n panel)))
          (drgnx-ui-panel-header--settle area))
      (drgnx-keys--restore))))

(ert-deftest drgnx-ui-panel-header/a-strip-that-wraps-refits-the-header ()
  (let ((drgnx-ui-panel-header--prefix 40))   ; a transcript longer than its window, so its start can move
    (drgnx-ui-panel-header--with (_panel hw tw area)
      (should (drgnx-ui-panel-header--longer-p tw))
      (let* ((hb (window-buffer hw)) (lines (with-current-buffer hb (count-lines (point-min) (point-max))))
             (h (window-body-height hw t)) (class (with-current-buffer hb (drgnx-view-patch-class drgnx-view-patch))))
        (unwind-protect
            (progn
              ;; the transcript scrolled back to its first row: the header's start and fit are its own
              (set-window-start tw (with-current-buffer (window-buffer tw) (point-min)))
              (set-window-point tw (with-current-buffer (window-buffer tw) (point-min)))
              ;; a bigger font: fewer columns, the strip wraps; the hub sends the rows of the new class
              (with-current-buffer hb (text-scale-increase 3))
              (drgnx-test-wait (lambda () (with-current-buffer hb
                                            (and (not (equal class (drgnx-view-patch-class drgnx-view-patch)))
                                                 (not (drgnx-view-patch-stale drgnx-view-patch)))))
                               :secs 20 :what "the header's rows at the bigger font")
              (with-current-buffer hb (drgnx-view-draw-now nil))
              (drgnx-ui-panel-header--settle area)
              (should (> (with-current-buffer hb (count-lines (point-min) (point-max))) lines))
              (should (> (window-body-height hw t) h))
              ;; fitted, or (s2: the wrapped strip is taller than the cap) at the cap from its first row
              (should (drgnx-ui-panel-header--fitted-or-capped-p (drgnx-ui-panel-header--facts hw area)))
              (should (= (window-start hw) (with-current-buffer hb (point-min))))
              ;; the transcript, still longer than its window (shorter, its start could not move), from its first row
              (should (drgnx-ui-panel-header--longer-p tw))
              (should (= (window-start tw) (with-current-buffer (window-buffer tw) (point-min)))))
          (with-current-buffer hb (text-scale-set 0)))
        ;; back to one row of strip: the header shrinks to its rows again
        (drgnx-test-wait (lambda () (with-current-buffer hb (equal class (drgnx-view-patch-class drgnx-view-patch))))
                         :secs 20 :what "the header's rows at the font again")
        (with-current-buffer hb (drgnx-view-draw-now nil))
        (drgnx-ui-panel-header--settle area)
        (should (= lines (with-current-buffer hb (count-lines (point-min) (point-max)))))
        (should (drgnx-ui-panel-header--fitted-p hw))))))

(provide 'agent-panel-header-gui-test)
;;; agent-panel-header-gui-test.el ends here
