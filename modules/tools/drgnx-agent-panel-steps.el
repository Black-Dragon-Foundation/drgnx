;;; drgnx-agent-panel-steps.el --- The agent panel's steps: clicks, disclosure, outputs, checkpoints (library of tools/agent-panel) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What the panel's rows do; the hub draws them (docs/develop/hub.md, "The agent panel's rows").  A click on the header,
;; the strip, a chip or a card runs the part's action (`drgnx-agent-panel-act'); the strip and the lens choose which
;; step types show their detail, which the hub hears (`agents/panel/look'); a large output is searched or opened range
;; by range; a step with a checkpoint is reverted or forked.  Loaded by tools/agent-panel (drgnx-agent-panel.el);
;; defines no module.  See docs/guide/agent-panel.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-setting)
(require 'drgnx-registry)
(require 'drgnx-ui-kit)                 ; the header's buttons

(defvar drgnx-agent-panel--session)
(defvar drgnx-agent-panel--snap)
(defvar drgnx-agent-panel--entries)
(defvar drgnx-agent-panel--steps)
(defvar drgnx-agent-panel--open)
(defvar drgnx-agent-panel--disclosure)      ; below: the header's lens reads them first
(defvar drgnx-agent-panel-presets)
(declare-function drgnx-agent-panel--key-at "drgnx-agent-panel")
(declare-function drgnx-agent-panel-chip "drgnx-agent-panel-explain")
(declare-function drgnx-agent-panel--send-look "drgnx-agent-panel")
(declare-function drgnx-agent-panel--entry "drgnx-agent-panel")
(declare-function drgnx-agent-panel--ask "drgnx-agent-panel")
(declare-function drgnx-agent-panel--type "drgnx-agent-panel")
(declare-function drgnx-agent-panel--one-line "drgnx-agent-panel")
(declare-function drgnx-history-revert-to-here "drgnx-history-revert")
(declare-function drgnx-history-fork-here "drgnx-history-revert")
(declare-function drgnx-agent-panel-ledger "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-accept "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-allow "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-always "drgnx-agent-panel-cards")
(declare-function drgnx-agent-panel-reject "drgnx-agent-panel-cards")
(declare-function drgnx-wb-area-window "drgnx-area" (area &optional frame))

(defface drgnx-agent-panel-lens '((t :inherit (drgnx-ui-caption drgnx-text-muted drgnx-surface-gap)
                                     :box (:line-width (2 . 8) :style flat-button)))
  "A preset of the header's lens that is not in force, on the lens's well (`.lens': the gap's colour)." :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-lens-on '((t :inherit (drgnx-ui-caption drgnx-control)))
  "The preset of the header's lens in force: raised (agent-panel.html `.lens span.on')." :group 'drgnx-agent-panel)

(defun drgnx-agent-panel--preset-in-force ()
  "The number (1 to 3) of the preset the chat's open step types are, or nil."
  (let ((open (sort (mapcar #'symbol-name drgnx-agent-panel--disclosure) #'string<)) (n 0))
    (seq-some (lambda (p) (cl-incf n)
                (and (equal open (sort (mapcar #'symbol-name (cdr p)) #'string<)) n))
              drgnx-agent-panel-presets)))

(defvar drgnx-agent-panel-header-menu
  '(("Fork the Chat" . agents-panel-fork) ("Compact the Context" . agents-panel-compact)
    ("Switch the Model" . agents-panel-model) ("Switch the Mode" . agents-panel-mode)
    ("List the Edits" . agents-panel-ledger) ("Stop the Agent" . agents-panel-stop))
  "The header's ⋯ menu: (LABEL . COMMAND), COMMAND a registry id.")

(defun drgnx-agent-panel-header-menu (event)
  "The header's ⋯ menu (`drgnx-agent-panel-header-menu') at EVENT; run the chosen command."
  (interactive "e")
  (when-let* ((choice (x-popup-menu event (list "Agent" (cons "" drgnx-agent-panel-header-menu)))))
    (drgnx-ui-kit-run choice)))

(defun drgnx-agent-panel--pin-from (window)
  "The pin button clicked in WINDOW: pin the step or card at the transcript's point.  In a companion (the header
window above the transcript) the transcript is its area's main window, whose point and buffer the pin reads."
  (let ((tw (if-let* (((window-parameter window 'drgnx-area-part)) (area (window-parameter window 'drgnx-role)))
                (drgnx-wb-area-window area (window-frame window))
              window)))
    (with-current-buffer (window-buffer tw)
      (save-excursion
        (goto-char (window-point tw))
        (drgnx-ui-kit-run 'agents-panel-pin)))))

(defun drgnx-agent-panel--prop-at (event prop)
  "Property PROP of the buffer text EVENT is on, or nil."
  (let* ((end (event-end event)) (pos (posn-point end)) (win (posn-window end)))
    (and pos (windowp win) (get-text-property pos prop (window-buffer win)))))

(defun drgnx-agent-panel-act (event)
  "Run the header, strip, chip or card part the click EVENT is on: the lens segment (`lens:N'), the pin or the ⋯ menu, a
step type's pill (`type:NAME') or `make default', the ledger or a card's button (`card:*'): the
`drgnx-agent-panel-action' of the text, which the hub's rows set; or the chip (`drgnx-agent-panel-chip')."
  (interactive "e")
  (let* ((end (event-end event)) (pos (posn-point end)) (win (posn-window end))
         (buf (and (windowp win) (window-buffer win))))
    (when (and pos buf)
      (let ((action (drgnx-agent-panel--prop-at event 'drgnx-agent-panel-action))
            (chip (drgnx-agent-panel--prop-at event 'drgnx-agent-panel-chip)))
        (with-current-buffer buf
          (cond ((and (stringp action) (string-prefix-p "lens:" action))
                 (drgnx-agent-panel-preset (string-to-number (substring action 5))))
                ((equal action "pin") (drgnx-agent-panel--pin-from win))
                ((equal action "more") (drgnx-agent-panel-header-menu event))
                ((and (stringp action) (string-prefix-p "type:" action))
                 (drgnx-agent-panel-toggle-type (intern (substring action 5))))
                ((equal action "default") (drgnx-agent-panel-make-default))
                ((equal action "card:ledger") (drgnx-agent-panel-ledger))
                ((and (stringp action) (string-prefix-p "card:" action))
                 ;; a card's button: the card's own commands read the card at point
                 (goto-char pos)
                 (pcase (nth 1 (split-string action ":"))
                   ("accept" (drgnx-agent-panel-accept))
                   ("allow" (drgnx-agent-panel-allow))
                   ("always" (drgnx-agent-panel-always))
                   ((or "reject" "deny") (drgnx-agent-panel-reject))))
                ((stringp chip) (drgnx-agent-panel-chip (intern chip)))))))))

;;;; Disclosure: which steps show their detail

(defconst drgnx-agent-panel-step-types '(thinking read search edit execute fetch other)
  "The step types the disclosure strip has a toggle for: a tool step's kind, and the agent's thinking.")

(defconst drgnx-agent-panel-presets
  '((watch) (review edit execute) (debug thinking read search edit execute fetch other))
  "The view presets on 1, 2 and 3: watch shows the steps' titles only, review opens edits and commands, debug opens all.")

(drgnx-defsetting drgnx-agent-panel-disclosure nil
  "The step types whose detail a new agent panel opens: thinking, read, search, edit, execute, fetch, other.
A failed step opens whatever this says.  `M' in a panel makes its current choice the default."
  :type '(set (const thinking) (const read) (const search) (const edit) (const execute) (const fetch) (const other))
  :group 'drgnx-agent-panel :scope 'global :agents 'never
  :schema '(list-of (enum thinking read search edit execute fetch other)))

(defvar-local drgnx-agent-panel--disclosure nil "The step types open in this chat.")
(defvar drgnx-agent-panel--defaults-unsaved nil "Non-nil while the default chosen with `M' is not yet in the settings file.")

(defun drgnx-agent-panel-steps-init ()
  "A new panel starts with the defaults."
  (setq drgnx-agent-panel--disclosure (copy-sequence drgnx-agent-panel-disclosure)))

(defun drgnx-agent-panel--step-type (e)
  (let ((k (and (stringp (plist-get e :kind)) (intern (plist-get e :kind)))))
    (if (memq k drgnx-agent-panel-step-types) k 'other)))

(defun drgnx-agent-panel--override (key) (and drgnx-agent-panel--open (gethash key drgnx-agent-panel--open)))

(defun drgnx-agent-panel--thinking-open-p (key)
  "Whether the thinking under the row KEY shows: your choice for the row, else the chat's toggle for thinking."
  (let ((o (drgnx-agent-panel--override key)))
    (if o (eq o 'open) (and (memq 'thinking drgnx-agent-panel--disclosure) t))))

(defun drgnx-agent-panel--detail-open-p (key e)
  "Whether the detail of tool entry E (row KEY) shows: your choice for the row, else it opens when the step failed,
else when the chat's toggle for its type is on."
  (let ((o (drgnx-agent-panel--override key)))
    (cond (o (eq o 'open))
          ((equal (plist-get e :status) "failed") t)
          (t (and (memq (drgnx-agent-panel--step-type e) drgnx-agent-panel--disclosure) t)))))

(defun drgnx-agent-panel--row-toggle (key)
  "Open or fold row KEY's detail and thinking, whatever the toggles say."
  (let* ((e (drgnx-agent-panel--entry (cadr key)))
         (now (or (drgnx-agent-panel--thinking-open-p key) (and e (drgnx-agent-panel--detail-open-p key e)))))
    (puthash key (if now 'closed 'open) drgnx-agent-panel--open)
    (drgnx-agent-panel--send-look)))

(defun drgnx-agent-panel--set-disclosure (types)
  "TYPES are the open step types of this chat; rows you opened or folded by hand are back under the toggles."
  (setq drgnx-agent-panel--disclosure (copy-sequence types))
  (clrhash drgnx-agent-panel--open)
  (drgnx-agent-panel--send-look))

(defun drgnx-agent-panel-toggle-type (type)
  "Open or close the detail of every step of TYPE in this chat."
  (interactive (list (intern (completing-read "Step type: " (mapcar #'symbol-name drgnx-agent-panel-step-types) nil t))))
  (drgnx-agent-panel--set-disclosure
   (if (memq type drgnx-agent-panel--disclosure) (remq type drgnx-agent-panel--disclosure)
     (cons type drgnx-agent-panel--disclosure))))

(defun drgnx-agent-panel-preset (n)
  "The view preset N: 1 watch, 2 review, 3 debug."
  (drgnx-agent-panel--set-disclosure (cdr (nth (1- n) drgnx-agent-panel-presets))))

(defun drgnx-agent-panel-preset-1 () "Watch: steps as titles only." (interactive) (drgnx-agent-panel-preset 1))
(defun drgnx-agent-panel-preset-2 () "Review: edits and commands open." (interactive) (drgnx-agent-panel-preset 2))
(defun drgnx-agent-panel-preset-3 () "Debug: everything open." (interactive) (drgnx-agent-panel-preset 3))

(declare-function drgnx-settings-editors-commit "drgnx-settings-editors")

(defun drgnx-agent-panel--save-defaults ()
  "Write the default to the user's settings file; nil (and the default stays unsaved) when that is refused."
  (require 'drgnx-settings-editors nil t)
  (when (fboundp 'drgnx-settings-editors-commit)
    (condition-case nil
        (progn (drgnx-settings-editors-commit 'drgnx-agent-panel-disclosure 'user nil drgnx-agent-panel-disclosure) t)
      (error nil))))

(defun drgnx-agent-panel-make-default ()
  "Make this chat's open step types the default for new panels, and save them in your settings."
  (interactive)
  (setq drgnx-agent-panel-disclosure (copy-sequence drgnx-agent-panel--disclosure))
  (setq drgnx-agent-panel--defaults-unsaved (not (drgnx-agent-panel--save-defaults)))
  (message "Agent panel: %s is now the default%s"
           (if drgnx-agent-panel-disclosure (mapconcat #'symbol-name drgnx-agent-panel-disclosure ", ") "titles only")
           (if drgnx-agent-panel--defaults-unsaved " (not saved: your settings file refused it)" "")))

(defface drgnx-agent-panel-tag '((t :inherit drgnx-pill))
  "A step type of the strip whose detail is closed." :group 'drgnx-agent-panel)
(defface drgnx-agent-panel-tag-on '((t :inherit drgnx-pill-on))
  "A step type of the strip whose detail is open (agent-panel.html `.disc .t.open')." :group 'drgnx-agent-panel)

(defun drgnx-agent-panel-steps-setup ()
  (drgnx-command-define 'agents-panel-toggle-type :category "Agents" :title "Open or Close a Step Type"
                        :command #'drgnx-agent-panel-toggle-type :map 'drgnx-agent-panel-mode-map
                        :doc "Show or hide the detail of every step of one type in this chat")
  (drgnx-command-define 'agents-panel-act :category "Agents" :title "Panel Header: Click"
                        :command #'drgnx-agent-panel-act :map 'drgnx-agent-panel-mode-map
                        :doc "A click on the header's lens, pin or ⋯, or on a chip: what that part does")
  (drgnx-command-define 'agents-panel-preset-1 :category "Agents" :title "Panel View: Watch"
                        :command #'drgnx-agent-panel-preset-1 :map 'drgnx-agent-panel-mode-map
                        :doc "Steps as titles only")
  (drgnx-command-define 'agents-panel-preset-2 :category "Agents" :title "Panel View: Review"
                        :command #'drgnx-agent-panel-preset-2 :map 'drgnx-agent-panel-mode-map
                        :doc "Edits and commands open")
  (drgnx-command-define 'agents-panel-preset-3 :category "Agents" :title "Panel View: Debug"
                        :command #'drgnx-agent-panel-preset-3 :map 'drgnx-agent-panel-mode-map
                        :doc "Every step open, thinking included")
  (drgnx-command-define 'agents-panel-make-default :category "Agents" :title "Make the Panel View the Default"
                        :command #'drgnx-agent-panel-make-default :map 'drgnx-agent-panel-mode-map
                        :doc "The step types open now are what new panels open")
  (drgnx-command-define 'agents-panel-revert-here :category "Agents" :title "Revert to the Step at Point"
                        :command #'drgnx-agent-panel-revert-here :map 'drgnx-agent-panel-mode-map
                        :doc "Open the revert card for the step at point")
  (drgnx-command-define 'agents-panel-fork-here :category "Agents" :title "Fork from the Step at Point"
                        :command #'drgnx-agent-panel-fork-here :map 'drgnx-agent-panel-mode-map
                        :doc "Start a second agent from the step at point")
  (drgnx-command-define 'agents-panel-output-search :category "Agents" :title "Search a Tool Output"
                        :command #'drgnx-agent-panel-output-search :map 'drgnx-agent-panel-mode-map
                        :doc "List the matching lines of the output of the step at point, paging through the hub")
  (drgnx-command-define 'agents-panel-output-open :category "Agents" :title "Open a Tool Output in a Buffer"
                        :command #'drgnx-agent-panel-output-open :map 'drgnx-agent-panel-mode-map
                        :doc "The output of the step at point in a read-only buffer that fills range by range")
  (drgnx-command-define 'agents-panel-output-more :category "Agents" :title "Load More of the Output"
                        :command #'drgnx-agent-panel-output-more :map 'drgnx-agent-panel-output-mode-map
                        :doc "Add the next range of the output to the buffer"))

(defun drgnx-agent-panel-steps-teardown ()
  "A default chosen with `M' that the settings file refused is tried once more before the module goes."
  (when drgnx-agent-panel--defaults-unsaved
    (setq drgnx-agent-panel--defaults-unsaved (not (drgnx-agent-panel--save-defaults)))))

;;;; Large outputs: head and tail here, the rest by range from the hub

(defconst drgnx-agent-panel-output-edge 10 "Lines of a large output shown at its head and at its tail.")
(defconst drgnx-agent-panel-output-page 262144 "Bytes asked of the hub for one range of an output (its own limit per answer).")
(defconst drgnx-agent-panel-output-max-hits 200 "Matching lines a search of an output lists.")

(defun drgnx-agent-panel--utf8-length (text) (length (encode-coding-string text 'utf-8)))

(defun drgnx-agent-panel--output-fetch (session tool from callback)
  "Ask the hub for the page of TOOL's output in SESSION that starts at byte FROM; CALLBACK gets (TEXT TOTAL ERROR)."
  (drgnx-agent-panel--ask
   "agents/tool-output" (list :id session :tool_call tool :from from :to (+ from drgnx-agent-panel-output-page))
   (lambda (r err) (funcall callback (and (not err) (or (plist-get r :text) "")) (and (not err) (plist-get r :total_bytes)) err))))

(defun drgnx-agent-panel--tool-at-point ()
  "The tool entry at point, or a user error."
  (let* ((key (drgnx-agent-panel--key-at))
         (e (and (eq (car-safe key) :e) (drgnx-agent-panel--entry (cadr key)))))
    (unless (and e (eq (drgnx-agent-panel--type e) 'tool) (plist-get e :id)) (user-error "Point is not on a tool step"))
    e))

(defvar-local drgnx-agent-panel-output--args nil "(SESSION TOOL) of the output this buffer shows.")
(defvar-local drgnx-agent-panel-output--next 0 "The first byte of the output not yet in this buffer.")
(defvar-local drgnx-agent-panel-output--total nil "The whole size of the output in bytes, once the hub has said.")
(defvar-local drgnx-agent-panel-output--loading nil)

(defun drgnx-agent-panel-output--header ()
  (setq header-line-format
        (format " %s of %s bytes%s" drgnx-agent-panel-output--next (or drgnx-agent-panel-output--total "?")
                (if (and drgnx-agent-panel-output--total (< drgnx-agent-panel-output--next drgnx-agent-panel-output--total))
                    " · n or scrolling to the end loads more" ""))))

(defun drgnx-agent-panel-output--scrolled (window _start)
  "WINDOW's end reached the end of the buffer: the next range is asked for."
  (with-current-buffer (window-buffer window)
    (when (>= (window-end window t) (point-max)) (drgnx-agent-panel-output-more))))

(define-derived-mode drgnx-agent-panel-output-mode special-mode "Output"
  "A tool's output, filled range by range."
  (buffer-disable-undo)
  (setq-local truncate-lines nil)
  (add-hook 'window-scroll-functions #'drgnx-agent-panel-output--scrolled nil t))

(defun drgnx-agent-panel-output-more ()
  "Add the next range of the output to this buffer, when the hub has more."
  (interactive)
  (when (and drgnx-agent-panel-output--args (not drgnx-agent-panel-output--loading)
             (or (null drgnx-agent-panel-output--total) (< drgnx-agent-panel-output--next drgnx-agent-panel-output--total)))
    (let ((buf (current-buffer)) (from drgnx-agent-panel-output--next))
      (setq drgnx-agent-panel-output--loading t)
      (drgnx-agent-panel--output-fetch
       (car drgnx-agent-panel-output--args) (cadr drgnx-agent-panel-output--args) from
       (lambda (text total err)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (setq drgnx-agent-panel-output--loading nil)
             (if err (message "Output: %s" err)
               (let ((inhibit-read-only t))
                 (save-excursion (goto-char (point-max)) (insert text)))
               (setq drgnx-agent-panel-output--total total
                     drgnx-agent-panel-output--next (if (string-empty-p text) (or total from)
                                                      (+ from (drgnx-agent-panel--utf8-length text))))
               (drgnx-agent-panel-output--header)))))))))

(defun drgnx-agent-panel-output-open ()
  "Open the output of the tool step at point in a read-only buffer, which fills range by range."
  (interactive)
  (let* ((e (drgnx-agent-panel--tool-at-point)) (session drgnx-agent-panel--session)
         (buf (generate-new-buffer (format "*drgnx output: %s*" (drgnx-agent-panel--one-line (or (plist-get e :title) "tool") 40)))))
    (with-current-buffer buf
      (drgnx-agent-panel-output-mode)
      (setq drgnx-agent-panel-output--args (list session (plist-get e :id))
            drgnx-agent-panel-output--next 0 drgnx-agent-panel-output--total nil drgnx-agent-panel-output--loading nil)
      (drgnx-agent-panel-output--header)
      (drgnx-agent-panel-output-more))
    (pop-to-buffer buf)
    buf))

(defun drgnx-agent-panel-output-search (regexp)
  "List the lines of the output of the tool step at point that match REGEXP, paging through the hub."
  (interactive (list (read-regexp "Search the output for: ")))
  (let* ((e (drgnx-agent-panel--tool-at-point)) (session drgnx-agent-panel--session) (tool (plist-get e :id))
         (out (generate-new-buffer (format "*drgnx output search: %s*" regexp))) (hits nil) (count 0))
    (cl-labels
        ((finish (note)
           (with-current-buffer out
             (drgnx-agent-panel-output-mode)
             (let ((inhibit-read-only t))
               (dolist (h (nreverse hits)) (insert (format "%d: %s\n" (car h) (cdr h))))
               (insert note "\n")
               (goto-char (point-min))))
           (pop-to-buffer out))
         (scan (data at)
           ;; the complete lines of DATA, which starts at byte AT, that match; returns the byte after the last one
           (let ((off at))
             (dolist (l (split-string data "\n"))
               (when (and (< count drgnx-agent-panel-output-max-hits) (string-match-p regexp l))
                 (push (cons off l) hits) (cl-incf count))
               (cl-incf off (1+ (drgnx-agent-panel--utf8-length l))))
             off))
         (step (from carry carry-at)
           (drgnx-agent-panel--output-fetch
            session tool from
            (lambda (text total err)
              (if err (finish (format "Search stopped: %s" err))
                (let* ((data (concat carry text)) (cut (string-match "[^\n]*\\'" data))
                       (head (substring data 0 cut)) (tail (substring data cut))
                       (next (+ from (drgnx-agent-panel--utf8-length text)))
                       (off (scan head carry-at))
                       (done (or (string-empty-p text) (and total (>= next total)))))
                  (cond ((>= count drgnx-agent-panel-output-max-hits)
                         (finish (format "Stopped at %d matches." count)))
                        (done (scan tail off) (finish (format "%d matches." count)))
                        (t (step next tail off)))))))))
      (step 0 "" 0))))

;;;; Checkpoints: revert and fork at a step

(defun drgnx-agent-panel--step-row (e)
  "The hub's timeline row of the step that entry E names, or nil."
  (when-let* ((seq (plist-get e :step))) (gethash seq drgnx-agent-panel--steps)))

(defun drgnx-agent-panel--step-at-point ()
  "The timeline row of the step at point, or a user error."
  (let* ((key (drgnx-agent-panel--key-at))
         (e (and (eq (car-safe key) :e) (drgnx-agent-panel--entry (cadr key))))
         (step (and e (drgnx-agent-panel--step-row e))))
    (unless step (user-error "Point is not on a step"))
    step))

(defun drgnx-agent-panel-revert-here ()
  "Open the revert card for the step at point (the edit history's revert; nothing changes until its Apply)."
  (interactive)
  (let ((step (drgnx-agent-panel--step-at-point)))
    (unless (eq (plist-get step :revertible) t) (user-error "This step has no checkpoint to go back to"))
    (require 'drgnx-history-revert)
    (drgnx-history-revert-to-here drgnx-agent-panel--session (plist-get step :seq))))

(defun drgnx-agent-panel-fork-here ()
  "Start a second agent from the step at point; the prompt says what one more run like this costs."
  (interactive)
  (let ((step (drgnx-agent-panel--step-at-point)))
    (require 'drgnx-history-revert)
    (drgnx-history-fork-here drgnx-agent-panel--session (plist-get step :seq))))


(provide 'drgnx-agent-panel-steps)
;;; drgnx-agent-panel-steps.el ends here
