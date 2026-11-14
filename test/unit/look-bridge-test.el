;;; look-bridge-test.el --- batch tests: the theme bridge (package faces onto the look's) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-look" drgnx-dir) nil t)

(defun drgnx-look-bridge-test--inherits (face)
  "The `:inherit' of FACE's default spec, as a list."
  (ensure-list (plist-get (cdar (get face 'face-defface-spec)) :inherit)))

;; The audit's G7: Magit's gold headings and plain refs, diff-hl's own tints
(ert-deftest drgnx-look-bridge/packages-loaded-later-take-the-look ()
  "A package that loads after ui/look gets its bridged specs then: refs as chips in their kinds' colours, headings in
the UI heading role, the gutter in the status colours.  Turning ui/look off gives the package its own specs back."
  (let ((feature 'magit) (old '((t :foreground "gold"))))
    (when (featurep feature) (ert-skip "magit is loaded in this Emacs"))
    (dolist (f '(magit-branch-local magit-branch-remote magit-tag magit-section-heading magit-hash))
      (unless (facep f) (custom-declare-face f old "A stand-in for the package's face.")))
    (unwind-protect
        (progn
          (drgnx-test-with-modules '(ui/look)
            (should (equal old (get 'magit-tag 'face-defface-spec)))   ; not loaded yet: untouched
            (provide 'magit)
            (should (memq 'drgnx-chip-accent (drgnx-look-bridge-test--inherits 'magit-branch-local)))
            (should (memq 'drgnx-chip-ok (drgnx-look-bridge-test--inherits 'magit-branch-remote)))
            (should (memq 'drgnx-chip-warn (drgnx-look-bridge-test--inherits 'magit-tag)))
            (should (memq 'drgnx-text-subtle (drgnx-look-bridge-test--inherits 'magit-hash)))
            ;; a chip is as tall as the text: no room above or below
            (let ((box (plist-get (cdar (get 'magit-tag 'face-defface-spec)) :box)))
              (should (<= (cdr (plist-get box :line-width)) 0))))
          (should (equal old (get 'magit-tag 'face-defface-spec))))
      (setq features (delq feature features)))))

(ert-deftest drgnx-look-bridge/a-loaded-package-takes-the-look-at-once ()
  "A package already loaded when ui/look starts is bridged at once."
  (let ((feature 'magit) (old '((t :background "green"))))
    (when (featurep feature) (ert-skip "magit is loaded in this Emacs"))
    (dolist (f '(magit-hash magit-dimmed))
      (unless (facep f) (custom-declare-face f old "A stand-in for the package's face.")))
    (provide feature)
    (unwind-protect
        (drgnx-test-with-modules '(ui/look)
          (should (memq 'drgnx-text-subtle (drgnx-look-bridge-test--inherits 'magit-hash)))
          (should (memq 'drgnx-text-subtle (drgnx-look-bridge-test--inherits 'magit-dimmed))))
      (setq features (delq feature features)))))

(load (expand-file-name "modules/org/drgnx-org" drgnx-dir) nil t)

(ert-deftest drgnx-look-bridge/org-in-the-look ()
  "magit.html's Org: level 1 and 2 headings in the UI font at 17 and 14.5 px (over the editor's 13.5), weight 600;
TODO and DONE as chips no taller than the text; `outline-1' (headings in code) stays at the text's height."
  (require 'org)
  (drgnx-test-with-modules '(org/org)
    (let ((one (cdar (get 'org-level-1 'face-defface-spec))) (two (cdar (get 'org-level-2 'face-defface-spec))))
      (should (memq 'drgnx-ui-text (ensure-list (plist-get one :inherit))))
      (should (< (abs (- (plist-get one :height) (/ 17 13.5))) 0.001))
      (should (< (abs (- (plist-get two :height) (/ 14.5 13.5))) 0.001))
      (should (eq 'semibold (plist-get two :weight))))
    (should (memq 'drgnx-chip-attention (drgnx-look-bridge-test--inherits 'org-todo)))
    (should (memq 'drgnx-chip-ok (drgnx-look-bridge-test--inherits 'org-done)))
    (should (<= (cdr (plist-get (plist-get (cdar (get 'org-todo 'face-defface-spec)) :box) :line-width)) 0))
    (should-not (plist-get (cdar (get 'outline-1 'face-defface-spec)) :height))))

(ert-deftest drgnx-look-bridge/magit-text-sits-in-from-the-card-edge ()
  "magit.html: Magit's text starts 16 logical px into its card, past the fringe (its section chevrons) and a line
prefix a column wide, on a graphical frame; a terminal gets no prefix.  Turning ui/look off takes it away."
  (with-temp-buffer
    (drgnx-test-with-modules '(ui/look)
      (should (memq 'drgnx-look-bridge-magit-inset (default-value 'magit-section-mode-hook)))
      (drgnx-look-bridge-magit-inset)
      (dolist (prefix (list line-prefix wrap-prefix))
        (should (equal '(when (display-graphic-p) space :width 1.0) (get-text-property 0 'display prefix)))
        (should (get-text-property 0 'invisible prefix))))      ; a terminal: nothing
    (should-not (memq 'drgnx-look-bridge-magit-inset (default-value 'magit-section-mode-hook)))
    (should-not line-prefix)
    (should-not wrap-prefix)))

(ert-deftest drgnx-look-bridge/magit-labels-and-file-states-are-dressed ()
  "LOOK-FIX-MAGIT-LABELS-1: `Head:' and its kin take the UI heading face, a file's `modified' / `new file' the warn
and ok faces, as overlays made again on every refresh; text that merely looks alike is left alone."
  (with-temp-buffer
    (insert "Head:     main  init\nPush:     origin/main\nmodified   core/a.el\nnew file   core/b.el\n  modified in a hunk\n")
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
      (drgnx-look-bridge--magit-label-overlays)
      (drgnx-look-bridge--magit-label-overlays))            ; again: no second set
    (let ((faces (mapcar (lambda (o) (cons (buffer-substring (overlay-start o) (overlay-end o)) (overlay-get o 'face)))
                         (sort (overlays-in (point-min) (point-max))
                               (lambda (a b) (< (overlay-start a) (overlay-start b)))))))
      (should (equal faces '(("Head:" . drgnx-look-bridge-label) ("Push:" . drgnx-look-bridge-label)
                             ("modified" . drgnx-look-bridge-file-modified)
                             ("new file" . drgnx-look-bridge-file-new)))))))

(ert-deftest drgnx-look-bridge/a-section-chevron-is-an-icon-that-follows-its-state ()
  "LOOK-FIX-MAGIT-FOLD-1: the heading's chevron is right when the section is hidden and down when it shows."
  (cl-letf (((symbol-function 'drgnx-look-icon) (lambda (name &rest _) (symbol-name name))))
    (should (equal "chevron-right " (drgnx-look-bridge--chevron-string t)))
    (should (equal "chevron-down " (drgnx-look-bridge--chevron-string nil)))))

(ert-deftest drgnx-look-bridge/org-tags-are-aligned-by-pixel ()
  "LOOK-FIX-ORG-TAGS-1: the blank before a headline's tags is a space that ends at the window's right edge (the tags'
own pixel width and 8 logical px in), whatever the headline's font; headlines without tags are untouched."
  (require 'org)
  (with-temp-buffer
    (insert "* Gateway   :core:agent:\n** Queue replies to a dead client  :test:\n* No tags here\n")
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'string-pixel-width) (lambda (s &rest _) (* 10 (length s)))))
      (goto-char (point-min))
      (drgnx-org--align-tags (point-max)))
    (let ((first (get-text-property 10 'display))
          (second (get-text-property (+ (string-search "dead client" (buffer-string)) 13) 'display)))
      (should (equal first `(space :align-to (- right (,(+ 120 (drgnx-px 8)))))))
      (should (equal second `(space :align-to (- right (,(+ 60 (drgnx-px 8))))))))
    (should-not (text-property-not-all (1+ (string-search "No tags" (buffer-string))) (point-max) 'display nil))))

;;; look-bridge-test.el ends here
