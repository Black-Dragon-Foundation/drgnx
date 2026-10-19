;;; drgnx-quickhelp.el --- Quick help: a card beside the symbol, a strip in terminals; never over the line you edit -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part A of M12f.  Hovering over a symbol (graphical frames), or Show Quick Help on it, shows a small card with
;; what eldoc knows about it — the docs and signature the language server or the mode gives — and three buttons:
;; Open Help, Go to Definition, Find References.  The docs come from `eldoc-documentation-functions' (eglot feeds
;; them), asked with point at the symbol; every answer is asynchronous and a request that is not answered within a
;; second shows what came (`drgnx-quickhelp-collect'), so nothing ever waits.
;;
;; The card never covers the line being edited: in a graphical frame it is a child frame below the symbol's line
;; (above it when there is no room below), inside the window (`drgnx-quickhelp-placement'); in a terminal frame
;; (30.2 has no child frames there) it is a strip of `drgnx-quickhelp-strip-lines' under the editor window, which
;; gets its rows back when the strip goes.  It goes away as soon as you type, run another command, change window
;; or buffer, press C-g, Esc or q, or click its ✕.  See docs/guide/face.md ("Quick help").

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'button)
(require 'eldoc)
(require 'thingatpt)
(require 'color)
(require 'drgnx-registry)
(require 'drgnx-modal)
(require 'drgnx-timer)
(require 'drgnx-state)
(declare-function drgnx-face-glyph "drgnx-face")
(declare-function eldoc--format-doc-buffer "eldoc")

(defgroup drgnx-quickhelp nil
  "Quick help: a card with a symbol's docs, beside it (a strip in terminals)."
  :group 'drgnx-face :prefix "drgnx-quickhelp-")

(defvar drgnx-quickhelp--active nil "Non-nil once set up: the hover setting then applies when it changes.")

(defun drgnx-quickhelp--set (symbol value)
  "Set SYMBOL to VALUE; the hover timer follows at once."
  (set-default symbol value)
  (when (fboundp 'drgnx-quickhelp--apply-hover) (drgnx-quickhelp--apply-hover)))

(defcustom drgnx-quickhelp-hover t
  "Non-nil: resting the mouse on a symbol shows its quick help (graphical frames; a terminal has the key only)."
  :type 'boolean :set #'drgnx-quickhelp--set :group 'drgnx-quickhelp)

(defcustom drgnx-quickhelp-delay 0.6
  "Seconds the mouse rests on a symbol before its quick help shows."
  :type 'number :group 'drgnx-quickhelp)

(defcustom drgnx-quickhelp-max-lines 12
  "Most lines of docs the card shows (Open Help shows them all)."
  :type 'natnum :group 'drgnx-quickhelp)

(defcustom drgnx-quickhelp-strip-lines 4
  "Height in lines of the strip that shows quick help in a terminal frame."
  :type 'natnum :group 'drgnx-quickhelp)

(defface drgnx-quickhelp '((t :inherit tooltip))
  "The quick help card.  Where the theme gives it the editor's own background (kusanagi's tooltip does), the card
takes a tint of the text colour instead (`drgnx-quickhelp-colors'), so it always stands out."
  :group 'drgnx-quickhelp)
(defface drgnx-quickhelp-title '((t :inherit bold)) "The symbol's name on the quick help card." :group 'drgnx-quickhelp)

;;;; Colours (pure) and width (pure)

(defconst drgnx-quickhelp--tint 0.16
  "How far the card's background moves from the editor's towards the text colour, where the face gives none apart.")
(defconst drgnx-quickhelp--distinct 1.15
  "The contrast ratio against the editor's background from which the face's own background is kept.")

(defun drgnx-quickhelp--rgb (color)
  "COLOR (#RRGGBB, or a name) as (R G B) in 0..1, or nil when it is not a colour (`unspecified', nil).
A #RRGGBB is read as written: `color-name-to-rgb' would snap it to the palette of a terminal frame."
  (and (stringp color)
       (if-let* ((v (color-values-from-color-spec color)))
           (mapcar (lambda (c) (/ c 65535.0)) v)
         (color-name-to-rgb color))))

(defun drgnx-quickhelp--mix (from to ratio)
  "The colour RATIO of the way from FROM to TO (both colour strings), as #RRGGBB; nil when either is no colour."
  (let ((a (drgnx-quickhelp--rgb from)) (b (drgnx-quickhelp--rgb to)))
    (when (and a b)
      (apply #'color-rgb-to-hex (append (cl-mapcar (lambda (p q) (+ p (* ratio (- q p)))) a b) '(2))))))

(defun drgnx-quickhelp--contrast (a b)
  "The WCAG contrast ratio of colours A and B (1 up to 21), or nil when either is no colour."
  (let ((l (mapcar (lambda (c)
                     (when-let* ((rgb (drgnx-quickhelp--rgb c)))
                       (pcase-let ((`(,r ,g ,b) (mapcar (lambda (v) (if (<= v 0.03928) (/ v 12.92) (expt (/ (+ v 0.055) 1.055) 2.4)))
                                                        rgb)))
                         (+ (* 0.2126 r) (* 0.7152 g) (* 0.0722 b)))))
                   (list a b))))
    (when (and (car l) (cadr l))
      (/ (+ 0.05 (max (car l) (cadr l))) (+ 0.05 (min (car l) (cadr l)))))))

(defun drgnx-quickhelp-colors (&optional frame)
  "The card's colours on FRAME's theme: (BACKGROUND . BORDER), or nil when the theme has no colours to go by.
BACKGROUND is the `drgnx-quickhelp' face's own when it stands out from the editor's (a theme or you set it), else the
editor's moved `drgnx-quickhelp--tint' of the way to the text colour: the same rule gives a light tint on a dark
theme and a dark one on a light theme.  BORDER is the card's text colour halfway to its background: a 1px line."
  (let* ((face-bg (face-attribute 'drgnx-quickhelp :background frame t))
         (bg0 (face-attribute 'default :background frame))
         (fg (let ((c (face-attribute 'drgnx-quickhelp :foreground frame t)))
               (if (drgnx-quickhelp--rgb c) c (face-attribute 'default :foreground frame))))
         (bg (if (let ((r (drgnx-quickhelp--contrast face-bg bg0))) (and r (>= r drgnx-quickhelp--distinct)))
                 face-bg
               (drgnx-quickhelp--mix bg0 (face-attribute 'default :foreground frame) drgnx-quickhelp--tint))))
    (when (and bg (drgnx-quickhelp--rgb fg))
      (cons bg (drgnx-quickhelp--mix fg bg 0.5)))))

(defun drgnx-quickhelp--text-width (text-w buttons-w char-w max-w)
  "The card's text width in pixels: TEXT-W (the widest line) and a character of room for the ✕, at most MAX-W —
but never less than BUTTONS-W, the buttons row: a card narrower than its buttons clips the last one."
  (max buttons-w (min max-w (+ text-w char-w))))

;;;; Placement (pure)

(defun drgnx-quickhelp-placement (win-edges bands symbol-x card-w card-h)
  "Where the card goes: (X . Y) in frame pixels, or nil when it fits nowhere.
WIN-EDGES (LEFT TOP RIGHT BOTTOM) is the window's text area; BANDS ((TOP . BOTTOM)…) are rows the card must never
cover — the first is the symbol's whole line (all its screen rows), the others such as the line point is on.
SYMBOL-X is where the symbol starts, CARD-W × CARD-H the card.  The card goes below the symbol's line when it fits
there inside the window, else above it, else just beside another band (the nearest first); it never covers a band
and never leaves the window (nil: the caller shortens the card, or shows none).  X is clamped to the window."
  (pcase-let* ((`(,left ,top ,right ,bottom) win-edges)
               (sym (car bands))
               (free (lambda (y) (not (seq-some (lambda (b) (and (< y (cdr b)) (> (+ y card-h) (car b)))) bands))))
               (inside (lambda (y) (and (>= y top) (<= (+ y card-h) bottom))))
               (near (sort (seq-mapcat (lambda (b) (list (cdr b) (- (car b) card-h))) (cdr bands))
                           (lambda (a b) (< (abs (- a (car sym))) (abs (- b (car sym)))))))
               (y (seq-find (lambda (y) (and (funcall free y) (funcall inside y)))
                            (append (list (cdr sym) (- (car sym) card-h)) near))))
    (when y (cons (max left (min symbol-x (- right card-w))) y))))

(defun drgnx-quickhelp--room (win-edges bands)
  "The tallest run of rows in WIN-EDGES's height that no band of BANDS covers, in pixels."
  (let ((y (nth 1 win-edges)) (room 0))
    (dolist (b (sort (copy-sequence bands) (lambda (a b) (< (car a) (car b)))))
      (setq room (max room (- (car b) y)) y (max y (cdr b))))
    (max room (- (nth 3 win-edges) y))))

;;;; Collecting docs: eldoc's functions, asynchronously

(defvar drgnx-quickhelp--request 0 "The id of the newest request: answers to an older one are dropped.")
(defconst drgnx-quickhelp--timeout 1.0 "Seconds a request waits for slow backends before it shows what came.")
(defconst drgnx-quickhelp--owner 'ui/face
  "The module whose run owns quick help's timers (the key `quickhelp-timeout' is the newest request's timeout).")

(defconst drgnx-quickhelp--fuller
  '((elisp-eldoc-var-docstring . elisp-eldoc-var-docstring-with-value)
    (elisp-eldoc-funcall . elisp-eldoc-funcall-with-docstring))
  "Eldoc functions whose fuller sibling (with the docstring) the card asks instead, where this Emacs has it.")

(defun drgnx-quickhelp--cancel ()
  "Drop the pending request: its answers and its timeout come to nothing."
  (cl-incf drgnx-quickhelp--request)
  (drgnx-timer-cancel 'quickhelp-timeout))

(defun drgnx-quickhelp--timed-out (finish)
  "The request's timeout (the timer's function): call FINISH, which shows what came."
  (funcall finish))

(defun drgnx-quickhelp-collect (pos window callback)
  "Ask `eldoc-documentation-functions' about POS in WINDOW's buffer (point there, in `save-excursion').
CALLBACK gets ((DOC . PLIST)…), in the functions' order, once all have answered or after one second, whichever
is first; a newer request drops this one (CALLBACK is then never called).  Returns at once."
  (drgnx-quickhelp--cancel)
  (let ((id drgnx-quickhelp--request) (answers nil) (n 0) (pending 1) (done nil))
    (cl-labels ((finish ()
                  (unless done
                    (setq done t)
                    (when (= id drgnx-quickhelp--request)
                      (drgnx-timer-cancel 'quickhelp-timeout)
                      (funcall callback (mapcar #'cdr (sort answers (lambda (a b) (< (car a) (car b)))))))))
                (answer-fn (i)
                  (let ((answered nil))
                    (lambda (doc &rest plist)
                      (unless (or answered done (/= id drgnx-quickhelp--request))
                        (setq answered t)
                        (when (and (stringp doc) (not (string-empty-p doc))) (push (cons i (cons doc plist)) answers))
                        (when (zerop (cl-decf pending)) (finish)))
                      t))))
      (with-current-buffer (window-buffer window)
        (save-excursion
          (goto-char pos)
          (let ((non-essential t))
            (run-hook-wrapped
             'eldoc-documentation-functions
             (lambda (f)
               (let* ((fuller (and (symbolp f) (alist-get f drgnx-quickhelp--fuller)))
                      (f (if (and fuller (fboundp fuller)) fuller f))
                      (cb (answer-fn (prog1 n (cl-incf n))))
                      ;; a backend that prints a value (a variable's, with its docstring) prints a short one:
                      ;; a 2M-element list took 1.5 s, from the hover timer
                      (res (progn (cl-incf pending)
                                  (let ((print-length 20) (print-level 3))
                                    (condition-case nil (funcall f cb) (error nil))))))
                 (when (or (null res) (stringp res)) (funcall cb res))
                 nil))))))
      (if (zerop (cl-decf pending))
          (finish)
        (drgnx-timer-start 'quickhelp-timeout drgnx-quickhelp--timeout #'drgnx-quickhelp--timed-out
                           :args (list #'finish) :owner drgnx-quickhelp--owner)))))

;;;; The card's text

(defconst drgnx-quickhelp--buffer-name " *drgnx-quickhelp*")

(defvar drgnx-quickhelp-showing-map (make-sparse-keymap)
  "Keys active while a quick help card shows, whichever window has the focus (the key profiles bind Esc and q to
Close Quick Help).")

(defvar drgnx-quickhelp--showing nil "Non-nil from a request until the card is put away: the showing map is on.")
(defvar drgnx-quickhelp--emulation (list (cons 'drgnx-quickhelp--showing drgnx-quickhelp-showing-map)))

(defvar drgnx-quickhelp-card-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m drgnx-quickhelp-showing-map)
    (define-key m [down-mouse-1] #'ignore)
    (define-key m [mouse-1] #'drgnx-quickhelp--click)
    m)
  "The card's buffer: a click runs the button under the mouse (and the showing map's keys).")

(defun drgnx-quickhelp--wrap (line width)
  "LINE (a string, its properties kept) cut into lines of at most WIDTH columns, at a space where there is one."
  (let (out)
    (while (> (string-width line) width)
      (let* ((fit (length (truncate-string-to-width line width)))
             (space (cl-position ?\s line :end (min (length line) (1+ fit)) :from-end t))
             (cut (if (and space (> space 0)) space (max 1 fit))))
        (push (substring line 0 cut) out)
        (setq line (string-trim-left (substring line cut) " +"))))
    (nreverse (cons line out))))

(defun drgnx-quickhelp--doc-lines (docs width max)
  "DOCS as at most MAX lines of at most WIDTH columns: \"THING: DOC\" each, the last line … when cut."
  (let ((lines (seq-mapcat
                (lambda (d)
                  (let* ((thing (plist-get (cdr d) :thing))
                         (text (concat (if thing (concat (propertize (format "%s" thing) 'face 'drgnx-quickhelp-title) ": ") "")
                                       (string-trim (car d)))))
                    (seq-mapcat (lambda (l) (drgnx-quickhelp--wrap l width)) (split-string text "\n"))))
                docs)))
    (if (<= (length lines) max) lines
      (append (seq-take lines (max 0 (1- max))) (list "…")))))

(defun drgnx-quickhelp--button (label action help)
  (propertize label 'face 'button 'mouse-face 'highlight 'help-echo help 'drgnx-quickhelp-action action))

(defun drgnx-quickhelp--buttons ()
  "The card's row of buttons."
  (concat (drgnx-quickhelp--button "Open Help" #'drgnx-quickhelp--open-help "The full documentation, in the Help tab")
          "  "
          (drgnx-quickhelp--button "Go to Definition" #'drgnx-quickhelp--definition "Jump to where it is defined")
          "  "
          (drgnx-quickhelp--button "Find References" #'drgnx-quickhelp--references "Every use of it")))

(defun drgnx-quickhelp--close-button ()
  (propertize (drgnx-quickhelp--button (or (drgnx-face-glyph 'close) "x") #'ignore "Close (Esc)") 'face 'default))

(defconst drgnx-quickhelp--gap '(space :align-to (- right 2)) "The space before the ✕: up to the right edge.")

(defun drgnx-quickhelp--render (docs width max strip)
  "Fill the card's buffer: DOCS in WIDTH columns, at most MAX lines; STRIP: the buttons on top (a terminal)."
  (let ((buf (get-buffer-create drgnx-quickhelp--buffer-name))
        (lines (cond ((eq docs :pending) (list "…"))         ; asked, not answered yet
                     (docs (drgnx-quickhelp--doc-lines docs (if strip width (max 10 (- width 3))) max))   ; room for the ✕
                     (t (list "No documentation here.")))))
    (with-current-buffer buf
      (buffer-disable-undo)                             ; redrawn on every card
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq-local mode-line-format nil header-line-format nil tab-line-format nil
                    cursor-type nil cursor-in-non-selected-windows nil truncate-lines t
                    buffer-read-only t show-trailing-whitespace nil
                    face-remapping-alist (if-let* ((bg (car (drgnx-quickhelp-colors))))
                                             `((default (:background ,bg) drgnx-quickhelp))
                                           '((default drgnx-quickhelp))))
        (use-local-map drgnx-quickhelp-card-map)
        ;; the card measures itself with a plain gap first, then the gap pushes the ✕ to the right edge
        (let ((close (concat (propertize " " 'display (if strip drgnx-quickhelp--gap '(space :width 2))
                                         'drgnx-quickhelp-gap t)
                             (drgnx-quickhelp--close-button))))
          (if strip
              (insert (drgnx-quickhelp--buttons) close "\n" (string-join lines "\n"))
            (insert (car lines) close "\n" (string-join (cdr lines) "\n") (if (cdr lines) "\n" "")
                    (drgnx-quickhelp--buttons))))
        (goto-char (point-min))))
    buf))

;;;; State

(defvar drgnx-quickhelp--frame nil "The card's child frame (graphical frames), made once and reused.")
(defvar drgnx-quickhelp--strip nil "The strip window (terminal frames) while it shows.")
(defvar drgnx-quickhelp--origin nil
  "What the card is about, from its request until it is put away: (:window :buffer :pos :selected :key :docs).")

(defvar drgnx-quickhelp--card-up nil "Non-nil while the card's frame is placed beside a symbol (not parked).")

(defun drgnx-quickhelp-shown-p ()
  "Non-nil while a quick help card (or strip) shows."
  (and drgnx-quickhelp--origin
       (or (window-live-p drgnx-quickhelp--strip)
           (and drgnx-quickhelp--card-up (frame-live-p drgnx-quickhelp--frame) (frame-visible-p drgnx-quickhelp--frame)))
       t))

(defun drgnx-quickhelp--unmap ()
  "Unmap the parked card (from an idle timer: a pgtk child frame's unmap waits ~100 ms for the compositor)."
  (when (and (not drgnx-quickhelp--card-up) (frame-live-p drgnx-quickhelp--frame) (frame-visible-p drgnx-quickhelp--frame))
    (make-frame-invisible drgnx-quickhelp--frame)))

(defun drgnx-quickhelp--park ()
  "Put the card's frame out of sight at once: moved outside its parent (about 1 ms, where unmapping it can take
100 ms in the middle of your typing), unmapped once Emacs has been idle for a second."
  (setq drgnx-quickhelp--card-up nil)
  (when (and (frame-live-p drgnx-quickhelp--frame) (frame-visible-p drgnx-quickhelp--frame))
    (set-frame-position drgnx-quickhelp--frame -10000 -10000)
    (drgnx-timer-soon 'quickhelp-unmap 1 #'drgnx-quickhelp--unmap :idle t :owner drgnx-quickhelp--owner)))

(defun drgnx-quickhelp--card-window ()
  (cond ((window-live-p drgnx-quickhelp--strip) drgnx-quickhelp--strip)
        ((frame-live-p drgnx-quickhelp--frame) (frame-root-window drgnx-quickhelp--frame))))

(defvar drgnx-quickhelp--rest nil "(KEY . SINCE): the symbol the mouse is on and since when; KEY is (WINDOW . START).")

(defvar drgnx-quickhelp--still nil
  "Hover waits for the pointer to move after a command or after the card went (else a card would come back at
every pause in your typing, the mouse resting on the text): t — a command ran, the next look notes where the
pointer is; a `mouse-pixel-position' — waiting for the pointer to leave it; nil — it moved, hover is armed.")

(defun drgnx-quickhelp--note-pointer ()
  "On `pre-command-hook' (while hover is on) and when the card goes: hover waits for the pointer to move.
Only a flag: the position is read at the next idle look, never per keystroke."
  (setq drgnx-quickhelp--still t drgnx-quickhelp--rest nil))

(defun drgnx-quickhelp-hide ()
  "Put the card away (and drop a request still waiting for docs); hover waits for the pointer to move."
  (drgnx-quickhelp--teardown)
  (drgnx-quickhelp--note-pointer))

(defun drgnx-quickhelp--teardown ()
  "Put the card away and drop a request still waiting for docs."
  (drgnx-quickhelp--cancel)
  (setq drgnx-quickhelp--origin nil)
  (remove-hook 'pre-command-hook #'drgnx-quickhelp--pre-command)
  (remove-hook 'post-command-hook #'drgnx-quickhelp--post-command)
  (setq drgnx-quickhelp--showing nil)
  (drgnx-quickhelp--park)
  (when (window-live-p drgnx-quickhelp--strip) (delete-window drgnx-quickhelp--strip))
  (setq drgnx-quickhelp--strip nil))

(defconst drgnx-quickhelp--keep-commands
  '(drgnx-quickhelp-show drgnx-quickhelp-close drgnx-quickhelp--click ignore handle-switch-frame)
  "Commands that leave the card where it is (the card's own; the rest put it away).")

(defconst drgnx-quickhelp--scroll-commands
  '(mwheel-scroll pixel-scroll-precision ultra-scroll scroll-up-command scroll-down-command)
  "Scrolling commands: they keep the card when the mouse scrolls the card itself.")

(defun drgnx-quickhelp--on-card-p (event)
  "Non-nil when EVENT is a mouse event on the card."
  (and (consp event) (windowp (posn-window (event-start event)))
       (eq (posn-window (event-start event)) (drgnx-quickhelp--card-window))))

(defun drgnx-quickhelp--pre-command ()
  "Before each command: anything but the card's own buttons and scrolling the card puts it away (typing too)."
  (unless (or (memq this-command drgnx-quickhelp--keep-commands)
              (and (memq this-command drgnx-quickhelp--scroll-commands) (drgnx-quickhelp--on-card-p last-input-event)))
    (drgnx-quickhelp-hide)))

(defun drgnx-quickhelp--post-command ()
  "After each command: another window or another buffer in it puts the card away."
  (let ((o drgnx-quickhelp--origin))
    (when (and o (not (eq (selected-window) (drgnx-quickhelp--card-window)))
               (or (not (eq (selected-window) (plist-get o :selected)))
                   (not (window-live-p (plist-get o :window)))
                   (not (eq (window-buffer (plist-get o :window)) (plist-get o :buffer)))))
      (drgnx-quickhelp-hide))))

;;;; Showing: a child frame (graphical), a strip (terminal)

(defun drgnx-quickhelp--line-geometry (win pos)
  "(LINE-TOP LINE-BOTTOM SYMBOL-X) of POS in WIN, in WIN's frame's pixels; nil when POS is not on screen.
`pos-visible-in-window-p' gives X from the text area's left edge but Y from the window's top edge (its tab and
header lines included), so each is added to its own origin."
  (when-let* ((xy (pos-visible-in-window-p pos win t)))
    (pcase-let* ((`(,x ,y . ,rest) xy)
                 (left (nth 0 (window-inside-pixel-edges win)))
                 (top (nth 1 (window-pixel-edges win)))
                 (height (if (nth 2 rest) (nth 2 rest)
                           (with-selected-window win (save-excursion (goto-char pos) (line-pixel-height))))))
      (list (+ top y) (+ top y height) (+ left x)))))

(defun drgnx-quickhelp--make-frame (parent)
  "The card's child frame of PARENT (made once; moved to another parent when needed, made again for a parent on
another display)."
  (when (and (frame-live-p drgnx-quickhelp--frame)
             (not (eq (frame-terminal drgnx-quickhelp--frame) (frame-terminal parent))))
    (delete-frame drgnx-quickhelp--frame)
    (setq drgnx-quickhelp--frame nil drgnx-quickhelp--card-up nil))
  (if (frame-live-p drgnx-quickhelp--frame)
      (unless (eq (frame-parent drgnx-quickhelp--frame) parent)
        (set-frame-parameter drgnx-quickhelp--frame 'parent-frame parent))
    (let ((after-make-frame-functions nil) (before-make-frame-hook nil))
      (setq drgnx-quickhelp--frame
            (make-frame `((parent-frame . ,parent) (minibuffer . nil) (no-accept-focus . t) (undecorated . t)
                          (no-focus-on-map . t) (no-other-frame . t) (skip-taskbar . t) (unsplittable . t)
                          (visibility . nil) (width . 40) (height . 4) (child-frame-border-width . 1)
                          (internal-border-width . 0) (left-fringe . 0) (right-fringe . 0)
                          (vertical-scroll-bars . nil) (horizontal-scroll-bars . nil) (menu-bar-lines . 0)
                          (tool-bar-lines . 0) (tab-bar-lines . 0) (line-spacing . 0) (cursor-type . nil)
                          (desktop-dont-save . t) (drgnx-quickhelp . t))))))
  (let ((win (frame-root-window drgnx-quickhelp--frame)))
    (set-window-buffer win (get-buffer-create drgnx-quickhelp--buffer-name))
    (set-window-dedicated-p win t)
    (dolist (p '(mode-line-format header-line-format tab-line-format)) (set-window-parameter win p 'none)))
  ;; the 1px border from the theme's colours, read at show time: the `child-frame-border' face where the toolkit
  ;; draws the border from it, and the frame's background colour where it paints the border with that (pgtk, 30.2);
  ;; the text and its margins have the card's own background, from the buffer's face remapping (`drgnx-quickhelp--render')
  (when-let* ((colors (drgnx-quickhelp-colors parent)))
    (unless (equal (frame-parameter drgnx-quickhelp--frame 'background-color) (cdr colors))
      (set-frame-parameter drgnx-quickhelp--frame 'background-color (cdr colors)))
    (set-face-background 'child-frame-border (cdr colors) drgnx-quickhelp--frame))
  drgnx-quickhelp--frame)

(defun drgnx-quickhelp--buttons-width (win)
  "The pixel width of the buttons row (the card buffer's last line) in WIN, and a character of room."
  (with-current-buffer (window-buffer win)
    (+ (car (window-text-pixel-size win (save-excursion (goto-char (point-max)) (line-beginning-position)) (point-max) 4000))
       (frame-char-width (window-frame win)))))

(defun drgnx-quickhelp--fit (frame max-w)
  "Size FRAME to its buffer, at most MAX-W pixels wide; then put the ✕ at its right edge.  (W . H) in pixels."
  (let ((win (frame-root-window frame)) (frame-resize-pixelwise t) (window-min-height 1) (window-min-width 1)
        (pad (* 2 (frame-char-width frame))))      ; a column of the card's colour on each side
    (set-window-margins win 1 1)
    (set-frame-size frame (+ (max max-w 50) pad) 2000 t)
    (pcase-let ((`(,w . ,h) (window-text-pixel-size win nil nil max-w 2000)))
      (let ((w (+ pad (drgnx-quickhelp--text-width w (drgnx-quickhelp--buttons-width win) (frame-char-width frame) max-w)))
            (border (* 2 (+ (or (frame-parameter frame 'child-frame-border-width) 0)
                            (or (frame-parameter frame 'internal-border-width) 0)))))
        (set-frame-size frame w h t)
        (with-current-buffer (window-buffer win)
          (let ((inhibit-read-only t) (gap (text-property-any (point-min) (point-max) 'drgnx-quickhelp-gap t)))
            (when gap (put-text-property gap (1+ gap) 'display drgnx-quickhelp--gap))))
        (cons (+ w border) (+ h border))))))

(defun drgnx-quickhelp--text-edges (win)
  "WIN's text area (LEFT TOP RIGHT BOTTOM) in frame pixels: below its tab and header lines (Emacs 30's
`window-body-pixel-edges' counts a tab line as body)."
  (let ((body (window-body-pixel-edges win)))
    (list (nth 0 body)
          (+ (nth 1 (window-pixel-edges win)) (window-tab-line-height win) (window-header-line-height win))
          (nth 2 body) (nth 3 body))))

(defun drgnx-quickhelp--line-band (win pos edges)
  "(TOP . BOTTOM): the rows of POS's whole line in WIN (every screen row of a wrapped line), clamped to EDGES."
  (with-current-buffer (window-buffer win)
    (save-excursion
      (goto-char pos)
      (let* ((bol (line-beginning-position)) (eol (line-end-position))
             (first (and (>= bol (window-start win)) (drgnx-quickhelp--line-geometry win bol)))
             (last (drgnx-quickhelp--line-geometry win eol)))
        (cons (if first (max (nth 1 edges) (car first)) (nth 1 edges))
              (if last (min (nth 3 edges) (nth 1 last)) (nth 3 edges)))))))

(defun drgnx-quickhelp--show-card (docs)
  "Show DOCS in the child frame beside the origin's symbol, below its line (above when no room); never over the
symbol's whole line or the line point is on."
  (let* ((o drgnx-quickhelp--origin) (win (plist-get o :window)) (pos (plist-get o :pos))
         (geo (and (window-live-p win) (drgnx-quickhelp--line-geometry win pos))))
    (when geo
      (pcase-let* ((`(,_ ,_ ,sym-x) geo)
                   (edges (drgnx-quickhelp--text-edges win))
                   (`(,left ,_ ,right ,_) edges)
                   (bands (cons (drgnx-quickhelp--line-band win pos edges)
                                (and (eq win (selected-window))
                                     (list (drgnx-quickhelp--line-band win (window-point win) edges)))))
                   (parent (window-frame win))
                   (cw (frame-char-width parent))
                   (max-w (max (* cw (1+ (string-width (drgnx-quickhelp--buttons))))   ; never narrower than the buttons
                               (min (* 80 cw) (- right left (* 2 cw)))))
                   (room (drgnx-quickhelp--room edges bands))
                   (frame (drgnx-quickhelp--make-frame parent))
                   (cols (max 20 (/ max-w cw)))
                   (lines drgnx-quickhelp-max-lines)
                   (size nil))
        (drgnx-quickhelp--render docs cols lines nil)
        (setq size (drgnx-quickhelp--fit frame max-w))
        ;; too tall for either side of the line: fewer lines of docs
        (while (and (> (cdr size) room) (> lines 1))
          (setq lines (max 1 (min (1- lines) (floor (* lines (/ (float room) (cdr size)))))))
          (drgnx-quickhelp--render docs cols lines nil)
          (setq size (drgnx-quickhelp--fit frame max-w)))
        (when-let* ((xy (drgnx-quickhelp-placement edges bands sym-x (car size) (cdr size))))   ; nil: no room
          ;; a window narrower than the buttons row: the card stays on the frame (over the window beside)
          (set-frame-position frame (max 0 (min (car xy) (- (frame-pixel-width parent) (car size)))) (cdr xy))
          (unless (frame-visible-p frame) (make-frame-visible frame))
          (setq drgnx-quickhelp--card-up t
                ;; what it was placed against: a look puts it away when the window scrolls; the store's events, when it moves
                drgnx-quickhelp--origin (plist-put (plist-put o :start (window-start win)) :edges (drgnx-state-edges win)))
          (drgnx-quickhelp--watch-card)
          t)))))

(defun drgnx-quickhelp--open-strip (win)
  "A strip of `drgnx-quickhelp-strip-lines' under WIN (its own split, given back whole when it goes); nil when
WIN is too small.  Point stays visible."
  (let ((lines drgnx-quickhelp-strip-lines))
    (when (>= (window-total-height win) (+ lines window-min-height 1))
      (let* ((window-combination-limit t)              ; WIN and the strip in a parent of their own
             (strip (ignore-errors (split-window win (- lines) 'below))))
        (when strip
          (set-window-buffer strip (drgnx-quickhelp--render :pending (window-body-width win) 0 t))
          (set-window-dedicated-p strip t)
          (dolist (p '((drgnx-role . quickhelp) (no-other-window . t) (mode-line-format . none)
                       (header-line-format . none) (tab-line-format . none)))
            (set-window-parameter strip (car p) (cdr p)))
          (unless (pos-visible-in-window-p (window-point win) win)
            (with-selected-window win (recenter -1)))
          strip)))))

(defun drgnx-quickhelp--show (docs)
  "The answer came: show DOCS (nil: none) for the origin, as a card or in the strip."
  (let ((o drgnx-quickhelp--origin))
    (when o
      (setq drgnx-quickhelp--origin (plist-put o :docs docs))
      (cond ((null docs)                                ; nothing to show: no card, no strip; the key says so
             (drgnx-quickhelp-hide)
             (when (plist-get o :key) (message "No documentation here.")))
            ((window-live-p drgnx-quickhelp--strip)
             (drgnx-quickhelp--render docs (window-body-width drgnx-quickhelp--strip)
                                      (1- (window-body-height drgnx-quickhelp--strip)) t))
            ;; no strip, or no room for a card beside the line: the first line in the echo area for the key, nothing
            ;; for a hover
            ((or (not (eq (drgnx-state-frame-kind (window-frame (plist-get o :window))) 'gui)) (not (drgnx-quickhelp--show-card docs)))
             (drgnx-quickhelp-hide)
             (when (and docs (plist-get o :key)) (message "%s" (car (drgnx-quickhelp--doc-lines docs 200 1)))))))))

(defun drgnx-quickhelp--request (win pos key)
  "Ask for the docs of POS in WIN and show them; KEY: asked with the key (else a hover).  Returns at once."
  (drgnx-quickhelp--teardown)                           ; (not `hide': hover stays armed for this card's mouse)
  (setq drgnx-quickhelp--origin (list :window win :buffer (window-buffer win) :pos pos :selected (selected-window) :key key))
  (add-hook 'pre-command-hook #'drgnx-quickhelp--pre-command)
  (add-hook 'post-command-hook #'drgnx-quickhelp--post-command)
  (setq drgnx-quickhelp--showing t)
  ;; a terminal: the strip opens now, from the command (never from a timer: the layout only changes when you act)
  (when (and key (not (eq (drgnx-state-frame-kind (window-frame win)) 'gui)))
    (setq drgnx-quickhelp--strip (drgnx-quickhelp--open-strip win)))
  (drgnx-quickhelp-collect pos win #'drgnx-quickhelp--show))

;;;; Commands and buttons

(defun drgnx-quickhelp-show ()
  "Show quick help for the symbol at point: its docs, signature and links, beside it.
Again while its card shows (same window, point not moved): Open Help.  A card from hovering is replaced by the
one at point."
  (interactive)
  (let ((o drgnx-quickhelp--origin))
    (if (and (drgnx-quickhelp-shown-p) (plist-get o :key)
             (eq (plist-get o :window) (selected-window)) (eql (plist-get o :pos) (point)))
        (drgnx-quickhelp--act #'drgnx-quickhelp--open-help)
      (drgnx-quickhelp--request (selected-window) (point) t))))

(defun drgnx-quickhelp-close ()
  "Put the quick help card away.
On a card that came from hovering, the key then does what it does without the card (q types a q, Esc is Esc): a
card you did not ask for never eats a key.  On any card, a letter (q) typed in a buffer you can edit is typed: the
card moves out of the way while you type — unless the modal engine's state does not type there
\(`drgnx-modal-typing-p': q would record a macro in Vim's normal state), where it only closes the card.  Esc and
\\`C-g' only close it."
  (interactive)
  (let* ((hover (and drgnx-quickhelp--origin (not (plist-get drgnx-quickhelp--origin :key))))
         (keys (this-command-keys-vector))
         (typed (and (= (length keys) 1) (characterp (aref keys 0)) (>= (aref keys 0) ?\s) (/= (aref keys 0) ?\d)
                     (not buffer-read-only) (drgnx-modal-typing-p))))
    (drgnx-quickhelp-hide)                                ; the showing map is off from here
    ;; the key again, read as if the card had not been there (not recorded twice in macros or the lossage)
    (when (and (or hover typed) (> (length keys) 0))
      (setq unread-command-events
            (append (mapcar (lambda (e) (cons 'no-record e)) keys) unread-command-events)))))

(defun drgnx-quickhelp--click (event)
  "Run the card's button under the mouse EVENT (the ✕ closes the card)."
  (interactive "e")
  (let* ((posn (event-start event)) (w (posn-window posn)) (p (posn-point posn))
         (action (and (windowp w) p (get-text-property p 'drgnx-quickhelp-action (window-buffer w)))))
    (cond ((eq action #'ignore) (drgnx-quickhelp-hide))
          (action (drgnx-quickhelp--act action)))))

(defun drgnx-quickhelp--act (fn)
  "Put the card away, go back to its symbol (its window selected, point on it) and call FN with the card's state."
  (let ((o drgnx-quickhelp--origin))
    (drgnx-quickhelp-hide)
    (when (and o (window-live-p (plist-get o :window)) (eq (window-buffer (plist-get o :window)) (plist-get o :buffer)))
      (select-window (plist-get o :window))
      (unless (eql (point) (plist-get o :pos))
        (push-mark nil t)                               ; a hovered spot: C-u C-SPC goes back
        (goto-char (plist-get o :pos)))
      (funcall fn o))))

(defun drgnx-quickhelp--symbol (o)
  "The symbol the card O is about, when Emacs knows it (a function, variable or face), else nil."
  (let ((thing (seq-some (lambda (d) (plist-get (cdr d) :thing)) (plist-get o :docs))))
    (seq-find (lambda (s) (and (symbolp s) s (or (fboundp s) (boundp s) (facep s))))
              (list (if (stringp thing) (intern-soft thing) thing) (intern-soft (thing-at-point 'symbol t))))))

(defun drgnx-quickhelp--open-help (o)
  "The full documentation: `describe-symbol' in Lisp, else eldoc's doc buffer (the Help tab)."
  (let ((sym (and (derived-mode-p 'emacs-lisp-mode 'lisp-interaction-mode 'lisp-data-mode) (drgnx-quickhelp--symbol o)))
        (docs (plist-get o :docs)))
    (cond (sym (describe-symbol sym))
          ((and docs (fboundp 'eldoc--format-doc-buffer)) (eldoc--format-doc-buffer docs) (eldoc-doc-buffer t))
          (t (message "No documentation here")))))

(defun drgnx-quickhelp--definition (_o) (call-interactively #'xref-find-definitions))
(defun drgnx-quickhelp--references (_o) (call-interactively #'xref-find-references))

;;;; Hover (graphical frames): an idle timer reads where the mouse rests

(defconst drgnx-quickhelp--poll-interval 0.2 "Seconds between looks at the mouse while idle.")

(defun drgnx-quickhelp--mouse-symbol ()
  "(WINDOW . START) of the symbol under the mouse in a graphical frame's text, or nil."
  (pcase-let ((`(,frame ,x . ,y) (mouse-pixel-position)))
    (when (and x y (eq (drgnx-state-frame-kind frame) 'gui))
      (let* ((posn (posn-at-x-y x y frame)) (w (posn-window posn)) (p (posn-point posn)))
        (when (and (windowp w) p (null (posn-area posn)) (not (window-minibuffer-p w)))
          (with-current-buffer (window-buffer w)
            (save-excursion
              (goto-char p)
              (when-let* ((b (bounds-of-thing-at-point 'symbol)) ((< p (cdr b))))
                (cons w (car b))))))))))

(defun drgnx-quickhelp--mouse-on-card-p ()
  (eq (car (mouse-pixel-position)) drgnx-quickhelp--frame))

(defun drgnx-quickhelp--focused-p ()
  "Non-nil when a graphical frame (not a child frame) has the focus (or Emacs cannot tell)."
  (seq-some (lambda (f) (and (eq (drgnx-state-frame-kind f) 'gui) (frame-focus-state f))) (frame-list)))

(defun drgnx-quickhelp--card-moved-p (o)
  "Non-nil when the window the card O was placed against has scrolled since (or is gone).
A move or a resize is the store's to tell (`drgnx-quickhelp--put-away'): scrolling is not window state."
  (let ((w (plist-get o :window)))
    (and (plist-get o :start)
         (or (not (window-live-p w)) (/= (window-start w) (plist-get o :start))))))

(defun drgnx-quickhelp--put-away-now (o)
  "Put the card away, unless it is not the card O any more (from the timer `drgnx-quickhelp--put-away' armed)."
  (when (and drgnx-quickhelp--card-up (eq drgnx-quickhelp--origin o))
    (drgnx-quickhelp--teardown)))

(defun drgnx-quickhelp--put-away (data)
  "A `now' subscriber of the store's `pane-resized', `windows-changed' and `selected-changed': when DATA says
the card's window moved, was resized, or the frame's windows or selection changed, arm the put-away timer at 0 s.
Only that: the card's frame is never touched during redisplay.  A strip is a window of the layout and stays."
  (let* ((o drgnx-quickhelp--origin) (win (plist-get o :window)))
    (when (and o drgnx-quickhelp--card-up
               (or (not (window-live-p win)) (eq (plist-get data :frame) (window-frame win)))
               (cond ((plist-member data :new)         ; pane-resized: any, if the card's window has other edges
                      (not (equal (drgnx-state-edges win) (plist-get o :edges))))
                     ((plist-member data :windows) t)  ; windows-changed
                     (t (not (memq (plist-get data :window) (list (plist-get o :selected) (drgnx-quickhelp--card-window)))))))
      (drgnx-timer-soon 'quickhelp-away 0 #'drgnx-quickhelp--put-away-now
                        :args (list o) :owner drgnx-quickhelp--owner))))

(defun drgnx-quickhelp--watch-windows ()
  "Hear from the store when the card's window moves (a module setup's own subscriptions: undone with it)."
  (dolist (event '(pane-resized windows-changed selected-changed))
    (drgnx-state-subscribe event #'drgnx-quickhelp--put-away :lane 'now)))

(defun drgnx-quickhelp--hover-step (o)
  "Hover's part of a look, O the card's state: once the pointer has moved since the last command, a symbol rested
on for `drgnx-quickhelp-delay' gets its card; a hover card goes when the mouse leaves its symbol and the card.
The look's own hides are teardowns: the pointer is moving, so the next symbol gets its card."
  (cond ((eq drgnx-quickhelp--still t) (setq drgnx-quickhelp--still (mouse-pixel-position)))
        ((and drgnx-quickhelp--still (not (equal (mouse-pixel-position) drgnx-quickhelp--still)))
         (setq drgnx-quickhelp--still nil)))            ; the pointer moved: hover is armed
  (unless drgnx-quickhelp--still                        ; resting where it was when you last typed: nothing
    (let ((key (drgnx-quickhelp--mouse-symbol)) (now (float-time)))
      (unless (equal key (car drgnx-quickhelp--rest)) (setq drgnx-quickhelp--rest (cons key now)))
      (cond ((and o (plist-get o :key)))                          ; a card you asked for stays
            ((drgnx-quickhelp--mouse-on-card-p))                 ; on the card: it stays
            ((null key) (when o (drgnx-quickhelp--teardown)))
            ((and o (eq (car key) (plist-get o :window)) (= (cdr key) (plist-get o :pos))))
            ((>= (- now (cdr drgnx-quickhelp--rest)) drgnx-quickhelp-delay)
             (drgnx-quickhelp--request (car key) (cdr key) nil))
            (o (drgnx-quickhelp--teardown))))))

(defun drgnx-quickhelp--hover-look ()
  "One look, while Emacs is idle: a card whose window scrolled goes (hover on or off); with hover
on and a graphical frame focused, `drgnx-quickhelp--hover-step'.  Looks go on while a card is up or hover looks."
  (let* ((idle (current-idle-time))
         (quiet (and idle (>= (float-time idle) (* 0.75 drgnx-quickhelp--poll-interval))))
         (o drgnx-quickhelp--origin)
         (hovering (and quiet drgnx-quickhelp-hover (not (active-minibuffer-window)) (drgnx-quickhelp--focused-p))))
    (when (and quiet o drgnx-quickhelp--card-up (drgnx-quickhelp--card-moved-p o))
      (drgnx-quickhelp--teardown)
      (setq o nil))
    (when hovering (drgnx-quickhelp--hover-step o))
    (when (or hovering drgnx-quickhelp--card-up)
      (drgnx-timer-soon 'quickhelp-look drgnx-quickhelp--poll-interval #'drgnx-quickhelp--hover-look
                        :owner drgnx-quickhelp--owner))))

(defun drgnx-quickhelp--watch-card ()
  "A card is up: make sure a look comes (with hover off the idle timer is not running)."
  (drgnx-timer-soon 'quickhelp-look drgnx-quickhelp--poll-interval #'drgnx-quickhelp--hover-look
                    :owner drgnx-quickhelp--owner))

(defun drgnx-quickhelp--hover-start ()
  "Emacs went idle: start looking at the mouse (once per idle spell)."
  (unless (drgnx-timer-active-p 'quickhelp-look) (drgnx-quickhelp--hover-look)))

(defun drgnx-quickhelp--apply-hover ()
  "The hover timer on when the setting asks and quick help is set up, else off."
  (drgnx-timer-cancel 'quickhelp-hover)
  (drgnx-timer-cancel 'quickhelp-look)
  (setq drgnx-quickhelp--rest nil)
  (remove-hook 'pre-command-hook #'drgnx-quickhelp--note-pointer)
  (when (and drgnx-quickhelp--active drgnx-quickhelp--card-up) (drgnx-quickhelp--watch-card))   ; a card up: looks go on
  (when (and drgnx-quickhelp--active drgnx-quickhelp-hover)
    (add-hook 'pre-command-hook #'drgnx-quickhelp--note-pointer)
    (drgnx-timer-start 'quickhelp-hover drgnx-quickhelp--poll-interval #'drgnx-quickhelp--hover-start
                       :idle t :repeat t :owner drgnx-quickhelp--owner)))

(defun drgnx-quickhelp-toggle-hover ()
  "Quick help on hover on or off, for this session (`drgnx-quickhelp-hover' keeps the default)."
  (interactive)
  (customize-set-variable 'drgnx-quickhelp-hover (not drgnx-quickhelp-hover))
  (message "Quick help on hover %s" (if drgnx-quickhelp-hover "on" "off")))

(defun drgnx-quickhelp-setup ()
  "Define the commands and start the hover timer (ui/face's setup)."
  (drgnx-command-define 'quick-help :category "Help" :title "Show Quick Help" :command #'drgnx-quickhelp-show
                        :scope 'editing
                        :doc "The symbol's docs and signature in a card beside it (a strip in a terminal); again: Open Help")
  (drgnx-command-define 'quick-help-toggle-hover :category "Help" :title "Toggle Quick Help on Hover"
                        :command #'drgnx-quickhelp-toggle-hover
                        :doc "Show quick help when the mouse rests on a symbol, or only on the key")
  (drgnx-command-define 'quick-help-close :category "Help" :title "Close Quick Help" :command #'drgnx-quickhelp-close
                        :map 'drgnx-quickhelp-showing-map :when #'drgnx-quickhelp-shown-p
                        :doc "Put the quick help card away (a card from hovering lets the key through)")
  (add-to-list 'emulation-mode-map-alists 'drgnx-quickhelp--emulation)
  ;; first in front of the modal engine's maps (evil's normal state takes Esc and q), then Close Pane's
  (add-to-list 'drgnx-modal-front-alists 'drgnx-quickhelp--emulation)
  (drgnx-modal-order-alists)
  (drgnx-state-define-role 'quickhelp)    ; the terminal strip's window: no editor, no chrome
  (drgnx-quickhelp--watch-windows)
  (setq drgnx-quickhelp--active t)
  (drgnx-quickhelp--apply-hover))

(provide 'drgnx-quickhelp)
;;; drgnx-quickhelp.el ends here
