;;; drgnx-debug-gutter.el --- The breakpoint column: glyphs in the left margin, kept in the hub's store -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The editor's half of breakpoints (docs/develop/debugging.md, "The breakpoint column"): a column in the left margin,
;; claimed through `drgnx-margins' (order 0: outermost), with one glyph per breakpoint.  The hub holds the breakpoints
;; (`debug/breakpoints', one store per project); this file asks it to change them by id and draws what it says.
;;
;; - Fill means enabled and colour means bound: red is verified, grey not bound yet, a hollow ring disabled, a dot with
;;   bars a condition or hit count, a diamond a logpoint (the mockup's legend, docs/specs/…/debugging.html).  Graphical
;;   frames draw SVGs at the frame's scale, terminals a character (ASCII where the terminal is not UTF-8).
;; - Each mark is an overlay over its line, so it moves with the text.  A moved mark is a draft: the store keeps the
;;   saved line, and the moves (and the marks whose line was deleted) are sent on save.  A revert puts the saved lines
;;   back.  Where the adapter bound a breakpoint to another line, the mark sits on that line.
;; - The column shows per `drgnx-debug-gutter-show': `auto' while the file has breakpoints or a session runs in its
;;   project, `always' in every file buffer of the mode, `never' not at all.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-margins)
(require 'drgnx-pixels)
(require 'drgnx-ui-kit)
(require 'drgnx-faces)
(require 'drgnx-color)
(declare-function drgnx-hub-call "drgnx-hub-client")
(require 'drgnx-debug-launch (expand-file-name "drgnx-debug-launch" (file-name-directory (macroexp-file-name))))
(defvar drgnx-hub-event-functions)
(defvar drgnx-debug-gutter-mode)

(defcustom drgnx-debug-gutter-show 'auto
  "When the breakpoint column shows: `auto' (while the file has breakpoints or a debug session runs in its project),
`always' or `never'."
  :type '(choice (const auto) (const always) (const never)) :group 'drgnx)

(defface drgnx-debug-breakpoint '((t :inherit drgnx-status-fail))
  "A breakpoint's glyph (its foreground)." :group 'drgnx)
(defface drgnx-debug-unverified '((t :inherit drgnx-text-disabled))
  "A breakpoint no adapter has bound yet." :group 'drgnx)
(defface drgnx-debug-hover '((t :inherit drgnx-debug-breakpoint))
  "The faint dot under the mouse in the column (drawn at 38 %)." :group 'drgnx)
(defface drgnx-debug-stopped '((t :inherit drgnx-status-warn))
  "The top frame's arrow." :group 'drgnx)
(defface drgnx-debug-frame '((t :inherit drgnx-status-ok))
  "A selected caller frame's arrow." :group 'drgnx)
(defface drgnx-debug-exception '((t :inherit drgnx-status-fail))
  "The arrow of a stop on an exception." :group 'drgnx)
(defface drgnx-debug-agent-ring '((t :inherit drgnx-agent-1))
  "The ring around an agent's breakpoint or probe, and the agent's name in the Investigation." :group 'drgnx)

(defface drgnx-debug-stopped-line '((t :extend t))
  "The top frame's line: a band in the warn tint (the theme sets it)." :group 'drgnx)
(defface drgnx-debug-frame-line '((t :extend t))
  "A selected caller frame's line: a band in the ok tint (the theme sets it)." :group 'drgnx)
(defface drgnx-debug-exception-line '((t :extend t))
  "The line of a stop on an exception: a band in the error tint (the theme sets it)." :group 'drgnx)
(defface drgnx-debug-exception-card '((t :inherit (drgnx-ui-text drgnx-surface-raised)))
  "The exception card under the stopped line: the raised surface, ringed in the error colour (the theme)."
  :group 'drgnx)
(defface drgnx-debug-exception-title '((t :inherit (error bold)))
  "The exception card's type." :group 'drgnx)
(defface drgnx-debug-exception-hint '((t :inherit (drgnx-text-subtle drgnx-ui-caption)))
  "The exception card's last row: what the keys do." :group 'drgnx)

(defface drgnx-debug-breakpoint-inline '((t :inherit drgnx-debug-breakpoint))
  "An inline breakpoint's dot, before its column's character." :group 'drgnx)
(defface drgnx-debug-breakpoint-candidate '((t :inherit drgnx-text-disabled))
  "A faint dot where an inline breakpoint can go, while stopped." :group 'drgnx)

(defcustom drgnx-debug-inline-breakpoint-candidates t
  "Whether, while this project's session is stopped, each line with a breakpoint shows faint dots where the adapter
can also stop (its `breakpointLocations', when there are two or more); a click on one adds an inline breakpoint there
\(VS Code's `debug.showInlineBreakpointCandidates')."
  :type 'boolean :group 'drgnx)

(defcustom drgnx-debug-focus-on-stop nil
  "Whether a stop raises the Emacs frame that shows it (VS Code's `debug.focusWindowOnBreak'; off here)."
  :type 'boolean :group 'drgnx)

(defconst drgnx-debug-gutter--width 18 "The column's width in logical pixels (the glyphs are 16).")

(defvar-local drgnx-debug-gutter--bps nil "The file's breakpoints as the hub last said: plists.")
(defvar-local drgnx-debug-gutter--version 0 "The version of `drgnx-debug-gutter--bps'.")
(defvar-local drgnx-debug-gutter--overlays nil "(ID . OVERLAY) of each mark.")
(defvar-local drgnx-debug-gutter--candidates nil "The candidate dots' overlays.")
(defvar-local drgnx-debug-gutter--candidates-gen 0 "Bumped at each refresh: an older answer is dropped.")
(defvar drgnx-debug-gutter--inline-map)
(defvar drgnx-debug-gutter--sessions nil "The debug sessions as `debug-state' last said: plists with :id and :root.")

;;;; Glyphs

(defun drgnx-debug-gutter--kind (bp)
  "BP's glyph: `off' (disabled), `log', `unverified', `cond' (a condition or hit count) or `bp'."
  (cond ((not (plist-get bp :enabled)) 'off)
        ((plist-get bp :log) 'log)
        ((not (plist-get bp :verified)) 'unverified)
        ((or (plist-get bp :condition) (plist-get bp :hit)) 'cond)
        (t 'bp)))

(defun drgnx-debug-gutter--face (kind)
  "The face KIND's glyph is drawn in."
  (pcase kind
    ('unverified 'drgnx-debug-unverified) ('hover 'drgnx-debug-hover)
    ((or 'stop 'stop-bp) 'drgnx-debug-stopped) ('frame 'drgnx-debug-frame) ('exception 'drgnx-debug-exception)
    (_ 'drgnx-debug-breakpoint)))

(defconst drgnx-debug-gutter--chars
  '((bp "●" . "B") (unverified "●" . "B") (cond "◐" . "C") (log "◆" . "L") (off "○" . "o") (hover "○" . "o")
    (stop "▶" . ">") (stop-bp "▶" . ">") (frame "▷" . "-") (exception "▶" . "!"))
  "KIND → (UNICODE . ASCII): the column's character in a terminal.")

(defun drgnx-debug-gutter--char (kind ascii)
  "KIND's terminal character, its ASCII form when ASCII."
  (let ((c (alist-get kind drgnx-debug-gutter--chars)))
    (if ascii (cdr c) (car c))))

(defun drgnx-debug-gutter--svg (kind h w bp unv stop frame editor &optional pad ring)
  "KIND's glyph as SVG text, H by W pixels, its 16-unit drawing centred; colours BP (the breakpoint), UNV (not bound),
STOP (the top frame), FRAME (a caller frame) and EDITOR (the bars and marks cut into a glyph).  PAD pixels of nothing
come first (the margin's columns outside the claim: a margin string's image cannot follow other text).  RING, a
colour, rings the glyph (an agent's mark)."
  (let* ((pad (or pad 0)) (vw (/ (* 16.0 (+ w pad)) h)) (x0 (- (/ (- 16 (/ (* 16.0 w) h)) 2) (/ (* 16.0 pad) h)))
         (arrow "M1.5 3.2h7.6L14.6 8l-5.5 4.8H1.5Z")
         (body
          (pcase kind
            ('bp (format "<circle cx='8' cy='8' r='5' fill='%s'/>" bp))
            ('unverified (format "<circle cx='8' cy='8' r='5' fill='%s'/>" unv))
            ('hover (format "<circle cx='8' cy='8' r='5' fill='%s' opacity='.38'/>" bp))
            ('cond (format "<circle cx='8' cy='8' r='5' fill='%s'/><path d='M5.6 6.8h4.8M5.6 9.2h4.8' stroke='%s' stroke-width='1.3' stroke-linecap='round'/>" bp editor))
            ('log (format "<path d='M8 2.6 13.4 8 8 13.4 2.6 8Z' fill='%s'/>" bp))
            ('off (format "<circle cx='8' cy='8' r='4.4' fill='none' stroke='%s' stroke-width='1.4'/>" bp))
            ('stop (format "<path d='%s' fill='%s'/>" arrow stop))
            ('stop-bp (format "<path d='%s' fill='%s'/><circle cx='6.6' cy='8' r='3' fill='%s'/>" arrow stop bp))
            ('frame (format "<path d='M2.2 3.9h6.6L13.6 8l-4.8 4.1H2.2Z' fill='none' stroke='%s' stroke-width='1.4' stroke-linejoin='round'/>" frame))
            ('exception (format "<path d='%s' fill='%s'/><path d='M6.8 5.4v3.2M6.8 10.6v.1' stroke='%s' stroke-width='1.5' stroke-linecap='round'/>" arrow bp editor)))))
    (format "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='%.3f 0 %.3f 16'>%s%s</svg>"
            (+ w pad) h x0 vw body
            (if ring (format "<circle cx='8' cy='8' r='7.1' fill='none' stroke='%s' stroke-width='1.2'/>" ring) ""))))

(defvar drgnx-debug-gutter--images (make-hash-table :test 'equal)
  "(KIND W H COLOURS) → image.  Ten kinds at a few sizes per theme; emptied past 64 entries (a theme change makes new
keys).")

(defun drgnx-debug-gutter--colour (face &optional background)
  "FACE's foreground (BACKGROUND: background) as #rrggbb, or `currentColor' (the text's colour) when the theme leaves it
unspecified."
  (let ((rgb (drgnx-color-rgb (if background (face-background face nil t) (face-foreground face nil t)))))
    (if rgb (drgnx-color-hex rgb) "currentColor")))

(defun drgnx-debug-gutter--columns ()
  "The column's width in the frame's columns: 18 px rounded up to whole characters (one in a terminal)."
  (if (display-graphic-p)
      (max 1 (ceiling (drgnx-px drgnx-debug-gutter--width) (frame-char-width)))
    1))

(defun drgnx-debug-gutter--image (kind &optional pad agent)
  "KIND's glyph image at this frame's size and the theme's colours, after PAD columns of nothing; ringed when AGENT
(an agent's session) set the mark."
  (let* ((w (* (drgnx-debug-gutter--columns) (frame-char-width)))
         (pad (* (or pad 0) (frame-char-width)))
         (h (min (drgnx-px 16) (frame-char-height)))
         (colours (list (drgnx-debug-gutter--colour 'drgnx-debug-breakpoint)
                        (drgnx-debug-gutter--colour 'drgnx-debug-unverified)
                        (drgnx-debug-gutter--colour 'drgnx-debug-stopped)
                        (drgnx-debug-gutter--colour 'drgnx-debug-frame)
                        (drgnx-debug-gutter--colour 'default t)))
         (ring (and agent (drgnx-debug-gutter--colour 'drgnx-debug-agent-ring)))
         (key (list kind w h pad colours ring)))
    (or (gethash key drgnx-debug-gutter--images)
        (progn
          (when (> (hash-table-count drgnx-debug-gutter--images) 64) (clrhash drgnx-debug-gutter--images))
          (puthash key (create-image (apply #'drgnx-debug-gutter--svg kind h w (append colours (list pad ring))) 'svg t
                                     :ascent 'center :scale 1)
                   drgnx-debug-gutter--images)))))

(defun drgnx-debug-gutter--ring-char (char agent)
  "CHAR, a mark's terminal character, in the agent ring's face when AGENT (an agent's session) set the mark."
  (if agent (propertize char 'face 'drgnx-debug-agent-ring) char))

(defun drgnx-debug-gutter--margin-string (kind help &optional agent)
  "The `before-string' of a mark of KIND, HELP its tooltip: on a graphical frame with SVG an image (the pad of the
column's claim drawn into it), else the pad and a character in KIND's face.  An AGENT's mark is ringed (a terminal: the
character wears the ring's face)."
  (propertize " " 'display
              (list '(margin left-margin)
                    (if (and (display-graphic-p) (image-type-available-p 'svg))
                        (drgnx-debug-gutter--image kind (drgnx-margins-offset 'debug) agent)
                      (concat (drgnx-margins-pad 'debug)
                              (drgnx-debug-gutter--ring-char
                               (propertize (drgnx-debug-gutter--char kind (drgnx-ui-ascii-frame-p))
                                           'face (drgnx-debug-gutter--face kind))
                               agent))))
              'help-echo help))

;;;; The hover dot

;; A faint dot under the pointer on a line without a mark, with no Lisp on mouse motion: each shown line carries a
;; margin string, a dot in the margin's own background with a `mouse-face' that shows it (Nidhogg lights a margin
;; string's mouse face).  The strings sit on a pool of overlays per window (the overlay's `window', so a buffer in two
;; windows is not doubled), laid over the window's lines when its start, height or the text changed.

(defvar-local drgnx-debug-gutter--pool nil
  "(WINDOW KEY . OVERLAYS): each window's hover dots and what they were laid out for (KEY: a vector of the window's
start and height, the text's tick, the marks' version and count and the string, compared without consing).")
(defvar-local drgnx-debug-gutter--hover-cache nil
  "[THEMES REMAPS OFFSET STRING]: the last hover string, for these `custom-enabled-themes', `face-remapping-alist' and
pad (the colours change only with a theme or a remap).")

(defun drgnx-debug-gutter--hover-p (window)
  "Whether WINDOW's frame lights a margin string's `mouse-face' (Nidhogg's feature, graphical frames)."
  (and (featurep 'glitnir-margin-mouse-face) (display-graphic-p (window-frame window))))

(defun drgnx-debug-gutter--margin-background ()
  "The background the left margin draws in here: `default' as this buffer remaps it (`face-remapping-alist'), else the
frame's."
  (let ((specs (alist-get 'default face-remapping-alist)))
    (when (keywordp (car-safe specs)) (setq specs (list specs)))
    (or (seq-some (lambda (s)
                    (let ((b (cond ((and (consp s) (keywordp (car s))) (plist-get s :background))
                                   ((and (symbolp s) (not (eq s 'default)) (facep s))
                                    (face-attribute s :background nil t)))))
                      (and (stringp b) b)))
                  specs)
        (face-background 'default nil t))))

(defun drgnx-debug-gutter--hover-colours ()
  "(BACKGROUND . DOT) as #rrggbb: the margin's background and the hover face's colour, or nil where either is unknown."
  (let ((bg (drgnx-color-rgb (drgnx-debug-gutter--margin-background)))
        (fg (drgnx-color-rgb (face-foreground 'drgnx-debug-hover nil t))))
    (and bg fg (cons (drgnx-color-hex bg) (drgnx-color-hex fg)))))

(defun drgnx-debug-gutter--hover-string (bg fg)
  "The hover dot's margin string: after the claim's pad, a dot in BG (the margin's background: unseen) whose
`mouse-face' is FG at 38 % over BG.  The dot sits in the column's middle character (a margin string draws no pixel
space: the glyphs' images are centred in the whole column, so an odd column count lines them up).  The dot is in the
UI font (`drgnx-ui-text'): its ● is the mockup's 10 px at 13 px where the code font's is 8, and its line is no
taller."
  (propertize " " 'display
              (list '(margin left-margin)
                    (concat (drgnx-margins-pad 'debug)
                            (make-string (/ (1- (drgnx-debug-gutter--columns)) 2) ?\s)
                            (propertize "●" 'face (list :inherit 'drgnx-ui-text :foreground bg)
                                        'mouse-face (list :inherit 'drgnx-ui-text
                                                          :foreground (drgnx-color-over fg bg 0.38))
                                        'help-echo "Click to add a breakpoint")))))

(defun drgnx-debug-gutter--hover-string-now ()
  "The hover string for this buffer's pad and the theme's colours, or nil without colours.  Cached on the themes, the
remaps and the pad by `eq', so a redisplay that changes none of them reads no face and conses nothing."
  (let ((c drgnx-debug-gutter--hover-cache) (offset (drgnx-margins-offset 'debug)))
    (if (and c (eq (aref c 0) custom-enabled-themes) (eq (aref c 1) face-remapping-alist) (eql (aref c 2) offset))
        (aref c 3)
      (let ((colours (drgnx-debug-gutter--hover-colours)))
        (aref (setq drgnx-debug-gutter--hover-cache
                    (vector custom-enabled-themes face-remapping-alist offset
                            (and colours (drgnx-debug-gutter--hover-string (car colours) (cdr colours)))))
              3)))))

(defun drgnx-debug-gutter--pool-clear (&optional window)
  "Take WINDOW's hover dots out (all windows' when nil)."
  (dolist (cell drgnx-debug-gutter--pool)
    (when (or (null window) (eq (car cell) window))
      (drgnx-timer-cancel (cons 'debug-hover (car cell)))
      (mapc #'delete-overlay (cddr cell))))
  (setq drgnx-debug-gutter--pool
        (and window (seq-remove (lambda (cell) (eq (car cell) window)) drgnx-debug-gutter--pool))))

(defun drgnx-debug-gutter--pool-key-p (key window string)
  "Whether KEY (a pool's vector) still describes WINDOW and STRING."
  (and key
       (eql (aref key 0) (window-start window)) (eql (aref key 1) (window-body-height window))
       (eql (aref key 2) (buffer-chars-modified-tick)) (eql (aref key 3) drgnx-debug-gutter--version)
       (eql (aref key 4) (length drgnx-debug-gutter--overlays)) (eq (aref key 5) string)))

(defun drgnx-debug-gutter--pool-lay (window string old)
  "Put STRING on each line WINDOW shows from its start, visible and without a mark, as many as its body is high:
reuse the overlays OLD, make more as needed, delete those left.  The new overlays, in order."
  (let ((n (window-body-height window)) new)
    (save-excursion
      (goto-char (window-start window))
      (while (> n 0)
        (let ((bol (line-beginning-position)))
          (unless (or (invisible-p bol) (get-char-property bol 'drgnx-debug-bp))
            (let ((o (or (pop old)
                         (let ((o (make-overlay 1 1 nil t nil)))
                           (overlay-put o 'drgnx-debug-hover window)
                           (overlay-put o 'window window)
                           o))))
              (move-overlay o bol bol)
              (unless (eq (overlay-get o 'before-string) string) (overlay-put o 'before-string string))
              (push o new)))
          (setq n (1- n))
          ;; the next visible line: `forward-line' then past any folded text
          (if (or (eobp) (/= (forward-line 1) 0))
              (setq n 0)
            (while (and (not (eobp)) (invisible-p (point)))
              (goto-char (next-single-char-property-change (point) 'invisible)))))))
    (mapc #'delete-overlay old)
    (nreverse new)))

(defconst drgnx-debug-gutter--settle 0.1
  "Seconds a scrolled window rests before its hover dots come back on the lines it shows.  The scroll's own frames
draw none: fifty margin strings cost a full redraw about a millisecond (perf rows `debug-gutter-scroll' and
`debug-gutter-baseline'), and at rest the dots are unseen anyway.")

(defun drgnx-debug-gutter--pool-moved-p (key window string)
  "Whether KEY differs from WINDOW and STRING only in WINDOW's start or height (it scrolled or was resized)."
  (and key
       (eql (aref key 2) (buffer-chars-modified-tick)) (eql (aref key 3) drgnx-debug-gutter--version)
       (eql (aref key 4) (length drgnx-debug-gutter--overlays)) (eq (aref key 5) string)
       (not (and (eql (aref key 0) (window-start window)) (eql (aref key 1) (window-body-height window))))))

(defun drgnx-debug-gutter--pool-settle (window buffer)
  "The settle timer: lay WINDOW's dots in BUFFER now."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (drgnx-debug-gutter--pool-update window t))))

(defun drgnx-debug-gutter--pool-update (window &optional now)
  "`pre-redisplay-functions' and `window-scroll-functions': lay WINDOW's hover dots over its shown lines when its start,
height, the text or the marks changed; take the dots of windows that no longer show the buffer out.  A window that
only scrolled gets them once it has rested `drgnx-debug-gutter--settle' seconds, unless NOW."
  (dolist (cell drgnx-debug-gutter--pool)
    (unless (and (window-live-p (car cell)) (eq (window-buffer (car cell)) (current-buffer)))
      (drgnx-debug-gutter--pool-clear (car cell))))
  (when (and (window-live-p window) (eq (window-buffer window) (current-buffer)))
    (let ((string (and drgnx-debug-gutter-mode (drgnx-debug-gutter--hover-p window)
                       (drgnx-margins-offset 'debug)
                       (drgnx-debug-gutter--hover-string-now))))
      (if (not string)
          (when (assq window drgnx-debug-gutter--pool) (drgnx-debug-gutter--pool-clear window))
        (let ((cell (assq window drgnx-debug-gutter--pool)))
          (cond
           ((and cell (drgnx-debug-gutter--pool-key-p (cadr cell) window string)))
           ((and cell (not now) (drgnx-debug-gutter--pool-moved-p (cadr cell) window string))
            ;; the dots it showed go (they would sit on the wrong lines and cost each frame), and the key no
            ;; longer matches any start, so a window scrolled back still waits to settle
            (when (cddr cell)
              (mapc #'delete-overlay (cddr cell))
              (setcdr (cdr cell) nil)
              (aset (cadr cell) 0 nil))
            (drgnx-timer-debounce (cons 'debug-hover window) drgnx-debug-gutter--settle
                                  #'drgnx-debug-gutter--pool-settle :args (list window (current-buffer))
                                  :owner (current-buffer)))
           (t
            (let ((overlays (drgnx-debug-gutter--pool-lay window string (cddr cell)))
                  (key (vector (window-start window) (window-body-height window) (buffer-chars-modified-tick)
                               drgnx-debug-gutter--version (length drgnx-debug-gutter--overlays) string)))
              (if cell
                  (setcdr cell (cons key overlays))
                (push (cons window (cons key overlays)) drgnx-debug-gutter--pool))))))))))

(defun drgnx-debug-gutter--pool-scrolled (window _start)
  "`window-scroll-functions': WINDOW scrolled; its dots follow."
  (drgnx-debug-gutter--pool-update window))

;;;; The column's claim

(defun drgnx-debug-gutter--wanted-p ()
  "Whether this buffer shows the column now."
  (pcase drgnx-debug-gutter-show
    ('never nil)
    ('always t)
    (_ (or drgnx-debug-gutter--bps
           (and (drgnx-debug-gutter--session) t)))))

(defun drgnx-debug-gutter--session ()
  "The id of a debug session in this buffer's project, or nil."
  (when drgnx-debug-gutter--sessions
    (let ((root (drgnx-debug-launch-root)))
      (plist-get (seq-find (lambda (s) (equal (plist-get s :root) root)) drgnx-debug-gutter--sessions) :id))))

(defun drgnx-debug-gutter--claim ()
  "Claim the column (or give it back) as `drgnx-debug-gutter-show' says."
  (drgnx-margins-claim 'debug (and drgnx-debug-gutter-mode (drgnx-debug-gutter--wanted-p) (drgnx-debug-gutter--columns))
                       :order 0))

;;;; Marks

(defun drgnx-debug-gutter--line-bounds (line)
  "(BEG . END) of LINE, its newline included; the last line ends at the buffer's end.  It moves from point's line, not
the buffer's start (a click deep in a long file was 10 ms of `forward-line')."
  (save-excursion
    (forward-line (- line (line-number-at-pos)))
    (cons (point) (progn (forward-line 1) (point)))))

(defun drgnx-debug-gutter--help (bp)
  "BP's tooltip: what it is, its condition, hit count or log message, or the adapter's reason."
  (string-join
   (delq nil (list (pcase (drgnx-debug-gutter--kind bp)
                     ('off "Breakpoint (disabled)") ('log "Logpoint") ('unverified "Breakpoint (not bound yet)")
                     (_ "Breakpoint"))
                   (when-let* ((c (plist-get bp :condition))) (format "when %s" c))
                   (when-let* ((h (plist-get bp :hit))) (format "hit count %s" h))
                   (when-let* ((l (plist-get bp :log))) (format "logs %s" l))
                   (plist-get bp :message)
                   (when-let* ((a (plist-get bp :agent))) (format "set by agent %s" a))))
   " · "))

(defun drgnx-debug-gutter--place (bp)
  "Put BP's mark on its line (the adapter's line where it bound it elsewhere)."
  (let* ((line (or (plist-get bp :bound_line) (plist-get bp :line)))
         (b (drgnx-debug-gutter--line-bounds line))
         (col (plist-get bp :column))
         (o (if col
                (let ((at (drgnx-debug-gutter--column-pos (car b) col)))
                  (make-overlay at at nil nil nil))
              (make-overlay (car b) (max (cdr b) (car b)) nil t nil))))
    (if col
        (overlay-put o 'drgnx-debug-column col)
      (unless (= (car b) (cdr b)) (overlay-put o 'evaporate t)))
    (overlay-put o 'drgnx-debug-bp (plist-get bp :id))
    (overlay-put o 'drgnx-debug-drawn line)
    (push (cons (plist-get bp :id) o) drgnx-debug-gutter--overlays)
    o))

(defun drgnx-debug-gutter--dress (o bp)
  "Give mark O BP's glyph and tooltip."
  (let ((kind (drgnx-debug-gutter--kind bp)))
    (overlay-put o 'drgnx-debug-kind kind)
    (overlay-put o 'drgnx-debug-help (drgnx-debug-gutter--help bp))
    (overlay-put o 'drgnx-debug-agent (plist-get bp :agent))
    (if (overlay-get o 'drgnx-debug-column)
        (overlay-put o 'before-string
                     (propertize "●" 'face (if (eq kind 'off) 'drgnx-debug-unverified 'drgnx-debug-breakpoint-inline)
                                 'help-echo (overlay-get o 'drgnx-debug-help) 'mouse-face 'highlight 'pointer 'hand
                                 'keymap drgnx-debug-gutter--inline-map 'drgnx-debug-bp (plist-get bp :id)))
      (unless (overlay-get o 'drgnx-debug-under-stop)
        (overlay-put o 'before-string (drgnx-debug-gutter--margin-string kind (overlay-get o 'drgnx-debug-help)
                                                                         (plist-get bp :agent)))))))

(defun drgnx-debug-gutter--draw ()
  "Draw `drgnx-debug-gutter--bps': marks moved by edits stay where the text put them while the buffer has unsaved
changes (drafts); otherwise each sits on the store's line."
  (drgnx-debug-gutter--claim)
  (let ((ids (mapcar (lambda (bp) (plist-get bp :id)) drgnx-debug-gutter--bps)))
    (dolist (e drgnx-debug-gutter--overlays)
      (unless (and (memq (car e) ids) (overlay-buffer (cdr e)))
        (delete-overlay (cdr e))))
    (setq drgnx-debug-gutter--overlays
          (seq-filter (lambda (e) (overlay-buffer (cdr e))) drgnx-debug-gutter--overlays))
    (dolist (bp drgnx-debug-gutter--bps)
      (let ((o (cdr (assq (plist-get bp :id) drgnx-debug-gutter--overlays))))
        (when (and o (not (buffer-modified-p))
                   (/= (overlay-get o 'drgnx-debug-drawn) (or (plist-get bp :bound_line) (plist-get bp :line))))
          (delete-overlay o)
          (setq drgnx-debug-gutter--overlays (assq-delete-all (plist-get bp :id) drgnx-debug-gutter--overlays))
          (setq o nil))
        (drgnx-debug-gutter--dress (or o (drgnx-debug-gutter--place bp)) bp))))
  (drgnx-debug-gutter--candidates-refresh))

(defun drgnx-debug-gutter--restring (buffer)
  "`drgnx-margins-changed-functions': the column moved in BUFFER's margin; its marks take the new pad."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when drgnx-debug-gutter-mode
        (dolist (o (overlays-in (point-min) (point-max)))
          (when (and (overlay-get o 'drgnx-debug-stop) (overlay-get o 'before-string))
            (overlay-put o 'before-string (drgnx-debug-gutter--margin-string
                                           (overlay-get o 'drgnx-debug-kind)
                                           (if (eq (overlay-get o 'drgnx-debug-stop) 'top)
                                               "Paused here" "The selected frame")))))
        (dolist (e drgnx-debug-gutter--overlays)
          (when (and (overlay-buffer (cdr e)) (not (overlay-get (cdr e) 'drgnx-debug-under-stop))
                     (not (overlay-get (cdr e) 'drgnx-debug-column)))
            (overlay-put (cdr e) 'before-string
                         (drgnx-debug-gutter--margin-string (overlay-get (cdr e) 'drgnx-debug-kind)
                                                            (overlay-get (cdr e) 'drgnx-debug-help)
                                                            (overlay-get (cdr e) 'drgnx-debug-agent)))))))))

(defun drgnx-debug-gutter--clear ()
  "Take every mark out."
  (dolist (e drgnx-debug-gutter--overlays) (delete-overlay (cdr e)))
  (setq drgnx-debug-gutter--overlays nil)
  (drgnx-debug-gutter--candidates-clear))

;;;; The hub

(defun drgnx-debug-gutter--apply (view)
  "Take the hub's VIEW of this file (`debug/breakpoints' or `debug-breakpoints') and draw it."
  (when (>= (or (plist-get view :version) 0) drgnx-debug-gutter--version)
    (setq drgnx-debug-gutter--version (or (plist-get view :version) 0)
          drgnx-debug-gutter--bps (plist-get view :breakpoints))
    (drgnx-debug-gutter--draw)))

(defun drgnx-debug-gutter--ask (op)
  "Send OP (nil: only ask) for this file to the hub; draw its answer."
  (let ((buffer (current-buffer)))
    (drgnx-hub-call "debug/breakpoints"
                    (append (list :root (drgnx-debug-launch-root))
                            (if op (list :op op) (list :path buffer-file-name)))
                    (lambda (result error)
                      (when (and result (not error) (buffer-live-p buffer))
                        (with-current-buffer buffer (drgnx-debug-gutter--apply result)))))))

(defun drgnx-debug-gutter--event (event data)
  "`drgnx-hub-event-functions': a file's breakpoints changed (`debug-breakpoints'), or the sessions did."
  (pcase event
    ("debug-breakpoints"
     (when-let* ((b (get-file-buffer (plist-get data :path))))
       (with-current-buffer b
         (when drgnx-debug-gutter-mode (drgnx-debug-gutter--apply data)))))
    ("debug-state"
     (setq drgnx-debug-gutter--sessions (plist-get data :sessions))
     (dolist (b (buffer-list))
       (when (buffer-local-value 'drgnx-debug-gutter-mode b)
         (with-current-buffer b
           (drgnx-debug-gutter--claim)
           (drgnx-debug-gutter--candidates-refresh)))))))

(defun drgnx-debug-gutter--mark-at (line)
  "The id of the mark on LINE, or nil."
  (let ((b (drgnx-debug-gutter--line-bounds line)))
    (car (seq-find (lambda (e) (and (overlay-buffer (cdr e)) (not (overlay-get (cdr e) 'drgnx-debug-column))
                                    (= (overlay-start (cdr e)) (car b))))
                   drgnx-debug-gutter--overlays))))

(defun drgnx-debug-gutter-toggle (&optional line)
  "A breakpoint on LINE (default: point's), or none."
  (interactive)
  (let ((line (or line (line-number-at-pos))))
    (drgnx-debug-gutter--ask (if-let* ((id (drgnx-debug-gutter--mark-at line)))
                                 (list :op "remove" :id id)
                               (list :op "add" :path buffer-file-name :line line)))))

;;;; Inline breakpoints

(defun drgnx-debug-gutter--column-pos (bol column)
  "The position of 1-based character COLUMN on the line at BOL (its end when the line is shorter)."
  (save-excursion (goto-char bol) (min (+ bol (1- column)) (line-end-position))))

(defun drgnx-debug-inline-breakpoint ()
  "An inline breakpoint at point's column (it stops there, not at the line's first statement), or none."
  (interactive)
  (let* ((line (line-number-at-pos)) (col (1+ (- (point) (line-beginning-position))))
         (bp (seq-find (lambda (b) (and (eql (plist-get b :line) line) (eql (plist-get b :column) col)))
                       drgnx-debug-gutter--bps)))
    (drgnx-debug-gutter--ask (if bp (list :op "remove" :id (plist-get bp :id))
                               (list :op "add" :path buffer-file-name :line line :column col)))))

(defun drgnx-debug-gutter--inline-click (event)
  "Mouse EVENT on an inline breakpoint's dot: remove it; on a candidate's: add one there."
  (interactive "e")
  (let* ((posn (event-start event)) (str (posn-string posn)))
    (with-current-buffer (window-buffer (posn-window posn))
      (if-let* ((id (and str (get-text-property (cdr str) 'drgnx-debug-bp (car str)))))
          (drgnx-debug-gutter--ask (list :op "remove" :id id))
        (when-let* ((add (and str (get-text-property (cdr str) 'drgnx-debug-candidate (car str)))))
          (funcall add))))))

(defvar drgnx-debug-gutter--inline-map
  (let ((m (make-sparse-keymap)))
    (define-key m [down-mouse-1] #'ignore)
    (define-key m [mouse-1] #'drgnx-debug-gutter--inline-click)
    m)
  "The dots' mouse: a click removes an inline breakpoint, or adds one at a candidate.")

(defun drgnx-debug-gutter--stopped-session ()
  "This project's stopped session, or nil."
  (let ((root (drgnx-debug-launch-root)))
    (seq-find (lambda (s) (and (equal (plist-get s :state) "stopped") (equal (plist-get s :root) root)))
              drgnx-debug-gutter--sessions)))

(defun drgnx-debug-gutter--candidates-clear ()
  (mapc #'delete-overlay drgnx-debug-gutter--candidates)
  (setq drgnx-debug-gutter--candidates nil))

(defun drgnx-debug-gutter--candidates-refresh ()
  "Ask again where inline breakpoints can go on the lines with breakpoints, while this project's session is stopped
and `drgnx-debug-inline-breakpoint-candidates' is on; else none."
  (drgnx-debug-gutter--candidates-clear)
  (let ((gen (cl-incf drgnx-debug-gutter--candidates-gen)) (buffer (current-buffer)))
    (when-let* ((drgnx-debug-inline-breakpoint-candidates) (buffer-file-name)
                (s (drgnx-debug-gutter--stopped-session)))
      (dolist (line (delete-dups (mapcar (lambda (b) (plist-get b :line)) drgnx-debug-gutter--bps)))
        (drgnx-hub-call "debug/breakpoint-locations" (list :session (plist-get s :id) :path buffer-file-name :line line)
                        (lambda (r error)
                          (when (and r (not error) (buffer-live-p buffer))
                            (with-current-buffer buffer
                              (when (= gen drgnx-debug-gutter--candidates-gen)
                                (drgnx-debug-gutter--candidates-put line (plist-get r :locations)))))))))))

(defun drgnx-debug-gutter--candidates-put (line locations)
  "Faint dots on LINE at LOCATIONS' columns (the adapter's, two or more) that hold no inline breakpoint."
  (let ((taken (delq nil (mapcar (lambda (b) (and (eql (plist-get b :line) line) (plist-get b :column)))
                                 drgnx-debug-gutter--bps)))
        (cols (delete-dups (delq nil (mapcar (lambda (l) (and (memql (plist-get l :line) (list nil line))
                                                              (plist-get l :column)))
                                             (append locations nil)))))
        (bol (car (drgnx-debug-gutter--line-bounds line)))
        (file buffer-file-name))
    (when (cdr cols)
      (dolist (col cols)
        (unless (memql col taken)
          (let* ((at (drgnx-debug-gutter--column-pos bol col)) (o (make-overlay at at nil nil nil))
                 (add (lambda () (drgnx-debug-gutter--ask (list :op "add" :path file :line line :column col)))))
            (overlay-put o 'drgnx-debug-candidate add)
            (overlay-put o 'before-string
                         (propertize "○" 'face 'drgnx-debug-breakpoint-candidate 'mouse-face 'highlight 'pointer 'hand
                                     'help-echo "Click to add an inline breakpoint" 'keymap drgnx-debug-gutter--inline-map
                                     'drgnx-debug-candidate add))
            (push o drgnx-debug-gutter--candidates)))))))

(defun drgnx-debug-gutter-add-logpoint (line message)
  "A logpoint on LINE printing MESSAGE (`{expression}' is replaced by its value)."
  (interactive (list (line-number-at-pos) (read-string "Log message: ")))
  (unless (string-empty-p message)
    (drgnx-debug-gutter--ask (list :op "add" :path buffer-file-name :line line :log message))))

(defun drgnx-debug-gutter--event-line (event)
  "The buffer line of mouse EVENT's position, with its window's buffer current."
  (let ((pos (event-start event)))
    (with-current-buffer (window-buffer (posn-window pos))
      (line-number-at-pos (posn-point pos)))))

(defun drgnx-debug-gutter-click (event)
  "Mouse EVENT in the column: toggle that line's breakpoint."
  (interactive "e")
  (with-current-buffer (window-buffer (posn-window (event-start event)))
    (drgnx-debug-gutter-toggle (drgnx-debug-gutter--event-line event))))

(defun drgnx-debug-gutter-drag (event)
  "Mouse EVENT dragged from a mark in the column to another line of the same window: the breakpoint moves there
(`move': its saved line plus the lines dragged, as a save would send)."
  (interactive "e")
  (let* ((start (event-start event)) (end (event-end event)) (w (posn-window start)))
    (when (and (eq w (posn-window end)) (posn-point end))
      (with-current-buffer (window-buffer w)
        (let* ((from (line-number-at-pos (posn-point start))) (to (line-number-at-pos (posn-point end)))
               (id (drgnx-debug-gutter--mark-at from)) (bp (and id (drgnx-debug-gutter--bp id))))
          (when (and bp (/= from to))
            (drgnx-debug-gutter--ask (list :op "move" :id id :line (+ (plist-get bp :line) (- to from))))))))))

(defun drgnx-debug-gutter-shift-click (event)
  "Shifted mouse EVENT in the column: a logpoint on that line."
  (interactive "e")
  (with-current-buffer (window-buffer (posn-window (event-start event)))
    (drgnx-debug-gutter-add-logpoint (drgnx-debug-gutter--event-line event) (read-string "Log message: "))))

;;;; Editing a breakpoint

(defconst drgnx-debug-gutter--fields
  '((condition :condition "Condition" "Add Conditional Breakpoint…" "Edit Condition…")
    (hit :hit "Hit count" nil "Edit Hit Count…")
    (log :log "Log message ({expression} is replaced)" "Add Logpoint…" "Edit Log Message…"))
  "FIELD → (KEY PROMPT ADD-LABEL EDIT-LABEL): what the breakpoint prompt edits.")

(defun drgnx-debug-gutter--bp (id)
  "The breakpoint ID as the hub last said."
  (seq-find (lambda (b) (eql (plist-get b :id) id)) drgnx-debug-gutter--bps))

(defun drgnx-debug-gutter-edit (line field)
  "Edit FIELD (`condition', `hit' or `log') of LINE's breakpoint in the minibuffer; on a line without one, add it.
An empty answer clears the field."
  (interactive (list (line-number-at-pos)
                     (intern (completing-read "Edit: " '("condition" "hit" "log") nil t))))
  (let* ((f (alist-get field drgnx-debug-gutter--fields))
         (id (drgnx-debug-gutter--mark-at line))
         (now (and id (plist-get (drgnx-debug-gutter--bp id) (car f))))
         (text (read-string (format "%s (empty clears): " (nth 1 f)) now)))
    (cond (id (drgnx-debug-gutter--ask (list :op "edit" :id id (car f) text)))
          ((not (string-empty-p text))
           (drgnx-debug-gutter--ask (list :op "add" :path buffer-file-name :line line (car f) text))))))

(defun drgnx-debug-gutter-set-enabled (line enabled)
  "Enable LINE's breakpoint, or disable it when ENABLED is nil."
  (when-let* ((id (drgnx-debug-gutter--mark-at line)))
    (drgnx-debug-gutter--ask (list :op "edit" :id id :enabled (if enabled t :false)))))

(defun drgnx-debug-gutter-run-to-cursor (line)
  "Continue the project's session until it reaches LINE."
  (interactive (list (line-number-at-pos)))
  (if-let* ((s (drgnx-debug-gutter--session)))
      (drgnx-hub-call "debug/run-to-cursor" (list :session s :path buffer-file-name :line line) #'ignore)
    (user-error "No debug session in this project")))

(defun drgnx-debug-gutter--menu-items (line)
  "The column's menu for LINE: (LABEL . FUNCTION) per item, by the line's state."
  (let* ((id (drgnx-debug-gutter--mark-at line))
         (bp (and id (drgnx-debug-gutter--bp id)))
         (edit (lambda (field) (lambda () (interactive) (drgnx-debug-gutter-edit line field)))))
    (append
     (if id
         (list (cons "Remove Breakpoint" (lambda () (interactive) (drgnx-debug-gutter-toggle line)))
               (cons "Edit Condition…" (funcall edit 'condition))
               (cons "Edit Hit Count…" (funcall edit 'hit))
               (cons "Edit Log Message…" (funcall edit 'log))
               (if (plist-get bp :enabled)
                   (cons "Disable Breakpoint" (lambda () (interactive) (drgnx-debug-gutter-set-enabled line nil)))
                 (cons "Enable Breakpoint" (lambda () (interactive) (drgnx-debug-gutter-set-enabled line t)))))
       (list (cons "Add Breakpoint" (lambda () (interactive) (drgnx-debug-gutter-toggle line)))
             (cons "Add Conditional Breakpoint…" (funcall edit 'condition))
             (cons "Add Logpoint…" (funcall edit 'log))))
     (when (drgnx-debug-gutter--session)
       (list (cons "Run to Cursor" (lambda () (interactive) (drgnx-debug-gutter-run-to-cursor line))))))))

(defun drgnx-debug-gutter-menu (event)
  "Mouse EVENT in the column: the menu for that line."
  (interactive "e")
  (with-current-buffer (window-buffer (posn-window (event-start event)))
    (popup-menu (cons "Breakpoint" (mapcar (lambda (it) (vector (car it) (cdr it) t))
                                           (drgnx-debug-gutter--menu-items (drgnx-debug-gutter--event-line event))))
                event)))

;;;; Saves and reverts

(defun drgnx-debug-gutter--saved ()
  "`after-save-hook': the drafts reach the store: a moved mark sends `move' (its saved line plus how far the text moved
it), a mark whose line was deleted sends `remove'."
  (dolist (e (reverse drgnx-debug-gutter--overlays))
    (let* ((id (car e)) (o (cdr e))
           (bp (seq-find (lambda (b) (eql (plist-get b :id) id)) drgnx-debug-gutter--bps)))
      (when bp
        (if (not (overlay-buffer o))
            (drgnx-debug-gutter--ask (list :op "remove" :id id))
          (let ((delta (- (line-number-at-pos (overlay-start o)) (overlay-get o 'drgnx-debug-drawn))))
            (unless (zerop delta)
              (drgnx-debug-gutter--ask (append (list :op "move" :id id :line (+ (plist-get bp :line) delta))
                                               (when-let* ((col (overlay-get o 'drgnx-debug-column)))
                                                 (list :column col)))))))))))

(defun drgnx-debug-gutter--reverted ()
  "`after-revert-hook': the text is the saved file again, so the marks go back to the store's lines."
  (drgnx-debug-gutter--clear)
  (drgnx-debug-gutter--draw))

;;;; The stopped line (spec §5)

;; A stop's `debug-frame' marks its line: the top frame with an arrow and a band (`drgnx-debug-stopped-line', the
;; error colours on an exception, with a card under the line), a caller frame picked in the Call Stack with an outline
;; arrow and its own band, drawn only when it is not the top frame.  The marks are overlays tagged `drgnx-debug-stop'
;; (`top' or `frame'), kept per session; a breakpoint under the arrow hides its glyph (the arrow carries its dot) until
;; the stop goes.  They go 150 ms after the session runs, unless a stop comes first, and at once when it ends.

(defvar drgnx-debug-gutter--stops nil "SESSION → the overlays of its stop marks.")
(defvar drgnx-debug-gutter--stop-windows nil
  "SESSION → the window its last stop opened in (reused, like a preview tab).")
(defconst drgnx-debug-gutter-stop-linger 0.15 "Seconds a stop's marks stay after its session runs (a step's flicker).")

(defun drgnx-debug-gutter--key-hint (command)
  "COMMAND's key in the active profile as text, or nil."
  (when-let* ((k (where-is-internal command nil t))) (key-description k)))

(defun drgnx-debug-gutter--exception-card (exception path line)
  "The card under an exception stop's line: EXCEPTION's type (or id) and break mode, where it was raised (PATH and
LINE), its message, and what the keys do.  The band ends after the line's newline, so its `after-string' (this) starts
the next row."
  (let* ((type (or (plist-get exception :type) (plist-get exception :id) "Exception"))
         (mode (pcase (plist-get exception :break_mode)
                 ((or "unhandled" "userUnhandled") "uncaught") ("always" "raised") (_ nil)))
         (where (and path (format "raised in %s:%d" (file-name-nondirectory path) line)))
         (cont (drgnx-debug-gutter--key-hint 'drgnx-debug-start-or-continue))
         (stop (drgnx-debug-gutter--key-hint 'drgnx-debug-stop))
         (pad (propertize " " 'display '(space :width (12))))
         (row (lambda (text face)
                (concat (propertize " " 'display '(space :align-to 6)) pad (propertize text 'face face) pad "\n"))))
    (concat (funcall row (concat (propertize type 'face 'drgnx-debug-exception-title)
                                 (propertize (concat (and (or mode where) " · ")
                                                     (string-join (delq nil (list mode where)) ", "))
                                             'face 'drgnx-debug-exception-card))
                     'drgnx-debug-exception-card)
            (when-let* ((m (plist-get exception :message)))
              (funcall row (format "%s" m) '(:inherit (default drgnx-debug-exception-card))))
            (funcall row (string-join (delq nil (list (and stop (format "%s to stop" stop))
                                                      (format "%s to continue" (or cont "Continue"))))
                                      " · ")
                     '(:inherit (drgnx-debug-exception-hint drgnx-debug-exception-card))))))

(defun drgnx-debug-gutter--stop-overlays (session &optional role)
  "SESSION's live stop overlays, only ROLE's when given."
  (seq-filter (lambda (o) (and (overlay-buffer o) (or (null role) (eq (overlay-get o 'drgnx-debug-stop) role))))
              (cdr (assoc session drgnx-debug-gutter--stops))))

(defun drgnx-debug-gutter--unmark (overlays)
  "Delete the stop OVERLAYS, and show again the breakpoint glyphs they hid."
  (dolist (o overlays)
    (when-let* ((b (overlay-buffer o)) (mark (overlay-get o 'drgnx-debug-hides)))
      (when (overlay-buffer mark)
        (overlay-put mark 'drgnx-debug-under-stop nil)
        (with-current-buffer b
          (overlay-put mark 'before-string (drgnx-debug-gutter--margin-string
                                            (overlay-get mark 'drgnx-debug-kind)
                                            (overlay-get mark 'drgnx-debug-help)
                                            (overlay-get mark 'drgnx-debug-agent))))))
    (delete-overlay o)))

(defun drgnx-debug-gutter-stop-clear (session &optional role)
  "Take SESSION's stop marks away (only ROLE's: `top' or `frame', when given)."
  (drgnx-timer-cancel (cons 'debug-stop session))
  (let ((gone (drgnx-debug-gutter--stop-overlays session role)))
    (drgnx-debug-gutter--unmark gone)
    (let ((left (seq-remove (lambda (o) (memq o gone)) (drgnx-debug-gutter--stop-overlays session))))
      (setq drgnx-debug-gutter--stops
            (if left (cons (cons session left) (assoc-delete-all session drgnx-debug-gutter--stops))
              (assoc-delete-all session drgnx-debug-gutter--stops))))
    (unless (assoc session drgnx-debug-gutter--stops)
      (setq drgnx-debug-gutter--stop-windows (assoc-delete-all session drgnx-debug-gutter--stop-windows)))))

(defun drgnx-debug-gutter-stop-clear-all ()
  "Take every session's stop marks away."
  (dolist (s (mapcar #'car drgnx-debug-gutter--stops)) (drgnx-debug-gutter-stop-clear s)))

(defun drgnx-debug-gutter--mark-stop (session role kind face line card)
  "Mark LINE of this buffer for SESSION's ROLE: an arrow of KIND (when the column is on) and a band in FACE, CARD
after the line when given."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (let* ((bol (point)) (eol (line-end-position))
           (band (make-overlay bol (min (point-max) (1+ eol)) nil t nil))
           (mark (and (eq role 'top) drgnx-debug-gutter-mode (drgnx-debug-gutter--mark-at line))))
      (when mark
        (let ((m (cdr (assq mark drgnx-debug-gutter--overlays))))
          (when (eq kind 'stop) (setq kind 'stop-bp))
          (overlay-put m 'before-string nil)
          (overlay-put m 'drgnx-debug-under-stop t)
          (overlay-put band 'drgnx-debug-hides m)))
      (overlay-put band 'drgnx-debug-stop role)
      (overlay-put band 'drgnx-debug-kind kind)
      (overlay-put band 'face face)
      (overlay-put band 'priority (if (eq role 'top) 20 19))
      (when drgnx-debug-gutter-mode
        (overlay-put band 'before-string
                     (drgnx-debug-gutter--margin-string kind (if (eq role 'top) "Paused here" "The selected frame"))))
      (when card (overlay-put band 'after-string card))
      (push band (alist-get session drgnx-debug-gutter--stops nil nil #'equal)))))

(defvar-local drgnx-debug-gutter--source-ref nil "(SESSION . REF): the debugger source this buffer shows.")

(defun drgnx-debug-gutter--source-buffer (session name ref)
  "The read-only buffer \"NAME (from the debugger)\" of SESSION's source REF (its text comes from
`drgnx-debug-gutter--fill-source')."
  (let ((buf (get-buffer-create (format "%s (from the debugger)" (or name "source")))))
    (with-current-buffer buf
      (setq buffer-read-only t)
      (setq-local drgnx-debug-gutter--source-ref (cons session ref)))
    buf))

(defun drgnx-debug-gutter--fill-source (buf session ref then)
  "Fill BUF with SESSION's source REF from the hub, then call THEN."
  (drgnx-hub-call "debug/source" (list :session session :ref ref)
                  (lambda (result error)
                    (when (buffer-live-p buf)
                      (with-current-buffer buf
                        (let ((inhibit-read-only t))
                          (erase-buffer)
                          (insert (if error (format "The debugger has no text for this source: %s" error)
                                    (or (plist-get result :text) ""))))
                        (set-buffer-modified-p nil)
                        (goto-char (point-min)))
                      (funcall then)))))

(defun drgnx-debug-gutter--show-stop-in (buf data)
  "Mark DATA's stop (a `debug-frame') in BUF and, when it says `open', show BUF at the line."
  (let* ((session (plist-get data :session)) (top (eq (plist-get data :top) t))
         (open (eq (plist-get data :open) t)) (line (or (plist-get data :line) 1))
         (exception (and top (equal (plist-get data :reason) "exception") (plist-get data :exception))))
    (with-current-buffer buf
      (drgnx-debug-gutter--mark-stop
       session (if top 'top 'frame)
       (cond (exception 'exception) (top 'stop) (t 'frame))
       (cond (exception 'drgnx-debug-exception-line) (top 'drgnx-debug-stopped-line) (t 'drgnx-debug-frame-line))
       line
       (and exception (drgnx-debug-gutter--exception-card exception (plist-get data :path) line))))
    (when open
      (let* ((prev (alist-get session drgnx-debug-gutter--stop-windows nil nil #'equal))
             (w (or (get-buffer-window buf)
                    (and (window-live-p prev) prev)
                    (selected-window))))
        (unless (eq (window-buffer w) buf) (set-window-buffer w buf))
        (setf (alist-get session drgnx-debug-gutter--stop-windows nil nil #'equal) w)
        (select-window w)
        (goto-char (point-min))
        (forward-line (1- line))
        (move-to-column (max 0 (1- (or (plist-get data :col) 1))))
        (set-window-point w (point))
        (when drgnx-debug-focus-on-stop (select-frame-set-input-focus (window-frame w)))))))

(defun drgnx-debug-gutter-show-frame (data)
  "A `debug-frame' event (DATA): mark its line, and open it in the editor that started the session (`open')."
  (let* ((session (plist-get data :session)) (top (eq (plist-get data :top) t))
         (open (eq (plist-get data :open) t))
         (path (plist-get data :path)) (ref (plist-get data :ref)))
    (drgnx-timer-cancel (cons 'debug-stop session))
    ;; a top frame is a new stop (or the top picked again): its marks go (the inline values stay, for the stop's own
    ;; `debug-inline' to replace in place); a caller replaces a caller
    (when top (drgnx-debug-gutter-stop-clear session 'top))
    (drgnx-debug-gutter-stop-clear session 'frame)
    (cond
     ((stringp path)
      (when-let* ((buf (if open (find-file-noselect path) (get-file-buffer path))))
        (drgnx-debug-gutter--show-stop-in buf data)))
     ((and (integerp ref) (> ref 0))
      (let* ((name (format "%s (from the debugger)" (or (plist-get data :source_name) "source")))
             (old (get-buffer name)))
        (when (or open old)
          (let ((buf (drgnx-debug-gutter--source-buffer session (plist-get data :source_name) ref)))
            (if (and old (equal (buffer-local-value 'drgnx-debug-gutter--source-ref old) (cons session ref))
                     (> (buffer-size old) 0))
                (drgnx-debug-gutter--show-stop-in buf data)
              (drgnx-debug-gutter--fill-source buf session ref
                                               (lambda () (drgnx-debug-gutter--show-stop-in buf data))))))))
     (open (message "No source: %s" (or (plist-get data :name) "this frame"))))))

(defun drgnx-debug-gutter-stop-sessions (sessions)
  "`debug-state' said SESSIONS: the marks of a session that is gone go now, a running one's after the linger."
  (dolist (id (mapcar #'car drgnx-debug-gutter--stops))
    (let ((s (seq-find (lambda (s) (equal (plist-get s :id) id)) sessions)))
      (cond ((null s) (drgnx-debug-gutter-stop-clear id))
            ;; owned by a buffer the marks are in: they go with it anyway
            ((and (equal (plist-get s :state) "running") (drgnx-debug-gutter--stop-overlays id))
             (drgnx-timer-debounce (cons 'debug-stop id) drgnx-debug-gutter-stop-linger
                                   #'drgnx-debug-gutter-stop-clear :args (list id)
                                   :owner (overlay-buffer (car (drgnx-debug-gutter--stop-overlays id)))))))))

;;;; Inline values (spec §8)

;; A stop's `debug-inline' (the hub picks the names, places them, cuts them and marks what changed: debug/inline.rs)
;; puts the values after their lines' ends: overlays tagged `drgnx-debug-stop' `inline' among the session's stop marks,
;; so they go with them (150 ms after it runs, at once when it ends).  A new stop's frame leaves them, and its own
;; `debug-inline' replaces them in place (a line that keeps values keeps its overlay).  Blame yields on those lines
;; (`drgnx-blame-yield').  A buffer modified since its save gets none: the program runs the saved file.

(defun drgnx-debug-gutter--inline-set (symbol value)
  "`:set' of `drgnx-debug-inline-values': off takes every value away at once."
  (set-default symbol value)
  (unless (eq value 'on) (drgnx-debug-gutter-inline-clear-all)))

(defcustom drgnx-debug-inline-values 'on
  "Whether a stop shows its variables' values at the ends of their lines."
  :type '(choice (const :tag "On" on) (const :tag "Off" off)) :group 'drgnx
  :set #'drgnx-debug-gutter--inline-set)

(defface drgnx-debug-inline-value '((t :inherit drgnx-text-subtle :slant italic))
  "A value after its line while stopped." :group 'drgnx)
(defface drgnx-debug-inline-value-changed '((t :inherit drgnx-status-warn :slant italic))
  "A value that changed since the last stop." :group 'drgnx)

(defconst drgnx-debug-gutter--inline-priority 90 "Below diagnostics' 100: the values come first after the line.")

(defvar drgnx-blame--overlay)

(defun drgnx-debug-gutter--inline-clear (session)
  "Take SESSION's inline values away (its other stop marks stay)."
  (let ((gone (drgnx-debug-gutter--stop-overlays session 'inline)))
    (when gone
      (mapc #'delete-overlay gone)
      (let ((left (drgnx-debug-gutter--stop-overlays session)))
        (setq drgnx-debug-gutter--stops
              (if left (cons (cons session left) (assoc-delete-all session drgnx-debug-gutter--stops))
                (assoc-delete-all session drgnx-debug-gutter--stops)))))))

(defun drgnx-debug-gutter-inline-clear-all ()
  "Take every session's inline values away."
  (dolist (s (mapcar #'car drgnx-debug-gutter--stops)) (drgnx-debug-gutter--inline-clear s)))

(defun drgnx-debug-gutter--inline-string (text changed)
  "TEXT after a line: in the value face, the CHANGED ranges ([START END] each) in the changed face."
  (let ((s (concat "  " (copy-sequence text))))
    (add-face-text-property 0 (length s) 'drgnx-debug-inline-value t s)
    (seq-doseq (r changed)
      (let ((b (+ 2 (elt r 0))) (e (+ 2 (elt r 1))))
        (when (<= b e (length s))
          (put-text-property b e 'face 'drgnx-debug-inline-value-changed s))))
    (put-text-property 0 1 'cursor t s)
    s))

(defun drgnx-debug-gutter-inline (data)
  "A `debug-inline' event (DATA: :session, :path, :lines of :line, :text, :changed): show the values in the file's
buffer, replacing the session's last ones in place."
  (let* ((session (plist-get data :session)) (path (plist-get data :path))
         (buf (and (eq drgnx-debug-inline-values 'on) (stringp path) (get-file-buffer path)))
         (old (drgnx-debug-gutter--stop-overlays session 'inline))
         (lines (append (plist-get data :lines) nil)))
    (cond
     ((or (null buf) (null lines)) (drgnx-debug-gutter--inline-clear session))
     ((buffer-modified-p buf)
      (drgnx-debug-gutter--inline-clear session)
      (message "No inline values: %s was modified since it was saved" (buffer-name buf)))
     (t
      (with-current-buffer buf
        (save-excursion
          (let ((keep nil))
            (dolist (l lines)
              (goto-char (point-min))
              (when (zerop (forward-line (1- (plist-get l :line))))
                (let* ((eol (line-end-position))
                       (o (or (seq-find (lambda (o) (and (eq (overlay-buffer o) buf) (= (overlay-start o) eol))) old)
                              (let ((n (make-overlay eol eol nil t nil)))
                                (overlay-put n 'drgnx-debug-stop 'inline)
                                (overlay-put n 'drgnx-blame-yield t)
                                (overlay-put n 'priority drgnx-debug-gutter--inline-priority)
                                n))))
                  (overlay-put o 'after-string
                               (drgnx-debug-gutter--inline-string (plist-get l :text) (plist-get l :changed)))
                  (push o keep)
                  ;; blame on this line yields (`drgnx-blame--show' checks `drgnx-blame-yield' before it shows again)
                  (when (and (bound-and-true-p drgnx-blame--overlay) (overlay-buffer drgnx-blame--overlay)
                             (= (overlay-start drgnx-blame--overlay) eol))
                    (delete-overlay drgnx-blame--overlay)))))
            (mapc #'delete-overlay (seq-remove (lambda (o) (memq o keep)) old))
            (let ((others (seq-remove (lambda (o) (eq (overlay-get o 'drgnx-debug-stop) 'inline))
                                      (drgnx-debug-gutter--stop-overlays session))))
              (setf (alist-get session drgnx-debug-gutter--stops nil nil #'equal) (append keep others))))))))))

;;;; The mode

(defvar drgnx-debug-gutter-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [left-margin down-mouse-1] #'ignore)  ; no text selection from the column: a drag moves a mark
    (define-key m [left-margin mouse-1] #'drgnx-debug-gutter-click)
    (define-key m [left-margin drag-mouse-1] #'drgnx-debug-gutter-drag)
    (define-key m [left-margin S-mouse-1] #'drgnx-debug-gutter-shift-click)
    (define-key m [left-margin mouse-3] #'drgnx-debug-gutter-menu)
    m)
  "The column's mouse: click toggles a breakpoint, a drag moves one, shift-click adds a logpoint, the right button
opens its menu.")

(defun drgnx-debug-gutter--in-use-p ()
  "Whether some buffer has the column."
  (seq-some (lambda (b) (buffer-local-value 'drgnx-debug-gutter-mode b)) (buffer-list)))

(defun drgnx-debug-gutter--major-mode-change ()
  "`change-major-mode-hook': the buffer's locals are about to go (a new major mode, `normal-mode' in a revert), so the
column turns off first, releasing its margin claim and the hooks; the module's `find-file-hook' turns it on again."
  (drgnx-debug-gutter-mode -1))

(define-minor-mode drgnx-debug-gutter-mode
  "The breakpoint column in this file's left margin (`drgnx-debug-gutter-show')."
  :group 'drgnx :keymap drgnx-debug-gutter-mode-map
  (if drgnx-debug-gutter-mode
      (progn
        (add-hook 'after-save-hook #'drgnx-debug-gutter--saved nil t)
        (add-hook 'after-revert-hook #'drgnx-debug-gutter--reverted nil t)
        (add-hook 'change-major-mode-hook #'drgnx-debug-gutter--major-mode-change nil t)
        (add-hook 'drgnx-margins-changed-functions #'drgnx-debug-gutter--restring)
        (add-hook 'drgnx-hub-event-functions #'drgnx-debug-gutter--event)
        (add-hook 'pre-redisplay-functions #'drgnx-debug-gutter--pool-update nil t)
        (add-hook 'window-scroll-functions #'drgnx-debug-gutter--pool-scrolled nil t)
        ;; asked from `find-file-hook' (`drgnx-debug--gutter-on'): with no hub to answer, the file has no breakpoints
        ;; to show; it never fails the visit (`drgnx-hub-call' signals when no hub serves).  The commands still say why
        (when buffer-file-name (condition-case nil (drgnx-debug-gutter--ask nil) (error nil)))
        (drgnx-debug-gutter--claim))
    (remove-hook 'after-save-hook #'drgnx-debug-gutter--saved t)
    (remove-hook 'after-revert-hook #'drgnx-debug-gutter--reverted t)
    (remove-hook 'change-major-mode-hook #'drgnx-debug-gutter--major-mode-change t)
    (remove-hook 'pre-redisplay-functions #'drgnx-debug-gutter--pool-update t)
    (remove-hook 'window-scroll-functions #'drgnx-debug-gutter--pool-scrolled t)
    (drgnx-debug-gutter--pool-clear)
    (setq drgnx-debug-gutter--hover-cache nil)
    (drgnx-debug-gutter--clear)
    (setq drgnx-debug-gutter--bps nil drgnx-debug-gutter--version 0)
    (drgnx-margins-claim 'debug nil)
    (unless (drgnx-debug-gutter--in-use-p)
      (remove-hook 'drgnx-margins-changed-functions #'drgnx-debug-gutter--restring)
      (remove-hook 'drgnx-hub-event-functions #'drgnx-debug-gutter--event))))

(provide 'drgnx-debug-gutter)
;;; drgnx-debug-gutter.el ends here
