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
(declare-function nidhogg-treesit-refold "treesit.c" (parser))
(declare-function treesit-parser-create "treesit.c" (language &optional buffer no-reuse tag))
(defvar treesit-extra-load-path)
(defvar drgnx-hub--events)
(defvar drgnx-minimap--watched)
(defvar drgnx-ruler--marks)
(defvar drgnx-fold-source)
(defvar drgnx-fold-remember)
(defvar drgnx-fold-summary)

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

(ert-deftest drgnx-fold/the-summary-counts-the-hidden-problems-and-agent-edits ()
  "Under `full' a fold's summary adds the errors, warnings and agent edits on its hidden lines (`✕ 1 ⚠ 2 ✦ 1'),
each only when there is one, and none outside the fold; under `lines' only the count."
  (fold-test--with
    (require 'drgnx-marks)
    (setq drgnx-ruler--marks
          (mapcar (lambda (m) (list (fold-test--line (car m)) 0 'error 0 'bar nil (cdr m)))
                  '((2 . agent) (3 . error) (4 . warning) (4 . warning) (6 . error) (7 . agent))))
    (drgnx-fold-fold)
    (let ((ov (car (drgnx-fold--overlays))))
      (should (string-match-p "⋯ 4 lines ✕ 1 ⚠ 2 ✦ 1 " (overlay-get ov 'display)))
      (let ((drgnx-fold-summary 'lines))
        (should (string-match-p "⋯ 4 lines $" (drgnx-fold--summary ov)))))
    (drgnx-fold-unfold)
    ;; only warnings hidden: no error or agent count
    (setq drgnx-ruler--marks (list (list (fold-test--line 4) 0 'warning 0 'bar nil 'warning)))
    (drgnx-fold-fold)
    (should (string-match-p "⋯ 4 lines ⚠ 1 $" (overlay-get (car (drgnx-fold--overlays)) 'display)))))

(defmacro fold-test--with-hub (&rest body)
  "BODY as `fold-test--with', the buffer visiting FILE (a temporary .txt, no parser), the hub's connection taken as
up: CALLS holds the `minimap/watch' params sent, oldest first; TOOK is what `nidhogg-lines-take-hub-folds' gives
\(its real value when `real')."
  (declare (indent 0))
  `(let ((calls nil) (took 'real) (file (make-temp-file "drgnx-fold" nil ".txt"))
         (real-take (symbol-function 'nidhogg-lines-take-hub-folds))
         (drgnx-hub--events 'fold-test-hub) (drgnx-fold-remember nil))
     (unwind-protect
         (cl-letf* (((symbol-function 'drgnx-fold--hub-p) (lambda () t))
                    ((symbol-function 'nidhogg-lines-take-hub-folds)
                     (lambda (b f) (if (eq took 'real) (funcall real-take b f) took)))
                    ((symbol-function 'drgnx-hub--call-on)
                     (lambda (_proc method params &rest _)
                       (when (equal method "minimap/watch") (setq calls (append calls (list params)))))))
           (fold-test--with
             (setq buffer-file-name file)
             ,@body))
       (delete-file file))))

(ert-deftest drgnx-fold/a-buffer-with-no-parser-folds-by-the-hubs-layer ()
  "In `auto', a file's buffer with no parser asks the hub to watch its file (one `minimap/watch') at its first fold
command and takes the hub's ranges; while the hub has none, indentation folds it and a fold command works; with the
hub's ranges, indentation is off."
  (skip-unless (fboundp 'nidhogg-lines-take-hub-folds))
  (fold-test--with-hub
    (drgnx-fold-fold)
    (should (equal (fold-test--hidden) '(2 3 4 5)))
    (should (equal calls (list (list :file (file-truename file) :on t))))
    (should (eq drgnx-fold--sources 'hub))
    (should (= (plist-get (nidhogg-lines-describe) :folds) 3))
    (drgnx-fold-unfold)
    ;; the hub's layer came: indentation goes; the watch is not sent again
    (setq took t)
    (drgnx-fold-ranges)
    (should (= (plist-get (nidhogg-lines-describe) :folds) 0))
    (should (= (length calls) 1))))

(ert-deftest drgnx-fold/the-hub-watch-stops-with-folding ()
  "The folds' watch ends (`:on :false') when the buffer leaves the hub's source (`indent'), when it is killed and when
the module is turned off; a watch the minimap holds on the same file is left on, and the minimap's own end keeps the
watch while folding takes the layer."
  (skip-unless (fboundp 'nidhogg-lines-take-hub-folds))
  (fold-test--with-hub
    (let ((on (list :file (file-truename file) :on t)) (off (list :file (file-truename file) :on :false)))
      (drgnx-fold-ranges)
      (let ((drgnx-fold-source 'indent)) (drgnx-fold-ranges))
      (should (equal calls (list on off)))
      (should (eq drgnx-fold--sources 'indent))
      ;; killed
      (drgnx-fold-ranges)
      (drgnx-fold--killed)
      (should (equal calls (list on off on off)))
      ;; the minimap watches the file too: folding sends nothing, and leaves it on
      (setq calls nil drgnx-fold--sources nil)
      (setq-local drgnx-minimap--watched (file-truename file))
      (drgnx-fold-ranges)
      (drgnx-fold--watch nil)
      (should-not calls)
      ;; the minimap ends its watch while folding takes the layer: the watch stays on, without the heat
      (drgnx-fold-ranges)
      (load (expand-file-name "modules/editor/drgnx-minimap" drgnx-dir) nil t)
      (cl-letf (((symbol-function 'drgnx-minimap--hub-p) (lambda () t)))
        (drgnx-minimap--watch (current-buffer) nil))
      (should (equal calls (list on)))
      ;; the module off: the watch ends
      (kill-local-variable 'drgnx-minimap--watched)
      (drgnx-fold-ranges)
      (let ((drgnx-fold-source 'indent)) (drgnx-fold-ranges))
      (setq calls nil)
      (drgnx-test-with-modules '(editor/fold) (drgnx-fold-ranges) (should (equal calls (list on))))
      (should (equal calls (list on off))))))

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
    (goto-char (fold-test--line 1))
    (set-mark (point))
    (goto-char (fold-test--line 3))
    (drgnx-fold-create (region-beginning) (region-end) nil)
    (should (equal (fold-test--hidden) '(2)))
    (should (seq-find (lambda (r) (= (nth 4 r) 5)) (drgnx-fold-ranges)))
    (goto-char (fold-test--line 1))
    (drgnx-fold-rename "setup")
    (should (string-match-p "setup" (overlay-get (car (drgnx-fold--overlays)) 'display)))
    (drgnx-fold-unfold)
    ;; on its line the manual fold wins over the larger range starting there too (a, lines 1-5)
    (drgnx-fold-fold)
    (should (equal (fold-test--hidden) '(2)))
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

;;;; Tree-sitter folds

(defun fold-test--python-grammar-p ()
  "Whether a python grammar is here: on the load path, or in the folder DRGNX_TEST_TS_GRAMMARS names (the pack job's,
which `bin/drgnx test --container' builds).  A grammar that was promised (that variable, or DRGNX_TEST_TS_REQUIRED in
CI) and is not loadable fails: a skip would hide its absence."
  (when-let* ((dir (getenv "DRGNX_TEST_TS_GRAMMARS")) ((file-directory-p dir)))
    (add-to-list 'treesit-extra-load-path dir))
  (let ((here (and (fboundp 'treesit-available-p) (treesit-available-p) (treesit-language-available-p 'python))))
    (when (and (not here) (or (getenv "DRGNX_TEST_TS_GRAMMARS") (getenv "DRGNX_TEST_TS_REQUIRED")))
      (ert-fail "a python grammar was promised (DRGNX_TEST_TS_GRAMMARS or DRGNX_TEST_TS_REQUIRED) and is not loadable"))
    here))

(defconst fold-test--python
  "class Point:\n    def norm(self):\n        return 1\ndef test_norm():\n    assert True\n"
  "A class (lines 1–3) holding a method (2–3), and a test (4–5).")

(defun fold-test--ts-ranges ()
  "The buffer's fold ranges as (LINE KIND SOURCE), LINE its first line."
  (mapcar (lambda (r) (list (line-number-at-pos (nth 0 r)) (aref drgnx-fold-kinds (nth 2 r)) (nth 4 r)))
          (drgnx-fold-ranges)))

(ert-deftest drgnx-fold/a-tree-sitter-buffer-folds-by-its-packs-query ()
  "A buffer with a tree-sitter parser folds by its pack's `folds.scm', run by Nidhogg at each reparse: kinds from
the query (a `test_' function a test), no indentation ranges; an edit's new range arrives with the next command; the
`indent' setting takes the query and its ranges away again."
  (skip-unless (and (fboundp 'nidhogg-treesit-refold) (fboundp 'nidhogg-lines-set-fold-sources)))
  (skip-unless (fold-test--python-grammar-p))
  (clrhash drgnx-fold--queries)
  (with-temp-buffer
    (insert fold-test--python)
    (prog-mode)
    (treesit-parser-create 'python)
    (unwind-protect
        (progn
          (should (eq (drgnx-fold--wanted) 'treesit))
          (should (equal (fold-test--ts-ranges) '((1 class 0) (2 function 0) (4 test 0))))
          (should (local-variable-p 'nidhogg-treesit-fold-query))
          (drgnx-fold-fold-kind 'test)
          (should (equal (fold-test--hidden) '(5)))
          (drgnx-fold-unfold-all)
          (goto-char (point-max))
          (insert "def b():\n    return [\n        1,\n    ]\n")
          (should (equal (fold-test--ts-ranges) '((1 class 0) (2 function 0) (4 test 0) (6 function 0) (7 block 0))))
          (let ((drgnx-fold-source 'indent))
            (should-not (seq-find (lambda (r) (eq (nth 2 r) 0)) (fold-test--ts-ranges)))
            (should-not (local-variable-p 'nidhogg-treesit-fold-query))))
      (nidhogg-lines-disable))))

(ert-deftest drgnx-fold/a-pack-without-folds-scm-folds-its-definitions ()
  "A pack's `tags.scm' as a fold query: functions, methods, macros and constructors fold as functions, the type-like
definitions as classes, any other definition as a block; a reference folds nothing."
  (should (equal (drgnx-fold--tags-query
                  "(f) @definition.function (m) @definition.method (c) @definition.class (i) @definition.impl
(k) @definition.constant (r) @reference.call (n) @name")
                 "(f) @fold.function (m) @fold.function (c) @fold.class (i) @fold.class
(k) @fold (r) @reference.call (n) @name")))

;;; fold-test.el ends here
