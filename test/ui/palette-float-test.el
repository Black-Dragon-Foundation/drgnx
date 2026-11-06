;;; palette-float-test.el --- GUI tests: the command palette floats in its own child frame -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; `drgnx-palette' under vertico's `vertico-buffer' with `drgnx-palette-frame--display': the prompt, the typed text
;; and the candidates show in a child frame of the editor frame, while the minibuffer window and keyboard focus
;; stay in the editor frame.  Needs vertico from $DRGNX_CHILDFRAME_ELPA.  Without Glitnir the float is switched on
;; by stubbing `glitnir-active-p' (the route is a plain child frame, so it is the same code); the screenshot row
;; needs the real thing.  The stub takes the primitive's optional FRAME: once the callers are native-compiled (the
;; session compiles them while the tier runs) they reach the stub through a trampoline that passes every argument.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-uitest)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-palette-float-test--repo        ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-palette-float-test--repo)))

(defvar vertico-multiform-categories)
(defvar vertico-count)
(declare-function drgnx-look-palette-current "drgnx-look" ())
(defvar drgnx-palette-float-test--ran nil "The command the palette ran.")
(declare-function glitnir-active-p "glitnir")
(declare-function vertico-mode "vertico")
(declare-function vertico-multiform-mode "vertico-multiform")
(declare-function drgnx-palette-frame-hide "drgnx-palette-frame")
(declare-function drgnx-palette-frame-delete "drgnx-palette-frame")

(defun drgnx-palette-float-test--run-it () (interactive) (setq drgnx-palette-float-test--ran 'it))
(defun drgnx-palette-float-test--run-other () (interactive) (setq drgnx-palette-float-test--ran 'other))

(defmacro drgnx-palette-float-test--with-palette (&rest body)
  "BODY with the palette as the completion module sets it up: vertico, multiform's entry, the exit hook."
  (declare (indent 0))
  `(progn
     (drgnx-uitest-require-childframe-packages)
     (require 'vertico) (require 'vertico-multiform) (require 'vertico-buffer)
     (require 'drgnx-palette) (require 'drgnx-palette-frame)
     (load (expand-file-name "modules/ui/drgnx-look" drgnx-palette-float-test--repo) nil t)
     (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
           (vertico-multiform-categories (list (cons 'drgnx-command drgnx-palette-frame-multiform)))
           (was-vertico (bound-and-true-p vertico-mode)) (was-multiform (bound-and-true-p vertico-multiform-mode))
           (drgnx-palette-float-test--ran nil))
       (drgnx-command-define 'it :title "Do It" :category "Test" :command #'drgnx-palette-float-test--run-it)
       (drgnx-command-define 'other :title "Do That" :category "Test" :command #'drgnx-palette-float-test--run-other)
       (add-hook 'minibuffer-exit-hook #'drgnx-palette-frame-hide)
       (vertico-mode 1) (vertico-multiform-mode 1)
       (unwind-protect
           (cl-letf (((symbol-function 'glitnir-active-p) (lambda (&optional _frame) t)))
             ,@body)
         (remove-hook 'minibuffer-exit-hook #'drgnx-palette-frame-hide)
         (unless was-multiform (vertico-multiform-mode -1))
         (unless was-vertico (vertico-mode -1))
         (drgnx-palette-frame-delete)))))

(defun drgnx-palette-float-test--reading (typed probe &optional ending)
  "Call `drgnx-palette' while TYPED arrives as keys; PROBE runs once the minibuffer holds them.
ENDING is the key list that ends the read after the probe (default C-g).  Return PROBE's value; an error it
signalled (a failed `should') is signalled again.  Handshake: the keys go in when the palette's minibuffer is set up,
and the probe runs from that minibuffer's `post-command-hook' once the last of them is in; no timer, no delay."
  (let* ((result nil) (stage 'open) (after nil)
         (drgnx-jank-guard--timer-fn nil) (drgnx-guard--timer-fn nil)
         (drgnx-uitest--queue (list 'typed-from-the-minibuffer-hooks-below))
         (setup (lambda ()
                  (setq stage 'typed)
                  ;; late, so vertico has drawn the candidates of the last key before the probe looks
                  (add-hook 'post-command-hook after 90 t)
                  (setq unread-command-events (append (listify-key-sequence typed) unread-command-events)))))
    (setq after (lambda ()
                  (when (and (eq stage 'typed) (null unread-command-events)
                             (equal (minibuffer-contents-no-properties) typed))
                    (setq stage 'probed)
                    (remove-hook 'post-command-hook after t)
                    (setq result (condition-case err (list :ok (funcall probe)) (error (list :error err))))
                    (setq unread-command-events (or ending (list ?\C-g))))))
    (minibuffer-with-setup-hook setup
      (condition-case nil (drgnx-palette) (quit nil)))
    (pcase result
      (`(:ok ,v) v)
      (`(:error ,err) (signal (car err) (cdr err)))
      (_ (error "The probe never ran (stage %s)" stage)))))

(defun drgnx-palette-float-test--palette-frame ()
  (seq-find (lambda (f) (frame-parameter f 'drgnx-palette)) (frame-list)))

(defun drgnx-palette-float-test--shown-p (frame)
  "FRAME shows the minibuffer buffer with its candidates."
  (and (frame-live-p frame) (frame-visible-p frame)
       (with-current-buffer (window-buffer (frame-root-window frame))
         ;; vertico draws the candidates as the before-string of an overlay at the end, not as buffer text
         (and (minibufferp)
              (seq-some (lambda (o) (let ((s (overlay-get o 'before-string))) (and (stringp s) (string-search "Do " s))))
                        (overlays-in (point-min) (point-max)))))))

(defun drgnx-palette-float-test--edges (frame)
  "FRAME's edges (LEFT TOP RIGHT BOTTOM) in its parent, in the frames' own pixels: its position and its size.  Not
`frame-edges': Nidhogg's Wayland shell answers a child frame's outer and native edges from (0, 0)."
  (let ((p (frame-position frame)))
    (list (car p) (cdr p) (+ (car p) (frame-pixel-width frame)) (+ (cdr p) (frame-pixel-height frame)))))

(defun drgnx-palette-float-test--wait-shown (frame)
  "Wait until FRAME shows the candidates; a timeout says what the minibuffer buffer and its overlays held."
  (condition-case err
      (drgnx-test-wait (lambda () (drgnx-palette-float-test--shown-p frame)) :what "the candidates in the frame")
    (ert-test-failed
     (ert-fail (list err :frame-live (frame-live-p frame) :visible (and (frame-live-p frame) (frame-visible-p frame))
                     :buffer (and (frame-live-p frame)
                                  (with-current-buffer (window-buffer (frame-root-window frame))
                                    (list (buffer-name) (minibufferp) (buffer-string)
                                          (mapcar (lambda (o) (list (overlay-start o) (overlay-end o)
                                                                    (overlay-get o 'window) (overlay-get o 'before-string)))
                                                  (overlays-in (point-min) (point-max)))
                                          vertico-count (bound-and-true-p vertico--input) (bound-and-true-p vertico--total)
                                          (bound-and-true-p vertico--candidates) (bound-and-true-p vertico-multiform--stack)
                                          (local-variable-p 'post-command-hook) post-command-hook
                                          completion-styles minibuffer-completion-table))))))))

(ert-deftest palette-float-shows-child-frame-with-look ()
  (drgnx-palette-float-test--with-palette
    (let ((root (drgnx-uitest-root-frame)))
      (drgnx-palette-float-test--reading
       "Test"
       (lambda ()
         (let ((f (drgnx-test-wait (lambda () (drgnx-palette-float-test--palette-frame)) :what "the palette's frame")))
           (drgnx-palette-float-test--wait-shown f)
           (drgnx-test-wait-presented)
           (should (eq (frame-parent f) root))
           (should (frame-visible-p f))
           ;; the look: the parameters for the theme's variant (`drgnx-look-palette-for'; the session's theme is a
           ;; light one, whose shadow is 0.22, not the dark 0.5 `drgnx-look-palette' holds as its standard value)
           (dolist (k '(corner-radius shadow backdrop-blur transition))
             (should (equal (frame-parameter f k) (alist-get k (drgnx-look-palette-current)))))
           ;; top-centre, inside the editor frame, at most 640 logical px wide
           (let ((e (drgnx-palette-float-test--edges f)) (w (frame-pixel-width root)))
             (should (<= (frame-pixel-width f) (drgnx-palette-frame--px root 640)))
             (should (>= (nth 0 e) 0)) (should (<= (nth 2 e) w))
             (should (< (abs (- (/ (+ (nth 0 e) (nth 2 e)) 2.0) (/ w 2.0))) 2))
             (should (< (nth 1 e) (/ (frame-pixel-height root) 3))))
           ;; `vertico-count' follows the window's height
           (with-current-buffer (window-buffer (frame-root-window f))
             (should (= vertico-count (default-value 'vertico-count))))))))))

(ert-deftest palette-float-typing-and-ret-runs-command ()
  (drgnx-palette-float-test--with-palette
    (drgnx-palette-float-test--reading
     "Test: Do It"
     (lambda ()
       (let ((f (drgnx-test-wait (lambda () (drgnx-palette-float-test--palette-frame)) :what "the palette's frame")))
         ;; the prompt and the typed text show in the palette frame's window, not in the editor frame's echo area
         (drgnx-test-wait
          (lambda ()
            (with-current-buffer (window-buffer (frame-root-window f))
              (and (minibufferp) (string-match-p "Command.*Test: Do It" (buffer-string)))))
          :what "the prompt and the typed text in the palette frame")
         (should (eq (window-buffer (frame-root-window f)) (window-buffer (active-minibuffer-window))))))
     (list 'return))
    (should (eq drgnx-palette-float-test--ran 'it))
    (let ((f (drgnx-palette-float-test--palette-frame)))
      (should-not (and f (frame-visible-p f))))))

(ert-deftest palette-float-c-g-hides-and-reuses ()
  (drgnx-palette-float-test--with-palette
    (let (first)
      (drgnx-palette-float-test--reading
       "Test"
       (lambda ()
         (setq first (drgnx-test-wait (lambda () (drgnx-palette-float-test--palette-frame)) :what "the palette's frame"))
         (drgnx-palette-float-test--wait-shown first))
       (list ?\C-g))
      (should-not drgnx-palette-float-test--ran)
      (should (frame-live-p first))
      (should-not (frame-visible-p first))
      ;; its window is plain again: not dedicated, no minibuffer buffer
      (let ((w (frame-root-window first)))
        (should-not (window-dedicated-p w))
        (should-not (window-parameter w 'no-other-window))
        (should-not (minibufferp (window-buffer w))))
      ;; the second use shows the same frame
      (drgnx-palette-float-test--reading
       "Test"
       (lambda ()
         (let ((f (drgnx-test-wait (lambda () (drgnx-palette-float-test--palette-frame)) :what "the palette's frame")))
           (should (eq f first))
           (drgnx-palette-float-test--wait-shown f))))
      (should-not (frame-visible-p first))
      (should (= 1 (length (seq-filter (lambda (f) (frame-parameter f 'drgnx-palette)) (frame-list))))))))

(ert-deftest palette-float-focus-stays-in-the-editor-frame ()
  (drgnx-palette-float-test--with-palette
    (let ((root (drgnx-uitest-root-frame)))
      (drgnx-palette-float-test--reading
       "Test: Do That"
       (lambda ()
         (let ((f (drgnx-test-wait (lambda () (drgnx-palette-float-test--palette-frame)) :what "the palette's frame")))
           (drgnx-palette-float-test--wait-shown f)
           (should (eq (window-frame (active-minibuffer-window)) root))
           (should (eq (selected-frame) root))
           (should (eq (selected-window) (active-minibuffer-window)))
           (should-not (eq (selected-frame) f))
           (should (frame-parameter f 'no-accept-focus))))
       (list 'return))
      ;; the typed answer reached the minibuffer window: the command ran
      (should (eq drgnx-palette-float-test--ran 'other)))))

(ert-deftest palette-float-screenshots ()
  "Screenshots of the open palette at the session's scale (1.25 and 2 for the P3 sign-off), and, when the snapshot
holds child frames, pixel checks: the palette's rectangle differs from the picture without it, its corner is cut."
  (skip-unless (drgnx-uitest-glitnir-p))
  (drgnx-palette-float-test--with-palette
    (let* ((root (drgnx-uitest-root-frame))
           (scale (frame-scale-factor root))
           (dir (or (getenv "DRGNX_PALETTE_SHOTS") (make-temp-file "drgnx-palette-shot" t)))
           (none (progn (drgnx-test-wait-presented) (drgnx-uitest-snapshot root))))
      (drgnx-palette-float-test--reading
       "Test"
       (lambda ()
         (let ((f (drgnx-test-wait (lambda () (drgnx-palette-float-test--palette-frame)) :what "the palette's frame")))
           (drgnx-palette-float-test--wait-shown f)
           (drgnx-test-wait-presented)
           (let* ((shot (drgnx-uitest-capture (expand-file-name (format "scale-%s" scale) dir)))
                  (snap (drgnx-uitest-snapshot root))
                  ;; the snapshot is in device pixels, which is what a frame of Nidhogg's Wayland shell counts
                  (e (mapcar (lambda (v) (round (* (if (featurep 'nidhogg-wayland) 1 scale) v)))
                             (drgnx-palette-float-test--edges f))))
             (should (file-exists-p (plist-get shot :root)))
             ;; the palette's rectangle as a whole, not one pixel: its middle may be its background, the root's colour
             (when (drgnx-uitest-region-equal-p snap none e)
               (ert-skip "the snapshot of a root does not hold child frames yet (nsnap): no pixel checks"))
             ;; the palette is drawn where the frame is, and its upper-left corner pixel is cut (rounded)
             (let ((corner (cdr (drgnx-uitest-pixel snap (nth 0 e) (nth 1 e))))
                   (bare (cdr (drgnx-uitest-pixel none (nth 0 e) (nth 1 e))))
                   (inside (cdr (drgnx-uitest-pixel snap (+ (nth 0 e) (ceiling (* scale 14))) (+ (nth 1 e) (ceiling (* scale 14)))))))
               ;; cut: what lies beneath, at most darkened by the shadow, not the palette's own pixel
               (should (cl-every #'<= corner bare))
               (should-not (equal corner inside))))))))))

(provide 'palette-float-test)
;;; palette-float-test.el ends here
