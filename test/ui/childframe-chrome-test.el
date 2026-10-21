;;; childframe-chrome-test.el --- GUI tests: popup chrome (Glitnir, §3.4 subset) -*- lexical-binding: t -*-

;; The four criterion-1 scenarios of the compositor design (§3.3, §3.4): real packages (corfu, corfu-popupinfo,
;; posframe, eldoc-box from `DRGNX_CHILDFRAME_ELPA') showing real child frames, probed in device pixels.  Each skips
;; unless Glitnir (the compositor) is active and the packages are present, so on a stock Nidhogg they are skipped.
;; Run with `child-frame-chrome' = drgnx's defaults and `glitnir-debug' = `verify'.

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
(defvar corfu-popupinfo-mode)
(defvar corfu-popupinfo--frame)
(defvar eldoc-box-position-function)
(declare-function posframe-show "posframe")
(declare-function posframe-hide "posframe")
(declare-function posframe-delete-all "posframe")
(declare-function posframe-poshandler-frame-bottom-right-corner "posframe")
(declare-function corfu-quit "corfu")
(declare-function corfu-mode "corfu")
(declare-function corfu-popupinfo-mode "corfu-popupinfo")
(declare-function eldoc-box--display "eldoc-box")
(declare-function eldoc-box-quit-frame "eldoc-box")
(declare-function eldoc-box--at-point-x-y-by-corfu "eldoc-box")
(declare-function eldoc-box--default-upper-corner-position-function "eldoc-box")
(declare-function glitnir-stats "glitnir")
(declare-function glitnir--stacking "glitnir")
(declare-function glitnir-refresh "glitnir")

(defconst drgnx-test-chrome--defaults
  '((corner-radius . 8) (shadow . (:blur 16 :offset (0 . 6) :spread 0 :opacity 0.35)))
  "drgnx's `child-frame-chrome' (`drgnx-look-chrome'), in logical pixels.")

(defconst drgnx-test-chrome--margin 32
  "Logical pixels around a popup that its shadow can reach (blur + offset + spread, rounded up).")

;;;; Helpers

(defmacro drgnx-test-chrome--skip-unless-ready ()
  "Skip the test unless Glitnir is active and the pinned packages are on `load-path'.
A macro: `skip-unless' exists only inside the body of `ert-deftest'."
  '(progn (skip-unless (drgnx-uitest-glitnir-p))
          (skip-unless (drgnx-uitest-childframe-packages))))

(defmacro drgnx-test-chrome--with-chrome (&rest body)
  "Run BODY on a bare root frame with the default chrome and the damage verifier on."
  (declare (indent 0))
  `(let ((glitnir-debug 'verify)
         (child-frame-chrome drgnx-test-chrome--defaults))
     (drgnx-test-chrome--skip-unless-ready)
     (drgnx-uitest-bare-frame)
     (glitnir-refresh)
     ,@body))

(defun drgnx-test-chrome--settle ()
  (redisplay t)
  (sit-for 0.3)
  (redisplay t))

(defun drgnx-test-chrome--scale (frame) (frame-scale-factor frame))

(defun drgnx-test-chrome--rect (child root)
  "CHILD's outer rectangle in ROOT's device pixels, (L T R B) with R and B exclusive."
  (let ((s (drgnx-test-chrome--scale root))
        (e (frame-edges child 'outer-edges))
        (p (frame-edges root 'native-edges)))
    (mapcar (lambda (v) (round (* s v)))
            (list (- (nth 0 e) (nth 0 p)) (- (nth 1 e) (nth 1 p))
                  (- (nth 2 e) (nth 0 p)) (- (nth 3 e) (nth 1 p))))))

(defun drgnx-test-chrome--clip (rect snap)
  "RECT (L T R B) clipped to SNAP's size."
  (list (max 0 (nth 0 rect)) (max 0 (nth 1 rect))
        (min (nth 0 snap) (nth 2 rect)) (min (nth 1 snap) (nth 3 rect))))

(defun drgnx-test-chrome--grow (rect n)
  (list (- (nth 0 rect) n) (- (nth 1 rect) n) (+ (nth 2 rect) n) (+ (nth 3 rect) n)))

(defun drgnx-test-chrome--shrink (rect n) (drgnx-test-chrome--grow rect (- n)))

(defun drgnx-test-chrome--off-snapshot (root)
  "ROOT's snapshot with Glitnir's drawing switched off (stock painting), then switched back on."
  (let ((old glitnir-enable))
    (unwind-protect
        (progn (setq glitnir-enable nil)
               (drgnx-test-chrome--settle)
               (drgnx-uitest-snapshot root))
      (setq glitnir-enable old)
      (drgnx-test-chrome--settle))))

(defun drgnx-test-chrome--check-chrome (root popups none off)
  "Assert the chrome of every frame in POPUPS (visible child frames of ROOT).
NONE is the no-popup snapshot, OFF the Glitnir-off one with the popups shown; the current picture is taken here.
Inside a popup away from its corners = OFF; the corner pixel = NONE; 4 device px outside the right edge is darker than
NONE; after the caller hides the popups it checks the no-popup picture with `drgnx-test-chrome--check-hidden'."
  (let* ((s (drgnx-test-chrome--scale root))
         (snap (drgnx-uitest-snapshot root))
         (inset (ceiling (* s (+ 8 4)))))      ; corner radius plus the anti-aliasing fringe
    (dolist (p popups)
      (let* ((r (drgnx-test-chrome--rect p root))
             (inner (drgnx-test-chrome--shrink r inset)))
        (should (drgnx-uitest-region-equal-p snap off inner :tolerance 0 :ignore-alpha t))
        (should (equal (drgnx-uitest-pixel snap (nth 0 r) (nth 1 r))
                       (drgnx-uitest-pixel none (nth 0 r) (nth 1 r))))
        (let ((x (+ (nth 2 r) 3)) (y (/ (+ (nth 1 r) (nth 3 r)) 2)))
          (when (< x (nth 0 snap))
            (should (drgnx-uitest-darker-p snap none x y))))))))

(defun drgnx-test-chrome--check-hidden (root popup-rects none)
  "Assert that POPUP-RECTS plus the shadow margin equal NONE (the no-popup snapshot) in ROOT's picture."
  (let ((snap (drgnx-uitest-snapshot root))
        (m (ceiling (* (drgnx-test-chrome--scale root) drgnx-test-chrome--margin))))
    (dolist (r popup-rects)
      (should (drgnx-uitest-region-equal-p
               snap none (drgnx-test-chrome--clip (drgnx-test-chrome--grow r m) snap)
               :tolerance 0 :ignore-alpha t)))))

(defun drgnx-test-chrome--no-violations ()
  "Assert the damage verifier found nothing (and, from Task 32, that the scene's stacking is GDK's)."
  (should (eql 0 (or (plist-get (glitnir-stats) :violations) 0))))

(defun drgnx-test-chrome--check-stacking (root popups)
  "From Task 32 on: every shown popup is in the scene's stacking list of ROOT."
  (when (fboundp 'glitnir--stacking)
    (let ((stack (glitnir--stacking root)))
      (dolist (p popups) (should (memq p stack))))))

(defun drgnx-test-chrome--complete (candidates doc)
  "Open corfu in the current buffer on CANDIDATES, each documented by DOC."
  (setq-local completion-at-point-functions
              (list (lambda ()
                      (when-let* ((b (bounds-of-thing-at-point 'symbol)))
                        (list (car b) (cdr b) candidates
                              :exclusive 'no
                              :company-doc-buffer
                              (lambda (_c)
                                (with-current-buffer (get-buffer-create " *chrome-doc*")
                                  (erase-buffer) (insert doc) (current-buffer)))))))))

(defmacro drgnx-test-chrome--with-corfu (&rest body)
  "Run BODY in a scratch buffer with corfu and corfu-popupinfo on; clean up after."
  (declare (indent 0))
  `(progn
     (require 'corfu) (require 'corfu-popupinfo)
     (let ((corfu-auto nil) (corfu-popupinfo-delay '(0.0 . 0.0)))
       (switch-to-buffer (get-buffer-create "*chrome-scratch*"))
       (erase-buffer)
       (corfu-mode 1) (corfu-popupinfo-mode 1)
       (unwind-protect (progn ,@body)
         (ignore-errors (corfu-quit))
         (corfu-popupinfo-mode -1) (corfu-mode -1)
         (kill-buffer "*chrome-scratch*")))))

(defun drgnx-test-chrome--wait-for (pred &optional timeout)
  "Redisplay until PRED is non-nil or TIMEOUT (default 3) seconds pass; PRED's value."
  (let ((end (+ (float-time) (or timeout 3))) v)
    (while (and (not (setq v (funcall pred))) (< (float-time) end))
      (redisplay t) (sit-for 0.05))
    v))

;;;; Scenarios

(ert-deftest drgnx-ui-chrome/corfu-and-popupinfo-overlap ()
  "corfu and the popupinfo beside it (their shadows overlap): chrome on both, no residue after quit."
  (drgnx-test-chrome--with-chrome
    (drgnx-test-chrome--with-corfu
      (drgnx-test-chrome--complete '("chrome-alpha" "chrome-beta" "chrome-gamma") "Documentation of the candidate.")
      (insert "chrome-")
      (drgnx-test-chrome--settle)
      (let* ((root (drgnx-uitest-root-frame))
             (none (drgnx-uitest-snapshot root))
             (corfu-frame nil) (info-frame nil))
        (completion-at-point)
        (should (drgnx-test-chrome--wait-for
                 (lambda () (and (frame-live-p corfu--frame) (frame-visible-p corfu--frame)
                                 (frame-live-p corfu-popupinfo--frame) (frame-visible-p corfu-popupinfo--frame)))))
        (setq corfu-frame corfu--frame info-frame corfu-popupinfo--frame)
        (drgnx-test-chrome--settle)
        (let* ((popups (list corfu-frame info-frame))
               (rects (mapcar (lambda (p) (drgnx-test-chrome--rect p root)) popups))
               (off (drgnx-test-chrome--off-snapshot root)))
          (drgnx-test-chrome--check-chrome root popups none off)
          ;; the lower popup's shadow also falls under the upper one's neighbour: 4 px below the lower bottom edge
          (let* ((snap (drgnx-uitest-snapshot root))
                 (lower (car (sort (copy-sequence rects) (lambda (a b) (> (nth 3 a) (nth 3 b))))))
                 (x (/ (+ (nth 0 lower) (nth 2 lower)) 2)) (y (+ (nth 3 lower) 3)))
            (when (< y (nth 1 snap)) (should (drgnx-uitest-darker-p snap none x y))))
          (drgnx-test-chrome--check-stacking root popups)
          (corfu-quit)
          (should (drgnx-test-chrome--wait-for (lambda () (not (frame-visible-p corfu-frame)))))
          (drgnx-test-chrome--settle)
          (drgnx-test-chrome--check-hidden root rects none)
          (drgnx-test-chrome--no-violations))))))

(ert-deftest drgnx-ui-chrome/posframe-show-hide-100 ()
  "A posframe shown and hidden 100 times: chrome while shown, the no-popup picture after every 25th hide."
  (drgnx-test-chrome--with-chrome
    (require 'posframe)
    (switch-to-buffer (get-buffer-create "*chrome-scratch*"))
    (erase-buffer) (insert (make-string 40 ?x))
    (let* ((root (drgnx-uitest-root-frame))
           (name " *chrome-posframe*")
           (none (progn (drgnx-test-chrome--settle) (drgnx-uitest-snapshot root))))
      (unwind-protect
          (dotimes (i 100)
            (posframe-show name :string "posframe chrome" :position (point-min) :border-width 1
                           :border-color "#888888")
            (when (= (% i 25) 0)
              (let* ((frame (buffer-local-value 'posframe--frame (get-buffer name)))
                     (rect nil))
                (drgnx-test-chrome--settle)
                (setq rect (drgnx-test-chrome--rect frame root))
                (let ((off (drgnx-test-chrome--off-snapshot root)))
                  (drgnx-test-chrome--check-chrome root (list frame) none off))
                (posframe-hide name)
                (drgnx-test-chrome--settle)
                (drgnx-test-chrome--check-hidden root (list rect) none)))
            (unless (= (% i 25) 0) (posframe-hide name)))
        (posframe-delete-all)
        (kill-buffer "*chrome-scratch*"))
      (drgnx-test-chrome--settle)
      (drgnx-test-chrome--check-hidden root (list (list 0 0 (nth 0 none) (nth 1 none))) none)
      (drgnx-test-chrome--no-violations))))

(ert-deftest drgnx-ui-chrome/eldoc-box-beside-corfu ()
  "eldoc-box placed beside corfu's popup (two adjacent popups): chrome on both, no residue after hide."
  (drgnx-test-chrome--with-chrome
    (drgnx-test-chrome--with-corfu
      (require 'eldoc-box)
      (drgnx-test-chrome--complete '("chrome-alpha" "chrome-beta") "Doc.")
      (insert "chrome-")
      (drgnx-test-chrome--settle)
      (let* ((root (drgnx-uitest-root-frame))
             (none (drgnx-uitest-snapshot root))
             (eldoc-box-position-function
              (lambda (w h) (or (eldoc-box--at-point-x-y-by-corfu)
                                (eldoc-box--default-upper-corner-position-function w h))))
             (corfu-popupinfo-mode nil))
        (completion-at-point)
        (should (drgnx-test-chrome--wait-for
                 (lambda () (and (frame-live-p corfu--frame) (frame-visible-p corfu--frame)))))
        (eldoc-box--display "eldoc-box beside corfu")
        (drgnx-test-chrome--settle)
        (let* ((box (cl-find-if (lambda (f) (and (frame-visible-p f) (not (eq f corfu--frame))))
                                (drgnx-uitest-child-frames root)))
               (popups (list corfu--frame box)))
          (should box)
          (let ((rects (mapcar (lambda (p) (drgnx-test-chrome--rect p root)) popups))
                (off (drgnx-test-chrome--off-snapshot root)))
            (drgnx-test-chrome--check-chrome root popups none off)
            (drgnx-test-chrome--check-stacking root popups)
            (eldoc-box-quit-frame)
            (corfu-quit)
            (drgnx-test-chrome--settle)
            (drgnx-test-chrome--check-hidden root rects none)
            (drgnx-test-chrome--no-violations)))))))

(ert-deftest drgnx-ui-chrome/popup-at-the-right-bottom-edge ()
  "A posframe flush with the parent's right and bottom edges: the clipped shadow stays inside, the corners are drawn."
  (drgnx-test-chrome--with-chrome
    (require 'posframe)
    (switch-to-buffer (get-buffer-create "*chrome-scratch*"))
    (erase-buffer) (insert "edge")
    (let* ((root (drgnx-uitest-root-frame))
           (name " *chrome-edge*")
           (none (progn (drgnx-test-chrome--settle) (drgnx-uitest-snapshot root))))
      (unwind-protect
          (progn
            (posframe-show name :string "flush right and bottom" :border-width 1 :border-color "#888888"
                           :poshandler #'posframe-poshandler-frame-bottom-right-corner)
            (drgnx-test-chrome--settle)
            (let* ((frame (buffer-local-value 'posframe--frame (get-buffer name)))
                   (r (drgnx-test-chrome--rect frame root))
                   (s (drgnx-test-chrome--scale root))
                   (inset (ceiling (* s 12)))
                   (off (drgnx-test-chrome--off-snapshot root))
                   (snap (drgnx-uitest-snapshot root)))
              (should (equal (seq-take snap 2) (seq-take none 2)))
              ;; flush: the popup reaches the parent's right and bottom edges
              (should (>= (nth 2 r) (- (nth 0 snap) 2)))
              (should (>= (nth 3 r) (- (nth 1 snap) 2)))
              (should (drgnx-uitest-region-equal-p snap off (drgnx-test-chrome--shrink r inset)
                                                   :tolerance 0 :ignore-alpha t))
              ;; the top-left corner is rounded: its pixel is the parent's, as with no popup
              (should (equal (drgnx-uitest-pixel snap (nth 0 r) (nth 1 r))
                             (drgnx-uitest-pixel none (nth 0 r) (nth 1 r))))
              ;; the shadow falls on the free sides (left, top), 4 device px outside
              (should (drgnx-uitest-darker-p snap none (- (nth 0 r) 4) (/ (+ (nth 1 r) (nth 3 r)) 2)))
              (should (drgnx-uitest-darker-p snap none (/ (+ (nth 0 r) (nth 2 r)) 2) (- (nth 1 r) 4)))
              (drgnx-test-chrome--check-stacking root (list frame))
              (posframe-hide name)
              (drgnx-test-chrome--settle)
              (drgnx-test-chrome--check-hidden root (list r) none)))
        (posframe-delete-all)
        (kill-buffer "*chrome-scratch*"))
      (drgnx-test-chrome--no-violations))))

;;; childframe-chrome-test.el ends here
