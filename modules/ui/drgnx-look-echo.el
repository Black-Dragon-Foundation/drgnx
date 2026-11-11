;;; drgnx-look-echo.el --- ui/look: no echo row; prompts float in a box at the top, messages go to the status bar -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-look-echo-row' `float' (the default): a graphical frame has no echo row.  Its minibuffer is a child frame,
;; the box, top-centre in the palette's look and hidden while nothing asks.  A prompt shows in it: a minibuffer
;; (`completing-read', `yes-or-no-p', a password), a question read with `read-key', `read-char' and the like, and
;; C's own prompts (`interactive' "c" and "k"), which Nidhogg tells apart with `nidhogg-echo-prompt'.  A message
;; shown just before a caller waits for a key (`query-replace''s) shows there again.  Plain messages and the keys of
;; a prefix (C-x-) go to the status bar for a few seconds, a command's error in the error face.  The box hides once
;; the prompt is answered: when the echo area is cleared, the minibuffer exits or the command ends.
;; `classic' gives the row back.  A terminal frame keeps its row either way: only the graphical window systems'
;; entries of `window-system-default-frame-alist' ask for the box.  A change applies at once: each graphical frame
;; is swapped for a new one with the same windows (`window-state-get'), buffers, selected window, size and place.

;;; Code:
(require 'seq)
(require 'drgnx-setting)
(require 'drgnx-timer)
(require 'drgnx-hooks)
(require 'drgnx-palette-frame)

(declare-function drgnx-module-running-p "drgnx-modules" (module))
(declare-function face-remap-remove-relative "face-remap" (cookie))
(defvar nidhogg-echo-prompt)

(defconst drgnx-look-echo--systems '(x w32 ns pgtk haiku android)
  "The graphical window systems: their frames get the box; a terminal's keeps its row.")

(defconst drgnx-look-echo--waits '(read-event read-char read-char-exclusive read-key)
  "The Lisp reads a prompt or a message waits on (`drgnx-look-echo--wait').")

(defcustom drgnx-look-echo-status-seconds 5
  "How long a message shows in the status bar, in seconds (or until the next one)."
  :type 'number :group 'drgnx-look)

(defvar drgnx-look-echo--on nil "Non-nil while the box is in use (`drgnx-look-echo-on').")
(defvar drgnx-look-echo--saved nil "The `resize-mini-frames' `drgnx-look-echo-on' replaced.")
(defvar drgnx-look-echo-swaps 0 "How many frames `drgnx-look-echo-swap' replaced this session (a start swaps none).")
(defvar drgnx-look-echo--waiting nil "Non-nil while a Lisp caller waits for a key (`drgnx-look-echo--wait').")
(defvar drgnx-look-echo--prompting nil
  "Non-nil while the echo area shows a prompt of C's: until it is cleared, a Lisp wait returns or the command ends.")
(defvar drgnx-look-echo--routed nil "(COMMAND-TICK . TEXT): the last message sent to the status bar.")
(defvar drgnx-look-echo--tick 0 "Counts commands: a message routed in this command shows again if the command then waits.")
(defvar drgnx-look-echo--status nil "(TEXT . FACE): the message the status bar shows, or nil.")

(defun drgnx-look-echo--apply-setting ()
  "The `:apply' of `drgnx-look-echo-row': on or off at once, while ui/look runs, and every graphical frame swapped."
  (when (drgnx-module-running-p 'ui/look) (drgnx-look-echo-apply)))

(drgnx-defsetting drgnx-look-echo-row 'float
  "Where a graphical frame's echo area lives.  `float': no row at the bottom; a prompt floats in a box at the top
centre, in the palette's look, and hides when nothing asks; messages and the keys of a prefix show in the status bar.
`classic': the row at the bottom, as in stock Emacs.  A terminal frame keeps its row either way.  A change applies at
once: each graphical frame is swapped for a new one with the same windows, buffers, size and place."
  :type '(choice (const float) (const classic)) :group 'drgnx-look
  :scope 'global :agents 'never :apply #'drgnx-look-echo--apply-setting
  :schema '(enum float classic))

;;;; The box

(defun drgnx-look-echo--root (&optional frame)
  "FRAME (default the selected one), or its parent when it is a box."
  (let ((f (or frame (selected-frame))))
    (if (and (eq (frame-parameter f 'minibuffer) 'only) (frame-parent f)) (frame-parent f) f)))

(defun drgnx-look-echo-box (&optional frame)
  "FRAME's box: its minibuffer's frame when that is a child of FRAME; nil for a frame with a row of its own."
  (let* ((f (drgnx-look-echo--root frame)) (m (window-frame (minibuffer-window f))))
    (and (not (eq m f)) (eq (frame-parent m) f) m)))

(defun drgnx-look-echo--params ()
  "The box's frame parameters at birth (`minibuffer-frame-alist'): the palette's chrome, hidden."
  `((name . "drgnx-echo") (drgnx-echo . t) (undecorated . t) (no-other-frame . t) (skip-taskbar . t)
    (no-special-glyphs . t) (desktop-dont-save . t) (border-width . 0) (internal-border-width . 8)
    (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0) (left-fringe . 0) (right-fringe . 0)
    (vertical-scroll-bars) (horizontal-scroll-bars) (visibility . nil) (minibuffer-exit . t)
    ,@(drgnx-palette-frame--look)))

(defun drgnx-look-echo--place (box)
  "BOX as wide as the palette, as high as what it shows, top-centre in its parent."
  (when-let* ((parent (frame-parent box)))
    (let* ((px (lambda (n) (drgnx-palette-frame--px parent n)))
           (width (min (funcall px drgnx-palette-frame-width)
                       (max (funcall px 100) (- (frame-pixel-width parent) (funcall px 32)))))
           (border (funcall px 8))
           (ring (funcall px (or (alist-get 'child-frame-border-width (drgnx-palette-frame--look)) 0)))
           (pad (* 2 border))
           (line (with-selected-frame box (default-line-height)))
           (h (if (active-minibuffer-window)
                  (max line (cdr (window-text-pixel-size (frame-root-window box) nil nil (- width pad) (* 20 line))))
                (* line (max 1 (min 20 (length (split-string (or (current-message) "") "\n"))))))))
      (unless (eql (frame-parameter box 'internal-border-width) border)
        (set-frame-parameter box 'internal-border-width border))
      (unless (eql (frame-parameter box 'child-frame-border-width) ring)
        (set-frame-parameter box 'child-frame-border-width ring))
      (unless (and (= (frame-text-width box) (- width pad)) (= (frame-text-height box) h))
        (set-frame-size box (- width pad) h t))
      (set-frame-position box (max 0 (/ (- (frame-pixel-width parent) (frame-pixel-width box)) 2))
                          (round (* drgnx-palette-frame-top (frame-pixel-height parent)))))))

(defconst drgnx-look-echo--buffers '(" *Echo Area 0*" " *Echo Area 1*")
  "The buffers the echo area shows messages in: dressed as the palette's input row while on.")

(defvar-local drgnx-look-echo--cookie nil "The remap that gives this buffer the UI font while the box is on.")

(defun drgnx-look-echo--palette-dressed-p ()
  "Non-nil when the floating palette dresses the current buffer (its minibuffer) as its input row."
  (when-let* ((d (bound-and-true-p drgnx-palette-frame--dressing)))
    (eq (current-buffer) (overlay-buffer (car d)))))

(defun drgnx-look-echo--dress ()
  "The current buffer in the palette's input row: the UI font, rows of its height, its inset before the text."
  (unless drgnx-look-echo--cookie
    (setq drgnx-look-echo--cookie (face-remap-add-relative 'default 'drgnx-ui-text))
    (unless (drgnx-look-echo--palette-dressed-p)                ; the palette's input row has its own inset
      (setq-local line-prefix (drgnx-palette-frame--lead)))
    (drgnx-palette-frame--rows drgnx-palette-frame-row-px)))

(defun drgnx-look-echo--undress ()
  "Undo `drgnx-look-echo--dress' in the current buffer."
  (when drgnx-look-echo--cookie
    (face-remap-remove-relative drgnx-look-echo--cookie)
    (setq drgnx-look-echo--cookie nil)
    (kill-local-variable 'line-prefix)
    (kill-local-variable 'line-spacing)))

(defun drgnx-look-echo--under-palette-p ()
  "Non-nil when the floating palette shows the active minibuffer: the palette is the prompt, the box stays hidden."
  (when-let* ((mw (active-minibuffer-window)))
    (and (frame-live-p drgnx-palette-frame--frame) (frame-visible-p drgnx-palette-frame--frame)
         (eq (window-buffer (frame-root-window drgnx-palette-frame--frame)) (window-buffer mw)))))

(defun drgnx-look-echo--show (box)
  "Dress the echo area, place BOX and show it, unless the floating palette is the prompt."
  (dolist (name drgnx-look-echo--buffers)
    (with-current-buffer (get-buffer-create name) (drgnx-look-echo--dress)))
  (drgnx-look-echo--place box)
  (if (drgnx-look-echo--under-palette-p)
      (when (frame-visible-p box) (make-frame-invisible box))
    (unless (frame-visible-p box) (make-frame-visible box))))

(defun drgnx-look-echo--hide (&optional frame)
  "Hide FRAME's box when nothing asks: no minibuffer is active, or the floating palette shows it, and no caller waits
for a key."
  (when-let* ((box (drgnx-look-echo-box frame)))
    (unless (or drgnx-look-echo--waiting drgnx-look-echo--prompting
                (and (active-minibuffer-window) (not (drgnx-look-echo--under-palette-p))))
      (when (frame-visible-p box) (make-frame-invisible box)))))

(defun drgnx-look-echo--fit (box)
  "`resize-mini-frames' while on: the box fits what it shows and stays top-centre."
  (when (frame-parameter box 'drgnx-echo) (drgnx-look-echo--place box)))

;;;; Prompts to the box, messages to the status bar

(defun drgnx-look-echo-status ()
  "(TEXT . FACE): the message the status bar shows, or nil."
  drgnx-look-echo--status)

(defun drgnx-look-echo-status-text ()
  "The message the status bar shows, or nil."
  (car drgnx-look-echo--status))

(defun drgnx-look-echo--status-show (text &optional face)
  "Show TEXT in the status bar for `drgnx-look-echo-status-seconds', in FACE."
  (setq drgnx-look-echo--status (and text (not (string-empty-p text)) (cons text face)))
  (drgnx-timer-start 'look-echo-status drgnx-look-echo-status-seconds #'drgnx-look-echo--status-clear
                     :owner 'ui/look)
  (force-mode-line-update t))

(defun drgnx-look-echo--status-clear ()
  "The status bar's message ends."
  (setq drgnx-look-echo--status nil)
  (force-mode-line-update t))

(defun drgnx-look-echo--route (text)
  "First of `set-message-functions' while on, for a frame with the box: a prompt (C's, while a Lisp caller waits for
a key, or with a minibuffer active) shows in the box (nil: the echo area, which is the box's); anything else goes to
the status bar (t: handled).  Emacs makes the box visible before it asks (`message3_nolog' shows a hidden minibuffer
frame first), so a message taken here hides it again, before anything is drawn, unless a prompt still shows."
  (when-let* ((box (drgnx-look-echo-box)))
    (if (or (eq (bound-and-true-p nidhogg-echo-prompt) 'prompt) drgnx-look-echo--waiting
            (and (active-minibuffer-window) (not (drgnx-look-echo--under-palette-p))))
        (progn (when (eq (bound-and-true-p nidhogg-echo-prompt) 'prompt) (setq drgnx-look-echo--prompting t))
               (drgnx-look-echo--show box)
               nil)
      (setq drgnx-look-echo--routed (cons drgnx-look-echo--tick text))
      (drgnx-look-echo--status-show (substring-no-properties text))
      (drgnx-look-echo--hide)
      t)))

(defun drgnx-look-echo--cleared (&rest _)
  "After `clear-message-function': the prompt is gone; the box hides when nothing else asks."
  (setq drgnx-look-echo--prompting nil)
  (drgnx-look-echo--hide))

(defun drgnx-look-echo--wait (orig &rest args)
  "Around `read-event', `read-char', `read-char-exclusive' and `read-key': while the caller waits, what the echo area
shows is a prompt; a message this command sent to the status bar just before (with no prompt given) shows in the box
again, as `query-replace''s does.  Once answered, the prompt goes and the box hides."
  (if (not (drgnx-look-echo-box))
      (apply orig args)
    (unwind-protect
        (let ((drgnx-look-echo--waiting t))
          (when (and (member (car args) '(nil "")) drgnx-look-echo--routed
                     (= (car drgnx-look-echo--routed) drgnx-look-echo--tick))
            (message "%s" (cdr drgnx-look-echo--routed)))
          (apply orig args))
      (setq drgnx-look-echo--routed nil drgnx-look-echo--prompting nil)
      (drgnx-look-echo--hide))))

(defun drgnx-look-echo--command-error (orig data context signal)
  "Around `command-error-function': on a frame with the box, the error shows in the status bar in the error face
(and in *Messages*), not in the hidden echo area."
  (if (not (drgnx-look-echo-box))
      (funcall orig data context signal)
    (let ((text (concat context (error-message-string data))))
      (let ((inhibit-message t)) (message "%s" text))
      (drgnx-look-echo--status-show text 'error)
      (ding))))

(defun drgnx-look-echo--minibuffer-setup ()
  "On `minibuffer-setup-hook': the box shows the minibuffer, in rows of the palette's height."
  (when-let* ((box (drgnx-look-echo-box)))
    (drgnx-look-echo--dress)
    (drgnx-look-echo--show box)))

(defun drgnx-look-echo--minibuffer-exit ()
  "On `minibuffer-exit-hook': the box hides after the minibuffer goes, unless another is still active."
  (drgnx-timer-start 'look-echo-hide 0 #'drgnx-look-echo--hide :owner 'ui/look))

(defun drgnx-look-echo--pre-command ()
  "On `pre-command-hook': a new command (a message it routes no longer belongs to the previous one)."
  (setq drgnx-look-echo--tick (1+ drgnx-look-echo--tick)))

(defun drgnx-look-echo--post-command ()
  "On `post-command-hook': the command is over, so is any prompt it showed."
  (when (and (drgnx-look-echo-box) (not (active-minibuffer-window)))
    (setq drgnx-look-echo--prompting nil)
    (drgnx-look-echo--hide)))

;;;; On, off and the swap

(defun drgnx-look-echo--without-box (alist params)
  "ALIST without the entries whose keys PARAMS (the box's parameters) has."
  (seq-remove (lambda (p) (assq (car p) params)) alist))

(defun drgnx-look-echo-on ()
  "Graphical frames made from now on get the box; prompts go to it, messages to the status bar.  Frames that exist
keep what they have (`drgnx-look-echo-apply' swaps them)."
  (unless drgnx-look-echo--on
    (setq drgnx-look-echo--on t
          drgnx-look-echo--saved resize-mini-frames)
    (dolist (sys drgnx-look-echo--systems)
      (setf (alist-get 'minibuffer (alist-get sys window-system-default-frame-alist)) 'child-frame))
    (let ((params (drgnx-look-echo--params)))    ; early-init.el may have put some of them there already
      (setq minibuffer-frame-alist (append params (drgnx-look-echo--without-box minibuffer-frame-alist params))
            resize-mini-frames #'drgnx-look-echo--fit))
    (add-hook 'set-message-functions #'drgnx-look-echo--route -90)
    (add-function :after (default-value 'clear-message-function) #'drgnx-look-echo--cleared)
    (add-function :around (default-value 'command-error-function) #'drgnx-look-echo--command-error)
    (dolist (fn drgnx-look-echo--waits) (advice-add fn :around #'drgnx-look-echo--wait))
    (add-hook 'minibuffer-setup-hook #'drgnx-look-echo--minibuffer-setup)
    (add-hook 'minibuffer-exit-hook #'drgnx-look-echo--minibuffer-exit)
    (add-hook 'pre-command-hook #'drgnx-look-echo--pre-command)
    (add-hook 'post-command-hook #'drgnx-look-echo--post-command)))

(defun drgnx-look-echo-off ()
  "Undo `drgnx-look-echo-on': frames made from now on have their row.  Frames that exist keep what they have."
  (when drgnx-look-echo--on
    (setq drgnx-look-echo--on nil)
    (dolist (sys drgnx-look-echo--systems)
      (when-let* ((cell (assq sys window-system-default-frame-alist)))
        (setcdr cell (assq-delete-all 'minibuffer (cdr cell)))
        (unless (cdr cell) (setq window-system-default-frame-alist (delq cell window-system-default-frame-alist)))))
    (setq resize-mini-frames drgnx-look-echo--saved
          minibuffer-frame-alist (drgnx-look-echo--without-box minibuffer-frame-alist (drgnx-look-echo--params))
          drgnx-look-echo--saved nil)
    (remove-hook 'set-message-functions #'drgnx-look-echo--route)
    (remove-function (default-value 'clear-message-function) #'drgnx-look-echo--cleared)
    (remove-function (default-value 'command-error-function) #'drgnx-look-echo--command-error)
    (dolist (fn drgnx-look-echo--waits) (advice-remove fn #'drgnx-look-echo--wait))
    (remove-hook 'minibuffer-setup-hook #'drgnx-look-echo--minibuffer-setup)
    (remove-hook 'minibuffer-exit-hook #'drgnx-look-echo--minibuffer-exit)
    (remove-hook 'pre-command-hook #'drgnx-look-echo--pre-command)
    (remove-hook 'post-command-hook #'drgnx-look-echo--post-command)
    (dolist (k '(look-echo-status look-echo-hide look-echo-apply)) (drgnx-timer-cancel k))
    (drgnx-look-echo--status-clear)
    (dolist (b (buffer-list))
      (when (buffer-local-value 'drgnx-look-echo--cookie b) (with-current-buffer b (drgnx-look-echo--undress))))))

(defconst drgnx-look-echo--not-copied
  '(minibuffer window-id outer-window-id parent-id frame-id parent-frame display-type terminal undeleted
               explicit-name)
  "The frame parameters a swap does not copy: the new frame's own, or what the swap decides.")

(defvar drgnx-look-echo--widths (make-hash-table :test 'eq :weakness 'key)
  "Frame → (TEXT-WIDTH . ((WINDOW . PIXEL-WIDTH) …)): the widths a swapped frame's windows had, waiting for the
frame to reach its width (a window system may size a new frame after it is made).")

(defun drgnx-look-echo--widths (old new)
  "Give each window of NEW the pixel width of its counterpart in OLD, now or once NEW has OLD's width.  The frames
differ in height by the echo row, and a new frame may get its size later, so `window-state-put' shares the width out
by proportion and a split can land a column off."
  (let ((pairs nil))
    (dolist (w (window-list new 'nomini (frame-first-window new)))
      (when-let* ((id (window-parameter w 'drgnx-replaced-id))
                  (was (seq-find (lambda (o) (eql (window-parameter o 'drgnx-replaced-id) id)) (window-list old 'nomini))))
        (push (cons w (window-pixel-width was)) pairs)))
    (puthash new (cons (frame-text-width old) (nreverse pairs)) drgnx-look-echo--widths)
    (if (= (frame-text-width new) (frame-text-width old))
        (drgnx-look-echo--widths-apply new)
      (add-hook 'window-size-change-functions #'drgnx-look-echo--widths-apply))))

(defun drgnx-look-echo--widths-apply (frame)
  "FRAME's windows get the widths they were swapped with, once FRAME has the width it was swapped from (on
`window-size-change-functions', which it leaves when no frame waits)."
  (when-let* ((want (gethash frame drgnx-look-echo--widths))
              ((or (not (frame-live-p frame)) (= (frame-text-width frame) (car want)))))
    (remhash frame drgnx-look-echo--widths)
    (when (zerop (hash-table-count drgnx-look-echo--widths))
      (remove-hook 'window-size-change-functions #'drgnx-look-echo--widths-apply))
    (when (frame-live-p frame)
      (let ((window-resize-pixelwise t))
        (pcase-dolist (`(,w . ,px) (cdr want))
          (when (window-live-p w)
            (let ((delta (- px (window-pixel-width w))))
              (when (and (/= delta 0) (window-resizable-p w delta t nil t))
                (window-resize w delta t nil t)))))))))

(defun drgnx-look-echo-swap (frame)
  "Replace FRAME with a new frame like it, whose minibuffer follows the setting now (the box when on): the same
windows and their parameters, buffers and points, the selected window, the frame's parameters, size and place.
Return the new frame.  Nothing is asked and no buffer is killed: FRAME's buffers stay, shown by the new frame."
  (let ((n 0))
    (dolist (w (window-list frame 'nomini)) (set-window-parameter w 'drgnx-replaced-id (setq n (1+ n)))))
  (let* ((window-persistent-parameters
          (append (mapcar (lambda (p) (cons p t))
                          (delete-dups (mapcan (lambda (w) (mapcar #'car (window-parameters w)))
                                               (window-list frame 'nomini))))
                  window-persistent-parameters))
         (state (window-state-get (frame-root-window frame)))
         (size (list (frame-text-width frame) (frame-text-height frame)))
         (params (seq-remove (lambda (p) (memq (car p) drgnx-look-echo--not-copied)) (frame-parameters frame)))
         (selected (eq frame (selected-frame)))
         (new (make-frame `((minibuffer . ,(if drgnx-look-echo--on 'child-frame t)) ,@params))))
    (set-frame-size new (car size) (cadr size) t)
    (window-state-put state (frame-root-window new) 'safe)
    (drgnx-look-echo--widths frame new)
    (when selected (select-frame-set-input-focus new))
    ;; The role first: the main window stays main, and deleting FRAME hands it to no other window.
    (when (eq (frame-parameter frame 'drgnx-frame-role) 'main) (set-frame-parameter frame 'drgnx-frame-role nil))
    (run-hook-with-args 'drgnx-frame-replaced-functions frame new)
    (dolist (w (window-list new 'nomini)) (set-window-parameter w 'drgnx-replaced-id nil))
    (delete-frame frame t)
    (setq drgnx-look-echo-swaps (1+ drgnx-look-echo-swaps))
    new))

(defun drgnx-look-echo--wrong-p (frame)
  "Non-nil when FRAME, a graphical root frame, is not as the setting wants: a row while on, a box while off."
  (and (display-graphic-p frame) (not (frame-parent frame))
       (not (eq (frame-parameter frame 'minibuffer) 'only))
       (if drgnx-look-echo--on (not (drgnx-look-echo-box frame)) (drgnx-look-echo-box frame))))

(defun drgnx-look-echo-apply ()
  "On or off as `drgnx-look-echo-row' says, at once, and the frames that exist with it (`drgnx-look-echo-apply-frames')."
  (if (eq drgnx-look-echo-row 'float) (drgnx-look-echo-on) (drgnx-look-echo-off))
  (drgnx-look-echo-apply-frames))

(defun drgnx-look-echo-apply-frames ()
  "Swap every graphical frame that is not as the box's state wants (a row while on, a box while off).  While a
minibuffer is in use the swap waits until it ends."
  (if (active-minibuffer-window)
      (add-hook 'minibuffer-exit-hook #'drgnx-look-echo--apply-later)
    (dolist (f (frame-list))
      (when (and (frame-live-p f) (drgnx-look-echo--wrong-p f))
        (if (memq f (bound-and-true-p drgnx-platform-moving))
            ;; the window manager may still be looking for it: try again once the move is over
            (drgnx-timer-start 'look-echo-apply 0.25 #'drgnx-look-echo-apply-frames :owner 'ui/look)
          (drgnx-look-echo-swap f))))))

(defun drgnx-look-echo--apply-later ()
  "On `minibuffer-exit-hook', once: the swap a minibuffer in use held back."
  (remove-hook 'minibuffer-exit-hook #'drgnx-look-echo--apply-later)
  (drgnx-timer-start 'look-echo-apply 0 #'drgnx-look-echo-apply-frames :owner 'ui/look))

(provide 'drgnx-look-echo)
;;; drgnx-look-echo.el ends here
