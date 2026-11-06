;;; look-bars-layout-test.el --- the status bar and the top line lay out in pixels -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): the layout is a function of the segments, a measure function and a pixel budget.  The tests
;; inject the measure (`drgnx-look-bars-measure-function': ten pixels a column), so no font or display is needed.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/unit/mod-statusbar-test" drgnx-dir) nil t)   ; its fixtures: segments a b c, the store
(load (expand-file-name "test/unit/mod-topline-test" drgnx-dir) nil t)     ; its fixtures: the line's registry and buffer
(load (expand-file-name "modules/ui/drgnx-look-density" drgnx-dir) nil t)

(defvar text-scale-mode-amount)
(defvar text-scale-mode)

(defun drgnx-look-bars-test--ten(string &optional _face)
  "A measure: ten pixels a column."
  (* 10 (string-width string)))

(defun drgnx-look-bars-test--plain (s)
  (substring-no-properties s))

(ert-deftest drgnx-look-bars/drop-order-by-pixels ()
  "Pattern D: with a measure that gives ten pixels a column, the segments dropped for three budgets are those
`drgnx-statusbar-drop-order' says: B first, then A; C (the right) stays."
  (drgnx-statusbar-test--with
    (let ((drgnx-look-bars-measure-function #'drgnx-look-bars-test--ten)
          (drgnx-statusbar-drop-order '(b a)))
      ;; widths: A 10, the separator 30, B 10, C 10, the padding 24, two spaces between 20 (one space with no left)
      (dolist (row '((200 "A" "B" "C") (90 "A" nil "C") (50 nil nil "C")))
        (let ((plain (drgnx-look-bars-test--plain (drgnx-statusbar-render (car row)))))
          (should (eq (and (string-match-p "A" plain) t) (and (nth 1 row) t)))
          (should (eq (and (string-match-p "B" plain) t) (and (nth 2 row) t)))
          (should (string-match-p "C" plain)))))))

(ert-deftest drgnx-look-bars/right-gap-is-in-pixels ()
  "Pattern D: the gap before the right segments is `(space :align-to (- right (PIXELS)))', PIXELS the right run and
the padding as measured, less the window's right fringe (`right' in a mode line stops at the fringe)."
  (drgnx-statusbar-test--with
    (let* ((drgnx-look-bars-measure-function #'drgnx-look-bars-test--ten)
           (pad (round (* (drgnx-look-density-value 'panel-padding) (drgnx-statusbar--scale nil))))
           (gap (drgnx-statusbar-test--gap (drgnx-statusbar-render 400))))
      (should (equal (plist-get (cdr gap) :align-to) `(- right (,(max 0 (- (+ 10 pad) (drgnx-statusbar--right-fringe (selected-window)))))))))))

(ert-deftest drgnx-look-bars/key-changes-with-width ()
  "Pattern D: the top line's items are not `equal' for another pixel width or another measure, and are `equal'
for the same ones (the tab bar redraws only when its items differ)."
  (drgnx-topline-test--with 'vscode
    (let ((buf (current-buffer)))
      (let ((a (let ((drgnx-look-bars-measure-function #'drgnx-look-bars-test--ten)) (drgnx-topline--build buf 80 nil 800)))
            (a2 (let ((drgnx-look-bars-measure-function #'drgnx-look-bars-test--ten)) (drgnx-topline--build buf 80 nil 800)))
            (b (let ((drgnx-look-bars-measure-function #'drgnx-look-bars-test--ten)) (drgnx-topline--build buf 80 nil 900)))
            (c (let ((drgnx-look-bars-measure-function (lambda (s &optional _f) (* 11 (string-width s)))))
                 (drgnx-topline--build buf 80 nil 800))))
        (should (equal a a2))
        (should-not (equal a b))
        (should-not (equal a c))))))

(ert-deftest drgnx-look-bars/no-measure-in-eval ()
  "Pattern D: the mode line's `:eval' measures when the bar's memo changes and never otherwise: a second
evaluation with nothing changed calls the measure function zero times."
  (drgnx-statusbar-test--with
    (let ((calls 0))
      (let ((drgnx-look-bars-measure-function (lambda (s &optional _f) (cl-incf calls) (* 10 (string-width s)))))
        (drgnx-statusbar-test--in-buffer 'emacs-lisp-mode
          (let ((first (drgnx-statusbar-mode-line)))
            (should (stringp first))
            (should (> calls 0))
            (setq calls 0)
            (should (eq first (drgnx-statusbar-mode-line)))
            (should (= 0 calls))))))))

(ert-deftest drgnx-look-bars/a-scale-or-font-change-lays-out-again ()
  "Pattern D: a scale, a text scale or a font-role change moves the bar's layout key, so the memo builds it again."
  (drgnx-statusbar-test--with
    (let ((drgnx-look-bars-measure-function #'drgnx-look-bars-test--ten)
          (w (selected-window)))
      (let ((k (drgnx-statusbar--layout-key w)))
        (should (eq k (drgnx-statusbar--layout-key w)))
        (cl-letf (((symbol-function 'frame-char-height) (lambda (&optional _f) 40)))
          (should-not (eq k (drgnx-statusbar--layout-key w))))
        (let ((drgnx-pixels-generation (1+ drgnx-pixels-generation)))
          (should-not (eq k (drgnx-statusbar--layout-key w))))
        (let ((text-scale-mode-amount 2) (text-scale-mode t))
          (should-not (eq k (drgnx-statusbar--layout-key w))))))))

(defun drgnx-look-bars-test--reaches (face target)
  "Non-nil when FACE inherits TARGET, directly or through the faces it inherits."
  (let ((parents (ensure-list (face-attribute face :inherit nil nil))))
    (or (memq target parents)
        (seq-some (lambda (p) (and (facep p) (drgnx-look-bars-test--reaches p target))) parents))))

(defun drgnx-look-bars-test--first-face (s)
  (let ((f (get-text-property 0 'face s))) (if (listp f) (car f) f)))

(ert-deftest drgnx-look-bars/segment-faces ()
  "Pattern D: the status faces the segments use do not reach the attention face; only the needs-you face does.
The tests segment uses the ok and fail faces."
  (dolist (f '(drgnx-status-ok drgnx-status-warn drgnx-status-fail drgnx-status-info))
    (should-not (drgnx-look-bars-test--reaches f 'drgnx-status-attention)))
  (should (drgnx-look-bars-test--reaches 'drgnx-statusbar-waiting 'drgnx-status-attention))
  (drgnx-statusbar-test--with
    (let ((drgnx-statusbar-tests-state '(:passed 3 :failed 0)))
      (drgnx-statusbar--bump)
      (should (eq 'drgnx-status-ok (drgnx-look-bars-test--first-face (drgnx-statusbar--seg-tests)))))
    (let ((drgnx-statusbar-tests-state '(:passed 3 :failed 2)))
      (drgnx-statusbar--bump)
      (should (eq 'drgnx-status-fail (drgnx-look-bars-test--first-face (drgnx-statusbar--seg-tests)))))))

(ert-deftest drgnx-look-bars/magit-gets-the-bar ()
  "Pattern D: a buffer in a mode derived from `special-mode' (Magit's, Help's) gets the bar too, with the `mode'
segment showing its `mode-name'; it does not show the stock mode line."
  (drgnx-statusbar-test--with
    (let ((drgnx-statusbar-other '(mode)))
      (drgnx-statusbar-define-segment 'mode :fn #'drgnx-statusbar--seg-mode)
      (drgnx-statusbar-test--in-buffer 'special-mode
        (let ((bar (drgnx-statusbar-mode-line)))
          (should (stringp bar))
          (should (string-match-p "Special" (substring-no-properties bar)))
          (should (eq 'mode (get-text-property (string-match "Special" bar) 'drgnx-statusbar-segment bar))))))))

(provide 'look-bars-layout-test)
;;; look-bars-layout-test.el ends here
