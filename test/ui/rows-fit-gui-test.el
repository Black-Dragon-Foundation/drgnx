;;; rows-fit-gui-test.el --- GUI tests: the hub's fitted widths against the editor's (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; The hub fits labels from the font file's advances (drgnx-rows, skrifa); the editor lays them out with its own
;; shaping and hinting.  These rows compare the two on the fixture fonts (test/fixtures/fonts), installed for this
;; session only.  The fit check and the row heights run on the fixture view `rows-demo', fed by the hub (a test-hooks
;; build from DRGNX_RATATOSKR_BIN; test/fixtures/rows-demo-fixture.el).  Runnable from a checkout on any GUI build
;; (Linux or macOS) with only the hub built: nothing here needs a Linux harness.

(require 'ert)
(require 'cl-lib)

(defconst drgnx-rows-fit-ui-test--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))

(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-rows-fit-ui-test--repo)))
(load (expand-file-name "test/fixtures/rows-demo-fixture" drgnx-rows-fit-ui-test--repo) nil t)
(require 'drgnx-pixels)                  ; `drgnx-px': a label's width in the frame's pixels

(defconst drgnx-rows-fit-ui-test--fonts
  '(("Inter" . "Inter-Regular.ttf") ("JetBrains Mono" . "JetBrainsMono-Regular.otf"))
  "The fixture fonts the rows measure: family → file under test/fixtures/fonts.")

(defun drgnx-rows-fit-ui-test--found-p ()
  "Non-nil when this Emacs finds every fixture family."
  (cl-every (lambda (f) (find-font (font-spec :family (car f)))) drgnx-rows-fit-ui-test--fonts))

(defun drgnx-rows-fit-ui-test--install ()
  "Make the fixture fonts known to this Emacs.  The GUI test image has them (test/container/base/Containerfile.gui);
elsewhere they are copied to the user's font folder (fontconfig's on GNU/Linux, the user's Fonts on macOS) and the
font cache cleared, which an Emacs started before may not see.  Non-nil when every family is found."
  (or (drgnx-rows-fit-ui-test--found-p)
      (let ((dir (if (eq system-type 'darwin) (expand-file-name "~/Library/Fonts/")
                   (expand-file-name "fonts/" (or (getenv "XDG_DATA_HOME") "~/.local/share/")))))
        (make-directory dir t)
        (dolist (f drgnx-rows-fit-ui-test--fonts)
          (let ((to (expand-file-name (cdr f) dir)))
            (unless (file-exists-p to)
              (copy-file (expand-file-name (concat "test/fixtures/fonts/" (cdr f)) drgnx-rows-fit-ui-test--repo) to))))
        (when (executable-find "fc-cache") (call-process "fc-cache" nil nil nil "-f" dir))
        (clear-font-cache)
        (drgnx-rows-fit-ui-test--found-p))))

(defun drgnx-rows-fit-ui-test--sums ()
  "The hub's sums (test/fixtures/rows-fit-sums.eld, written by drgnx-rows' `fit_sums')."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/fixtures/rows-fit-sums.eld" drgnx-rows-fit-ui-test--repo))
    (read (current-buffer))))

(defun drgnx-rows-fit-ui-test--emacs-width (family px text)
  "TEXT's width in px as the editor lays it out in FAMILY at PX pixels."
  (let ((face (make-symbol "rows-fit")))
    (face-spec-set face `((t :font ,(font-spec :family family :size px))) 'face-defface-spec)
    (unwind-protect (string-pixel-width (propertize text 'face face))
      (face-spec-set face nil 'reset))))

(ert-deftest drgnx-ui-rows-fit/sums-are-within-the-slack ()
  "The rounding decision: for every fixture string (40 chars; Latin, digits, punctuation) in Inter and JetBrains Mono
at 11-16 px, the hub's sum against `string-pixel-width'.  Both modes' largest errors are printed; the smaller decides
`drgnx_rows::fit::ROUNDING'.  The mode the hub uses must stay within the 10 px slack."
  (skip-unless (display-graphic-p))
  (should (drgnx-rows-fit-ui-test--install))
  (let ((frac 0.0) (round 0.0) (worst nil))
    (dolist (s (drgnx-rows-fit-ui-test--sums))
      (let* ((w (drgnx-rows-fit-ui-test--emacs-width (plist-get s :family) (plist-get s :px) (plist-get s :text)))
             (ef (abs (- w (plist-get s :fractional)))) (er (abs (- w (plist-get s :per-glyph)))))
        (when (> ef frac) (setq frac ef worst (list s w)))
        (setq round (max round er))))
    (let ((line (format "rows-fit: max error over 40 chars: fractional %.2f px, per-glyph %.2f px; worst fractional %S\n"
                        frac round worst))
          (out (or (getenv "DRGNX_ROWS_FIT_REPORT")
                   (and (getenv "DRGNX_UI_EVIDENCE") (expand-file-name "rows-fit.txt" (getenv "DRGNX_UI_EVIDENCE"))))))
      (message "%s" line)
      ;; a report file: DRGNX_ROWS_FIT_REPORT, else the container run's evidence folder (the numbers go in the ledger)
      (when out (write-region line nil out t)))
    (should (<= (min frac round) 10))))

;;;; The fit check row and row heights: the fixture view `rows-demo' fed by a real hub (test/fixtures/rows-demo-fixture.el)

(defconst drgnx-rows-fit-ui-test--labels
  '(("latin" . "The quick brown fox jumps over the lazy dog 0123456789")
    ("liga" . "-> => != === <= >= :: ffi ffl fi fl www")
    ("zwj" . "dev \N{WOMAN}\N{ZERO WIDTH JOINER}\N{PERSONAL COMPUTER} team done")
    ("combining" . "cafe\N{COMBINING ACUTE ACCENT} nai\N{COMBINING DIAERESIS}ve A\N{COMBINING RING ABOVE}ngstrom")
    ("rtl" . "\N{ARABIC LETTER MEEM}\N{ARABIC LETTER REH}\N{ARABIC LETTER HAH}\N{ARABIC LETTER BEH}\N{ARABIC LETTER ALEF} hello"))
  "The fit check's labels: Latin, ligatures, a ZWJ sequence, combining marks and right-to-left text.")

(defconst drgnx-rows-fit-ui-test--widths '(80 160 240)
  "The widths each label is fitted to, in logical pixels (the hub fits to them at the class's scale).")

(defun drgnx-rows-fit-ui-test--report (line)
  "LINE in the messages and in the report file (DRGNX_ROWS_FIT_REPORT, else the run's evidence folder)."
  (message "%s" line)
  (when-let* ((out (or (getenv "DRGNX_ROWS_FIT_REPORT")
                       (and (getenv "DRGNX_UI_EVIDENCE") (expand-file-name "rows-fit.txt" (getenv "DRGNX_UI_EVIDENCE"))))))
    (write-region (concat line "\n") nil out t 'silent)))

(defun drgnx-rows-fit-ui-test--check-rows (buffer)
  "Each label row of BUFFER: (KEY PX WIDTH CUT MAX-CHAR), PX the label's width in the frame's pixels (`drgnx-px'),
WIDTH the drawn segment's before its stop."
  (with-current-buffer buffer
    (let ((state drgnx-view-patch) out)
      (dolist (l drgnx-rows-fit-ui-test--labels)
        (dolist (px drgnx-rows-fit-ui-test--widths)
          (let* ((key (format "%s/%d" (car l) px)) (row (gethash key (drgnx-view-patch-rows state)))
                 (beg (drgnx-view-row-start drgnx-view key)) (stop (car (car (plist-get row :stops))))
                 (seg (buffer-substring beg (+ beg stop))))
            (push (list key (drgnx-px px) (string-pixel-width seg) (and (string-search "…" seg) t)
                        (apply #'max (mapcar (lambda (c) (string-pixel-width (string c))) (cdr l))))
                  out))))
      out)))

(ert-deftest drgnx-ui-rows-fit/no-fitted-segment-overflows-its-stop ()
  "The fit check row: the hub fits each label (Latin, ligatures, ZWJ, combining, RTL) in Inter and JetBrains Mono at
11-16 px to 80, 160 and 240 px from the font file Emacs uses; after the editor's fit guard no segment runs past its
stop, and none is cut more than the slack and one glyph short (joined right-to-left text in a fallback font, whose
per-char sum runs wide, is reported instead).  The guard's re-fits are reported."
  (skip-unless (display-graphic-p))
  (should (drgnx-rows-fit-ui-test--install))
  (let ((font (face-attribute 'default :font (selected-frame))) (refits 0) (rows 0) (gap 0) (latin-asked nil) (bad nil) (rtl-short nil))
    (unwind-protect
        (drgnx-rows-demo-with
          (dolist (family '("Inter" "JetBrains Mono"))
            (dolist (px '(11 12 13 14 15 16))
              (set-face-attribute 'default (selected-frame) :font (font-spec :family family :size px))
              (let ((b (drgnx-rows-demo-open)))
                (drgnx-rows-demo-feed nil nil (cl-loop for l in drgnx-rows-fit-ui-test--labels
                                                       append (mapcar (lambda (w) (list (format "%s/%d" (car l) w) (cdr l) w))
                                                                      drgnx-rows-fit-ui-test--widths)))
                (drgnx-rows-demo-settle b (format "%s %d px fitted" family px))
                (dolist (r (drgnx-rows-fit-ui-test--check-rows b))
                  (cl-destructuring-bind (key w width cut max-char) r
                    (setq rows (1+ rows))
                    (when (> width w) (push (list :over family px key w width) bad))
                    (when cut
                      (setq gap (max gap (- w width)))
                      ;; joined (shaped) script in a fallback font: the per-char sum runs wide, so it may cut short;
                      ;; reported, not failed (docs/develop/hub.md, "Fitting")
                      (when (> (- w width) (+ 10 max-char))
                        (if (string-prefix-p "rtl/" key) (push (list key family px (- w width)) rtl-short)
                          (push (list :short family px key w width max-char) bad))))))
                (setq refits (+ refits (drgnx-view-patch-refits (drgnx-rows-demo-state b))))
                ;; the font file was read: no Latin letter was asked of the editor
                (maphash (lambda (k _) (when (memq (cdr k) (string-to-list "Thequickbrownfox")) (setq latin-asked t)))
                         drgnx-view-env--glyphs)
                (kill-buffer b)))))
      (set-face-attribute 'default (selected-frame) :font font))
    (drgnx-rows-fit-ui-test--report
     (format "rows-fit check: %d rows, %d re-fit by the guard, largest cut gap %d px; shaped RTL cut short: %S"
             rows refits gap (nreverse rtl-short)))
    (should-not (nreverse bad))
    (should-not latin-asked)))

(ert-deftest drgnx-ui-rows-fit/row-heights-match-the-window ()
  "A row of two lines' height is drawn that tall: `window-line-height' of its line against `default-line-height'."
  (skip-unless (display-graphic-p))
  (drgnx-rows-demo-with
    (let ((b (drgnx-rows-demo-open)))
      (delete-other-windows)
      (drgnx-rows-demo-feed (list (drgnx-rows-demo-row "tall" "tall row" :height '(:lines 2 :unit 0))
                                  (drgnx-rows-demo-row "plain" "plain row")))
      (drgnx-rows-demo-settle b)
      (set-window-start (selected-window) (point-min))
      (redisplay t)
      (let ((dlh (with-current-buffer b (default-line-height))))
        (should (<= (abs (- (car (window-line-height 0)) (* 2 dlh))) 2))
        (should (<= (abs (- (car (window-line-height 1)) dlh)) 2))))))

(ert-deftest drgnx-ui-rows-fit/text-scale-moves-the-view-to-its-new-class ()
  "`text-scale' in a hub-fed view's buffer makes a new display class: the buffer follows it, and the hub's reset for
that class fills it again."
  (skip-unless (display-graphic-p))
  (require 'face-remap)
  (drgnx-rows-demo-with
    (let ((b (drgnx-rows-demo-open)))
      (drgnx-rows-demo-feed (list (drgnx-rows-demo-row "a" "row a") (drgnx-rows-demo-row "b" "row b")))
      (drgnx-rows-demo-settle b)
      (let ((class (drgnx-view-patch-class (drgnx-rows-demo-state b))))
        (with-current-buffer b (text-scale-set 2))
        (drgnx-test-wait (lambda () (not (equal class (drgnx-view-patch-class (drgnx-rows-demo-state b)))))
                         :secs 10 :what "the buffer in its new class")
        (drgnx-rows-demo-settle b "the new class's reset")
        (should (equal "row a\nrow b\n" (drgnx-rows-demo-text b)))
        (should (member (drgnx-view-patch-class (drgnx-rows-demo-state b)) (drgnx-view-env-classes drgnx-rows-demo-view)))))))

(ert-deftest drgnx-ui-rows-fit/two-frames-two-classes ()
  "Two real GUI classes in one session: the view's buffer shown in a second frame whose default font is twice the
first's (scale 2: the container cannot change `frame-scale-factor').  The editor sends one env per class, the hub
starts each class with its own reset (the second fitted to twice the size), and the buffer keeps the one fit it
holds: the class it was paired with, never stale."
  (skip-unless (display-graphic-p))
  (drgnx-rows-demo-with
    (let* ((b (drgnx-rows-demo-open)) (resets nil)
           (count (lambda (event data)
                    (when (and (equal event "view-patch") (drgnx-view-patch--reset-p data))
                      (push (plist-get data :class) resets))))
           (frame (make-frame '((width . 60) (height . 10))))
           (px (aref (font-info (face-font 'default)) 2)))
      (unwind-protect
          (progn
            (add-hook 'drgnx-hub-event-functions count)
            (drgnx-rows-demo-feed nil nil '(("label" "The quick brown fox jumps over the lazy dog" 160)))
            (drgnx-rows-demo-settle b)
            (let ((paired (drgnx-view-patch-class (drgnx-rows-demo-state b))))
              (set-face-attribute 'default frame :font (font-spec :family "Inter" :size (* 2 px)))
              (set-window-buffer (frame-root-window frame) b)
              (drgnx-test-wait (lambda () (eq t (frame-visible-p frame))) :secs 10 :what "the second frame shown")
              (drgnx-view-env-update drgnx-rows-demo-view)
              (drgnx-test-wait (lambda () (= 2 (length (delete-dups (copy-sequence resets))))) :secs 15
                               :what "a reset for each class")
              (let ((classes (drgnx-view-env-classes drgnx-rows-demo-view)))
                (should (= 2 (length classes)))
                (should (member paired classes)))
              (drgnx-rows-demo-settle b)
              (let ((s (drgnx-rows-demo-state b)))
                (should (equal paired (drgnx-view-patch-class s)))
                (should-not (drgnx-view-patch-stale s)))
              (should (string-prefix-p "The quick" (drgnx-rows-demo-text b)))))
        (remove-hook 'drgnx-hub-event-functions count)
        (delete-frame frame)))))

(defun drgnx-rows-fit-ui-test--scales ()
  "The session's monitor scales (one per monitor), from DRGNX_UI_SESSION_SCALES; nil at scale 1."
  (mapcar #'string-to-number (split-string (or (getenv "DRGNX_UI_SESSION_SCALES") "") " " t)))

(defun drgnx-rows-fit-ui-test--move (frame output)
  "Put FRAME (titled \"drgnx-rows-twin\") on sway's OUTPUT: non-nil once `swaymsg' finds its window.  A frame
becomes a compositor window only when it is drawn and presented, so each try waits for FRAME's paint first; a wait
that only reads process output leaves it unmapped and the move finds no node."
  (drgnx-test-wait
   (lambda ()
     (drgnx-test-wait-presented :frame frame)
     (zerop (call-process "swaymsg" nil nil nil (format "[title=\"drgnx-rows-twin\"] move to output %s" output))))
   :secs 10 :what "the second frame on the second monitor"))

(defun drgnx-rows-fit-ui-test--second-frame (px)
  "A new frame in a display class of its own, as (FRAME HOW . SCALED): on the second monitor when the session has two at two
scales under sway (`swaymsg' moves its window there; the class then differs by its scale), else with a default font
twice PX.  SCALED is non-nil on the second monitor: there the class differs by its scale alone, so a label's fit in
logical pixels, and its text, is the same in both."
  (let ((scales (drgnx-rows-fit-ui-test--scales)) (root (selected-frame))
        (frame (make-frame '((width . 60) (height . 10) (title . "drgnx-rows-twin")))))
    (if (and (= 2 (length scales)) (/= (nth 0 scales) (nth 1 scales))
             (getenv "SWAYSOCK") (executable-find "swaymsg"))
        (progn
          (drgnx-rows-fit-ui-test--move frame "HEADLESS-2")
          (drgnx-test-wait (lambda () (drgnx-test-wait-presented :frame frame)
                             (/= (drgnx-pixels-scale frame) (drgnx-pixels-scale root)))
                           :secs 10 :what "the second monitor's scale on the second frame")
          (select-frame-set-input-focus root)
          (cl-list* frame (format "two monitors, scales %S and %S" (drgnx-pixels-scale root) (drgnx-pixels-scale frame)) t))
      (set-face-attribute 'default frame :font (font-spec :family "Inter" :size (* 2 px)))
      (cl-list* frame "one monitor: the second frame's font twice the first's" nil))))

(defun drgnx-rows-fit-ui-test--panel-keys (buffer)
  "BUFFER's view drawn: the key of each line, top to bottom, a key once."
  (with-current-buffer buffer
    (drgnx-view-draw-now drgnx-view)
    (save-excursion
      (goto-char (point-min))
      (let (keys)
        (while (not (eobp))
          (let ((k (drgnx-view-key-at))) (unless (equal k (car keys)) (push k keys)))
          (forward-line 1))
        (nreverse keys)))))

(ert-deftest drgnx-ui-rows-fit/a-view-in-two-classes-shows-each-its-own-rows ()
  "One buffer per class (RRO-BUFFER-PER-CLASS-1): the view's buffer, with a twin function, shown in a second frame of
another class: the second monitor at another scale when the session has two under sway (`DRGNX_UI_MONITORS=2
DRGNX_UI_SCALES=\"1 2\"`), else a default font twice the size.  That
frame's window shows a twin paired with its class, the first keeps the buffer; the hub sends each its own class's
reset, neither stale; with the doubled font each holds its own fit of the label (the second's cut shorter)."
  (skip-unless (display-graphic-p))
  (require 'drgnx-pixels)
  (drgnx-rows-demo-with
    (let* ((b (drgnx-rows-demo-open)) (twins nil) (px (aref (font-info (face-font 'default)) 2))
           (made (drgnx-rows-fit-ui-test--second-frame px)) (frame (car made)) (how (cadr made)) (scaled (cddr made)))
      (with-current-buffer b
        (setq-local drgnx-view-patch-twin-function
                    (lambda (class)
                      (let ((tw (generate-new-buffer " *rows-demo twin*")))
                        (push tw drgnx-rows-demo--buffers)
                        (with-current-buffer tw (drgnx-view-patch-attach drgnx-rows-demo-view class))
                        (push tw twins)
                        tw))))
      (unwind-protect
          (progn
            (drgnx-rows-demo-feed nil nil '(("label" "The quick brown fox jumps over the lazy dog" 160)))
            (drgnx-rows-demo-settle b)
            (drgnx-test-wait (lambda () (eq t (frame-visible-p frame))) :secs 10 :what "the second frame shown")
            (set-window-buffer (frame-root-window frame) b)
            (drgnx-view-env-update drgnx-rows-demo-view)
            (drgnx-test-wait (lambda () twins) :secs 10 :what "a twin for the second class")
            (let ((tw (car twins)))
              (should (eq tw (window-buffer (frame-root-window frame))))
              (should (eq b (window-buffer (frame-root-window (selected-frame)))))
              (drgnx-rows-demo-settle tw "the twin's class's reset")
              (drgnx-rows-demo-settle b)
              (let ((sb (drgnx-rows-demo-state b)) (st (drgnx-rows-demo-state tw)))
                (should-not (equal (drgnx-view-patch-class sb) (drgnx-view-patch-class st)))
                (should (equal (sort (list (drgnx-view-patch-class sb) (drgnx-view-patch-class st)) #'string<)
                               (sort (copy-sequence (drgnx-view-env-classes drgnx-rows-demo-view)) #'string<)))
                (should-not (drgnx-view-patch-stale sb))
                (should-not (drgnx-view-patch-stale st)))
              (let ((one (drgnx-rows-demo-text b)) (two (drgnx-rows-demo-text tw)))
                (drgnx-rows-fit-ui-test--report (format "per-class rows (%s): %S | %S" how one two))
                (should (string-prefix-p "The" one))
                (should (string-prefix-p "The" two))
                (unless scaled (should-not (equal one two))))))
        (delete-frame frame)))))

(defvar drgnx-panel-replay-prefix)
(declare-function drgnx-panel-replay-up "panel-replay-fixture" (bin &optional old))
(declare-function drgnx-panel-replay-down "panel-replay-fixture" ())

(ert-deftest drgnx-ui-rows-fit/the-agent-panel-in-two-classes-keeps-its-cards-and-composer ()
  "The agent panel shown in a second class (RRO-PANEL-TWIN-1), as the user's external monitor does: a real hub and a
mock agent (test/fixtures/panel-replay-fixture.el, a short turn); the second frame's window shows the panel's twin,
paired with its class, its hub rows that class's, its own rows (the header, the chips, the cards, the composer) the
panel's, neither stale; the twin is no panel of its own."
  (skip-unless (display-graphic-p))
  (require 'drgnx-pixels)
  (load (expand-file-name "test/fixtures/panel-replay-fixture" drgnx-rows-fit-ui-test--repo) nil t)
  (let* ((load-path (cons (expand-file-name "modules/tools" drgnx-rows-fit-ui-test--repo) load-path))
         (drgnx-view-patch--buffers (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
         (drgnx-view-env--views (make-hash-table :test #'equal)) (drgnx-view-env--sent (make-hash-table :test #'equal))
         (drgnx-view-env--glyphs (make-hash-table :test #'equal)) (drgnx-view-env--hooked nil)
         (drgnx-panel-replay-prefix 3) (frame nil) (panel nil))
    (unwind-protect
        (save-window-excursion
          (setq panel (drgnx-panel-replay-up (drgnx-rows-demo--bin)))
          (let* ((px (aref (font-info (face-font 'default)) 2)) (made (drgnx-rows-fit-ui-test--second-frame px))
                 (view (with-current-buffer panel (drgnx-view-patch-view drgnx-view-patch))) (tw nil))
            (setq frame (car made))
            (drgnx-test-wait (lambda () (eq t (frame-visible-p frame))) :secs 10 :what "the second frame shown")
            (set-window-buffer (frame-root-window frame) panel)
            (drgnx-view-env-update view)
            (setq tw (drgnx-test-wait (lambda () (let ((b (window-buffer (frame-root-window frame))))
                                                   (and (eq panel (drgnx-view-patch-twin-p b)) b)))
                                      :secs 10 :what "the panel's twin in the second frame"))
            (should (eq panel (window-buffer (get-buffer-window panel (selected-frame)))))
            (should-not (memq tw (drgnx-agent-panel-buffers)))
            (dolist (b (list panel tw))
              (drgnx-test-wait (lambda () (with-current-buffer b
                                            (and (> (hash-table-count (drgnx-view-patch-rows drgnx-view-patch)) 0)
                                                 (not (drgnx-view-patch-stale drgnx-view-patch)))))
                               :secs 20 :what (list "the hub's rows of the class" b)))
            (let ((sp (buffer-local-value 'drgnx-view-patch panel)) (st (buffer-local-value 'drgnx-view-patch tw)))
              (should-not (equal (drgnx-view-patch-class sp) (drgnx-view-patch-class st)))
              (should (equal (sort (list (drgnx-view-patch-class sp) (drgnx-view-patch-class st)) #'string<)
                             (sort (copy-sequence (drgnx-view-env-classes view)) #'string<))))
            (let ((kp (drgnx-rows-fit-ui-test--panel-keys panel)) (kt (drgnx-rows-fit-ui-test--panel-keys tw)))
              (drgnx-rows-fit-ui-test--report (format "agent panel in two classes (%s): own rows %S, hub rows %d | %d"
                                                      (cadr made) (seq-remove #'stringp kp)
                                                      (length (seq-filter #'stringp kp)) (length (seq-filter #'stringp kt))))
              (should (equal (seq-remove #'stringp kp) (seq-remove #'stringp kt)))
              (should (member '(:composer) kt))
              (should (equal (seq-filter #'stringp kp) (seq-filter #'stringp kt))))))
      (when (frame-live-p frame) (delete-frame frame))
      (drgnx-panel-replay-down)
      (drgnx-view-env-teardown)
      (drgnx-view-patch-teardown))))

(defvar drgnx-explorer--roots)
(defvar drgnx-explorer--hub-view)
(defvar drgnx-explorer--expanded)
(defvar drgnx-explorer-git)
(defvar drgnx-explorer--window-asker)
(defvar drgnx-explorer-buffer-name)
(defvar drgnx-explorer-hub-view-name)
(declare-function drgnx-explorer--buffer "drgnx-explorer" ())

(ert-deftest drgnx-ui-rows-fit/the-explorer-s-twin-pages-when-it-scrolls ()
  "Pattern C (a handshake on the hub's rows): the Explorer over a folder of 400 files (more than the hub's window of
rows), shown in a second frame of another class (the second monitor at another scale under sway, else a doubled
font): that frame shows the Explorer's twin with its class's rows; scrolled to the end of its rows, the twin asks the
hub for the window further on, and its rows then hold entries past the first window."
  (skip-unless (display-graphic-p))
  (skip-unless (fboundp 'nidhogg-view--call))
  (require 'drgnx-pixels)
  (require 'drgnx-explorer)
  (drgnx-rows-demo-with
    (let* ((dir (file-name-as-directory (make-temp-file "explorer-twin" t)))
           (drgnx-explorer--roots (list dir)) (drgnx-explorer--hub-view nil) (drgnx-explorer-git nil)
           (drgnx-explorer--expanded (make-hash-table :test #'equal)) (drgnx-explorer--window-asker nil)
           (px (aref (font-info (face-font 'default)) 2)) (frame nil))
      (dotimes (i 400) (write-region "" nil (expand-file-name (format "f%03d.txt" i) dir) nil 'silent))
      (unwind-protect
          (let* ((b (drgnx-explorer--buffer))
                 (rows-p (lambda (buf) (with-current-buffer buf
                                         (and drgnx-view-patch (> (drgnx-view-row-count drgnx-view) 1)))))
                 (made (drgnx-rows-fit-ui-test--second-frame px)))
            (setq frame (car made))
            (set-window-buffer (selected-window) b)
            (drgnx-view-env-update drgnx-explorer-hub-view-name)
            (drgnx-test-wait (lambda () (funcall rows-p b)) :secs 20 :what "the Explorer's rows")
            (drgnx-test-wait (lambda () (eq t (frame-visible-p frame))) :secs 10 :what "the second frame shown")
            (set-window-buffer (frame-root-window frame) b)
            (drgnx-view-env-update drgnx-explorer-hub-view-name)
            (let* ((w (frame-root-window frame))
                   (tw (drgnx-test-wait (lambda () (let ((x (window-buffer w))) (and (eq b (drgnx-view-patch-twin-p x)) x)))
                                        :secs 10 :what "the Explorer's twin in the second frame")))
              (drgnx-test-wait (lambda () (funcall rows-p tw)) :secs 20 :what "the twin's rows")
              (should-not (string-match-p "f300" (with-current-buffer tw (buffer-string))))
              (with-selected-window w (goto-char (point-max)) (recenter -1))
              (drgnx-test-wait (lambda ()
                                 (drgnx-test-wait-presented :frame frame)   ; the scroll runs in its redisplay
                                 (with-current-buffer tw
                                   (> (car (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'window "order")) 0)))
                               :secs 20 :what "the hub's window moved by the twin's scroll")
              (should (eq tw (cdr drgnx-explorer--window-asker)))          ; the twin asked, not the Explorer's buffer
              (drgnx-test-wait (lambda () (with-current-buffer tw (string-match-p "f2[0-9][0-9]" (buffer-string))))
                               :secs 20 :what "the twin's rows past the first window")
              (drgnx-rows-fit-ui-test--report
               (format "the Explorer's twin (%s): window from %S" (cadr made)
                       (with-current-buffer tw (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'window "order"))))))
        (when (frame-live-p frame) (delete-frame frame))
        (when-let* ((b (get-buffer drgnx-explorer-buffer-name))) (kill-buffer b))
        (delete-directory dir t)))))
