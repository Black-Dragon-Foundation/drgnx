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

(defconst drgnx-rows-fit-ui-test--widths '(80 160 240) "The pixel widths each label is fitted to.")

(defun drgnx-rows-fit-ui-test--report (line)
  "LINE in the messages and in the report file (DRGNX_ROWS_FIT_REPORT, else the run's evidence folder)."
  (message "%s" line)
  (when-let* ((out (or (getenv "DRGNX_ROWS_FIT_REPORT")
                       (and (getenv "DRGNX_UI_EVIDENCE") (expand-file-name "rows-fit.txt" (getenv "DRGNX_UI_EVIDENCE"))))))
    (write-region (concat line "\n") nil out t 'silent)))

(defun drgnx-rows-fit-ui-test--check-rows (buffer)
  "Each label row of BUFFER: (KEY PX WIDTH CUT MAX-CHAR), WIDTH the drawn segment's before its stop."
  (with-current-buffer buffer
    (let ((state drgnx-view-patch) out)
      (dolist (l drgnx-rows-fit-ui-test--labels)
        (dolist (px drgnx-rows-fit-ui-test--widths)
          (let* ((key (format "%s/%d" (car l) px)) (row (gethash key (drgnx-view-patch-rows state)))
                 (beg (drgnx-view-row-start drgnx-view key)) (stop (car (car (plist-get row :stops))))
                 (seg (buffer-substring beg (+ beg stop))))
            (push (list key px (string-pixel-width seg) (and (string-search "…" seg) t)
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
