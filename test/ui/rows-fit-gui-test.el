;;; rows-fit-gui-test.el --- GUI tests: the hub's fitted widths against the editor's (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; The hub fits labels from the font file's advances (drgnx-rows, skrifa); the editor lays them out with its own
;; shaping and hinting.  These rows compare the two on the fixture fonts (test/fixtures/fonts), installed for this
;; session only.  Runnable from a checkout on any GUI build (Linux or macOS): nothing here needs a Linux harness.

(require 'ert)
(require 'cl-lib)

(defconst drgnx-rows-fit-ui-test--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))

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
