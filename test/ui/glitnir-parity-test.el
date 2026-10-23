;;; glitnir-parity-test.el --- GUI tests: Glitnir's picture equals the stock picture (PD-9) -*- lexical-binding: t -*-

;; Parity of Glitnir (the compositor) with the stock path, in the parts the plan (PD-9) can prove at run time:
;; (c) with `glitnir-enable' nil the snapshot equals `x-export-frames' (scale 1 only: the export is a 1x picture);
;; (d) the snapshot with Glitnir on equals the one with it off, after typing, scrolling and a popup shown and hidden;
;; (b) with it off no call is made into Glitnir; and the panic fallback leaves the picture the stock path draws.
;; Each skips unless Glitnir is active and the pinned child-frame packages are present (so on a stock Nidhogg they are
;; skipped).  The fixture has no chrome (`child-frame-chrome' nil): the pictures must be the same, pixel for pixel.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-uitest)

(defvar glitnir-debug)
(defvar glitnir-enable)
(defvar child-frame-chrome)
(defvar corfu-auto)
(defvar corfu--frame)
(defvar corfu-popupinfo-delay)
(declare-function corfu-quit "corfu")
(declare-function corfu-mode "corfu")
(declare-function corfu-popupinfo-mode "corfu-popupinfo")
(declare-function glitnir-stats "glitnir")
(declare-function glitnir--calls "glitnir")
(declare-function glitnir--debug-panic "glitnir")
(declare-function glitnir-active-p "glitnir")
(declare-function drgnx-quickhelp-show "drgnx-quickhelp")
(declare-function drgnx-quickhelp-hide "drgnx-quickhelp")
(declare-function drgnx-quickhelp-shown-p "drgnx-quickhelp")
(declare-function drgnx-quickhelp--unmap "drgnx-quickhelp")

(defconst drgnx-test-glitnir--repo           ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d (quote ("core" "wb" "harness")))
  (add-to-list (quote load-path) (expand-file-name d drgnx-test-glitnir--repo)))
(dolist (m (quote ("ui/drgnx-face" "ui/drgnx-quickhelp")))
  (load (expand-file-name (concat "modules/" m) drgnx-test-glitnir--repo) nil t))

;;;; Helpers

(defmacro drgnx-test-glitnir--skip-unless-ready ()
  "Skip the test unless Glitnir is active and the pinned packages are on `load-path'.
A macro: `skip-unless' exists only inside the body of `ert-deftest'."
  '(progn (skip-unless (drgnx-uitest-glitnir-p))
          (skip-unless (drgnx-uitest-childframe-packages))))

(defun drgnx-test-glitnir--settle ()
  "Redisplay, wait, and clear the echo area (a message would be in one picture and not the other)."
  (redisplay t)
  (sit-for 0.3)
  (message nil)
  (redisplay t))

(defun drgnx-test-glitnir--wait-for (pred &optional timeout)
  "Redisplay until PRED is non-nil or TIMEOUT (default 3) seconds pass; PRED's value."
  (let ((end (+ (float-time) (or timeout 3))) v)
    (while (and (not (setq v (funcall pred))) (< (float-time) end))
      (redisplay t) (sit-for 0.05))
    v))

(defun drgnx-test-glitnir--rect (snap)
  "SNAP's whole picture as (L T R B)."
  (list 0 0 (nth 0 snap) (nth 1 snap)))

(defun drgnx-test-glitnir--diff (a b &optional skip)
  "Nil when snapshots A and B are the same size and agree on every RGB channel of every pixel (alpha ignored).
Pixels inside the rectangles SKIP (L T R B each, right and bottom exclusive) are not compared.
Else a plist (:pixels N :box (L T R B) :first (X Y A-PIXEL B-PIXEL)) of the differing pixels, or (:size A B).
Rows are compared whole first, so equal pictures cost one string compare a row."
  (if (not (equal (seq-take a 2) (seq-take b 2)))
      (list :size (seq-take a 2) (seq-take b 2))
    (pcase-let* ((`(,w ,h ,ba) a) (bb (nth 2 b)) (n 0) (box nil) (first nil) (rows nil)
                 (alpha (if (eq (byteorder) ?l) 3 0)))
      (cl-loop for y below h while (< n 5000) do         ; (a whole-frame diff is slow)
               (let ((s (* 4 w y)) (e (* 4 w (1+ y))))
                 (unless (string= (substring ba s e) (substring bb s e))
                   (when (< (length rows) 60) (push y rows))
                   (dotimes (x w)
                     (let ((o (+ s (* 4 x))) (differs nil))
                       (dotimes (c 4)
                         (when (and (/= c alpha) (/= (aref ba (+ o c)) (aref bb (+ o c)))) (setq differs t)))
                       (when (and differs
                                  (not (cl-some (lambda (r) (and (<= (nth 0 r) x) (< x (nth 2 r)) (<= (nth 1 r) y) (< y (nth 3 r))))
                                                skip)))
                         (setq n (1+ n))
                         (unless first
                           (setq first (list x y (drgnx-uitest-pixel a x y) (drgnx-uitest-pixel b x y))))
                         (setq box (if box
                                       (list (min (nth 0 box) x) (min (nth 1 box) y) (max (nth 2 box) (1+ x)) (max (nth 3 box) (1+ y)))
                                     (list x y (1+ x) (1+ y))))))))))
      (and (> n 0) (list :pixels n :box box :first first :rows (nreverse rows))))))

(defun drgnx-test-glitnir--same-p (a b)
  "Non-nil when snapshots A and B are the same size and agree on every RGB channel of every pixel."
  (null (drgnx-test-glitnir--diff a b)))

(defun drgnx-test-glitnir--candidates (candidates doc)
  "Make corfu in the current buffer complete to CANDIDATES, each documented by DOC."
  (setq-local completion-at-point-functions
              (list (lambda ()
                      (when-let* ((b (bounds-of-thing-at-point 'symbol)))
                        (list (car b) (cdr b) candidates
                              :exclusive 'no
                              :company-doc-buffer
                              (lambda (_c)
                                (with-current-buffer (get-buffer-create " *parity-doc*")
                                  (erase-buffer) (insert doc) (current-buffer)))))))))

(defun drgnx-test-glitnir--show-popups ()
  "At the end of the buffer type `car' on a new line, open corfu on it and quick help for it; wait until both are up."
  (goto-char (point-max))
  (drgnx-uitest-run (drgnx-uitest-type-events "\n(car ca"))
  (drgnx-uitest-run (drgnx-uitest-key-events "C-M-i"))        ; through the command loop: corfu's UI is a post-command-hook
  (should (drgnx-test-glitnir--wait-for
           (lambda () (and (frame-live-p corfu--frame) (frame-visible-p corfu--frame)))))
  (call-interactively #'drgnx-quickhelp-show)
  (should (drgnx-test-glitnir--wait-for #'drgnx-quickhelp-shown-p))
  (drgnx-test-glitnir--settle))

(defun drgnx-test-glitnir--hide-popups ()
  (ignore-errors (corfu-quit))
  (drgnx-quickhelp-hide)
  (drgnx-quickhelp--unmap)
  (drgnx-test-glitnir--settle))

(defmacro drgnx-test-glitnir--with-fixture (&rest body)
  "Run BODY on a bare root frame, no chrome, in a fixture buffer with corfu and quick help available.
The fixture is 60 lines of Lisp (so it scrolls) with the cursor on the last line; popups are shown by BODY."
  (declare (indent 0))
  `(let ((glitnir-debug nil) (child-frame-chrome nil))
     (drgnx-test-glitnir--skip-unless-ready)
     (require 'corfu) (require 'corfu-popupinfo)
     (let* ((root (drgnx-uitest-root-frame))
            (corfu-auto nil) (corfu-popupinfo-delay '(0.0 . 0.0))
            (buf (generate-new-buffer "parity-fixture.el")))
       (drgnx-uitest-bare-frame)
       (unwind-protect
           (with-selected-frame root
             (delete-other-windows)
             (switch-to-buffer buf)
             (dotimes (i 60) (insert (format "(defun fixture-%d (x) \"A function.\" (car (cdr x)))\n" i)))
             (emacs-lisp-mode)
             (drgnx-test-glitnir--candidates '("car-alpha" "car-beta" "car-gamma") "Documentation.")
             (corfu-mode 1)
             (message nil)
             (drgnx-test-glitnir--settle)
             ,@body)
         (ignore-errors (drgnx-test-glitnir--hide-popups))
         (ignore-errors (corfu-mode -1))
         (setq glitnir-enable t)
         (when (buffer-live-p buf) (with-current-buffer buf (set-buffer-modified-p nil)) (kill-buffer buf))
         (message nil)))))

(defun drgnx-test-glitnir--off-snapshot (root)
  "ROOT's snapshot with Glitnir off (stock painting after a full redraw); Glitnir is left off."
  (setq glitnir-enable nil)
  (redraw-frame root)
  (drgnx-test-glitnir--settle)
  (drgnx-uitest-snapshot root))

(defun drgnx-test-glitnir--on-snapshot (root)
  "ROOT's snapshot with Glitnir on again (a full redraw first)."
  (setq glitnir-enable t)
  (redraw-frame root)
  (drgnx-test-glitnir--settle)
  (should (glitnir-active-p))
  (drgnx-uitest-snapshot root))

(defun drgnx-test-glitnir--scene (root)
  "Type, scroll, and show and hide the popups, in whatever state `glitnir-enable' is.  Return ROOT."
  (drgnx-uitest-run (drgnx-uitest-type-events "xyz "))
  (drgnx-test-glitnir--settle)
  (goto-char (point-min))
  (dotimes (_ 3) (scroll-up-command 10) (redisplay t))
  (scroll-down-command 4)
  (drgnx-test-glitnir--settle)
  (goto-char (point-max))
  (drgnx-test-glitnir--show-popups)
  (drgnx-test-glitnir--hide-popups)
  (goto-char (point-max))
  (drgnx-uitest-run (drgnx-uitest-type-events "ab"))
  (drgnx-test-glitnir--settle)
  (redisplay t)
  root)

;;;; Tests

(defun drgnx-test-glitnir--child-rects (root)
  "The visible child frames of ROOT as (L T R B) in its device pixels."
  (let ((s (frame-scale-factor root)) (p (frame-edges root 'native-edges)))
    (mapcar (lambda (c)
              (let ((e (frame-edges c 'outer-edges)))
                (mapcar (lambda (v) (round (* s v)))
                        (list (- (nth 0 e) (nth 0 p)) (- (nth 1 e) (nth 1 p))
                              (- (nth 2 e) (nth 0 p)) (- (nth 3 e) (nth 1 p))))))
            (drgnx-uitest-child-frames root))))

(ert-deftest drgnx-ui-glitnir/off-equals-export-at-scale-1 ()
  "(c): Glitnir off, a bare frame with a corfu popup and quick help: the snapshot is `x-export-frames', RGB.
The export draws the root frame alone, not its child frames, so the popups' rectangles are left out of the
comparison (and must differ there: the snapshot shows the popups)."
  (skip-unless (= (frame-scale-factor (drgnx-uitest-root-frame)) 1))
  (drgnx-test-glitnir--with-fixture
    (drgnx-test-glitnir--show-popups)
    (should (frame-visible-p corfu--frame))
    (should (drgnx-quickhelp-shown-p))
    (let* ((rects (drgnx-test-glitnir--child-rects root))
           (snap (drgnx-test-glitnir--off-snapshot root))
           (exp (drgnx-uitest-export root)))
      (should (>= (length rects) 2))
      (should-not (glitnir-active-p))
      (should (equal (seq-take snap 2) (seq-take exp 2)))
      (should-not (drgnx-test-glitnir--diff snap exp rects))
      (should (drgnx-test-glitnir--diff snap exp)))))

(ert-deftest drgnx-ui-glitnir/on-equals-off ()
  "(d): the same fixture without chrome, typed keys, scrolls and a popup shown and hidden: on = off, tolerance 0."
  (drgnx-test-glitnir--with-fixture
    (drgnx-test-glitnir--scene root)
    ;; the popups hidden
    (let ((on (drgnx-test-glitnir--on-snapshot root)))
      (should-not (drgnx-test-glitnir--diff on (drgnx-test-glitnir--off-snapshot root))))
    ;; and shown: the picture with the popups
    (setq glitnir-enable t)
    (goto-char (point-max))
    (drgnx-test-glitnir--show-popups)
    (should (frame-visible-p corfu--frame))
    (let ((on (drgnx-test-glitnir--on-snapshot root)))
      (should-not (drgnx-test-glitnir--diff on (drgnx-test-glitnir--off-snapshot root))))))

(ert-deftest drgnx-ui-glitnir/off-makes-no-calls ()
  "(b): with `glitnir-enable' nil, `(glitnir--calls)' is unchanged over typing, scrolling and a popup, none composed."
  (drgnx-test-glitnir--with-fixture
    (glitnir-stats root t)                     ; empty the record
    (setq glitnir-enable nil)
    (drgnx-test-glitnir--settle)
    (should-not (glitnir-active-p))
    (let ((calls (glitnir--calls)))
      (drgnx-test-glitnir--scene root)
      (goto-char (point-max))
      (drgnx-test-glitnir--show-popups)
      (should (= calls (glitnir--calls)))
      ;; the stock path still records its paints (`:count'), but composes nothing
      (should (equal (plist-get (glitnir-stats root) :compose-ms) '(:p50 0.0 :p95 0.0 :max 0.0))))))

(ert-deftest drgnx-ui-glitnir/panic-equals-off ()
  "After `(glitnir--debug-panic 'draw)' the picture is the one the stock path draws."
  (drgnx-test-glitnir--with-fixture
    (drgnx-test-glitnir--scene root)
    (goto-char (point-max))
    (drgnx-test-glitnir--show-popups)
    (let ((off (drgnx-test-glitnir--off-snapshot root)) (panicked nil))
      (setq glitnir-enable t)
      (drgnx-test-glitnir--settle)
      (should (glitnir-active-p))
      (unwind-protect
          (let ((glitnir-debug 'verify))
            (glitnir--debug-panic 'draw)
            (redraw-frame root)
            (drgnx-test-glitnir--settle)
            (should-not (glitnir-active-p))
            (setq panicked t)
            (should-not (drgnx-test-glitnir--diff (drgnx-uitest-snapshot root) off)))
        (let ((glitnir-debug 'verify)) (glitnir--debug-panic 'revive))
        (redraw-frame root) (redisplay t) (sit-for 0.2))
      (should panicked)
      (should (glitnir-active-p)))))

;;; glitnir-parity-test.el ends here
