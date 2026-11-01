;;; palette-float-test.el --- GUI tests: the command palette floats in its own child frame -*- lexical-binding: t -*-
;; test-class: cond

;; `drgnx-palette' under vertico's `vertico-buffer' with `drgnx-palette-frame--display': the prompt, the typed text
;; and the candidates show in a child frame of the editor frame, while the minibuffer window and keyboard focus
;; stay in the editor frame.  Needs vertico from $DRGNX_CHILDFRAME_ELPA.  Without Glitnir the float is switched on
;; by stubbing `glitnir-active-p' (the route is a plain child frame, so it is the same code); the screenshot row
;; needs the real thing.

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
(defvar drgnx-look-palette)
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
           (cl-letf (((symbol-function 'glitnir-active-p) (lambda () t)))
             ,@body)
         (remove-hook 'minibuffer-exit-hook #'drgnx-palette-frame-hide)
         (unless was-multiform (vertico-multiform-mode -1))
         (unless was-vertico (vertico-mode -1))
         (drgnx-palette-frame-delete)))))

(defun drgnx-palette-float-test--reading (typed probe &optional ending)
  "Call `drgnx-palette' while TYPED arrives as keys; PROBE runs once the minibuffer holds them.
ENDING is the key list that ends the read after the probe (default C-g).  Return PROBE's value; an error it
signalled (a failed `should') is signalled again.  Conditions, not delays."
  (let* ((result nil) (stage 'open) (timer nil) (watchdog nil)
         (drgnx-jank-guard--timer-fn nil) (drgnx-guard--timer-fn nil)
         (drgnx-uitest--queue (list 'typed-from-the-timers-below))
         (finish (lambda () (cancel-timer timer) (cancel-timer watchdog))))
    (setq timer (run-with-timer
                 0.02 0.02
                 (lambda ()
                   (pcase stage
                     ('open (when (active-minibuffer-window)
                              (setq stage 'typed)
                              (setq unread-command-events
                                    (append (listify-key-sequence typed) unread-command-events))))
                     ('typed (when (and (null unread-command-events)
                                        (equal (with-current-buffer (window-buffer (active-minibuffer-window))
                                                 (minibuffer-contents-no-properties))
                                               typed))
                               (setq stage 'probed)
                               (funcall finish)
                               (setq result (condition-case err (list :ok (funcall probe)) (error (list :error err))))
                               (setq unread-command-events (or ending (list ?\C-g))))))))
          watchdog (run-at-time 60 nil (lambda ()
                                         (unless (eq stage 'probed)
                                           (funcall finish)
                                           (setq result (list :error (list 'error (format "the read never reached its probe (stage %s)" stage))))
                                           (setq unread-command-events (list 'return))))))
    (unwind-protect (condition-case nil (drgnx-palette) (quit nil))
      (funcall finish))
    (pcase result
      (`(:ok ,v) v)
      (`(:error ,err) (signal (car err) (cdr err)))
      (_ (error "The probe never ran")))))

(defun drgnx-palette-float-test--palette-frame ()
  (seq-find (lambda (f) (frame-parameter f 'drgnx-palette)) (frame-list)))

(defun drgnx-palette-float-test--shown-p (frame)
  "FRAME shows the minibuffer buffer with its candidates."
  (and (frame-live-p frame) (frame-visible-p frame)
       (with-current-buffer (window-buffer (frame-root-window frame))
         ;; vertico draws the candidates as the after-string of an overlay, not as buffer text
         (and (minibufferp)
              (seq-some (lambda (o) (let ((s (overlay-get o 'after-string))) (and (stringp s) (string-search "Do It" s))))
                        (overlays-in (point-min) (point-max)))))))

(ert-deftest palette-float-shows-child-frame-with-look ()
  (drgnx-palette-float-test--with-palette
    (let ((root (drgnx-uitest-root-frame)))
      (drgnx-palette-float-test--reading
       "Test"
       (lambda ()
         (let ((f (drgnx-test-wait (lambda () (drgnx-palette-float-test--palette-frame)) :what "the palette's frame")))
           (drgnx-test-wait (lambda () (drgnx-palette-float-test--shown-p f)) :what "the candidates in the frame")
           (drgnx-test-wait-presented)
           (should (eq (frame-parent f) root))
           (should (frame-visible-p f))
           ;; the look: the parameters of `drgnx-look-palette'
           (dolist (k '(corner-radius shadow backdrop-blur transition))
             (should (equal (frame-parameter f k) (alist-get k drgnx-look-palette))))
           ;; top-centre, inside the editor frame, at most 640 logical px wide
           (let ((e (frame-edges f 'outer-edges)) (w (frame-pixel-width root)))
             (should (<= (frame-pixel-width f) 640))
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
         (drgnx-test-wait (lambda () (drgnx-palette-float-test--shown-p first)) :what "the candidates in the frame"))
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
           (drgnx-test-wait (lambda () (drgnx-palette-float-test--shown-p f)) :what "the candidates in the frame"))))
      (should-not (frame-visible-p first))
      (should (= 1 (length (seq-filter (lambda (f) (frame-parameter f 'drgnx-palette)) (frame-list))))))))

(ert-deftest palette-float-focus-stays-in-the-editor-frame ()
  (drgnx-palette-float-test--with-palette
    (let ((root (drgnx-uitest-root-frame)))
      (drgnx-palette-float-test--reading
       "Test: Do That"
       (lambda ()
         (let ((f (drgnx-test-wait (lambda () (drgnx-palette-float-test--palette-frame)) :what "the palette's frame")))
           (drgnx-test-wait (lambda () (drgnx-palette-float-test--shown-p f)) :what "the candidates in the frame")
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
           (drgnx-test-wait (lambda () (drgnx-palette-float-test--shown-p f)) :what "the candidates in the frame")
           (drgnx-test-wait-presented)
           (let* ((shot (drgnx-uitest-capture (expand-file-name (format "scale-%s" scale) dir)))
                  (snap (drgnx-uitest-snapshot root))
                  (e (mapcar (lambda (v) (round (* scale v))) (frame-edges f 'outer-edges)))
                  (mid-x (/ (+ (nth 0 e) (nth 2 e)) 2)) (mid-y (/ (+ (nth 1 e) (nth 3 e)) 2)))
             (should (file-exists-p (plist-get shot :root)))
             (when (equal (drgnx-uitest-pixel snap mid-x mid-y) (drgnx-uitest-pixel none mid-x mid-y))
               (ert-skip "the snapshot of a root does not hold child frames yet (nsnap): no pixel checks"))
             ;; the palette is drawn where the frame is, and its upper-left corner pixel is cut (rounded)
             (should-not (equal (drgnx-uitest-pixel snap mid-x mid-y) (drgnx-uitest-pixel none mid-x mid-y)))
             (should (equal (cdr (drgnx-uitest-pixel snap (nth 0 e) (nth 1 e)))
                            (cdr (drgnx-uitest-pixel none (nth 0 e) (nth 1 e))))))))))))

(provide 'palette-float-test)
;;; palette-float-test.el ends here
