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
(defvar-local drgnx-notebook--prompts (make-hash-table :test #'equal) "ID → execution count (an integer), or nil.")
(defvar-local drgnx-notebook--state "idle" "The kernel's state as the hub last said: idle, busy, starting, dead.")
(defvar-local drgnx-notebook--running nil "The cell the kernel runs now, or nil.")
(defvar-local drgnx-notebook--selected nil "The overlay that tints the selected cell.")
(defvar-local drgnx-notebook--language nil "The notebook's language (python), for the cells' chip.")
(defvar-local drgnx-notebook--kernel nil "The kernelspec the hub started, or nil.")
(defvar-local drgnx-notebook--tails (make-hash-table :test #'equal) "ID → the version of the last tail put.")
(defvar-local drgnx-notebook--outputs-hidden nil "Non-nil while the outputs are hidden.")
(defvar-local drgnx-notebook--rescans 0 "How many rescans ran (for the tests).")

(defvar drgnx-notebook--buffers (make-hash-table :test #'equal :weakness 'value)
  "Hub notebook id → its buffer.")

(defvar drgnx-notebook--clipboard nil "The cell cut or copied last: (:type TYPE :source SOURCE).")

(defconst drgnx-notebook--debounce 0.12 "Seconds of quiet before the rescan.")

;;;; The hub

(defun drgnx-notebook--call (method params callback)
  "Ask the hub METHOD with PARAMS; CALLBACK gets (RESULT ERROR).  The one place the notebook buffer reaches the hub."
  (drgnx-hub-call method params callback))

(defun drgnx-notebook--call-sync (method params &optional timeout)
  "METHOD's result, waiting up to TIMEOUT seconds (a save is a command the user gave)."
  (drgnx-hub-call-sync method params timeout))

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
                           (message "drgnx notebook: cell id %s was repeated; the second is %s" id new)
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
  (let* ((pos (posn-point (event-end event)))
         (id (and pos (get-text-property pos 'drgnx-notebook-run))))
    (when id (drgnx-notebook--run-ids (list id)))))

(defun drgnx-notebook--prompt (id type)
  "The prompt of cell ID: [n], [*] while it runs, [ ] before it ran; none for a markdown or raw cell."
  (if (not (eq type 'code)) ""
    (let ((n (gethash id drgnx-notebook--prompts)))
      (cond ((equal id drgnx-notebook--running) "[*]")
            (n (format "[%d]" n))
            (t "[ ]")))))

(defun drgnx-notebook--head-string (id type)
  "The header strip of cell ID, built when something it shows changes (never while redisplay draws)."
  (concat
   (if (eq type 'code)
       (propertize (drgnx-notebook--icon 'play 'drgnx-notebook-run-button)
                   'drgnx-notebook-run id 'keymap drgnx-notebook-run-map 'mouse-face 'drgnx-hover
                   'help-echo "Run this cell")
     "")
   (if (eq type 'code) " " "")
   (propertize (drgnx-notebook--prompt id type) 'face 'drgnx-notebook-prompt)
   " "
   (propertize (format " %s " type) 'face 'drgnx-notebook-chip)
   (if (and (eq type 'code) drgnx-notebook--language)
       (propertize (format " %s " drgnx-notebook--language) 'face 'drgnx-notebook-chip) "")
   (propertize " " 'face 'drgnx-notebook-head)))

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
    (drgnx-notebook--select-at (point))))

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
    (drgnx-notebook--sync-chrome))
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

(defun drgnx-notebook--select-at (pos)
  "Tint the cell at POS as the selected one (one overlay, moved)."
  (let ((c (and drgnx-notebook--cells (drgnx-notebook--cell-at pos))))
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

(defun drgnx-notebook--tail-string (tail)
  "The string put after a cell's tail boundary, from the hub's TAIL (:text :runs :more_lines :stale): its text with the
runs' faces on it, and a newline, since the next row is the next cell's header."
  (let* ((text (or (plist-get tail :text) "")) (n (length text)))
    (if (zerop n) ""
      (let ((s (copy-sequence text)))
        (add-face-text-property 0 n (if (plist-get tail :stale) '(drgnx-notebook-output drgnx-notebook-stale) 'drgnx-notebook-output) nil s)
        (dolist (run (plist-get tail :runs))
          (let ((start (min n (or (plist-get run :start) 0))) (end (min n (or (plist-get run :end) 0)))
                (faces (drgnx-notebook--run-faces run)))
            (when (< start end) (dolist (face faces) (add-face-text-property start end face nil s)))))
        (concat s "\n")))))

(defun drgnx-notebook--put-tail (tail)
  "Put the hub's TAIL after its cell: only when it is newer than the one shown."
  (let* ((id (plist-get tail :cell)) (ov (plist-get (drgnx-notebook--chrome-of id) :tail))
         (version (or (plist-get tail :version) 0)))
    (when (and ov (overlay-buffer ov) (>= version (or (gethash id drgnx-notebook--tails) 0)))
      (puthash id version drgnx-notebook--tails)
      (when-let* ((n (plist-get tail :execution_count))) (puthash id n drgnx-notebook--prompts) (drgnx-notebook--refresh-head id))
      (overlay-put ov 'after-string (drgnx-notebook--tail-string tail)))))

(defun drgnx-notebook--request-tail (id)
  "Ask the hub for cell ID's tail (a boundary came back, or a cell moved): the string comes from the hub's state."
  (let ((buffer (current-buffer)) (nb drgnx-notebook--id))
    (when nb
      (drgnx-notebook--call "notebook/tail" (list :id nb :cell id)
                            (lambda (r e)
                              (when (and r (not e) (buffer-live-p buffer))
                                (with-current-buffer buffer (drgnx-notebook--put-tail r))))))))

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
  "A kernel's state: the cell it runs, and the queue."
  (let ((old drgnx-notebook--running))
    (setq drgnx-notebook--state (or (plist-get data :state) "idle")
          drgnx-notebook--running (and (member drgnx-notebook--state '("busy" "running")) (plist-get data :cell)))
    (dolist (id (delq nil (list old drgnx-notebook--running))) (drgnx-notebook--refresh-head id))
    (force-mode-line-update)))

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
          drgnx-notebook--kernel (plist-get result :kernelspec))
    (puthash drgnx-notebook--id (current-buffer) drgnx-notebook--buffers)
    (erase-buffer)
    (dolist (c cells)
      (let ((id (plist-get c :id)) (type (intern (or (plist-get c :type) "code"))))
        (puthash id t drgnx-notebook--known)
        (when-let* ((n (plist-get c :execution_count))) (puthash id n drgnx-notebook--prompts))
        (insert (drgnx-notebook--cell-text id type (or (plist-get c :source) "")))))
    (when (null cells) (insert (drgnx-notebook--cell-text (drgnx-notebook--mint) 'code "")))
    (setq buffer-undo-list nil buffer-read-only nil)
    (set-buffer-modified-p nil)
    (setq drgnx-notebook--dirty t drgnx-notebook--cells nil)
    (drgnx-notebook--rescan)
    (dolist (tail (plist-get result :tails)) (drgnx-notebook--put-tail tail))
    (goto-char (if drgnx-notebook--cells (1+ (plist-get (car drgnx-notebook--cells) :head)) (point-min)))
    (drgnx-notebook--select-at (point))))

(defun drgnx-notebook--begin-open ()
  "Ask the hub to open the file this buffer visited; the text is its JSON until the answer comes."
  (when (and buffer-file-name (null drgnx-notebook--id))
    (let ((buffer (current-buffer)) (text (buffer-substring-no-properties (point-min) (point-max))))
      (setq buffer-read-only t)
      (drgnx-notebook--call "notebook/open" (list :path (expand-file-name buffer-file-name) :text text)
                            (lambda (r e)
                              (when (buffer-live-p buffer)
                                (with-current-buffer buffer
                                  (if (or e (null r))
                                      (progn (setq buffer-read-only nil)
                                             (message "drgnx: %s is not opened as a notebook: %s" buffer-file-name (or e "no answer"))
                                             (fundamental-mode))
                                    (drgnx-notebook--install r)))))))))

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
  (when drgnx-notebook--id
    (remhash drgnx-notebook--id drgnx-notebook--buffers)
    (ignore-errors (drgnx-notebook--call "notebook/close" (list :id drgnx-notebook--id) #'ignore))))

(define-derived-mode drgnx-notebook-mode prog-mode "Notebook"
  "Major mode of a Jupyter notebook: one buffer of cells, the output after each (docs/guide/notebooks.md)."
  (setq-local yank-excluded-properties (append '(drgnx-cell drgnx-cell-type) yank-excluded-properties)
              require-final-newline nil
              drgnx-notebook--chrome (make-hash-table :test #'equal)
              drgnx-notebook--known (make-hash-table :test #'equal)
              drgnx-notebook--prompts (make-hash-table :test #'equal)
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
    (drgnx-notebook--mark-known)
    ;; the buffer's cells are the notebook's first (`notebook/sync'), then the cells to run are queued (`notebook/execute')
    (drgnx-notebook--call
     "notebook/sync" (list :id nb :cells cells)
     (lambda (_r e)
       (cond ((and e (buffer-live-p buffer)) (message "drgnx notebook: %s" e))
             ((buffer-live-p buffer)
              (drgnx-notebook--call
               "notebook/execute" (list :id nb :cells (vconcat run))
               (lambda (_r e)
                 (when (and e (buffer-live-p buffer))
                   (if (string-match-p "no kernel\\|not started\\|has no kernel\\|ended" e)
                       (with-current-buffer buffer (drgnx-notebook--start-then ids))
                     (message "drgnx notebook: %s" e)))))))))))

(defun drgnx-notebook--start-then (ids)
  "Start the kernel (the notebook's own, or ask when several fit), then run IDS."
  (let ((buffer (current-buffer)) (nb drgnx-notebook--id))
    (drgnx-notebook--call "notebook/start" (list :id nb)
                          (lambda (r e)
                            (when (buffer-live-p buffer)
                              (with-current-buffer buffer
                                (cond ((and e (string-match "several kernels fit" e)) (drgnx-notebook-select-kernel ids))
                                      (e (message "drgnx notebook: %s" e))
                                      (t (setq drgnx-notebook--kernel (or (plist-get r :kernel) r))
                                         (drgnx-notebook--run-ids ids)))))))))

(defun drgnx-notebook-select-kernel (&optional then-run)
  "Choose the notebook's kernel from the installed kernelspecs and start it."
  (interactive)
  (drgnx-notebook--ensure)
  (let ((buffer (current-buffer)) (nb drgnx-notebook--id))
    (drgnx-notebook--call "notebook/kernels" nil
                          (lambda (r e)
                            (when (buffer-live-p buffer)
                              (with-current-buffer buffer
                                (let* ((names (mapcar (lambda (k) (plist-get k :name)) (plist-get r :kernels))))
                                  (cond (e (message "drgnx notebook: %s" e))
                                        ((null names) (message "drgnx notebook: no kernelspec is installed"))
                                        (t (let ((name (completing-read "Kernel: " names nil t)))
                                             (drgnx-notebook--call "notebook/start" (list :id nb :kernel name)
                                                                   (lambda (_r e2)
                                                                     (when (and (buffer-live-p buffer))
                                                                       (with-current-buffer buffer
                                                                         (if e2 (message "drgnx notebook: %s" e2)
                                                                           (setq drgnx-notebook--kernel name)
                                                                           (when then-run (drgnx-notebook--run-ids then-run)))))))))))))))))

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
  (drgnx-notebook--call "notebook/interrupt" (list :id drgnx-notebook--id) (lambda (_r e) (when e (message "drgnx notebook: %s" e)))))

(defun drgnx-notebook-restart-kernel (&optional then-run-all)
  "Restart the kernel: it ends and starts again, the outputs stay.  THEN-RUN-ALL: run every code cell once it is up."
  (interactive)
  (drgnx-notebook--ensure)
  (let ((buffer (current-buffer)) (nb drgnx-notebook--id) (name drgnx-notebook--kernel))
    (drgnx-notebook--call "notebook/shutdown" (list :id nb)
                          (lambda (_r _e)
                            (when (buffer-live-p buffer)
                              (drgnx-notebook--call "notebook/start" (append (list :id nb) (and name (list :kernel name)))
                                                    (lambda (_r2 e2)
                                                      (when (buffer-live-p buffer)
                                                        (with-current-buffer buffer
                                                          (cond (e2 (message "drgnx notebook: %s" e2))
                                                                (then-run-all (drgnx-notebook-run-all))))))))))))

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
                            (if e (message "drgnx notebook: %s" e)
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

(defun drgnx-notebook-clear-outputs ()
  "Clear every cell's output."
  (interactive)
  (drgnx-notebook--ensure)
  (user-error "Clearing outputs needs the hub's notebook/clear, which is not there yet"))

(defun drgnx-notebook-open-output ()
  "Open this cell's full output in its own view."
  (interactive)
  (user-error "The full-output view is a hub-fed Sjá view (not built yet): copy the output instead"))

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
    (notebook-copy-output "Copy Output" drgnx-notebook-copy-output)
    (notebook-toggle-outputs "Toggle Outputs" drgnx-notebook-toggle-outputs))
  "The notebook's commands: (ID TITLE FUNCTION), registered in category Notebook.")

(defun drgnx-notebook--in-notebook-p () (derived-mode-p 'drgnx-notebook-mode))

(drgnx-module-define 'lang/notebook
                     :doc "Jupyter notebooks: a .ipynb opens as one buffer of cells with their outputs, run on any installed kernel."
                     :stage 'startup
                     :teardown (lambda ()
                                 (setq auto-mode-alist (rassq-delete-all 'drgnx-notebook-mode auto-mode-alist))
                                 (remove-hook 'drgnx-hub-event-functions #'drgnx-notebook--event)
                                 (advice-remove 'kill-region #'drgnx-notebook-guard-kill))
                     :setup
                     (lambda ()
                       (add-to-list 'auto-mode-alist '("\\.ipynb\\'" . drgnx-notebook-mode))
                       (add-hook 'drgnx-hub-event-functions #'drgnx-notebook--event)
                       (advice-add 'kill-region :before #'drgnx-notebook-guard-kill)
                       (dolist (c drgnx-notebook--commands)
                         (drgnx-command-define (nth 0 c) :title (nth 1 c) :category "Notebook" :command (nth 2 c) :map 'drgnx-notebook-mode-map
                                               :scope 'editing :when #'drgnx-notebook--in-notebook-p))))

(provide 'drgnx-notebook)
;;; drgnx-notebook.el ends here
