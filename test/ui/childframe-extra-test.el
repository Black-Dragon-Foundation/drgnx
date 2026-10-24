;;; childframe-extra-test.el --- GUI tests: Glitnir's §10.3 additions -*- lexical-binding: t -*-

;; The compositor design's added scenarios (§10.3) on top of the §3.4 matrix (childframe-chrome-test.el, whose helpers
;; these use): the core rows (the four §3.3 criterion-1 scenarios) at 1.5 and at the user's five 125 % setups, the core
;; rows under KWin, a root moved to a monitor of another scale with a popup shown, the nested `make-frame-visible'
;; path, child frames that take the focus, IME preedit in a child frame, a shadow beside GTK's scroll bar and tool bar,
;; and an xwidget under a popup.  Each test that needs a session of its own kind (a scale, a size, a compositor, two
;; monitors) skips in any other, so one run of this file per kind runs its tests: see docs/develop/harness.md.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'dbus)
(require 'drgnx-uitest)

(unless (ert-test-boundp 'drgnx-ui-chrome/posframe-show-hide-100)   ; the session loads test/ui in name order
  (load (expand-file-name "childframe-chrome-test" (or (getenv "DRGNX_UI_TEST") (file-name-directory (macroexp-file-name))))
        nil t))

(defvar glitnir-enable)
(defvar glitnir-debug)
(defvar posframe--frame)
(defvar mini-frame-show-parameters)
(defvar pgtk-preedit-overlay)
(declare-function glitnir-stats "glitnir")
(declare-function posframe-hide "posframe")
(declare-function posframe-delete-all "posframe")
(declare-function mini-frame-mode "mini-frame")
(declare-function vertico-mode "vertico")
(declare-function vertico-posframe-mode "vertico-posframe")
(declare-function drgnx-test-chrome--settle "childframe-chrome-test")
(declare-function drgnx-test-chrome--rect "childframe-chrome-test")
(declare-function drgnx-test-chrome--grow "childframe-chrome-test")
(declare-function drgnx-test-chrome--shown "childframe-chrome-test")
(declare-function drgnx-test-chrome--hidden "childframe-chrome-test")
(declare-function drgnx-test-chrome--pf "childframe-chrome-test")
(declare-function drgnx-test-chrome--wait-for "childframe-chrome-test")
(declare-function drgnx-test-chrome--wait-stable "childframe-chrome-test")
(declare-function drgnx-test-chrome--children "childframe-chrome-test")
(declare-function drgnx-test-chrome--off-snapshot "childframe-chrome-test")
(declare-function drgnx-test-chrome--rows-equal-p "childframe-chrome-test")
(declare-function drgnx-test-chrome--corner-cut-p "childframe-chrome-test")
(declare-function drgnx-test-chrome--no-violations "childframe-chrome-test")
(declare-function drgnx-test-chrome--check-chrome "childframe-chrome-test")
(declare-function drgnx-test-chrome--check-stacking "childframe-chrome-test")
(declare-function drgnx-test-chrome--reading "childframe-chrome-test")
(declare-function drgnx-test-chrome--first-diff "childframe-chrome-test")
(declare-function drgnx-test-chrome--clip "childframe-chrome-test")
(defvar drgnx-test-chrome--margin)
(defvar drgnx-jank-guard--timer-fn)
(defvar drgnx-guard--timer-fn)

;;;; The session's kind

(defconst drgnx-test-extra--core-rows
  '(drgnx-ui-chrome/corfu-and-popupinfo-overlap drgnx-ui-chrome/posframe-show-hide-100
                                                drgnx-ui-chrome/eldoc-box-beside-corfu drgnx-ui-chrome/popup-at-the-right-bottom-edge)
  "The core rows: the §3.3 criterion-1 scenarios (the §3.4 subset), run whole in each kind of session.")

(defconst drgnx-test-extra--125-setups
  '((u1 . "2560x1440") (u2 . "1920x1080") (u3 . "2560x1600") (u4 . "2880x1800") (u5 . "3840x2160"))
  "The user's 125 % setups (U1–U5): the monitor size in device pixels, each at scale 1.25.")

(defun drgnx-test-extra--scales ()
  "The session's monitor scales (numbers, one per monitor; (1) at scale 1), from DRGNX_UI_SESSION_SCALES."
  (or (mapcar #'string-to-number (split-string (or (getenv "DRGNX_UI_SESSION_SCALES") "") " " t)) '(1)))

(defun drgnx-test-extra--size () (getenv "DRGNX_UI_SESSION_SIZE"))

(defun drgnx-test-extra--kwin-p ()
  "Non-nil in a KWin session (the harness sets what a Plasma session sets)."
  (equal (getenv "XDG_CURRENT_DESKTOP") "KDE"))

(defun drgnx-test-extra--mutter-p ()
  (and (not (drgnx-test-extra--kwin-p)) (null (getenv "SWAYSOCK")) (getenv "WAYLAND_DISPLAY")))

(defun drgnx-test-extra--check-scale (root scale)
  "ROOT shows SCALE as GTK 3 does: `frame-scale-factor' = (ceiling SCALE), its monitor's geometry = size / SCALE
times that (R12)."
  (let ((factor (frame-scale-factor root))
        (geometry (alist-get 'geometry (frame-monitor-attributes root))))
    (unless (drgnx-uitest-scale-ready-p scale (drgnx-test-extra--size) factor geometry)
      (ert-fail (list "the root does not show the session's scale" :scale scale :size (drgnx-test-extra--size)
                      :frame-scale-factor factor :monitor-geometry geometry)))))

(defun drgnx-test-extra--run-core-rows ()
  "Run every core row's body here; a row's failure fails the caller with the row's name."
  (dolist (name drgnx-test-extra--core-rows)
    (condition-case err (funcall (ert-test-body (ert-get-test name)))
      (ert-test-failed (ert-fail (list :row name :failed (cadr err)))))))

;;;; Fractional scales (R12, DP-8: gdctl on headless mutter)

(ert-deftest drgnx-ui-chrome/fractional-1-5 ()
  "The core rows at monitor scale 1.5 (`DRGNX_UI_SCALE=1.5'): GTK 3 draws at 2 and mutter scales the buffer down."
  (skip-unless (equal (drgnx-test-extra--scales) '(1.5)))
  (drgnx-test-extra--check-scale (drgnx-uitest-root-frame) 1.5)
  (drgnx-test-extra--run-core-rows))

(defmacro drgnx-test-extra--at-125 (setup)
  "The body of SETUP's test (a key of `drgnx-test-extra--125-setups'): skip unless the session is that setup, then
the scale check and the core rows.  A macro: `skip-unless' exists only inside the body of `ert-deftest'.  (The tests
are written out: the runner's selector prefilter reads their names from the `ert-deftest' forms.)"
  `(progn (skip-unless (and (equal (drgnx-test-extra--scales) '(1.25))
                            (equal (drgnx-test-extra--size) (alist-get ',setup drgnx-test-extra--125-setups))))
          (drgnx-test-extra--check-scale (drgnx-uitest-root-frame) 1.25)
          (drgnx-test-extra--run-core-rows)))

(ert-deftest drgnx-ui-chrome/fractional-1-25-u1 ()
  "The core rows at the 125 % setup U1: `DRGNX_UI_SIZE=2560x1440', `DRGNX_UI_SCALE=1.25'."
  (drgnx-test-extra--at-125 u1))

(ert-deftest drgnx-ui-chrome/fractional-1-25-u2 ()
  "The core rows at the 125 % setup U2: `DRGNX_UI_SIZE=1920x1080', `DRGNX_UI_SCALE=1.25'."
  (drgnx-test-extra--at-125 u2))

(ert-deftest drgnx-ui-chrome/fractional-1-25-u3 ()
  "The core rows at the 125 % setup U3: `DRGNX_UI_SIZE=2560x1600', `DRGNX_UI_SCALE=1.25'."
  (drgnx-test-extra--at-125 u3))

(ert-deftest drgnx-ui-chrome/fractional-1-25-u4 ()
  "The core rows at the 125 % setup U4: `DRGNX_UI_SIZE=2880x1800', `DRGNX_UI_SCALE=1.25'."
  (drgnx-test-extra--at-125 u4))

(ert-deftest drgnx-ui-chrome/fractional-1-25-u5 ()
  "The core rows at the 125 % setup U5: `DRGNX_UI_SIZE=3840x2160', `DRGNX_UI_SCALE=1.25'."
  (drgnx-test-extra--at-125 u5))

;;;; KWin

(ert-deftest drgnx-ui-chrome/kwin-core-rows ()
  "The core rows under KWin (`--compositor kwin'), at the session's scale (run at 1 and 2)."
  (skip-unless (drgnx-test-extra--kwin-p))
  (drgnx-test-extra--check-scale (drgnx-uitest-root-frame) (car (drgnx-test-extra--scales)))
  (drgnx-test-extra--run-core-rows))

;;;; Mixed DPI: the root moved to a monitor of another scale

(defun drgnx-test-extra--gdctl (&rest args)
  "Run gdctl with ARGS on the session's mutter; signal with its output unless it succeeded."
  (with-temp-buffer
    (unless (eq 0 (apply #'call-process "gdctl" nil t nil args))
      (ert-fail (list "gdctl failed" :args args :output (buffer-string))))))

(defun drgnx-test-extra--logical-monitors (monitors)
  "gdctl arguments for logical MONITORS ((K . SCALE) ...), side by side from x 0, the first primary."
  (let ((w (car (mapcar #'string-to-number (split-string (drgnx-test-extra--size) "x")))) (x 0) (first t))
    (cl-loop for (k . s) in monitors
             append (prog1 (append '("--logical-monitor") (and first '("--primary"))
                                   (list "--monitor" (format "Meta-%d" k) "--scale" (number-to-string s)
                                         "--x" (number-to-string x) "--y" "0"))
                      (setq first nil x (+ x (round (/ (float w) s))))))))

(defun drgnx-test-extra--mismatches (root) (or (plist-get (glitnir-stats root) :scale-mismatch) 0))

(ert-deftest drgnx-ui-chrome/mixed-dpi-move ()
  "The root moved to a monitor of another scale with a popup shown (`DRGNX_UI_MONITORS=2', `DRGNX_UI_SCALES=\"1 2\"').
The first monitor is taken out of mutter's layout (gdctl), so mutter moves the root to the second.  After 1.5 s (pgtk
looks at a monitor's scale on a 1 s timer) the root is at the new scale, every pixel outside the popup is the stock
picture's (full damage: nothing of the old scale is left), the popup's chrome and shadow are those of a popup shown at
the new scale, and `:scale-mismatch' counted paints only during the wait."
  (let ((scales (drgnx-test-extra--scales)))
    (skip-unless (and (= (length scales) 2) (/= (nth 0 scales) (nth 1 scales))
                      (drgnx-test-extra--mutter-p) (executable-find "gdctl")))
    (drgnx-test-chrome--with-scratch
      (let ((name " *extra-mixed*") (moved nil))
        (unwind-protect
            (let* ((f (drgnx-test-chrome--pf name "a popup that moves with its root" :position '(200 . 120)))
                   (s1 (progn (drgnx-test-chrome--settle) (frame-scale-factor root))))
              (drgnx-test-extra--check-scale root (nth 0 scales))
              (drgnx-test-chrome--shown root (list f) none)
              (let ((n0 (drgnx-test-extra--mismatches root)))
                (apply #'drgnx-test-extra--gdctl "set" (drgnx-test-extra--logical-monitors (list (cons 1 (nth 1 scales)))))
                (setq moved t)
                ;; the wait: ≥ 1.5 s, redisplaying, before any probe
                (let ((end (+ (float-time) 1.6))) (while (< (float-time) end) (redisplay t) (sit-for 0.1)))
                (drgnx-test-chrome--wait-stable (lambda () (list (frame-pixel-width root) (frame-pixel-height root)
                                                                 (frame-edges f 'outer-edges))))
                (unless (= (frame-scale-factor root) (ceiling (nth 1 scales)))
                  (ert-fail (list "the root did not reach the second monitor's scale" :before s1
                                  :after (frame-scale-factor root) :monitor (frame-monitor-attributes root))))
                (let* ((n1 (drgnx-test-extra--mismatches root))
                       (moved-snap (drgnx-uitest-snapshot root))   ; before anything redraws the root whole
                       (off (drgnx-test-chrome--off-snapshot root))
                       (rect (drgnx-test-chrome--rect f root))
                       (m (ceiling (* (frame-scale-factor root) drgnx-test-chrome--margin))))
                  ;; full damage: outside the popup and its shadow, the moved picture is the stock one
                  (should (drgnx-test-chrome--rows-equal-p moved-snap off (list (drgnx-test-chrome--grow rect m))))
                  ;; the popup, its corners and its shadow are those of a popup shown afresh at the new scale
                  (posframe-hide name)
                  (drgnx-test-chrome--settle)
                  (let* ((none2 (drgnx-uitest-snapshot root))
                         (f2 (drgnx-test-chrome--pf name "a popup that moves with its root" :position '(200 . 120))))
                    (drgnx-test-chrome--settle)
                    (should (eq f f2))
                    (let ((fresh (drgnx-uitest-snapshot root))
                          (region (drgnx-test-chrome--clip (drgnx-test-chrome--grow rect m) moved-snap)))
                      (should (equal (drgnx-test-chrome--rect f2 root) rect))
                      (unless (drgnx-uitest-region-equal-p moved-snap fresh region :tolerance 0 :ignore-alpha t)
                        (ert-fail (list "the moved popup is not drawn as one shown at the new scale" :region region
                                        :first-pixel (drgnx-test-chrome--first-diff moved-snap fresh region)))))
                    (let ((rects (drgnx-test-chrome--shown root (list f2) none2)))
                      ;; no mismatch after the wait: paints at the new scale (a move, a redraw) count none
                      (set-frame-position f2 240 140)
                      (drgnx-test-chrome--settle)
                      (redraw-frame root)
                      (drgnx-test-chrome--settle)
                      (unless (= (drgnx-test-extra--mismatches root) n1)
                        (ert-fail (list "scale mismatches after the wait" :before-move n0 :after-wait n1
                                        :now (drgnx-test-extra--mismatches root))))
                      (posframe-hide name)
                      (drgnx-test-chrome--hidden root (cons (drgnx-test-chrome--rect f2 root) rects) none2))))))
          (when moved                     ; the session's own layout again
            (apply #'drgnx-test-extra--gdctl "set"
                   (drgnx-test-extra--logical-monitors (list (cons 0 (nth 0 scales)) (cons 1 (nth 1 scales)))))
            (drgnx-test-chrome--wait-stable (lambda () (list (frame-scale-factor root) (frame-pixel-width root))))))))))

;;;; The nested `make-frame-visible' path

(defun drgnx-test-extra--nested-run (root on none)
  "Show a child frame of ROOT with `make-frame-visible' and read its geometry at once, then type into ROOT, with
Glitnir ON (or off).  The notes: geometry at once, after typing, after GTK's layout.  ON: the chrome is checked (NONE is
the no-popup picture) and the popup hidden again, with no residue."
  (let ((glitnir-enable on) (f nil) (out nil))
    (drgnx-test-chrome--settle)
    (unwind-protect
        (progn
          (with-current-buffer (get-buffer-create "*extra-nested*") (erase-buffer) (insert "a child frame\nshown"))
          (setq f (make-frame `((parent-frame . ,root) (minibuffer . nil) (left . 240) (top . 220) (width . 30)
                                (height . 4) (visibility . nil) (undecorated . t) (no-accept-focus . t)
                                (no-other-frame . t) (internal-border-width . 1) (child-frame-border-width . 1))))
          (select-frame root)
          (set-window-buffer (frame-root-window f) "*extra-nested*")
          (set-face-background 'child-frame-border "#204060" f)   ; unlike the root, so a square corner shows
          (make-frame-visible f)
          ;; at once: no redisplay, no wait between the call and the reads
          (push (list :at-once (frame-visible-p f) (frame-edges f 'outer-edges) (frame-edges f 'native-edges)
                      (frame-position f) (frame-pixel-width f) (frame-pixel-height f))
                out)
          (drgnx-uitest-run (drgnx-uitest-type-events "typed beside a popup") 20)
          (push (list :typed (buffer-substring-no-properties (point-min) (point-max)) (frame-visible-p f)
                      (eq (selected-frame) root) (frame-edges f 'outer-edges))
                out)
          (push (cons :settled (drgnx-test-chrome--wait-stable (lambda () (list (frame-edges f 'outer-edges)
                                                                                (frame-edges f 'native-edges)))))
                out)
          (when on
            (let ((rects (drgnx-test-chrome--shown root (list f) none)))
              (make-frame-invisible f)
              (drgnx-test-chrome--hidden root rects none)))
          (nreverse out))
      (when (frame-live-p f) (delete-frame f t))
      (kill-buffer "*extra-nested*"))))

(ert-deftest drgnx-ui-chrome/nested-make-frame-visible ()
  "A child frame shown with `make-frame-visible' (pgtk waits for the map, drawing meanwhile): its geometry read at once
is what Glitnir off reads, the keys typed next reach the root, and the popup has chrome and leaves nothing behind."
  (drgnx-test-chrome--with-scratch
    (let* ((text (buffer-string))         ; the picture NONE shows
           (on (drgnx-test-extra--nested-run root t none))
           (_ (progn (erase-buffer) (insert text)))
           (off (drgnx-test-extra--nested-run root nil none)))
      (setq glitnir-enable t)
      (redraw-frame root)
      (drgnx-test-chrome--settle)
      (should (nth 1 (assq :at-once on)))                      ; visible at once
      (should (equal (nth 1 (assq :typed on)) (concat text "typed beside a popup")))
      (should (nth 3 (assq :typed on)))                        ; the root kept the focus
      (unless (equal on off)
        (ert-fail (list "Glitnir on and off differ" :on on :off off)))
      (drgnx-test-chrome--no-violations))))

;;;; Child frames that take the focus

(defun drgnx-test-extra--focus-read (root reader typed on)
  "Read with READER while TYPED arrives, with Glitnir ON (or off); the notes on the focus while it reads and after.
ON: the popups' chrome is asserted while it reads (`drgnx-test-chrome--shown') and their place after."
  (let* ((glitnir-enable on)
         (none (progn (drgnx-test-chrome--settle) (drgnx-uitest-snapshot root)))
         (rects nil) (during nil) (result nil))
    (drgnx-test-chrome--reading
     (lambda () (setq result (funcall reader))) typed
     (lambda ()
       (should (drgnx-test-chrome--wait-for (lambda () (drgnx-test-chrome--children root)) 5))
       (drgnx-test-chrome--settle)
       (let ((sel (selected-frame)))
         (setq during (list :selected-is-root (eq sel root) :selected-is-child (eq (frame-parent sel) root)
                            :minibuffer-selected (minibufferp (window-buffer (selected-window)))
                            :contents (drgnx-test-extra--minibuffer-contents)
                            :root-focus (frame-focus-state root)
                            :children (length (drgnx-test-chrome--children root)))))
       (when on (setq rects (drgnx-test-chrome--shown root (drgnx-test-chrome--children root) none)))))
    (should (drgnx-test-chrome--wait-for (lambda () (null (drgnx-test-chrome--children root)))))
    (when on (drgnx-test-chrome--hidden root rects none))
    (list :during during :result result :after-root-selected (eq (selected-frame) root)
          :after-root-focus (frame-focus-state root))))

(ert-deftest drgnx-ui-chrome/focus-taking-child ()
  "vertico-posframe and mini-frame read in a child frame: the focus is where stock has it while reading (mini-frame's
child takes it) and after, the typed text arrives, and the popups have chrome."
  (dolist (pkg '(vertico-posframe mini-frame))
    (drgnx-test-chrome--with-chrome
      (require 'vertico) (require 'vertico-posframe) (require 'mini-frame)
      (let ((root (drgnx-uitest-root-frame))  ; once: mini-frame detaches its frame
            (mini-frame-show-parameters '((left . 0.5) (top . 0.3) (width . 0.6) (height . 1))))
        (switch-to-buffer (get-buffer-create "*chrome-scratch*"))
        (pcase pkg
          ('vertico-posframe (vertico-mode 1) (vertico-posframe-mode 1))
          ('mini-frame (mini-frame-mode 1)))
        (unwind-protect
            (let* ((reader (if (eq pkg 'mini-frame) (lambda () (read-string "Focus: "))
                             (lambda () (completing-read "Focus: " '("focus-one" "focus-two" "other")))))
                   (on (drgnx-test-extra--focus-read root reader "focus" t))
                   (off (drgnx-test-extra--focus-read root reader "focus" nil)))
              (setq glitnir-enable t)
              (redraw-frame root)
              (drgnx-test-chrome--settle)
              (should (equal (plist-get (plist-get on :during) :contents) "focus"))
              (should (plist-get on :after-root-selected))
              (when (eq pkg 'mini-frame) (should (plist-get (plist-get on :during) :selected-is-child)))
              (unless (equal on off)
                (ert-fail (list "Glitnir on and off differ" :package pkg :on on :off off))))
          (pcase pkg
            ('vertico-posframe (vertico-posframe-mode -1) (vertico-mode -1))
            ('mini-frame (mini-frame-mode -1)))
          (when (get-buffer "*chrome-scratch*") (kill-buffer "*chrome-scratch*")))
        (drgnx-test-chrome--no-violations)))))

;;;; IME preedit in a child frame

;; Keys reach GTK (and its input method) only from a keyboard: headless mutter's RemoteDesktop service gives the test
;; one (`NotifyKeyboardKeysym'), with mutter's built-in "us" keymap.  That keymap has no dead keys, so the composed
;; sequence is GTK's own of `gtk-im-context-simple' (the session's GTK_IM_MODULE): Control+Shift+U, the code point's
;; hex digits, Space.  pgtk passes key presses, not releases, to the input method, so the modifiers stay held until
;; the Space has committed.

(defconst drgnx-test-extra--rd "org.gnome.Mutter.RemoteDesktop")
(defvar drgnx-test-extra--rd-session nil "The RemoteDesktop session's object path while a test types through mutter.")

(defun drgnx-test-extra--rd-start ()
  (setq drgnx-test-extra--rd-session
        (dbus-call-method :session drgnx-test-extra--rd "/org/gnome/Mutter/RemoteDesktop" drgnx-test-extra--rd
                          "CreateSession"))
  (dbus-call-method :session drgnx-test-extra--rd drgnx-test-extra--rd-session
                    (concat drgnx-test-extra--rd ".Session") "Start"))

(defun drgnx-test-extra--rd-stop ()
  (when drgnx-test-extra--rd-session
    (ignore-errors (dbus-call-method :session drgnx-test-extra--rd drgnx-test-extra--rd-session
                                     (concat drgnx-test-extra--rd ".Session") "Stop"))
    (setq drgnx-test-extra--rd-session nil)))

(defun drgnx-test-extra--key (keysym down)
  (dbus-call-method :session drgnx-test-extra--rd drgnx-test-extra--rd-session (concat drgnx-test-extra--rd ".Session")
                    "NotifyKeyboardKeysym" :uint32 keysym (and down t)))

(defun drgnx-test-extra--tap (&rest keysyms)
  (dolist (k keysyms) (drgnx-test-extra--key k t) (drgnx-test-extra--key k nil)))

(defun drgnx-test-extra--steps (steps on-error)
  "Run STEPS ((DELAY . FN) ...) from timers one after another, each DELAY seconds after the previous one ended (so a
slow step never runs the next one early).  An error in a step stops the rest and is passed to ON-ERROR.  Return a
function that cancels the step still pending."
  (let ((timer nil))
    (cl-labels ((next (rest)
                  (when rest
                    (setq timer (run-at-time (caar rest) nil
                                             (lambda ()
                                               (condition-case err (progn (funcall (cdar rest)) (next (cdr rest)))
                                                 (error (funcall on-error err)))))))))
      (next steps))
    (lambda () (when timer (cancel-timer timer)))))

(defun drgnx-test-extra--minibuffer-contents ()
  (let ((w (active-minibuffer-window)))
    (and w (with-current-buffer (window-buffer w) (minibuffer-contents-no-properties)))))

(defun drgnx-test-extra--preedit ()
  "The preedit text pgtk shows (`pgtk-preedit-text'), without properties, or nil."
  (and (boundp 'pgtk-preedit-overlay) (overlayp pgtk-preedit-overlay) (overlay-buffer pgtk-preedit-overlay)
       (let ((s (overlay-get pgtk-preedit-overlay 'before-string))) (and s (substring-no-properties s)))))

(ert-deftest drgnx-ui-chrome/ime-preedit-in-child ()
  "IME preedit in mini-frame's child frame: GTK's input method composes \"é\" (Control+Shift+U e 9 Space).  The
preedit is drawn inside the chromed child (its pixels change, its corners stay cut, nothing outside it changes), and
the committed text is \"é\"."
  (skip-unless (and (featurep 'dbusbind) (drgnx-test-extra--mutter-p)
                    (equal (getenv "GTK_IM_MODULE") "gtk-im-context-simple")
                    (member drgnx-test-extra--rd (ignore-errors (dbus-list-names :session)))))
  (drgnx-test-chrome--with-chrome
    (require 'mini-frame)
    (let ((root (drgnx-uitest-root-frame))
          (mini-frame-show-parameters '((left . 0.5) (top . 0.3) (width . 0.6) (height . 1)))
          (shown nil) (before nil) (during nil) (committed nil) (result nil) (fail nil)
          (ctrl #xffe3) (shift #xffe1))
      (switch-to-buffer (get-buffer-create "*chrome-scratch*"))
      (mini-frame-mode 1)
      (drgnx-test-extra--rd-start)
      (unwind-protect
          (let* ((none (progn (drgnx-test-chrome--settle) (drgnx-uitest-snapshot root)))
                 (cancel
                  (drgnx-test-extra--steps
                   (list
                    (cons 0.5 (lambda () (drgnx-test-extra--tap shift)))   ; the virtual keyboard's first key reaches no one
                    (cons 0.5 (lambda ()
                                (should (drgnx-test-chrome--wait-for (lambda () (drgnx-test-chrome--children root)) 5))
                                (drgnx-test-chrome--settle)
                                (setq shown (drgnx-test-chrome--shown root (drgnx-test-chrome--children root) none)
                                      before (drgnx-uitest-snapshot root))))
                    (cons 0.3 (lambda ()
                                (drgnx-test-extra--key ctrl t) (drgnx-test-extra--key shift t)
                                (drgnx-test-extra--tap #x75 #x65 #x39)))   ; u e 9
                    (cons 1.0 (lambda ()
                                (drgnx-test-chrome--settle)
                                (setq during (list :preedit (drgnx-test-extra--preedit)
                                                   :contents (drgnx-test-extra--minibuffer-contents)
                                                   :snap (drgnx-uitest-snapshot root)))))
                    (cons 0.2 (lambda ()
                                (drgnx-test-extra--tap #x20)                ; Space commits
                                (drgnx-test-extra--key shift nil) (drgnx-test-extra--key ctrl nil)))
                    (cons 1.0 (lambda ()
                                (drgnx-test-chrome--settle)
                                (setq committed (list :preedit (drgnx-test-extra--preedit)
                                                      :contents (drgnx-test-extra--minibuffer-contents)))
                                (drgnx-test-extra--tap #xff0d)))            ; Return ends the read
                    ;; only if mutter's Return did not arrive
                    (cons 3.0 (lambda () (when (active-minibuffer-window)
                                           (setq fail '(error "the Return typed through mutter did not end the read")
                                                 unread-command-events (list 'return))))))
                   (lambda (err) (setq fail err unread-command-events (list 'return))))))
            (unwind-protect
                (let ((drgnx-jank-guard--timer-fn nil) (drgnx-guard--timer-fn nil))
                  (setq result (read-string "IME: ")))
              (funcall cancel))
            (when fail (signal (car fail) (cdr fail)))
            (should shown)
            ;; the preedit, drawn in the child: only the child's pixels changed, and its corners are still cut
            ;; GTK shows the keys as typed: Shift is held, so \"uE9\"
            (should (equal (downcase (or (plist-get during :preedit) "")) "ue9"))
            (should (equal (plist-get during :contents) ""))
            (let* ((snap (plist-get during :snap)) (r (car shown))
                   (m (ceiling (* (frame-scale-factor root) drgnx-test-chrome--margin))))
              (should-not (drgnx-uitest-region-equal-p snap before r :ignore-alpha t))
              (should (drgnx-test-chrome--rows-equal-p snap before (list (drgnx-test-chrome--grow r m))))
              (dolist (c (list (cons (nth 0 r) (nth 1 r)) (cons (1- (nth 2 r)) (nth 1 r))))
                (should (equal (drgnx-uitest-pixel snap (car c) (cdr c)) (drgnx-uitest-pixel before (car c) (cdr c))))))
            ;; the commit: the composed character, no preedit left
            (should (member (plist-get committed :preedit) '(nil "")))
            (should (equal (plist-get committed :contents) "é"))
            (should (equal result "é"))
            (should (drgnx-test-chrome--wait-for (lambda () (null (drgnx-test-chrome--children root)))))
            (drgnx-test-chrome--hidden root shown none))
        (drgnx-test-extra--rd-stop)
        (mini-frame-mode -1)
        (when (get-buffer "*chrome-scratch*") (kill-buffer "*chrome-scratch*"))))))

;;;; A shadow beside GTK's scroll bar and tool bar

(ert-deftest drgnx-ui-chrome/shadow-beside-scroll-bars-and-tool-bar ()
  "A popup flush under the tool bar and 4 px left of the scroll bar: its shadow reaches the scroll bar and ends under it
\(the bar's pixels are stock's), the tool bar stays outside the root's picture, and nothing else changes."
  (drgnx-test-chrome--with-scratch
    (let ((name " *extra-bars*"))
      (unwind-protect
          (progn
            (modify-frame-parameters root '((vertical-scroll-bars . right) (tool-bar-lines . 1)))
            (drgnx-test-chrome--wait-stable (lambda () (list (frame-pixel-width root) (frame-pixel-height root)
                                                             (frame-geometry root))))
            (let* ((s (frame-scale-factor root))
                   (w (frame-root-window root))
                   (edges (window-edges w nil nil t))
                   (sbw (window-scroll-bar-width w))
                   (sb-left (- (nth 2 edges) sbw))
                   (geometry (frame-geometry root))
                   (none (drgnx-uitest-snapshot root))
                   (f (drgnx-test-chrome--pf name "beside the bars"
                                             :poshandler (lambda (info) (cons (- sb-left 4 (plist-get info :posframe-width)) 0)))))
              (should (> sbw 0))
              (should (alist-get 'tool-bar-external geometry))
              (should (> (cdr (alist-get 'tool-bar-size geometry)) 0))
              (drgnx-test-chrome--settle)
              (let* ((r (drgnx-test-chrome--rect f root))
                     (m (ceiling (* s drgnx-test-chrome--margin)))
                     ;; the bar beside the popup's shadow, a device pixel in from its left edge
                     (bar (list (1+ (round (* s sb-left))) 0 (round (* s (nth 2 edges)))
                                (min (nth 1 none) (+ (nth 3 r) m))))
                     (rects (drgnx-test-chrome--shown root (list f) none))
                     (snap (drgnx-uitest-snapshot root))
                     (off (drgnx-test-chrome--off-snapshot root)))
                (should (= (nth 1 r) 0))                                   ; flush under the tool bar
                (should (<= (- (nth 0 bar) (nth 2 r)) (ceiling (* s 6))))  ; and close to the bar
                ;; the shadow reaches the bar…
                (should (drgnx-uitest-darker-p snap none (+ (nth 2 r) (round s)) (/ (+ (nth 1 r) (nth 3 r)) 2)))
                ;; …and ends under it: the bar's pixels are the stock ones
                (unless (drgnx-uitest-region-equal-p snap off bar :ignore-alpha t)
                  (ert-fail (list "the shadow shows on the scroll bar" :bar bar
                                  :first-pixel (drgnx-test-chrome--first-diff snap off bar))))
                ;; the tool bar is GTK's, outside the root's picture: the picture is the native area, as stock's
                (should (equal (seq-take snap 2) (seq-take off 2)))
                (should (= (nth 1 snap) (round (* s (frame-pixel-height root)))))
                (should (equal (frame-geometry root) geometry))
                (posframe-hide name)
                (drgnx-test-chrome--hidden root rects none))))
        (posframe-delete-all)
        (drgnx-uitest-bare-frame)
        (drgnx-test-chrome--wait-stable (lambda () (list (frame-pixel-width root) (frame-pixel-height root))))))))

;;;; xwidgets

(ert-deftest drgnx-ui-chrome/xwidget-under-popup ()
  "An xwidget in a scrolled window under a popup (§10.3).  Nidhogg builds no xwidgets yet."
  (ert-skip "xwidgets are not built in Nidhogg yet (GLITNIR-XWIDGET-1)"))

;;; childframe-extra-test.el ends here
