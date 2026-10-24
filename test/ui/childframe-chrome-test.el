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
(declare-function corfu--exhibit "corfu")
(declare-function corfu-mode "corfu")
(declare-function corfu-popupinfo-mode "corfu-popupinfo")
(declare-function eldoc-box--display "eldoc-box")
(declare-function eldoc-box-quit-frame "eldoc-box")
(declare-function eldoc-box--at-point-x-y-by-corfu "eldoc-box")
(declare-function eldoc-box--default-upper-corner-position-function "eldoc-box")
(defvar posframe--frame)
(defvar corfu-preselect)
(defvar corfu-auto-delay)
(defvar corfu-auto-prefix)
(defvar corfu--index)
(defvar company-backends)
(defvar company-idle-delay)
(defvar company-minimum-prefix-length)
(defvar company-box-doc-delay)
(defvar company-box-doc-enable)
(defvar company-box-mode)
(defvar company-frontends)
(defvar which-key-posframe-mode)
(defvar transient-posframe-mode)
(defvar blink-cursor-interval)
(defvar blink-cursor-delay)
(defvar blink-cursor-blinks)
(declare-function posframe-poshandler-frame-center "posframe")
(declare-function eldoc-box--default-at-point-position-function "eldoc-box")
(declare-function corfu-last "corfu")
(declare-function corfu-first "corfu")
(declare-function company-mode "company")
(declare-function company-manual-begin "company")
(declare-function company-select-next "company")
(declare-function company-abort "company")
(declare-function company-doc-buffer "company")
(declare-function company-grab-symbol "company")
(declare-function company-box-mode "company-box")
(declare-function which-key--show-keymap "which-key")
(declare-function which-key--hide-popup "which-key")
(declare-function which-key-posframe-mode "which-key-posframe")
(declare-function transient-posframe-mode "transient-posframe")
(declare-function transient-quit-all "transient")
(declare-function transient--emergency-exit "transient")
(declare-function vertico-mode "vertico")
(declare-function vertico-posframe-mode "vertico-posframe")
(declare-function mini-frame-mode "mini-frame")
(declare-function glitnir-stats "glitnir")
(declare-function glitnir-active-p "glitnir")
(declare-function glitnir--stacking "glitnir")
(declare-function glitnir-refresh "glitnir")
(declare-function glitnir--draw-count "glitnir")

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
     (message nil)                      ; the echo area stays one line: an edge popup's margin reaches it
     (when (fboundp 'glitnir-refresh) (glitnir-refresh))   ; Task 33 on; before it there is no chrome to refresh
     (unwind-protect (progn ,@body)
       ;; a failed scenario leaves no popup shown for the next one
       (dolist (c (drgnx-uitest-child-frames (drgnx-uitest-root-frame)))
         (make-frame-invisible c))
       (drgnx-test-chrome--settle))))

(defun drgnx-test-chrome--settle ()
  (redisplay t)
  (sit-for 0.3)
  (redisplay t))

(defun drgnx-test-chrome--scale (frame) (frame-scale-factor frame))

(defun drgnx-test-chrome--rect (child root)
  "CHILD's outer rectangle in ROOT's device pixels, (L T R B) with R and B exclusive.
A child frame's edges are relative to its parent's native area (not to the display: ROOT's own place on the display
moves when it is resized or made fullscreen)."
  (let ((s (drgnx-test-chrome--scale root))
        (e (frame-edges child 'outer-edges)))
    (mapcar (lambda (v) (round (* s v))) e)))

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
      (redraw-frame root)               ; the picture Glitnir draws again, whole
      (drgnx-test-chrome--settle))))

(defun drgnx-test-chrome--equal-except-p (a b rect excluded)
  "Non-nil when snapshots A and B agree (alpha ignored) on RECT (L T R B) outside the rectangles EXCLUDED."
  (if (null excluded)
      (drgnx-uitest-region-equal-p a b rect :tolerance 0 :ignore-alpha t)
    (let ((w (nth 0 a)) (ba (nth 2 a)) (bb (nth 2 b)) (ok t) (y (nth 1 rect)) (alpha (if (eq (byteorder) ?l) 3 0)))
      (while (and ok (< y (nth 3 rect)))
        (let ((x (nth 0 rect)))
          (while (and ok (< x (nth 2 rect)))
            (unless (seq-some (lambda (e) (and (<= (nth 0 e) x) (< x (nth 2 e)) (<= (nth 1 e) y) (< y (nth 3 e))))
                              excluded)
              (let ((o (* 4 (+ (* y w) x))))
                (dotimes (i 4)
                  (unless (or (= i alpha) (= (aref ba (+ o i)) (aref bb (+ o i)))) (setq ok nil)))))
            (setq x (1+ x))))
        (setq y (1+ y)))
      ok)))

(defun drgnx-test-chrome--corner-cut-p (snap none off x y)
  "The pixel X, Y of SNAP is a cut corner: not the popup's square corner (OFF's) but what lies beneath, which is the
no-popup pixel in NONE or, under the popup's own shadow, a darker one."
  (let ((got (cdr (drgnx-uitest-pixel snap x y))) (bare (cdr (drgnx-uitest-pixel none x y)))
        (square (cdr (drgnx-uitest-pixel off x y))))
    (or (and (not (equal got square)) (cl-every #'<= got bare))
        (ert-fail (list "the corner pixel is not cut" (cons x y) :got got :beneath bare :square-corner square)))))

(defun drgnx-test-chrome--check-chrome (root popups none off)
  "Assert the chrome of every frame in POPUPS (visible child frames of ROOT).
NONE is the no-popup snapshot, OFF the Glitnir-off one with the popups shown; the current picture is taken here.
Inside a popup away from its corners = OFF (leaving out what lies within another popup's shadow margin); each upper
corner pixel is cut (`drgnx-test-chrome--corner-cut-p'); 3 device px outside the right edge is darker than NONE.
After the caller hides the popups it checks the no-popup picture with `drgnx-test-chrome--check-hidden'."
  (let* ((s (drgnx-test-chrome--scale root))
         (snap (drgnx-uitest-snapshot root))
         (inset (ceiling (* s (+ 8 4))))       ; corner radius plus the anti-aliasing fringe
         (m (ceiling (* s drgnx-test-chrome--margin))))
    (dolist (p popups)
      (let* ((r (drgnx-test-chrome--rect p root))
             (inner (drgnx-test-chrome--shrink r inset))
             ;; another popup's shadow falls on this one by design (shadows show on lower popups)
             (others (mapcar (lambda (o) (drgnx-test-chrome--grow (drgnx-test-chrome--rect o root) m))
                             (remq p popups))))
        (should (drgnx-test-chrome--equal-except-p snap off inner others))
        (dolist (c (list (cons (nth 0 r) (nth 1 r)) (cons (1- (nth 2 r)) (nth 1 r))))
          (when (and (< -1 (car c) (nth 0 snap)) (< -1 (cdr c) (nth 1 snap))
                     (not (seq-some (lambda (e) (and (<= (nth 0 e) (car c)) (< (car c) (nth 2 e))
                                                     (<= (nth 1 e) (cdr c)) (< (cdr c) (nth 3 e))))
                                    others)))
            (should (drgnx-test-chrome--corner-cut-p snap none off (car c) (cdr c)))))
        (let ((x (+ (nth 2 r) 3)) (y (/ (+ (nth 1 r) (nth 3 r)) 2)))
          (when (< x (nth 0 snap))
            (should (drgnx-uitest-darker-p snap none x y))))))))

(defun drgnx-test-chrome--check-hidden (root popup-rects none)
  "Assert that POPUP-RECTS plus the shadow margin equal NONE (the no-popup snapshot) in ROOT's picture."
  (let ((snap (drgnx-uitest-snapshot root))
        (m (ceiling (* (drgnx-test-chrome--scale root) drgnx-test-chrome--margin))))
    (dolist (r popup-rects)
      (let ((region (drgnx-test-chrome--clip (drgnx-test-chrome--grow r m) snap)))
        (unless (drgnx-uitest-region-equal-p snap none region :tolerance 0 :ignore-alpha t)
          (ert-fail (list "the popup's place is not the no-popup picture" :region region
                          :first-pixel (drgnx-test-chrome--first-diff snap none region))))))))

(defun drgnx-test-chrome--first-diff (a b rect)
  "The first pixel (X Y A-PIXEL B-PIXEL) inside RECT where snapshots A and B differ (RGB), or nil."
  (cl-loop for y from (nth 1 rect) below (nth 3 rect)
           thereis (cl-loop for x from (nth 0 rect) below (nth 2 rect)
                            when (not (equal (cdr (drgnx-uitest-pixel a x y)) (cdr (drgnx-uitest-pixel b x y))))
                            return (list x y (drgnx-uitest-pixel a x y) (drgnx-uitest-pixel b x y)))))

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
        (corfu--exhibit)                ; corfu shows its popup after a command; no command runs here
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
          (progn
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
            ;; the whole picture is the no-popup one, before the buffer goes
            (drgnx-test-chrome--settle)
            (drgnx-test-chrome--check-hidden root (list (list 0 0 (nth 0 none) (nth 1 none))) none))
        (posframe-delete-all)
        (kill-buffer "*chrome-scratch*"))
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
        (corfu--exhibit)                ; corfu shows its popup after a command; no command runs here
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
                           ;; flush with the parent's native edges (the corner poshandler keeps above the mode
                           ;; line and the minibuffer)
                           :poshandler (lambda (_info) (cons -1 -1)))
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
              ;; the top-left corner is rounded: its pixel is the parent's (under the popup's own shadow at most)
              (should (drgnx-test-chrome--corner-cut-p snap none off (nth 0 r) (nth 1 r)))
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

;;;; The rest of the §3.4 matrix (Task 36)
;; Every package row of the design's matrix, plus its generic checks, as `drgnx-ui-chrome/<package>-<check>'.  They share
;; the helpers below and the verifier (`verify': a violation anywhere fails the run).  Chrome checks (rounded corners,
;; the shadow, the border stroke) need Glitnir's chrome and fail without it; geometry, focus, stacking and the
;; "nothing outside the popup changes" checks hold on any build.

(defvar drgnx-jank-guard--timer-fn)
(defvar drgnx-guard--timer-fn)

(defun drgnx-test-chrome--rects (popups root)
  (mapcar (lambda (p) (drgnx-test-chrome--rect p root)) popups))

(defun drgnx-test-chrome--rows-equal-p (a b rects)
  "Non-nil when snapshots A and B agree (RGB) everywhere outside RECTS (L T R B each).
Rows are compared whole first, so the usual all-equal picture costs one string compare a row."
  (and (equal (seq-take a 2) (seq-take b 2))
       (let ((w (nth 0 a)) (h (nth 1 a)) (ba (nth 2 a)) (bb (nth 2 b)) (ok t) (y 0)
             (alpha (if (eq (byteorder) ?l) 3 0)))
         (while (and ok (< y h))
           (let ((cuts nil) (x 0))
             (dolist (r rects)
               (when (and (<= (nth 1 r) y) (< y (nth 3 r)))
                 (push (cons (max 0 (nth 0 r)) (min w (nth 2 r))) cuts)))
             (setq cuts (sort cuts (lambda (p q) (< (car p) (car q)))))
             (dolist (c (append cuts (list (cons w w))))
               (when (and ok (< x (car c)))
                 (let ((s (* 4 (+ (* y w) x))) (e (* 4 (+ (* y w) (car c)))))
                   (unless (string= (substring ba s e) (substring bb s e))
                     (let ((i s))
                       (while (and ok (< i e))
                         (when (and (/= (% (- i s) 4) alpha) (/= (aref ba i) (aref bb i)))
                           (setq ok nil)
                           (ert-fail (list "the pictures differ outside the popups" :first-pixel
                                           (cons (/ (- i (* 4 y w)) 4) y)
                                           :a (drgnx-uitest-pixel a (/ (- i (* 4 y w)) 4) y)
                                           :b (drgnx-uitest-pixel b (/ (- i (* 4 y w)) 4) y))))
                         (setq i (1+ i)))))))
               (setq x (max x (cdr c))))
             (setq y (1+ y))))
         ok)))

(defun drgnx-test-chrome--shown (root popups none)
  "Assert the chrome of POPUPS, their stacking and that nothing outside them and their shadows differs from stock.
NONE is the no-popup snapshot.  Return the popups' rectangles."
  (let* ((off (drgnx-test-chrome--off-snapshot root))
         (rects (drgnx-test-chrome--rects popups root))
         (m (ceiling (* (drgnx-test-chrome--scale root) drgnx-test-chrome--margin))))
    (drgnx-test-chrome--check-chrome root popups none off)
    (drgnx-test-chrome--check-stacking root popups)
    (should (drgnx-test-chrome--rows-equal-p (drgnx-uitest-snapshot root) off
                                             (mapcar (lambda (r) (drgnx-test-chrome--grow r m)) rects)))
    rects))

(defun drgnx-test-chrome--hidden (root rects none)
  "After the caller hid the popups whose rectangles were RECTS: settle, compare with NONE, no violations."
  (drgnx-test-chrome--settle)
  ;; RECTS: rectangles, or lists of them as `drgnx-test-chrome--shown' returns
  (drgnx-test-chrome--check-hidden
   root (apply #'append (mapcar (lambda (r) (if (numberp (car r)) (list r) r)) rects)) none)
  (drgnx-test-chrome--no-violations))

(defun drgnx-test-chrome--pf (name string &rest args)
  "Show posframe NAME with STRING (a border of 1 px unless ARGS say otherwise); return its frame."
  (apply #'posframe-show name :string string (append args '(:border-width 1 :border-color "#888888")))
  (buffer-local-value 'posframe--frame (get-buffer name)))

(defmacro drgnx-test-chrome--with-scratch (&rest body)
  "Run BODY on a bare root frame in a scratch buffer with posframe loaded; `root' and `none' (the no-popup picture)."
  (declare (indent 0))
  `(drgnx-test-chrome--with-chrome
     (require 'posframe)
     (switch-to-buffer (get-buffer-create "*chrome-scratch*"))
     (erase-buffer) (insert "scratch text for popups")
     (let* ((root (drgnx-uitest-root-frame))
            (none (progn (drgnx-test-chrome--settle) (drgnx-uitest-snapshot root))))
       (ignore root none)
       (unwind-protect (progn ,@body)
         (ignore-errors (posframe-delete-all))
         (when (get-buffer "*chrome-scratch*") (kill-buffer "*chrome-scratch*"))))))

(defun drgnx-test-chrome--centred-p (rect root)
  "RECT (device px) is centred in ROOT's picture, within 8 logical px."
  (let ((snap (drgnx-uitest-snapshot root)) (tol (* 16 (drgnx-test-chrome--scale root))))
    (and (<= (abs (- (/ (+ (nth 0 rect) (nth 2 rect)) 2) (/ (nth 0 snap) 2))) tol)
         (<= (abs (- (/ (+ (nth 1 rect) (nth 3 rect)) 2) (/ (nth 1 snap) 2))) tol))))

(defun drgnx-test-chrome--wait-stable (fn &optional timeout)
  "Redisplay until FN's value has not changed for four samples 0.1 s apart (GTK's layout has followed), or TIMEOUT."
  (let ((end (+ (float-time) (or timeout 5))) (last nil) (same 0))
    (while (and (< same 4) (< (float-time) end))
      (redisplay t) (sit-for 0.1)
      (let ((v (funcall fn)))
        (setq same (if (equal v last) (1+ same) 0) last v)))
    last))

(defun drgnx-test-chrome--children (root)
  (drgnx-uitest-child-frames root))

(defun drgnx-test-chrome--reading (reader typed probe)
  "Call READER (it opens the minibuffer) while TYPED arrives as keys; PROBE runs when it shows them, then Return ends it.
Return PROBE's value; an error PROBE signalled (a failed `should') is signalled again here."
  (let ((result nil) (drgnx-jank-guard--timer-fn nil) (drgnx-guard--timer-fn nil))
    (run-at-time 0.5 nil (lambda () (setq unread-command-events
                                          (append (listify-key-sequence typed) unread-command-events))))
    (run-at-time 3.0 nil (lambda ()
                           (setq result (condition-case err (list :ok (funcall probe)) (error (list :error err))))
                           (setq unread-command-events (list 'return))))
    (funcall reader)
    (pcase result
      (`(:ok ,v) v)
      (`(:error ,err) (signal (car err) (cdr err)))
      (_ (error "The probe never ran")))))

(defun drgnx-test-chrome--blink-corners (root popups none)
  "Blink the cursor for a moment: at every sample each popup's two upper corner pixels are still NONE's."
  (let ((old (list blink-cursor-interval blink-cursor-delay blink-cursor-blinks)) (snaps nil))
    (setq blink-cursor-interval 0.1 blink-cursor-delay 0 blink-cursor-blinks 0)
    (unwind-protect
        (progn (blink-cursor-mode 1)
               (dotimes (_ 8) (sit-for 0.07) (redisplay t) (push (drgnx-uitest-snapshot root) snaps)))
      (blink-cursor-mode -1)
      (setq blink-cursor-interval (nth 0 old) blink-cursor-delay (nth 1 old) blink-cursor-blinks (nth 2 old)))
    (dolist (snap snaps)
      (dolist (p popups)
        (let ((r (drgnx-test-chrome--rect p root)))
          (dolist (xy (list (cons (nth 0 r) (nth 1 r)) (cons (1- (nth 2 r)) (nth 1 r))))
            (let ((got (cdr (drgnx-uitest-pixel snap (car xy) (cdr xy))))
                  (first (cdr (drgnx-uitest-pixel (car (last snaps)) (car xy) (cdr xy))))
                  (bare (cdr (drgnx-uitest-pixel none (car xy) (cdr xy)))))
              ;; the same at every sample, and cut: what lies beneath, a little darker at most (the popup's own shadow;
              ;; a square corner would be the border colour, far darker)
              (should (equal got first))
              (should (cl-every #'<= got bare))
              (should (cl-every (lambda (g b) (<= (- b 20) g)) got bare)))))))))

;;;; posframe

(ert-deftest drgnx-ui-chrome/posframe-move ()
  "A posframe moved by showing it elsewhere (the frame is reused): chrome at each place, nothing left at either."
  (drgnx-test-chrome--with-scratch
    (let* ((name " *chrome-move*")
           (f (drgnx-test-chrome--pf name "moves" :position '(300 . 200))))
      (drgnx-test-chrome--settle)
      (let ((r1 (drgnx-test-chrome--shown root (list f) none))
            (f2 (drgnx-test-chrome--pf name "moves" :position '(120 . 140))))
        (drgnx-test-chrome--settle)
        (should (eq f f2))
        (let ((r2 (drgnx-test-chrome--shown root (list f2) none)))
          (should-not (equal r1 r2))
          (posframe-hide name)
          (drgnx-test-chrome--hidden root (list r1 r2) none))))))

(ert-deftest drgnx-ui-chrome/posframe-border-colour-follows-face ()
  "The border stroke takes the `child-frame-border' face's background, set per frame as posframe does."
  (drgnx-test-chrome--with-scratch
    (let* ((name " *chrome-border*") frame r)
      (cl-flet ((probe (colour)
                  (drgnx-test-chrome--settle)
                  (let* ((snap (drgnx-uitest-snapshot root)) (s (drgnx-test-chrome--scale root))
                         (px (drgnx-uitest-pixel snap (/ (+ (nth 0 r) (nth 2 r)) 2) (+ (nth 1 r) (round s))))
                         (want (mapcar (lambda (v) (/ v 257)) (color-values colour))))
                    (cl-loop for got in (cdr px) for w in want do (should (<= (abs (- got w)) 6))))))
        (dolist (colour '("#ff0000" "#00ff00"))
          (setq frame (drgnx-test-chrome--pf name "border" :border-width 2 :border-color colour))
          (drgnx-test-chrome--settle)
          (setq r (drgnx-test-chrome--rect frame root))
          (probe colour))
        (set-face-background 'child-frame-border "#0000ff" frame)
        (probe "#0000ff")
        (drgnx-test-chrome--shown root (list frame) none)
        (posframe-hide name)
        (drgnx-test-chrome--hidden root (list r) none)))))

(ert-deftest drgnx-ui-chrome/posframe-reuse-after-hide ()
  "A posframe hidden and shown again reuses its frame: chrome the second time, nothing left after the second hide."
  (drgnx-test-chrome--with-scratch
    (let* ((name " *chrome-reuse*")
           (f (drgnx-test-chrome--pf name "first" :position '(260 . 180))))
      (drgnx-test-chrome--settle)
      (let ((r (drgnx-test-chrome--shown root (list f) none)))
        (posframe-hide name)
        (drgnx-test-chrome--hidden root (list r) none)
        (let ((f2 (drgnx-test-chrome--pf name "second" :position '(260 . 180))))
          (drgnx-test-chrome--settle)
          (should (eq f f2))
          (setq r (drgnx-test-chrome--shown root (list f2) none))
          (posframe-hide name)
          (drgnx-test-chrome--hidden root (list r) none))))))

(ert-deftest drgnx-ui-chrome/posframe-resize-draw-count ()
  "The resize row: GTK's draws of the root per `set-frame-size-and-position-pixelwise' on a shown chromed child.
Task 35 (one move+resize) is built only when this is two.  Measured on Task 34's build (2026-10-24): 2 per call at
scale 1 and at scale 2 (one call in eight took 4), so MP-23 is needed; the assertion is that the median is one or two."
  (drgnx-test-chrome--with-scratch
    (let* ((name " *chrome-resize*")
           (f (drgnx-test-chrome--pf name "resize me" :position '(200 . 150)))
           (counts nil))
      (drgnx-test-chrome--settle)
      (dotimes (i 8)
        (let ((before (glitnir--draw-count root)))
          (set-frame-size-and-position-pixelwise f (+ 200 (* 20 (% i 3))) (+ 60 (* 10 (% i 2)))
                                                 (+ 200 (* 15 i)) (+ 150 (* 5 i)))
          (drgnx-test-chrome--settle)
          (push (- (glitnir--draw-count root) before) counts)))
      (setq counts (nreverse counts))
      (should (<= 1 (nth (/ (length counts) 2) (sort (copy-sequence counts) #'<)) 2))
      (let ((r (drgnx-test-chrome--shown root (list f) none)))
        (posframe-hide name)
        (drgnx-test-chrome--hidden root (list r) none)))))

(ert-deftest drgnx-ui-chrome/posframe-delete-frame-mid-show ()
  "`delete-frame' on a shown posframe, then on one just shown: no crash, no residue, and the next show works."
  (drgnx-test-chrome--with-scratch
    (let* ((name " *chrome-delete*")
           (f (drgnx-test-chrome--pf name "deleted" :position '(240 . 160))))
      (drgnx-test-chrome--settle)
      (let ((r (drgnx-test-chrome--shown root (list f) none)))
        (delete-frame f)
        (drgnx-test-chrome--hidden root (list r) none)
        ;; deleted straight after the show, before any redisplay
        (let ((g (drgnx-test-chrome--pf name "again" :position '(240 . 160))))
          (delete-frame g)
          (drgnx-test-chrome--hidden root (list r) none))
        (let ((h (drgnx-test-chrome--pf name "after" :position '(240 . 160))))
          (drgnx-test-chrome--settle)
          (setq r (drgnx-test-chrome--shown root (list h) none))
          (posframe-hide name)
          (drgnx-test-chrome--hidden root (list r) none))))))

(ert-deftest drgnx-ui-chrome/which-key-posframe-centred ()
  "which-key through which-key-posframe: one chromed popup, centred by `posframe-poshandler-frame-center'."
  (drgnx-test-chrome--with-scratch
    (require 'which-key) (require 'which-key-posframe)
    (which-key-posframe-mode 1)
    (unwind-protect
        (progn
          (which-key--show-keymap "ctl-x" ctl-x-map nil nil t)
          (should (drgnx-test-chrome--wait-for (lambda () (drgnx-test-chrome--children root))))
          (drgnx-test-chrome--settle)
          (let* ((popups (drgnx-test-chrome--children root))
                 (rects (drgnx-test-chrome--shown root popups none)))
            (should (= 1 (length popups)))
            (should (drgnx-test-chrome--centred-p (car rects) root))
            (which-key--hide-popup)
            (message nil)
            (should (drgnx-test-chrome--wait-for (lambda () (null (drgnx-test-chrome--children root)))))
            (drgnx-test-chrome--hidden root rects none)))
      (ignore-errors (which-key--hide-popup))
      (which-key-posframe-mode -1))))

(defun drgnx-test-chrome--define-prefix ()
  (require 'transient)
  (eval '(transient-define-prefix drgnx-test-chrome--prefix ()
                                  "A transient prefix for the matrix."
                                  [["Chrome" ("a" "alpha" ignore) ("b" "beta" ignore) ("c" "gamma" ignore)]])
        t))

(ert-deftest drgnx-ui-chrome/transient-posframe-centred ()
  "transient through transient-posframe: one chromed popup, centred."
  (drgnx-test-chrome--with-scratch
    (drgnx-test-chrome--define-prefix)
    (require 'transient-posframe)
    (transient-posframe-mode 1)
    (unwind-protect
        (progn
          (call-interactively #'drgnx-test-chrome--prefix)
          (should (drgnx-test-chrome--wait-for (lambda () (drgnx-test-chrome--children root))))
          (drgnx-test-chrome--settle)
          (let* ((popups (drgnx-test-chrome--children root))
                 (rects (drgnx-test-chrome--shown root popups none)))
            (should (= 1 (length popups)))
            (should (drgnx-test-chrome--centred-p (car rects) root))
            (drgnx-uitest-run (drgnx-uitest-key-events "C-g") 10) ; through the command loop: transient's keymap
            (should (drgnx-test-chrome--wait-for (lambda () (null (drgnx-test-chrome--children root)))))
            (drgnx-test-chrome--hidden root rects none)))
      (ignore-errors (transient--emergency-exit))
      (transient-posframe-mode -1))))

(ert-deftest drgnx-ui-chrome/which-key-default-pixels-off ()
  "which-key's default (a side window) is no child frame: the picture equals Glitnir off's."
  (drgnx-test-chrome--with-scratch
    (require 'which-key)
    (unwind-protect
        (progn
          (which-key--show-keymap "ctl-x" ctl-x-map nil nil t)
          (drgnx-test-chrome--settle)
          (should-not (drgnx-test-chrome--children root))
          (let* ((on (drgnx-uitest-snapshot root))
                 (off (drgnx-test-chrome--off-snapshot root)))
            (should (drgnx-test-chrome--rows-equal-p on off nil))))
      (ignore-errors (which-key--hide-popup)))
    (drgnx-test-chrome--no-violations)))

(ert-deftest drgnx-ui-chrome/transient-default-pixels-off ()
  "transient's default (a window at the bottom) is no child frame: the picture equals Glitnir off's."
  (drgnx-test-chrome--with-scratch
    (drgnx-test-chrome--define-prefix)
    (unwind-protect
        (progn
          (call-interactively #'drgnx-test-chrome--prefix)
          (drgnx-test-chrome--settle)
          (should-not (drgnx-test-chrome--children root))
          (let* ((on (drgnx-uitest-snapshot root))
                 (off (drgnx-test-chrome--off-snapshot root)))
            (should (drgnx-test-chrome--rows-equal-p on off nil))))
      (ignore-errors (transient-quit-all))
      (ignore-errors (transient--emergency-exit)))
    (drgnx-test-chrome--no-violations)))

;;;; corfu

(ert-deftest drgnx-ui-chrome/corfu-typing-200 ()
  "corfu popping up and following the point while 200 characters are typed: no trail, no stale frame, chrome after."
  (drgnx-test-chrome--with-chrome
    (drgnx-test-chrome--with-corfu
      (corfu-mode -1)
      (let ((corfu-auto t) (corfu-auto-delay 0.0) (corfu-auto-prefix 1))
        (corfu-mode 1)
        (drgnx-test-chrome--complete '("xa1" "xb2" "xc3") "Doc.") ; no common prefix beyond \"x\": completing inserts nothing
        (drgnx-test-chrome--settle)
        (let ((root (drgnx-uitest-root-frame)) (max-frames 0))
          (let ((timer (run-with-timer 0.05 0.05 (lambda () (setq max-frames (max max-frames (length (drgnx-test-chrome--children root))))))))
            (unwind-protect
                (drgnx-uitest-run (drgnx-uitest-type-events (apply #'concat (make-list 100 "x "))) 120)
              (cancel-timer timer)))
          (should (<= max-frames 2))      ; corfu's and popupinfo's, never a stale third
          (should (drgnx-test-chrome--wait-for (lambda () (null (drgnx-test-chrome--children root)))))
          (drgnx-test-chrome--settle)
          (should (drgnx-test-chrome--rows-equal-p (drgnx-uitest-snapshot root)
                                                   (drgnx-test-chrome--off-snapshot root) nil)) ; no trail
          ;; one more character opens the popups again; the picture with them closed is the reference
          (drgnx-uitest-run (drgnx-uitest-type-events "x") 20)
          (should (drgnx-test-chrome--wait-for
                   (lambda () (and (frame-live-p corfu--frame) (frame-visible-p corfu--frame)))))
          (corfu-quit)
          (should (drgnx-test-chrome--wait-for (lambda () (null (drgnx-test-chrome--children root)))))
          (drgnx-test-chrome--settle)
          (let ((none (drgnx-uitest-snapshot root)))
            (completion-at-point)
            (corfu--exhibit)
            (should (drgnx-test-chrome--wait-for
                     (lambda () (and (frame-live-p corfu--frame) (frame-visible-p corfu--frame)))))
            (drgnx-test-chrome--settle)
            (let* ((popups (drgnx-test-chrome--children root))
                   (rects (drgnx-test-chrome--shown root popups none)))
              (should (<= (length popups) 2))
              (corfu-quit)
              (should (drgnx-test-chrome--wait-for (lambda () (null (drgnx-test-chrome--children root)))))
              (drgnx-test-chrome--hidden root rects none))))))))

(defmacro drgnx-test-chrome--with-three-rows (&rest body)
  "Run BODY (`root', `none') with corfu open on three candidates; the first and last are short, the middle one long."
  (declare (indent 0))
  `(drgnx-test-chrome--with-chrome
     (drgnx-test-chrome--with-corfu
       (let ((corfu-popupinfo-mode nil) (corfu-preselect 'first))
         (drgnx-test-chrome--complete '("chrome-alpha" "chrome-beta" "chrome-gamma") "Doc.")
         (insert "chrome-")
         (drgnx-test-chrome--settle)
         (let* ((root (drgnx-uitest-root-frame)) (none (drgnx-uitest-snapshot root)))
           (completion-at-point)
           (corfu--exhibit)                ; corfu shows its popup after a command; no command runs here
           (should (drgnx-test-chrome--wait-for
                    (lambda () (and (frame-live-p corfu--frame) (frame-visible-p corfu--frame)))))
           (drgnx-test-chrome--settle)
           ,@body)))))

(defun drgnx-test-chrome--row-colours (root frame)
  "The pixels of FRAME's first and last candidate rows in their right margin, below the corner arcs."
  (let* ((r (drgnx-test-chrome--rect frame root)) (s (drgnx-test-chrome--scale root))
         (snap (drgnx-uitest-snapshot root)) (h (- (nth 3 r) (nth 1 r)))
         (x (- (nth 2 r) (round (* 3 s)))))
    (list (drgnx-uitest-pixel snap x (+ (nth 1 r) (/ h 6)))
          (drgnx-uitest-pixel snap x (+ (nth 1 r) (/ (* 5 h) 6))))))

(ert-deftest drgnx-ui-chrome/corfu-highlight-under-the-corners ()
  "The selected row is painted edge to edge, first row then last row: the corners are still cut, the stroke stays."
  (drgnx-test-chrome--with-three-rows
    (let* ((first-colours (drgnx-test-chrome--row-colours root corfu--frame)))
      (should-not (equal (nth 0 first-colours) (nth 1 first-colours)))     ; the first row is the highlighted one
      (drgnx-test-chrome--shown root (list corfu--frame) none)
      (corfu-last)
      (corfu--exhibit)
      (drgnx-test-chrome--settle)
      (let ((last-colours (drgnx-test-chrome--row-colours root corfu--frame)))
        (should-not (equal (nth 0 last-colours) (nth 1 last-colours)))
        (should (equal (nth 0 first-colours) (nth 1 last-colours)))         ; the highlight, now on the last row
        (should (equal (nth 1 first-colours) (nth 0 last-colours))))        ; and the plain row
      (let ((rects (drgnx-test-chrome--shown root (list corfu--frame) none)))
        (corfu-quit)
        (should (drgnx-test-chrome--wait-for (lambda () (not (frame-visible-p corfu--frame)))))
        (drgnx-test-chrome--hidden root rects none)))))

(ert-deftest drgnx-ui-chrome/corfu-popupinfo-z-order ()
  "popupinfo is above corfu's popup in Glitnir's stacking (the verifier checks GDK's agrees), chrome on both."
  (drgnx-test-chrome--with-chrome
    (drgnx-test-chrome--with-corfu
      (drgnx-test-chrome--complete '("chrome-alpha" "chrome-beta") "Documentation of the candidate.")
      (insert "chrome-")
      (drgnx-test-chrome--settle)
      (let* ((root (drgnx-uitest-root-frame)) (none (drgnx-uitest-snapshot root)))
        (completion-at-point)
        (corfu--exhibit)                ; corfu shows its popup after a command; no command runs here
        (should (drgnx-test-chrome--wait-for
                 (lambda () (and (frame-live-p corfu-popupinfo--frame) (frame-visible-p corfu-popupinfo--frame)))))
        (drgnx-test-chrome--settle)
        (let* ((popups (list corfu--frame corfu-popupinfo--frame))
               (stack (glitnir--stacking root)))
          (should (memq corfu--frame stack))
          (should (memq corfu-popupinfo--frame stack))
          (should (< (cl-position corfu--frame stack) (cl-position corfu-popupinfo--frame stack)))
          (let ((rects (drgnx-test-chrome--shown root popups none)))
            (corfu-quit)
            (should (drgnx-test-chrome--wait-for (lambda () (not (frame-visible-p corfu--frame)))))
            (drgnx-test-chrome--hidden root rects none)))))))

(ert-deftest drgnx-ui-chrome/corfu-right-edge ()
  "corfu at the end of a long line is clamped to the parent's right edge: the clipped shadow stays inside, corners cut."
  (drgnx-test-chrome--with-chrome
    (drgnx-test-chrome--with-corfu
      (let ((corfu-popupinfo-mode nil))
        (drgnx-test-chrome--complete '("chrome-alpha-longer-candidate" "chrome-beta") "Doc.")
        (insert (make-string (max 0 (- (window-width) 12)) ?\s) "chrome-")
        (drgnx-test-chrome--settle)
        (let* ((root (drgnx-uitest-root-frame)) (none (drgnx-uitest-snapshot root)))
          (completion-at-point)
          (corfu--exhibit)                ; corfu shows its popup after a command; no command runs here
          (should (drgnx-test-chrome--wait-for
                   (lambda () (and (frame-live-p corfu--frame) (frame-visible-p corfu--frame)))))
          (drgnx-test-chrome--settle)
          (let* ((r (drgnx-test-chrome--rect corfu--frame root))
                 (snap (drgnx-uitest-snapshot root)))
            (should (>= (nth 2 r) (- (nth 0 snap) (* 16 (drgnx-test-chrome--scale root)))))
            (let ((rects (drgnx-test-chrome--shown root (list corfu--frame) none)))
              (corfu-quit)
              (should (drgnx-test-chrome--wait-for (lambda () (not (frame-visible-p corfu--frame)))))
              (drgnx-test-chrome--hidden root rects none))))))))

(defun drgnx-test-chrome--wheel-events (posn n)
  "N wheel-down events at POSN."
  (let ((head 'wheel-down))
    (put head 'event-kind 'mouse-click)
    (make-list n (list head posn))))

(ert-deftest drgnx-ui-chrome/corfu-click-and-wheel ()
  "Clicks on a candidate are ignored by corfu and the wheel scrolls popupinfo's documentation, under the chrome."
  (drgnx-test-chrome--with-chrome
    (drgnx-test-chrome--with-corfu
      (drgnx-test-chrome--complete '("chrome-alpha" "chrome-beta" "chrome-gamma")
                                   (mapconcat (lambda (i) (format "documentation line %d" i)) (number-sequence 1 80) "\n"))
      (insert "chrome-")
      (drgnx-test-chrome--settle)
      (let* ((root (drgnx-uitest-root-frame)) (none (drgnx-uitest-snapshot root)))
        (completion-at-point)
        (corfu--exhibit)                ; corfu shows its popup after a command; no command runs here
        (should (drgnx-test-chrome--wait-for
                 (lambda () (and (frame-live-p corfu-popupinfo--frame) (frame-visible-p corfu-popupinfo--frame)))))
        (drgnx-test-chrome--settle)
        (let* ((popups (list corfu--frame corfu-popupinfo--frame))
               (cwin (frame-root-window corfu--frame))
               (iwin (frame-root-window corfu-popupinfo--frame))
               (index corfu--index) (text (buffer-string)) (start (window-start iwin)))
          ;; a click on the second candidate row: ignored, nothing moves
          (drgnx-uitest-run (drgnx-uitest-click-events
                             (with-current-buffer (window-buffer cwin)
                               (save-excursion (goto-char (point-min)) (forward-line 1) (posn-at-point (point) cwin))))
                            10)
          (should (equal index corfu--index))
          (should (equal text (buffer-string)))
          (should (eq (selected-frame) root))
          ;; the wheel over the documentation scrolls it
          (drgnx-uitest-run (drgnx-test-chrome--wheel-events
                             (with-current-buffer (window-buffer iwin) (posn-at-point (window-start iwin) iwin)) 3)
                            10)
          (drgnx-test-chrome--settle)
          (should (> (window-start iwin) start))
          (should (and (frame-visible-p corfu--frame) (frame-visible-p corfu-popupinfo--frame)))
          (let ((rects (drgnx-test-chrome--shown root popups none)))
            (corfu-quit)
            (should (drgnx-test-chrome--wait-for (lambda () (not (frame-visible-p corfu--frame)))))
            (drgnx-test-chrome--hidden root rects none)))))))

;;;; eldoc-box

(defmacro drgnx-test-chrome--with-eldoc (&rest body)
  "Run BODY (`root', `none') in a 60-line buffer with eldoc-box loaded and the point on line 11."
  (declare (indent 0))
  `(drgnx-test-chrome--with-chrome
     (require 'eldoc-box)
     (switch-to-buffer (get-buffer-create "*chrome-scratch*"))
     (erase-buffer)
     (dotimes (i 60) (insert (format "line %d of the text under the eldoc-box popup\n" i)))
     (goto-char (point-min)) (forward-line 10) (end-of-line)
     (let* ((root (drgnx-uitest-root-frame))
            (none (progn (drgnx-test-chrome--settle) (drgnx-uitest-snapshot root))))
       (ignore root none)
       (unwind-protect (progn ,@body)
         (ignore-errors (eldoc-box-quit-frame))
         (when (get-buffer "*chrome-scratch*") (kill-buffer "*chrome-scratch*"))))))

(defun drgnx-test-chrome--eldoc-show (position-function &optional text)
  "Show eldoc-box with POSITION-FUNCTION; the visible popup frame."
  (let ((eldoc-box-position-function position-function)
        (root (drgnx-uitest-root-frame)))
    (eldoc-box--display (or text "eldoc-box shows documentation here\nand a second line"))
    (should (drgnx-test-chrome--wait-for (lambda () (drgnx-test-chrome--children root))))
    (drgnx-test-chrome--settle)
    (car (drgnx-test-chrome--children root))))

(ert-deftest drgnx-ui-chrome/eldoc-box-at-point ()
  "eldoc-box placed at the point: chrome, nothing outside its shadow changes, nothing left after the hide."
  (drgnx-test-chrome--with-eldoc
    (let* ((box (drgnx-test-chrome--eldoc-show #'eldoc-box--default-at-point-position-function))
           (rects (drgnx-test-chrome--shown root (list box) none)))
      (eldoc-box-quit-frame)
      (drgnx-test-chrome--hidden root rects none))))

(ert-deftest drgnx-ui-chrome/eldoc-box-top-right ()
  "eldoc-box in the upper right corner of the window: chrome, the shadow clipped at the edge, nothing left."
  (drgnx-test-chrome--with-eldoc
    (let* ((box (drgnx-test-chrome--eldoc-show #'eldoc-box--default-upper-corner-position-function))
           (rects (drgnx-test-chrome--shown root (list box) none)))
      (eldoc-box-quit-frame)
      (drgnx-test-chrome--hidden root rects none))))

(ert-deftest drgnx-ui-chrome/eldoc-box-scroll-under ()
  "The text under a shown eldoc-box scrolls: everything outside the popup and its shadow is stock's, and its chrome holds."
  (drgnx-test-chrome--with-eldoc
    (let* ((box (drgnx-test-chrome--eldoc-show #'eldoc-box--default-upper-corner-position-function))
           (rect (drgnx-test-chrome--rect box root)))
      (dotimes (_ 4) (scroll-up-command 6) (redisplay t) (sit-for 0.05))
      (drgnx-test-chrome--settle)
      (let ((off (drgnx-test-chrome--off-snapshot root))
            (m (ceiling (* (drgnx-test-chrome--scale root) drgnx-test-chrome--margin))))
        (should (drgnx-test-chrome--rows-equal-p (drgnx-uitest-snapshot root) off
                                                 (list (drgnx-test-chrome--grow rect m)))))
      (eldoc-box-quit-frame)
      (drgnx-test-chrome--settle)
      (let* ((none2 (drgnx-uitest-snapshot root))
             (box2 (drgnx-test-chrome--eldoc-show #'eldoc-box--default-upper-corner-position-function))
             (rects (drgnx-test-chrome--shown root (list box2) none2)))
        (eldoc-box-quit-frame)
        (drgnx-test-chrome--hidden root rects none2)))))

(ert-deftest drgnx-ui-chrome/eldoc-box-theme-switch ()
  "A theme switch with the popup shown recolours the shadow and the stroke: chrome right in the new theme."
  (drgnx-test-chrome--with-eldoc
    (drgnx-test-chrome--eldoc-show #'eldoc-box--default-at-point-position-function)
    (unwind-protect
        (progn
          (load-theme 'modus-operandi-tinted t)
          (drgnx-test-chrome--settle)
          (eldoc-box-quit-frame)
          (drgnx-test-chrome--settle)
          (let* ((none2 (drgnx-uitest-snapshot root))
                 (box (drgnx-test-chrome--eldoc-show #'eldoc-box--default-at-point-position-function))
                 (rects (drgnx-test-chrome--shown root (list box) none2)))
            (eldoc-box-quit-frame)
            (drgnx-test-chrome--hidden root rects none2)))
      (disable-theme 'modus-operandi-tinted))))

;;;; company-box

(defun drgnx-test-chrome--company-backend (command &optional arg &rest _)
  "A company backend for the matrix: 30 candidates `chrome-NN', each with a documentation buffer."
  (pcase command
    ('interactive (company-begin-backend 'drgnx-test-chrome--company-backend))
    ('prefix (company-grab-symbol))
    ('candidates (cl-remove-if-not (lambda (c) (string-prefix-p arg c))
                                   (mapcar (lambda (i) (format "chrome-%02d" i)) (number-sequence 1 30))))
    ('doc-buffer (company-doc-buffer (format "Documentation of %s\n\nSome more text." arg)))
    ('sorted t)))

(defmacro drgnx-test-chrome--with-company-box (&rest body)
  "Run BODY (`root', `none') with company-box showing the matrix's candidates for \"chrome-\"; its frames are up."
  (declare (indent 0))
  `(drgnx-test-chrome--with-chrome
     (require 'company) (require 'company-box)
     (switch-to-buffer (get-buffer-create "*chrome-scratch*"))
     (erase-buffer)
     (let ((company-backends (list #'drgnx-test-chrome--company-backend)) (company-idle-delay nil)
           (company-minimum-prefix-length 1) (company-box-doc-delay 0) (company-box-doc-enable t))
       (company-mode 1) (company-box-mode 1)
       (setq-local company-frontends '(company-box-frontend))  ; company 1.1's own child-frame frontend is not loaded
       (insert "chrome-")
       (let* ((root (drgnx-uitest-root-frame))
              (none (progn (drgnx-test-chrome--settle) (drgnx-uitest-snapshot root))))
         (ignore root none)
         (unwind-protect
             (progn
               (company-manual-begin)
               (should (drgnx-test-chrome--wait-for (lambda () (>= (length (drgnx-test-chrome--children root)) 2)) 5))
               (drgnx-test-chrome--settle)
               ,@body)
           (ignore-errors (company-abort))
           (ignore-errors (company-box-mode -1))
           (ignore-errors (company-mode -1))
           (when (get-buffer "*chrome-scratch*") (kill-buffer "*chrome-scratch*")))))))

(ert-deftest drgnx-ui-chrome/company-box-candidates-and-doc ()
  "company-box's candidate frame and documentation frame at once: chrome on both, nothing left after the abort."
  (drgnx-test-chrome--with-company-box
    (let* ((popups (drgnx-test-chrome--children root))
           (rects (drgnx-test-chrome--shown root popups none)))
      (should (>= (length popups) 2))
      (company-abort)
      (should (drgnx-test-chrome--wait-for (lambda () (null (drgnx-test-chrome--children root)))))
      (drgnx-test-chrome--hidden root rects none))))

(ert-deftest drgnx-ui-chrome/company-box-scroll ()
  "Scrolling company-box's candidates (the selection runs past the visible rows): chrome holds, no residue."
  (drgnx-test-chrome--with-company-box
    (dotimes (_ 15) (company-select-next) (redisplay t) (sit-for 0.05))
    (drgnx-test-chrome--settle)
    (let* ((popups (drgnx-test-chrome--children root))
           (rects (drgnx-test-chrome--shown root popups none)))
      (company-abort)
      (should (drgnx-test-chrome--wait-for (lambda () (null (drgnx-test-chrome--children root)))))
      (drgnx-test-chrome--hidden root rects none))))

(ert-deftest drgnx-ui-chrome/company-box-delete-while-visible ()
  "company-box's frames deleted while shown: no crash, nothing left behind.
Skipped: Nidhogg crashes (with Glitnir off too) when company-box then kills its buffer of a deleted frame
\(`replace-buffer-in-windows' → `delete_frame' → `pgtk_clear_frame_selections', pgtkselect.c:793); NH-PGTK-DELETE-KILL-1.
The generic `posframe-delete-frame-mid-show' covers the delete itself."
  (ert-skip "NH-PGTK-DELETE-KILL-1: killing the buffer of a deleted child frame crashes pgtk (pgtkselect.c:793)")
  (drgnx-test-chrome--with-company-box
    (let* ((popups (drgnx-test-chrome--children root))
           (rects (drgnx-test-chrome--rects popups root)))
      (mapc #'delete-frame popups)
      (drgnx-test-chrome--hidden root rects none)
      (ignore-errors (company-abort))
      (drgnx-test-chrome--hidden root rects none))))

;;;; vertico-posframe and mini-frame

(defun drgnx-test-chrome--read-with-popup (reader typed)
  "Read with READER while TYPED is typed; the popups' chrome is asserted while it shows, and their rectangles returned
with the no-popup picture taken before the read."
  (let* ((root (drgnx-uitest-root-frame))
         (none (progn (drgnx-test-chrome--settle) (drgnx-uitest-snapshot root))))
    (list root none
          (drgnx-test-chrome--reading
           reader typed
           (lambda ()
             (should (drgnx-test-chrome--wait-for (lambda () (drgnx-test-chrome--children root)) 5))
             (drgnx-test-chrome--settle)
             (let ((popups (drgnx-test-chrome--children root)))
               (drgnx-test-chrome--shown root popups none)))))))

(defmacro drgnx-test-chrome--with-vertico-posframe (&rest body)
  (declare (indent 0))
  `(drgnx-test-chrome--with-chrome
     (require 'vertico) (require 'vertico-posframe)
     (switch-to-buffer (get-buffer-create "*chrome-scratch*"))
     (vertico-mode 1) (vertico-posframe-mode 1)
     (unwind-protect (progn ,@body)
       (vertico-posframe-mode -1) (vertico-mode -1)
       (when (get-buffer "*chrome-scratch*") (kill-buffer "*chrome-scratch*")))))

(defun drgnx-test-chrome--vertico-read ()
  (completing-read "Chrome: " '("chrome-one" "chrome-two" "chrome-three" "other")))

(ert-deftest drgnx-ui-chrome/vertico-posframe-typing ()
  "vertico-posframe while typing in the minibuffer: chrome on the candidates popup, nothing left after the read."
  (drgnx-test-chrome--with-vertico-posframe
    (pcase-let ((`(,root ,none ,rects) (drgnx-test-chrome--read-with-popup #'drgnx-test-chrome--vertico-read "chrome")))
      (should rects)
      (drgnx-test-chrome--hidden root rects none))))

(ert-deftest drgnx-ui-chrome/vertico-posframe-cursor-blink ()
  "The cursor blinking while vertico-posframe shows: the popup's upper corners stay the picture beneath."
  (drgnx-test-chrome--with-vertico-posframe
    (let* ((root (drgnx-uitest-root-frame))
           (none (progn (drgnx-test-chrome--settle) (drgnx-uitest-snapshot root))))
      (drgnx-test-chrome--reading
       #'drgnx-test-chrome--vertico-read "chrome"
       (lambda ()
         (should (drgnx-test-chrome--wait-for (lambda () (drgnx-test-chrome--children root)) 5))
         (drgnx-test-chrome--settle)
         (drgnx-test-chrome--blink-corners root (drgnx-test-chrome--children root) none)))
      (drgnx-test-chrome--hidden root (list (list 0 0 (nth 0 none) (nth 1 none))) none))))

(defmacro drgnx-test-chrome--with-mini-frame (&rest body)
  (declare (indent 0))
  `(drgnx-test-chrome--with-chrome
     (require 'mini-frame)
     (switch-to-buffer (get-buffer-create "*chrome-scratch*"))
     (let ((mini-frame-show-parameters '((left . 0.5) (top . 0.3) (width . 0.6) (height . 1))))
       (mini-frame-mode 1)
       (unwind-protect (progn ,@body)
         (mini-frame-mode -1)
         (when (get-buffer "*chrome-scratch*") (kill-buffer "*chrome-scratch*"))))))

(defun drgnx-test-chrome--mini-read () (read-string "Chrome: "))

(ert-deftest drgnx-ui-chrome/mini-frame-typing ()
  "mini-frame while typing: the minibuffer in a child frame has chrome, and nothing is left after the read."
  (drgnx-test-chrome--with-mini-frame
    (pcase-let ((`(,root ,none ,rects) (drgnx-test-chrome--read-with-popup #'drgnx-test-chrome--mini-read "typing in a child")))
      (should rects)
      (drgnx-test-chrome--hidden root rects none))))

(ert-deftest drgnx-ui-chrome/mini-frame-cursor-blink ()
  "The cursor blinking in mini-frame's child frame: its upper corners stay the picture beneath."
  (drgnx-test-chrome--with-mini-frame
    (let* ((root (drgnx-uitest-root-frame))
           (none (progn (drgnx-test-chrome--settle) (drgnx-uitest-snapshot root))))
      (drgnx-test-chrome--reading
       #'drgnx-test-chrome--mini-read "blink"
       (lambda ()
         (should (drgnx-test-chrome--wait-for (lambda () (drgnx-test-chrome--children root)) 5))
         (drgnx-test-chrome--settle)
         (drgnx-test-chrome--blink-corners root (drgnx-test-chrome--children root) none)))
      (drgnx-test-chrome--hidden root (list (list 0 0 (nth 0 none) (nth 1 none))) none))))

;;;; display-buffer-in-child-frame

(ert-deftest drgnx-ui-chrome/display-buffer-in-child-frame ()
  "A GUI child frame made by `display-buffer-in-child-frame': chrome, and nothing left after it is deleted."
  (drgnx-test-chrome--with-chrome
    (let* ((root (drgnx-uitest-root-frame)) (buf (get-buffer-create "*chrome-dbicf*")) win)
      (switch-to-buffer (get-buffer-create "*chrome-scratch*"))
      (with-current-buffer buf (erase-buffer) (insert "shown by display-buffer-in-child-frame\nsecond line"))
      (drgnx-test-chrome--settle)
      (let ((none (drgnx-uitest-snapshot root)))
        (unwind-protect
            (progn
              (setq win (display-buffer buf '(display-buffer-in-child-frame
                                              (child-frame-parameters . ((left . 120) (top . 100) (width . 40)
                                                                         (height . 4) (minibuffer . nil)
                                                                         (undecorated . t) (no-accept-focus . t)
                                                                         (internal-border-width . 1)))
                                              (inhibit-switch-frame . t))))
              (should (window-live-p win))
              ;; a border colour unlike the root's, so a square corner shows
              (set-face-background 'child-frame-border "#204060" (window-frame win))
              (drgnx-test-chrome--settle)
              (let* ((popups (drgnx-test-chrome--children root))
                     (rects (progn (should (memq (window-frame win) popups))
                                   (drgnx-test-chrome--shown root popups none))))
                (delete-frame (window-frame win))
                (drgnx-test-chrome--hidden root rects none)))
          (kill-buffer buf)
          (kill-buffer "*chrome-scratch*"))))))

;;;; Generic checks

(defun drgnx-test-chrome--geometry-run (on)
  "Show, move, resize, hide and show a posframe with Glitnir ON (or off); the geometry notes after each call."
  (let ((glitnir-enable on) (name " *chrome-geometry*") (out nil) (f nil))
    (drgnx-test-chrome--settle)
    (unwind-protect
        (cl-flet ((note () (redisplay t) (sit-for 0.1)
                    (push (list (frame-edges f) (frame-edges f 'native-edges) (frame-position f)
                                (frame-visible-p f) (frame-width f) (frame-height f))
                          out)))
          (setq f (drgnx-test-chrome--pf name "geometry" :position '(200 . 160))) (note)
          (set-frame-position f 260 200) (note)
          (set-frame-size f 24 5) (note)
          (set-frame-size-and-position-pixelwise f 300 120 150 150) (note)
          (make-frame-invisible f) (note)
          (make-frame-visible f) (note)
          (modify-frame-parameters f '((left . 180) (top . 210))) (note)
          (nreverse out))
      (ignore-errors (posframe-delete-all)))))

(ert-deftest drgnx-ui-chrome/generic-geometry-parity ()
  "A child frame's geometry right after each Lisp call is what the Glitnir-off run reads (chrome never places it)."
  (drgnx-test-chrome--with-scratch
    (let* ((on (drgnx-test-chrome--geometry-run t))
           (off (drgnx-test-chrome--geometry-run nil)))
      (setq glitnir-enable t)
      (drgnx-test-chrome--settle)
      (should (equal on off))
      (drgnx-test-chrome--no-violations))))

(defun drgnx-test-chrome--focus-run (on)
  "Where the focus is after a posframe is shown, hidden, shown again and deleted, with Glitnir ON (or off)."
  (let ((glitnir-enable on) (name " *chrome-focus*") (out nil) (root (drgnx-uitest-root-frame)))
    (drgnx-test-chrome--settle)
    (unwind-protect
        (cl-flet ((note (what) (redisplay t) (sit-for 0.1)
                    (push (list what (eq (selected-frame) root) (buffer-name (window-buffer (selected-window)))
                                (frame-focus-state root))
                          out)))
          (let ((f (drgnx-test-chrome--pf name "focus" :position '(200 . 160))))
            (note 'shown)
            (posframe-hide name) (note 'hidden)
            (drgnx-test-chrome--pf name "focus" :position '(200 . 160)) (note 'again)
            (delete-frame f t) (note 'deleted))
          (nreverse out))
      (ignore-errors (posframe-delete-all)))))

(ert-deftest drgnx-ui-chrome/generic-focus-stays ()
  "Focus is where stock leaves it: the selected frame and window, and the root's focus state, on = off."
  (drgnx-test-chrome--with-scratch
    (let* ((on (drgnx-test-chrome--focus-run t))
           (off (drgnx-test-chrome--focus-run nil)))
      (setq glitnir-enable t)
      (drgnx-test-chrome--settle)
      (should (equal on off))
      (should (cl-every (lambda (n) (nth 1 n)) on)))))

(defun drgnx-test-chrome--set-fullscreen (root state)
  "Make ROOT's `fullscreen' parameter STATE (`fullboth' or nil) and wait until its size has settled."
  (set-frame-parameter root 'fullscreen state)
  (drgnx-test-chrome--wait-stable
   (lambda () (list (frame-pixel-width root) (frame-pixel-height root) (frame-parameter root 'fullscreen))) 8))

(defun drgnx-test-chrome--reshown (root name f string)
  "Hide posframe NAME (frame F), take the no-popup picture, show it again with STRING and wait for GTK's layout.
Return (NONE . FRAME): the picture without the popup and the reused frame."
  (posframe-hide name)
  (drgnx-test-chrome--settle)
  (let* ((none (drgnx-uitest-snapshot root))
         (f2 (drgnx-test-chrome--pf name string :position '(240 . 160))))
    (should (= (length (nth 2 none)) (* 4 (nth 0 none) (nth 1 none))))
    (drgnx-test-chrome--settle)
    (drgnx-test-chrome--wait-stable (lambda () (list (frame-edges root 'native-edges) (frame-edges f2 'outer-edges))))
    (should (eq f f2))
    (cons none f2)))

(ert-deftest drgnx-ui-chrome/generic-parent-resize-moves-shadows ()
  "The parent shrunk with a popup shown: the popup keeps its chrome, shadow and corners, on the resized picture."
  (drgnx-test-chrome--with-scratch
    (let* ((name " *chrome-parent*") (orig (frame-parameter root 'fullscreen))
           (f (drgnx-test-chrome--pf name "parent resize" :position '(240 . 160))) w1 h1)
      (drgnx-test-chrome--settle)
      (unwind-protect
          (progn
            (drgnx-test-chrome--set-fullscreen root nil) ; the session's root is fullscreen, which cannot be resized
            (setq w1 (frame-pixel-width root) h1 (frame-pixel-height root))
            (set-frame-size root (- w1 160) (- h1 80) t)
            (should (drgnx-test-chrome--wait-for (lambda () (< (frame-pixel-width root) w1)) 5))
            (drgnx-test-chrome--wait-stable (lambda () (list (frame-pixel-width root) (frame-pixel-height root))))
            (pcase-let* ((`(,none2 . ,f2) (drgnx-test-chrome--reshown root name f "parent resize"))
                         (rects (drgnx-test-chrome--shown root (list f2) none2)))
              (posframe-hide name)
              (drgnx-test-chrome--hidden root rects none2)))
        (when w1
          (set-frame-size root w1 h1 t)
          (drgnx-test-chrome--wait-stable (lambda () (list (frame-pixel-width root) (frame-pixel-height root)))))
        (drgnx-test-chrome--set-fullscreen root orig)
        (drgnx-test-chrome--settle)))))

(ert-deftest drgnx-ui-chrome/generic-parent-fullscreen-moves-shadows ()
  "The parent made fullscreen and back with a popup shown: chrome right on both pictures."
  (drgnx-test-chrome--with-scratch
    (let* ((name " *chrome-fullscreen*") (orig (frame-parameter root 'fullscreen))
           (f (drgnx-test-chrome--pf name "fullscreen" :position '(240 . 160))))
      (drgnx-test-chrome--settle)
      (unwind-protect
          (dolist (state '(nil fullboth))
            (drgnx-test-chrome--set-fullscreen root state)
            (drgnx-test-chrome--settle)
            (pcase-let* ((`(,none2 . ,f2) (drgnx-test-chrome--reshown root name f "fullscreen"))
                         (rects (drgnx-test-chrome--shown root (list f2) none2)))
              (posframe-hide name)
              (drgnx-test-chrome--hidden root rects none2)))
        (drgnx-test-chrome--set-fullscreen root orig)
        (drgnx-test-chrome--settle)))))

(defun drgnx-test-chrome--plain-child (root &rest params)
  "A shown child frame of ROOT with PARAMS added, in a buffer of its own."
  (let ((f (make-frame `((parent-frame . ,root) (minibuffer . nil) (left . 160) (top . 120) (width . 30)
                         (height . 6) (visibility . nil) (no-accept-focus . t) (no-other-frame . t)
                         (background-color . "#204060") ,@params))))
    (select-frame root)
    (set-window-buffer (frame-root-window f) (get-buffer-create "*chrome-plain*"))
    (make-frame-visible f)
    f))

(defmacro drgnx-test-chrome--with-plain-child (params &rest body)
  (declare (indent 1))
  `(drgnx-test-chrome--with-chrome
     (let* ((root (drgnx-uitest-root-frame)) (child nil))
       (ignore root)
       (unwind-protect
           (progn (setq child (apply #'drgnx-test-chrome--plain-child root ,params))
                  (drgnx-test-chrome--settle)
                  ,@body)
         (when (frame-live-p child) (delete-frame child t))
         (when (get-buffer "*chrome-plain*") (kill-buffer "*chrome-plain*"))))))

(ert-deftest drgnx-ui-chrome/generic-decorated-child-is-off-pixels ()
  "A decorated (not `undecorated') child frame gets no chrome: the picture is exactly Glitnir off's."
  (drgnx-test-chrome--with-plain-child '((undecorated . nil))
    (should (drgnx-test-chrome--children root))
    (let* ((on (drgnx-uitest-snapshot root)) (off (drgnx-test-chrome--off-snapshot root)))
      (should (drgnx-test-chrome--rows-equal-p on off nil)))
    (drgnx-test-chrome--no-violations)))

(ert-deftest drgnx-ui-chrome/generic-alpha-child-is-off-pixels ()
  "A child frame with an `alpha' gets no chrome: the picture is exactly Glitnir off's."
  (drgnx-test-chrome--with-plain-child '((undecorated . t) (alpha . 80))
    (should (drgnx-test-chrome--children root))
    (let* ((on (drgnx-uitest-snapshot root)) (off (drgnx-test-chrome--off-snapshot root)))
      (should (drgnx-test-chrome--rows-equal-p on off nil)))
    (drgnx-test-chrome--no-violations)))

;;; childframe-chrome-test.el ends here
