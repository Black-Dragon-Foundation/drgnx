;;; drgnx-view-env.el --- What the editor tells the hub about a hub-fed view: fonts, scale, width, palette -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A hub-fed view (its rows are built by the hub: docs/develop/hub.md, "Rows") registers its buffer here
;; (`drgnx-view-env-register').  For each display class the buffer is shown in -- display kind, scale and the
;; buffer's effective fonts, measured in the buffer (after `text-scale' and face remapping) -- this module sends the
;; hub `view/env': the fonts per role, the cell, the narrowest live window's body width, the palette roles the SVG
;; writer colours from, the terminal's width table, the time zone and reduced motion.
;;
;; The rules (docs/develop/hub.md, "Rows"; the hub only echoes them):
;; - the epoch is this module's, one counter per (view, class): +1 for every env whose look changed (fonts, scale,
;;   palette, display, widths, zone, motion).  A width change alone keeps the epoch: the hub answers it with
;;   `replace's of the rows whose fit changed, never a reset;
;; - on `drgnx-hub-connected-functions' (a hub that started, or restarted) the current env of every live (view, class)
;;   is sent again, then the view's RESUBSCRIBE runs: a restarted hub holds no env and builds nothing until then.
;; - the hub asks for the advances it cannot read from a font file (`view-glyphs'); they are measured here once per
;;   (font, char) and cached.
;;
;; One message per kind of change: a theme change sends each (view, class) one env.  Width changes are debounced
;; through `drgnx-timer-debounce', on idleness.  The hooks are added with the first registered view and removed with the last, and
;; by `drgnx-view-env-teardown'.  See docs/develop/core.md, "Views".

;;; Code:
(require 'cl-lib)
(require 'drgnx-timer)
(require 'drgnx-color)
(require 'drgnx-pixels)

(defvar drgnx-hub--events)
(defvar drgnx-look-motion)
(defvar text-scale-mode-amount)
(defvar text-scale-mode-step)
(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-view-patch-env-sent "drgnx-view")
(declare-function drgnx-view-patch-reclass "drgnx-view")

(defconst drgnx-view-env-delay 0.1
  "Seconds of idleness after a width change before its env is sent.")

(defconst drgnx-view-env-roles '((ui . default) (code . fixed-pitch) (card . variable-pitch))
  "The font roles a view's rows use, and the face each is read from in the view's buffer.")

(defconst drgnx-view-env-palette-roles
  '((edge . drgnx-work-edge) (edit . drgnx-work-edge-strong) (accent . drgnx-work-chain) (warn . drgnx-work-overlap)
    (chip-fg . drgnx-work-chip) (chip-bg . (drgnx-work-chip . :background))
    (agent-1 . drgnx-work-agent-1) (agent-2 . drgnx-work-agent-2) (agent-3 . drgnx-work-agent-3)
    (agent-4 . drgnx-work-agent-4) (agent-5 . drgnx-work-agent-5) (agent-6 . drgnx-work-agent-6))
  "The palette roles the hub's SVG writer colours from, and the face each is read from (a face's foreground, or
\(FACE . :background)).  A face that is not defined reads as the default face's foreground.")

(defconst drgnx-view-env-glyph-cache-max 4096
  "The most (font, char) advances `drgnx-view-env--glyphs' holds; past that it is emptied (a font or theme change
asks again anyway).")

(defvar drgnx-view-env-send-function #'drgnx-view-env--send
  "Called with (METHOD PARAMS) to tell the hub; tests capture it.")

(defvar drgnx-view-env--views (make-hash-table :test #'equal)
  "View id → (BUFFER . RESUBSCRIBE): the registered hub-fed views.  Emptied by `drgnx-view-env-teardown'.")

(defvar drgnx-view-env--sent (make-hash-table :test #'equal)
  "(VIEW . CLASS) → (EPOCH LOOK WIDTH): what was last sent for each (view, class), LOOK the facts the epoch counts.
Pruned with its view.")

(defvar drgnx-view-env--headless (make-hash-table :test #'equal)
  "View id → t for the views that are in no window and still get the env of the selected window's class (git letters).")

(defvar drgnx-view-env--glyphs (make-hash-table :test #'equal)
  "(FONT-NAME . CHAR) → its advance in px, as the editor measured it for a `view-glyphs' ask (bounded:
`drgnx-view-env-glyph-cache-max').")

(defvar drgnx-view-env--hooked nil "Non-nil while the global hooks are on (the first view added them).")

;;;; The facts

(defun drgnx-view-env--scale-factor (buffer)
  "How much `text-scale' enlarges BUFFER's default face (1.0 when it is off)."
  (with-current-buffer buffer
    (if (and (bound-and-true-p text-scale-mode) (/= text-scale-mode-amount 0))
        (expt text-scale-mode-step text-scale-mode-amount)
      1.0)))

(defun drgnx-view-env--font (face frame factor)
  "FACE's font on FRAME as `[role file index px ascent descent avg space]' facts without the role, scaled by FACTOR;
nil on a terminal or when FACE has no font."
  (when-let* (((display-graphic-p frame))
              (name (ignore-errors (face-font face frame)))
              (info (ignore-errors (font-info name frame))))
    (let ((s (lambda (v) (and (numberp v) (* factor v)))))
      ;; `font-info': [OPENED-NAME FULL-NAME SIZE HEIGHT BASELINE-OFFSET RELATIVE-COMPOSE DEFAULT-ASCENT MAX-WIDTH
      ;; ASCENT DESCENT SPACE-WIDTH AVERAGE-WIDTH FILENAME CAPABILITY]
      (list (aref info 12) 0 (funcall s (aref info 2)) (funcall s (aref info 8)) (funcall s (aref info 9))
            (funcall s (aref info 11)) (funcall s (aref info 10)) (aref info 0)))))

(defun drgnx-view-env--window-facts (window)
  "The facts of the display class WINDOW shows its buffer in: a plist :display :scale :fonts :cell.  FONTS is a list
of (ROLE FILE INDEX PX ASCENT DESCENT AVG SPACE NAME)."
  (let* ((frame (window-frame window)) (buffer (window-buffer window))
         (gui (display-graphic-p frame)) (factor (drgnx-view-env--scale-factor buffer)))
    (list :display (if gui "gui" "tty")
          :scale (if gui (drgnx-pixels-scale frame) 1.0)
          :fonts (and gui (delq nil (mapcar (lambda (r)
                                              (when-let* ((f (drgnx-view-env--font (cdr r) frame factor)))
                                                (cons (symbol-name (car r)) f)))
                                            drgnx-view-env-roles)))
          :cell (list (frame-char-width frame) (frame-char-height frame)))))

(defun drgnx-view-env--class (facts)
  "The name of the display class FACTS describe: its display, scale and a hash of its fonts."
  (format "%s-%s-%x" (plist-get facts :display) (plist-get facts :scale)
          (sxhash-equal (mapcar (lambda (f) (list (nth 1 f) (nth 3 f))) (plist-get facts :fonts)))))

(defun drgnx-view-env--colour (spec)
  "The colour SPEC (a face, or (FACE . :background)) reads as now, as #rrggbb when Emacs knows it."
  (let* ((face (if (consp spec) (car spec) spec)) (attr (if (consp spec) :background :foreground))
         (c (and (facep face) (face-attribute face attr nil t))))
    (when (or (not (stringp c)) (string-prefix-p "unspecified" c))
      (setq c (face-attribute 'default :foreground nil t)))
    (let ((rgb (drgnx-color-rgb c)))
      (if rgb (drgnx-color-hex rgb) "currentColor"))))

(defun drgnx-view-env--palette ()
  (mapcar (lambda (r) (list (symbol-name (car r)) (drgnx-view-env--colour (cdr r)))) drgnx-view-env-palette-roles))

(defvar drgnx-view-env--tty-widths nil "The terminal width table as sent, computed once (`drgnx-view-env--tty-widths').")

(defun drgnx-view-env--tty-widths ()
  "`char-width-table's ranges of width 0 and 2 as ((FROM TO WIDTH) ...), at most 4096; computed once."
  (or drgnx-view-env--tty-widths
      (let ((out nil) (n 0))
        (map-char-table (lambda (k v)
                          (when (and (memq v '(0 2)) (< n 4096))
                            (setq n (1+ n))
                            (push (if (consp k) (list (car k) (cdr k) v) (list k k v)) out)))
                        char-width-table)
        (setq drgnx-view-env--tty-widths (or (nreverse out) :none)))))

(defun drgnx-view-env--windows (buffer)
  "The live windows on visible frames that show BUFFER."
  (cl-remove-if-not (lambda (w) (eq (frame-visible-p (window-frame w)) t)) (get-buffer-window-list buffer nil t)))

(defun drgnx-view-env--envs (view)
  "VIEW's env per display class it shows in now: a list of (CLASS . PARAMS), PARAMS without the epoch.  WIDTH_PX is
the narrowest window of the class (Call 2: one buffer holds one fit)."
  (let ((buffer (car (gethash view drgnx-view-env--views))) (classes nil))
    (when (buffer-live-p buffer)
      (dolist (w (or (drgnx-view-env--windows buffer)
                     (and (gethash view drgnx-view-env--headless) (list (selected-window)))))
        (let* ((facts (drgnx-view-env--window-facts w)) (class (drgnx-view-env--class facts))
               (width (window-body-width w t)) (have (assoc class classes)))
          (if have
              (setf (plist-get (cdr have) :width_px) (min width (plist-get (cdr have) :width_px)))
            (push (cons class (list :view view :class class :display (plist-get facts :display)
                                    :scale (plist-get facts :scale)
                                    :fonts (mapcar (lambda (f) (cl-subseq f 0 8)) (plist-get facts :fonts))
                                    :cell (plist-get facts :cell) :width_px width
                                    :palette (drgnx-view-env--palette)
                                    :tty_widths (let ((t-w (drgnx-view-env--tty-widths))) (if (eq t-w :none) nil t-w))
                                    :tz (format-time-string "%z")
                                    :reduced_motion (if (eq (bound-and-true-p drgnx-look-motion) 'reduced) t :false)))
                  classes)))))
    (nreverse classes)))

;;;; Sending

(defun drgnx-view-env--send (method params)
  "METHOD with PARAMS on this Emacs's subscribed connection, the one the view's patches come back on; nil while it is
down (the reconnect sends again)."
  (when (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
    ;; lists go out as arrays, and nil as null: an empty list must be an empty array
    (let ((p (copy-sequence params)))
      (dolist (k '(:fonts :palette :tty_widths :glyphs))
        (when (plist-member p k) (setq p (plist-put p k (vconcat (plist-get p k))))))
      (drgnx-hub--call-on drgnx-hub--events method p #'ignore))
    t))

(defun drgnx-view-env--look (params)
  "The facts of PARAMS the epoch counts: all but the width."
  (let ((p (copy-sequence params))) (cl-remf p :width_px) p))

(defun drgnx-view-env-update (view &optional force)
  "Send VIEW's env for each class it shows in whose facts changed since the last send (FORCE: every class, as last
numbered).  A changed look takes the next epoch; a width change alone keeps it.  The classes VIEW no longer shows are
forgotten."
  (let ((live nil) (envs (drgnx-view-env--envs view)))
    ;; a buffer shown in one class follows it (the inserter re-pairs it) before that class's env goes out
    (when (and (= 1 (length envs)) (fboundp 'drgnx-view-patch-reclass))
      (drgnx-view-patch-reclass (car (gethash view drgnx-view-env--views)) (car (car envs))))
    (dolist (c envs)
      (let* ((key (cons view (car c))) (params (cdr c)) (look (drgnx-view-env--look params))
             (old (gethash key drgnx-view-env--sent))
             (epoch (cond ((null old) 1) ((equal look (nth 1 old)) (nth 0 old)) (t (1+ (nth 0 old))))))
        (push key live)
        (when (or force (null old) (/= epoch (nth 0 old)) (not (equal (plist-get params :width_px) (nth 2 old))))
          (puthash key (list epoch look (plist-get params :width_px)) drgnx-view-env--sent)
          (funcall drgnx-view-env-send-function "view/env"
                   (append params (list :epoch epoch) (and (null old) (list :attach t))))   ; a new buffer: the hub starts the pair over
          ;; the inserter holds patches of an older epoch from now on
          (when (fboundp 'drgnx-view-patch-env-sent) (drgnx-view-patch-env-sent view (car c) epoch)))))
    (let ((gone nil))
      (maphash (lambda (k _) (when (and (equal (car k) view) (not (member k live))) (push k gone))) drgnx-view-env--sent)
      (dolist (k gone) (remhash k drgnx-view-env--sent)))))

(defun drgnx-view-env-epoch (view class)
  "The epoch last sent for (VIEW, CLASS), or nil."
  (car (gethash (cons view class) drgnx-view-env--sent)))

(defun drgnx-view-env-classes (view)
  "The display classes VIEW's env was last sent for."
  (let ((out nil))
    (maphash (lambda (k _) (when (equal (car k) view) (push (cdr k) out))) drgnx-view-env--sent)
    out))

(defun drgnx-view-env--update-all ()
  (maphash (lambda (view _) (drgnx-view-env-update view)) drgnx-view-env--views))

;;;; Hooks: what changes an env

(defun drgnx-view-env--theme-changed (&optional _theme)
  "A theme was enabled or disabled: one env per (view, class) whose look changed."
  (drgnx-view-env--update-all))

(defun drgnx-view-env--size-changed (&optional _frame)
  "A window's size or a frame's windows changed: the width, once Emacs is idle (never inside a follow)."
  (drgnx-timer-debounce 'drgnx-view-env drgnx-view-env-delay #'drgnx-view-env--update-all :idle t :owner :core))

(defun drgnx-view-env--text-scale ()
  "`text-scale' changed in a view's buffer (buffer-local `text-scale-mode-hook'): its class changed."
  (maphash (lambda (view v) (when (eq (car v) (current-buffer)) (drgnx-view-env-update view)))
           drgnx-view-env--views))

(defun drgnx-view-env--reconnected ()
  "The hub is up (again): every live (view, class)'s env first, then each view's RESUBSCRIBE."
  (maphash (lambda (view v)
             (if (not (buffer-live-p (car v)))
                 (drgnx-view-env-unregister view)
               (drgnx-view-env-update view t)
               (when (cdr v) (funcall (cdr v) view))))
           (copy-hash-table drgnx-view-env--views)))

(defun drgnx-view-env--measure (buffer face char)
  "CHAR's advance in px in FACE, measured in BUFFER."
  (with-current-buffer buffer
    (string-pixel-width (propertize (string char) 'face face))))

(defun drgnx-view-env-event (event data)
  "A `drgnx-hub-event-functions' handler: `view-glyphs' asks for advances, answered with `view/glyphs' from the
cache, each (font, char) measured once."
  (when (equal event "view-glyphs")
    (let* ((view (plist-get data :view)) (buffer (car (gethash view drgnx-view-env--views))) (out nil))
      (when (buffer-live-p buffer)
        (dolist (a (plist-get data :ask))
          (let* ((role (nth 0 a)) (char (string-to-char (nth 1 a)))
                 (face (or (alist-get (intern-soft role) drgnx-view-env-roles) 'default))
                 (font (or (ignore-errors (face-font face)) (symbol-name face)))
                 (key (cons font char))
                 (px (or (gethash key drgnx-view-env--glyphs)
                         (progn (when (>= (hash-table-count drgnx-view-env--glyphs) drgnx-view-env-glyph-cache-max)
                                  (clrhash drgnx-view-env--glyphs))
                                (puthash key (drgnx-view-env--measure buffer face char) drgnx-view-env--glyphs)))))
            (push (list role (nth 1 a) px) out)))
        (funcall drgnx-view-env-send-function "view/glyphs"
                 (list :view view :class (plist-get data :class) :glyphs (nreverse out)))))))

(defun drgnx-view-env--hook (on)
  "Add the global hooks (ON) or remove them."
  (let ((f (if on #'add-hook #'remove-hook)))
    (funcall f 'enable-theme-functions #'drgnx-view-env--theme-changed)
    (funcall f 'disable-theme-functions #'drgnx-view-env--theme-changed)
    (funcall f 'window-size-change-functions #'drgnx-view-env--size-changed)
    (funcall f 'window-buffer-change-functions #'drgnx-view-env--size-changed)
    (funcall f 'drgnx-hub-connected-functions #'drgnx-view-env--reconnected)
    (funcall f 'drgnx-hub-event-functions #'drgnx-view-env-event))
  (setq drgnx-view-env--hooked on))

;;;; Registering a view

(defun drgnx-view-env-register (view buffer &optional resubscribe headless)
  "VIEW (an id string) is hub-fed and drawn in BUFFER: send its env now and whenever it changes.  RESUBSCRIBE (VIEW)
runs after the env is sent again on a reconnect.  HEADLESS: BUFFER is shown in no window, and the hub gets the env
of the selected window's display class for it (rows that only Lisp reads).  The view is forgotten with its buffer."
  (puthash view (cons buffer resubscribe) drgnx-view-env--views)
  (if headless (puthash view t drgnx-view-env--headless) (remhash view drgnx-view-env--headless))
  (with-current-buffer buffer
    (add-hook 'text-scale-mode-hook #'drgnx-view-env--text-scale nil t)
    (add-hook 'kill-buffer-hook #'drgnx-view-env--buffer-killed nil t))
  (unless drgnx-view-env--hooked (drgnx-view-env--hook t))
  (drgnx-view-env-update view))

(defun drgnx-view-env--buffer-killed ()
  (maphash (lambda (view v) (when (eq (car v) (current-buffer)) (drgnx-view-env-unregister view)))
           (copy-hash-table drgnx-view-env--views)))

(defun drgnx-view-env-unregister (view)
  "Forget VIEW: its envs, its buffer's hooks; the global hooks go with the last view."
  (let ((v (gethash view drgnx-view-env--views)))
    (remhash view drgnx-view-env--views)
    (remhash view drgnx-view-env--headless)
    (when (and v (buffer-live-p (car v)))
      (with-current-buffer (car v)
        (remove-hook 'text-scale-mode-hook #'drgnx-view-env--text-scale t)
        (remove-hook 'kill-buffer-hook #'drgnx-view-env--buffer-killed t))))
  (let ((gone nil))
    (maphash (lambda (k _) (when (equal (car k) view) (push k gone))) drgnx-view-env--sent)
    (dolist (k gone) (remhash k drgnx-view-env--sent)))
  (when (and drgnx-view-env--hooked (zerop (hash-table-count drgnx-view-env--views)))
    (drgnx-view-env--hook nil)
    (drgnx-timer-cancel 'drgnx-view-env)))

(defun drgnx-view-env-teardown ()
  "Forget every view and remove every hook (the owning module's teardown)."
  (maphash (lambda (view _) (drgnx-view-env-unregister view)) (copy-hash-table drgnx-view-env--views))
  (when drgnx-view-env--hooked (drgnx-view-env--hook nil))
  (drgnx-timer-cancel 'drgnx-view-env)
  (clrhash drgnx-view-env--glyphs)
  (setq drgnx-view-env--tty-widths nil))

(provide 'drgnx-view-env)
;;; drgnx-view-env.el ends here
