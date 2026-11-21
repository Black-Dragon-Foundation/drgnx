;;; drgnx-agent-identity.el --- One identity rule for every agent surface: colour, mark, glyph -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The hub gives each live agent an ordinal (1, 2, 3 ...).  Each display maps the ordinal to a colour (a face), a mark
;; (circle, square, triangle, diamond, hexagon, star) and a text glyph, by one fixed rule, so the cursor bar, the
;; gutter, the badges, the status bar and the panel of one display agree.  Colour is never the only cue: the mark and
;; the handle come with it.
;;
;; The colours are the display's ring: the look's six (`drgnx-agent-1..6') and up to six tonal variants of them
;; (`drgnx-agent-7..12'), which `drgnx-look-derive' works out at theme load and publishes in
;; `drgnx-agent-identity-rings'.  With C colours the default diagonal walk gives agent k (ordinal - 1) colour k mod C
;; and mark ((k mod C) mod 6 + k div C) mod 6: every pair is distinct up to 6 x C (36 with the look's six, up to 72),
;; and agents 1 to 6 get six different marks.  Past that, an ordinal takes the pair of the least recently active
;; session that no watched buffer shows.  Results are cached per frame and cleared at theme load.
;; See docs/guide/look.md ("Agent colours, marks and handles").

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-setting)
(require 'drgnx-icons)

(drgnx-defsetting drgnx-agents-identity-walk 'diagonal
  "How agents are given a colour and a mark: `diagonal' (the look's six colours each with its own mark, then the
rest) or `colour-first' (every colour with the circle first, marks from the agent after the last colour).  A change
applies to the agents shown from then on."
  :type '(choice (const :tag "Diagonal" diagonal) (const :tag "Colour first" colour-first)) :group 'drgnx
  :scope 'global :agents 'never :apply #'drgnx-agent-identity-clear :schema '(enum diagonal colour-first))

(defconst drgnx-agent-identity-marks '(circle square triangle diamond hexagon star)
  "The six marks, in walk order.")

(defconst drgnx-agent-identity--ring-one
  '(drgnx-agent-1 drgnx-agent-2 drgnx-agent-3 drgnx-agent-4 drgnx-agent-5 drgnx-agent-6)
  "The look's six colours: the ring when no derivation has published another.")

(defvar drgnx-agent-identity-rings nil
  "((KIND . FACES)...), KIND `gui' or `tty256': the faces of each display's colours in order, published by
`drgnx-look-derive'.  Nil means the look's six.")

(defvar drgnx-agent-identity-sessions-function nil
  "A function returning ((ORDINAL . LAST-ACTIVE)...), the live sessions and when each was last active, or nil.
Used only past capacity; the agent client sets it.")

(defvar drgnx-agent-identity-watched-function nil
  "A function returning the ordinals of the sessions present in a watched buffer, or nil.  The agent client sets it.")

(defvar drgnx-agent-identity--cache (make-hash-table :test 'eq :weakness 'key)
  "FRAME → a hash of ordinal → identity and mark → glyph; weak on the frame, emptied by
`drgnx-agent-identity-clear' at theme load.")

(defvar drgnx-agent-identity-cleared-hook nil
  "Run after `drgnx-agent-identity-clear': surfaces that resolved an agent's colour redraw with the new one.")

(defun drgnx-agent-identity-clear ()
  "Forget every cached identity: the ring, the setting or the theme changed."
  (clrhash drgnx-agent-identity--cache)
  (run-hooks 'drgnx-agent-identity-cleared-hook))

(defun drgnx-agent-identity--kind (frame)
  (if (display-graphic-p frame) 'gui 'tty256))

(defun drgnx-agent-identity--ring (frame)
  "The faces of FRAME's display, in colour order."
  (or (cdr (assq (drgnx-agent-identity--kind frame) drgnx-agent-identity-rings))
      drgnx-agent-identity--ring-one))

(defun drgnx-agent-identity--table (frame)
  (or (gethash frame drgnx-agent-identity--cache)
      (puthash frame (make-hash-table :test 'equal) drgnx-agent-identity--cache)))

(defun drgnx-agent-identity-colour-count (&optional frame)
  "How many colours FRAME's display gives agents: 6 to 12."
  (length (drgnx-agent-identity--ring (or frame (selected-frame)))))

(defun drgnx-agent-identity-capacity(&optional frame)
  "How many agents FRAME's display tells apart by colour and mark: 6 times its colour count."
  (* 6 (length (drgnx-agent-identity--ring (or frame (selected-frame))))))

(defun drgnx-agent-identity--pair (k colours walk)
  "(COLOUR-INDEX . MARK-INDEX) of the zero-based agent K, K below 6 x COLOURS, for WALK."
  (let ((ci (mod k colours)) (q (/ k colours)))
    (cons ci (mod (if (eq walk 'colour-first) q (+ (mod ci 6) q)) 6))))

(defun drgnx-agent-identity--reused (ordinal capacity)
  "The zero-based slot whose pair ORDINAL (past CAPACITY) takes: the least recently active session's not shown in a
watched buffer, else the ordinal's place in the cycle."
  (let* ((sessions (and drgnx-agent-identity-sessions-function (funcall drgnx-agent-identity-sessions-function)))
         (watched (and drgnx-agent-identity-watched-function (funcall drgnx-agent-identity-watched-function)))
         (free (cl-remove-if (lambda (s) (or (eql (car s) ordinal) (memq (car s) watched) (> (car s) capacity)))
                             sessions))
         (pick (car (sort (copy-sequence free)
                          (lambda (a b) (or (< (cdr a) (cdr b)) (and (= (cdr a) (cdr b)) (< (car a) (car b)))))))))
    (if pick (1- (car pick)) (mod (1- ordinal) capacity))))

(defun drgnx-agent-identity (ordinal &optional frame)
  "The identity of agent ORDINAL (1-based) on FRAME's display: (:face FACE :mark MARK :glyph GLYPH)."
  (let* ((frame (or frame (selected-frame)))
         (table (drgnx-agent-identity--table frame)))
    (or (gethash ordinal table)
        (let* ((ring (drgnx-agent-identity--ring frame))
               (colours (length ring))
               (capacity (* 6 colours))
               (k (if (> ordinal capacity) (drgnx-agent-identity--reused ordinal capacity) (1- (max 1 ordinal))))
               (pair (drgnx-agent-identity--pair k colours drgnx-agents-identity-walk))
               (mark (nth (cdr pair) drgnx-agent-identity-marks)))
          (puthash ordinal (list :face (nth (car pair) ring) :mark mark :glyph (drgnx-agent-identity--glyph mark frame))
                   table)))))

;;;; Marks as text, images and gutter bitmaps

(defconst drgnx-agent-identity--glyphs
  '((circle "●" . "o") (square "■" . "#") (triangle "▲" . "^") (diamond "◆" . "<") (hexagon "⬢" . "H") (star "★" . "*"))
  "MARK → (UNICODE . ASCII).")

(defun drgnx-agent-identity--glyph (mark frame)
  "MARK's glyph on FRAME: the Unicode shape when it is displayable and one column wide there, else ASCII.  Kept
per frame."
  (let* ((table (drgnx-agent-identity--table frame))
         (hit (gethash mark table)))
    (or hit
        (puthash mark
                 (let ((e (alist-get mark drgnx-agent-identity--glyphs)))
                   (if (and (char-displayable-p (aref (car e) 0)) (eql 1 (char-width (aref (car e) 0))))
                       (car e)
                     (cdr e)))
                 table))))

(defun drgnx-agent-identity-text (ordinal &optional frame)
  "Agent ORDINAL's mark as a one-column string (● ■ ▲ ◆ ⬢ ★, or o # ^ < H * where those do not display)."
  (plist-get (drgnx-agent-identity ordinal frame) :glyph))

(defun drgnx-agent-identity-image (ordinal size &optional frame)
  "Agent ORDINAL's mark as a Lucide icon string of SIZE pixels, coloured by the agent's face at draw time."
  (let ((id (drgnx-agent-identity ordinal frame)))
    (drgnx-look-icon (plist-get id :mark) (plist-get id :face) size)))

(defconst drgnx-agent-identity--fringe-shapes
  '((circle . circle) (square . square) (triangle . triangle) (diamond . diamond) (hexagon . circle) (star . diamond))
  "MARK → the gutter shape that stands for it: the four drawn, and the nearest for the other two.")

(defconst drgnx-agent-identity--bitmaps
  `((circle . [#x3c #x7e #xff #xff #xff #xff #x7e #x3c])
    (square . [#xff #xff #xff #xff #xff #xff #xff #xff])
    (triangle . [#x08 #x18 #x38 #x78 #xf8 #xfc #xfe #xff])
    (diamond . [#x18 #x3c #x7e #xff #xff #x7e #x3c #x18]))
  "The gutter shapes, 8 by 8.")

(dolist (e drgnx-agent-identity--bitmaps)
  (when (fboundp 'define-fringe-bitmap)
    (define-fringe-bitmap (intern (format "drgnx-agent-fringe-%s" (car e))) (cdr e) 8 8 'center)))

(defun drgnx-agent-identity-fringe (ordinal &optional frame)
  "The fringe bitmap symbol for agent ORDINAL: circle, square, triangle or diamond (hexagon and star use the nearest)."
  (let ((mark (plist-get (drgnx-agent-identity ordinal frame) :mark)))
    (intern (format "drgnx-agent-fringe-%s" (alist-get mark drgnx-agent-identity--fringe-shapes)))))

(provide 'drgnx-agent-identity)
;;; drgnx-agent-identity.el ends here
