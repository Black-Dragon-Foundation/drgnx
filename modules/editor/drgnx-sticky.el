;;; drgnx-sticky.el --- Module editor/sticky: sticky scroll — the scopes scrolled past, after the breadcrumb -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Like VS Code's sticky scroll: when the start of the function (class, block) you are in has scrolled off the top,
;; its name shows in the header, after the breadcrumb — up to three enclosing scopes, outermost first, one
;; line (`a › b › c'), in the breadcrumb's caption face (the look shows symbol names, never the code line).  The header line is always there (the breadcrumb), so nothing shifts as you scroll.  Scopes
;; come from tree-sitter when the buffer has a parser (functions, classes, …), else from the hub: the definitions the
;; Outline lists around the line (`outline/scopes', unsaved text included), asked once per start line and text, the
;; header drawn again when the answer comes.  Each window start is worked out once (a memo, rebuilt when the start
;; moves, the text above it changes or the hub answers).  drgnx's own; no package.  See docs/guide/editing.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-memo)
(require 'drgnx-large-file)
(require 'drgnx-timer)
(require 'drgnx-type-faces)             ; `drgnx-ui-caption'

(declare-function drgnx-chrome-add-tail-provider "drgnx-chrome")
(declare-function drgnx-chrome-remove-tail-provider "drgnx-chrome")
(declare-function nidhogg-treesit-parser-ready-p "nidhogg-treesit-bg.c" (parser))
(declare-function treesit-parser-p "treesit.c")
(declare-function drgnx-chrome-apply "drgnx-chrome")
(declare-function drgnx-state-subscribe "drgnx-state")
(declare-function drgnx-outline-scopes "drgnx-outline" (buffer line callback))
(declare-function treesit-parser-list "treesit.c")
(declare-function treesit-node-at "treesit")
(declare-function treesit-node-parent "treesit.c")
(declare-function treesit-node-type "treesit.c")
(declare-function treesit-node-start "treesit.c")

(drgnx-defsetting drgnx-sticky-style 'names
  "How sticky scroll shows the scopes whose start has scrolled off the top: `names', their names after the breadcrumb;
`lines', their first lines as code (line numbers and syntax colours) pinned over the window's top rows, VS Code's
sticky scroll.  A click on a line goes there; Ctrl+click folds that scope."
  :type '(choice (const names) (const lines)) :group 'drgnx :scope 'global :apply #'drgnx-sticky--setting-changed)

(drgnx-defsetting drgnx-sticky-max 3
  "Scopes sticky scroll shows at most, the outermost first (VS Code's default is 5; the lines cover text rows)."
  :type 'integer :group 'drgnx :scope 'global :apply #'drgnx-sticky--setting-changed)

(defun drgnx-sticky--setting-changed (&rest _)
  "A sticky setting changed: every buffer's scopes are worked out again, and the cards a `names' style leaves go."
  (dolist (b (buffer-list))
    (when (buffer-local-value 'drgnx-sticky-mode b) (drgnx-epoch-bump 'sticky b)))
  (unless (eq drgnx-sticky-style 'lines) (drgnx-sticky--hide-all t))
  (force-mode-line-update t))

(defvar drgnx-sticky-node-types
  '("function_definition" "function_declaration" "function_item" "function_expression" "function" "arrow_function"
    "generator_function_declaration" "method_definition" "method_declaration" "method" "singleton_method"
    "constructor_declaration" "class_definition" "class_declaration" "abstract_class_declaration" "class_specifier"
    "class" "struct_specifier" "struct_item" "impl_item" "trait_item" "mod_item" "module" "namespace_definition"
    "internal_module" "interface_declaration" "enum_declaration" "enum_item" "enum_specifier" "object_declaration"
    "type_declaration")
  "Tree-sitter node types that are scopes (never the root node: python's is `module').")

(defface drgnx-sticky '((t :inherit (drgnx-ui-caption drgnx-text-muted)))
  "Sticky scroll's scope names in the header line: the breadcrumb's caption." :group 'drgnx)

(defun drgnx-sticky--treesit-scopes (pos)
  (let ((node (treesit-node-at (save-excursion (goto-char pos) (back-to-indentation) (point)))) (bol (save-excursion (goto-char pos) (line-beginning-position))) out)
    (while node
      (when (and (treesit-node-parent node)                        ; the root is the file, not a scope
                 (member (treesit-node-type node) drgnx-sticky-node-types)
                 (< (treesit-node-start node) bol))
        (push (save-excursion (goto-char (treesit-node-start node)) (line-beginning-position)) out))
      (setq node (treesit-node-parent node)))
    out))

(defun drgnx-sticky--parse-pending-p ()
  "Non-nil when this buffer's tree-sitter tree is not ready: on Nidhogg (`nidhogg-treesit-parser-ready-p') a parse job,
a large file's first parse, may still run, and reading a node now would wait for it in the header's `:eval'."
  (and (fboundp 'nidhogg-treesit-parser-ready-p)
       (let ((p (or (bound-and-true-p treesit-primary-parser) (car (treesit-parser-list)))))
         (and (treesit-parser-p p) (not (nidhogg-treesit-parser-ready-p p))))))

(defun drgnx-sticky--parse-landed (buffer)
  "The poll `drgnx-sticky--treesit-p' starts: once BUFFER's tree is ready, raise its `sticky' epoch and redraw the headers
once, so the scopes come from tree-sitter again.  Non-nil ends the poll."
  (or (not (buffer-live-p buffer))
      (with-current-buffer buffer
        (unless (drgnx-sticky--parse-pending-p)
          (drgnx-epoch-bump 'sticky buffer)
          (force-mode-line-update t)
          t))))

(defun drgnx-sticky--treesit-p ()
  "Non-nil when this buffer's scopes come from its tree-sitter tree: it has a parser and the tree is ready.  On Nidhogg a
parse job (a large file's first parse) may still run; reading a node then would wait for it in the header's `:eval', so
the hub answers meanwhile and a poll redraws the header once the tree is there."
  (and (fboundp 'treesit-parser-list) (treesit-parser-list)
       (or (not (drgnx-sticky--parse-pending-p))
           (progn (drgnx-timer-poll (cons 'sticky-parse (current-buffer)) 0.05 #'drgnx-sticky--parse-landed
                                    :deadline 30 :args (list (current-buffer)) :owner 'editor/sticky)
                  nil))))

(defconst drgnx-sticky--lisp-name
  "(\\(?:[[:alnum:]-]+[:/]\\)?def[[:alnum:]-]*\\*?[ \t]+'?(?\\([^][ \t\n()\"]+\\)"
  "A Lisp definition's name: `(defun NAME', `(cl-defmethod NAME', `(defvar NAME'.")

(defconst drgnx-sticky--keyword-name
  (concat "\\_<\\(?:def\\|fn\\|func\\|function\\|class\\|struct\\|enum\\|union\\|trait\\|impl\\|interface\\|module"
          "\\|mod\\|namespace\\|object\\|record\\|type\\|macro_rules!\\)\\_>[ \t]+\\([[:alpha:]_$][[:alnum:]_$]*\\)")
  "A definition's name after its keyword: `def area', `class Shape', `fn main', `impl Foo'.")

(defconst drgnx-sticky--call-name "\\([[:alpha:]_][[:alnum:]_:.~]*\\)[ \t]*("
  "A C-like definition's name: the identifier before its parameter list (`int main(void) {').")

(defconst drgnx-sticky--key-name "\\`\\([[:alpha:]_][[:alnum:]_.-]*\\)[ \t]*:"
  "A key that opens a block (`build:' in YAML).")

(defconst drgnx-sticky--not-names '("if" "for" "while" "switch" "catch" "return" "sizeof" "else" "do")
  "Words before a `(' that are statements, not definitions.")

(defun drgnx-sticky--name (line lisp)
  "The symbol name LINE (a scope's first line, trimmed) defines, or nil when it names nothing (`(let ((x', `if (a)').
LISP: the buffer is a Lisp, where only a definition form names a scope."
  (save-match-data
    (cond ((string-match drgnx-sticky--lisp-name line) (match-string 1 line))
          (lisp nil)
          ((string-match drgnx-sticky--keyword-name line) (match-string 1 line))
          ((and (string-match drgnx-sticky--call-name line)
                (not (member (match-string 1 line) drgnx-sticky--not-names)))
           (match-string 1 line))
          ((string-match drgnx-sticky--key-name line) (match-string 1 line)))))

(defun drgnx-sticky--text (start)
  "The symbol name the scope at START defines (the look: a breadcrumb shows names, never code), or nil."
  (save-excursion
    (goto-char start)
    (drgnx-sticky--name (string-trim (buffer-substring-no-properties (progn (back-to-indentation) (point))
                                                                     (line-end-position)))
                        (derived-mode-p 'lisp-data-mode))))

(drgnx-epoch-define 'sticky :per 'buffer
                    :doc "Raised by an edit at or above a window's start in the buffer (its scopes may have changed).")

(drgnx-memo-define sticky-segment :on window
                   :keys ((window-start object) (window-buffer object) (drgnx-epoch 'sticky (window-buffer object)))
                   :doc "A window's sticky part of the header, until its start moves, it shows another buffer or the text above changes.")

(defun drgnx-sticky--after-change (beg _end _len)
  "`after-change-functions': an edit above the top of a window showing this buffer changes its scopes."
  (when (seq-some (lambda (w) (<= beg (window-start w))) (get-buffer-window-list nil nil t))
    (drgnx-epoch-bump 'sticky (current-buffer))))

(defvar-local drgnx-sticky--last nil
  "[TICK SCOPES SEGMENT]: the segment last made from this buffer's tree, for the scopes starting at SCOPES, at change
TICK.")

(defvar-local drgnx-sticky--hub nil
  "[TICK LINE SEGMENT]: the segment made from the hub's answer for the scopes above LINE, at change TICK.")

(defvar-local drgnx-sticky--asked nil
  "(TICK . LINE): the start line, at change TICK, whose scopes the hub is to be asked for or was asked for last.")

(defun drgnx-sticky--join (names)
  "The segment showing NAMES (outermost first): \" › A › B\" in the caption face, or \"\" for none."
  (let ((s (if names (concat " › " (string-replace "%" "%%" (string-join names " › "))) "")))   ; the mode line's %
    (add-face-text-property 0 (length s) 'drgnx-sticky t s)
    s))

(defun drgnx-sticky--treesit-segment (w)
  "Window W's segment from the buffer's tree.  A start under the same scopes as the last one, with the text unchanged,
takes that segment: the scope lines are read once."
  (let* ((scopes (seq-take (drgnx-sticky--treesit-scopes (window-start w)) drgnx-sticky-max))
         (last drgnx-sticky--last) (tick (buffer-chars-modified-tick)))
    (cond ((null scopes) "")
          ((and last (eql (aref last 0) tick) (equal (aref last 1) scopes)) (aref last 2))
          (t (let ((s (drgnx-sticky--join (delq nil (mapcar #'drgnx-sticky--text scopes)))))
               (setq drgnx-sticky--last (vector tick scopes s))
               s)))))

(defun drgnx-sticky--hub-segment (w)
  "Window W's segment from the hub: the answer kept for its start line and the buffer's text; else the hub is asked
\(once, after this redisplay) and the last segment made stays until it answers."
  (let ((tick (buffer-chars-modified-tick)) (line (line-number-at-pos (window-start w))) (kept drgnx-sticky--hub))
    (if (and kept (eql (aref kept 0) tick) (eql (aref kept 1) line))
        (aref kept 2)
      (unless (equal drgnx-sticky--asked (cons tick line))
        (setq drgnx-sticky--asked (cons tick line))
        (drgnx-timer-debounce (cons 'sticky-ask (current-buffer)) 0 #'drgnx-sticky--ask   ; the buffer owns it
                              :args (list (current-buffer)) :owner (current-buffer)))
      (if kept (aref kept 2) ""))))

(defun drgnx-sticky--ask (buffer)
  "Ask the hub for the scopes of BUFFER's start line `drgnx-sticky--asked' names (`drgnx-outline-scopes')."
  (when (buffer-live-p buffer)
    (pcase-let ((`(,tick . ,line) (buffer-local-value 'drgnx-sticky--asked buffer)))
      (when line
        (require 'drgnx-outline)
        (drgnx-outline-scopes buffer line
                              (lambda (scopes) (drgnx-sticky--answered buffer tick line scopes)))))))

(defun drgnx-sticky--answered (buffer tick line scopes)
  "The hub's SCOPES (plists, outermost first) of LINE of BUFFER at change TICK: those that start above LINE make the
segment, kept for (TICK, LINE), and the header is drawn again."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((names (seq-take (delq nil (mapcar (lambda (s) (and (< (plist-get s :line) line) (plist-get s :name)))
                                               scopes))
                             drgnx-sticky-max)))
        (setq drgnx-sticky--hub (vector tick line (drgnx-sticky--join names)))
        (drgnx-epoch-bump 'sticky buffer)
        (force-mode-line-update t)))))

(defun drgnx-sticky--segment (w)
  "Window W's sticky part of the header: \" › SCOPE › …\" for its start, or \"\" (the memo `sticky-segment': built
again only when the start moves, the text above it changes or the hub answers).  From the buffer's tree-sitter tree
when it is ready (`drgnx-sticky--treesit-p'), else from the hub (`drgnx-sticky--hub-segment')."
  (drgnx-memo sticky-segment w
              (with-current-buffer (window-buffer w)
                (cond ((eq drgnx-sticky-style 'lines) (drgnx-sticky--want w (drgnx-sticky--scopes w)) "")
                      ((drgnx-sticky--treesit-p) (drgnx-sticky--treesit-segment w))
                      (t (drgnx-sticky--hub-segment w))))))

;;;; The `lines' style: a card over the window's top rows (design F6, §7.5)

;; A child frame per window, pooled, over the window's top rows: it shows the scope start lines (copied with their
;; faces, a line number before each), so Emacs draws them; it does not reflow the text, move point or change what a
;; scroll counts, and a click lands on the real line.  It is filled again only when the window's set of scopes changes
;; (the memo `sticky-segment' runs once per window start); moving with the frame is the child frame's own.  Its window
;; is marked `drgnx-minimap-exclude' (no ruler, minimap or card of its own).  `pin-show' (X5) uses the same card.

(defface drgnx-sticky-line '((t :inherit default))
  "A sticky line of the `lines' style: the code as the buffer shows it, over this face." :group 'drgnx)

(defvar drgnx-sticky--cards nil
  "Alist WINDOW → [FRAME BUFFER CONTENT]: each window's card, CONTENT the positions it shows (nil: hidden).")

(defvar-local drgnx-sticky--owner nil "In a card's buffer: the window the card is over.")

(defvar drgnx-sticky--pin-shown nil "Alist WINDOW → the pin (an element of `drgnx-sticky--pins') its card shows.")

(defvar drgnx-sticky-line-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-1] #'drgnx-sticky-click)
    (define-key m [down-mouse-1] #'ignore)
    (define-key m [C-mouse-1] #'drgnx-sticky-fold-click)
    (define-key m [C-down-mouse-1] #'ignore)
    m)
  "The keys of a sticky line: a click goes there, Ctrl+click folds that scope.")

(defun drgnx-sticky--scopes (w)
  "The starts (line beginnings, outermost first, at most `drgnx-sticky-max') of the scopes holding window W's start
that start above it: from the fold table (sticky, folds and the minimap agree), else the buffer's tree."
  (let* ((start (window-start w)) (bol (save-excursion (goto-char start) (line-beginning-position)))
         (folds (and (fboundp 'drgnx-fold-ranges) (ignore-errors (drgnx-fold-ranges start (1+ start)))))
         (scopes (if folds
                     (delete-dups (delq nil (mapcar (lambda (r) (and (< (nth 0 r) bol) (>= (nth 1 r) start)
                                                                     (save-excursion (goto-char (nth 0 r))
                                                                                     (line-beginning-position))))
                                                    folds)))
                   (and (drgnx-sticky--treesit-p) (drgnx-sticky--treesit-scopes start)))))
    (seq-take scopes drgnx-sticky-max)))

(defun drgnx-sticky--line (pos width)
  "POS's line as a sticky line: its number (WIDTH columns) in `line-number', then its text with the buffer's faces,
the whole line carrying `drgnx-sticky-pos' POS (where a click goes)."
  (save-excursion
    (goto-char pos)
    (let ((b (line-beginning-position)) (e (line-end-position)))
      (when (fboundp 'font-lock-ensure) (font-lock-ensure b e))
      (let ((s (concat (propertize (format (format "%%%dd " width) (line-number-at-pos b)) 'face 'line-number)
                       (buffer-substring b e))))
        (add-face-text-property 0 (length s) 'drgnx-sticky-line t s)
        (add-text-properties 0 (length s) (list 'drgnx-sticky-pos b 'mouse-face 'highlight 'keymap drgnx-sticky-line-map
                                                'help-echo "mouse-1: go there; C-mouse-1: fold it")
                             s)
        s))))

(defun drgnx-sticky--text-of (positions)
  "The card's text for POSITIONS (line beginnings of the current buffer): one sticky line each, numbers aligned."
  (let ((width (length (number-to-string (line-number-at-pos (car (last positions)))))))
    (mapconcat (lambda (p) (drgnx-sticky--line p width)) positions "\n")))

(defun drgnx-sticky--want (w positions)
  "Window W should show POSITIONS in its card (nil: no card): when that differs from what it shows, the card is filled
again after this redisplay (a frame is not changed inside one).  A window showing a pin (`pin-show') keeps it."
  (let ((card (cdr (assq w drgnx-sticky--cards))))
    (unless (or (assq w drgnx-sticky--pin-shown) (equal positions (and card (aref card 2))))
      (drgnx-timer-debounce (cons 'sticky-card w) 0 #'drgnx-sticky--fill :args (list w positions)
                            :owner 'editor/sticky))))

(defun drgnx-sticky--card-params (parent)
  "A card's frame parameters under PARENT: no focus, no decorations, the popups' chrome (their shadow), excluded from
the minimap and the ruler."
  (let ((chrome (and (fboundp 'drgnx-look-chrome-current) (drgnx-look-chrome-current))))
    `((parent-frame . ,parent) (minibuffer . nil) (name . "drgnx-sticky") (drgnx-sticky-card . t)
      (drgnx-minimap-exclude . t) (undecorated . t) (no-accept-focus . t) (no-focus-on-map . t) (no-other-frame . t)
      (skip-taskbar . t) (unsplittable . t) (no-special-glyphs . t) (desktop-dont-save . t) (border-width . 0)
      (internal-border-width . 0) (child-frame-border-width . 0) (menu-bar-lines . 0) (tool-bar-lines . 0)
      (tab-bar-lines . 0) (left-fringe . 0) (right-fringe . 0) (vertical-scroll-bars) (horizontal-scroll-bars)
      (cursor-type . nil) (visibility . nil) ,@chrome)))

(defun drgnx-sticky--card (w)
  "Window W's card, [FRAME BUFFER CONTENT], made on first use."
  (let ((card (cdr (assq w drgnx-sticky--cards))))
    (unless (and card (frame-live-p (aref card 0)))
      (let* ((buf (generate-new-buffer " *drgnx-sticky*" t))
             (frame (let ((after-make-frame-functions nil) (before-make-frame-hook nil))
                      (make-frame (drgnx-sticky--card-params (window-frame w))))))
        (with-current-buffer buf
          (setq-local mode-line-format nil header-line-format nil tab-line-format nil cursor-type nil
                      cursor-in-non-selected-windows nil truncate-lines t display-line-numbers nil
                      drgnx-sticky--owner w)
          (buffer-disable-undo))
        (set-window-buffer (frame-root-window frame) buf)
        (set-window-dedicated-p (frame-root-window frame) t)
        (set-window-parameter (frame-root-window frame) 'drgnx-minimap-exclude t)
        (setq card (vector frame buf nil))
        (setq drgnx-sticky--cards (cons (cons w card) (assq-delete-all w drgnx-sticky--cards)))))
    card))

(defun drgnx-sticky--place (w card)
  "Put CARD over window W's top rows, as wide as its text area, as tall as its lines."
  (let* ((frame (aref card 0)) (edges (window-inside-pixel-edges w))
         (lines (with-current-buffer (aref card 1) (count-lines (point-min) (point-max))))
         (height (* (max 1 lines) (with-selected-window w (default-line-height)))))
    (set-frame-size frame (- (nth 2 edges) (nth 0 edges)) height t)
    (set-frame-position frame (nth 0 edges) (nth 1 edges))))

(defun drgnx-sticky--fill (w positions)
  "Show POSITIONS of window W's buffer in its card (the debounce's end); nil hides it."
  (when (window-live-p w)
    (if (or (null positions) (not (display-graphic-p (window-frame w))))
        (drgnx-sticky--hide w)
      (let* ((card (drgnx-sticky--card w))
             (text (with-current-buffer (window-buffer w) (drgnx-sticky--text-of positions))))
        (with-current-buffer (aref card 1)
          (let ((inhibit-read-only t)) (erase-buffer) (insert text) (goto-char (point-min))))
        (aset card 2 positions)
        (drgnx-sticky--place w card)
        (unless (frame-visible-p (aref card 0)) (make-frame-visible (aref card 0)))))))

(defun drgnx-sticky--hide (w)
  "Hide window W's card (it stays in the pool)."
  (when-let* ((card (cdr (assq w drgnx-sticky--cards))))
    (aset card 2 nil)
    (when (and (frame-live-p (aref card 0)) (frame-visible-p (aref card 0))) (make-frame-invisible (aref card 0)))))

(defun drgnx-sticky--hide-all (&optional delete)
  "Hide every card; with DELETE, delete their frames and buffers and forget them (the pins shown go too)."
  (dolist (e drgnx-sticky--cards)
    (let ((card (cdr e)))
      (if (not delete) (drgnx-sticky--hide (car e))
        (when (frame-live-p (aref card 0)) (delete-frame (aref card 0) t))
        (when (buffer-live-p (aref card 1)) (kill-buffer (aref card 1))))))
  (when delete (setq drgnx-sticky--cards nil drgnx-sticky--pin-shown nil)))

(defun drgnx-sticky--windows-moved (data)
  "A `now' subscriber of the store's `pane-resized' and `windows-changed' (DATA): the cards over its frame's windows
are placed again after this redisplay (a frame is never changed inside one)."
  (when drgnx-sticky--cards
    (drgnx-timer-debounce 'sticky-cards 0 #'drgnx-sticky--resized :args (list (plist-get data :frame))
                          :owner 'editor/sticky)))

(defun drgnx-sticky--resized (frame)
  "The cards over FRAME's windows follow their windows; a dead window's card goes."
  (dolist (e drgnx-sticky--cards)
    (let ((w (car e)) (card (cdr e)))
      (cond ((not (window-live-p w))
             (when (frame-live-p (aref card 0)) (delete-frame (aref card 0) t))
             (when (buffer-live-p (aref card 1)) (kill-buffer (aref card 1)))
             (setq drgnx-sticky--cards (delq e drgnx-sticky--cards)
                   drgnx-sticky--pin-shown (assq-delete-all w drgnx-sticky--pin-shown)))
            ((and (eq (window-frame w) frame) (aref card 2) (frame-live-p (aref card 0)))
             (drgnx-sticky--place w card))))))

(defun drgnx-sticky--click-target (event)
  "The window and position a click EVENT on a card goes to, as (WINDOW . POS), or nil."
  (let* ((posn (event-start event)) (cw (posn-window posn)) (pt (posn-point posn)))
    (when (and (windowp cw) pt)
      (with-current-buffer (window-buffer cw)
        (let ((pos (get-text-property (min pt (max (point-min) (1- (point-max)))) 'drgnx-sticky-pos)))
          (and pos (window-live-p drgnx-sticky--owner) (cons drgnx-sticky--owner pos)))))))

(defun drgnx-sticky-click (event)
  "Go to the scope line clicked in the sticky card (EVENT), in the window under it."
  (interactive "e")
  (when-let* ((target (drgnx-sticky--click-target event)))
    (select-window (car target))
    (goto-char (cdr target))))

(defun drgnx-sticky-fold-click (event)
  "Fold the scope whose line was Ctrl-clicked in the sticky card (EVENT)."
  (interactive "e")
  (when-let* ((target (drgnx-sticky--click-target event)))
    (select-window (car target))
    (goto-char (cdr target))
    (when (fboundp 'drgnx-fold-toggle) (drgnx-fold-toggle))))

;;;; Pinned regions (design X5)

;; `pin-region' pins the selection or the scope at point: a band and a label on the minimap (the scroll bar's `pin'
;; marks, which the line model moves with edits; the names go in the minimap's spec), listed by `pin-show' and
;; `unpin-region'.  `pin-show' shows a pinned region in the window's card, over its top rows, until it is toggled off:
;; read a signature while you write its uses.

(defface drgnx-marks-pin '((t :inherit font-lock-type-face))
  "A pinned region's band and label on the minimap, and its scroll bar mark (the design's teal)." :group 'drgnx)

(defvar-local drgnx-sticky--pins nil
  "This buffer's pinned regions, in buffer order: (START-MARKER END-MARKER NAME) each.")

(defun drgnx-sticky-pin-names (&optional buffer)
  "The names of BUFFER's pins (default current), in buffer order: what the minimap labels its bands with."
  (with-current-buffer (or buffer (current-buffer))
    (mapcar (lambda (p) (nth 2 p)) drgnx-sticky--pins)))

(defun drgnx-sticky--pin-marks ()
  "The pins as scroll bar marks, each running to its region's end (the minimap's band)."
  (mapcar (lambda (p) (list (marker-position (nth 0 p)) 'left 'drgnx-marks-pin 1 nil (marker-position (nth 1 p))))
          drgnx-sticky--pins))

(defun drgnx-sticky--pins-changed ()
  "The pins changed: the scroll bar's marks and the minimap's names again."
  (setq drgnx-sticky--pins (sort drgnx-sticky--pins (lambda (a b) (< (nth 0 a) (nth 0 b)))))
  (when (fboundp 'drgnx-ruler-source)
    (drgnx-ruler-source 'pins (and drgnx-sticky--pins #'drgnx-sticky--pin-marks))))

(defun drgnx-sticky--pin-bounds ()
  "The region to pin: the selection, else the innermost scope holding point (the fold table's, else the line)."
  (cond ((use-region-p) (cons (region-beginning) (region-end)))
        ((when-let* ((r (and (fboundp 'drgnx-fold--range-at) (ignore-errors (drgnx-fold--range-at (point))))))
           (cons (nth 0 r) (nth 1 r))))
        (t (cons (line-beginning-position) (line-end-position)))))

(defun drgnx-sticky--pin-name (beg)
  "A pin's name: the symbol the line at BEG defines, else that line's text, shortened."
  (or (drgnx-sticky--text beg)
      (save-excursion (goto-char beg)
                      (truncate-string-to-width (string-trim (buffer-substring-no-properties (line-beginning-position)
                                                                                             (line-end-position)))
                                                32 nil nil "…"))))

(defun drgnx-pin-region (beg end &optional name)
  "Pin BEG..END (interactively the selection, else the scope at point) under NAME (default its symbol's name)."
  (interactive (let ((b (drgnx-sticky--pin-bounds))) (list (car b) (cdr b))))
  (let ((name (or name (drgnx-sticky--pin-name beg))))
    (push (list (copy-marker (save-excursion (goto-char beg) (line-beginning-position)))
                (copy-marker (save-excursion (goto-char end) (line-end-position)) t)
                name)
          drgnx-sticky--pins)
    (deactivate-mark)
    (drgnx-sticky--pins-changed)
    (message "Pinned %s" name)))

(defun drgnx-sticky--read-pin (prompt)
  "A pin of this buffer: the one holding point, else the only one, else one read with PROMPT (the palette's
\"Pinned\" list)."
  (or (seq-find (lambda (p) (<= (nth 0 p) (point) (nth 1 p))) drgnx-sticky--pins)
      (and (null (cdr drgnx-sticky--pins)) (car drgnx-sticky--pins))
      (let* ((items (mapcar (lambda (p) (cons (format "%s (line %d)" (nth 2 p) (line-number-at-pos (nth 0 p))) p))
                            drgnx-sticky--pins))
             (choice (completing-read prompt items nil t)))
        (cdr (assoc choice items)))))

(defun drgnx-unpin-region ()
  "Remove a pin: the one at point, else one chosen from the buffer's pins."
  (interactive)
  (unless drgnx-sticky--pins (user-error "No pinned regions in this buffer"))
  (let ((pin (drgnx-sticky--read-pin "Unpin: ")))
    (dolist (e drgnx-sticky--pin-shown)
      (when (eq (cdr e) pin) (drgnx-sticky-pin-show-off (car e))))
    (set-marker (nth 0 pin) nil)
    (set-marker (nth 1 pin) nil)
    (setq drgnx-sticky--pins (delq pin drgnx-sticky--pins))
    (drgnx-sticky--pins-changed)))

(defun drgnx-sticky-pin-show-off (w)
  "Window W's card stops showing its pin; the sticky scopes come back at the next redisplay."
  (setq drgnx-sticky--pin-shown (assq-delete-all w drgnx-sticky--pin-shown))
  (drgnx-sticky--hide w)
  (when (window-live-p w) (drgnx-epoch-bump 'sticky (window-buffer w)) (force-mode-line-update t)))

(defun drgnx-sticky--pin-lines (pin w)
  "The line beginnings of PIN's region that window W's card shows: at most a third of W's rows."
  (let ((max (max 3 (/ (window-body-height w) 3))) (out nil))
    (save-excursion
      (goto-char (nth 0 pin))
      (while (and (< (length out) max) (<= (point) (nth 1 pin)))
        (push (line-beginning-position) out)
        (when (/= 0 (forward-line 1)) (goto-char (1+ (nth 1 pin))))))
    (nreverse out)))

(defun drgnx-pin-show ()
  "Show a pinned region over the selected window's top rows (the pin at point, else one chosen); again: stop."
  (interactive)
  (let ((w (selected-window)))
    (if (assq w drgnx-sticky--pin-shown)
        (drgnx-sticky-pin-show-off w)
      (unless drgnx-sticky--pins (user-error "No pinned regions in this buffer"))
      (let ((pin (drgnx-sticky--read-pin "Show pinned: ")))
        (push (cons w pin) drgnx-sticky--pin-shown)
        (drgnx-sticky--fill w (drgnx-sticky--pin-lines pin w))))))

(defun drgnx-sticky--tail (w)
  "The chrome's tail provider (depth 20, after the large-file header): window W's sticky part,
in a buffer with sticky scroll."
  (and (buffer-local-value 'drgnx-sticky-mode (window-buffer w)) (drgnx-sticky--segment w)))

(define-minor-mode drgnx-sticky-mode
  "Sticky scroll: the scopes scrolled off the top, in the header after the breadcrumb."
  :lighter nil
  (if drgnx-sticky-mode
      (add-hook 'after-change-functions #'drgnx-sticky--after-change nil t)
    (remove-hook 'after-change-functions #'drgnx-sticky--after-change t)
    (dolist (w (get-buffer-window-list nil nil t)) (drgnx-sticky--hide w)))
  (when (and (bound-and-true-p drgnx-chrome-mode) (get-buffer-window)) (drgnx-chrome-apply)))   ; the header shows it now

(defun drgnx-sticky--maybe ()
  "`prog-mode-hook': sticky scroll in file buffers, not in a large file's."
  (when (and buffer-file-name (not (drgnx-large-file-p))) (drgnx-sticky-mode 1)))

(defun drgnx-sticky--teardown ()
  "Sticky scroll off in every live buffer that has it, the cards deleted, the pins gone (the hooks and the commands go
with the setup)."
  (when (fboundp 'drgnx-chrome-remove-tail-provider) (drgnx-chrome-remove-tail-provider #'drgnx-sticky--tail))
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when drgnx-sticky-mode (drgnx-sticky-mode -1))
      (when drgnx-sticky--pins
        (dolist (p drgnx-sticky--pins) (set-marker (nth 0 p) nil) (set-marker (nth 1 p) nil))
        (setq drgnx-sticky--pins nil)
        (drgnx-sticky--pins-changed))))
  (drgnx-sticky--hide-all t))

(drgnx-module-define 'editor/sticky
                     :doc "Sticky scroll: the function (class, block) you are in, when its start has scrolled off, after the breadcrumb."
                     :stage 'startup
                     :teardown #'drgnx-sticky--teardown
                     :setup (lambda ()
                              (drgnx-memo-activate 'sticky-segment)
                              (eval-after-load 'drgnx-chrome
                                (drgnx-modules-with-owner (drgnx-chrome-add-tail-provider #'drgnx-sticky--tail 20)))
                              (add-hook 'prog-mode-hook #'drgnx-sticky--maybe)
                              ;; the cards follow their windows: the store's events (a setup's subscriptions go
                              ;; with it)
                              (when (fboundp 'drgnx-state-subscribe)
                                (dolist (event '(pane-resized windows-changed))
                                  (drgnx-state-subscribe event #'drgnx-sticky--windows-moved :lane 'now)))
                              (drgnx-command-define 'toggle-sticky-scroll :category "View" :title "Toggle Sticky Scroll"
                                                    :command #'drgnx-sticky-mode :doc "The enclosing scopes in the header, off or on")
                              (drgnx-command-define 'pin-region :category "Edit" :title "Pin Region"
                                                    :command #'drgnx-pin-region
                                                    :doc "Pin the selection or the scope at point: a band on the minimap, shown on demand")
                              (drgnx-command-define 'unpin-region :category "Edit" :title "Unpin Region"
                                                    :command #'drgnx-unpin-region :doc "Remove a pinned region")
                              (drgnx-command-define 'pin-show :category "View" :title "Show Pinned Region"
                                                    :command #'drgnx-pin-show
                                                    :doc "A pinned region over the window's top rows, off or on")))

(provide 'drgnx-sticky)
;;; drgnx-sticky.el ends here
