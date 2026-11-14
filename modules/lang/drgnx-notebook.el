;;; drgnx-notebook.el --- Module lang/notebook: Jupyter notebooks as one buffer of cell blocks -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A `.ipynb' file opens in `drgnx-notebook-mode' (docs/guide/notebooks.md; design: docs/specs/drgnx/2026-11-14-jupyter-tier1-design.md,
;; §4).  The hub owns the notebook (cells, outputs, the file's bytes) and its kernel; the buffer owns what the user types.
;;
;; One buffer.  A cell is HEAD, SOURCE, TAIL.  The head and the tail are each one boundary character (a newline), read-only,
;; carrying the text property `drgnx-cell' (ID . PART), PART `head' or `tail', and `drgnx-cell-type' (code, markdown, raw).
;; Undo restores text properties with the text, so a split, merge, move or delete and their undo are text edits, and the cell
;; ranges are derived from the property (`drgnx-notebook--cells', cached).  Lisp never scans on a keystroke: a change only
;; marks the buffer dirty and starts a debounce (`drgnx-timer-debounce'); the idle rescan walks the property's changes, not the text.
;;
;; The chrome is an overlay on each boundary character: the head's `before-string' is the header strip (the run button, the
;; prompt, the cell type), the tail's `after-string' the output.  (The design says after-string for both: a head after-string
;; lands on the source's first row, so the strip would not have a row of its own.)  The hub builds each tail whole (text, runs,
;; images: `notebook-tail'); Lisp only puts it: `overlay-put' touches no undo, no modified flag and no change hook, so a
;; stream of 20 updates a second costs the buffer nothing.  A boundary that comes back by undo or yank has no overlay: the
;; rescan asks the hub for that cell's tail, so a restored boundary never shows a stale string.
;;
;; The hub's methods (`notebook/open', `/save', `/kernels', `/start', `/execute', `/interrupt', `/shutdown', `/input', `/tail',
;; `/output', `/close') and events (`notebook-tail', `notebook-status', `notebook-input-request') are called through
;; `drgnx-notebook--call' (tests bind it).  Nothing here prompts except the commands that ask the user a question.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-timer)
(require 'drgnx-hub-client)

(declare-function drgnx-notify "drgnx-notice")
(declare-function drgnx-view-patch-attach "drgnx-view")
(declare-function drgnx-view-env-register "drgnx-view-env")
(declare-function drgnx-view-env-unregister "drgnx-view-env")
(declare-function drgnx-view-env-twin "drgnx-view-env")
(declare-function drgnx-view-env-update "drgnx-view-env")
(declare-function drgnx-notice-define-source "drgnx-notice")
(declare-function drgnx-state-subscribe "drgnx-state")
(declare-function drgnx-look-icon "drgnx-icons" (name &optional face size))

(defgroup drgnx-notebook nil "Jupyter notebooks in drgnx." :group 'drgnx)

;;;; Faces: named as the future block's fill (the band look ships first), so the block primitive is one more property

(defface drgnx-notebook-cell '((t :inherit drgnx-surface-panel :extend t))
  "The rows of a cell that is not selected." :group 'drgnx-notebook)
(defface drgnx-notebook-cell-selected '((t :inherit drgnx-selected-quiet :extend t))
  "The rows of the selected cell." :group 'drgnx-notebook)
(defface drgnx-notebook-head '((t :inherit (drgnx-ui-caption drgnx-text-muted) :extend t))
  "A cell's header strip." :group 'drgnx-notebook)
(defface drgnx-notebook-prompt '((t :inherit (drgnx-code-small drgnx-text-subtle)))
  "The execution count of a code cell: [3], [*] while it runs." :group 'drgnx-notebook)
(defface drgnx-notebook-run-button '((t :inherit drgnx-control))
  "A cell's run button." :group 'drgnx-notebook)
(defface drgnx-notebook-chip '((t :inherit drgnx-chip-quiet))
  "A cell's type, and the kernel's state, in its header." :group 'drgnx-notebook)
(defface drgnx-notebook-output '((t :inherit (drgnx-code-small) :extend t))
  "A cell's output." :group 'drgnx-notebook)
(defface drgnx-notebook-error '((t :inherit drgnx-chip-error :extend t))
  "A cell's error output." :group 'drgnx-notebook)
(defface drgnx-notebook-stale '((t :inherit drgnx-text-subtle))
  "An output that came from the file, not from a run in this session." :group 'drgnx-notebook)
(defface drgnx-notebook-cut '((t :inherit (drgnx-text-muted drgnx-selected-quiet) :extend t))
  "A view's cut row (`N lines above' and `below'): a quiet tint across the row." :group 'drgnx-notebook)
(defface drgnx-notebook-error-row '((t :inherit drgnx-chip-error :extend t))
  "An error's rows in a view: the error tint across the row, never a solid block." :group 'drgnx-notebook)
(defface drgnx-notebook-current-row '((t :inherit drgnx-selected-quiet :extend t))
  "The outline's row of the cell point is in: the selected row's look." :group 'drgnx-notebook)
(defface drgnx-notebook-inverse '((t :inverse-video t))
  "Output text the terminal showed in reverse video (the hub's views name it, never a colour)." :group 'drgnx-notebook)

;; The terminal's sixteen roles, as foreground and as background faces (the themes set them: themes/drgnx-theme-gen.el);
;; the fallback is the text colour, so an output is readable under any theme.
(eval-and-compile
  (defconst drgnx-notebook--ansi-names
    [black red green yellow blue magenta cyan white bright-black bright-red bright-green bright-yellow bright-blue
           bright-magenta bright-cyan bright-white]
    "The terminal's sixteen roles, in the hub's order (0 to 15)."))

(defmacro drgnx-notebook--define-ansi-faces ()
  "Define `drgnx-notebook-fg-NAME' and `drgnx-notebook-bg-NAME' for the sixteen roles."
  `(progn
     ,@(cl-loop for name across drgnx-notebook--ansi-names
                append (list `(defface ,(intern (format "drgnx-notebook-fg-%s" name)) '((t :inherit default))
                                "A terminal foreground role in a notebook's output." :group 'drgnx-notebook)
                             `(defface ,(intern (format "drgnx-notebook-bg-%s" name)) '((t :inherit default))
                                "A terminal background role in a notebook's output." :group 'drgnx-notebook)))))
(drgnx-notebook--define-ansi-faces)

;;;; State

(defvar-local drgnx-notebook--id nil "The hub's id of this buffer's notebook, nil until `notebook/open' answered.")
(defvar-local drgnx-notebook--cells nil
  "The cells as the last rescan found them: a list of (:id ID :type TYPE :head POS :tail POS) in buffer order.")
(defvar-local drgnx-notebook--dirty nil "Non-nil after a change the rescan has not seen.")
(defvar-local drgnx-notebook--chrome (make-hash-table :test #'equal)
  "ID → (:head OV :tail OV :body OV): the overlays of a cell.")
(defvar-local drgnx-notebook--known (make-hash-table :test #'equal)
  "ID → t: cells the hub holds (a cell minted here is known after the first sync).")
(defvar-local drgnx-notebook--heads (make-hash-table :test #'equal)
  "ID → the hub's head of the cell (:text :state :runs), from its last tail: the header strip after the button.")
(defvar-local drgnx-notebook--selected-id nil "The selected cell's id: its output is tinted selected and has the add-cell row.")
(defvar-local drgnx-notebook--queue 0 "How many cells wait for the kernel, as the hub last said.")
(defvar-local drgnx-notebook--retry nil "Non-nil when the first open got no answer (no hub, or it went away): asked again at the next
connect.")
(defvar-local drgnx-notebook--state "idle" "The kernel's state as the hub last said: idle, busy, starting, dead.")
(defvar-local drgnx-notebook--running nil "The cell the kernel runs now, or nil.")
(defvar-local drgnx-notebook--selected nil "The overlay that tints the selected cell.")
(defvar-local drgnx-notebook--language nil "The notebook's language (python), for the cells' chip.")
(defvar-local drgnx-notebook--kernel nil "The kernelspec the hub started, or nil.")
(defvar-local drgnx-notebook--tails (make-hash-table :test #'equal) "ID → the version of the last tail put.")
(defvar-local drgnx-notebook--outputs-hidden nil "Non-nil while the outputs are hidden.")
(defvar-local drgnx-notebook--images (make-hash-table :test #'equal)
  "(CELL OUTPUT MIME WIDTH HEIGHT) → the image spec drawn, or `pending' or `failed'; dropped when the cell runs again.")
(defvar-local drgnx-notebook--last-tails (make-hash-table :test #'equal) "ID → the last tail put, for the redraw an image fetch ends with.")
(defvar-local drgnx-notebook--rescans 0 "How many rescans ran (for the tests).")

(defvar drgnx-notebook--buffers (make-hash-table :test #'equal :weakness 'value)
  "Hub notebook id → its buffer.")

(defvar drgnx-notebook--clipboard nil "The cell cut or copied last: (:type TYPE :source SOURCE).")

(defconst drgnx-notebook--debounce 0.12 "Seconds of quiet before the rescan.")

;;;; The hub

(defvar drgnx-hub--events)
(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-hub--settle "drgnx-hub-client")

(defun drgnx-notebook--conn ()
  "The connection the notebook's calls go on: this Emacs's subscribed one.  The hub keeps a notebook, its events and
its views (`view/env' comes on this connection too) per connection, so all of them must be on the one the events
come back on."
  (if (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
      drgnx-hub--events
    (error "The drgnx hub is not subscribed")))

(defun drgnx-notebook--call (method params callback &optional full)
  "Ask the hub METHOD with PARAMS; CALLBACK gets (RESULT ERROR).  The one place the notebook buffer reaches the hub.
No hub to ask is an error for the callback, not for the caller (an open buffer must not fail because the hub is down).
With FULL the hub's own error is a plist (:code :message), so it can be told from this side's, a string."
  (condition-case err (drgnx-hub--call-on (drgnx-notebook--conn) method params callback :full full)
    (error (funcall callback nil (error-message-string err)) nil)))

(defun drgnx-notebook--call-sync (method params &optional timeout)
  "METHOD's result, waiting up to TIMEOUT seconds on the notebook's connection (a save is a command the user gave)."
  (let* ((conn (drgnx-notebook--conn)) (done nil) result error
         (limit (+ (float-time (time-convert nil t)) (or timeout 5) 1))
         (id (drgnx-hub--call-on conn method params (lambda (r e) (setq done t result r error e)) :deadline (or timeout 5))))
    (while (and (not done) (< (float-time (time-convert nil t)) limit))
      (accept-process-output conn 0.02))
    (unless done (drgnx-hub--settle id nil "gave up"))
    (cond ((not done) (error "The drgnx hub did not answer %s" method))
          (error (error "drgnx hub: %s" error))
          (t result))))

(defun drgnx-notebook--say (format &rest args)
  "Say something about a notebook (a refusal, a failed call): a notice of source `notebook' (the Notices list, once in
the echo area when it matters), not a message: most callers are hub callbacks."
  (drgnx-notify 'notebook 'warn (apply #'format format args)))

(defun drgnx-notebook--sync-cells ()
  "The cells' id, type and source, for the hub: a vector of plists."
  (drgnx-notebook--rescan)
  (vconcat
   (mapcar (lambda (c)
             (list :id (plist-get c :id) :type (symbol-name (plist-get c :type))
                   :source (buffer-substring-no-properties (1+ (plist-get c :head)) (plist-get c :tail))))
           drgnx-notebook--cells)))

(defun drgnx-notebook--mark-known ()
  "After a sync every cell of the buffer is known to the hub."
  (dolist (c drgnx-notebook--cells) (puthash (plist-get c :id) t drgnx-notebook--known)))

;;;; Boundaries

(defun drgnx-notebook--boundary (id part type)
  "The boundary character of cell ID: PART `head' or `tail', cell TYPE.  Read-only;
text typed next to it is not part of it."
  (propertize "\n" 'drgnx-cell (cons id part) 'drgnx-cell-type type 'read-only t 'rear-nonsticky t))

(defun drgnx-notebook--cell-text (id type source)
  "The text of a cell: head, SOURCE, tail."
  (concat (drgnx-notebook--boundary id 'head type) source (drgnx-notebook--boundary id 'tail type)))

(defun drgnx-notebook--mint ()
  "A fresh cell id (nbformat: 1 to 64 of letters, digits, - and _)."
  (format "c%08x" (random (ash 1 32))))

(defun drgnx-notebook--scan ()
  "The boundary characters of the buffer, ((POS ID PART TYPE)…), found by the property's changes (never the text)."
  (let ((pos (point-min)) (max (point-max)) found)
    (while (< pos max)
      (let ((v (get-text-property pos 'drgnx-cell)))
        (if v
            (progn (push (list pos (car v) (cdr v) (get-text-property pos 'drgnx-cell-type)) found)
                   (setq pos (1+ pos)))
          (setq pos (or (next-single-property-change pos 'drgnx-cell nil max) max)))))
    (nreverse found)))

(defun drgnx-notebook--strip (pos)
  "Make the character at POS an ordinary newline again (an orphan boundary)."
  (with-silent-modifications
    (remove-list-of-text-properties pos (1+ pos) '(drgnx-cell drgnx-cell-type read-only rear-nonsticky))))

(defun drgnx-notebook--retag (head tail id)
  "Give the boundaries at HEAD and TAIL the cell id ID."
  (with-silent-modifications
    (put-text-property head (1+ head) 'drgnx-cell (cons id 'head))
    (put-text-property tail (1+ tail) 'drgnx-cell (cons id 'tail))))

(defun drgnx-notebook--pair (boundaries)
  "BOUNDARIES (from `drgnx-notebook--scan') as cells: a head and the next tail of its id.  Orphans lose the property; a
repeated id is re-minted (a second cell with an id the buffer already has gets a new one, and the log says so)."
  (let (cells open (seen (make-hash-table :test #'equal)))
    (dolist (b boundaries)
      (pcase-let ((`(,pos ,id ,part ,type) b))
        (pcase part
          ('head (when open (drgnx-notebook--strip (car open)))
                 (setq open b))
          ('tail (if (and open (equal (nth 1 open) id))
                     (let ((head (car open)) (id id))
                       (when (gethash id seen)
                         (let ((new (drgnx-notebook--mint)))
                           (drgnx-notebook--say "cell id %s was repeated; the second is %s" id new)
                           (drgnx-notebook--retag head pos new)
                           (setq id new)))
                       (puthash id t seen)
                       (push (list :id id :type (or (nth 3 open) 'code) :head head :tail pos) cells)
                       (setq open nil))
                   (drgnx-notebook--strip pos)
                   (when open (drgnx-notebook--strip (car open)) (setq open nil)))))
        (ignore type)))
    (when open (drgnx-notebook--strip (car open)))
    (nreverse cells)))

;;;; Overlays: the chrome

(defun drgnx-notebook--icon (name face)
  "The icon NAME in FACE as a string (the character when no icon draws)."
  (if (fboundp 'drgnx-look-icon) (drgnx-look-icon name face) (propertize "▶" 'face face)))

(defvar drgnx-notebook-run-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-1] #'drgnx-notebook-run-cell-at-mouse)
    m)
  "The keymap of a cell's run button.")

(defun drgnx-notebook-run-cell-at-mouse (event)
  "Run the cell whose run button EVENT clicked."
  (interactive "e")
  (let* ((ps (posn-string (event-end event)))
         (id (and ps (get-text-property (cdr ps) 'drgnx-notebook-run (car ps)))))
    (when id (drgnx-notebook--run-ids (list id)))))

(defvar drgnx-notebook-add-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-1] #'drgnx-notebook-add-cell-at-mouse)
    m)
  "The keymap of the add-cell row's buttons.")

(defun drgnx-notebook-add-cell-at-mouse (event)
  "Add a cell below the selected one, of the type of the button EVENT clicked (+ Code, + Markdown)."
  (interactive "e")
  (let* ((ps (posn-string (event-end event))) (type (and ps (get-text-property (cdr ps) 'drgnx-notebook-add (car ps)))))
    (when type (drgnx-notebook-add-cell-below type))))

(defun drgnx-notebook--add-row ()
  "The row under the selected cell: + Code and + Markdown, chips that add a cell below."
  (concat (propertize "+ Code" 'face 'drgnx-notebook-chip 'drgnx-notebook-add 'code 'keymap drgnx-notebook-add-map
                      'mouse-face 'drgnx-hover 'help-echo "Add a code cell below")
          " "
          (propertize "+ Markdown" 'face 'drgnx-notebook-chip 'drgnx-notebook-add 'markdown 'keymap drgnx-notebook-add-map
                      'mouse-face 'drgnx-hover 'help-echo "Add a markdown cell below")
          (propertize "\n" 'face 'drgnx-notebook-cell-selected)))

(defun drgnx-notebook--styled (text runs &rest base)
  "A copy of TEXT with the BASE faces on all of it and each of RUNS' faces (the hub's roles) on its stretch."
  (let* ((s (copy-sequence text)) (n (length s)))
    (when (> n 0)
      (dolist (face base) (add-face-text-property 0 n face nil s))
      (dolist (run runs)
        (let ((start (min n (or (plist-get run :start) 0))) (end (min n (or (plist-get run :end) 0)))
              (faces (drgnx-notebook--run-faces run)))
          (when (< start end) (dolist (face faces) (add-face-text-property start end face nil s))))))
    s))

(defun drgnx-notebook--head-string (id type)
  "The header strip of cell ID (`drgnx-notebook--head-strip'), without the band look's hairline when the cell is a card:
the card's ring is its edge."
  (let ((s (drgnx-notebook--head-strip id type)))
    (when (drgnx-notebook--cards-p) (add-face-text-property 0 (length s) '(:overline nil) nil s))
    s))

(defun drgnx-notebook--head-strip (id type)
  "The header strip of cell ID: the run button (the editor's) and the head the hub built (`[3]  python'), else the type
until the hub has sent a head (a new cell, a markdown cell).  Built when a head arrives, never while redisplay draws."
  (let ((head (gethash id drgnx-notebook--heads)))
    (concat
     (if (eq type 'code)
         (concat (propertize (drgnx-notebook--icon 'play 'drgnx-notebook-run-button)
                             'drgnx-notebook-run id 'keymap drgnx-notebook-run-map 'mouse-face 'drgnx-hover
                             'help-echo "Run this cell")
                 " ")
       "")
     (drgnx-notebook--styled (or (plist-get head :text) (symbol-name type)) (plist-get head :runs) 'drgnx-notebook-head)
     (propertize " " 'face 'drgnx-notebook-head))))

(defun drgnx-notebook--chrome-of (id) (gethash id drgnx-notebook--chrome))

(defun drgnx-notebook--overlay (beg end kind id)
  "A new overlay of KIND on BEG..END for cell ID: it goes when its text goes, and takes no text typed at its edges."
  (let ((ov (make-overlay beg end nil t nil)))
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'drgnx-notebook-kind kind)
    (overlay-put ov 'drgnx-notebook-id id)
    ov))

(defun drgnx-notebook--live-at-p (ov pos)
  (and ov (overlay-buffer ov) (= (overlay-start ov) pos)))

(defun drgnx-notebook--sync-chrome ()
  "Make each cell's overlays match the cells (after a rescan): keep those in place, make the missing, drop the rest.
A tail boundary with no overlay (restored by undo or yank, or moved) asks the hub for the cell's tail when a tail
of it was ever shown."
  (let ((ids (make-hash-table :test #'equal)) restored)
    (dolist (c drgnx-notebook--cells)
      (let* ((id (plist-get c :id)) (type (plist-get c :type)) (head (plist-get c :head)) (tail (plist-get c :tail))
             (set (or (drgnx-notebook--chrome-of id) (list :head nil :tail nil :body nil))))
        (puthash id t ids)
        (unless (drgnx-notebook--live-at-p (plist-get set :head) head)
          (when (plist-get set :head) (delete-overlay (plist-get set :head)))
          (setq set (plist-put set :head (drgnx-notebook--overlay head (1+ head) 'head id)))
          (overlay-put (plist-get set :head) 'before-string (drgnx-notebook--head-string id type)))
        (unless (drgnx-notebook--live-at-p (plist-get set :tail) tail)
          (when (plist-get set :tail) (delete-overlay (plist-get set :tail)))
          (setq set (plist-put set :tail (drgnx-notebook--overlay tail (1+ tail) 'tail id)))
          (when (and (gethash id drgnx-notebook--known) (gethash id drgnx-notebook--tails)) (push id restored)))
        (let ((body (plist-get set :body)))
          (unless (and body (overlay-buffer body) (= (overlay-start body) head) (= (overlay-end body) (1+ tail)))
            (when body (delete-overlay body))
            (setq body (drgnx-notebook--overlay head (1+ tail) 'body id))
            (overlay-put body 'face 'drgnx-notebook-cell)
            (overlay-put body 'priority -10)
            (setq set (plist-put set :body body))))
        (puthash id set drgnx-notebook--chrome)))
    (maphash (lambda (id set)
               (unless (gethash id ids)
                 (dolist (k '(:head :tail :body)) (when-let* ((ov (plist-get set k))) (delete-overlay ov)))
                 (remhash id drgnx-notebook--chrome)))
             drgnx-notebook--chrome)
    (dolist (id (nreverse restored)) (drgnx-notebook--request-tail id))
    (drgnx-notebook--select-at (point))
    (drgnx-notebook--blocks-update)))

(defun drgnx-notebook--refresh-head (id)
  "Build cell ID's header strip again (its type, prompt or the running cell changed)."
  (when-let* ((c (drgnx-notebook--cell-by-id id))
              (ov (plist-get (drgnx-notebook--chrome-of id) :head)))
    (overlay-put ov 'before-string (drgnx-notebook--head-string id (plist-get c :type)))))

;;;; The rescan

(defun drgnx-notebook--rescan ()
  "Find the cells again from the boundary property, then bring the overlays along.
Idempotent; cheap when nothing changed."
  (when (or drgnx-notebook--dirty (null drgnx-notebook--cells))
    (setq drgnx-notebook--dirty nil)
    (cl-incf drgnx-notebook--rescans)
    (setq drgnx-notebook--cells (drgnx-notebook--pair (drgnx-notebook--scan)))
    (drgnx-notebook--sync-chrome)
    (drgnx-notebook--sync-parsers))
  drgnx-notebook--cells)

(defun drgnx-notebook--changed (&rest _)
  "`after-change-functions': note it and start the debounce; nothing is read here."
  (setq drgnx-notebook--dirty t)
  (drgnx-timer-debounce (cons 'drgnx-notebook (current-buffer)) drgnx-notebook--debounce
                        #'drgnx-notebook--rescan-in :args (list (current-buffer)) :owner (current-buffer)))

(defun drgnx-notebook--rescan-in (buffer)
  (when (buffer-live-p buffer) (with-current-buffer buffer (drgnx-notebook--rescan))))

(defun drgnx-notebook--cell-by-id (id)
  (seq-find (lambda (c) (equal (plist-get c :id) id)) drgnx-notebook--cells))

(defun drgnx-notebook--cell-at (&optional pos)
  "The cell holding POS (default point): the cells are in buffer order, so a binary search over the cached ranges."
  (drgnx-notebook--rescan)
  (let* ((pos (or pos (point))) (v (vconcat drgnx-notebook--cells)) (lo 0) (hi (1- (length v))) found)
    (while (and (<= lo hi) (not found))
      (let* ((mid (/ (+ lo hi) 2)) (c (aref v mid)))
        (cond ((< pos (plist-get c :head)) (setq hi (1- mid)))
              ((> pos (plist-get c :tail)) (setq lo (1+ mid)))
              (t (setq found c)))))
    found))

(defun drgnx-notebook--focus (cell)
  "Tell the hub which CELL point is in (none: omitted), so its outline marks the row; asked when it changes, not per move."
  (when drgnx-notebook--id
    (drgnx-notebook--call "notebook/focus" (append (list :id drgnx-notebook--id) (and cell (list :cell cell))) #'ignore)))

(defun drgnx-notebook--select-at (pos)
  "Tint the cell at POS as the selected one (one overlay, moved); its output takes the selected tint and the add row
and the cell it left goes back (their strings are built again from their last tails: two cells, not a scan)."
  (let* ((c (and drgnx-notebook--cells (drgnx-notebook--cell-at pos)))
         (old drgnx-notebook--selected-id)
         (new (and c (plist-get c :id))))
    (setq drgnx-notebook--selected-id new)
    (unless (equal old new)
      (dolist (id (delq nil (list old new))) (drgnx-notebook--refresh-tail id))
      (drgnx-notebook--blocks-update)
      (drgnx-notebook--focus new)
      (when (fboundp 'drgnx-statusbar-refresh) (drgnx-statusbar-refresh t)))
    (cond ((null c) (when drgnx-notebook--selected (delete-overlay drgnx-notebook--selected)))
          (t (unless drgnx-notebook--selected
               (setq drgnx-notebook--selected (make-overlay (plist-get c :head) (1+ (plist-get c :tail))))
               (overlay-put drgnx-notebook--selected 'face 'drgnx-notebook-cell-selected)
               (overlay-put drgnx-notebook--selected 'priority -5))
             (move-overlay drgnx-notebook--selected (plist-get c :head) (1+ (plist-get c :tail)) (current-buffer))))))

(defun drgnx-notebook--post-command ()
  "Move the selected tint when point left its cell: a comparison with the tint's ends, no scan."
  (when (and drgnx-notebook--selected (overlay-buffer drgnx-notebook--selected)
             (or (< (point) (overlay-start drgnx-notebook--selected))
                 (>= (point) (overlay-end drgnx-notebook--selected))))
    (drgnx-notebook--select-at (point))))

;;;; Tails

(defun drgnx-notebook--run-faces (run)
  "The face list of the style RUN (a plist from the hub: :fg :bg :bold :italic :underline :inverse)."
  (let (faces)
    (when-let* ((fg (plist-get run :fg)) ((<= 0 fg 15)))
      (push (intern (format "drgnx-notebook-fg-%s" (aref drgnx-notebook--ansi-names fg))) faces))
    (when-let* ((bg (plist-get run :bg)) ((<= 0 bg 15)))
      (push (intern (format "drgnx-notebook-bg-%s" (aref drgnx-notebook--ansi-names bg))) faces))
    (when (plist-get run :bold) (push 'bold faces))
    (when (plist-get run :italic) (push 'italic faces))
    (when (plist-get run :underline) (push 'underline faces))
    (when (plist-get run :inverse) (push '(:inverse-video t) faces))
    faces))

(defun drgnx-notebook--tail-string (tail &optional selected)
  "The string put after a cell's tail boundary, from the hub's TAIL (:text :runs :more_lines :stale): its text with the
runs' faces on it and a newline (the next row is the next cell's header).  SELECTED: the selected tint and the
and the add-cell row follows."
  (let* ((text (or (plist-get tail :text) "")) (n (length text)) (cell (if selected 'drgnx-notebook-cell-selected 'drgnx-notebook-cell)))
    (concat
     (if (zerop n) ""
       (let ((s (drgnx-notebook--styled text (plist-get tail :runs) (if (plist-get tail :stale) 'drgnx-notebook-stale 'drgnx-notebook-output) cell)))
         (dolist (image (reverse (plist-get tail :images)))   ; last first: a label is longer than the character it replaces
           (let ((at (plist-get image :at)))
             (when (and at (< at n) (eq (aref s at) #xfffc))
               (setq s (concat (substring s 0 at) (drgnx-notebook--image-piece tail image) (substring s (1+ at)))))))
         (concat s (propertize "\n" 'face cell))))
     (if selected (drgnx-notebook--add-row) ""))))

;;; Images (static PNG and JPEG; SVG is not in tier 1): one character each in the tail, drawn from the hub's full output

(defconst drgnx-notebook--image-types '(("image/png" . png) ("image/jpeg" . jpeg)) "The image MIME types drawn, with their image type.")
(declare-function drgnx-px "drgnx-pixels" (logical &optional frame scale))

(defun drgnx-notebook--image-key (tail image)
  (list (plist-get tail :cell) (plist-get image :output) (plist-get image :mime) (plist-get image :width) (plist-get image :height)))

(defun drgnx-notebook--image-piece (tail image)
  "What replaces the image character of IMAGE in TAIL's text: the picture when it is here, else a label."
  (let ((spec (gethash (drgnx-notebook--image-key tail image) drgnx-notebook--images)))
    (if (consp spec)
        (propertize " " 'display spec)
      (propertize (format "[%s %s×%s]" (plist-get image :mime) (plist-get image :width) (plist-get image :height))
                  'face 'drgnx-notebook-stale))))

(defun drgnx-notebook--image-spec (bytes type)
  "The image spec of BYTES of TYPE, no taller than a window's worth of rows (the inline cap of outputs)."
  (list 'image :type type :data bytes :ascent 'center
        :max-height (if (fboundp 'drgnx-px) (drgnx-px 240) 240) :max-width (if (fboundp 'drgnx-px) (drgnx-px 720) 720)))

(defun drgnx-notebook--output-image (output mime)
  "The bytes of the image of MIME in the nbformat OUTPUT, or nil."
  (when-let* ((data (plist-get (plist-get output :data) (intern (concat ":" mime))))
              (text (if (listp data) (apply #'concat data) data)))
    (ignore-errors (base64-decode-string (replace-regexp-in-string "[ \t\r\n]" "" text)))))

(defun drgnx-notebook--want-images (tail)
  "Fetch what TAIL's images need that is not here: one `notebook/output' for the cell, however many images."
  (let (wanted)
    (dolist (image (plist-get tail :images))
      (let ((key (drgnx-notebook--image-key tail image)))
        (when (and (assoc (plist-get image :mime) drgnx-notebook--image-types) (null (gethash key drgnx-notebook--images)))
          (puthash key 'pending drgnx-notebook--images)
          (push (cons key image) wanted))))
    (when (and wanted drgnx-notebook--id)
      (let ((buffer (current-buffer)) (id (plist-get tail :cell)))
        (drgnx-notebook--call
         "notebook/output" (list :id drgnx-notebook--id :cell id)
         (lambda (r e)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (let ((outputs (and (not e) (plist-get r :outputs))))
                 (dolist (w wanted)
                   (let* ((image (cdr w)) (mime (plist-get image :mime))
                          (bytes (and (listp outputs) (drgnx-notebook--output-image (nth (or (plist-get image :output) 0) outputs) mime))))
                     (puthash (car w) (if bytes (drgnx-notebook--image-spec bytes (cdr (assoc mime drgnx-notebook--image-types))) 'failed)
                              drgnx-notebook--images)))
                 (when-let* ((last (gethash id drgnx-notebook--last-tails))) (drgnx-notebook--put-tail last)))))))))))

(defun drgnx-notebook--forget-images (id)
  "Forget the images of cell ID: it runs again, and an image at the same place may be another."
  (let (gone)
    (maphash (lambda (k _) (when (equal (car k) id) (push k gone))) drgnx-notebook--images)
    (dolist (k gone) (remhash k drgnx-notebook--images))))

(defun drgnx-notebook--put-tail (tail)
  "Put the hub's TAIL after its cell: only when it is newer than the one shown."
  (let* ((id (plist-get tail :cell)) (ov (plist-get (drgnx-notebook--chrome-of id) :tail))
         (version (or (plist-get tail :version) 0)))
    (when (and ov (overlay-buffer ov) (>= version (or (gethash id drgnx-notebook--tails) 0)))
      (puthash id version drgnx-notebook--tails)
      (puthash id tail drgnx-notebook--last-tails)
      (drgnx-notebook--want-images tail)
      (when-let* ((head (plist-get tail :head))) (puthash id head drgnx-notebook--heads) (drgnx-notebook--refresh-head id))
      (overlay-put ov 'after-string (drgnx-notebook--tail-string tail (equal id drgnx-notebook--selected-id))))))

(defun drgnx-notebook--refresh-tail (id)
  "Build cell ID's output string again from its last tail (or none): the selection moved onto or off the cell."
  (when-let* ((ov (plist-get (drgnx-notebook--chrome-of id) :tail)) ((overlay-buffer ov)))
    (overlay-put ov 'after-string
                 (drgnx-notebook--tail-string (or (gethash id drgnx-notebook--last-tails) (list :cell id))
                                              (equal id drgnx-notebook--selected-id)))))

(defun drgnx-notebook--request-tail (id)
  "Ask the hub for cell ID's tail (a boundary came back, or a cell moved): the string comes from the hub's state."
  (let ((buffer (current-buffer)) (nb drgnx-notebook--id))
    (when nb
      (drgnx-notebook--call "notebook/tail" (list :id nb :cell id)
                            (lambda (r e)
                              (when (and r (not e) (buffer-live-p buffer))
                                (with-current-buffer buffer (drgnx-notebook--put-tail r))))))))

;;;; Tree-sitter: one parser per language, its included ranges the union of that language's cells (design §4.6)

(declare-function treesit-available-p "treesit.c")
(declare-function treesit-language-available-p "treesit.c")
(declare-function treesit-parser-create "treesit.c")
(declare-function treesit-parser-list "treesit.c")
(declare-function treesit-parser-language "treesit.c")
(declare-function treesit-parser-set-included-ranges "treesit.c")
(declare-function treesit-parser-delete "treesit.c")
(declare-function treesit-major-mode-setup "treesit")
(defvar treesit-font-lock-settings)
(defvar treesit-font-lock-feature-list)
(defvar treesit-language-at-point-function)

(defvar-local drgnx-notebook--ranges nil "The language ranges the parsers hold now: ((NAME . RANGES)…).")

(defun drgnx-notebook--cell-language (type)
  "The language name of a cell of TYPE, or nil (raw cells have none)."
  (pcase type ('code drgnx-notebook--language) ('markdown "markdown")))

(defun drgnx-notebook--language-ranges (&optional cells)
  "Each language of the notebook's cells with the source ranges of its cells: ((NAME (BEG . END)…)…), in the order the
languages first appear.  An empty source has no range.
CELLS: the cells to read (default the buffer's, found again when it changed)."
  (let (result)
    (dolist (c (or cells (drgnx-notebook--rescan)))
      (when-let* ((lang (drgnx-notebook--cell-language (plist-get c :type)))
                  (beg (1+ (plist-get c :head))) (end (plist-get c :tail)) ((< beg end)))
        (let ((cell (or (assoc lang result) (car (push (list lang) result)))))
          (setcdr cell (append (cdr cell) (list (cons beg end)))))))
    (nreverse result)))

(defun drgnx-notebook--language-at-point ()
  "`treesit-language-at-point-function': the language of the cell at point, a symbol, or nil."
  (when-let* ((c (drgnx-notebook--cell-at)) (lang (drgnx-notebook--cell-language (plist-get c :type))))
    (intern lang)))

(defun drgnx-notebook--sync-parsers (&optional cells)
  "One parser for each language of the cells that has a grammar, its included ranges the union of its cells' sources;
a parser of a language no cell has any more goes.  Does nothing when the ranges are as they were."
  (when (and (fboundp 'treesit-available-p) (treesit-available-p))
    (let ((want (drgnx-notebook--language-ranges cells)))
      (unless (equal want drgnx-notebook--ranges)
        (setq drgnx-notebook--ranges want)
        (dolist (p (treesit-parser-list))
          (unless (assoc (symbol-name (treesit-parser-language p)) want) (treesit-parser-delete p)))
        (dolist (entry want)
          (let ((lang (intern (car entry))))
            (when (treesit-language-available-p lang)
              (let ((parser (or (seq-find (lambda (p) (eq (treesit-parser-language p) lang)) (treesit-parser-list))
                                (treesit-parser-create lang))))
                (treesit-parser-set-included-ranges parser (cdr entry))))))))))

(defun drgnx-notebook--ts-settings (lang)
  "(FONT-LOCK-SETTINGS . FEATURE-LIST) of LANG's tree-sitter mode, read from a scratch buffer, or nil."
  (let ((mode (intern (format "%s-ts-mode" lang))))
    (when (and (fboundp mode) (treesit-language-available-p (intern lang)))
      (condition-case nil
          (with-temp-buffer
            (delay-mode-hooks (funcall mode))
            (cons treesit-font-lock-settings treesit-font-lock-feature-list))
        (error nil)))))

(defun drgnx-notebook--setup-treesit (&optional cells)
  "Font-lock the cells by their languages' tree-sitter modes: their settings joined, the parsers' ranges set.  Never
fails the notebook: a language without a grammar or a mode stays plain text."
  (when (and (fboundp 'treesit-available-p) (treesit-available-p))
    (condition-case nil
        (let ((settings nil) (features nil))
          (dolist (entry (drgnx-notebook--language-ranges cells))
            (when-let* ((s (drgnx-notebook--ts-settings (car entry))))
              (setq settings (append settings (car s)))
              (let ((i 0))
                (dolist (level (cdr s))
                  (let ((have (nth i features)))
                    (if (< i (length features))
                        (setcar (nthcdr i features) (delete-dups (append have level)))
                      (setq features (append features (list level)))))
                  (cl-incf i)))))
          (when settings
            (setq-local treesit-font-lock-settings settings
                        treesit-font-lock-feature-list features
                        treesit-language-at-point-function #'drgnx-notebook--language-at-point)
            (setq drgnx-notebook--ranges nil)
            (drgnx-notebook--sync-parsers cells)
            (treesit-major-mode-setup)))
      (error nil))))

;;;; The card: Glitnir blocks
;; Each cell's rows (head, source, tail) are one `ring' block (`glitnir-blocks', Nidhogg's `glitnir.el', as the Flow's cards):
;; radius 10, its corners carved outside the rounded path in the colour of `default' beneath; the rows keep their own fill
;; (the cell faces' `:extend' band), the fringes are the card's side insets.  The ring is `drgnx-border-subtle', the
;; selected cell's `drgnx-border-strong', and `drgnx-focus-line' only on the selected cell of the selected window.  The
;; window parameter is set only when the blocks changed (a rescan, the selection, the focus), never per redisplay; Glitnir
;; takes the faces' colours again on a theme change.  Without Glitnir (a terminal) the band look stays.

(defconst drgnx-notebook--card-inset 16 "The card's inset from the window's sides, logical pixels (the mockup's body padding).")

(defvar-local drgnx-notebook--blocks nil
  "Alist FOCUSED → (KEY . BLOCKS): the `glitnir-blocks' value last given to a window that is (or is not) the selected one.")

(defun drgnx-notebook--cards-p ()
  "Non-nil when cells are drawn as cards: a graphical frame with Glitnir's blocks."
  (and (display-graphic-p) (fboundp 'glitnir--block-vector)))

(defun drgnx-notebook--blocks-key (focused)
  "What the blocks of a window are (FOCUSED: it is the selected one): one entry per cell, its positions and ring face."
  (let ((radius (drgnx-px 10)))
    (mapcar (lambda (c)
              (list (plist-get c :head) (1+ (plist-get c :tail)) radius
                    (cond ((not (equal (plist-get c :id) drgnx-notebook--selected-id)) 'drgnx-border-subtle)
                          (focused 'drgnx-focus-line)
                          (t 'drgnx-border-strong))))
            drgnx-notebook--cells)))

(defun drgnx-notebook--blocks-for (focused)
  "The `glitnir-blocks' value for a window (FOCUSED: the selected one).  The same object while nothing changed."
  (let* ((key (drgnx-notebook--blocks-key focused)) (entry (alist-get focused drgnx-notebook--blocks)))
    (if (equal key (car entry))
        (cl-loop for b in (cdr entry) for k in key
                 do (set-marker (nth 1 b) (nth 0 k)) (set-marker (nth 2 b) (nth 1 k)))
      (dolist (b (cdr entry)) (set-marker (nth 1 b) nil) (set-marker (nth 2 b) nil))
      (setf (alist-get focused drgnx-notebook--blocks)
            (cons key (mapcar (lambda (k) (list 'ring (copy-marker (nth 0 k)) (copy-marker (nth 1 k))
                                                :radius (nth 2 k) :ring (nth 3 k) :beneath 'default))
                              key))))
    (cdr (alist-get focused drgnx-notebook--blocks))))

(defun drgnx-notebook--blocks-update ()
  "Give the windows showing this buffer their cards (and the fringes that inset them), when they changed."
  (when (drgnx-notebook--cards-p)
    (let ((inset (drgnx-px drgnx-notebook--card-inset)))
      (setq-local left-fringe-width inset right-fringe-width inset)
      (dolist (w (get-buffer-window-list nil nil t))
        (unless (equal (window-fringes w) (list inset inset nil nil))
          (set-window-fringes w inset inset))
        (let ((blocks (drgnx-notebook--blocks-for (eq w (selected-window)))))
          (unless (eq (window-parameter w 'glitnir-blocks) blocks)
            (set-window-parameter w 'glitnir-blocks blocks)))))))

(defun drgnx-notebook--blocks-clear ()
  "No window keeps this buffer's cards (the buffer goes)."
  (dolist (w (get-buffer-window-list nil nil t))
    (when (memq (window-parameter w 'glitnir-blocks) (mapcar #'cddr drgnx-notebook--blocks))
      (set-window-parameter w 'glitnir-blocks nil)))
  (dolist (e drgnx-notebook--blocks)
    (dolist (b (cddr e)) (set-marker (nth 1 b) nil) (set-marker (nth 2 b) nil)))
  (setq drgnx-notebook--blocks nil))

(defun drgnx-notebook--windows-changed (&optional _data)
  "The state store's `windows-changed' and `selected-changed' (on idle): the notebooks shown take their cards."
  (dolist (frame (frame-list))
    (dolist (w (window-list frame 'never))
      (with-current-buffer (window-buffer w)
        (when (derived-mode-p 'drgnx-notebook-mode) (drgnx-notebook--blocks-update))))))

;;;; Hub events

(defun drgnx-notebook--event (event data)
  "`drgnx-hub-event-functions': a notebook's tail, status or question, for the buffer that holds it."
  (when (member event '("notebook-tail" "notebook-status" "notebook-input-request"))
    (when-let* ((buffer (gethash (plist-get data :id) drgnx-notebook--buffers)) ((buffer-live-p buffer)))
      (with-current-buffer buffer
        (pcase event
          ("notebook-tail" (drgnx-notebook--put-tail data))
          ("notebook-status" (drgnx-notebook--status data))
          ("notebook-input-request" (drgnx-notebook--input-request data)))))))

(defun drgnx-notebook--status (data)
  "A kernel's state (starting, idle, busy, dead), the cell it runs and the queue: the status bar shows them; heads
come with their tails."
  (let ((old drgnx-notebook--running))
    (setq drgnx-notebook--state (or (plist-get data :state) "idle")
          drgnx-notebook--running (and (equal drgnx-notebook--state "busy") (plist-get data :cell))
          drgnx-notebook--queue (or (plist-get data :queue) 0))
    (when (and drgnx-notebook--running (not (equal drgnx-notebook--running old)))
      (drgnx-notebook--forget-images drgnx-notebook--running))
    (when (fboundp 'drgnx-statusbar-refresh) (drgnx-statusbar-refresh t))))

(defun drgnx-notebook--input-request (data)
  "The kernel asked for a line (`input()'): the user is waiting, so it is asked now."
  (let ((id drgnx-notebook--id) (request (plist-get data :request)) (buffer (current-buffer)))
    (run-at-time 0 nil
                 (lambda ()
                   (when (buffer-live-p buffer)
                     (let ((value (with-current-buffer buffer
                                    (if (plist-get data :password)
                                        (read-passwd (or (plist-get data :prompt) "Input: "))
                                      (read-string (or (plist-get data :prompt) "Input: "))))))
                       (drgnx-notebook--call "notebook/input" (list :id id :request request :value value) #'ignore)))))))

;;;; Opening and saving

(defvar drgnx-notebook-mode-map (make-sparse-keymap) "Keys of a notebook buffer; the key profiles bind the commands.")

(defun drgnx-notebook--install (result)
  "Replace the buffer's text with the notebook the hub opened (RESULT of `notebook/open')."
  (let ((cells (plist-get result :cells)) (inhibit-read-only t) (inhibit-modification-hooks t))
    (setq drgnx-notebook--id (plist-get result :id)
          drgnx-notebook--language (plist-get result :language)
          drgnx-notebook--kernel nil)   ; the kernelspec the file names is started on the first run; the segment shows the one started
    (puthash drgnx-notebook--id (current-buffer) drgnx-notebook--buffers)
    (erase-buffer)
    (dolist (c cells)
      (let ((id (plist-get c :id)) (type (intern (or (plist-get c :type) "code"))))
        (puthash id t drgnx-notebook--known)
        (insert (drgnx-notebook--cell-text id type (or (plist-get c :source) "")))))
    (when (null cells) (insert (drgnx-notebook--cell-text (drgnx-notebook--mint) 'code "")))
    (setq buffer-undo-list nil buffer-read-only nil)
    (set-buffer-modified-p nil)
    (setq drgnx-notebook--dirty t drgnx-notebook--cells nil)
    ;; the parsers and the font-lock settings first, from the cells as the text has them: the chrome is made after, once
    (drgnx-notebook--setup-treesit (drgnx-notebook--pair (drgnx-notebook--scan)))
    (drgnx-notebook--rescan)
    (dolist (tail (plist-get result :tails)) (drgnx-notebook--put-tail tail))
    (goto-char (if drgnx-notebook--cells (1+ (plist-get (car drgnx-notebook--cells) :head)) (point-min)))
    (drgnx-notebook--select-at (point))))

(defun drgnx-notebook--begin-open ()
  "Ask the hub to open the file this buffer visited; the text is its JSON until the answer comes.  An answer that never
comes (no hub, or it went away) leaves the buffer waiting: `drgnx-notebook--reconnect-all' asks again at the next
connect.  Only the hub's own refusal makes the file text."
  (when (and buffer-file-name (null drgnx-notebook--id))
    (let ((buffer (current-buffer)) (text (buffer-substring-no-properties (point-min) (point-max))))
      (setq buffer-read-only t drgnx-notebook--retry nil)
      (drgnx-notebook--call "notebook/open" (list :path (expand-file-name buffer-file-name) :text text)
                            (lambda (r e)
                              (when (buffer-live-p buffer)
                                (with-current-buffer buffer
                                  (cond ((and (null e) r) (drgnx-notebook--install r))
                                        ((stringp e)
                                         (setq drgnx-notebook--retry t)
                                         (drgnx-notebook--say "%s waits for the hub: %s" buffer-file-name e))
                                        (t (setq buffer-read-only nil)
                                           (drgnx-notebook--say "%s is not opened as a notebook: %s" buffer-file-name
                                                                (or (and (consp e) (plist-get e :message)) "no answer"))
                                           (fundamental-mode))))))
                            t))))

(defun drgnx-notebook--reopened (result)
  "The new hub's RESULT of `notebook/open' for this buffer's file: take its id, forget what belonged to the old hub (the
kernel, the tails' versions) and give it the buffer's cells, unsaved edits included, which the file does not have."
  (remhash drgnx-notebook--id drgnx-notebook--buffers)
  (setq drgnx-notebook--id (plist-get result :id)
        drgnx-notebook--kernel nil drgnx-notebook--running nil drgnx-notebook--state "idle" drgnx-notebook--queue 0)
  (puthash drgnx-notebook--id (current-buffer) drgnx-notebook--buffers)
  (clrhash drgnx-notebook--known)
  (clrhash drgnx-notebook--tails)
  (let ((id drgnx-notebook--id) (buffer (current-buffer)))
    (drgnx-notebook--call "notebook/sync" (list :id id :cells (drgnx-notebook--sync-cells))
                          (lambda (_r e)
                            (when (buffer-live-p buffer)
                              (with-current-buffer buffer
                                (if e (drgnx-notebook--say "the hub did not take the cells: %s" e)
                                  (when (equal drgnx-notebook--id id) (drgnx-notebook--mark-known))))))))
  (dolist (tail (plist-get result :tails)) (drgnx-notebook--put-tail tail))
  (drgnx-notebook--reask-views)
  (drgnx-notebook--focus drgnx-notebook--selected-id)
  (when (fboundp 'drgnx-statusbar-refresh) (drgnx-statusbar-refresh t)))

(defun drgnx-notebook--reconnect ()
  "In this notebook buffer: the hub is a new one, which holds no notebook: open the file again by its path, then give it
the buffer's cells.  A refusal leaves the buffer as it is; nothing in it is lost either way."
  (when (and drgnx-notebook--id buffer-file-name)
    (let ((buffer (current-buffer)))
      (drgnx-notebook--call "notebook/open" (list :path (expand-file-name buffer-file-name))
                            (lambda (r e)
                              (when (buffer-live-p buffer)
                                (with-current-buffer buffer
                                  (if (or e (null r))
                                      (drgnx-notebook--say "%s is not open on the new hub: %s" buffer-file-name (or e "no answer"))
                                    (drgnx-notebook--reopened r)))))))))

(defun drgnx-notebook--reconnect-all ()
  "`drgnx-hub-connected-functions': every open notebook goes to the hub that came up."
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when (derived-mode-p 'drgnx-notebook-mode)
        (if drgnx-notebook--retry (drgnx-notebook--begin-open) (drgnx-notebook--reconnect))))))

(defun drgnx-notebook--write ()
  "`write-contents-functions': the hub writes the file (the cells' text goes along); the buffer is not written as text."
  (when drgnx-notebook--id
    (drgnx-notebook--call-sync "notebook/save" (list :id drgnx-notebook--id :cells (drgnx-notebook--sync-cells)) 15)
    (drgnx-notebook--mark-known)
    (set-buffer-modified-p nil)
    (when buffer-file-name (set-visited-file-modtime))
    t))

(defun drgnx-notebook--kill ()
  "`kill-buffer-hook': the hub forgets the notebook (its kernel ends), and the buffer's rescan is not waited for."
  (drgnx-timer-cancel (cons 'drgnx-notebook (current-buffer)))
  (drgnx-notebook--blocks-clear)
  (drgnx-notebook--kill-views)
  (when drgnx-notebook--id
    (remhash drgnx-notebook--id drgnx-notebook--buffers)
    (ignore-errors (drgnx-notebook--call "notebook/close" (list :id drgnx-notebook--id) #'ignore))))

(define-derived-mode drgnx-notebook-mode prog-mode "Notebook"
  "Major mode of a Jupyter notebook: one buffer of cells, the output after each (docs/guide/notebooks.md)."
  (setq-local yank-excluded-properties (append '(drgnx-cell drgnx-cell-type) yank-excluded-properties)
              require-final-newline nil
              drgnx-notebook--chrome (make-hash-table :test #'equal)
              drgnx-notebook--known (make-hash-table :test #'equal)
              drgnx-notebook--heads (make-hash-table :test #'equal)
              drgnx-notebook--images (make-hash-table :test #'equal)
              drgnx-notebook--last-tails (make-hash-table :test #'equal)
              drgnx-notebook--tails (make-hash-table :test #'equal))
  (add-hook 'after-change-functions #'drgnx-notebook--changed nil t)
  (add-hook 'post-command-hook #'drgnx-notebook--post-command nil t)
  (add-hook 'write-contents-functions #'drgnx-notebook--write nil t)
  (add-hook 'kill-buffer-hook #'drgnx-notebook--kill nil t)
  (drgnx-notebook--begin-open))

;;;; Cell commands

(defun drgnx-notebook--ensure ()
  (unless (derived-mode-p 'drgnx-notebook-mode) (user-error "Not in a notebook"))
  (unless drgnx-notebook--id (user-error "The notebook is still opening")))

(defun drgnx-notebook--current ()
  "The cell at point, or a `user-error'."
  (drgnx-notebook--ensure)
  (or (drgnx-notebook--cell-at) (user-error "Point is not in a cell")))

(defun drgnx-notebook--cell-source (c)
  (buffer-substring-no-properties (1+ (plist-get c :head)) (plist-get c :tail)))

(defun drgnx-notebook--insert-cell (pos type source)
  "Insert a new cell of TYPE with SOURCE at POS; point goes into its source.  Returns its id."
  (let ((id (drgnx-notebook--mint)) (inhibit-read-only t))
    (save-excursion (goto-char pos) (insert (drgnx-notebook--cell-text id type source)))
    (drgnx-notebook--rescan)
    (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id id) :head)))
    id))

(defun drgnx-notebook-add-cell-below (&optional type)
  "Add an empty cell (TYPE, default code) after this one."
  (interactive)
  (let ((c (drgnx-notebook--current)))
    (drgnx-notebook--insert-cell (1+ (plist-get c :tail)) (or type 'code) "")))

(defun drgnx-notebook-add-cell-above (&optional type)
  "Add an empty cell (TYPE, default code) before this one."
  (interactive)
  (let ((c (drgnx-notebook--current)))
    (drgnx-notebook--insert-cell (plist-get c :head) (or type 'code) "")))

(defun drgnx-notebook-delete-cell ()
  "Delete this cell, source and output."
  (interactive)
  (let ((c (drgnx-notebook--current)) (inhibit-read-only t))
    (delete-region (plist-get c :head) (1+ (plist-get c :tail)))
    (drgnx-notebook--rescan)
    (when (null drgnx-notebook--cells) (drgnx-notebook--insert-cell (point-min) 'code ""))))

(defun drgnx-notebook-copy-cell ()
  "Copy this cell (its type and source) to the cell clipboard."
  (interactive)
  (let ((c (drgnx-notebook--current)))
    (setq drgnx-notebook--clipboard (list :type (plist-get c :type) :source (drgnx-notebook--cell-source c)))
    (message "Cell copied")))

(defun drgnx-notebook-cut-cell ()
  "Cut this cell to the cell clipboard."
  (interactive)
  (drgnx-notebook-copy-cell)
  (drgnx-notebook-delete-cell))

(defun drgnx-notebook-paste-cell ()
  "Paste the clipboard's cell below this one, under a new id."
  (interactive)
  (unless drgnx-notebook--clipboard (user-error "No cell was cut or copied"))
  (let ((c (drgnx-notebook--current)))
    (drgnx-notebook--insert-cell (1+ (plist-get c :tail)) (plist-get drgnx-notebook--clipboard :type)
                                 (plist-get drgnx-notebook--clipboard :source))))

(defun drgnx-notebook--swap (a b)
  "Exchange the cells A and B (A is the earlier): their text, boundaries and all, so undo is one edit."
  (let* ((inhibit-read-only t)
         (ta (buffer-substring (plist-get a :head) (1+ (plist-get a :tail))))
         (tb (buffer-substring (plist-get b :head) (1+ (plist-get b :tail))))
         (mid (buffer-substring (1+ (plist-get a :tail)) (plist-get b :head)))
         (beg (plist-get a :head)))
    (delete-region beg (1+ (plist-get b :tail)))
    (goto-char beg)
    (insert tb mid ta)))

(defun drgnx-notebook-move-cell-up ()
  "Move this cell above the one before it."
  (interactive)
  (let* ((c (drgnx-notebook--current)) (i (seq-position drgnx-notebook--cells c #'eq)) (prev (and (> i 0) (nth (1- i) drgnx-notebook--cells))))
    (unless prev (user-error "This is the first cell"))
    (let ((off (- (point) (plist-get c :head))) (id (plist-get c :id)))
      (drgnx-notebook--swap prev c)
      (drgnx-notebook--rescan)
      (goto-char (+ (plist-get (drgnx-notebook--cell-by-id id) :head) off)))))

(defun drgnx-notebook-move-cell-down ()
  "Move this cell below the one after it."
  (interactive)
  (let* ((c (drgnx-notebook--current)) (i (seq-position drgnx-notebook--cells c #'eq)) (next (nth (1+ i) drgnx-notebook--cells)))
    (unless next (user-error "This is the last cell"))
    (let ((off (- (point) (plist-get c :head))) (id (plist-get c :id)))
      (drgnx-notebook--swap c next)
      (drgnx-notebook--rescan)
      (goto-char (+ (plist-get (drgnx-notebook--cell-by-id id) :head) off)))))

(defun drgnx-notebook-split-cell ()
  "Split this cell at point: the text after point becomes a new cell below.
The first part keeps the id and the output."
  (interactive)
  (let* ((c (drgnx-notebook--current)) (pos (point)) (type (plist-get c :type)) (inhibit-read-only t))
    (unless (and (> pos (plist-get c :head)) (<= pos (plist-get c :tail))) (user-error "Point is not in the cell's source"))
    (let ((new (drgnx-notebook--mint)) (tail (plist-get c :tail)))
      ;; the old tail character ends the new cell; the first part gets a tail of its own
      (drgnx-notebook--retag-part tail new 'tail)
      (goto-char pos)
      (insert (drgnx-notebook--boundary (plist-get c :id) 'tail type) (drgnx-notebook--boundary new 'head type))
      (drgnx-notebook--rescan)
      (goto-char (1+ (plist-get (drgnx-notebook--cell-by-id new) :head))))))

(defun drgnx-notebook--retag-part (pos id part)
  (with-silent-modifications (put-text-property pos (1+ pos) 'drgnx-cell (cons id part))))

(defun drgnx-notebook-merge-cell-below ()
  "Merge the cell below into this one: its source follows this source."
  (interactive)
  (let* ((c (drgnx-notebook--current)) (i (seq-position drgnx-notebook--cells c #'eq)) (next (nth (1+ i) drgnx-notebook--cells))
         (inhibit-read-only t))
    (unless next (user-error "This is the last cell"))
    (let ((at (plist-get c :tail)) (id (plist-get c :id)) (type (plist-get c :type)))
      ;; drop this cell's tail and the next one's head; the next tail character becomes this cell's
      (delete-region at (1+ (plist-get next :head)))
      (let ((tail (- (plist-get next :tail) 1 (- (plist-get next :head) at))))
        (with-silent-modifications
          (put-text-property tail (1+ tail) 'drgnx-cell (cons id 'tail))
          (put-text-property tail (1+ tail) 'drgnx-cell-type type)))
      (drgnx-notebook--rescan)
      (goto-char at))))

(defun drgnx-notebook-change-cell-type (type)
  "Make this cell a TYPE cell (code, markdown or raw)."
  (interactive (list (intern (completing-read "Cell type: " '("code" "markdown" "raw") nil t))))
  (let ((c (drgnx-notebook--current)) (inhibit-read-only t))
    (dolist (pos (list (plist-get c :head) (plist-get c :tail)))
      (put-text-property pos (1+ pos) 'drgnx-cell-type type))
    (drgnx-notebook--refresh-head (plist-get c :id))
    (setq drgnx-notebook--cells nil drgnx-notebook--dirty t)
    (drgnx-notebook--rescan)
    (drgnx-notebook--refresh-head (plist-get c :id))))

(defun drgnx-notebook-guard-kill (beg end &rest _)
  "Before `kill-region': a region that holds a cell boundary is not killed; cutting a cell is its own command."
  (when (and (derived-mode-p 'drgnx-notebook-mode) (text-property-not-all (min beg end) (max beg end) 'drgnx-cell nil))
    (user-error "The region crosses a cell boundary: use Cut Cell")))

;;;; Running

(defun drgnx-notebook--run-ids (ids)
  "Run the code cells IDS, in order, on the notebook's kernel (started first when it has none)."
  (drgnx-notebook--ensure)
  (let* ((cells (drgnx-notebook--sync-cells))
         (run (seq-filter (lambda (c) (member (plist-get c :id) ids)) cells))
         (buffer (current-buffer)) (nb drgnx-notebook--id))
    (dolist (id ids) (drgnx-notebook--forget-images id))
    (drgnx-notebook--mark-known)
    ;; the buffer's cells are the notebook's first (`notebook/sync'), then the cells to run are queued (`notebook/execute')
    (drgnx-notebook--call
     "notebook/sync" (list :id nb :cells cells)
     (lambda (_r e)
       (cond ((and e (buffer-live-p buffer)) (drgnx-notebook--say "%s" e))
             ((buffer-live-p buffer)
              (drgnx-notebook--call
               "notebook/execute" (list :id nb :cells (vconcat run))
               (lambda (_r e)
                 (when (and e (buffer-live-p buffer))
                   (if (string-match-p "no kernel\\|not started\\|has no kernel\\|ended" e)
                       (with-current-buffer buffer (drgnx-notebook--start-then ids))
                     (drgnx-notebook--say "%s" e)))))))))))

(defun drgnx-notebook--start-then (ids)
  "Start the kernel (the notebook's own, or ask when several fit), then run IDS."
  (let ((buffer (current-buffer)) (nb drgnx-notebook--id))
    (drgnx-notebook--call "notebook/start" (list :id nb)
                          (lambda (r e)
                            (when (buffer-live-p buffer)
                              (with-current-buffer buffer
                                (cond ((and e (string-match "several kernels fit" e)) (drgnx-notebook-select-kernel ids))
                                      (e (drgnx-notebook--say "%s" e))
                                      (t (setq drgnx-notebook--kernel (plist-get r :kernel))
                                         (drgnx-notebook--run-ids ids)))))))))

(defun drgnx-notebook--kernel-candidates (result)
  "The kernels of `notebook/kernels' RESULT as ((NAME . PLIST)…): an installed one with :display and :language, one
the hub skipped with :why (shown in the picker with its reason, and refused when chosen)."
  (append (mapcar (lambda (k) (cons (plist-get k :name) (list :display (plist-get k :display_name) :language (plist-get k :language))))
                  (plist-get result :kernels))
          (mapcar (lambda (k) (cons (plist-get k :name) (list :why (plist-get k :why))))
                  (plist-get result :skipped))))

(defun drgnx-notebook--choose-kernel (candidates)
  "Ask for one of CANDIDATES (`drgnx-notebook--kernel-candidates'); a skipped one is a user-error saying why."
  (let* ((completion-extra-properties
          (list :annotation-function
                (lambda (name)
                  (let ((c (cdr (assoc name candidates))))
                    (if (plist-get c :why) (format "  unavailable: %s" (plist-get c :why))
                      (format "  %s (%s)" (plist-get c :display) (plist-get c :language)))))))
         (name (completing-read "Kernel: " (mapcar #'car candidates) nil t))
         (c (cdr (assoc name candidates))))
    (when (plist-get c :why) (user-error "Kernel %s is not available: %s" name (plist-get c :why)))
    name))

(defun drgnx-notebook-select-kernel (&optional then-run)
  "Choose the notebook's kernel from the installed kernelspecs (the hub's skipped ones are listed with why); start it."
  (interactive)
  (drgnx-notebook--ensure)
  (let ((buffer (current-buffer)) (nb drgnx-notebook--id))
    (drgnx-notebook--call
     "notebook/kernels" nil
     (lambda (r e)
       (when (buffer-live-p buffer)
         ;; the picker is the user's command asking, but it is not asked from inside the hub's process filter
         (run-at-time
          0 nil
          (lambda ()
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (let ((candidates (and (not e) (drgnx-notebook--kernel-candidates r))))
                  (cond (e (drgnx-notebook--say "%s" e))
                        ((null candidates) (drgnx-notebook--say "no kernelspec is installed"))
                        (t (let ((name (drgnx-notebook--choose-kernel candidates)))
                             (drgnx-notebook--call
                              "notebook/start" (list :id nb :kernel name)
                              (lambda (r2 e2)
                                (when (buffer-live-p buffer)
                                  (with-current-buffer buffer
                                    (if e2 (drgnx-notebook--say "%s" e2)
                                      (setq drgnx-notebook--kernel (or (plist-get r2 :kernel) name))
                                      (when then-run (drgnx-notebook--run-ids then-run))))))))))))))))))))

(defun drgnx-notebook-run-cell ()
  "Run this cell."
  (interactive)
  (drgnx-notebook--run-ids (list (plist-get (drgnx-notebook--current) :id))))

(defun drgnx-notebook-run-cell-and-advance ()
  "Run this cell and move to the next (a new code cell after the last)."
  (interactive)
  (let* ((c (drgnx-notebook--current)) (i (seq-position drgnx-notebook--cells c #'eq)) (next (nth (1+ i) drgnx-notebook--cells)))
    (drgnx-notebook--run-ids (list (plist-get c :id)))
    (if next (goto-char (1+ (plist-get next :head))) (drgnx-notebook-add-cell-below))))

(defun drgnx-notebook-run-all ()
  "Run every code cell, in order."
  (interactive)
  (drgnx-notebook--ensure)
  (drgnx-notebook--run-ids (mapcar (lambda (c) (plist-get c :id)) (seq-filter (lambda (c) (eq (plist-get c :type) 'code)) (drgnx-notebook--rescan)))))

(defun drgnx-notebook-run-above ()
  "Run every code cell above this one."
  (interactive)
  (let* ((c (drgnx-notebook--current)) (i (seq-position drgnx-notebook--cells c #'eq)))
    (drgnx-notebook--run-ids (mapcar (lambda (x) (plist-get x :id)) (seq-filter (lambda (x) (eq (plist-get x :type) 'code)) (seq-take drgnx-notebook--cells i))))))

(defun drgnx-notebook-run-below ()
  "Run this cell and every code cell below it."
  (interactive)
  (let* ((c (drgnx-notebook--current)) (i (seq-position drgnx-notebook--cells c #'eq)))
    (drgnx-notebook--run-ids (mapcar (lambda (x) (plist-get x :id)) (seq-filter (lambda (x) (eq (plist-get x :type) 'code)) (seq-drop drgnx-notebook--cells i))))))

(defun drgnx-notebook-interrupt ()
  "Interrupt the running cell."
  (interactive)
  (drgnx-notebook--ensure)
  (drgnx-notebook--call "notebook/interrupt" (list :id drgnx-notebook--id) (lambda (_r e) (when e (drgnx-notebook--say "%s" e)))))

(defun drgnx-notebook-restart-kernel (&optional then-run-all)
  "Restart the kernel (the hub's: it ends and a new one of the same kernelspec starts; queued cells show cancelled).
THEN-RUN-ALL: run every code cell once it is up."
  (interactive)
  (drgnx-notebook--ensure)
  (let ((buffer (current-buffer)))
    (drgnx-notebook--call "notebook/restart" (list :id drgnx-notebook--id)
                          (lambda (r e)
                            (when (buffer-live-p buffer)
                              (with-current-buffer buffer
                                (cond (e (drgnx-notebook--say "%s" e))
                                      (t (setq drgnx-notebook--kernel (plist-get r :kernel))
                                         (when then-run-all (drgnx-notebook-run-all))))))))))

(defun drgnx-notebook-restart-and-run-all ()
  "Restart the kernel and run every code cell."
  (interactive)
  (drgnx-notebook-restart-kernel t))

(defun drgnx-notebook-toggle-outputs ()
  "Show or hide every cell's output (the tails stay with the hub)."
  (interactive)
  (drgnx-notebook--ensure)
  (setq-local drgnx-notebook--outputs-hidden (not (bound-and-true-p drgnx-notebook--outputs-hidden)))
  (maphash (lambda (_id set)
             (when-let* ((ov (plist-get set :tail)))
               (overlay-put ov 'invisible nil)
               (when drgnx-notebook--outputs-hidden
                 (overlay-put ov 'after-string (propertize (or (overlay-get ov 'after-string) "") 'invisible t)))))
           drgnx-notebook--chrome)
  (unless drgnx-notebook--outputs-hidden (maphash (lambda (id _) (drgnx-notebook--request-tail id)) drgnx-notebook--chrome)))

(defun drgnx-notebook-copy-output ()
  "Copy this cell's output as plain text (the hub's text of the output, not the displayed string)."
  (interactive)
  (let ((c (drgnx-notebook--current)) (buffer (current-buffer)))
    (drgnx-notebook--call "notebook/output" (list :id drgnx-notebook--id :cell (plist-get c :id))
                          (lambda (r e)
                            (if e (drgnx-notebook--say "%s" e)
                              (let ((text (drgnx-notebook--outputs-text (plist-get r :outputs))))
                                (when (buffer-live-p buffer)
                                  (kill-new text)
                                  (message "Output copied (%d characters)" (length text)))))))))

(defun drgnx-notebook--outputs-text (outputs)
  "The text/plain (or stream text) of the hub's nbformat OUTPUTS."
  (mapconcat
   (lambda (o)
     (let ((type (plist-get o :output_type)))
       (pcase type
         ("stream" (let ((x (plist-get o :text))) (if (listp x) (apply #'concat x) (or x ""))))
         ("error" (concat (plist-get o :ename) ": " (plist-get o :evalue)))
         (_ (let ((p (plist-get (plist-get o :data) :text/plain))) (if (listp p) (apply #'concat p) (or p "")))))))
   outputs ""))

(defun drgnx-notebook-clear-outputs (&optional this-cell)
  "Clear every cell's output and execution count (a prefix argument: this cell's); a queued or running cell stays."
  (interactive "P")
  (drgnx-notebook--ensure)
  (let ((id (and this-cell (plist-get (drgnx-notebook--current) :id))))
    (drgnx-notebook--call "notebook/clear" (append (list :id drgnx-notebook--id) (and id (list :cell id)))
                          (lambda (_r e) (when e (drgnx-notebook--say "%s" e))))))

(defun drgnx-notebook-open-output ()
  "Open this cell's whole output: a Sjá view of the hub's lines (drgnx's own Emacs), else its text in a buffer."
  (interactive)
  (let ((c (drgnx-notebook--current)) (name (buffer-name)))
    (if (drgnx-notebook--views-p)
        (drgnx-notebook--view-open 'output (plist-get c :id))
      (drgnx-notebook--call "notebook/output" (list :id drgnx-notebook--id :cell (plist-get c :id))
                            (lambda (r e)
                              (if e (drgnx-notebook--say "%s" e)
                                (let ((text (drgnx-notebook--outputs-text (plist-get r :outputs)))
                                      (buffer (get-buffer-create (format "*Output: %s %s*" name (plist-get c :id)))))
                                  (with-current-buffer buffer
                                    (let ((inhibit-read-only t))
                                      (erase-buffer)
                                      (insert (if (string-empty-p text) "(no output)\n" text))
                                      (goto-char (point-min)))
                                    (special-mode))
                                  (pop-to-buffer buffer))))))))

;;;; The views: the outline, a cell's full output, the kernel log
;; The hub builds their rows (`notebook/view', docs/develop/notebooks.md "The views"); the editor makes a buffer for each, attaches
;; it to the hub's view, sends its env (`drgnx-view-env-register') and binds keys.  A view buffer belongs to a notebook buffer and
;; ends with it; its hub view is closed with `view/close' when the buffer is killed, and asked for again when the notebook
;; comes back on a new hub (the view's id is the old hub's).

(defvar-local drgnx-notebook-view--notebook nil "In a view buffer: the notebook buffer it shows.")
(defvar-local drgnx-notebook-view--kind nil "In a view buffer: `outline', `output' or `log'.")
(defvar-local drgnx-notebook-view--cell nil "In an output view: the cell's id.")
(defvar-local drgnx-notebook-view--id nil "In a view buffer: the hub's id of its view.")

(defun drgnx-notebook--views-p ()
  "Whether Sjá (drgnx's own Emacs) is here to show the hub's views."
  (fboundp 'nidhogg-view--call))

(defun drgnx-notebook--view-name (notebook kind cell)
  (pcase kind
    ('outline (format "*Notebook outline: %s*" notebook))
    ('output (format "*Notebook output: %s %s*" notebook cell))
    (_ (format "*Notebook log: %s*" notebook))))

(defvar drgnx-notebook-view-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    map)
  "Keys of the notebook views.")
(defvar drgnx-notebook-outline-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map drgnx-notebook-view-mode-map)
    map)
  "Keys of the cell outline.")
(defvar drgnx-notebook-output-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map drgnx-notebook-view-mode-map)
    map)
  "Keys of a cell's full output.")

(define-derived-mode drgnx-notebook-view-mode special-mode "Notebook view"
  "A notebook's Sjá view: rows the hub builds."
  (setq-local truncate-lines t cursor-type nil header-line-format '(" " (:eval drgnx-notebook-view--header)))
  (add-hook 'drgnx-view-patch-patched-functions #'drgnx-notebook-view--refresh nil t))
(define-derived-mode drgnx-notebook-outline-mode drgnx-notebook-view-mode "Notebook outline"
  "The cell outline: one row per cell; Go to Cell (the key profiles' RET) goes to the cell.")
(define-derived-mode drgnx-notebook-output-mode drgnx-notebook-view-mode "Notebook output"
  "The whole output of one cell, a window of 1000 lines at a time; Output Later and Earlier Lines move it."
  (setq-local display-line-numbers t)
  (face-remap-add-relative 'line-number 'drgnx-text-subtle))
(define-derived-mode drgnx-notebook-log-mode drgnx-notebook-view-mode "Notebook log"
  "What the kernel says that answers no cell.")

(defun drgnx-notebook--view-twin (class)
  "The view's buffer in display CLASS (`drgnx-view-patch-twin-function')."
  (drgnx-view-env-twin class '("drgnx-notebook-view-")))

(defun drgnx-notebook--view-attach (view)
  "Attach the current view buffer to the hub's VIEW and send its env."
  (setq drgnx-notebook-view--id view)
  (drgnx-view-patch-attach view "unshown")
  (setq-local drgnx-view-patch-twin-function #'drgnx-notebook--view-twin)
  (require 'drgnx-view-env)
  (drgnx-view-env-register view (current-buffer)))

(defun drgnx-notebook--view-killed ()
  "`kill-buffer-hook' of a view buffer: the hub forgets the view."
  (when drgnx-notebook-view--id
    (ignore-errors (drgnx-notebook--call "view/close" (list :view drgnx-notebook-view--id) #'ignore))))

(defun drgnx-notebook--view-params (notebook-id kind cell)
  (append (list :id notebook-id :kind (symbol-name kind)) (and cell (list :cell cell))))

(defun drgnx-notebook--view-open (kind &optional cell)
  "Show the hub's view of KIND (`outline', `output' of CELL, `log') of this notebook."
  (drgnx-notebook--ensure)
  (unless (drgnx-notebook--views-p) (user-error "This view needs drgnx's own Emacs (Nidhogg)"))
  (let* ((notebook (current-buffer)) (name (drgnx-notebook--view-name (buffer-name) kind cell)) (existing (get-buffer name)))
    (if (buffer-live-p existing)
        (pop-to-buffer existing)
      (drgnx-notebook--call "notebook/view" (drgnx-notebook--view-params drgnx-notebook--id kind cell)
                            (lambda (r e)
                              (if (or e (null (plist-get r :view)))
                                  (drgnx-notebook--say "no %s view: %s" kind (or e "no answer"))
                                (when (and (buffer-live-p notebook) (not (get-buffer name)))
                                  (with-current-buffer (generate-new-buffer name)
                                    (pcase kind
                                      ('outline (drgnx-notebook-outline-mode))
                                      ('output (drgnx-notebook-output-mode))
                                      (_ (drgnx-notebook-log-mode)))
                                    (setq drgnx-notebook-view--notebook notebook drgnx-notebook-view--kind kind
                                          drgnx-notebook-view--cell cell)
                                    (add-hook 'kill-buffer-hook #'drgnx-notebook--view-killed nil t)
                                    (drgnx-notebook--view-attach (plist-get r :view))
                                    (pop-to-buffer (current-buffer))
                                    ;; shown now: its env goes out (the hooks that follow windows run at redisplay)
                                    (drgnx-view-env-update drgnx-notebook-view--id)))))))))

(defun drgnx-notebook--view-buffers (notebook)
  "The live view buffers of NOTEBOOK."
  (seq-filter (lambda (b) (eq (buffer-local-value 'drgnx-notebook-view--notebook b) notebook)) (buffer-list)))

(defun drgnx-notebook--reask-views ()
  "The notebook came back on a new hub with a new id: each of its views is asked for again, its old id forgotten."
  (let ((notebook (current-buffer)) (id drgnx-notebook--id))
    (dolist (view (drgnx-notebook--view-buffers notebook))
      (let ((kind (buffer-local-value 'drgnx-notebook-view--kind view)) (cell (buffer-local-value 'drgnx-notebook-view--cell view))
            (old (buffer-local-value 'drgnx-notebook-view--id view)))
        (drgnx-notebook--call "notebook/view" (drgnx-notebook--view-params id kind cell)
                              (lambda (r e)
                                (when (buffer-live-p view)
                                  (with-current-buffer view
                                    (if (or e (null (plist-get r :view)))
                                        (drgnx-notebook--say "no %s view on the new hub: %s" kind (or e "no answer"))
                                      (when old (drgnx-view-env-unregister old))
                                      (drgnx-notebook--view-attach (plist-get r :view)))))))))))

(defun drgnx-notebook--kill-views ()
  "The notebook goes: so do its views."
  (dolist (view (drgnx-notebook--view-buffers (current-buffer)))
    (kill-buffer view)))

(defun drgnx-notebook-outline ()
  "Show the cell outline: one row per cell (index, type, prompt, first line, state); RET goes to the cell."
  (interactive)
  (drgnx-notebook--view-open 'outline))

(defun drgnx-notebook-kernel-log ()
  "Show the kernel's log: what it sends that answers no cell (its own logging, other clients' messages)."
  (interactive)
  (drgnx-notebook--view-open 'log))

(defun drgnx-notebook-outline-visit ()
  "Go to the cell of the outline row at point."
  (interactive)
  (let ((id (get-text-property (line-beginning-position) 'drgnx-notebook-cell)) (notebook drgnx-notebook-view--notebook))
    (unless id (user-error "This row is not a cell"))
    (unless (buffer-live-p notebook) (user-error "The notebook is closed"))
    (pop-to-buffer notebook)
    (let ((c (drgnx-notebook--cell-by-id id)))
      (unless c (user-error "The cell is not in the notebook any more"))
      (goto-char (1+ (plist-get c :head)))
      (drgnx-notebook--select-at (point)))))

(defun drgnx-notebook--output-lines ()
  "The first and last line numbers (1-based) the output view holds, or nil: a read of the rows' property, on a command."
  (let ((pos (point-min)) first last)
    (while (< pos (point-max))
      (when-let* ((n (get-text-property pos 'drgnx-notebook-line)))
        (setq first (min n (or first n)) last (max n (or last n))))
      (setq pos (or (next-single-property-change pos 'drgnx-notebook-line) (point-max))))
    (and first (cons first last))))

(defun drgnx-notebook--output-move (delta)
  "Ask the hub for the output's window moved by DELTA lines from the first line shown (the hub clamps it)."
  (let ((lines (drgnx-notebook--output-lines)))
    (unless lines (user-error "No lines here yet"))
    (drgnx-notebook--call "view/window" (list :view drgnx-notebook-view--id :list "lines"
                                              :from (max 0 (+ (1- (car lines)) delta)))
                          (lambda (_r e) (when e (drgnx-notebook--say "%s" e))))))

(defun drgnx-notebook-output-later ()
  "Move the output's window half a window on."
  (interactive)
  (drgnx-notebook--output-move 500))

(defun drgnx-notebook-output-earlier ()
  "Move the output's window half a window back."
  (interactive)
  (drgnx-notebook--output-move -500))

;;; The foot line of a view: what the status bar says (the approved mockup), computed from the rows when a patch draws, never at redisplay

(defvar-local drgnx-notebook-view--foot nil "In a view buffer: the status bar's line about its rows (`9 of 2 000 listed').")
(defvar-local drgnx-notebook-view--hint nil "In a view buffer: the key hint at the bar's other end.")
(defvar-local drgnx-notebook-view--header nil "In a view buffer: its pane title, the name, what it is of and a count chip.")

(defun drgnx-notebook--key-word (label)
  "A key's LABEL as a hint says it: the Return key is `Enter'."
  (if (equal label "RET") "Enter" label))

(defun drgnx-notebook-view--title (name subtitle chip &optional accent)
  "The pane title: NAME, the muted SUBTITLE and a CHIP at the right end (in the accent when ACCENT)."
  (concat (propertize name 'face 'drgnx-text) "  " (propertize (or subtitle "") 'face 'drgnx-text-subtle)
          (when chip
            (concat (propertize " " 'display `(space :align-to (- right ,(+ 2 (string-width chip)))))
                    (propertize (concat " " chip " ") 'face (if accent 'drgnx-chip-accent 'drgnx-chip-quiet))))))

(defun drgnx-notebook-view--notebook-name ()
  (if (buffer-live-p drgnx-notebook-view--notebook) (buffer-name drgnx-notebook-view--notebook) ""))

(defun drgnx-notebook--group (n)
  "N with its thousands set off by a space, as the mockup writes them (`1 240')."
  (let ((s (number-to-string n)))
    (while (string-match "\\`\\([0-9]+\\)\\([0-9]\\{3\\}\\)" s)
      (setq s (replace-match "\\1 \\2" nil nil s)))
    s))

(defun drgnx-notebook-view--rows-count (property)
  "How many distinct values PROPERTY has over the buffer's rows, and the count of rows that carry it."
  (let ((pos (point-min)) seen (rows 0))
    (while (< pos (point-max))
      (when-let* ((v (get-text-property pos property)))
        (cl-incf rows) (cl-pushnew v seen :test #'equal))
      (setq pos (or (save-excursion (goto-char pos) (and (zerop (forward-line 1)) (point))) (point-max))))
    (cons (length seen) rows)))

(defun drgnx-notebook-view--prop (property)
  "The number the hub put in PROPERTY on a row (`drgnx-notebook-more', `-above', `-below', `-lost'), or 0 without one."
  (let ((pos (text-property-not-all (point-min) (point-max) property nil)))
    (or (and pos (let ((v (get-text-property pos property))) (and (numberp v) v))) 0)))

(defun drgnx-notebook-view--output-title ()
  "`Output  cell 3 · [*] · running', with `follows the run' while the cell runs."
  (let* ((nb drgnx-notebook-view--notebook) (cell drgnx-notebook-view--cell)
         (index (and (buffer-live-p nb)
                     (with-current-buffer nb
                       (seq-position drgnx-notebook--cells cell (lambda (c id) (equal (plist-get c :id) id))))))
         (head (and (buffer-live-p nb) (gethash cell (buffer-local-value 'drgnx-notebook--heads nb))))
         (running (and (buffer-live-p nb) (equal (buffer-local-value 'drgnx-notebook--running nb) cell))))
    (drgnx-notebook-view--title "Output"
                                (string-join (delq nil (list (and index (format "cell %d" (1+ index)))
                                                             (and head (plist-get head :text) (string-trim (plist-get head :text)))))
                                             " · ")
                                (and running "follows the run") t)))

(defun drgnx-notebook-view--refresh (&optional _view _keys)
  "Compute this view buffer's foot line, key hint and gutter from its rows (a draw just changed them)."
  (when (derived-mode-p 'drgnx-notebook-view-mode)
    (pcase major-mode
      ('drgnx-notebook-outline-mode
       (let* ((listed (cdr (drgnx-notebook-view--rows-count 'drgnx-notebook-cell)))
              (more (drgnx-notebook-view--prop 'drgnx-notebook-more)))
         (setq drgnx-notebook-view--foot (format "%s of %s listed" (drgnx-notebook--group listed) (drgnx-notebook--group (+ listed more)))
               drgnx-notebook-view--header (drgnx-notebook-view--title "Outline" (drgnx-notebook-view--notebook-name)
                                                                       (format "%s cells" (drgnx-notebook--group (+ listed more))))
               drgnx-notebook-view--hint
               (and (fboundp 'drgnx-surfaces-key-label)
                    (when-let* ((k (drgnx-surfaces-key-label 'notebook-outline-visit :short t)))
                      (format "%s goes to the cell" (drgnx-notebook--key-word k)))))))
      ('drgnx-notebook-output-mode
       (let ((lines (drgnx-notebook--output-lines)))
         (if (null lines)
             (setq drgnx-notebook-view--foot "no output")
           (let* ((above (drgnx-notebook-view--prop 'drgnx-notebook-above))
                  (below (drgnx-notebook-view--prop 'drgnx-notebook-below)))
             (setq drgnx-notebook-view--header (drgnx-notebook-view--output-title)
                   drgnx-notebook-view--foot (format "lines %s–%s of %s" (drgnx-notebook--group (car lines)) (drgnx-notebook--group (cdr lines))
                                                     (drgnx-notebook--group (+ (cdr lines) below)))
                   ;; the gutter counts the cell's lines: a row above is the line before the first shown
                   display-line-numbers t
                   display-line-numbers-offset (- (car lines) 1 (if (> above 0) 1 0)))))))
      ('drgnx-notebook-log-mode
       (let ((entries (car (drgnx-notebook-view--rows-count 'drgnx-notebook-log)))
             (lost (drgnx-notebook-view--prop 'drgnx-notebook-lost)))
         (setq drgnx-notebook-view--header (drgnx-notebook-view--title "Kernel log" (or (and (buffer-live-p drgnx-notebook-view--notebook)
                                                                                             (buffer-local-value 'drgnx-notebook--kernel drgnx-notebook-view--notebook))
                                                                                        (drgnx-notebook-view--notebook-name))
                                                                       (and (> lost 0) (format "%d earlier entries dropped" lost)))
               drgnx-notebook-view--foot (format "%d entries%s" entries (if (> lost 0) (format " · %d dropped" lost) ""))
               drgnx-notebook-view--hint "answers no cell"))))
    (when (fboundp 'drgnx-statusbar-refresh) (drgnx-statusbar-refresh t))))

(defun drgnx-notebook--segment-view ()
  "A view's foot line (a status bar reads only what was computed)."
  (and (derived-mode-p 'drgnx-notebook-view-mode) drgnx-notebook-view--foot))

(defun drgnx-notebook--segment-view-hint ()
  (and (derived-mode-p 'drgnx-notebook-view-mode) drgnx-notebook-view--hint))

;;;; The status bar: which cell, and the kernel

(declare-function drgnx-statusbar-define-segment "drgnx-statusbar")
(declare-function drgnx-statusbar-refresh "drgnx-statusbar")
(declare-function drgnx-module-set "drgnx-modules-helpers")
(defvar drgnx-statusbar-left)
(defvar drgnx-statusbar-right)
(defvar drgnx-statusbar-other)
(defvar drgnx-statusbar-other-right)

(defun drgnx-notebook--segment-cell ()
  "`cell 3 of 4 · python': the selected cell's place, from the cached ranges (a status bar reads only cached state)."
  (when (and (derived-mode-p 'drgnx-notebook-mode) drgnx-notebook--cells)
    (let ((i (seq-position drgnx-notebook--cells drgnx-notebook--selected-id
                           (lambda (c id) (equal (plist-get c :id) id)))))
      (format "cell %d of %d%s" (1+ (or i 0)) (length drgnx-notebook--cells)
              (if drgnx-notebook--language (format " · %s" drgnx-notebook--language) "")))))

(defun drgnx-notebook--segment-kernel ()
  "`● python3 · busy': the kernel and what it is doing (the hub's `notebook-status'), `no kernel' before one starts."
  (when (derived-mode-p 'drgnx-notebook-mode)
    (if (null drgnx-notebook--kernel)
        (propertize "no kernel" 'face 'drgnx-text-muted)
      (concat (propertize "●" 'face (pcase drgnx-notebook--state ("busy" 'drgnx-status-warn) ("dead" 'drgnx-status-fail)
                                           ("starting" 'drgnx-status-info) (_ 'drgnx-status-ok)))
              (format " %s · %s" drgnx-notebook--kernel drgnx-notebook--state)))))

(defun drgnx-notebook--segments-define ()
  "Define the segments `notebook-cell' (before the left end of the bar) and `notebook-kernel' (before the language)."
  (when (fboundp 'drgnx-statusbar-define-segment)
    (drgnx-statusbar-define-segment 'notebook-cell :fn #'drgnx-notebook--segment-cell
                                    :help "The selected cell's place in the notebook")
    (drgnx-statusbar-define-segment 'notebook-kernel :fn #'drgnx-notebook--segment-kernel
                                    :help "The notebook's kernel and its state")
    (drgnx-statusbar-define-segment 'notebook-view :fn #'drgnx-notebook--segment-view :help "What a notebook view shows")
    (drgnx-statusbar-define-segment 'notebook-view-hint :fn #'drgnx-notebook--segment-view-hint :help "A notebook view's key")
    ;; a view is a special-mode buffer: the bar for those is `drgnx-statusbar-other' (left) and `-other-right'
    (unless (memq 'notebook-view drgnx-statusbar-other)
      (drgnx-module-set 'drgnx-statusbar-other (append drgnx-statusbar-other '(notebook-view))))
    (unless (memq 'notebook-view-hint drgnx-statusbar-other-right)
      (drgnx-module-set 'drgnx-statusbar-other-right (append drgnx-statusbar-other-right '(notebook-view-hint))))
    (unless (memq 'notebook-cell drgnx-statusbar-left)
      (drgnx-module-set 'drgnx-statusbar-left (append drgnx-statusbar-left '(notebook-cell))))
    (unless (memq 'notebook-kernel drgnx-statusbar-right)
      (let ((tail (memq 'language drgnx-statusbar-right)))
        (drgnx-module-set 'drgnx-statusbar-right
                          (append (butlast drgnx-statusbar-right (length tail)) '(notebook-kernel) tail))))))

;;;; The module

(defconst drgnx-notebook--commands
  '((notebook-run-cell "Run Cell" drgnx-notebook-run-cell)
    (notebook-run-and-advance "Run Cell and Advance" drgnx-notebook-run-cell-and-advance)
    (notebook-run-all "Run All Cells" drgnx-notebook-run-all)
    (notebook-run-above "Run Cells Above" drgnx-notebook-run-above)
    (notebook-run-below "Run Cell and Below" drgnx-notebook-run-below)
    (notebook-interrupt "Interrupt Kernel" drgnx-notebook-interrupt)
    (notebook-restart "Restart Kernel" drgnx-notebook-restart-kernel)
    (notebook-restart-run-all "Restart Kernel and Run All" drgnx-notebook-restart-and-run-all)
    (notebook-add-below "Add Cell Below" drgnx-notebook-add-cell-below)
    (notebook-add-above "Add Cell Above" drgnx-notebook-add-cell-above)
    (notebook-cut-cell "Cut Cell" drgnx-notebook-cut-cell)
    (notebook-copy-cell "Copy Cell" drgnx-notebook-copy-cell)
    (notebook-paste-cell "Paste Cell" drgnx-notebook-paste-cell)
    (notebook-delete-cell "Delete Cell" drgnx-notebook-delete-cell)
    (notebook-move-up "Move Cell Up" drgnx-notebook-move-cell-up)
    (notebook-move-down "Move Cell Down" drgnx-notebook-move-cell-down)
    (notebook-split-cell "Split Cell" drgnx-notebook-split-cell)
    (notebook-merge-cell "Merge Cell With the Next" drgnx-notebook-merge-cell-below)
    (notebook-change-type "Change Cell Type…" drgnx-notebook-change-cell-type)
    (notebook-clear-outputs "Clear Outputs" drgnx-notebook-clear-outputs)
    (notebook-select-kernel "Select Kernel…" drgnx-notebook-select-kernel)
    (notebook-open-output "Open Output" drgnx-notebook-open-output)
    (notebook-outline "Show Cell Outline" drgnx-notebook-outline)
    (notebook-kernel-log "Show Kernel Log" drgnx-notebook-kernel-log)
    (notebook-outline-visit "Go to Cell" drgnx-notebook-outline-visit drgnx-notebook-outline-mode-map drgnx-notebook--in-outline-p)
    (notebook-output-later "Output: Later Lines" drgnx-notebook-output-later drgnx-notebook-output-mode-map drgnx-notebook--in-output-p)
    (notebook-output-earlier "Output: Earlier Lines" drgnx-notebook-output-earlier drgnx-notebook-output-mode-map
                             drgnx-notebook--in-output-p)
    (notebook-copy-output "Copy Output" drgnx-notebook-copy-output)
    (notebook-toggle-outputs "Toggle Outputs" drgnx-notebook-toggle-outputs))
  "The notebook's commands: (ID TITLE FUNCTION [MAP WHEN]), registered in category Notebook;
MAP and WHEN for a view's buffer.")

(defun drgnx-notebook--in-notebook-p () (derived-mode-p 'drgnx-notebook-mode))
(defun drgnx-notebook--in-outline-p () (derived-mode-p 'drgnx-notebook-outline-mode))
(defun drgnx-notebook--in-output-p () (derived-mode-p 'drgnx-notebook-output-mode))

(drgnx-module-define 'lang/notebook
                     :doc "Jupyter notebooks: a .ipynb opens as one buffer of cells with their outputs, run on any installed kernel."
                     :stage 'startup
                     :teardown (lambda ()
                                 (setq auto-mode-alist (rassq-delete-all 'drgnx-notebook-mode auto-mode-alist))
                                 (remove-hook 'drgnx-hub-event-functions #'drgnx-notebook--event)
                                 (remove-hook 'drgnx-hub-connected-functions #'drgnx-notebook--reconnect-all)
                                 (advice-remove 'kill-region #'drgnx-notebook-guard-kill))
                     :setup
                     (lambda ()
                       (add-to-list 'auto-mode-alist '("\\.ipynb\\'" . drgnx-notebook-mode))
                       (add-hook 'drgnx-hub-event-functions #'drgnx-notebook--event)
                       (require 'drgnx-state)
                       (drgnx-notice-define-source 'notebook :title "Notebooks")
                       (drgnx-state-subscribe 'windows-changed #'drgnx-notebook--windows-changed)
                       (drgnx-state-subscribe 'selected-changed #'drgnx-notebook--windows-changed)
                       (add-hook 'drgnx-hub-connected-functions #'drgnx-notebook--reconnect-all)
                       (drgnx-notebook--segments-define)
                       (advice-add 'kill-region :before #'drgnx-notebook-guard-kill)
                       (dolist (c drgnx-notebook--commands)
                         (drgnx-command-define (nth 0 c) :title (nth 1 c) :category "Notebook" :command (nth 2 c)
                                               :map (or (nth 3 c) 'drgnx-notebook-mode-map)
                                               :scope 'editing :when (or (nth 4 c) #'drgnx-notebook--in-notebook-p)))))

(provide 'drgnx-notebook)
;;; drgnx-notebook.el ends here
