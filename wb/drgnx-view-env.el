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
(require 'drgnx-ui-kit)

(defvar drgnx-hub--events)
(defvar drgnx-look-motion)
(defvar drgnx-look-density)
(defvar text-scale-mode-amount)
(defvar text-scale-mode-step)
(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-view-patch-env-sent "drgnx-view")
(declare-function drgnx-view-sja-held-p "drgnx-view-sja" (view class))
(declare-function drgnx-view-patch-reclass "drgnx-view")
(defvar drgnx-view-patch)
(defvar drgnx-view-patch--buffers)
(defvar drgnx-view-patch-twin-function)
(declare-function drgnx-view-patch-class "drgnx-view")

(defconst drgnx-view-env-delay 0.1
  "Seconds of idleness after a width change before its env is sent.")

(defconst drgnx-view-env-roles '((ui . default) (text . drgnx-ui-text) (code . fixed-pitch) (card . variable-pitch)
                                 (caption . drgnx-ui-caption) (code-small . drgnx-code-small))
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
  "((FONT-NAME . REMAPS) . CHAR) → its advance in px, as the editor measured it for a `view-glyphs' ask, REMAPS the
measuring buffer's `face-remapping-alist' (bounded:
`drgnx-view-env-glyph-cache-max').")

(defvar drgnx-view-env--hooked nil "Non-nil while the global hooks are on (the first view added them).")

(defvar drgnx-view-patch-twin-of)
(declare-function drgnx-view-patch-attach "drgnx-view")
(declare-function drgnx-view-patch-view "drgnx-view")
(declare-function drgnx-view-patch-sja "drgnx-view")
(defvar drgnx-view-patch-patched-functions)
(defvar drgnx-view-patch-id-prop)
(defvar drgnx-view-nav-faces)
(defvar drgnx-view-nav-through-faces)
(defvar drgnx-view-nav-notice-method)
(defvar drgnx-view-nav-list)
(defvar drgnx-view-nav-paged-functions)

(defvar-local drgnx-view-env--twin-prefix nil
  "In a twin made by `drgnx-view-env-twin': the prefixes of the view buffer's locals it copies before each command.")

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

(defun drgnx-view-env--drawn-font (face buffer window)
  "FACE's font as it draws in BUFFER in WINDOW's frame, as `drgnx-view-env--font' gives it: FACE merged over BUFFER's
remapped `default' (its family, its `text-scale' height), which `face-font' does not see; nil on a terminal."
  (when-let* (((display-graphic-p (window-frame window)))
              (remap (cdr (assq 'default (buffer-local-value 'face-remapping-alist buffer))))
              (specs (if (and (consp remap) (not (keywordp (car remap)))) remap (list remap)))
              (font (with-current-buffer buffer
                      (ignore-errors (font-at 0 window (propertize "x" 'face (cons face specs))))))
              (q (query-font font)))
    ;; `query-font': [NAME FILENAME PIXEL-SIZE SIZE ASCENT DESCENT SPACE-WIDTH AVERAGE-WIDTH CAPABILITY]
    (list (aref q 1) 0 (aref q 2) (aref q 4) (aref q 5) (aref q 7) (aref q 6) (aref q 0))))

(defun drgnx-view-env--window-facts (window &optional buffer)
  "The facts of the display class WINDOW shows BUFFER in (default: its buffer; a twin is measured as its view's
buffer): a plist :display :scale :fonts :cell.  FONTS is a list of (ROLE FILE INDEX PX ASCENT DESCENT AVG SPACE NAME),
read in BUFFER: `face-font' resolves a face through the current buffer's remapping, and the window change hooks run
in whichever buffer is current (the agent panel's maps `default' to `drgnx-ui-text')."
  (let* ((frame (window-frame window)) (buffer (or buffer (window-buffer window)))
         (gui (display-graphic-p frame)) (factor (drgnx-view-env--scale-factor buffer)))
    (list :display (if gui "gui" "tty")
          :scale (if gui (drgnx-pixels-scale frame) 1.0)
          :fonts (and gui (with-current-buffer buffer
                            (delq nil (mapcar (lambda (r)
                                                (when-let* ((f (drgnx-view-env--font (cdr r) frame factor)))
                                                  (cons (symbol-name (car r)) f)))
                                              drgnx-view-env-roles))))
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

(defun drgnx-view-env--kit-glyphs (frame)
  "The kit's glyphs as FRAME draws them, ((NAME GLYPH)...): ASCII on a terminal that is not UTF-8 (`drgnx-face-glyph')."
  (mapcar (lambda (n) (list (symbol-name n) (drgnx-face-glyph n frame))) (drgnx-ui-kit-glyph-names)))

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

(defun drgnx-view-env--twins (view)
  "VIEW's twins: ((CLASS . BUFFER) ...), the live buffers that show it in another display class."
  (let (out)
    (when (boundp 'drgnx-view-patch--buffers)
      (maphash (lambda (pair b)
                 (when (and (equal (car pair) view) (buffer-live-p b)
                            (buffer-local-value 'drgnx-view-patch-twin-of b))
                   (push (cons (cdr pair) b) out)))
               drgnx-view-patch--buffers))
    out))

(defun drgnx-view-env--window-classes (view)
  "((WINDOW . FACTS) ...): the windows that show VIEW (its buffer or a twin), or the selected one for a headless view."
  (let ((buffer (car (gethash view drgnx-view-env--views))))
    (when (buffer-live-p buffer)
      (mapcar (lambda (w) (cons w (drgnx-view-env--window-facts w buffer)))
              (or (apply #'append (drgnx-view-env--windows buffer)
                         (mapcar (lambda (c) (drgnx-view-env--windows (cdr c))) (drgnx-view-env--twins view)))
                  (and (gethash view drgnx-view-env--headless) (list (selected-window))))))))

(defun drgnx-view-env--show (window buffer)
  "Show BUFFER in WINDOW, which keeps its dedication."
  (unless (eq (window-buffer window) buffer)
    (let ((dedicated (window-dedicated-p window)))
      (set-window-dedicated-p window nil)
      (set-window-buffer window buffer t)
      (set-window-dedicated-p window dedicated))))

(defun drgnx-view-env--route (view wins)
  "One buffer per display class (Call 2, RRO-BUFFER-PER-CLASS-1): of WINS ((WINDOW . FACTS) ...), the windows of the
class VIEW's buffer is paired with show that buffer, each other class's a twin made by the buffer's
`drgnx-view-patch-twin-function' (then the env of that class goes out and its rows come to the twin).  A twin whose
class no window shows goes.  When no window shows the buffer's class, the buffer takes the first class shown."
  (let* ((buffer (car (gethash view drgnx-view-env--views)))
         (classes (delete-dups (mapcar (lambda (w) (drgnx-view-env--class (cdr w))) wins)))
         (twins (drgnx-view-env--twins view))
         (own (with-current-buffer buffer
                (and (bound-and-true-p drgnx-view-patch) (drgnx-view-patch-class drgnx-view-patch)))))
    (when (and classes (not (member own classes)))
      ;; the twin of the class the buffer takes goes first: its kill forgets the (view, class) pair
      (when-let* ((tw (cdr (assoc (car classes) twins)))) (kill-buffer tw))
      (drgnx-view-patch-reclass buffer (car classes))
      (setq own (car classes) twins (drgnx-view-env--twins view)))
    (dolist (class classes)
      (unless (or (equal class own) (assoc class twins))
        (let ((tw (with-current-buffer buffer (funcall drgnx-view-patch-twin-function class))))
          (when (buffer-live-p tw)
            (with-current-buffer tw (setq-local drgnx-view-patch-twin-of buffer))
            (push (cons class tw) twins)))))
    (dolist (w wins)
      (let ((class (drgnx-view-env--class (cdr w))))
        (drgnx-view-env--show (car w) (if (equal class own) buffer (or (cdr (assoc class twins)) buffer)))))
    (dolist (tw twins)
      (unless (member (car tw) classes) (kill-buffer (cdr tw))))))

(defun drgnx-view-env--right-fringe (window)
  "WINDOW's right fringe, in pixels."
  (or (cadr (window-fringes window)) 0))

(defvar-local drgnx-view-env-tail nil
  "In a hub-fed view's buffer whose rows get a tail at the window's right edge (the Explorer's, the Buffers panel's,
`drgnx-wb-row-tail'), a function of a window: (MARK CONTROL), where the tail's git mark and its control start, in
pixels (a terminal's: columns) from the right edge (`drgnx-wb-tail-px').  The env's `tail': the hub ends a row's text
short of what its tail always draws.  Nil: the rows get no tail.")

(defun drgnx-view-env--width (window facts)
  "The pixels WINDOW (with FACTS) gives a row: its body, less a column when a GUI window has no right fringe (Emacs
keeps that column for its truncation glyph, and a row as wide as the body would end in a `$')."
  (let ((px (window-body-width window t)))
    (if (and (equal (plist-get facts :display) "gui") (zerop (drgnx-view-env--right-fringe window)))
        (- px (or (car (plist-get facts :cell)) 0))
      px)))

(defun drgnx-view-env--tail (window buffer)
  "The env's `tail' for WINDOW: [MARK CONTROL] from `drgnx-view-env-tail' of BUFFER (the view's own, which its twins
in other display classes share), or nil."
  (when-let* ((fn (and (buffer-live-p buffer) (buffer-local-value 'drgnx-view-env-tail buffer))))
    (apply #'vector (funcall fn window))))

(defun drgnx-view-env--envs (view &optional wins)
  "VIEW's env per display class it shows in now: a list of (CLASS . PARAMS), PARAMS without the epoch.  WIDTH_PX is
the narrowest window of the class (Call 2: one buffer per class, which holds one fit).  WINS: VIEW's windows with
their facts (`drgnx-view-env--window-classes'), read again when not given."
  (let ((classes nil))
    (dolist (wf (or wins (drgnx-view-env--window-classes view)))
      (let* ((w (car wf)) (facts (cdr wf)) (class (drgnx-view-env--class facts))
             (width (drgnx-view-env--width w facts)) (have (assoc class classes))
             (tail (drgnx-view-env--tail w (car (gethash view drgnx-view-env--views)))))
        (if have
            (setf (plist-get (cdr have) :width_px) (min width (plist-get (cdr have) :width_px)))
          (push (cons class (append (list :view view :class class :display (plist-get facts :display)
                                          :scale (plist-get facts :scale)
                                          :fonts (mapcar (lambda (f) (cl-subseq f 0 8)) (plist-get facts :fonts))
                                          :cell (plist-get facts :cell) :width_px width
                                          :palette (drgnx-view-env--palette)
                                          :tty_widths (let ((t-w (drgnx-view-env--tty-widths))) (if (eq t-w :none) nil t-w))
                                          :tz (format-time-string "%z")
                                          :reduced_motion (if (eq (bound-and-true-p drgnx-look-motion) 'reduced) t :false)
                                          :glyphs (drgnx-view-env--kit-glyphs (window-frame w))
                                          ;; the user's density: the kit's sizes that follow it (a change is a new epoch)
                                          :density (symbol-name (or (bound-and-true-p drgnx-look-density) 'comfortable))
                                          ;; rows only read, never drawn: the hub fits them to no window
                                          :headless (if (gethash view drgnx-view-env--headless) t :false))
                                    ;; where a row's tail is drawn, from the right edge
                                    (and tail (list :tail tail))))
                classes))))
    (nreverse classes)))

;;;; Twins: one buffer per display class

(defconst drgnx-view-env--twin-locals
  '(drgnx-view-patch-id-prop drgnx-view-nav-faces drgnx-view-nav-through-faces drgnx-view-nav-notice-method drgnx-view-nav-list
                             drgnx-view-nav-paged-functions)
  "The view buffer's locals a twin takes as they are when it is made: how its keys and classes read the model.")

(defun drgnx-view-env--twin-copy (from prefixes)
  "Copy FROM's buffer-local variables whose names start with one of PREFIXES into the current buffer.
Not those holding a marker or an overlay (FROM's own text; tables and lists are shared, read) and those the current
buffer has as its own \(`drgnx-view-patch...')."
  (dolist (b (buffer-local-variables from))
    (let ((sym (car-safe b)) (v (cdr-safe b)))
      (when (and sym (symbolp sym) (cl-some (lambda (p) (string-prefix-p p (symbol-name sym))) prefixes)
                 (not (or (markerp v) (overlayp v)
                          (and (consp v) (or (markerp (car v)) (overlayp (car v)))))))
        (set (make-local-variable sym) v)))))

(defun drgnx-view-env--twin-sync ()
  "`pre-command-hook' of a twin: the view buffer's state its commands read, as it is now."
  (when (and drgnx-view-env--twin-prefix (buffer-live-p drgnx-view-patch-twin-of))
    (drgnx-view-env--twin-copy drgnx-view-patch-twin-of drgnx-view-env--twin-prefix)))

(defun drgnx-view-env-twin (class prefixes &optional setup)
  "A twin of the current buffer, a hub-fed view's, for display CLASS (what a `drgnx-view-patch-twin-function' returns):
a new buffer in the same major mode, the view's nav locals (`drgnx-view-env--twin-locals') and its locals whose names
start with one of PREFIXES (a module's state, read again before each command in the twin), attached to (view, CLASS),
with the view buffer's handlers after a draw, its rows held where the view buffer's are (Sjá or Lisp); SETUP then
runs in it (a module removes what its mode added that only the view's buffer may do: a kill hook that ends the hub's
view).  Nothing is subscribed: the hub sends every class its env named."
  (let* ((from (current-buffer)) (mode major-mode) (view (drgnx-view-patch-view drgnx-view-patch))
         (sja (drgnx-view-patch-sja drgnx-view-patch))
         (patched (and (local-variable-p 'drgnx-view-patch-patched-functions)
                       drgnx-view-patch-patched-functions))
         (locals (mapcar (lambda (v) (cons v (and (boundp v) (symbol-value v)))) drgnx-view-env--twin-locals)))
    (with-current-buffer (generate-new-buffer (format "%s <%s>" (buffer-name from) class))
      (funcall mode)
      (setq-local drgnx-view-patch-twin-of from drgnx-view-env--twin-prefix prefixes)
      (dolist (l locals) (set (make-local-variable (car l)) (cdr l)))
      (drgnx-view-env--twin-copy from prefixes)
      (drgnx-view-patch-attach view class :sja (and sja t))     ; held where the view's own buffer holds its rows
      (dolist (f patched) (unless (eq f t) (add-hook 'drgnx-view-patch-patched-functions f nil t)))
      (add-hook 'pre-command-hook #'drgnx-view-env--twin-sync nil t)
      (when setup (funcall setup))
      (current-buffer))))

;;;; Sending

(defun drgnx-view-env--send (method params)
  "METHOD with PARAMS on this Emacs's subscribed connection, the one the view's patches come back on; nil while it is
down (the reconnect sends again)."
  (when (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
    ;; lists go out as arrays, and nil as null: an empty list must be an empty array
    (let ((p (copy-sequence params)))
      (dolist (k '(:fonts :palette :tty_widths :glyphs :faces :measured))
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
  (let* ((live nil) (buffer (car (gethash view drgnx-view-env--views))) (wins (drgnx-view-env--window-classes view))
         (envs (drgnx-view-env--envs view wins)))
    ;; a view with twins: each class's windows show its own buffer, made before that class's env goes out
    (when (and wins (not (gethash view drgnx-view-env--headless))
               (with-current-buffer buffer (bound-and-true-p drgnx-view-patch-twin-function)))
      (drgnx-view-env--route view wins))
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
                   (append params (list :epoch epoch) (and (null old) (list :attach t))   ; a new buffer: the hub starts the pair over
                           ;; the buffer holds its rows in Sjá: the hub sends them on the raw `view-model' line
                           (and (fboundp 'drgnx-view-sja-held-p) (drgnx-view-sja-held-p view (car c))
                                (list :rows_in_sja t))))
          ;; the inserter holds patches of an older epoch from now on
          (when (fboundp 'drgnx-view-patch-env-sent) (drgnx-view-patch-env-sent view (car c) epoch (null old))))))
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

(defun drgnx-view-env-look-changed ()
  "The fonts, the scale or the density changed outside a theme (the UI scale): one env per (view, class) whose look
changed."
  (drgnx-view-env--update-all))

(defun drgnx-view-env--size-changed (&optional _frame)
  "A window's size or a frame's windows changed: the width, once Emacs is idle (never inside a follow)."
  (drgnx-timer-debounce 'drgnx-view-env drgnx-view-env-delay #'drgnx-view-env--update-all :idle t :owner :core))

(defun drgnx-view-env--send-unsent ()
  "The env of each view a window now shows that the hub has no env for (a view opened by a command, or shown again
after no window showed it): the hub builds nothing for a view until it hears where it shows."
  (maphash (lambda (view v)
             (when (and (buffer-live-p (car v)) (not (drgnx-view-env-classes view))
                        (drgnx-view-env--window-classes view))
               (drgnx-view-env-update view)))
           (copy-hash-table drgnx-view-env--views)))

(defun drgnx-view-env--buffer-changed (&optional frame)
  "A window shows another buffer: a view now shown with no env sent gets it here, as redisplay runs this hook after
the command, not once Emacs is idle (a command that opens a view and waits for its rows never idles; no timer, so
nothing runs inside a follow); the widths as on a resize."
  (drgnx-view-env--send-unsent)
  (drgnx-view-env--size-changed frame))

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

(defun drgnx-view-env--frame (buffer)
  "The frame BUFFER draws on: a window's that shows it, else the selected one.  Faces' fonts are per frame (a frame of
another scale or default font draws the same buffer in another font), so BUFFER's text is measured there."
  (let ((w (get-buffer-window buffer t))) (if w (window-frame w) (selected-frame))))

(defun drgnx-view-env--on-frame (frame fn)
  "FN called with FRAME selected (a face's font is per frame), every buffer's point kept: selecting another frame
selects its selected window, which puts that window's buffer's point at the window's (a scan of a view's rows that
asks how a face draws would start over)."
  (if (eq frame (selected-frame)) (funcall fn)
    (with-current-buffer (window-buffer (frame-selected-window frame))
      (save-excursion (with-selected-frame frame (funcall fn))))))

(defun drgnx-view-env--measure (buffer face char)
  "CHAR's advance in px in FACE, measured in BUFFER (with its face remaps: the agent panel's `default' is
`drgnx-ui-text') on its frame (`drgnx-view-env--frame'), without FACE's box: the hub adds its ends once per run (the
face's :pad, `drgnx-view-env-face')."
  (drgnx-view-env--on-frame (drgnx-view-env--frame buffer)
                            (lambda () (string-pixel-width (propertize (string char) 'face (list '(:box nil) face))
                                                           buffer))))

(defconst drgnx-view-env--weights
  '((thin . 100) (ultra-light . 200) (extra-light . 200) (light . 300) (semi-light . 350) (demi-light . 350)
    (normal . 400) (regular . 400) (book . 400) (medium . 500) (semi-bold . 600) (demi-bold . 600) (bold . 700)
    (extra-bold . 800) (ultra-bold . 800) (heavy . 900) (black . 900) (ultra-heavy . 900))
  "A face's `:weight' as a font's `wght' axis value (a variable font draws its weights from one file).")

(defconst drgnx-view-env--probe "Hamburgefonstiv 0123456789 WMmw.,"
  "The text a face's drawn width is compared on with each role's (`drgnx-view-env-face').")

(defun drgnx-view-env-face (face-name buffer)
  "How the face FACE-NAME (a string the hub's rows name) draws in BUFFER, a hub-fed view's, on the frame of a window
that shows it: a plist for `view/glyphs' faces, :role the role whose font it is (`drgnx-view-env-roles', read in
BUFFER as the env's are: the role whose face draws `drgnx-view-env--probe' as wide in BUFFER, else whose font has
the same name), else FACE-NAME itself with its font's :file :px :avg and :wght; :pad its box's ends.  A
name that is no face, or a terminal, draws in `ui'."
  (let* ((face (intern-soft face-name))
         (window (or (get-buffer-window buffer t) (selected-window)))
         (frame (window-frame window)))
    (if (not (and face (facep face) (display-graphic-p frame)))
        (list :face face-name :role "ui")
      (with-current-buffer buffer
        (let* ((factor (drgnx-view-env--scale-factor buffer))
               ;; a face with a font of its own (`bold') takes its family from the remapped `default' too
               (mine (or (drgnx-view-env--drawn-font face buffer window) (drgnx-view-env--font face frame factor)))
               ;; drawn in BUFFER, FACE merges over its remapped `default' (the agent panel's `drgnx-ui-text'), which
               ;; `face-font' does not see: a face that sets only colours draws in the buffer's `default', not the
               ;; frame's.  A role whose face draws a probe as wide (FACE's box left out) is FACE's role.
               (probe (lambda (f) (drgnx-view-env--on-frame
                                   frame (lambda () (string-pixel-width (propertize drgnx-view-env--probe 'face f)
                                                                        buffer)))))
               (drawn (funcall probe (list '(:box nil) face)))
               ;; the box's ends as drawn (a negative line width is drawn inside the text; a scaled frame scales it)
               (pad (max 0 (/ (- (funcall probe face) drawn) 2.0)))
               (role (or (cl-some (lambda (r) (and (= drawn (funcall probe (cdr r))) (symbol-name (car r))))
                                  drgnx-view-env-roles)
                         (and mine (cl-some (lambda (r)
                                              (let ((f (drgnx-view-env--font (cdr r) frame factor)))
                                                (and f (equal (car (last f)) (car (last mine)))
                                                     (symbol-name (car r)))))
                                            drgnx-view-env-roles)))))
          (cond ((or role (null mine)) (list :face face-name :role (or role "ui") :pad pad))
                (t (list :face face-name :role face-name :pad pad :file (nth 0 mine) :index (nth 1 mine)
                         :px (nth 2 mine) :avg (nth 5 mine)
                         :wght (alist-get (face-attribute face :weight frame t) drgnx-view-env--weights 400)))))))))

(defun drgnx-view-env-event (event data)
  "A `drgnx-hub-event-functions' handler: `view-glyphs' asks for advances, answered with `view/glyphs' from the
cache, each (font, char) measured once, and how the faces it names draw (`drgnx-view-env-face'), read in the
buffer of the asked display class."
  (when (equal event "view-glyphs")
    (let* ((view (plist-get data :view)) (buffer (car (gethash view drgnx-view-env--views))) (out nil)
           (class-buffer (or (cdr (assoc (plist-get data :class) (drgnx-view-env--twins view))) buffer)))
      (unless (buffer-live-p class-buffer) (setq class-buffer buffer))
      (when (buffer-live-p buffer)
        (dolist (a (plist-get data :ask))
          (let* ((role (nth 0 a)) (char (string-to-char (nth 1 a)))
                 ;; a role of a face's own is that face
                 (face (or (alist-get (intern-soft role) drgnx-view-env-roles)
                           (let ((f (intern-soft role))) (and f (facep f) f))
                           'default))
                 ;; the font the face resolves to in the class's buffer (its remaps: the agent panel's `default' is
                 ;; `drgnx-ui-text', the Flow's the code font) on its frame, which is what the cache is keyed by
                 (font (or (ignore-errors (with-current-buffer class-buffer
                                            (face-font face (drgnx-view-env--frame class-buffer))))
                           (symbol-name face)))
                 ;; with the buffer's remaps: `face-font' names the same font under a `text-scale' (a :height remap)
                 (key (cons (cons font (buffer-local-value 'face-remapping-alist class-buffer)) char))
                 (px (or (gethash key drgnx-view-env--glyphs)
                         (progn (when (>= (hash-table-count drgnx-view-env--glyphs) drgnx-view-env-glyph-cache-max)
                                  (clrhash drgnx-view-env--glyphs))
                                (puthash key (drgnx-view-env--measure class-buffer face char)
                                         drgnx-view-env--glyphs)))))
            (push (list role (nth 1 a) px) out)))
        (funcall drgnx-view-env-send-function "view/glyphs"
                 (list :view view :class (plist-get data :class) :glyphs (nreverse out)
                       :faces (mapcar (lambda (f) (drgnx-view-env-face f class-buffer)) (plist-get data :faces))))
        (when-let* ((measure (plist-get data :measure)))
          (funcall drgnx-view-env-send-function "view/measured"
                   (list :view view :class (plist-get data :class)
                         :measured (mapcar (lambda (m)
                                             (vector (nth 0 m) (nth 1 m)
                                                     (drgnx-view-env-measure (nth 1 m) (nth 2 m) class-buffer)))
                                           measure))))))))

(defun drgnx-view-env-measure (text runs buffer)
  "TEXT's width in px as BUFFER draws it in RUNS, ([START END FACE] ...) over its chars, an earlier run above a later
one (the hub's `view-glyphs' `measure': a row segment whose sum came too close to its end to decide, or a cluster of
several chars), on BUFFER's frame (`drgnx-view-env--frame')."
  (let ((s (copy-sequence text)))
    (dolist (r (reverse runs))
      (let ((face (intern-soft (nth 2 r))))
        (when (and face (<= 0 (nth 0 r) (nth 1 r) (length s)))
          (add-face-text-property (nth 0 r) (nth 1 r) face nil s))))
    (drgnx-view-env--on-frame (drgnx-view-env--frame buffer) (lambda () (string-pixel-width s buffer)))))

(defun drgnx-view-env--hook (on)
  "Add the global hooks (ON) or remove them."
  (let ((f (if on #'add-hook #'remove-hook)))
    (funcall f 'enable-theme-functions #'drgnx-view-env--theme-changed)
    (funcall f 'disable-theme-functions #'drgnx-view-env--theme-changed)
    (funcall f 'window-size-change-functions #'drgnx-view-env--size-changed)
    (funcall f 'window-buffer-change-functions #'drgnx-view-env--buffer-changed)
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
    (dolist (tw (drgnx-view-env--twins view)) (kill-buffer (cdr tw)))
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
