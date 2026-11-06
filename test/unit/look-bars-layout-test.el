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

(defvar drgnx-notice--needs-you)
(defvar drgnx-topline-agents-function)

(ert-deftest drgnx-look-bars/title-row-items ()
  "Pattern D: the title row's items, in order: the project, the branch chip, the search box (it opens the palette),
the attention chip (\"1 needs you\"), the agents chip, then the window controls when drgnx draws the title."
  (drgnx-topline-test--with 'vscode
    (setq-local vc-mode " Git-main")
    (let ((drgnx-notice--needs-you 1) (drgnx-topline-agents-function (lambda () 2))
          (order '(drgnx-topline-mark drgnx-topline-branch drgnx-topline-search drgnx-topline-attention
                                      drgnx-topline-agents drgnx-topline-minimize drgnx-topline-maximize
                                      drgnx-topline-close)))
      (let* ((items (drgnx-topline--build (current-buffer) 160 t))
             (keys (mapcar #'car items)))
        (should (equal (seq-filter (lambda (k) (memq k order)) keys) order))
        (should (string-match-p "1 needs you" (nth 2 (assq 'drgnx-topline-attention items))))
        (should (string-match-p "2" (nth 2 (assq 'drgnx-topline-agents items))))
        (should (string-match-p "main" (nth 2 (assq 'drgnx-topline-branch items))))
        (should (eq 'drgnx-topline-test-palette (nth 3 (assq 'drgnx-topline-search items)))))
      ;; nothing waits and no agent runs: no chips; no drawn title: no controls
      (let* ((drgnx-notice--needs-you 0) (drgnx-topline-agents-function (lambda () 0))
             (keys (mapcar #'car (drgnx-topline--build (current-buffer) 160 nil))))
        (should-not (memq 'drgnx-topline-attention keys))
        (should-not (memq 'drgnx-topline-agents keys))
        (should-not (memq 'drgnx-topline-close keys))))))

(ert-deftest drgnx-look-bars/double-click-maximises ()
  "Pattern D: a double click on the title row's empty space is bound to the command Maximize or Restore Window
\(`title-row-maximize' in the registry), which toggles the frame's maximised state."
  (drgnx-topline-test--with 'vscode
    (drgnx-topline--on)
    ;; the tab bar's keymap (`tab-bar-map'); the global map's [tab-bar] entry is a menu item that builds a new keymap
    ;; for each lookup, so a binding put there would not stay
    (should (eq 'drgnx-topline-toggle-maximized (lookup-key tab-bar-map [double-mouse-1])))
    (let (called)
      (cl-letf (((symbol-function 'toggle-frame-maximized) (lambda (&optional _f) (setq called t))))
        (drgnx-topline-toggle-maximized))
      (should called))
    (drgnx-topline--off)
    (should-not (eq 'drgnx-topline-toggle-maximized (lookup-key tab-bar-map [double-mouse-1])))))

(ert-deftest drgnx-look-bars/title-bar-default-needs-the-shell ()
  "Pattern D: drgnx draws the title bar by default only on GNOME's window manager and only when the shell can keep an
undecorated frame's margins and corners (`nhwl-toplevel-chrome-p'); with the predicate unbound, or under another
window manager, the default is `dark'."
  (should (eq 'dark (drgnx-face-title-bar-default)))
  (cl-letf (((symbol-function 'nhwl-toplevel-chrome-p) (lambda (&optional _f) t))
            ((symbol-function 'drgnx-platform-wm) (lambda (&optional _f) 'gnome)))
    (should (eq 'drgnx (drgnx-face-title-bar-default))))
  (cl-letf (((symbol-function 'nhwl-toplevel-chrome-p) (lambda (&optional _f) t))
            ((symbol-function 'drgnx-platform-wm) (lambda (&optional _f) 'i3)))
    (should (eq 'dark (drgnx-face-title-bar-default))))
  (cl-letf (((symbol-function 'nhwl-toplevel-chrome-p) (lambda (&optional _f) nil))
            ((symbol-function 'drgnx-platform-wm) (lambda (&optional _f) 'gnome)))
    (should (eq 'dark (drgnx-face-title-bar-default)))))

(ert-deftest drgnx-look-bars/start-page-in-the-type-faces ()
  "Pattern D: the start page's name is in the title type face, its sentences in the UI text face, and its buttons
are in sentence case."
  (load (expand-file-name "modules/ui/drgnx-start" drgnx-dir) nil t)
  (should (memq 'drgnx-ui-title (ensure-list (face-attribute 'drgnx-start-title :inherit nil nil))))
  (should (memq 'drgnx-ui-text (ensure-list (face-attribute 'drgnx-start-quiet :inherit nil nil))))
  (should (equal (mapcar #'cadr drgnx-start--buttons)
                 '("Open a folder…" "Open the work graph" "All keys" "Don't show this again"))))

(defconst drgnx-look-bars-test--font-info-fields
  '(OPENED-NAME FULL-NAME SIZE HEIGHT BASELINE-OFFSET RELATIVE-COMPOSE DEFAULT-ASCENT MAX-WIDTH ASCENT DESCENT
                SPACE-WIDTH AVERAGE-WIDTH FILENAME CAPABILITY)
  "The fields of `font-info''s vector, in the order its documentation gives them.")

(ert-deftest drgnx-look-bars/font-extent-reads-ascent-and-descent ()
  "Pattern D: `drgnx-pixels-font-extent' is the ASCENT and DESCENT fields of `font-info''s documented vector.  The
fields are the ones its docstring lists; the vector gives each field a value of its own (100 plus its place)."
  (let ((doc (replace-regexp-in-string "[ \t\n]+" " " (or (documentation 'font-info) ""))))
    (should (string-match-p (regexp-quote (mapconcat #'symbol-name drgnx-look-bars-test--font-info-fields " "))
                            doc)))
  (let* ((fields drgnx-look-bars-test--font-info-fields)
         (info (apply #'vector (number-sequence 100 (+ 99 (length fields)))))
         (at (lambda (field) (aref info (seq-position fields field)))))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _d) t))
              ((symbol-function 'face-font) (lambda (&rest _) "a font"))
              ((symbol-function 'font-info) (lambda (&rest _) info)))
      (should (equal (cons (funcall at 'ASCENT) (funcall at 'DESCENT))
                     (drgnx-pixels-font-extent 'default))))))

(ert-deftest drgnx-look-bars/lead-takes-the-font-ascent ()
  "Pattern D: when the row less the text is odd (compact: 22 pixels on a 17 pixel font), the bar's lead is a spacer
whose ascent is the font's ASCENT (`drgnx-pixels-font-extent'), the box (2) and the leftover pixel (1), of the row:
not the font's MAX-WIDTH, which put the spacer wholly above the baseline and grew the bar by the descent."
  (drgnx-statusbar-test--with
    (let* ((fields drgnx-look-bars-test--font-info-fields)
           (info (apply #'vector (number-sequence 100 (+ 99 (length fields)))))
           (drgnx-look-density 'compact))
      (aset info (seq-position fields 'ASCENT) 13)
      (aset info (seq-position fields 'DESCENT) 4)
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _d) t))
                ((symbol-function 'face-font) (lambda (&rest _) "a font"))
                ((symbol-function 'font-info) (lambda (&rest _) info))
                ((symbol-function 'window-font-height) (lambda (&rest _) 17))
                ((symbol-function 'drgnx-statusbar--scale) (lambda (&optional _f) 1.0)))
        (let ((spec (get-text-property 0 'display (drgnx-statusbar--lead (selected-window) 12))))
          (should (equal '(22) (plist-get (cdr spec) :height)))
          (should (equal (ceiling (* 100.0 (+ 13 2 1)) 22) (plist-get (cdr spec) :ascent))))))))

(ert-deftest drgnx-look-bars/a-density-change-lays-the-bar-out-again ()
  "Pattern D: the bar's layout key holds its row height, so a density change builds the bar again at the new
height (the memo would keep the old box otherwise)."
  (drgnx-statusbar-test--with
    (let ((w (selected-window)) (drgnx-look-density 'comfortable))
      (let ((k (drgnx-statusbar--layout-key w)))
        (let ((drgnx-look-density 'roomy)) (should-not (eq k (drgnx-statusbar--layout-key w))))
        (let ((drgnx-look-density 'compact)) (should-not (eq k (drgnx-statusbar--layout-key w))))
        (should (eq k (drgnx-statusbar--layout-key w)))))))

(provide 'look-bars-layout-test)
;;; look-bars-layout-test.el ends here
