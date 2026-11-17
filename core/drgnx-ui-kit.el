;;; drgnx-ui-kit.el --- The UI kit: glyphs by meaning, status faces, buttons -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What every surface that draws a mark shares, in core, so the status bar, the lists and the notices never
;; depend on the `ui/face' module being loaded.  Glyphs are by meaning: `close' is the mark of a close button,
;; `fail' is "tests failed", `dismiss' is "dismiss this notice" -- restyling one leaves the others alone.  Each
;; glyph has an ASCII form for terminals that do not write UTF-8.  The status faces inherit theme faces.  A button
;; runs a registry command, a command or a function; the close button is the `close' glyph on a header line.
;; The components (etc/ui/components.eld) are read here: the state table, each component's geometry, and the kit
;; faces generated from the file's colour bindings.
;; The file is not `drgnx-ui.el': that is the harness's feature (harness/drgnx-ui.el), and the test runner has both on its
;; `load-path'.  See docs/develop/core.md ("The UI kit") and docs/guide/face.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-registry)
(require 'drgnx-modules-helpers)        ; the aliases' face specs (`drgnx-module-face-spec')
(require 'drgnx-surfaces)
(require 'drgnx-faces)
(require 'drgnx-type-faces)
(require 'drgnx-pixels)
(require 'face-remap)

(defconst drgnx-ui--icon-glyphs
  ;; one per icon of etc/icons (`drgnx-look-icon'): the glyph a terminal frame or the setting `glyphs' shows
  '((file-code "‹›" . "<>") (file-text "≡" . "=") (file-cog "⚙" . "*") (file-image "▣" . "#") (file-archive "▥" . "z")
    (file "▯" . "-") (folder "▪" . "/") (folder-open "▫" . "/") (folder-git-2 "▪" . "/")
    (chevron-right "›" . ">") (chevron-left "‹" . "<") (chevron-down "⌄" . "v") (chevron-up "⌃" . "^")
    (plus "+" . "+") (minus "−" . "-") (ellipsis "…" . "...") (x "×" . "x") (check "✓" . "+") (replace-all "⇗" . "/")
    (git-branch "⑂" . "Y") (git-merge "⑃" . "Y") (git-pull-request "⇄" . "<>") (git-commit-horizontal "○" . "o")
    (circle-x "✕" . "X") (triangle-alert "⚠" . "!") (circle-check "✓" . "+") (circle-alert "!" . "!")
    (layers "☰" . "=") (grip-vertical "⠿" . "::") (maximize-2 "▢" . "[]") (minimize-2 "–" . "-")
    (message-square "▭" . "m") (scroll-text "≣" . "=") (list-checks "☑" . "x")
    (monitor "▭" . "M") (laptop "▭" . "L") (server "☰" . "S") (globe "◍" . "@") (brain "◉" . "B")
    (lightbulb "◌" . "i") (pencil "✎" . "e") (clock "◷" . "t") (bot "◈" . "b") (pin "⌖" . "p")
    (circle-dot "◉" . "o") (play "▶" . ">") (pause "⏸" . "||") (git-fork "⑂" . "Y") (arrow-up "↑" . "^") (sparkle "✦" . "*") (square "■" . "#") (refresh-cw "↻" . "r")
    (trash-2 "⌫" . "d") (copy "⎘" . "c") (settings "⚙" . "*") (terminal "›_" . ">_") (bell "◔" . "!")
    (eye "◉" . "o") (lock "▮" . "#") (tag "⌗" . "#") (shield "⛨" . "!") (panel-right "◫" . "|") (panel-left "◧" . "|=") (panel-bottom "▬" . "_") (menu "☰" . "=")
    (triangle "▲" . "^") (hexagon "⬢" . "H") (star "★" . "*") (flask-conical "⚗" . "T")
    ;; the debug toolbar's (step over, into, out; restart; the session's bug; disconnect)
    (redo-dot "↷" . ">") (arrow-down-to-dot "↓" . "v") (arrow-up-from-dot "↑" . "^") (rotate-ccw "↺" . "r")
    (bug "✱" . "*") (unplug "⏏" . "x")
    ;; Send Run's card and a sent run's chip
    (send "➤" . ">") (key "⚿" . "k") (inbox "⊔" . "u") (braces "{}" . "{}")
    ;; the heap graph's header
    (workflow "⧉" . "#")
    ;; the Search view's kind chips, as the hub's kind icons on definition rows
    (square-function "ƒ" . "f") (type "◇" . "T") (wand "#" . "#") (variable "≡" . "=")
    ;; the Extensions list's kinds (a package's is `package''s, below)
    (plug "◆" . "&") (blocks "▣" . "M"))
  "The glyphs of the icons (NAME → (UNICODE . ASCII)), named after the icon files.  Several look alike on a terminal
that is not UTF-8: an icon's glyph says less than its picture.  The icon names that exist as glyphs already
\(`circle', `search', `info', `flag') are in the table below.")

(defconst drgnx-ui--default-glyphs
  (append
   '((handle "⠿" . "::") (close "×" . "x") (branch "⑂" . "Y") (warning "⚠" . "!") (ok "✓" . "+")
     (busy "◎" . "@") (waiting "◐" . "?") (paused "⏸" . "||") (ahead "↑" . "^") (behind "↓" . "v")
     (dot "●" . "*") (circle "○" . "o") (sep " · " . " | ") (flag "⚑" . "#") (newline "⏎" . "\\n")
     (dash "—" . "--") (arrow-left "←" . "<-") (empty-set "∅" . "{}")
     (diamond "◆" . "<>") (search "⌕" . "/") (bullet "•" . ">") (minimize "–" . "-") (maximize "▢" . "[]")
     (fail "✕" . "X") (stopped "■" . "#") (dismiss "×" . "x") (unqueue "−" . "-")
     (info "ℹ" . "i") (warn "⚠" . "!") (cloud "☁" . "c")
     (package "⬡" . "P") (plugin "◆" . "&") (module "▣" . "M")
     (refused "⛔" . "X") (note "✎" . "n") (changed "↻" . "~") (hook-busy "⏳" . "...")
     ;; the find bar's previous and next match buttons and its Symbol toggle
     (match-previous "↑" . "^") (match-next "↓" . "v") (rename-symbol "⟨⟩" . "<>")
     ;; the Search view's: a chip that opens a menu, Changed Lines Only, Save This Search and a saved search
     (dropdown "▾" . "v") (changed-lines "±" . "+-") (save-search "☆" . "*"))
   drgnx-ui--icon-glyphs)
  "The standard glyph table: the default of `drgnx-face-glyphs', and where a name the option lacks is found.")

(defcustom drgnx-face-glyphs drgnx-ui--default-glyphs
  "The glyphs drgnx draws: NAME → (UNICODE . ASCII).  The ASCII form is used on a terminal frame that is not UTF-8.
One glyph per meaning: `close' (a close button), `fail' (something failed), `dismiss' (dismiss a notice) and
`unqueue' (take a queued message back) look alike by default and are separate so each can be restyled alone.
Change one to suit your font; `drgnx-face-glyph' reads this.  A name missing here (a value saved before drgnx
added it) is drawn from the standard table."
  :type '(alist :key-type symbol :value-type (cons (string :tag "Unicode") (string :tag "ASCII")))
  :group 'drgnx)

(defun drgnx-ui-ascii-frame-p (&optional frame)
  "Non-nil when FRAME (default: the selected one) is a terminal frame whose terminal does not write UTF-8."
  (let ((frame (or frame (selected-frame))))
    (and (not (display-graphic-p frame))
         (let ((coding (terminal-coding-system (frame-terminal frame))))
           (not (and coding (string-prefix-p "utf-8" (symbol-name (coding-system-base coding)))))))))

(defun drgnx-face-glyph (name &optional frame)
  "The glyph NAME (see `drgnx-face-glyphs') as a string: its ASCII form on a terminal frame that is not UTF-8.
FRAME defaults to the selected one.  A NAME the option lacks comes from `drgnx-ui--default-glyphs'; nil when
neither has it."
  (when-let* ((g (or (alist-get name drgnx-face-glyphs) (alist-get name drgnx-ui--default-glyphs))))
    (if (drgnx-ui-ascii-frame-p frame) (cdr g) (car g))))

;;;; Status

(defface drgnx-status-ok '((t :inherit success)) "Something is fine." :group 'drgnx)
(defface drgnx-status-info '((t :inherit shadow)) "Something to know." :group 'drgnx)
(defface drgnx-status-warn '((t :inherit warning)) "Something to look at." :group 'drgnx)
(defface drgnx-status-fail '((t :inherit error)) "Something failed." :group 'drgnx)
(defface drgnx-status-needs-you '((t :inherit drgnx-status-attention)) "Something waits for you." :group 'drgnx)

(defconst drgnx-ui--severities
  '((ok ok drgnx-status-ok) (info info drgnx-status-info) (warn warn drgnx-status-warn)
    (fail fail drgnx-status-fail) (needs-you waiting drgnx-status-needs-you))
  "SEVERITY → (GLYPH-NAME FACE).")

(defun drgnx-ui-status (severity &optional text)
  "The glyph for SEVERITY (ok, info, warn, fail or needs-you), then a space and TEXT when given, in its status face.
An unknown SEVERITY is `info'."
  (pcase-let ((`(,_ ,glyph ,face) (or (assq severity drgnx-ui--severities) (assq 'info drgnx-ui--severities))))
    (propertize (if text (concat (drgnx-face-glyph glyph) " " text) (drgnx-face-glyph glyph)) 'face face)))

;;;; Buttons

(defface drgnx-ui-button '((t :inherit (drgnx-ui-text drgnx-control)))
  "A button drawn by the UI kit (`drgnx-ui-button'): the look's control, in the UI text role." :group 'drgnx)
(defface drgnx-ui-button-primary '((t :inherit (drgnx-ui-text drgnx-control-primary)))
  "The primary button of a group (`drgnx-ui-button' with this face): filled with the accent." :group 'drgnx)

(defface drgnx-ui-close '((t :inherit shadow))
  "The close button (×) of a title, tab row or popup header (`drgnx-ui-close-button')." :group 'drgnx)

(defvar drgnx-ui--button-maps (make-hash-table :test #'eq :weakness 'key)
  "ACTION → alist WHERE → the keymap of a button that runs ACTION.  Weak: a closure's maps go with it.")

(defun drgnx-ui-kit-run (action)
  "Run ACTION: a registry id through `drgnx-surfaces-run' (the usage count and the key tip follow), else a command
called interactively, else a function of no arguments.  A symbol that is none of these (its module is off) says so."
  (cond ((and (symbolp action) (drgnx-commands-get action)) (drgnx-surfaces-run action))
        ((commandp action) (call-interactively action))
        ((and (symbolp action) (not (fboundp action))) (user-error "%s is not available (its module is off)" action))
        (t (funcall action))))

(defun drgnx-ui--button-map (action where)
  "The keymap of a button that runs ACTION on WHERE, built once per (ACTION . WHERE)."
  (let ((maps (gethash action drgnx-ui--button-maps)))
    (or (alist-get where maps)
        (let ((m (make-sparse-keymap)) (run (lambda () (interactive) (drgnx-ui-kit-run action))))
          (if (eq where 'text)
              (progn (define-key m [mouse-1] run) (define-key m [mouse-2] run) (define-key m (kbd "RET") run))
            (define-key m (vector where 'mouse-1) run))
          (puthash action (cons (cons where m) maps) drgnx-ui--button-maps)
          m))))

(defconst drgnx-ui-button-height 26
  "A button's height with its 1 px ring, in logical pixels (design §3.5 `.btn').  The room's stretch is this tall:
the ring does not add to a stretch's height.")

(defun drgnx-ui-button-pad (face &optional frame)
  "The `display' of the room at either end of a button in FACE on FRAME: 11 logical pixels (12 with the ring), and on
a graphical frame as tall as `drgnx-ui-button-height', the text centred in it."
  (let* ((scale (drgnx-pixels-scale frame)) (width (list (round (* scale 11))))
         (height (round (* scale drgnx-ui-button-height)))
         (extent (drgnx-pixels-font-extent face frame)))
    (if (and extent (> height (+ (car extent) (cdr extent))))
        (let* ((below (+ (cdr extent) (/ (- height (car extent) (cdr extent)) 2))))
          `(space :width ,width :height (,height) :ascent ,(min 100 (ceiling (* 100.0 (- height below)) height))))
      `(space :width ,width))))

(defun drgnx-ui-button-focus-box ()
  "The box of a button that has the focus (look.css `.btn.focus'): the theme's `drgnx-focus' ring, 2 px inside, with
the button's corners where Glitnir rounds them; nil when the theme gives no ring."
  (let ((ring (face-attribute 'drgnx-focus :box nil t)) (w (drgnx-pixels-box-width (- (drgnx-px-line 2)))))
    (when (stringp (plist-get ring :color))
      `(:line-width (,w . ,w) :color ,(plist-get ring :color)
                    ,@(and (fboundp 'glitnir-active-p) (glitnir-active-p) (list :corner-radius (drgnx-px 6)))))))

(declare-function glitnir-active-p "glitnir")

(cl-defun drgnx-ui-button (label action &key help face (where 'text) props focus)
  "LABEL as a button that runs ACTION: a registry id (run as from the palette, so its use is counted), a command, or
a function of no arguments.  WHERE is `text' (`mouse-1' and RET), `header-line', `mode-line' or `tab-line' (`mouse-1'
there).  FACE defaults to `drgnx-ui-button' (`drgnx-ui-button-primary' for a group's main action); HELP is the
`help-echo'; PROPS are more text properties.  FOCUS non-nil rings the button as the one RET presses (a card's
default, `drgnx-ui-button-focus-box').  In text the label has room inside the button at either end
\(`drgnx-ui-button-pad'); on a line (header, mode, tab) it is the label alone."
  (let* ((face (or face 'drgnx-ui-button)) (box (and focus (drgnx-ui-button-focus-box)))
         (label (if (eq where 'text)
                    (let ((pad (propertize " " 'display (drgnx-ui-button-pad face))))
                      (concat pad label pad))
                  label)))
    (apply #'propertize label 'face (if box `(:inherit ,face :box ,box) face) 'mouse-face 'highlight 'help-echo help
           (if (eq where 'text) 'keymap 'local-map) (drgnx-ui--button-map action where)
           (append (and (eq where 'text) '(follow-link t)) props))))

(defun drgnx-ui-insert-button (label action &rest keys)
  "Insert at point the button `drgnx-ui-button' makes of LABEL, ACTION and KEYS."
  (insert (apply #'drgnx-ui-button label action keys)))

(defvar drgnx-ui--close-maps nil "Alist (COMMAND . WHERE) → the keymap of a close button that runs COMMAND.")

(cl-defun drgnx-ui-close-button (command help &key (where 'header-line) props)
  "The `close' glyph as a button on WHERE (default `header-line'; or `mode-line', `tab-line', `text'): `mouse-1' runs
COMMAND itself, so it gets the click event.  HELP is its `help-echo'; PROPS are text properties the command reads.
Build it when a title or row is set, never while drawing."
  (let* ((key (cons command where))
         (map (or (alist-get key drgnx-ui--close-maps nil nil #'equal)
                  (let ((m (make-sparse-keymap)))
                    (define-key m (if (eq where 'text) [mouse-1] (vector where 'mouse-1)) command)
                    (setf (alist-get key drgnx-ui--close-maps nil nil #'equal) m)))))
    (apply #'propertize (drgnx-face-glyph 'close) 'face 'drgnx-ui-close 'mouse-face 'highlight
           (if (eq where 'text) 'keymap 'local-map) map 'help-echo help props)))

;;;; Components: etc/ui/components.eld

;; The reader and the face list are needed when this file is compiled: `drgnx-ui-kit-define-faces' expands to one
;; `defface' per kit face, read from the file then.
(eval-and-compile
  (defconst drgnx-ui-kit-file (expand-file-name "etc/ui/components.eld" drgnx-dir)
    "The kit's components: the state table and one entry per component (docs/develop/core.md, \"The UI kit\").")

  (defun drgnx-ui-kit--read (&optional file)
    "The components FILE (default `drgnx-ui-kit-file') as data: ((state-table . STATES) (components . ENTRIES))."
    (let ((r (drgnx-file-read (or file drgnx-ui-kit-file))))
      (unless (eq (plist-get r :status) 'ok)
        (error "drgnx: the components file %s is %s" (or file drgnx-ui-kit-file) (plist-get r :status)))
      (plist-get r :data)))

  (defun drgnx-ui-kit--colours (binding)
    "The colours BINDING ((VALUE...) :bg :fg :edge ...) names, as (BG FG EDGE)."
    (list (plist-get (cdr binding) :bg) (plist-get (cdr binding) :fg) (plist-get (cdr binding) :edge)))

  (defun drgnx-ui-kit-face-bindings (&optional table)
    "((FACE ID BINDING-PLIST)...): the kit faces of TABLE (default the components file), in its order.
A component's binding of () is its face `drgnx-kit-ID'; another binding, of variant values V..., is
`drgnx-kit-ID-V...' and is made only when its colours differ from the component's own (size is geometry, never a face)."
    (let (out)
      (dolist (c (alist-get 'components (or table (drgnx-ui-kit-components))))
        (let* ((binds (plist-get (cdr c) :bind)) (own (assq nil binds)))
          (dolist (b binds)
            (when (or (eq b own) (not own)
                      (not (equal (drgnx-ui-kit--colours b) (drgnx-ui-kit--colours own))))
              (push (list (intern (mapconcat #'symbol-name (cons (car c) (car b)) "-" ))
                          (car c) (cdr b))
                    out)))))
      (mapcar (lambda (f) (cons (intern (format "drgnx-kit-%s" (car f))) (cdr f))) (nreverse out)))))

(defvar drgnx-ui-kit--table nil "The components file once read (`drgnx-ui-kit-components').")

(defun drgnx-ui-kit-components ()
  "The components file as data, read once: ((state-table . STATES) (components . ENTRIES))."
  (or drgnx-ui-kit--table (setq drgnx-ui-kit--table (drgnx-ui-kit--read))))

(defconst drgnx-ui-kit-states '(rest hover pressed selected selected-inactive focus-visible disabled)
  "The state table's states, in its order (spec §7.3).")

(defun drgnx-ui-kit-state (state)
  "STATE's plist in the state table: :fill, :radius, :ring, :fg, :face and :tty."
  (cdr (assq state (alist-get 'state-table (drgnx-ui-kit-components)))))

(defun drgnx-ui-kit-state-face (state)
  "The semantic face that draws STATE (the state table's :face), or nil (rest)."
  (plist-get (drgnx-ui-kit-state state) :face))

(defun drgnx-ui-kit-row-box (&optional ring)
  "A row's `:box': inside the row (negative widths, so nothing moves when it appears), in the fill's own colour (a
flat button: only its rounded corners show), or with RING (a colour) a 1 px ring in it; rounded (the state table's
radius, 6) where Glitnir draws."
  (let ((w (drgnx-pixels-box-width (- (drgnx-px-line 1)))) (glitnir (and (fboundp 'glitnir-active-p) (glitnir-active-p))))
    `(:line-width (,w . ,w) ,@(if (and ring glitnir) (list :color ring) '(:style flat-button))
                  ,@(and glitnir (list :corner-radius (drgnx-px (or (plist-get (drgnx-ui-kit-state 'selected) :radius) 6)))))))

(defvar drgnx-ui-kit--row-faces (make-hash-table :test #'equal)
  "(STATE LINE RADIUS GLITNIR) → a row's face in STATE (`drgnx-ui-kit-row-face'): a handful per scale, cleared past 32.")

(defun drgnx-ui-kit-row-face (state)
  "STATE's face on a row: its semantic face (`drgnx-ui-kit-state-face') in the row's rounded inside box, in the fill's
own colour (no visible edge); `drgnx-row-selected' for `selected', which follows the window's focus
\(`drgnx-ui-kit-focus-remap').  The same object per state and scale."
  (let* ((face (if (eq state 'selected) 'drgnx-row-selected (drgnx-ui-kit-state-face state)))
         (key (list state (drgnx-px-line 1) (drgnx-px 6) (and (fboundp 'glitnir-active-p) (glitnir-active-p)))))
    (and face
         (or (gethash key drgnx-ui-kit--row-faces)
             (progn (when (> (hash-table-count drgnx-ui-kit--row-faces) 32) (clrhash drgnx-ui-kit--row-faces))
                    (puthash key `(:inherit ,face :box ,(drgnx-ui-kit-row-box)) drgnx-ui-kit--row-faces))))))

;; A list's selection is `drgnx-row-selected' (the inactive selection); while the list's window is the selected one it
;; is remapped to the full selection, so an unfocused list still shows where it is (VS Code's inactive selection).
(defvar-local drgnx-ui-kit--focus-cookie nil "The remap of `drgnx-row-selected' while this buffer's window is selected.")

(defun drgnx-ui-kit-focus-remap (window)
  "`window-selection-change-functions' (buffer-local): `drgnx-row-selected' in WINDOW's buffer is the full selection
while that buffer shows in the selected window, else the inactive one."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (let ((focused (eq (window-buffer (selected-window)) (current-buffer))))
        (cond ((and focused (not drgnx-ui-kit--focus-cookie))
               (setq drgnx-ui-kit--focus-cookie (face-remap-add-relative 'drgnx-row-selected 'drgnx-selected)))
              ((and (not focused) drgnx-ui-kit--focus-cookie)
               (face-remap-remove-relative drgnx-ui-kit--focus-cookie)
               (setq drgnx-ui-kit--focus-cookie nil)))))))

(defun drgnx-ui-kit-focus-remap-enable ()
  "Make the current buffer's `drgnx-row-selected' follow its window's focus (`drgnx-ui-kit-focus-remap')."
  (add-hook 'window-selection-change-functions #'drgnx-ui-kit-focus-remap nil t)
  (when-let* ((w (get-buffer-window nil t))) (drgnx-ui-kit-focus-remap w)))

(defun drgnx-ui-kit-component (id)
  "The entry of component ID: a plist of :variants, :defaults, :geometry, :tty, :label, :bind, :replaces, :helpers
and :lint."
  (cdr (assq id (alist-get 'components (drgnx-ui-kit-components)))))

(defun drgnx-ui-kit--chosen (entry variants)
  "AXIS → VALUE for ENTRY: its defaults, each of VARIANTS (variant values) put on the axis that has it."
  (let ((chosen nil) (d (plist-get entry :defaults)))
    (while d (push (cons (car d) (cadr d)) chosen) (setq d (cddr d)))
    (dolist (v variants chosen)
      (dolist (axis (plist-get entry :variants))
        (when (memq v (cdr axis)) (setf (alist-get (car axis) chosen) v))))))

(declare-function drgnx-look-density-value "drgnx-look-density" (key &optional density))

(defun drgnx-ui-kit--value (value chosen)
  "VALUE of a geometry key resolved for CHOSEN (AXIS → VALUE): a (:by AXIS (V X)...) case, a (density KEY) size (nil
without ui/look), or VALUE itself."
  (pcase value
    (`(:by ,axis . ,cases) (drgnx-ui-kit--value (cadr (assq (alist-get axis chosen) cases)) chosen))
    (`(density ,key) (and (fboundp 'drgnx-look-density-value) (drgnx-look-density-value key)))
    (_ value)))

(defun drgnx-ui-kit-geometry (id variants)
  "Component ID's geometry for VARIANTS (a list of variant values; the defaults fill the other axes): a plist of
logical px (:height :pad :gap :box :radius :line-height :hit :indent), every per-variant and density value resolved."
  (let* ((entry (drgnx-ui-kit-component id)) (chosen (drgnx-ui-kit--chosen entry variants))
         (g (plist-get entry :geometry)) (out nil))
    (while g
      (setq out (plist-put out (car g) (drgnx-ui-kit--value (cadr g) chosen)) g (cddr g)))
    out))

(defmacro drgnx-ui-kit-define-faces ()
  "Define every kit face of etc/ui/components.eld, as the file stood when this was compiled.
Each inherits its binding's standard faces, so any theme styles it; drgnx's themes give it the bindings' token
colours (`drgnx-ui-kit-theme-specs')."
  `(progn
     ,@(mapcar (lambda (f)
                 `(defface ,(car f) '((t :inherit ,(plist-get (nth 2 f) :inherit)))
                    ,(format "The kit's `%s' component (etc/ui/components.eld)." (nth 1 f))
                    :group 'drgnx))
               (drgnx-ui-kit-face-bindings (drgnx-ui-kit--read)))))

(drgnx-ui-kit-define-faces)

(defun drgnx-ui-kit-theme-specs (tok &optional table)
  "((FACE . ATTRIBUTES)...) of the kit faces of TABLE (default the components file) for one of drgnx's themes: the
bindings' tokens as colours through TOK (a token name → a colour), the edge as a 1 px box inside the face.  A
binding with no colours (the row's: a font only) keeps its `:inherit' (a theme's spec replaces the `defface''s)."
  (mapcar (lambda (f)
            (let ((b (nth 2 f)))
              `(,(car f)
                ;; a binding with colours keeps only its font faces (`:font': the UI or code font, no colours) of its
                ;; `:inherit', which a third-party theme styles through; one without colours keeps all of it
                ,@(let ((inh (if (or (plist-get b :bg) (plist-get b :fg) (plist-get b :edge))
                                 (plist-get b :font)
                               (plist-get b :inherit))))
                    (and inh `(:inherit ,inh)))
                ,@(and (plist-get b :bg) `(:background ,(funcall tok (plist-get b :bg))))
                ,@(and (plist-get b :fg) `(:foreground ,(funcall tok (plist-get b :fg))))
                ,@(and (plist-get b :edge) `(:box (:line-width (-1 . -1) :color ,(funcall tok (plist-get b :edge))))))))
          (drgnx-ui-kit-face-bindings table)))

(defun drgnx-ui-kit-replaced-faces (&optional table)
  "The faces the landed components of TABLE (default the components file; `:lint t') replace: drgnx's themes no
longer style them, their kit faces do."
  (let (out)
    (dolist (c (alist-get 'components (or table (drgnx-ui-kit-components))) (nreverse out))
      (when (eq (plist-get (cdr c) :lint) t)
        (dolist (r (plist-get (cdr c) :replaces)) (push (car r) out))))))


(defun drgnx-ui-kit-define-aliases (&optional table)
  "Each face a component of TABLE (default the components file) `:replaces' inherits its kit face: its default spec
becomes ((t :inherit KIT-FACE)), set through `drgnx-module-face-spec' (undone with the module that calls this).  The
`defface' stays where it is, so what the user customized on the old name still applies.  Faces not defined yet are
skipped.  Returns the faces it set."
  (let (done)
    (dolist (c (alist-get 'components (or table (drgnx-ui-kit-components))) (nreverse done))
      (pcase-dolist (`(,old . ,kit) (plist-get (cdr c) :replaces))
        (when (facep old)
          (drgnx-module-face-spec old `((t :inherit ,kit)))
          (push old done))))))

(defun drgnx-ui-kit-glyph-names (&optional table)
  "The glyph names the components of TABLE (default the components file) draw (:tty :glyph and :twisty), in order, each
once: the glyphs a view's env sends (`ViewEnv.glyphs') and the hub's table falls back on (`kit_gen::GLYPHS')."
  (let (names)
    (dolist (c (alist-get 'components (or table (drgnx-ui-kit-components))))
      (let ((tty (plist-get (cdr c) :tty)))
        (dolist (v (list (plist-get tty :glyph) (plist-get tty :twisty)))
          (dolist (g (drgnx-ui-kit--glyphs-in v))
            (unless (memq g names) (push g names))))))
    (nreverse names)))

(defun drgnx-ui-kit--glyphs-in (value)
  "The glyph names in VALUE: a name, a list of names, or a (:by AXIS (V X)...) case of them."
  (cond ((null value) nil)
        ((symbolp value) (list value))
        ((eq (car value) :by) (apply #'append (mapcar (lambda (c) (drgnx-ui-kit--glyphs-in (cadr c))) (cddr value))))
        (t (cl-remove-if-not #'symbolp value))))

;;;; The expansion: the hub's (drgnx_rows::kit), for Lisp-drawn chrome

;; A component and its props (the hub's `Comp' JSON as a plist: `:c' "row", `:kind' "tree"...) expand to a row's
;; pieces: its text, face runs, properties and spaces, exactly as the hub's expansion makes them; the conformance
;; fixture (test/fixtures/kit) keeps the two equal.  Pads are spaces of device px at the scale, each part rounded half
;; up (`drgnx-px'); on a terminal they are characters and glyphs take their terminal form.  Called per row: positional
;; arguments, no `&key', no `apply', no closures.

(defun drgnx-ui-kit--run (runs from to face)
  "RUNS (newest first) with FACE over FROM..TO: the newest run extended when it ends at FROM in FACE (as the hub's
`RowBuilder::push' merges), else a new run.  No FACE: RUNS."
  (cond ((null face) runs)
        ((and runs (eq (nth 2 (car runs)) face) (= (nth 1 (car runs)) from))
         (setcar (cdar runs) to)
         runs)
        (t (cons (list from to face) runs))))

(defun drgnx-ui-kit--glyph (name tty)
  "Glyph NAME as TTY draws it: its ASCII form when TTY is `ascii', else its Unicode form (`drgnx-face-glyphs')."
  (let ((g (or (alist-get name drgnx-face-glyphs) (alist-get name drgnx-ui--default-glyphs))))
    (if (eq tty 'ascii) (cdr g) (car g))))

(defun drgnx-ui-kit--face (id chosen)
  "The face of component ID at CHOSEN ((AXIS . VALUE)...): the kit face of its most specific binding that CHOSEN all
has and that exists, else `drgnx-kit-ID' when it exists, else nil (the surface's own face; the hub's `default')."
  (let ((best nil) (best-n 0))
    (dolist (b (plist-get (drgnx-ui-kit-component id) :bind))
      (when (and (car b) (> (length (car b)) best-n)
                 (let ((all t)) (dolist (v (car b)) (unless (rassq v chosen) (setq all nil))) all))
        (let ((f (intern-soft (format "drgnx-kit-%s-%s" id (mapconcat #'symbol-name (car b) "-")))))
          (when (facep f) (setq best f best-n (length (car b)))))))
    (or best (let ((f (intern-soft (format "drgnx-kit-%s" id)))) (and (facep f) f)))))

(declare-function drgnx-icons--image "drgnx-icons" (name size))

(defconst drgnx-ui-kit-icon-px 16 "An icon's size in a component, logical px (the hub's `kit::ICON_PX').")

(defvar drgnx-ui-kit--icons nil
  "While an expansion draws icons: a function of an icon name and a logical size giving its image, or nil (none
drawn: each icon is its glyph, as the hub's `KitEnv' without icons).  `drgnx-ui-kit-string' binds it on a frame that
draws SVG icons (`drgnx-look-icons').")

(defun drgnx-ui-kit-icon-function (frame)
  "The `drgnx-ui-kit--icons' of FRAME: `drgnx-icons--image' where FRAME draws SVG icons, else nil."
  (and (display-graphic-p frame) (featurep 'drgnx-icons) (eq (bound-and-true-p drgnx-look-icons) 'svg)
       (image-type-available-p 'svg) #'drgnx-icons--image))

(defun drgnx-ui-kit--row (props scale tty)
  "The `row' component of PROPS (:kind :depth :twisty :icon :text :state :action) at SCALE, or on a terminal (TTY non-nil,
`ascii' for ASCII glyphs): (TEXT RUNS PROPS SPACES HEIGHT), see `drgnx-ui-kit--expand'."
  (let* ((entry (drgnx-ui-kit-component 'row))
         (kind (or (intern-soft (or (plist-get props :kind) "list")) 'list))
         (chosen (drgnx-ui-kit--chosen entry (list kind)))
         (g (plist-get entry :geometry)) (tg (plist-get entry :tty))
         (face (drgnx-ui-kit--face 'row chosen))
         (depth (or (plist-get props :depth) 0))
         (twisty (plist-get props :twisty))     ; t open, :false closed, nil none
         (state (plist-get (drgnx-ui-kit-state (intern-soft (or (plist-get props :state) "rest"))) :face))
         (action (plist-get props :action))
         (hit (if (and action (not tty)) (drgnx-px (or (drgnx-ui-kit--value (plist-get g :hit) chosen) 0) nil scale) 0))
         (pad (plist-get g :pad))
         (pos 0) (runs nil) (spaces nil) (parts nil) (images nil) start end)
    ;; each part: (TEXT FACE) pushed in order, a space's placeholder noted in SPACES
    (when (> hit 0)
      (push (list pos hit 0) spaces) (push " " parts) (setq pos (1+ pos)))
    (setq start pos)
    (if tty
        (let ((n (+ (or (plist-get tg :pad) 0) (* depth (or (drgnx-ui-kit--value (plist-get tg :indent) chosen) 0)))))
          (when (> n 0)
            (push (make-string n ?\s) parts) (setq runs (drgnx-ui-kit--run runs pos (+ pos n) face) pos (+ pos n))))
      (let ((w (+ (drgnx-px (car pad) nil scale)
                  (* depth (drgnx-px (or (drgnx-ui-kit--value (plist-get g :indent) chosen) 0) nil scale)))))
        (when (> w 0)
          (push (list pos w 0) spaces) (push " " parts)
          (setq runs (drgnx-ui-kit--run runs pos (1+ pos) face) pos (1+ pos)))))
    ;; the twisty and the icon: images then the row's gap where icons are drawn (`drgnx-ui-kit--icons'), else glyphs
    ;; then a space; an icon with no glyph is left out
    (let ((names (drgnx-ui-kit--value (plist-get tg :twisty) chosen))
          (gap (drgnx-px (or (drgnx-ui-kit--value (plist-get g :gap) chosen) 0) nil scale))
          (icon (plist-get props :icon)))
      ;; the twisty in the subtle role (the mockups' chevrons), above the row's own and state colours
      (dolist (part (delq nil (list (and twisty (cons (if (eq twisty t) (cadr names) (car names)) t))
                                    (and icon (cons (intern icon) nil)))))
        (let* ((name (car part)) (twisty-p (cdr part))
               (img (and drgnx-ui-kit--icons (not tty) (funcall drgnx-ui-kit--icons name drgnx-ui-kit-icon-px)))
               (mark (drgnx-ui-kit--glyph name tty)))
          (cond (img
                 (push (list pos (1+ pos) 'display img) images) (push " " parts)
                 (when twisty-p (setq runs (cons (list pos (1+ pos) 'drgnx-text-subtle) runs)))
                 (setq pos (1+ pos))
                 (when (> gap 0)
                   (push (list pos gap 0) spaces) (push " " parts)
                   (setq runs (drgnx-ui-kit--run runs pos (1+ pos) face) pos (1+ pos))))
                ((and mark (not (string-empty-p mark)) twisty-p)
                 (let ((end (+ pos (length mark))))
                   (push mark parts)
                   (setq runs (drgnx-ui-kit--run runs pos end 'drgnx-text-subtle))
                   (when face (setq runs (cons (list pos end face) runs)))
                   (push " " parts)
                   (setq runs (drgnx-ui-kit--run runs end (1+ end) face) pos (1+ end))))
                ((and mark (not (string-empty-p mark)))
                 (let ((s (concat mark " ")))
                   (push s parts)
                   (setq runs (drgnx-ui-kit--run runs pos (+ pos (length s)) face) pos (+ pos (length s)))))))))
    (let ((s (or (plist-get props :text) "")))
      (push s parts) (setq runs (drgnx-ui-kit--run runs pos (+ pos (length s)) face) pos (+ pos (length s))))
    (if tty
        (let ((n (or (plist-get tg :pad) 0)))
          (when (> n 0)
            (push (make-string n ?\s) parts) (setq runs (drgnx-ui-kit--run runs pos (+ pos n) face) pos (+ pos n))))
      (let ((w (drgnx-px (cdr pad) nil scale)))
        (when (> w 0)
          (push (list pos w 0) spaces) (push " " parts)
          (setq runs (drgnx-ui-kit--run runs pos (1+ pos) face) pos (1+ pos)))))
    (setq end pos)
    (when (> hit 0)
      (push (list pos hit 0) spaces) (push " " parts) (setq pos (1+ pos)))
    ;; the state's face under the component's (the hub's `RowBuilder::face', appended after the pushes)
    (setq runs (nreverse runs))
    (when state (setq runs (nconc runs (list (list start end state)))))
    (list (mapconcat #'identity (nreverse parts) "") runs
          (append (nreverse images)
                  (and action (list (list 0 pos 'drgnx-action (cons (plist-get action :kind) (plist-get action :args)))
                                    (list 0 pos 'mouse-face 'drgnx-hover))))
          (nreverse spaces)
          ;; the row is the density's height in device px (`:height (density tree-row)'); a terminal's is one line
          (let ((h (and (not tty) (drgnx-ui-kit--value (plist-get g :height) chosen))))
            (and h (> h 0) (drgnx-px h nil scale))))))

;;;; The builder: the inline components' expansion, pushed piece by piece like the hub's `RowBuilder'

;; Dynamic state of one expansion (`drgnx-ui-kit--building'), so a component's code takes no closure and no `&key'.
(defvar drgnx-ui-kit--bpos 0 "The position the next piece starts at.")
(defvar drgnx-ui-kit--bparts nil "The pieces of text, newest first.")
(defvar drgnx-ui-kit--bruns nil "The runs ((FROM TO FACE)...), newest first.")
(defvar drgnx-ui-kit--bspaces nil "The pads ((POS PX 0)...), newest first.")
(defvar drgnx-ui-kit--bscale 1.0 "The scale of the expansion.")
(defvar drgnx-ui-kit--btty nil "Non-nil when the expansion is for a terminal (`ascii': ASCII glyphs).")

(defmacro drgnx-ui-kit--building (scale tty &rest body)
  "BODY with an empty builder at SCALE (TTY: for a terminal)."
  (declare (indent 2))
  `(let ((drgnx-ui-kit--bpos 0) (drgnx-ui-kit--bparts nil) (drgnx-ui-kit--bruns nil) (drgnx-ui-kit--bspaces nil)
         (drgnx-ui-kit--bscale ,scale) (drgnx-ui-kit--btty ,tty))
     ,@body))

(defun drgnx-ui-kit--b-push (text face)
  "TEXT in FACE (nil: none) at the end of the builder, merged into the run before it (the hub's `RowBuilder::push')."
  (let ((end (+ drgnx-ui-kit--bpos (length text))))
    (push text drgnx-ui-kit--bparts)
    (setq drgnx-ui-kit--bruns (drgnx-ui-kit--run drgnx-ui-kit--bruns drgnx-ui-kit--bpos end face)
          drgnx-ui-kit--bpos end)))

(defun drgnx-ui-kit--b-pad (logical chars face)
  "A pad of LOGICAL px (rounded at the builder's scale) in FACE, or CHARS spaces on a terminal; nothing when empty."
  (if drgnx-ui-kit--btty
      (when (> chars 0) (drgnx-ui-kit--b-push (make-string chars ?\s) face))
    (let ((w (drgnx-px logical nil drgnx-ui-kit--bscale)))
      (when (> w 0)
        (push (list drgnx-ui-kit--bpos w 0) drgnx-ui-kit--bspaces)
        (drgnx-ui-kit--b-push " " face)))))

(defun drgnx-ui-kit--b-under (from to face)
  "FACE over FROM..TO below the runs so far."
  (when face (push (list from to face) drgnx-ui-kit--bruns)))

(defun drgnx-ui-kit--b-finish (state-face from to props height)
  "The builder's (TEXT RUNS PROPS SPACES HEIGHT), STATE-FACE (nil: none) above every run over FROM..TO."
  (let ((runs (nreverse drgnx-ui-kit--bruns)))
    (when state-face (push (list from to state-face) runs))
    (list (mapconcat #'identity (nreverse drgnx-ui-kit--bparts) "") runs props (nreverse drgnx-ui-kit--bspaces) height)))

(defun drgnx-ui-kit--b-action (action from)
  "The `drgnx-action' and `mouse-face' props of ACTION (:kind :args) over FROM..the end."
  (and action (list (list from drgnx-ui-kit--bpos 'drgnx-action (cons (plist-get action :kind) (plist-get action :args)))
                    (list from drgnx-ui-kit--bpos 'mouse-face 'drgnx-hover))))

(defun drgnx-ui-kit--name (props key default)
  "The symbol of PROPS' string KEY, DEFAULT (a symbol) when absent."
  (let ((v (plist-get props key))) (if v (intern-soft v) default)))

(defun drgnx-ui-kit--b-key-hint (keys variant)
  "The key hint of KEYS in VARIANT (`cap' or `menu') on the builder."
  (let* ((entry (drgnx-ui-kit-component 'key-hint)) (chosen (drgnx-ui-kit--chosen entry (list variant)))
         (g (plist-get entry :geometry)) (face (drgnx-ui-kit--face 'key-hint chosen))
         (pad (drgnx-ui-kit--value (plist-get g :pad) chosen)))
    (if drgnx-ui-kit--btty
        (drgnx-ui-kit--b-push (if (eq variant 'menu) keys (concat "[" keys "]")) face)
      (drgnx-ui-kit--b-pad (car pad) 0 face)
      (drgnx-ui-kit--b-push keys face)
      (drgnx-ui-kit--b-pad (cdr pad) 0 face))))

(defun drgnx-ui-kit--key-hint (props scale tty)
  "The `key-hint' component of PROPS (:keys :variant :state) at SCALE, see `drgnx-ui-kit--expand'."
  (drgnx-ui-kit--building scale tty
    (drgnx-ui-kit--b-key-hint (or (plist-get props :keys) "") (drgnx-ui-kit--name props :variant 'cap))
    (drgnx-ui-kit--b-finish (plist-get (drgnx-ui-kit-state (drgnx-ui-kit--name props :state 'rest)) :face)
                            0 drgnx-ui-kit--bpos nil nil)))

(defun drgnx-ui-kit--button (props scale tty)
  "The `button' component of PROPS (:label :style :size :state :key :action) at SCALE, see `drgnx-ui-kit--expand'."
  (drgnx-ui-kit--building scale tty
    (let* ((entry (drgnx-ui-kit-component 'button))
           (style (drgnx-ui-kit--name props :style 'secondary)) (size (drgnx-ui-kit--name props :size 'md))
           (chosen (drgnx-ui-kit--chosen entry (list style size)))
           (g (plist-get entry :geometry)) (face (drgnx-ui-kit--face 'button chosen))
           (pad (drgnx-ui-kit--value (plist-get g :pad) chosen))
           (state (plist-get (drgnx-ui-kit-state (drgnx-ui-kit--name props :state 'rest)) :face))
           (action (plist-get props :action)) (keys (plist-get props :key))
           (tty-pad (or (plist-get (plist-get entry :tty) :pad) 0))
           (hit (if (and action (not tty)) (drgnx-px (or (drgnx-ui-kit--value (plist-get g :hit) chosen) 0) nil scale) 0))
           (key-run nil) start end)
      (when (> hit 0)
        (push (list 0 hit 0) drgnx-ui-kit--bspaces) (drgnx-ui-kit--b-push " " nil))
      (setq start drgnx-ui-kit--bpos)
      (drgnx-ui-kit--b-pad (car pad) tty-pad face)
      (drgnx-ui-kit--b-push (or (plist-get props :label) "") face)
      (when keys
        (drgnx-ui-kit--b-pad (drgnx-ui-kit--value (plist-get g :gap) chosen) 1 face)
        (let ((at drgnx-ui-kit--bpos))
          (drgnx-ui-kit--b-key-hint keys 'cap)
          (setq key-run (cons at drgnx-ui-kit--bpos))))
      (drgnx-ui-kit--b-pad (cdr pad) tty-pad face)
      (setq end drgnx-ui-kit--bpos)
      (when (> hit 0)
        (push (list drgnx-ui-kit--bpos hit 0) drgnx-ui-kit--bspaces) (drgnx-ui-kit--b-push " " nil))
      (when key-run (drgnx-ui-kit--b-under (car key-run) (cdr key-run) face))
      (drgnx-ui-kit--b-finish state start end (drgnx-ui-kit--b-action action 0)
                              (let ((h (and (not tty) (drgnx-ui-kit--value (plist-get g :height) chosen))))
                                (and h (> h 0) (drgnx-px h nil scale)))))))

(defun drgnx-ui-kit--expand (component props scale tty)
  "COMPONENT (a symbol) with PROPS at SCALE (TTY: on a terminal, `ascii' for ASCII glyphs) as (TEXT RUNS PROPS
SPACES HEIGHT): RUNS ((FROM TO FACE)...), PROPS ((FROM TO NAME VALUE)...), SPACES ((POS WIDTH HEIGHT)...) in device
px, HEIGHT the row's line height in device px or nil (one text line)."
  (pcase component
    ('row (drgnx-ui-kit--row props scale tty))
    ('button (drgnx-ui-kit--button props scale tty))
    ('key-hint (drgnx-ui-kit--key-hint props scale tty))
    (_ (error "drgnx-ui-kit: no component %s" component))))

(defun drgnx-ui-kit--wire (v)
  "V as the hub writes it: a symbol as its name, a list as a vector."
  (cond ((and v (symbolp v)) (symbol-name v)) ((consp v) (vconcat v)) (t v)))

(defun drgnx-ui-kit-expand (component props scale tty)
  "COMPONENT (a symbol, e.g. `row') with PROPS (the hub's `Comp' JSON as a plist) at SCALE, on a terminal when TTY is
non-nil (`ascii': glyphs in their ASCII form), as a row's pieces in the hub's shape: (:text S :runs [[FROM TO FACE]...]
:props [[FROM TO NAME VALUE]...] :spaces [[POS W H]...] :height (:lines 1 :unit PX) or nil).  What the conformance test
compares with the hub's."
  (let ((e (drgnx-ui-kit--expand component props scale tty)) runs ps spaces)
    (dolist (r (nth 1 e)) (push (vector (nth 0 r) (nth 1 r) (symbol-name (nth 2 r))) runs))
    (dolist (p (nth 2 e)) (push (vector (nth 0 p) (nth 1 p) (symbol-name (nth 2 p)) (drgnx-ui-kit--wire (nth 3 p))) ps))
    (dolist (s (nth 3 e)) (push (vconcat s) spaces))
    (list :text (nth 0 e) :runs (vconcat (nreverse runs)) :props (vconcat (nreverse ps)) :spaces (vconcat (nreverse spaces))
          :height (and (nth 4 e) (list :lines 1 :unit (nth 4 e))))))

(defvar drgnx-ui-kit--pads (make-hash-table :test #'eql)
  "Device px → the `display' spec of a pad that wide on a mode, header or tab line, made once.  Bounded by the widths
the kit's pads take at the scales seen (a handful per component and scale).")

(defun drgnx-ui-kit--pad (width where frame)
  "The `display' of a pad WIDTH device px wide on WHERE in FRAME: in buffer text (`text') a width in FRAME's canonical
characters, so one buffer is right on frames of two scales; on a line its px, the spec cached."
  (if (eq where 'text)
      `(space :width ,(/ (float width) (frame-char-width frame)))
    (or (gethash width drgnx-ui-kit--pads)
        (puthash width `(space :width (,width)) drgnx-ui-kit--pads))))

(defun drgnx-ui-kit-string (component props where frame)
  "COMPONENT with PROPS (as `drgnx-ui-kit-expand') as a propertized string for WHERE (`text', `header-line',
`mode-line' or `tab-line') on FRAME (nil: the selected one), at FRAME's scale or as its terminal draws it.  A click
on an action (PROPS :action) runs `kit-activate' (the kind's map, `drgnx-ui-kit-action-map')."
  (let* ((gui (display-graphic-p frame))
         (e (let ((drgnx-ui-kit--icons (drgnx-ui-kit-icon-function frame)))
              (drgnx-ui-kit--expand component props (if gui (drgnx-pixels-scale frame) 1.0)
                                    (cond (gui nil) ((drgnx-ui-ascii-frame-p frame) 'ascii) (t t)))))
         (s (nth 0 e)))
    (dolist (r (nth 1 e)) (add-face-text-property (nth 0 r) (nth 1 r) (nth 2 r) t s))
    (dolist (p (nth 2 e))
      (put-text-property (nth 0 p) (nth 1 p) (nth 2 p) (nth 3 p) s)
      (when (eq (nth 2 p) 'drgnx-action)
        (put-text-property (nth 0 p) (nth 1 p) (if (eq where 'text) 'keymap 'local-map)
                           (drgnx-ui-kit-action-map (car (nth 3 p))) s)))
    (dolist (sp (nth 3 e)) (put-text-property (car sp) (1+ (car sp)) 'display (drgnx-ui-kit--pad (nth 1 sp) where frame) s))
    s))

;;;; Actions: what a click or RET on a component does

;; A component's action is a `drgnx-action' property, (KIND ARGS...), over the component and its hit padding (from the
;; hub, or `drgnx-ui-kit-string').  Each KIND has one keymap, built once, put where the property is, whose keys run
;; `kit-activate': it reads the property and calls the kind's function with ARGS.  No closure per row.

(declare-function drgnx-modules--recording-p "drgnx-modules")
(declare-function drgnx-modules-push-undo "drgnx-modules")

(defvar drgnx-ui-kit--actions (make-hash-table :test #'eq)
  "Action KIND (a symbol) → (FUNCTION KEYS MAP): `drgnx-ui-kit-define-action'.")

(defvar drgnx-ui-kit-action-base-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-1] #'drgnx-ui-kit-activate)
    (define-key m [header-line mouse-1] #'drgnx-ui-kit-activate)
    (define-key m [mode-line mouse-1] #'drgnx-ui-kit-activate)
    (define-key m [tab-line mouse-1] #'drgnx-ui-kit-activate)
    m)
  "The keymap every action kind's map inherits: a click runs `drgnx-ui-kit-activate'; the profiles bind its keys
\(`kit-activate', RET by default).  An unknown kind's property gets this map.")

(defun drgnx-ui-kit-define-action (kind function keys)
  "Define the action KIND (a symbol): `kit-activate' on a `drgnx-action' (KIND ARGS...) calls FUNCTION with the list
ARGS.  KEYS: ((KEY . ARGS-TRANSFORM)...) more keys of the kind's map (`kbd' strings), each calling FUNCTION with
\(funcall ARGS-TRANSFORM ARGS), or nil.  Defined by a module's setup, it is undefined with the module.  Returns KIND."
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m drgnx-ui-kit-action-base-map)
    (dolist (k keys) (define-key m (kbd (car k)) #'drgnx-ui-kit-activate))
    (puthash kind (list function keys m) drgnx-ui-kit--actions)
    (when (and (fboundp 'drgnx-modules--recording-p) (drgnx-modules--recording-p))
      (drgnx-modules-push-undo (format "action kind %s" kind) (lambda () (drgnx-ui-kit-undefine-action kind))))
    kind))

(defun drgnx-ui-kit-undefine-action (kind)
  "Remove the action KIND; its properties then say it is unknown.  Returns KIND when it was defined."
  (when (gethash kind drgnx-ui-kit--actions)
    (remhash kind drgnx-ui-kit--actions)
    kind))

(defun drgnx-ui-kit-action-map (kind)
  "The keymap of the action KIND (a symbol or its name; never interned): its own, or for a kind not defined
`drgnx-ui-kit-action-base-map', so `kit-activate' says so."
  (let ((k (if (stringp kind) (intern-soft kind) kind)))
    (or (and k (nth 2 (gethash k drgnx-ui-kit--actions))) drgnx-ui-kit-action-base-map)))

(defun drgnx-ui-kit--action-at ()
  "The `drgnx-action' where the last input event was: at the click (in a line's string or the buffer), else at point."
  (let* ((ev last-input-event) (posn (and (consp ev) (event-start ev))))
    (cond ((and posn (posn-string posn))
           (get-text-property (or (cdr (posn-string posn)) 0) 'drgnx-action (car (posn-string posn))))
          ((and posn (windowp (posn-window posn)) (posn-point posn))
           (with-current-buffer (window-buffer (posn-window posn)) (get-text-property (posn-point posn) 'drgnx-action)))
          (t (get-text-property (point) 'drgnx-action)))))

(defun drgnx-ui-kit-activate ()
  "Run the action of the component at point or at the click: its `drgnx-action' (KIND ARGS...) calls KIND's function
with ARGS (transformed when a key of KIND's own ran it).  A KIND not defined is an error naming it."
  (interactive)
  (let ((a (drgnx-ui-kit--action-at)))
    (unless a (user-error "No action here"))
    (let* ((name (car a)) (k (if (stringp name) (intern-soft name) name))
           (def (and k (gethash k drgnx-ui-kit--actions)))
           (args (cdr a)))
      (unless def (user-error "No action kind %s (its module is off?)" name))
      (let ((keys (this-command-keys-vector)))
        (dolist (key (nth 1 def))
          (when (equal (kbd (car key)) keys) (setq args (funcall (cdr key) args)))))
      (funcall (car def) args))))

;;;; Constructors of the chrome's components

(defun drgnx-ui-kit--run-button (args)
  "The action kind `ui-button': run the button's own ACTION (the one element of ARGS) as `drgnx-ui-kit-run' does."
  (drgnx-ui-kit-run (car args)))

(drgnx-ui-kit-define-action 'ui-button #'drgnx-ui-kit--run-button nil)

(defun drgnx-ui-kit--action-spec (action)
  "ACTION as the props' action plist (:kind :args): a kit action (KIND . ARGS) as it is, anything else (a registry id, a
command, a function of no arguments) as the kind `ui-button' holding it.  Nil is no action."
  (cond ((null action) nil)
        ((and (consp action) (symbolp (car action)) (not (eq (car action) 'lambda)))
         (list :kind (car action) :args (cdr action)))
        (t (list :kind 'ui-button :args (list action)))))

(defun drgnx-ui-kit-button (label action style size state key where)
  "LABEL as a kit button on WHERE (`text', `header-line', `mode-line' or `tab-line') that runs ACTION: a registry id, a
command, a function of no arguments, or (KIND . ARGS) of a kit action (`drgnx-ui-kit-define-action'); nil is a button
with no action.  STYLE is `primary', `secondary', `quiet' or `danger', SIZE `md' or `sm', STATE one of the state
table's (`focus-visible' shows its ring only after a key event, `drgnx-ui-kit-focus-visible-p'), KEY the keys of its key
hint or nil.  Its `help-echo' and accessible text are LABEL."
  (let ((s (drgnx-ui-kit-string
            'button
            (list :c "button" :label label :style (symbol-name (or style 'secondary)) :size (symbol-name (or size 'md))
                  :state (symbol-name (if (and (eq state 'focus-visible) (not (drgnx-ui-kit-focus-visible-p))) 'rest (or state 'rest)))
                  :key key :action (drgnx-ui-kit--action-spec action))
            where nil)))
    (put-text-property 0 (length s) 'help-echo label s)
    s))

(defun drgnx-ui-kit-key-hint (keys variant where)
  "KEYS as a kit key hint (VARIANT `cap' or `menu', nil is `cap') on WHERE, as `drgnx-ui-kit-button' takes it.  Its
`help-echo' and accessible text are \"key KEYS\"."
  (let ((s (drgnx-ui-kit-string 'key-hint (list :c "key-hint" :keys keys :variant (symbol-name (or variant 'cap))) where nil)))
    (put-text-property 0 (length s) 'help-echo (concat "key " keys) s)
    s))

;;;; Focus-visible: the focus ring after a key, not after a click

(defvar drgnx-ui-kit--focus-visible nil
  "Non-nil when the last command came from a key (not the mouse): the focus ring shows.")

(defun drgnx-ui-kit-focus-visible-p ()
  "Non-nil when the focus ring shows (spec §7.3): after a key event, not after a mouse event."
  drgnx-ui-kit--focus-visible)

(defun drgnx-ui-kit--note-input ()
  "`pre-command-hook' of `drgnx-ui-kit-focus-mode': a key event shows the focus ring, a mouse event hides it."
  (setq drgnx-ui-kit--focus-visible (not (consp last-input-event))))

(define-minor-mode drgnx-ui-kit-focus-mode
  "Track whether the focus ring shows: after a key event, not a mouse event (`drgnx-ui-kit-focus-visible-p')."
  :global t :group 'drgnx
  (if drgnx-ui-kit-focus-mode
      (add-hook 'pre-command-hook #'drgnx-ui-kit--note-input)
    (remove-hook 'pre-command-hook #'drgnx-ui-kit--note-input)))

(provide 'drgnx-ui-kit)
;;; drgnx-ui-kit.el ends here
