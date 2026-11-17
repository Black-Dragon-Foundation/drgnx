;;; fold-test.el --- batch tests: folding on the line model (module editor/fold) -*- lexical-binding: t -*-
;; test-class: det
;; The commands of modules/editor/drgnx-fold.el over Nidhogg's line model (nidhogg-lines-*): ranges by indentation,
;; overlays with a summary, the hidden ranges told to the model, manual and named folds, Org, evil's fold keys.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx)
(load (expand-file-name "modules/editor/drgnx-fold" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(declare-function nidhogg-lines-describe "nidhogg-lines" (&optional buffer))
(declare-function nidhogg-lines-disable "nidhogg-lines" (&optional buffer))

(defconst fold-test--text
  "def a():\n    x = 1\n    if x:\n        y = 2\n    z = 3\ndef b():\n    w = 4\n"
  "Three indentation ranges: a (lines 1–5), its `if' (3–4), b (6–7).")

(defmacro fold-test--with (&rest body)
  "BODY in a `prog-mode' buffer of `fold-test--text', point at its start."
  (declare (indent 0))
  `(progn
     (skip-unless (fboundp 'nidhogg-lines-set-fold-sources))
     (with-temp-buffer
       (insert fold-test--text)
       (prog-mode)
       (goto-char (point-min))
       (unwind-protect (progn ,@body)
         (nidhogg-lines-disable)))))

(defun fold-test--line (n)
  "The start of line N."
  (save-excursion (goto-char (point-min)) (forward-line (1- n)) (point)))

(defun fold-test--hidden ()
  "The lines hidden, as numbers."
  (cl-loop for n from 1 to 7 when (invisible-p (fold-test--line n)) collect n))

(defun fold-test--model-hidden ()
  "How many hidden ranges the line model holds."
  (plist-get (nidhogg-lines-describe) :hidden))

(ert-deftest drgnx-fold/fold-and-unfold-the-block-at-point ()
  "Fold hides the block after its first line, with `⋯ N lines', and tells the model; Unfold shows it again."
  (fold-test--with
    (drgnx-fold-fold)
    (should (equal (fold-test--hidden) '(2 3 4 5)))
    (let ((ov (car (drgnx-fold--overlays))))
      (should (string-match-p "⋯ 4 lines" (overlay-get ov 'display))))
    (should (= (fold-test--model-hidden) 1))
    (drgnx-fold-unfold)
    (should-not (fold-test--hidden))
    (should (= (fold-test--model-hidden) 0))
    (should-error (drgnx-fold-unfold) :type 'user-error)))

(ert-deftest drgnx-fold/fold-on-a-folded-line-folds-the-block-around-it ()
  (fold-test--with
    (goto-char (fold-test--line 3))
    (drgnx-fold-fold)
    (should (equal (fold-test--hidden) '(4)))
    (drgnx-fold-fold)
    (should (equal (fold-test--hidden) '(2 3 4 5)))
    (should (= (length (drgnx-fold--overlays)) 2))))

(ert-deftest drgnx-fold/toggle ()
  (fold-test--with
    (goto-char (fold-test--line 6))
    (drgnx-fold-toggle)
    (should (equal (fold-test--hidden) '(7)))
    (drgnx-fold-toggle)
    (should-not (fold-test--hidden))))

(ert-deftest drgnx-fold/recursive-folds-and-unfolds-the-blocks-inside ()
  (fold-test--with
    (drgnx-fold-fold-recursive)
    (should (= (length (drgnx-fold--overlays)) 2))
    (should (equal (fold-test--hidden) '(2 3 4 5)))
    (drgnx-fold-unfold-recursive)
    (should-not (drgnx-fold--overlays))))

(ert-deftest drgnx-fold/all-and-none ()
  (fold-test--with
    (drgnx-fold-fold-all)
    (should (= (length (drgnx-fold--overlays)) 3))
    (should (equal (fold-test--hidden) '(2 3 4 5 7)))
    (should (= (fold-test--model-hidden) 3))
    (drgnx-fold-unfold-all)
    (should-not (drgnx-fold--overlays))
    (should (= (fold-test--model-hidden) 0))))

(ert-deftest drgnx-fold/level-folds-one-depth-but-the-block-at-point ()
  (fold-test--with
    (drgnx-fold-fold-level 2)
    (should (equal (fold-test--hidden) '(4)))
    (drgnx-fold-unfold-all)
    (goto-char (fold-test--line 2))
    (drgnx-fold-fold-level 1)
    (should (equal (fold-test--hidden) '(7)))
    (should-error (drgnx-fold-fold-level 8) :type 'user-error)))

(ert-deftest drgnx-fold/more-and-less-step-vims-fold-level ()
  "`z m' folds the deepest blocks still open, then the next level; `z r' opens them again level by level; the
level is the buffer's own and Unfold All clears it."
  (fold-test--with
    (drgnx-fold-more)
    (should (equal (fold-test--hidden) '(4)))
    (drgnx-fold-more)
    (should (equal (fold-test--hidden) '(2 3 4 5 7)))
    (drgnx-fold-more)
    (should (= drgnx-fold--level 0))
    (drgnx-fold-less)
    (should (equal (fold-test--hidden) '(4)))
    (drgnx-fold-less)
    (should-not (fold-test--hidden))
    (should-not drgnx-fold--level)
    (drgnx-fold-more)
    (drgnx-fold-unfold-all)
    (should-not drgnx-fold--level)))

(ert-deftest drgnx-fold/kind-folds-every-range-of-it ()
  (fold-test--with
    (should (equal (drgnx-fold--kinds-here) '(block)))
    (drgnx-fold-fold-kind 'block)
    (should (= (length (drgnx-fold--overlays)) 3))
    (drgnx-fold-unfold-all)
    (drgnx-fold-fold-kind 'function)
    (should-not (drgnx-fold--overlays))
    (should-error (drgnx-fold-fold-kind 'nonsense) :type 'user-error)))

(ert-deftest drgnx-fold/focus-leaves-exactly-the-ranges-holding-point ()
  "Fold All Except Here folds every range but those holding point, and unfolds those; Unfold All Except Here
unfolds every fold but those holding point."
  (fold-test--with
    (goto-char (fold-test--line 6))
    (drgnx-fold-fold)
    (goto-char (fold-test--line 4))
    (drgnx-fold-fold-focus)
    ;; a and its `if' hold point: shown; b folded
    (should (equal (fold-test--hidden) '(7)))
    (let ((shown (seq-remove #'drgnx-fold--overlay-of (drgnx-fold-ranges))))
      (should (equal (mapcar #'car shown) (list (fold-test--line 1) (fold-test--line 3)))))
    (drgnx-fold-unfold-focus)
    (should-not (drgnx-fold--overlays))))

(ert-deftest drgnx-fold/a-manual-fold-is-made-named-and-removed ()
  "Create Fold from Selection makes a manual fold (the model's source 5) and folds it; it wins on its line; Name Fold
shows the name; Remove Manual Fold drops it from the model."
  (fold-test--with
    (transient-mark-mode 1)
    (goto-char (fold-test--line 2))
    (set-mark (point))
    (goto-char (fold-test--line 4))
    (drgnx-fold-create (region-beginning) (region-end) nil)
    (should (equal (fold-test--hidden) '(3)))
    (should (seq-find (lambda (r) (= (nth 4 r) 5)) (drgnx-fold-ranges)))
    (goto-char (fold-test--line 2))
    (drgnx-fold-rename "setup")
    (should (string-match-p "setup" (overlay-get (car (drgnx-fold--overlays)) 'display)))
    (drgnx-fold-unfold)
    ;; on its line the manual fold wins over the larger ranges around
    (drgnx-fold-fold)
    (should (equal (fold-test--hidden) '(3)))
    (drgnx-fold-remove)
    (should-not (drgnx-fold--overlays))
    (should-not (seq-find (lambda (r) (= (nth 4 r) 5)) (drgnx-fold-ranges)))))

(ert-deftest drgnx-fold/next-and-previous-go-to-fold-starts ()
  (fold-test--with
    (goto-char (fold-test--line 2))
    (drgnx-fold-next)
    (should (= (line-number-at-pos) 3))
    (drgnx-fold-next)
    (should (= (line-number-at-pos) 6))
    (should-error (drgnx-fold-next) :type 'user-error)
    (drgnx-fold-previous)
    (should (= (line-number-at-pos) 3))))

(ert-deftest drgnx-fold/folds-follow-edits ()
  "A fold keeps its lines through a line typed above it; the model's hidden range moves with it."
  (fold-test--with
    (goto-char (fold-test--line 6))
    (drgnx-fold-fold)
    (goto-char (point-min))
    (insert "import os\n")
    (should (equal (cl-loop for n from 1 to 8 when (invisible-p (fold-test--line n)) collect n) '(8)))
    (should (= (fold-test--model-hidden) 1))))

(ert-deftest drgnx-fold/isearch-opens-a-fold-it-passes ()
  (fold-test--with
    (drgnx-fold-fold)
    (let ((ov (car (drgnx-fold--overlays))))
      (funcall (overlay-get ov 'isearch-open-invisible-temporary) ov nil)
      (should-not (overlay-get ov 'invisible))
      (funcall (overlay-get ov 'isearch-open-invisible-temporary) ov t)
      (should (overlay-get ov 'invisible))
      (funcall (overlay-get ov 'isearch-open-invisible) ov))
    (should-not (drgnx-fold--overlays))
    (should (= (fold-test--model-hidden) 0))))

(ert-deftest drgnx-fold/org-folds-its-own-headings ()
  (with-temp-buffer
    (insert "* a\nx\n* b\ny\n")
    (org-mode)
    (goto-char (point-min))
    (drgnx-fold-fold-all)
    (should (invisible-p (fold-test--line 2)))
    (drgnx-fold-unfold-all)
    (should-not (invisible-p (fold-test--line 2)))
    (drgnx-fold-fold)
    (should (invisible-p (fold-test--line 2)))
    (should-not (drgnx-fold--overlays))))

(ert-deftest drgnx-fold/evil-fold-keys-act-on-drgnx-folds ()
  "drgnx's folds go first in evil's fold list, once, and come out again."
  (let ((l (drgnx-fold--with-provider (drgnx-fold--with-provider '(((hs-minor-mode) :close hs-hide-block))))))
    (should (equal (car (car l)) '(drgnx-fold-mode)))
    (should (eq (plist-get (cdr (car l)) :close) 'drgnx-fold-fold))
    (should (= (length l) 2))
    (should (equal (drgnx-fold--without-provider l) '(((hs-minor-mode) :close hs-hide-block))))))

(ert-deftest drgnx-fold/the-module-sets-up-and-turns-off ()
  (drgnx-test-with-modules '(editor/fold) :strict t
                           (should (drgnx-commands-get 'edit-fold))
                           (should (drgnx-commands-get 'fold-focus))
                           (should drgnx-fold-mode))
  (should-not drgnx-fold-mode)
  (should-not (drgnx-commands-get 'edit-fold)))

;;; fold-test.el ends here
