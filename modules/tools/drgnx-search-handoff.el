;;; drgnx-search-handoff.el --- Ask an Agent about a search's results  -*- lexical-binding: t -*-

;;; Commentary:

;; Ask an Agent (docs/guide/replace.md, "Ask an Agent"): the Search view's ticked matches (the row's when none is
;; ticked) go to an agent with what to do.  A small card in the popup lane takes the instruction (prefilled from the
;; replacement) and who: a new worker in a worktree of its own (the default profile), or a live session (a paired chat
;; edits in this checkout).  Send asks the hub (`search/handoff'), which builds the brief and starts or messages the
;; session; the handed-off rows show the agent's mark, and the view's status line its state chip (`sent', `editing',
;; `done 47 / 2 skipped') from `search-handoff-state'.  Re-run in Worktree runs the same search in a worker's worktree
;; to show what is left.  The agent's edits come back through the existing review (a worker's hunks in the Work space,
;; a pair's in the user's buffers): this file links to them only.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-icons)                  ; and through it the pixels and the buttons
(require 'drgnx-faces)

(declare-function drgnx-replace--live-view "drgnx-replace")
(declare-function drgnx-replace--rows-p "drgnx-replace")
(declare-function drgnx-replace--rows-off "drgnx-replace")
(declare-function drgnx-replace--rows-group-p "drgnx-replace")
(declare-function drgnx-replace--rows-file-matches "drgnx-replace")
(declare-function drgnx-replace--text "drgnx-replace")
(declare-function drgnx-replace--update-status "drgnx-replace")
(declare-function drgnx-replace--search-now "drgnx-replace")
(declare-function drgnx-view-nav-selection "drgnx-view-patch")
(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-agents-sessions "drgnx-agents")
(declare-function drgnx-agents-default-profile "drgnx-agents")
(declare-function drgnx-agent-session-remote "drgnx-agents")
(declare-function drgnx-agent-session-name "drgnx-agents")
(declare-function drgnx-agent-session-status "drgnx-agents")
(declare-function drgnx-agent-session-cwd "drgnx-agents")
(declare-function drgnx-agent-session-profile "drgnx-agents")
(declare-function drgnx-agents-profile "drgnx-agents")
(declare-function drgnx-ai-agent-gateway-chain "drgnx-ai")
(declare-function drgnx-ai-remote-p "drgnx-ai")
(declare-function drgnx-ai-confirm-project-route "drgnx-ai")
(declare-function drgnx-agent-identity "drgnx-agent-identity")
(declare-function drgnx-agents-editor-ordinal "drgnx-agents-editor")
(declare-function drgnx-surfaces-key-label "drgnx-surfaces")
(declare-function drgnx-replace--sheet-button "drgnx-replace")
(declare-function drgnx-ui--button-map "drgnx-ui-kit")
(declare-function drgnx-color-rgb "drgnx-color")
(declare-function drgnx-color-hex "drgnx-color")
(defvar drgnx-hub--events)
(defvar drgnx-replace-view)
(defvar drgnx-replace--root)
(defvar drgnx-replace--hub-counts)
(defvar drgnx-replace-buffer-name)
(defvar drgnx-view-patch)
(defvar drgnx-popup-width)
(declare-function drgnx-popup-refit "drgnx-popup")

(defface drgnx-search-handoff-chip '((t :inherit drgnx-chip))
  "The Search view's state chip of a hand-off: `sent', `editing', `done 47 / 2 skipped'." :group 'drgnx)

(defface drgnx-search-handoff-title '((t :inherit drgnx-ui-heading))
  "The Ask an Agent card's title." :group 'drgnx)

(defconst drgnx-search-handoff-buffer-name "*drgnx ask an agent*")

;;;; What is handed off

(defun drgnx-search-handoff--what ()
  "In the Search view: (IDS OFF N) of what Ask an Agent hands off: every ticked match (IDS nil, OFF the unticked),
or, when none is ticked, the selected row's (a match, or a file's matches).  N is how many."
  (let* ((off (drgnx-replace--rows-off)) (total (or (cdr drgnx-replace--hub-counts) 0)))
    (if (< (hash-table-count off) total)
        (list nil (hash-table-keys off) (- total (hash-table-count off)))
      (let* ((id (or (get-text-property (point) 'drgnx-work-id) (drgnx-view-nav-selection)
                     (user-error "Tick matches, or select a row, to ask an agent about")))
             (ids (if (drgnx-replace--rows-group-p id) (drgnx-replace--rows-file-matches id) (list id))))
        (list ids nil (length ids))))))

(defun drgnx-search-handoff--choices (root)
  "Who a hand-off can go to: a new worker of the default profile in a worktree of its own, a new chat of it paired in
the checkout ROOT (it edits your buffers), then each live session (hub-run) by name and state, one in ROOT marked as a
pair.  Each (LABEL . TO), TO as `search/handoff' takes it."
  (let ((profile (drgnx-agents-default-profile)))
    (append
     (list (cons "New worker, own worktree" (list :new (list :profile profile)))
           (cons "New pair here" (list :pair (list :profile profile))))
     (delq nil
           (mapcar (lambda (s)
                     (when-let* ((id (drgnx-agent-session-remote s))
                                 (status (drgnx-agent-session-status s))
                                 ((not (memq status '(exited stopped)))))
                       (cons (format "%s%s (%s)"
                                     (if (and root (drgnx-agent-session-cwd s)
                                              (string= (file-name-as-directory
                                                        (expand-file-name (drgnx-agent-session-cwd s)))
                                                       (file-name-as-directory (expand-file-name root))))
                                         "Pair · " "")
                                     (drgnx-agent-session-name s) status)
                             (list :session (list :id id)))))
                   (and (fboundp 'drgnx-agents-sessions) (drgnx-agents-sessions)))))))

;;;; The card

(defvar-local drgnx-search-handoff--ask nil
  "The card's hand-off: (:view V :ids IDS :off OFF :n N :root ROOT :choices CHOICES :who K :hidden BOOL).")

(defvar drgnx-search-handoff-keys-map (make-sparse-keymap)
  "The Ask an Agent card's keys (Send, Cancel, next who, hidden files), from the key profiles.")

(defvar drgnx-search-handoff-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-search-handoff-keys-map) m)
  "The Ask an Agent card's keymap: the profiles' keys; the rest is the instruction's text.")

(define-derived-mode drgnx-search-handoff-mode text-mode "Ask an Agent"
  "The Ask an Agent card (search-view.html `.ho'): its title, the instruction box (the only text you edit), who it
goes to as chips and where that agent sends, the context it gets with its size, and Cancel / Send."
  (setq-local mode-line-format nil header-line-format nil
              drgnx-popup-width drgnx-search-handoff--width word-wrap t truncate-lines nil
              ;; the instruction wraps 9 px or so inside its ring, which ends 2 px inside the window
              right-margin-width 1)
  (add-hook 'kill-buffer-hook #'drgnx-search-handoff--unblock nil t))

(defun drgnx-search-handoff--key (id)
  "Registry command ID's key, short, or nil."
  (and (fboundp 'drgnx-surfaces-key-label) (drgnx-surfaces-key-label id :short t)))

(defvar-local drgnx-search-handoff--box nil
  "(START . END): markers around the instruction, the card's only editable text.")

(defvar-local drgnx-search-handoff--box-ov nil "The overlay that indents the instruction inside its box.")

(defconst drgnx-search-handoff--width 436
  "The card's window width in logical pixels: the mockup's `.ho' (460) less the modal popup's 12 px border each side.")

(defun drgnx-search-handoff--gap (px)
  "A stretch PX logical pixels wide."
  (propertize " " 'display `(space :width (,(drgnx-px px)))))

(defconst drgnx-search-handoff--pad 2
  "The card's padding inside its window, in logical pixels: the mockup's 14 less the modal popup's 12 px border.")

(defun drgnx-search-handoff--edge ()
  "Where the card's boxes and its right-aligned text end, in pixels: its width less its 14 px padding."
  (drgnx-px (- drgnx-search-handoff--width drgnx-search-handoff--pad)))

(defun drgnx-search-handoff--at-edge (str)
  "STR ending at the text area's right (the card's edge, less the right margin the instruction wraps inside), less
a column: a line that reaches the right edge wraps (the window has no right fringe for the wrap glyph)."
  (concat (propertize " " 'display `(space :align-to (- right (,(+ (string-pixel-width str (current-buffer))
                                                                   (frame-char-width))))))
          str))

(defun drgnx-search-handoff--room (px &optional last)
  "A row PX logical pixels high: its text in a tiny font, so the stretch alone sets its height; LAST: the card's
last row, with no newline after it."
  (propertize (concat (propertize " " 'display `(space :width (1) :height (,(drgnx-px px)))) (if last "" "\n"))
              'face '(:height 0.1)))

(defun drgnx-search-handoff--rule ()
  "The card's rule (the mockup's title and foot lines): a row one line high, filled in the border colour, across the
card (its text in a tiny font, so the stretch alone sets its height)."
  (concat (propertize " " 'display `(space :align-to right :height (,(drgnx-px-line 1)))
                      'face '(drgnx-border (:height 0.1)))
          (propertize "\n" 'face '(:height 0.1))))

(defun drgnx-search-handoff--instruction ()
  "The card's instruction: the text in its box."
  (string-trim (buffer-substring-no-properties (car drgnx-search-handoff--box) (cdr drgnx-search-handoff--box))))

(defun drgnx-search-handoff--tokens (n)
  "N tokens as the card says it: `~840', `~1.1k'."
  (if (< n 1000) (format "~%d" n) (format "~%.1fk" (/ n 1000.0))))

(defun drgnx-search-handoff--title ()
  "The card's title row (44 px, the mockup's `.ho .t'): the agent icon, how many results, the query at the right."
  (let ((a drgnx-search-handoff--ask) (n (plist-get drgnx-search-handoff--ask :n)))
    (concat (drgnx-search-handoff--gap drgnx-search-handoff--pad) (drgnx-look-icon 'bot 'drgnx-text-muted) (drgnx-search-handoff--gap 8)
            (propertize (format "Ask an agent about %d result%s" n (if (= n 1) "" "s")) 'face 'drgnx-search-handoff-title)
            (if (string-empty-p (or (plist-get a :query) ""))
                ""
              (drgnx-search-handoff--at-edge (propertize (plist-get a :query) 'face 'drgnx-text-subtle)))
            (propertize "\n" 'line-height 2.4)
            (drgnx-search-handoff--rule)
            (drgnx-search-handoff--room 10))))

(defun drgnx-search-handoff--chip (i label on)
  "Who chip I (LABEL; ON when chosen): a pill that chooses it when clicked; the new worker's with its fork icon."
  (let ((map (drgnx-ui--button-map (lambda () (drgnx-search-handoff--choose i)) 'text))
        (face (if on 'drgnx-pill-accent 'drgnx-pill)))
    (propertize (concat (drgnx-search-handoff--gap 6)
                        (if (= i 0) (concat (drgnx-look-icon 'git-fork face 14) (drgnx-search-handoff--gap 3)) "")
                        label (drgnx-search-handoff--gap 6))
                'face face 'mouse-face 'highlight 'keymap map 'follow-link t 'help-echo "Ask this agent"
                'drgnx-search-handoff-who label)))

(defun drgnx-search-handoff--inset ()
  "Where the boxes' text starts: 9 px inside their rings."
  (+ drgnx-search-handoff--pad 9))

(defun drgnx-search-handoff--wrap (str)
  "STR in lines that fit the context box's inside (9 px within its ring each side), two at most, the second cut with
an ellipsis (the mockup's `.ctxbox' rows)."
  (let ((width (- (drgnx-search-handoff--edge) (drgnx-px (+ (drgnx-search-handoff--inset) 9)))))
    (if (<= (string-pixel-width str (current-buffer)) width)
        (list str)
      (let* ((first (truncate-string-pixelwise str width (current-buffer)))
             (rest (string-trim-left (substring str (length first)))))
        (list first (truncate-string-pixelwise rest width (current-buffer) "…"))))))

(defun drgnx-search-handoff--context-lines ()
  "The context box's lines (the mockup's `.ho .ctxbox'): the first places by file, then how many more and the
brief's size; the hidden files left out, with the key that puts them in."
  (let* ((a drgnx-search-handoff--ask) (c (plist-get a :context)) (pad (drgnx-search-handoff--gap (drgnx-search-handoff--inset)))
         (rows (append (plist-get c :rows) nil)) (file nil) (out nil)
         (tokens (+ (or (plist-get c :tokens) 0)
                    (/ (length (drgnx-search-handoff--instruction)) 4))))
    (if (null c)
        (list (concat pad (propertize "Reading the places…" 'face 'drgnx-text-subtle)))
      (dolist (r rows)
        (unless (equal (plist-get r :path) file)
          (setq file (plist-get r :path))
          (push (concat pad (propertize file 'face '(default drgnx-replace-sheet-code))) out))
        (dolist (line (drgnx-search-handoff--wrap
                       (propertize (format "%d  %s%s" (plist-get r :line)
                                           (if (plist-get r :ctx) (format "in %s  " (plist-get r :ctx)) "")
                                           (plist-get r :text))
                                   'face '(drgnx-text-muted drgnx-replace-sheet-code))))
          (push (concat pad line) out)))
      (let ((more (- (or (plist-get c :total) 0) (length rows))))
        (push (concat pad (propertize (format "%s%s tokens" (if (> more 0) (format "⋯ %d more · " more) "")
                                              (drgnx-search-handoff--tokens tokens))
                                      'face '(drgnx-text-subtle drgnx-replace-sheet-code)))
              out))
      (let ((hidden (append (plist-get c :hidden) nil)))
        (when (or hidden (plist-get a :hidden))
          (push (concat pad (propertize (if (plist-get a :hidden) "hidden files in"
                                          (format "%d hidden file%s left out: %s" (length hidden)
                                                  (if (= 1 (length hidden)) "" "s") (string-join hidden ", ")))
                                        'face '(warning drgnx-replace-sheet-code))
                        (if-let* ((k (drgnx-search-handoff--key 'search-handoff-hidden)))
                            (propertize (format "  %s %s" k (if (plist-get a :hidden) "leave out" "put in"))
                                        'face 'drgnx-text-subtle)
                          ""))
                out)))
      (nreverse out))))

(defun drgnx-search-handoff--lower ()
  "The card under the instruction: who, where it sends, the context box, the foot with Cancel and Send."
  (let* ((a drgnx-search-handoff--ask) (choices (plist-get a :choices)) (who (plist-get a :who))
         (to (cdr (nth who choices)))
         (route (drgnx-search-handoff--route (drgnx-search-handoff--profile-of to) (plist-get a :root)))
         (room #'drgnx-search-handoff--room))
    (concat
     "\n" (funcall room 8)
     (drgnx-search-handoff--gap drgnx-search-handoff--pad)
     (mapconcat #'identity (cl-loop for (label . _) in choices for i from 0
                                    collect (drgnx-search-handoff--chip i label (= i who)))
                (drgnx-search-handoff--gap 4))
     "\n" (drgnx-search-handoff--gap drgnx-search-handoff--pad)
     (propertize (concat "via " (car route)) 'face (if (cdr route) 'drgnx-text-subtle 'error))
     "\n" (funcall room 8)
     (propertize (concat (mapconcat #'identity (drgnx-search-handoff--context-lines) "\n") "\n")
                 'drgnx-search-handoff-context t)
     (funcall room 10)
     (drgnx-search-handoff--rule)
     (funcall room 10)
     (drgnx-search-handoff--gap drgnx-search-handoff--pad)
     (propertize (cond ((plist-get to :new) "Hunks come back to Review")
                       ((or (plist-get to :pair) (string-prefix-p "Pair · " (car (nth who choices))))
                        "Edits go to your buffers")
                       (t "Edits come back as the agent's"))
                 'face 'drgnx-text-subtle)
     (drgnx-search-handoff--at-edge
      (concat (drgnx-ui-button "Cancel" 'search-handoff-cancel :face 'drgnx-ui-button) (drgnx-search-handoff--gap 8)
              (drgnx-replace--sheet-button "Send" 'search-handoff-send 'drgnx-ui-button-primary)))
     "\n" (drgnx-search-handoff--room 10 t))))

(defun drgnx-search-handoff--draw (&optional instruction)
  "Draw the card from `drgnx-search-handoff--ask', keeping the instruction (INSTRUCTION when it is new)."
  (let ((inhibit-read-only t) (buffer-undo-list t)
        (text (or instruction (and drgnx-search-handoff--box (drgnx-search-handoff--instruction)) "")))
    (when drgnx-search-handoff--box
      (set-marker (car drgnx-search-handoff--box) nil) (set-marker (cdr drgnx-search-handoff--box) nil))
    (erase-buffer)
    ;; the title cannot be typed before or into; the instruction after it is free; the rest refuses typing at its end
    (insert (propertize (drgnx-search-handoff--title) 'read-only t 'front-sticky '(read-only) 'rear-nonsticky t))
    (let ((start (point-marker)))
      (insert text)
      ;; the end advances with typing at it, so it is made once the rest is in (else it would pass the rest)
      (let ((end (point)))
        (setq drgnx-search-handoff--box (cons start (copy-marker end)))
        (insert (propertize (drgnx-search-handoff--lower) 'read-only t))
        (set-marker (cdr drgnx-search-handoff--box) nil)
        (setq end (copy-marker end t))
        (setcdr drgnx-search-handoff--box end)
        (if drgnx-search-handoff--box-ov
            (move-overlay drgnx-search-handoff--box-ov start end)
          (setq drgnx-search-handoff--box-ov (make-overlay start end nil nil t))
          (overlay-put drgnx-search-handoff--box-ov 'line-prefix (drgnx-search-handoff--gap (drgnx-search-handoff--inset)))
          (overlay-put drgnx-search-handoff--box-ov 'wrap-prefix (drgnx-search-handoff--gap (drgnx-search-handoff--inset))))
        (goto-char end)))
    (drgnx-search-handoff--blocks)))

(defun drgnx-search-handoff--redraw ()
  "Draw the card again where it is, point kept in the instruction."
  (let ((at (- (point) (car drgnx-search-handoff--box))))
    (drgnx-search-handoff--draw)
    (goto-char (max (car drgnx-search-handoff--box) (min (cdr drgnx-search-handoff--box)
                                                         (+ (car drgnx-search-handoff--box) at))))))

;; The two boxes are Glitnir block rings (`glitnir-blocks'), as the Replace All sheet's hunk card: the instruction's
;; in the focus colour, the context's in the subtle border, radius 6, 14 px in from the card's sides.

(defvar-local drgnx-search-handoff--block nil "The card's boxes as last set (`glitnir-blocks'), or nil.")

(defun drgnx-search-handoff--blocks ()
  "Give the windows showing the card its two boxes."
  (dolist (b drgnx-search-handoff--block) (set-marker (nth 1 b) nil) (set-marker (nth 2 b) nil))
  (let* ((bg (and (fboundp 'drgnx-color-rgb) (drgnx-color-rgb (face-background 'drgnx-surface-overlay nil t))))
         (ring (lambda (from to face)
                 `(ring ,(copy-marker from) ,(copy-marker to t) :x0 ,(drgnx-px drgnx-search-handoff--pad) :x1 ,(drgnx-search-handoff--edge)
                        :radius ,(drgnx-px 6) :ring ,face ,@(and bg (list :beneath (drgnx-color-hex bg)))))))
    (setq drgnx-search-handoff--block
          (list (funcall ring (car drgnx-search-handoff--box) (1+ (cdr drgnx-search-handoff--box)) 'drgnx-focus-line)
                (save-excursion
                  (goto-char (point-min))
                  (let ((m (text-property-search-forward 'drgnx-search-handoff-context t t)))
                    (funcall ring (prop-match-beginning m) (prop-match-end m) 'drgnx-border-subtle))))))
  (dolist (w (get-buffer-window-list (current-buffer) nil t))
    (set-window-parameter w 'glitnir-blocks drgnx-search-handoff--block)))

(defun drgnx-search-handoff--unblock ()
  "The card goes (`kill-buffer-hook'): no window keeps its boxes."
  (let ((card drgnx-search-handoff--block))
    (when card
      (walk-windows (lambda (w) (when (eq (window-parameter w 'glitnir-blocks) card)
                                  (set-window-parameter w 'glitnir-blocks nil)))
                    nil t))))

(defun drgnx-search-handoff--context ()
  "Ask the hub for the context box (`search/handoff-context'); the card is drawn again when it answers."
  (let ((a drgnx-search-handoff--ask) (buf (current-buffer)))
    (drgnx-hub--call-on drgnx-hub--events "search/handoff-context"
                        (append (list :view (plist-get a :view))
                                (if (plist-get a :ids) (list :ids (vconcat (plist-get a :ids)))
                                  (list :off (vconcat (plist-get a :off))))
                                (and (plist-get a :hidden) (list :hidden t)))
                        (lambda (r err)
                          (when (and (not err) (buffer-live-p buf))
                            (with-current-buffer buf
                              (setq drgnx-search-handoff--ask (plist-put drgnx-search-handoff--ask :context r))
                              (drgnx-search-handoff--redraw)
                              (when (fboundp 'drgnx-popup-refit) (drgnx-popup-refit buf))))))))

(defun drgnx-search-handoff--profile-of (to)
  "The agent profile TO (a `search/handoff' target) runs: a new one's, or the live session's."
  (or (plist-get (or (plist-get to :new) (plist-get to :pair)) :profile)
      (when-let* ((id (plist-get (plist-get to :session) :id)) ((fboundp 'drgnx-agents-sessions)))
        (seq-some (lambda (s) (and (equal (drgnx-agent-session-remote s) id) (drgnx-agent-session-profile s)))
                  (drgnx-agents-sessions)))))

(defun drgnx-search-handoff--route (profile root)
  "Where PROFILE's agent sends its requests, as the card says it: (TEXT . OK).  A gateway profile's providers come
from its chain, which keeps only the remote steps of the project's routes (ROOT's .drgnx/ai.eld) you allowed; OK is
nil when none is left.  Another profile talks to its vendor's own service."
  (let* ((p (and profile (cdr (ignore-errors (drgnx-agents-profile profile)))))
         (kind (plist-get p :ai))
         (chain (and kind (fboundp 'drgnx-ai-agent-gateway-chain)
                     (let ((default-directory (file-name-as-directory (or root default-directory))))
                       (ignore-errors (drgnx-ai-agent-gateway-chain kind (plist-get p :model)))))))
    (cond ((not kind) (cons "its vendor's own service" t))
          ((null chain) (cons "no provider the project's routes allow" nil))
          (t (cons (mapconcat (lambda (step)
                                (format "%s (%s)" (car step)
                                        (if (and (fboundp 'drgnx-ai-remote-p) (drgnx-ai-remote-p (car step)))
                                            "remote" "local")))
                              chain " → ")
                   t)))))

(defun drgnx-search-to-agent ()
  "Ask an agent to work on the Search view's ticked matches (the selected row's when none is ticked)."
  (interactive)
  (with-current-buffer (drgnx-replace--live-view)
    (unless (drgnx-replace--rows-p) (user-error "Ask an Agent needs a text search"))
    ;; a project's remote route is asked about here, in the command, once (as every AI command does)
    (when (and drgnx-replace--root (require 'drgnx-ai nil t))
      (let ((default-directory (file-name-as-directory drgnx-replace--root))) (drgnx-ai-confirm-project-route)))
    (pcase-let* ((`(,ids ,off ,n) (drgnx-search-handoff--what))
                 (replace (drgnx-replace--text 'replace)) (find (drgnx-replace--text 'find))
                 (ask (list :view drgnx-replace-view :ids ids :off off :n n :root drgnx-replace--root :query find
                            :choices (drgnx-search-handoff--choices drgnx-replace--root) :who 0 :hidden nil))
                 (buf (get-buffer-create drgnx-search-handoff-buffer-name)))
      (with-current-buffer buf
        (drgnx-search-handoff-mode)
        (setq drgnx-search-handoff--ask ask)
        (drgnx-search-handoff--draw
         (if (string-empty-p replace) ""
           (format "Replace `%s' with `%s' in these places, keeping behaviour." find replace)))
        (drgnx-search-handoff--context))
      (pop-to-buffer buf)
      (with-current-buffer buf (drgnx-search-handoff--blocks)))))

(defun drgnx-search-handoff--choose (i)
  "On the card: the agent it goes to is choice I."
  (setq drgnx-search-handoff--ask (plist-put drgnx-search-handoff--ask :who i))
  (drgnx-search-handoff--redraw))

(defun drgnx-search-handoff-next-who ()
  "On the Ask an Agent card: who it goes to next (a new worker, each live session)."
  (interactive)
  (let ((a drgnx-search-handoff--ask))
    (drgnx-search-handoff--choose (mod (1+ (plist-get a :who)) (length (plist-get a :choices))))))

(defun drgnx-search-handoff-hidden ()
  "On the Ask an Agent card: put the matches in hidden files (dot paths, secret-looking names) in the brief, or not."
  (interactive)
  (setq drgnx-search-handoff--ask (plist-put drgnx-search-handoff--ask :hidden
                                             (not (plist-get drgnx-search-handoff--ask :hidden))))
  (drgnx-search-handoff--redraw)
  (drgnx-search-handoff--context))

(defun drgnx-search-handoff-cancel ()
  "Close the Ask an Agent card; nothing is sent."
  (interactive)
  (quit-window t))

;;;; Send, and the state that comes back

(defvar-local drgnx-search-handoff--live nil
  "In the Search view: the view's hand-offs, newest first, each (:handoff H :session S :name NAME :worktree W :ids
IDS :state STATE), STATE the last `search-handoff-state'.")

(defun drgnx-search-handoff--mark-of (ordinal)
  "The mark of the session with ORDINAL for the handed-off rows: (:face NAME :glyph G) from the agents' identity
scheme, or nil."
  (when-let* (((fboundp 'drgnx-agent-identity)) (ordinal) (id (drgnx-agent-identity ordinal)))
    (list :face (symbol-name (plist-get id :face)) :glyph (plist-get id :glyph))))

(defun drgnx-search-handoff--mark (session)
  "SESSION's mark for the handed-off rows, or nil before the session has its ordinal (its first snapshot)."
  (and (fboundp 'drgnx-agents-editor-ordinal)
       (drgnx-search-handoff--mark-of (drgnx-agents-editor-ordinal session))))

(defun drgnx-search-handoff-send ()
  "Send the Ask an Agent card: the hub builds the brief and starts or messages the agent."
  (interactive)
  (let* ((a drgnx-search-handoff--ask) (choice (nth (plist-get a :who) (plist-get a :choices)))
         (to (cdr choice)) (text (drgnx-search-handoff--instruction))
         (session (plist-get (plist-get to :session) :id))
         (mark (and session (drgnx-search-handoff--mark session)))
         (params (append (list :view (plist-get a :view) :instruction text :to to)
                         (if (plist-get a :ids) (list :ids (vconcat (plist-get a :ids)))
                           (list :off (vconcat (plist-get a :off))))
                         (and (plist-get a :hidden) (list :hidden t))
                         (and mark (list :mark mark)))))
    (when (string-empty-p text) (user-error "Say what the agent is to do"))
    (unless (cdr (drgnx-search-handoff--route (drgnx-search-handoff--profile-of to) (plist-get a :root)))
      (user-error "The project's routes (.drgnx/ai.eld) allow no provider for this agent: choose another"))
    (quit-window t)
    (with-current-buffer (drgnx-replace--live-view)
      (let ((view (current-buffer)))
        (drgnx-hub--call-on
         drgnx-hub--events "search/handoff" params
         (lambda (r err)
           (if err
               (message "Ask an Agent: %s" (or (plist-get err :message) err))
             (when (buffer-live-p view)
               (with-current-buffer view
                 (push (list :handoff (plist-get r :handoff) :session (plist-get r :session)
                             :name (cond ((plist-get to :new) "Worker") ((plist-get to :pair) "Pair")
                                         (t (replace-regexp-in-string " ([^)]*)\\'" "" (car choice))))
                             :worktree (plist-get r :worktree) :ids (append (plist-get r :ids) nil)
                             :state (list :phase "sent") :unmarked (not mark))
                       drgnx-search-handoff--live)
                 ;; a new worker has its ordinal by now when its first snapshot came before the answer
                 (drgnx-search-handoff--mark-later (plist-get r :session)
                                                   (and (fboundp 'drgnx-agents-editor-ordinal)
                                                        (drgnx-agents-editor-ordinal (plist-get r :session))))
                 (drgnx-replace--update-status)))
             (message "Asked %s about %d match%s%s%s" (car choice) (length (plist-get r :ids))
                      (if (= 1 (length (plist-get r :ids))) "" "es")
                      (if (> (or (plist-get r :more) 0) 0)
                          (format " (%d in the brief, the rest through search_results)" (plist-get r :sent)) "")
                      (if (plist-get r :hidden)
                          (format "; left out (hidden): %s" (string-join (append (plist-get r :hidden) nil) ", "))
                        "")))))))))

(defun drgnx-search-handoff--mark-later (session ordinal)
  "In the Search view: SESSION has ORDINAL (its snapshot came): its hand-offs sent without a mark (a new worker has
none before its first snapshot) get it now (`search/handoff-mark')."
  (when-let* ((mark (drgnx-search-handoff--mark-of ordinal)))
    (dolist (h drgnx-search-handoff--live)
      (when (and (plist-get h :unmarked) (equal (plist-get h :session) session))
        (setf (plist-get h :unmarked) nil)
        (drgnx-hub--call-on drgnx-hub--events "search/handoff-mark" (list :handoff (plist-get h :handoff) :mark mark)
                            #'ignore)))))

(defun drgnx-search-handoff-event (event data)
  "`search-handoff-state' (DATA) of EVENT: the Search view's chip follows it; an `agent' snapshot brings a new
worker's mark to its hand-off's rows.  Non-nil when it was a hand-off's state."
  (when-let* (((equal event "agent")) (ordinal (plist-get (plist-get data :session) :ordinal))
              (buf (get-buffer drgnx-replace-buffer-name)))
    (with-current-buffer buf (drgnx-search-handoff--mark-later (plist-get data :id) ordinal)))
  (when (equal event "search-handoff-state")
    (when-let* ((buf (get-buffer drgnx-replace-buffer-name)))
      (with-current-buffer buf
        (when-let* ((h (seq-find (lambda (h) (equal (plist-get h :handoff) (plist-get data :handoff)))
                                 drgnx-search-handoff--live)))
          (setf (plist-get h :state) data)
          (drgnx-replace--update-status))))
    t))

(defun drgnx-search-handoff-chip ()
  "The Search view's chip of its newest hand-off (`sent', `editing', `done 47 / 2 skipped'), or \"\"."
  (if-let* ((h (car drgnx-search-handoff--live)))
      (let* ((s (plist-get h :state)) (phase (format "%s" (plist-get s :phase)))
             (done (length (plist-get s :done))) (left (length (plist-get s :left)))
             (unknown (length (plist-get s :unknown))))
        (concat " · " (propertize (format " %s: %s " (plist-get h :name)
                                          (pcase phase
                                            ("done" (format "done %d / %d skipped%s" done left
                                                            (if (> unknown 0) (format " / %d unknown" unknown) "")))
                                            ("editing" (format "editing, %d done" done))
                                            (_ "sent")))
                                  'face 'drgnx-search-handoff-chip)))
    ""))

(defun drgnx-search-handoff-rerun ()
  "Run the Search view's search again in the worktree of its newest hand-off's worker, to show what is left."
  (interactive)
  (with-current-buffer (drgnx-replace--live-view)
    (let ((tree (cl-some (lambda (h) (plist-get h :worktree)) drgnx-search-handoff--live)))
      (unless tree (user-error "No hand-off to a worker in its own worktree"))
      (setq drgnx-replace--root (file-name-as-directory tree))
      (drgnx-replace--search-now))))

(provide 'drgnx-search-handoff)
;;; drgnx-search-handoff.el ends here
