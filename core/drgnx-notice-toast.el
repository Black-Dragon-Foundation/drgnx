;;; drgnx-notice-toast.el --- Notices as floating toasts under Glitnir -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The float route of the notice model's echo rule (drgnx-notice-echo.el): where Glitnir draws, a notice the rule
;; wants shown appears as a toast, a pooled child frame at the bottom right of the editor frame, above the status
;; bar: an icon in the severity's colour, a bold title, the detail in the subtle text and up to three buttons
;; (the notice's own command first, with its key).  At most three are stacked upward; the rest wait and are counted
;; (`drgnx-notice-toast-more-text').  A toast never takes focus, never prompts, and goes by itself.  Without
;; Glitnir (a terminal, macOS before its port, after a renderer panic), with `drgnx-notice-style' `echo', or in
;; batch, nothing here runs and the echo area says it as before.  Core: it requires nothing in wb/ or modules/.
;; See docs/guide/notices.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-setting)
(require 'drgnx-notice)
(require 'drgnx-timer)
(require 'drgnx-registry)
(require 'drgnx-surfaces)
(require 'drgnx-icons)
(require 'drgnx-ui-kit)

(declare-function glitnir-active-p "glitnir")
(declare-function drgnx-look-chrome-current "drgnx-look" (&optional frame))
(defvar drgnx-look-motion)

(drgnx-defsetting drgnx-notice-style 'auto
  "Where a notice that interrupts shows: `float' (a toast over the editor on any graphical frame, without Glitnir's
corners and shadow where it does not draw), `echo' (a line in the echo area) or `auto' (`float' while Glitnir draws,
else `echo').  A terminal frame always echoes.  A change applies to the next notice."
  :type '(choice (const auto) (const echo) (const float)) :group 'drgnx
  :scope 'global :workspace 'never :agents 'never
  :schema '(enum auto echo float))

(defconst drgnx-notice-toast-max 3 "How many toasts show at once.")
(defconst drgnx-notice-toast-width 360 "A toast's width, in logical pixels.")
(defconst drgnx-notice-toast-seconds 8 "How long the oldest toast stays before it goes.")
(defconst drgnx-notice-toast--waiting-max 50 "How many toasts may wait; past it the oldest go.")

(defvar drgnx-notice-toast--visible nil "The notices shown as toasts, oldest (bottom) first.")
(defvar drgnx-notice-toast--waiting nil "The notices that wait for a place, oldest first.")
(defvar drgnx-notice-toast--pool nil "The toasts' child frames, bottom first, made once and reused.")

;;;; The model (pure)

(defun drgnx-notice-toast-active-p ()
  "Non-nil when notices float: the style says so and a graphical frame can show a child frame."
  (and (not noninteractive) (display-graphic-p)
       (pcase drgnx-notice-style
         ('echo nil)
         ('float t)
         (_ (and (fboundp 'glitnir-active-p) (glitnir-active-p) t)))))

(defun drgnx-notice-toast--key (notice)
  "NOTICE's identity."
  (cons (plist-get notice :source) (plist-get notice :id)))

(defun drgnx-notice-toast-admit (notice)
  "Take NOTICE as a toast: a repeat of one shown or waiting replaces it; else it shows if there is room, else it
waits (the status bar counts it).  Draws."
  (let ((key (drgnx-notice-toast--key notice)) (done nil))
    (setq drgnx-notice-toast--visible
          (mapcar (lambda (n) (if (equal (drgnx-notice-toast--key n) key) (progn (setq done t) notice) n))
                  drgnx-notice-toast--visible))
    (unless done
      (setq drgnx-notice-toast--waiting
            (mapcar (lambda (n) (if (equal (drgnx-notice-toast--key n) key) (progn (setq done t) notice) n))
                    drgnx-notice-toast--waiting)))
    (unless done
      (if (< (length drgnx-notice-toast--visible) drgnx-notice-toast-max)
          (setq drgnx-notice-toast--visible (append drgnx-notice-toast--visible (list notice)))
        (setq drgnx-notice-toast--waiting (append drgnx-notice-toast--waiting (list notice)))
        (let ((over (- (length drgnx-notice-toast--waiting) drgnx-notice-toast--waiting-max)))
          (when (> over 0) (setq drgnx-notice-toast--waiting (nthcdr over drgnx-notice-toast--waiting))))))
    (drgnx-notice-toast--sync)))

(defun drgnx-notice-toast-expire (notice)
  "NOTICE's toast goes; the first one waiting takes its place.  Draws."
  (setq drgnx-notice-toast--visible (delq notice (copy-sequence drgnx-notice-toast--visible)))
  (when (and drgnx-notice-toast--waiting (< (length drgnx-notice-toast--visible) drgnx-notice-toast-max))
    (setq drgnx-notice-toast--visible (append drgnx-notice-toast--visible (list (pop drgnx-notice-toast--waiting)))))
  (drgnx-notice-toast--sync))

(defun drgnx-notice-toast-more-count ()
  "How many toasts wait for a place."
  (length drgnx-notice-toast--waiting))

(defun drgnx-notice-toast-more-text ()
  "\"+N\" for the toasts that wait, else nil (for the status bar)."
  (let ((n (drgnx-notice-toast-more-count))) (and (> n 0) (format "+%d" n))))

(defun drgnx-notice-toast-offer (kind notice)
  "The echo rule's line of KIND (`problem' or `waiting') for NOTICE: take it as a toast when notices float.
Return non-nil when taken."
  (when (and (memq kind '(problem waiting)) (drgnx-notice-toast-active-p))
    (drgnx-notice-toast-admit notice)
    t))

(defun drgnx-notice-toast--command-label (command)
  "The registry title of COMMAND (an id, a command or (FN . ARGS)), else its name."
  (let* ((id (if (consp command) (car command) command)) (cmd (and (fboundp 'drgnx-commands-get)
                                                                   (or (drgnx-commands-get id) (drgnx-commands-for-function id)))))
    (or (and cmd (drgnx-cmd-title cmd)) (symbol-name id))))

(defun drgnx-notice-toast-buttons (notice)
  "The buttons of NOTICE's toast, primary first, at most three: (:label L :key K :action A) with K the key label or
nil and A a command, (FN . ARGS) or (dismiss . KEY).  The notice's own command, Show Notices, Dismiss (not for a
thing waiting on you)."
  (let* ((command (plist-get notice :command)) (id (if (consp command) (car command) command)) (buttons nil))
    (when command
      (push (list :label (drgnx-notice-toast--command-label command)
                  :key (drgnx-surfaces-key-label id :short t) :action command)
            buttons))
    (unless (eq id 'notices)
      (push (list :label "Show Notices" :key (drgnx-surfaces-key-label 'notices :short t) :action 'notices) buttons))
    (unless (eq (plist-get notice :life) 'attention)
      (push (list :label "Dismiss" :key nil :action (cons 'dismiss (drgnx-notice-toast--key notice))) buttons))
    (seq-take (nreverse buttons) 3)))

;;;; Drawing

(defun drgnx-notice-toast--px (parent logical)
  "LOGICAL pixels in PARENT's own pixels (a frame of Nidhogg's Wayland shell counts device pixels)."
  (if (featurep 'nidhogg-wayland) (round (* logical (frame-scale-factor parent))) logical))

(defun drgnx-notice-toast--parent ()
  "The graphical root frame the toasts float over, or nil."
  (let ((f (selected-frame)))
    (while (frame-parent f) (setq f (frame-parent f)))
    (and (display-graphic-p f) f)))

(defun drgnx-notice-toast--transition ()
  "The toast's `transition': in 160 ms `ease-out', out 100 ms `ease-in'; none under reduced motion."
  (unless (eq (bound-and-true-p drgnx-look-motion) 'reduced)
    '(:show fade :hide fade :duration 0.16 :curve ease-out :hide-duration 0.1 :hide-curve ease-in)))

(defun drgnx-notice-toast--run (action)
  "Run a button's ACTION."
  (cond ((eq (car-safe action) 'dismiss) (drgnx-notice-dismiss (cdr action)))
        ((consp action) (if (fboundp (car action)) (apply (car action) (cdr action))
                          (message "%s is not available (its module is off)" (car action))))
        ((commandp action) (call-interactively action))
        (t (drgnx-ui--run action))))

(defun drgnx-notice-toast--render (notice)
  "The text of NOTICE's toast."
  (let* ((sev (plist-get notice :severity))
         (face (pcase (plist-get notice :life) ('attention 'drgnx-status-needs-you) (_ (intern (format "drgnx-status-%s" sev)))))
         (icon (pcase (plist-get notice :life)
                 ('attention 'bell)
                 (_ (pcase sev ('fail 'circle-x) ('warn 'triangle-alert) (_ 'info)))))
         (detail (or (plist-get notice :detail) (plist-get notice :fix))))
    (concat (propertize (drgnx-look-icon icon face) 'face face) " "
            (propertize (plist-get notice :text) 'face 'bold) "\n"
            (if detail (concat (propertize detail 'face 'drgnx-text-subtle) "\n") "")
            (mapconcat (lambda (b)
                         (let ((action (plist-get b :action)))
                           (drgnx-ui-button (if (plist-get b :key) (format "%s (%s)" (plist-get b :label) (plist-get b :key))
                                              (plist-get b :label))
                                            (lambda () (drgnx-notice-toast--run action)))))
                       (drgnx-notice-toast-buttons notice) "  "))))

(defun drgnx-notice-toast--params (parent)
  "The frame parameters of a toast under PARENT: no focus, ever; popup chrome with the toast's motion."
  (let* ((chrome (and (featurep 'glitnir) (fboundp 'drgnx-look-chrome-current) (drgnx-look-chrome-current)))
         (ring (or (alist-get 'child-frame-border-width chrome) 0))
         (transition (drgnx-notice-toast--transition)))
    `((parent-frame . ,parent) (minibuffer . nil) (name . "drgnx-toast") (drgnx-notice-toast . t)
      (undecorated . t) (no-accept-focus . t) (no-focus-on-map . t) (no-other-frame . t) (skip-taskbar . t)
      (unsplittable . t) (no-special-glyphs . t) (desktop-dont-save . t)
      (internal-border-width . ,(drgnx-notice-toast--px parent 10)) (border-width . 0)
      (child-frame-border-width . ,(drgnx-notice-toast--px parent ring))
      (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0) (left-fringe . 0) (right-fringe . 0)
      (vertical-scroll-bars) (horizontal-scroll-bars) (cursor-type . nil) (visibility . nil)
      ,@(seq-remove (lambda (p) (memq (car p) '(child-frame-border-width transition))) chrome)
      ,@(and transition `((transition . ,transition))))))

(defun drgnx-notice-toast--slot (i parent)
  "The pooled frame number I under PARENT, made if need be; its buffer is the frame's."
  (let ((entry (nth i drgnx-notice-toast--pool)))
    (unless (and entry (frame-live-p (car entry)))
      (let* ((buf (get-buffer-create (format " *drgnx-toast-%d*" i)))
             (frame (let ((after-make-frame-functions nil) (before-make-frame-hook nil))
                      (make-frame (drgnx-notice-toast--params parent)))))
        (with-current-buffer buf
          (setq-local cursor-type nil truncate-lines nil word-wrap t mode-line-format nil header-line-format nil
                      tab-line-format nil cursor-in-non-selected-windows nil)
          (face-remap-add-relative 'default 'drgnx-surface-overlay))
        (set-window-buffer (frame-root-window frame) buf)
        (set-window-dedicated-p (frame-root-window frame) t)
        (setq entry (cons frame buf))
        (if (< i (length drgnx-notice-toast--pool))
            (setf (nth i drgnx-notice-toast--pool) entry)
          (setq drgnx-notice-toast--pool (append drgnx-notice-toast--pool (list entry))))))
    (unless (eq (frame-parent (car entry)) parent) (set-frame-parameter (car entry) 'parent-frame parent))
    entry))

(defun drgnx-notice-toast--anchor (parent)
  "(RIGHT . BOTTOM) of the toasts' corner in PARENT's pixels: inside the outer gap, above the status bar."
  (let* ((gap (max (or (frame-parameter parent 'internal-border-width) 0) (drgnx-notice-toast--px parent 8)))
         (bottom (apply #'max 0 (mapcar (lambda (w) (- (nth 3 (window-pixel-edges w)) (window-mode-line-height w)))
                                        (seq-remove #'window-minibuffer-p (window-list parent 'no-minibuf))))))
    (cons (- (frame-pixel-width parent) gap) (- bottom gap))))

(defun drgnx-notice-toast--hide-all ()
  "Every pooled toast out of sight."
  (dolist (e drgnx-notice-toast--pool)
    (when (and (frame-live-p (car e)) (frame-visible-p (car e))) (make-frame-invisible (car e)))))

(defun drgnx-notice-toast--expire-oldest ()
  "The timer `notice-toast': the oldest toast goes."
  (when drgnx-notice-toast--visible (drgnx-notice-toast-expire (car drgnx-notice-toast--visible))))

(defvar drgnx-notice-toast--counted 0 "The waiting count the status bars were last told of.")

(defun drgnx-notice-toast--sync ()
  "Draw the model: one pooled frame per visible notice, stacked upward from the corner; the rest out of sight.
When the count of those waiting changed, the status bars are drawn again (their `toasts' segment)."
  (unless (= drgnx-notice-toast--counted (length drgnx-notice-toast--waiting))
    (setq drgnx-notice-toast--counted (length drgnx-notice-toast--waiting))
    (force-mode-line-update t))
  (let ((parent (drgnx-notice-toast--parent)))
    (cond
     ((or (null drgnx-notice-toast--visible) (null parent))
      (drgnx-timer-cancel 'notice-toast)
      (drgnx-notice-toast--hide-all))
     (t
      (let* ((anchor (drgnx-notice-toast--anchor parent)) (right (car anchor)) (bottom (cdr anchor))
             (width (drgnx-notice-toast--px parent drgnx-notice-toast-width))
             (gap (drgnx-notice-toast--px parent 8)) (i 0))
        (dolist (n drgnx-notice-toast--visible)
          (let* ((entry (drgnx-notice-toast--slot i parent)) (frame (car entry)) (win (frame-root-window frame)))
            (with-current-buffer (cdr entry)
              (let ((inhibit-read-only t)) (erase-buffer) (insert (drgnx-notice-toast--render n)) (goto-char (point-min))))
            (set-frame-width frame width nil t)
            (let* ((h (+ (cdr (window-text-pixel-size win nil nil width 2000))
                         (* 2 (drgnx-notice-toast--px parent 10)))))
              (set-frame-size frame width h t)
              (setq bottom (- bottom h))
              (set-frame-position frame (- right (frame-pixel-width frame)) bottom)
              (setq bottom (- bottom gap)))
            (unless (frame-visible-p frame) (make-frame-visible frame))
            (setq i (1+ i))))
        (dolist (e (nthcdr i drgnx-notice-toast--pool))
          (when (and (frame-live-p (car e)) (frame-visible-p (car e))) (make-frame-invisible (car e)))))
      (drgnx-timer-start 'notice-toast drgnx-notice-toast-seconds #'drgnx-notice-toast--expire-oldest :owner :core)))))

(defun drgnx-notice-toast-delete-all ()
  "Forget every toast and delete the pooled frames and their buffers (the echo mode going off)."
  (drgnx-timer-cancel 'notice-toast)
  (setq drgnx-notice-toast--visible nil drgnx-notice-toast--waiting nil)
  (dolist (e drgnx-notice-toast--pool)
    (when (frame-live-p (car e)) (delete-frame (car e) t))
    (when (buffer-live-p (cdr e)) (kill-buffer (cdr e))))
  (setq drgnx-notice-toast--pool nil))

(provide 'drgnx-notice-toast)
;;; drgnx-notice-toast.el ends here
