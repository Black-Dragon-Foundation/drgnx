;;; drgnx-minimap.el --- Module editor/minimap: the scroll bar with marks on every surface -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The module of the scroll bar and, as its later stages land, the minimap that widens out of it (docs/guide/
;; minimap.md).  Its setup turns on the scroll bar on every scrollable surface (`drgnx-scrollbar-mode',
;; core/drgnx-ruler.el) and the marks' producers (core/drgnx-marks.el), and redraws the strips when the UI
;; scale or the density changes; its teardown undoes both.  It registers the next-mark commands (`mark-next', by kind
;; `change-next', `bookmark-next', `agent-edit-next', each with a previous).

;;
;; The minimap (state B, design §4): an editor window's strip widens into a map of the whole file when the pointer
;; rests on it, drawn by Nidhogg over the text's right edge from the buffer text's line model (`glitnir-minimap',
;; Hlidskjalf), so a scroll, an edit or a pointer move costs no Lisp.  Lisp gives each editor window its spec when
;; its strip is placed (`drgnx-ruler-place-functions'), the model the MARK expression, and the hub the file whose
;; definitions label the map (`minimap/watch'; the labels go from the hub to Sjá, not through Lisp).  A tree-sitter
;; buffer's bars are coloured by class: its pack's highlights query (else its own font-lock rules' queries) runs in C
;; at each parse (`nidhogg-treesit-highlight-query'), the classes' colours are the standard faces'.
;; One heat layer at a time (`drgnx-minimap-layer', design X3) recolours the bars: the hub computes it (blame, coverage,
;; profile, agent reads) and sends it to Sjá, the spec names it.  A diff buffer, or a file with its change marks on,
;; gets a label at each hunk (`:hunk-labels', X6), counted here (`drgnx-marks-hunks').

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-modules)
(require 'drgnx-ruler)
(require 'drgnx-marks)
(require 'drgnx-registry)
(require 'drgnx-setting)

;; The module's other files sit beside this one (modules are not on the load path): the peek and cards first, which
;; the search and the density strip use.  At compile time too, so their definitions are known here.
(eval-and-compile
  (let ((dir (file-name-directory (or load-file-name (bound-and-true-p byte-compile-current-file) buffer-file-name))))
    (dolist (f '(drgnx-minimap-peek drgnx-minimap-search drgnx-minimap-density))
      (unless (featurep f) (load (expand-file-name (symbol-name f) dir) nil t)))))

(declare-function drgnx-sticky-pin-names "drgnx-sticky" (&optional buffer))

(defvar drgnx-look-density-changed-hook)
(defvar drgnx-hunks-mode)
(defvar drgnx-hub--events)
(defvar drgnx-fold--watched)
(declare-function drgnx-hub--call-on "drgnx-hub-client" (conn method params callback &rest keys))
(declare-function drgnx-notify "drgnx-notice")
(declare-function nidhogg-lines-enable "nidhogg-lines" (&optional buffer wait))
(declare-function nidhogg-lines-set-section-regexp "nidhogg-lines" (buffer regexp))
(declare-function nidhogg-treesit-refold "treesit.c" (parser))
(declare-function treesit-parser-list "treesit.c" (&optional buffer language tag))
(declare-function treesit-parser-language "treesit.c" (parser))
(declare-function treesit-query-compile "treesit.c" (language query &optional eager))
(declare-function treesit-query-language "treesit.c" (query))
(declare-function drgnx-packs-language-dir "drgnx-packs" (language))
(defvar nidhogg-treesit-highlight-query)
(defvar treesit-primary-parser)
(defvar treesit-font-lock-settings)

(defun drgnx-minimap--setting-changed (&rest _)
  "A minimap setting changed: every window's spec again, now."
  (when drgnx-scrollbar-mode (drgnx-scrollbar-refresh-all)))

(drgnx-defsetting drgnx-minimap t
  "Non-nil: an editor's scroll bar widens into the minimap while the pointer rests on it (150 ms), over the text's
right edge, and shrinks back 600 ms after the pointer leaves."
  :type 'boolean :group 'drgnx-minimap :scope 'global :apply #'drgnx-minimap--setting-changed)

(drgnx-defsetting drgnx-minimap-hstrip t
  "Non-nil: an editor that cuts its lines gets a horizontal scroll bar along the bottom of the text while a line is
wider than the window (12 px over the text, from the first text column; it takes no space).  Nil: none."
  :type 'boolean :group 'drgnx-minimap :scope 'global :apply #'drgnx-minimap--setting-changed)

(drgnx-defsetting drgnx-minimap-width 120
  "The minimap's width in logical pixels, 80 to 200."
  :type 'natnum :group 'drgnx-minimap :scope 'global :apply #'drgnx-minimap--setting-changed)

(drgnx-defsetting drgnx-minimap-scale 2
  "How tall a line is on the minimap, in logical pixels: 1 to 3 (3 shows fewer lines, each easier to tell apart)."
  :type '(choice (const 1) (const 2) (const 3)) :group 'drgnx-minimap :scope 'global
  :apply #'drgnx-minimap--setting-changed)

(drgnx-defsetting drgnx-minimap-side 'right
  "Which edge of the text the minimap opens over: `right' or `left'.  The scroll bar stays at the right edge."
  :type '(choice (const right) (const left)) :group 'drgnx-minimap :scope 'global
  :apply #'drgnx-minimap--setting-changed)

(drgnx-defsetting drgnx-minimap-sticky nil
  "Non-nil: the minimap stays open, and the text narrows by its width so it covers no code (on the right; on the left
it opens over the text)."
  :type 'boolean :group 'drgnx-minimap :scope 'global :apply #'drgnx-minimap--setting-changed)

(drgnx-defsetting drgnx-minimap-labels t
  "The names drawn over the minimap: t, each definition (from the hub's outline, for files up to 8 MiB) and each
MARK section; `marks-only', the MARK sections alone; nil, none."
  :type '(choice (const :tag "Definitions and MARK sections" t) (const :tag "MARK sections only" marks-only)
                 (const :tag "None" nil))
  :group 'drgnx-minimap :scope 'global :apply #'drgnx-minimap--setting-changed)

(defconst drgnx-minimap-default-mark-regexp
  "^\\s*(?:;;;;+|(?://+|#+|;+|--|/\\*+)\\s*(?:MARK:\\s*-?|pragma\\s+mark\\s+-?|region\\b|%%))\\s*(?P<name>\\S.*?)\\s*(?:\\*/)?$"
  "The MARK sections drgnx finds by default: `MARK:' comments, `// region' and `#region', `#pragma mark', Lisp
`;;;;' headings and `# %%' cells.")

(drgnx-defsetting drgnx-minimap-mark-regexp drgnx-minimap-default-mark-regexp
  "The comment lines drawn as MARK sections on the minimap, a regular expression in Rust's regex syntax (not
Emacs's): it is matched against each line; the section's name is the group named `name', else the first group, else
the whole match.  Nil: no MARK sections."
  :type '(choice (const :tag "None" nil) string) :group 'drgnx-minimap :scope 'global
  :apply #'drgnx-minimap--setting-changed)

(defconst drgnx-minimap-layers '(blame coverage profile agent-read)
  "The heat layers the hub computes (`minimap/watch''s `heat').")

(drgnx-defsetting drgnx-minimap-layer nil
  "The heat layer that recolours the minimap's bars, one at a time: `blame', each line's age (newest hottest);
`coverage', covered lines (from the newest report `drgnx-minimap-coverage-files' names); `profile', each line's own
samples (from the profile `minimap-layer' asks for); `agent-read', the lines agents read most; nil, none.  Marks stay
on top."
  :type '(choice (const :tag "None" nil) (const :tag "Blame age" blame) (const :tag "Coverage" coverage)
                 (const :tag "Profile" profile) (const :tag "Lines agents read" agent-read))
  :group 'drgnx-minimap :scope 'global :apply #'drgnx-minimap--setting-changed)

(drgnx-defsetting drgnx-minimap-coverage-files
  '("lcov.info" "coverage/lcov.info" "coverage/*.info" "coverage.xml" "coverage/cobertura*.xml" "cobertura.xml"
    "coverage.json" "target/llvm-cov/*.json")
  "Where the coverage heat layer finds reports, relative to the file's worktree (`*' and `?' match in the last part):
lcov tracefiles, Cobertura XML reports and llvm-cov JSON exports.  The newest that names the file is read, and read
again when a test run writes it."
  :type '(repeat string) :group 'drgnx-minimap :scope 'global :apply #'drgnx-minimap--setting-changed)

(defvar drgnx-minimap-profile-file nil
  "The profile the `profile' heat layer reads (pprof, `perf script' text with source lines, or speedscope), as
`minimap-layer' asked for it, or nil.")

(defface drgnx-minimap-label '((t :inherit drgnx-ui-text :weight semi-bold))
  "The font of the minimap's labels (its colour comes from the label's kind)." :group 'drgnx-minimap)

;;;; Colours: the line model's display classes

(defconst drgnx-minimap--class-faces
  '((keyword font-lock-keyword-face) (function font-lock-function-name-face) (type font-lock-type-face)
    (string font-lock-string-face) (comment font-lock-comment-face) (constant font-lock-constant-face)
    (added diff-indicator-added) (removed diff-indicator-removed) (heading outline-1) (link link)
    (special font-lock-escape-face))
  "Each display class (`glitnir-minimap-classes') and the face whose foreground colours its bars, (CLASS FACE); a
class not listed (variable, property, operator, punctuation), or whose face is not defined, draws as text.")

(defvar drgnx-minimap--queries (make-hash-table :test 'eq)
  "Each tree-sitter language's compiled `queries/highlights.scm' of its pack, or `none'.")

(defun drgnx-minimap--query (language)
  "The highlight query the minimap colours a LANGUAGE buffer by: its pack's `queries/highlights.scm' (compiled once a
language), else the compiled queries of the buffer's own tree-sitter font-lock rules for LANGUAGE that are on (their
captures are face names, which Nidhogg maps to classes as well); nil when there is neither."
  (let ((q (gethash language drgnx-minimap--queries)))
    (unless q
      (setq q (or (when-let* ((dir (and (require 'drgnx-packs nil t) (drgnx-packs-language-dir language)))
                              (file (expand-file-name "queries/highlights.scm" dir))
                              ((file-readable-p file)))
                    (ignore-errors
                      (treesit-query-compile language (with-temp-buffer (insert-file-contents file) (buffer-string))
                                             t)))
                  'none))
      (puthash language q drgnx-minimap--queries))
    (if (not (eq q 'none))
        q
      (and (fboundp 'treesit-query-language)
           (seq-keep (lambda (setting)
                       (let ((c (car setting)))
                         (and (nth 1 setting) (ignore-errors (eq (treesit-query-language c) language)) c)))
                     (bound-and-true-p treesit-font-lock-settings))))))

(defun drgnx-minimap--highlight ()
  "Give the current buffer's tree-sitter parser (its primary one, else its first) the highlight query that colours
its minimap (`nidhogg-treesit-highlight-query'), running it over the whole text when it changed; nothing without a
parser or a Nidhogg that runs it."
  (when-let* (((fboundp 'nidhogg-treesit-refold)) ((boundp 'nidhogg-treesit-highlight-query))
              ((fboundp 'treesit-parser-list))
              (parser (or (bound-and-true-p treesit-primary-parser) (car (treesit-parser-list))))
              (q (drgnx-minimap--query (treesit-parser-language parser))))
    (unless (equal q nidhogg-treesit-highlight-query)
      (setq-local nidhogg-treesit-highlight-query q)
      (nidhogg-treesit-refold parser))))

(defvar-local drgnx-minimap--regexp :none "The MARK expression last given the buffer's line model.")
(defvar-local drgnx-minimap--watched nil "The file name the hub was last told this buffer shows in a minimap.")
(defvar-local drgnx-minimap--asked nil "What the hub was last asked for with that file beyond its labels (the heat).")

(defun drgnx-minimap-window-p (window)
  "Whether WINDOW gets the minimap: its strip is shown and it holds an editor's text (a file or a text buffer that
is not a view: no `drgnx-ruler-span-function', not a special mode)."
  (and drgnx-minimap (window-parameter window 'glitnir-ruler) (fboundp 'nidhogg-lines-enable)
       (with-current-buffer (window-buffer window)
         (and (not drgnx-ruler-span-function) (not (derived-mode-p 'special-mode))
              (or buffer-file-name (derived-mode-p 'prog-mode 'text-mode 'diff-mode))))))

(defun drgnx-minimap--file (buffer)
  "The name BUFFER's file has in the hub's minimap layers (its true name), or nil (no file, a remote one)."
  (when-let* ((f (buffer-file-name buffer)) ((not (file-remote-p f))))
    (file-truename f)))

(defun drgnx-minimap--hunk-labels (buffer)
  "BUFFER's hunk labels for the spec: a vector of [LINE TEXT] (`drgnx-marks-hunks'), or nil when it has none."
  (with-current-buffer buffer
    (let ((n 0))
      (and (or (derived-mode-p 'diff-mode) (bound-and-true-p drgnx-hunks-mode))
           (vconcat (mapcar (lambda (h)
                              (setq n (1+ n))
                              (vector (car h) (drgnx-marks-hunk-label n (nth 1 h) (nth 2 h))))
                            (drgnx-marks-hunks)))))))

(defun drgnx-minimap--width ()
  "The minimap's width, logical pixels: `drgnx-minimap-width' held to 80..200."
  (max 80 (min 200 drgnx-minimap-width)))

(defun drgnx-minimap--reserve (window on)
  "Narrow WINDOW's text by the minimap's width while it is sticky on the right and WINDOW has one (ON), else give the
width back: `drgnx-ruler-reserve' widens the right fringe inside the strip, where the minimap opens."
  (let ((px (and on drgnx-minimap-sticky (not (eq drgnx-minimap-side 'left))
                 (not (drgnx-ruler--column-p window))
                 (drgnx-px (drgnx-minimap--width) (window-frame window)))))
    (unless (eql px (window-parameter window 'drgnx-ruler-reserve))
      (drgnx-ruler-reserve window px))))

(defun drgnx-minimap--spec (window)
  "WINDOW's `glitnir-minimap': the width, the colours, the labels and the heat layer."
  (let ((file (and (or drgnx-minimap-layer (and drgnx-minimap-labels (not (eq drgnx-minimap-labels 'marks-only))))
                   (drgnx-minimap--file (window-buffer window))))
        (hunks (and drgnx-minimap-labels (drgnx-minimap--hunk-labels (window-buffer window)))))
    (append
     (list :width (drgnx-minimap--width) :scale (max 1 (min 3 drgnx-minimap-scale)) :nesting t
           ;; the search's hits (X1): accent bars at their columns, the current one ringed
           :hit (cons 'drgnx-accent 1.0)
           :fill (cons (face-background 'drgnx-surface-panel nil 'default) 1.0)
           :text (cons 'default 0.35)
           :band (cons 'default 0.09)
           ;; a folded range's dashed pill (F3): its name (`nidhogg-lines-set-hidden'), else its count
           :pill 'drgnx-text-muted :pill-format "⋯ %d folded"
           :classes (seq-keep (lambda (c) (and (facep (cadr c)) (cons (car c) (cadr c))))
                              drgnx-minimap--class-faces))
     (and drgnx-minimap-labels
          (list :labels (if (eq drgnx-minimap-labels 'marks-only) 'marks-only t)
                :label 'default :sub 'drgnx-text-muted :accent 'drgnx-accent :mark 'warning
                :label-face 'drgnx-minimap-label))
     (and file (list :file file))
     (and (eq drgnx-minimap-side 'left) (list :left t))
     ;; a focused minimap stays open (`minimap-focus'), and a sticky one
     (and (or drgnx-minimap-sticky (eq window (drgnx-minimap-focus-window))) (list :open t))
     ;; the visited trail (M4): the line model's last visits as fading bars at the left edge
     (and drgnx-minimap-trail
          (list :trail (cons 'warning 0.7) :trail-length (max 1 (min 64 drgnx-minimap-trail-length))))
     ;; the heat layer (X3): Sjá's `heat:S' of the file recolours the bars on the ramp
     (and file drgnx-minimap-layer
          (list :heat (symbol-name drgnx-minimap-layer) :heat-low 'drgnx-border-strong :heat-high 'drgnx-agent-2))
     ;; the hunks' labels (X6), lines from 1 as counted now; sent again when the hunks change
     (and (length> hunks 0) (list :hunk-labels hunks :hunk 'drgnx-text-muted))
     ;; pinned regions (X5): the bands are the line model's `pin' marks (they move with edits in C); the spec names
     ;; them in buffer order
     (let ((names (and (fboundp 'drgnx-sticky-pin-names) (drgnx-sticky-pin-names (window-buffer window)))))
       (and names (list :pin-kind (cl-position 'pin drgnx-ruler-kinds) :pin 'drgnx-marks-pin
                        :pin-names (vconcat names)))))))

(defun drgnx-minimap--hub-p ()
  "Non-nil when the hub's subscribed connection is up (the labels come there)."
  (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events) (fboundp 'drgnx-hub--call-on)))

(defun drgnx-minimap--ask ()
  "What a watch asks the hub for beyond the labels: the heat layer, with the coverage reports' places or the profile
it reads."
  (and drgnx-minimap-layer
       (append (list :heat (symbol-name drgnx-minimap-layer))
               (and (eq drgnx-minimap-layer 'coverage) drgnx-minimap-coverage-files
                    (list :coverage (vconcat drgnx-minimap-coverage-files)))
               (and (eq drgnx-minimap-layer 'profile) drgnx-minimap-profile-file
                    (list :profile (expand-file-name drgnx-minimap-profile-file))))))

(defun drgnx-minimap--watch (buffer file)
  "Tell the hub BUFFER now shows FILE in a minimap (nil: none) with the heat layer asked for, when either changed."
  (with-current-buffer buffer
    (let ((ask (and file (if (drgnx-minimap-density-p) (drgnx-minimap-density-ask) (drgnx-minimap--ask)))))
      (unless (and (equal file drgnx-minimap--watched) (equal ask drgnx-minimap--asked))
        (when (drgnx-minimap--hub-p)
          (when (and drgnx-minimap--watched (not (equal file drgnx-minimap--watched)))
            ;; folding still takes that file's `folds' layer (drgnx-fold): the watch stays, without the heat
            (drgnx-hub--call-on drgnx-hub--events "minimap/watch"
                                (list :file drgnx-minimap--watched
                                      :on (if (equal drgnx-minimap--watched (bound-and-true-p drgnx-fold--watched))
                                              t :false))
                                #'ignore))
          (when file
            (drgnx-hub--call-on drgnx-hub--events "minimap/watch" (append (list :file file :on t) ask) #'ignore))
          (setq drgnx-minimap--watched file drgnx-minimap--asked ask))))))

(defun drgnx-minimap-layer (layer)
  "Show the heat LAYER on the minimap (a symbol of `drgnx-minimap-layers', or nil for none); for `profile', ask which
profile it reads."
  (interactive
   (let* ((names '(("None" . nil) ("Blame age" . blame) ("Coverage" . coverage) ("Profile…" . profile)
                   ("Lines agents read" . agent-read)))
          (layer (cdr (assoc (completing-read "Minimap heat layer: " names nil t) names))))
     (when (eq layer 'profile)
       (setq drgnx-minimap-profile-file
             (read-file-name "Profile (pprof, perf script, speedscope): " nil drgnx-minimap-profile-file t)))
     (list layer)))
  (customize-set-variable 'drgnx-minimap-layer layer)
  (drgnx-minimap--setting-changed))

;;;; The horizontal strip (design 2026-11-18 §3.1): Nidhogg draws it and decides when it shows (the window cuts its
;; lines and a line is wider than the text); Lisp names the windows that may have it, through `glitnir-hstrip'.

(defun drgnx-minimap-hstrip-window-p (window)
  "Whether WINDOW may get the horizontal strip: a scrollable surface that is an editor (no `drgnx-role', not a popup
or a child frame's, a file's or a text buffer that is not a view or a special mode), or whose buffer sets
`drgnx-hscrollbar'."
  (and drgnx-minimap-hstrip (drgnx-scrollbar-window-p window)
       (with-current-buffer (window-buffer window)
         (or drgnx-hscrollbar
             (and (not (window-parameter window 'drgnx-role)) (not (window-parameter window 'drgnx-popup))
                  (not (frame-parent (window-frame window)))
                  (not drgnx-ruler-span-function) (not (derived-mode-p 'special-mode))
                  (or buffer-file-name (derived-mode-p 'prog-mode 'text-mode 'diff-mode)))))
       t))

(defun drgnx-minimap--hstrip-spec (frame)
  "The `glitnir-hstrip' of FRAME's windows, in its device px: the strip's height, the hit lane (its bottom), the
thumb's inset, radius and least length, and its face and opacity (the vertical thumb's)."
  (list :height (drgnx-px 12 frame) :lane (drgnx-px 8 frame) :thumb-inset (drgnx-px 3 frame)
        :radius (drgnx-px 3 frame) :least (drgnx-px 24 frame) :band (cons 'drgnx-ruler-view drgnx-ruler--thumb-opacity)))

(defun drgnx-minimap-hstrip-scroll (event)
  "EVENT, (glitnir-hstrip WINDOW HSCROLL), a press or drag on WINDOW's horizontal strip: scroll it to HSCROLL columns.
Point stays, and WINDOW is not selected; Emacs keeps the scroll until point moves."
  (interactive "e")
  (let ((w (nth 1 event)) (cols (nth 2 event)))
    (when (and (window-live-p w) (natnump cols))
      (set-window-hscroll w cols))))

(defun drgnx-minimap--wraps-p (window)
  "Whether WINDOW wraps its lines now: its buffer does not truncate them, in this window, and it is not scrolled
sideways."
  (and (zerop (window-hscroll window))
       (not (buffer-local-value 'truncate-lines (window-buffer window)))
       (not (truncated-partial-width-window-p window))))

(defun drgnx-hscroll-wheel (event)
  "A sideways wheel, tilt or Shift-wheel EVENT: nothing over a window that wraps its lines (any scroll would cut
them), else `mwheel-scroll'."
  (interactive "e")
  (let ((w (posn-window (event-start event))))
    (unless (and (window-live-p w) (drgnx-minimap--wraps-p w))
      (mwheel-scroll event))))

(defun drgnx-minimap--place (window on)
  "`drgnx-ruler-place-functions': WINDOW's minimap and horizontal strip as they should be now, given that it shows
the strip (ON)."
  (let ((hs (and on (drgnx-minimap-hstrip-window-p window) (drgnx-minimap--hstrip-spec (window-frame window)))))
    (unless (equal hs (window-parameter window 'glitnir-hstrip))
      (set-window-parameter window 'glitnir-hstrip hs)))
  (cond
   ;; past the density limit (M7): no line model, the hub's density strip of the file on disk
   ((and on (drgnx-minimap-window-p window) (drgnx-minimap-density-p (window-buffer window)))
    (let* ((buffer (window-buffer window)) (file (drgnx-minimap--file buffer))
           (spec (and file (drgnx-minimap-density-spec window file))))
      (unless (equal spec (window-parameter window 'glitnir-minimap))
        (set-window-parameter window 'glitnir-minimap spec))
      (drgnx-minimap--reserve window nil)
      (drgnx-minimap--watch buffer file)))
   ((and on (drgnx-minimap-window-p window))
    (let ((buffer (window-buffer window)))
      (with-current-buffer buffer
        (nidhogg-lines-enable)
        (drgnx-minimap--highlight)
        (let ((re (and drgnx-minimap-labels drgnx-minimap-mark-regexp)))
          (unless (equal re drgnx-minimap--regexp)
            (setq drgnx-minimap--regexp re)
            (condition-case err
                (nidhogg-lines-set-section-regexp nil re)
              (error (drgnx-notify 'minimap 'warn (format "Minimap MARK regexp: %s" (error-message-string err))
                                   :id 'mark-regexp))))))
      (let ((spec (drgnx-minimap--spec window)))
        (unless (equal spec (window-parameter window 'glitnir-minimap))
          (set-window-parameter window 'glitnir-minimap spec))
        (drgnx-minimap--watch buffer (plist-get spec :file)))
      (drgnx-minimap--reserve window t)))
   ((window-parameter window 'glitnir-minimap)
    (set-window-parameter window 'glitnir-minimap nil)
    (drgnx-minimap--reserve window nil))))

(defun drgnx-minimap--off ()
  "Every window's minimap gone, and the hub told no file is shown in one."
  (dolist (f (frame-list))
    (dolist (w (window-list f 'nomini))
      (when (window-parameter w 'glitnir-minimap) (set-window-parameter w 'glitnir-minimap nil))
      (when (window-parameter w 'drgnx-ruler-reserve) (drgnx-ruler-reserve w nil))
      (when (window-parameter w 'glitnir-hstrip) (set-window-parameter w 'glitnir-hstrip nil))))
  (dolist (b (buffer-list))
    (when (buffer-local-value 'drgnx-minimap--watched b) (drgnx-minimap--watch b nil))
    (with-current-buffer b (kill-local-variable 'drgnx-minimap--asked))
    (when (local-variable-p 'nidhogg-treesit-highlight-query b)
      (with-current-buffer b (kill-local-variable 'nidhogg-treesit-highlight-query))))
  (clrhash drgnx-minimap--queries))

(defconst drgnx-minimap--commands
  '((mark-next "Next Mark" drgnx-marks-next "Go to the next mark of any kind on the scroll bar")
    (mark-previous "Previous Mark" drgnx-marks-previous "Go to the previous mark of any kind on the scroll bar")
    (change-next "Next Change" drgnx-marks-next-change "Go to the next change against the last commit")
    (change-previous "Previous Change" drgnx-marks-previous-change "Go to the previous change against the last commit")
    (bookmark-next "Next Bookmark" drgnx-marks-next-bookmark "Go to the next bookmark in this file")
    (bookmark-previous "Previous Bookmark" drgnx-marks-previous-bookmark "Go to the previous bookmark in this file")
    (bookmark-toggle "Toggle Bookmark" drgnx-marks-bookmark-toggle "Set a bookmark on this line, or clear it")
    (bookmark-name "Name Bookmark…" drgnx-marks-bookmark-name "Name the bookmark on this line")
    (bookmark-go "Go to Bookmark…" drgnx-marks-bookmark-go "Go to a bookmark, this file's first")
    (agent-edit-next "Next Agent Edit" drgnx-marks-next-agent-edit "Go to the next place an agent edited in this file")
    (agent-edit-previous "Previous Agent Edit" drgnx-marks-previous-agent-edit
                         "Go to the previous place an agent edited in this file")
    (minimap-layer "Minimap Heat Layer…" drgnx-minimap-layer
                   "Recolour the minimap by blame age, coverage, a profile or the lines agents read, or turn that off")
    (minimap-describe "Describe Position" drgnx-minimap-describe
                      "Say the section at point, its marks and the minimap's heat value there")
    (trail-clear "Clear Visited Trail" drgnx-minimap-trail-clear "Clear this file's visited trail on the minimap")
    (minimap-focus "Focus Minimap" drgnx-minimap-focus
                   "Keep the minimap open and move, search, peek and fold in it with keys"))
  "The module's commands: (ID TITLE FUNCTION DOC) each.")

(defconst drgnx-minimap--map-commands
  '((minimap-focus-down "Minimap: Down" drgnx-minimap-focus-down drgnx-minimap-focus-map
                        "Move the focused minimap's row down")
    (minimap-focus-up "Minimap: Up" drgnx-minimap-focus-up drgnx-minimap-focus-map "Move the focused minimap's row up")
    (minimap-focus-search "Minimap: Search" drgnx-minimap-focus-search drgnx-minimap-focus-map
                          "Search the file and mark the hits on the focused minimap")
    (minimap-focus-next "Minimap: Next Hit" drgnx-minimap-focus-next drgnx-minimap-focus-map
                        "Move the focused minimap's row to the next search hit")
    (minimap-focus-previous "Minimap: Previous Hit" drgnx-minimap-focus-previous drgnx-minimap-focus-map
                            "Move the focused minimap's row to the previous search hit")
    (minimap-focus-peek "Minimap: Peek" drgnx-minimap-focus-peek drgnx-minimap-focus-map
                        "Peek at the focused minimap's row")
    (minimap-focus-fold "Minimap: Fold" drgnx-minimap-focus-fold drgnx-minimap-focus-map
                        "Fold or unfold the range at the focused minimap's row")
    (minimap-focus-go "Minimap: Go" drgnx-minimap-focus-go drgnx-minimap-focus-map
                      "Go to the focused minimap's row and leave the minimap")
    (minimap-focus-leave "Minimap: Leave" drgnx-minimap-focus-leave drgnx-minimap-focus-map
                         "Leave the minimap: point back where it was")
    (minimap-card-jump "Minimap Peek: Go" drgnx-minimap-card-jump drgnx-minimap-card-map "Go to the peeked line")
    (minimap-card-close "Minimap Peek: Close" drgnx-minimap-card-hide drgnx-minimap-card-map "Close the minimap's peek")
    (minimap-bucket-jump "Minimap Part: Go" drgnx-minimap-bucket-jump drgnx-minimap-bucket-map
                         "Go to the peeked part of a huge file, when the buffer holds it")
    (minimap-bucket-close "Minimap Part: Close" drgnx-minimap-card-hide drgnx-minimap-bucket-map
                          "Close the peek of a huge file's part")
    (minimap-chip-copy "Minimap Selection: Copy" drgnx-minimap-chip-copy drgnx-minimap-chip-map
                       "Copy the minimap's selected lines")
    (minimap-chip-fold "Minimap Selection: Fold" drgnx-minimap-chip-fold drgnx-minimap-chip-map
                       "Fold the minimap's selected lines")
    (minimap-chip-pin "Minimap Selection: Pin" drgnx-minimap-chip-pin drgnx-minimap-chip-map
                      "Pin the minimap's selected lines")
    (minimap-chip-ask "Minimap Selection: Ask Agent" drgnx-minimap-chip-ask drgnx-minimap-chip-map
                      "Ask an agent about the minimap's selected lines")
    (minimap-chip-close "Minimap Selection: Close" drgnx-minimap-card-hide drgnx-minimap-chip-map
                        "Close the selection's chip"))
  "The keys of the minimap's focus, peek, part peek and selection chip: (ID TITLE FUNCTION MAP DOC) each.  Their keys
come from the profiles (`:map' rows); the maps bind only the mouse in code.")

(defun drgnx-minimap--teardown ()
  "The scroll bar and the marks' producers off; every window's strip gone."
  (drgnx-marks-off)
  (drgnx-minimap-peek-off)
  (drgnx-minimap-search-off)
  (drgnx-minimap-density-off)
  (remove-hook 'drgnx-ruler-place-functions #'drgnx-minimap--place)
  (when (eq (lookup-key special-event-map [glitnir-hstrip]) #'drgnx-minimap-hstrip-scroll)
    (define-key special-event-map [glitnir-hstrip] nil t))
  (drgnx-minimap--off)
  (remove-hook 'drgnx-look-density-changed-hook #'drgnx-scrollbar-refresh-all)
  (drgnx-scrollbar-mode -1))

(drgnx-module-define 'editor/minimap
                     :doc "The scroll bar on every scrollable surface: the thumb and the file's marks (changes, problems, search hits)."
                     :stage 'startup
                     :teardown #'drgnx-minimap--teardown
                     :setup (lambda ()
                              (pcase-dolist (`(,id ,title ,fn ,doc) drgnx-minimap--commands)
                                (drgnx-command-define id :category "Go" :title title :command fn :scope 'editing
                                                      :doc doc))
                              (pcase-dolist (`(,id ,title ,fn ,map ,doc) drgnx-minimap--map-commands)
                                (drgnx-command-define id :category "Go" :title title :command fn :map map
                                                      :scope 'editing :doc doc))
                              (add-hook 'drgnx-ruler-place-functions #'drgnx-minimap--place)
                              ;; the horizontal strip: Nidhogg's press and drag events, the sideways wheel and tilt
                              (define-key special-event-map [glitnir-hstrip] #'drgnx-minimap-hstrip-scroll)
                              (dolist (k '([wheel-left] [wheel-right] [S-wheel-up] [S-wheel-down]))
                                (drgnx-module-define-key 'global-map k #'drgnx-hscroll-wheel))
                              (drgnx-module-set 'mouse-wheel-tilt-scroll t)
                              (drgnx-scrollbar-mode 1)
                              (add-hook 'drgnx-look-density-changed-hook #'drgnx-scrollbar-refresh-all)
                              (drgnx-marks-on)
                              (drgnx-minimap-peek-on)
                              (drgnx-minimap-search-on)
                              (drgnx-minimap-density-on)))

(provide 'drgnx-minimap)
;;; drgnx-minimap.el ends here
