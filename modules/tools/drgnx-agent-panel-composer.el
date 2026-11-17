;;; drgnx-agent-panel-composer.el --- The agent panel's composer and steering queue (library of tools/agent-panel) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Under the transcript: the steering queue (the notes waiting for the turn to end, each editable until it is sent),
;; and the composer, an input buffer of its own (`drgnx-agent-panel--composer-of'): the message you write at its start,
;; and under it a read-only bar of chips and buttons.  `s' in the panel puts point in it; RET sends (a message sent
;; while the agent works is queued, never a cancel), S-RET breaks the line.  `x' stops the agent (after a confirmation
;; line), `p' stops it after its current step, `u' resumes it.  `@file' and `/command' complete in the composer from the
;; session's folder and the snapshot's commands.  The Pair chip shows the snapshot's `paired' and `waiting' and runs
;; `agents-pair' when that command exists; else it is not there.
;; The composer works on the panel's state through the state twin (`drgnx-agent-panel--companion-sync'), which the
;; header uses too.
;; Loaded by tools/agent-panel (drgnx-agent-panel.el); defines no module.  See docs/guide/agent-panel.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-registry)
(require 'drgnx-ui-kit)                 ; the bar's buttons
(require 'drgnx-pixels)
(require 'drgnx-state)                  ; which frame shows the composer (the store's windows)
(require 'drgnx-icons)
(require 'drgnx-modal)                  ; the composer starts in insert state

(defvar drgnx-view-patch-twin-of)
(declare-function drgnx-view-env--twin-copy "drgnx-view-env" (from prefixes))
(declare-function drgnx-wb-area-fit-companions "drgnx-area" (area &optional frame))

(defvar drgnx-agent-panel--session)
(defvar drgnx-agent-panel--snap)
(defvar drgnx-agent-panel-mode-map)
(defvar drgnx-work-resume-text)
(declare-function drgnx-agent-panel--ask "drgnx-agent-panel")
(declare-function drgnx-agent-panel--one-line "drgnx-agent-panel")
(declare-function drgnx-history-fork-here "drgnx-history-revert")
(defvar drgnx-agent-panel--steps)

;;;; Context: what the next message is about, as removable items

(defvar-local drgnx-agent-panel--context nil
  "What the next message is about, a list of removable items: (:file PATH), (:file PATH :lines (A . B)) or
\(:item (KIND . ID)).  Send turns each into an `@' reference in the text and clears the list.")

(defun drgnx-agent-panel-context-add (item)
  "Add the context ITEM to this composer's list, once."
  (unless (member item drgnx-agent-panel--context)
    (setq drgnx-agent-panel--context (append drgnx-agent-panel--context (list item))))
  drgnx-agent-panel--context)

(defun drgnx-agent-panel-context-remove (item)
  "Take the context ITEM out of this composer's list."
  (setq drgnx-agent-panel--context (delete item drgnx-agent-panel--context)))

(defun drgnx-agent-panel-context-ref (item)
  "ITEM as the `@' reference the text carries: `@path', `@path:A-B' or `@KIND:ID'."
  (cond ((plist-get item :item)
         (let ((it (plist-get item :item))) (format "@%s:%s" (car it) (cdr it))))
        ((plist-get item :lines)
         (let ((l (plist-get item :lines)))
           (format "@%s:%d-%d" (plist-get item :file) (car l) (cdr l))))
        (t (format "@%s" (plist-get item :file)))))

(defun drgnx-agent-panel-with-context (text)
  "TEXT followed by the `@' references of this buffer's context items; the list is cleared."
  (let ((refs (mapcar #'drgnx-agent-panel-context-ref drgnx-agent-panel--context)))
    (setq drgnx-agent-panel--context nil)
    (if refs (concat text (unless (string-empty-p text) " ") (mapconcat #'identity refs " ")) text)))

(defconst drgnx-agent-panel-composer-max-files 2000 "How many files `@' completion looks through at most.")

(defun drgnx-agent-panel-composer--queue ()
  "The notes waiting in the snapshot, a list of strings."
  (append (plist-get drgnx-agent-panel--snap :queue) nil))

;;;; Rows

(defun drgnx-agent-panel-composer--pair-chip ()
  "The Pair chip, or nil when `agents-pair' is not a command."
  (when (drgnx-commands-get 'agents-pair)
    (let ((paired (plist-get drgnx-agent-panel--snap :paired)) (waiting (plist-get drgnx-agent-panel--snap :waiting)))
      (propertize (format " Pair%s " (cond ((and waiting (not (eq waiting :json-false))) " · waiting for you")
                                           ((and paired (not (eq paired :json-false))) " · on")
                                           (t "")))
                  'face 'drgnx-agent-panel-chip))))

(defun drgnx-agent-panel-composer--click (text command face &optional help)
  "TEXT in FACE (nil: its own faces) that runs COMMAND (a registry command) when clicked."
  (let ((map (make-sparse-keymap)) (s (copy-sequence text)))
    (define-key map [mouse-1] command)
    (when face (add-face-text-property 0 (length s) face nil s))
    (add-text-properties 0 (length s) (list 'mouse-face 'drgnx-hover 'keymap map 'help-echo help) s)
    s))

(defun drgnx-agent-panel-fork ()
  "Start a second agent from the chat's last step: the composer's Fork (Fork from the Step at Point picks another)."
  (interactive)
  (let ((seq (and (hash-table-p drgnx-agent-panel--steps)
                  (car (sort (hash-table-keys drgnx-agent-panel--steps) #'>)))))
    (unless seq (user-error "The chat has no step to fork from yet"))
    (require 'drgnx-history-revert)
    (drgnx-history-fork-here drgnx-agent-panel--session seq)))

(defun drgnx-agent-panel-composer--frame ()
  "The frame this composer is drawn in, from the workbench state store (`drgnx-state-frames', `drgnx-state-windows'):
the selected frame when a window of it shows the buffer, else the first recorded frame that does; the selected frame
when none does.  Its pads and its buttons' widths are that frame's pixels, whichever frame is selected."
  (let ((buffer (current-buffer)) (selected (selected-frame)))
    (cl-flet ((shows (f) (seq-some (lambda (w) (eq (window-buffer w) buffer)) (drgnx-state-windows f))))
      (cond ((shows selected) selected)
            (t (or (seq-find #'shows (drgnx-state-frames)) selected))))))

(defun drgnx-agent-panel-composer--pad (&optional frame)
  "The composer bar's right pad (20 logical pixels) in the pixels of FRAME, default the frame it is drawn in."
  (drgnx-px 20 (or frame (drgnx-agent-panel-composer--frame))))

(defun drgnx-agent-panel-composer--bar ()
  "The composer's bar (agent-panel.html `.composer'): the model and the mode as chips that switch them, Pair when it is
a command, then Fork, the pause icon (stop after this step) and Send, an arrow, as buttons.  It has no newline.  It is
built with the frame it is drawn in selected, so its icons, its buttons' widths and its pad are that frame's pixels
whichever frame is selected when the panel updates."
  (let ((buffer (current-buffer)) (frame (drgnx-agent-panel-composer--frame)))
    (with-selected-frame frame
      (with-current-buffer buffer (drgnx-agent-panel-composer--bar-in frame)))))

(defun drgnx-agent-panel-composer--bar-in (frame)
  "`drgnx-agent-panel-composer--bar''s text, built with FRAME selected."
  (let* ((snap drgnx-agent-panel--snap) (model (plist-get snap :model)) (mode (plist-get snap :mode))
         (pair (drgnx-agent-panel-composer--pair-chip))
         (buttons (concat (drgnx-agent-panel-composer--click (concat " " (drgnx-look-icon 'git-fork) " Fork ")
                                                             #'drgnx-agent-panel-fork 'drgnx-ui-button
                                                             "Start a second agent from the chat's last step")
                          " "
                          (drgnx-agent-panel-composer--click (concat " " (drgnx-look-icon 'pause) " ") #'drgnx-agent-panel-pause
                                                             'drgnx-ui-button "p: stop the agent after its current step")
                          " "
                          (drgnx-agent-panel-composer--click (concat " " (drgnx-look-icon 'arrow-up) " ")
                                                             #'drgnx-agent-panel-send 'drgnx-ui-button-primary
                                                             "RET: send to the agent; while it works it is queued"))))
    (concat (if (stringp model)
                (concat (drgnx-agent-panel-composer--click (concat " " (drgnx-look-icon 'sparkle) " " model " ")
                                                           #'drgnx-agent-panel-switch-model
                                                           'drgnx-agent-panel-chip "Switch the model")
                        " ")
              "")
            (if mode
                (concat (drgnx-agent-panel-composer--click (format " %s ▾ " mode) #'drgnx-agent-panel-switch-mode
                                                           'drgnx-agent-panel-chip "Switch the mode")
                        " ")
              "")
            (if pair (concat (drgnx-agent-panel-composer--click pair #'drgnx-agent-panel-pair nil "C: pair with the agent") " ")
              "")
            (propertize " " 'display `(space :align-to (- right (,(+ (string-pixel-width buttons)
                                                                     (drgnx-agent-panel-composer--pad frame))))))
            buttons)))

;;;; Completion in the composer

(defun drgnx-agent-panel-composer--command-names ()
  (delq nil (mapcar (lambda (c) (cond ((stringp c) c) ((consp c) (let ((n (plist-get c :name))) (and (stringp n) n)))))
                    (append (plist-get drgnx-agent-panel--snap :commands) nil))))

(defun drgnx-agent-panel-composer--files (dir)
  "Files under DIR, relative, at most `drgnx-agent-panel-composer-max-files', without dot folders."
  (when (and (stringp dir) (file-directory-p dir) (not (file-remote-p dir)))
    (let ((n 0) out)
      (catch 'done
        (dolist (f (directory-files-recursively dir "" nil (lambda (d) (not (string-prefix-p "." (file-name-nondirectory d))))))
          (unless (string-prefix-p "." (file-name-nondirectory f))
            (push (file-relative-name f dir) out)
            (when (> (cl-incf n) drgnx-agent-panel-composer-max-files) (throw 'done nil)))))
      (nreverse out))))

(defun drgnx-agent-panel-composer--capf (names files)
  "A completion-at-point function: `/' completes NAMES at the start of the text, `@' completes FILES anywhere."
  (lambda ()
    (let ((end (point)) (beg (save-excursion (skip-chars-backward "^ \t\n") (point))))
      (cond ((and (< beg end) (eq (char-after beg) ?@))
             (list (1+ beg) end files :exclusive 'no))
            ((and (< beg end) (eq (char-after beg) ?/) (= beg (minibuffer-prompt-end)))
             (list (1+ beg) end names :exclusive 'no))))))

(defun drgnx-agent-panel-composer--complete ()
  "`completion-at-point-functions' of the composer: `--capf' over the session's commands and, for an `@' word, the
files of its folder (looked through only then)."
  (let ((beg (save-excursion (skip-chars-backward "^ \t\n") (point))))
    (when (memq (char-after beg) '(?@ ?/))
      (funcall (drgnx-agent-panel-composer--capf
                (drgnx-agent-panel-composer--command-names)
                (and (eq (char-after beg) ?@) (drgnx-agent-panel-composer--files (plist-get drgnx-agent-panel--snap :cwd))))))))

;;;; The state twin: a companion buffer works on its panel's state

;; The header and the composer are buffers of their own beside the panel's (the transcript's), which owns the state.
;; Before each command in a companion the panel's `drgnx-agent-panel-' locals are copied in; after it, the ones the
;; command changed go back.  The companion's own locals are named `drgnx-agent-companion-', so they never travel.

(defvar-local drgnx-agent-companion--main nil "In a companion (the header, the composer): the panel's buffer.")
(defvar-local drgnx-agent-companion--taken nil "In a companion: the state as copied in, ((SYMBOL . VALUE)...).")
(defvar-local drgnx-agent-companion--composer nil "In a panel's buffer: its composer, once made.")

(defun drgnx-agent-panel--companion-state ()
  "The current buffer's `drgnx-agent-panel-' locals that travel between a panel and its companions: ((SYMBOL . VALUE)
...), as `drgnx-view-env--twin-copy' copies them (no marker or overlay: those point into their own buffer)."
  (let (out)
    (dolist (b (buffer-local-variables))
      (let ((sym (car-safe b)) (v (cdr-safe b)))
        (when (and sym (symbolp sym) (string-prefix-p "drgnx-agent-panel-" (symbol-name sym))
                   (not (or (markerp v) (overlayp v) (and (consp v) (or (markerp (car v)) (overlayp (car v)))))))
          (push (cons sym v) out))))
    out))

(defun drgnx-agent-panel--companion-take ()
  "`pre-command-hook' of a companion: the panel's state as it is now."
  (when (buffer-live-p drgnx-agent-companion--main)
    (drgnx-view-env--twin-copy drgnx-agent-companion--main '("drgnx-agent-panel-"))
    (setq drgnx-agent-companion--taken (drgnx-agent-panel--companion-state))))

(defun drgnx-agent-panel--companion-give ()
  "`post-command-hook' of a companion: what the command changed of the state goes back to the panel (only that: a
snapshot the panel took meanwhile is not overwritten by the older copy)."
  (when (buffer-live-p drgnx-agent-companion--main)
    (drgnx-agent-panel--give-changed drgnx-agent-companion--main)))

(defun drgnx-agent-panel--give-changed (main)
  "Give MAIN, the panel's buffer, the current buffer's state the command changed since it was taken
\(`drgnx-agent-companion--taken'): only that, so a value the command set on MAIN itself, or a snapshot MAIN took
meanwhile, is not overwritten by the older copy.  A companion's and a display-class twin's hand-back."
  (let (changed)
    (dolist (c (drgnx-agent-panel--companion-state))
      (unless (let ((was (assq (car c) drgnx-agent-companion--taken))) (and was (eq (cdr was) (cdr c))))
        (push c changed)))
    (setq drgnx-agent-companion--taken (drgnx-agent-panel--companion-state))
    (when changed
      (with-current-buffer main
        (dolist (c changed) (set (make-local-variable (car c)) (cdr c)))))))

(defun drgnx-agent-panel--companion-sync (main)
  "Make the current buffer a companion of MAIN, a panel's buffer: it works on MAIN's state, copied in before each
command and given back after it.  The state is copied in at once."
  (require 'drgnx-view-env)
  (setq drgnx-agent-companion--main main)
  (drgnx-agent-panel--companion-take)
  (add-hook 'pre-command-hook #'drgnx-agent-panel--companion-take nil t)
  (add-hook 'post-command-hook #'drgnx-agent-panel--companion-give nil t))

(defun drgnx-agent-panel--main-of (buffer)
  "The panel's buffer of BUFFER: BUFFER itself for a panel, the panel a companion or a display class's twin belongs
to, or nil."
  (with-current-buffer buffer
    (cond ((buffer-live-p drgnx-agent-companion--main) drgnx-agent-companion--main)
          ((and (boundp 'drgnx-view-patch-twin-of) (buffer-live-p drgnx-view-patch-twin-of)) drgnx-view-patch-twin-of)
          ((derived-mode-p 'drgnx-agent-panel-mode) buffer))))

;;;; The composer buffer

(defconst drgnx-agent-panel-composer-placeholder "Steer the agent… (@ file, / command)"
  "What an empty composer shows.")

(defvar drgnx-agent-panel-composer-mode-map (make-sparse-keymap)
  "Keys of the composer.  The key profiles bind them (`drgnx-command-define' with this map).")

(defvar-local drgnx-agent-companion--placeholder nil "The composer's placeholder overlay.")
(defvar-local drgnx-agent-companion--fit-heights nil
  "In the composer: its text's pixel height in each area window that showed it when they were last fitted, an alist
\((WINDOW . PX)...); only the windows that show it now are kept.")

(defvar drgnx-agent-panel-composer--button-map
  (let ((m (make-sparse-keymap))) (define-key m [mouse-1] #'drgnx-agent-panel-composer--clicked) m)
  "The keymap of the composer bar's buttons: a click runs the button's `drgnx-agent-composer-command'.")

(define-derived-mode drgnx-agent-panel-composer-mode text-mode "Agent composer"
  "The agent panel's composer: the message you write to the agent, and under it the bar of its chips and buttons."
  (setq-local truncate-lines nil word-wrap t require-final-newline nil)
  (face-remap-add-relative 'default 'drgnx-ui-text)
  ;; only `@file' and `/command': text-mode's word completion wants a dictionary and knows neither
  (setq-local completion-at-point-functions (list #'drgnx-agent-panel-composer--complete))
  (add-hook 'after-change-functions #'drgnx-agent-panel-composer--changed nil t))

(defun drgnx-agent-panel-composer--field-end ()
  "Where the composer's field ends: the bar's start (the field's text carries no `field' property)."
  (if (eq (get-text-property (point-min) 'field) 'drgnx-agent-composer-bar) (point-min)
    (or (next-single-property-change (point-min) 'field) (point-max))))

(defun drgnx-agent-panel-composer--field-text ()
  "The message in the composer's field."
  (buffer-substring-no-properties (point-min) (drgnx-agent-panel-composer--field-end)))

(defun drgnx-agent-panel-composer--placehold ()
  "The placeholder shows while the field is empty."
  (overlay-put drgnx-agent-companion--placeholder 'before-string
               (and (eq (get-text-property (point-min) 'field) 'drgnx-agent-composer-bar)   ; an empty field
                    (let ((s (propertize drgnx-agent-panel-composer-placeholder 'face 'drgnx-agent-panel-subtle)))
                      (put-text-property 0 1 'cursor t s)    ; the cursor at its start, not after it
                      s))))

(defun drgnx-agent-panel-composer--refit ()
  "The composer's text changed: each area window that shows it below a panel, whose text height is not the one it was
last fitted to (a line more or less, a wrap, a chip), is fitted again; a keystroke that changes no height fits nothing."
  (let (heights)
    (dolist (w (get-buffer-window-list (current-buffer) nil t))
      (when-let* (((window-parameter w 'drgnx-area-part)) (area (window-parameter w 'drgnx-role)))
        (let ((h (cdr (window-text-pixel-size w (point-min) (point-max)))))
          (push (cons w h) heights)
          (unless (eql h (alist-get w drgnx-agent-companion--fit-heights))
            (drgnx-wb-area-fit-companions area (window-frame w))))))
    (setq drgnx-agent-companion--fit-heights heights)))

(defun drgnx-agent-panel-composer--changed (&rest _)
  "`after-change-functions' of the composer: the placeholder, and the window's fit."
  (when (overlayp drgnx-agent-companion--placeholder) (drgnx-agent-panel-composer--placehold))
  (drgnx-agent-panel-composer--refit))

(defun drgnx-agent-panel-composer--draw-bar ()
  "Draw the composer's bar again from the panel's state, after the field.  The bar is read-only, takes no typing at
its end, and is a field of its own (line moves stop at it); typing at the field's end, right before it, works."
  (let ((inhibit-read-only t) (buffer-undo-list t) (inhibit-modification-hooks t)
        (bar (concat "\n" (drgnx-agent-panel-composer--bar))) (i 0))
    ;; each button's click runs its command through `--clicked', in this composer on the session's state
    (while (< i (length bar))
      (let ((next (next-single-property-change i 'keymap bar (length bar))) (map (get-text-property i 'keymap bar)))
        (when (keymapp map)
          (add-text-properties i next (list 'drgnx-agent-composer-command (lookup-key map [mouse-1])
                                            'keymap drgnx-agent-panel-composer--button-map)
                               bar))
        (setq i next)))
    (add-text-properties 0 (length bar) (list 'read-only t 'field 'drgnx-agent-composer-bar) bar)
    (save-excursion
      (delete-region (drgnx-agent-panel-composer--field-end) (point-max))
      (goto-char (point-max))
      (insert bar)))
  (drgnx-agent-panel-composer--refit))   ; a chip more or less may wrap the bar

(defun drgnx-agent-panel-composer-redraw ()
  "The snapshot changed: the composer's bar is drawn again."
  (when-let* ((c drgnx-agent-companion--composer) ((buffer-live-p c)))
    (with-current-buffer c
      (drgnx-agent-panel--companion-take)
      (drgnx-agent-panel-composer--draw-bar))))

(defun drgnx-agent-panel-composer--main-killed ()
  "`kill-buffer-hook' of a panel's buffer: its composer goes with it."
  (when (buffer-live-p drgnx-agent-companion--composer) (kill-buffer drgnx-agent-companion--composer)))

(defun drgnx-agent-panel--composer-of (buffer)
  "The composer of BUFFER's panel (BUFFER a panel, a companion or a twin), made when there is none; nil when BUFFER
belongs to no panel.  What the area shows under the transcript."
  (when-let* ((main (drgnx-agent-panel--main-of buffer)))
    (with-current-buffer main
      (if (buffer-live-p drgnx-agent-companion--composer) drgnx-agent-companion--composer
        (let ((c (get-buffer-create (format "%s composer" (buffer-name main)))))
          (setq drgnx-agent-companion--composer c)
          (add-hook 'kill-buffer-hook #'drgnx-agent-panel-composer--main-killed nil t)
          (with-current-buffer c
            (drgnx-agent-panel-composer-mode)
            (drgnx-agent-panel--companion-sync main)
            (setq drgnx-agent-companion--placeholder (make-overlay (point-min) (point-min)))
            (drgnx-agent-panel-composer--draw-bar)
            (drgnx-agent-panel-composer--placehold)
            (goto-char (point-min)))
          c)))))

(defun drgnx-agent-panel-composer--clicked (event)
  "A click on a button of the composer's bar: its command, in the composer clicked, on the session's state (the click
comes whatever buffer is current)."
  (interactive "e")
  (let* ((posn (event-start event)) (w (posn-window posn)) (pos (posn-point posn)))
    (with-current-buffer (window-buffer w)
      (when-let* ((cmd (and (integer-or-marker-p pos) (get-text-property pos 'drgnx-agent-composer-command))))
        (drgnx-agent-panel--companion-take)
        (unwind-protect (call-interactively cmd)
          (drgnx-agent-panel--companion-give))))))

;;;; Commands

(defun drgnx-agent-panel-composer--send-text (text)
  "Send TEXT to the session: the hub queues it while the agent works.  Never a cancel.  The context items go in as
`@' references."
  (setq text (drgnx-agent-panel-with-context text))
  (when (equal (format "%s" (plist-get drgnx-agent-panel--snap :mode)) "interrupt")
    (user-error "This agent's mode would cancel its turn for a message; change its mode first"))
  (let ((busy (equal (format "%s" (plist-get drgnx-agent-panel--snap :status)) "busy")))
    (drgnx-agent-panel--ask "agents/send" (list :id drgnx-agent-panel--session :text text))
    (message (if busy "Agent: queued, it goes in after the current turn" "Agent: sent"))))

(defun drgnx-agent-panel-send ()
  "Send the composer's message to the agent and empty the field.  While it works the message is queued; it is not
cancelled.  An empty field sends nothing.  From the panel or its header it sends the composer's draft too."
  (interactive)
  (when-let* ((c (drgnx-agent-panel--composer-of (current-buffer))))
    (with-current-buffer c
      (drgnx-agent-panel--companion-take)   ; the state as it is now, from wherever the command ran
      (let ((text (string-trim (drgnx-agent-panel-composer--field-text))))
        (unless (string-empty-p text)
          (drgnx-agent-panel-composer--send-text text)
          (delete-region (point-min) (drgnx-agent-panel-composer--field-end)))))))

(defun drgnx-agent-panel-composer-newline ()
  "Break the line in the composer's message; nothing is sent."
  (interactive)
  (insert "\n"))

(defun drgnx-agent-panel-compose ()
  "Write to the agent: point goes to the end of the composer's message, in the window under the panel."
  (interactive)
  (let* ((c (or (drgnx-agent-panel--composer-of (current-buffer)) (user-error "Not in an agent panel")))
         (w (or (get-buffer-window c) (display-buffer c '(display-buffer-below-selected)))))
    (select-window w)
    (goto-char (drgnx-agent-panel-composer--field-end))))

(defun drgnx-agent-panel-composer-back ()
  "Back from the composer to its panel's transcript."
  (interactive)
  (when-let* ((main (drgnx-agent-panel--main-of (current-buffer)))
              (w (or (get-buffer-window main)
                     (seq-find (lambda (w) (eq main (drgnx-agent-panel--main-of (window-buffer w))))
                               (delq (selected-window) (window-list))))))
    (select-window w)))

(defun drgnx-agent-panel-stop ()
  "Stop the agent, after a confirmation line: its turn ends after its current step."
  (interactive)
  (when (y-or-n-p "Stop the agent? Its turn stops after the current step ")
    (drgnx-agent-panel--ask "agents/stop" (list :id drgnx-agent-panel--session))))

(defun drgnx-agent-panel-pause ()
  "Stop the agent after its current step and hold its queue; `u' resumes."
  (interactive)
  (drgnx-agent-panel--ask "agents/pause" (list :id drgnx-agent-panel--session))
  (message "Agent: stops after its current step · u resume"))

(defun drgnx-agent-panel-resume ()
  "Resume the agent with a plain continue prompt."
  (interactive)
  (drgnx-agent-panel--ask "agents/send"
                          (list :id drgnx-agent-panel--session
                                :text (if (boundp 'drgnx-work-resume-text) drgnx-work-resume-text "Please continue.")))
  (message "Agent: resumed"))

(defun drgnx-agent-panel-composer--queue-index ()
  "The number of the queued note at point (a hub row carries it as `drgnx-agent-panel-queued')."
  (let ((n (get-text-property (point) 'drgnx-agent-panel-queued)))
    (unless (integerp n) (user-error "Point is not on a queued note"))
    n))

(defun drgnx-agent-panel-edit-queued ()
  "Edit the queued note at point, until it is sent."
  (interactive)
  (let* ((n (drgnx-agent-panel-composer--queue-index))
         (text (read-string "Queued note: " (nth n (drgnx-agent-panel-composer--queue)))))
    (drgnx-agent-panel--ask "agents/do" (list :id drgnx-agent-panel--session :op "requeue" :n n :text text))))

(defun drgnx-agent-panel-drop-queued ()
  "Take the queued note at point out of the queue."
  (interactive)
  (drgnx-agent-panel--ask "agents/do" (list :id drgnx-agent-panel--session :op "unqueue"
                                            :n (drgnx-agent-panel-composer--queue-index))))

(defun drgnx-agent-panel-pair ()
  "Pair mode for this agent: runs `agents-pair'."
  (interactive)
  (if-let* ((cmd (drgnx-commands-get 'agents-pair)))
      (call-interactively (drgnx-cmd-command cmd))
    (user-error "Pair mode is not available")))

;;;; Session control: start, move, compact, mode and model

(declare-function drgnx-agent-panel-open "drgnx-agent-panel")
(declare-function drgnx-agents-profile-names "drgnx-agents")
(declare-function drgnx-agent-panel-explain--fresh "drgnx-agent-panel-explain")
(declare-function drgnx-agents-hooks--preview-text "drgnx-agents-hooks")

(defun drgnx-agent-panel--say (method)
  "A callback that says how METHOD went."
  (lambda (_r err) (message "%s" (if err (format "%s: %s" method err) (format "%s: done" method)))))

(defun drgnx-agent-panel--fact (facts name)
  (plist-get (seq-find (lambda (f) (equal (plist-get f :name) name)) (append facts nil)) :value))

(defun drgnx-agent-panel--offer-modes (buffer facts)
  "Offer the modes FACTS (the hub's `agents/explain' for mode) allow switching to, and switch to the one you choose.
When the lock allows none, say why (the hub's reason)."
  (let* ((allowed (drgnx-agent-panel--fact facts "allowed switches"))
         (modes (unless (member allowed '(nil "none")) (split-string allowed ", " t))))
    (unless modes
      (user-error "No mode switch is allowed here: %s"
                  (or (drgnx-agent-panel--fact facts "other modes are refused because") "this agent's lock allows none")))
    (let ((mode (completing-read "Switch mode to: " modes nil t)))
      (with-current-buffer buffer
        (drgnx-agent-panel--ask "agents/config" (list :id drgnx-agent-panel--session :option "mode" :value mode)
                                (drgnx-agent-panel--say "agents/config"))))))

(defun drgnx-agent-panel-switch-mode ()
  "Switch the agent's mode, to one its lock allows (the hub says which, and why the others are not offered)."
  (interactive)
  (let ((buffer (current-buffer)))
    (drgnx-agent-panel--ask "agents/explain" (list :id drgnx-agent-panel--session :item "mode")
                            (lambda (r err)
                              (if err (message "agents/explain: %s" err)
                                (drgnx-agent-panel--offer-modes buffer (plist-get r :facts)))))))

(defun drgnx-agent-panel-switch-model ()
  "Switch the agent's model; the agent refuses one it does not have, and the panel says so."
  (interactive)
  (let ((model (string-trim (read-string "Model: " (plist-get drgnx-agent-panel--snap :model)))))
    (unless (string-empty-p model)
      (drgnx-agent-panel--ask "agents/config" (list :id drgnx-agent-panel--session :option "model" :value model)
                              (drgnx-agent-panel--say "agents/config")))))

(defun drgnx-agent-panel--other-profiles ()
  (require 'drgnx-agents)
  (seq-remove (lambda (n) (equal n (plist-get drgnx-agent-panel--snap :profile))) (drgnx-agents-profile-names)))

(defun drgnx-agent-panel-move ()
  "Move this session to another profile: it stops after its tool call and the new agent continues in the same worktree."
  (interactive)
  (let ((profile (completing-read "Move to profile: " (drgnx-agent-panel--other-profiles) nil t)))
    (when (y-or-n-p (format "Move to %s? The agent stops after its current tool call " profile))
      (drgnx-agent-panel--ask "agents/move" (list :id drgnx-agent-panel--session :profile profile)
                              (lambda (r err)
                                (if err (message "agents/move: %s" err)
                                  (drgnx-agent-panel-open (plist-get r :id))))))))

(defun drgnx-agent-panel-start ()
  "Start another agent in this session's folder and open its panel."
  (interactive)
  (require 'drgnx-agents)
  (let ((profile (completing-read "Start profile: " (drgnx-agents-profile-names) nil t))
        (cwd (plist-get drgnx-agent-panel--snap :cwd)))
    (drgnx-agent-panel--ask "agents/start" (append (list :profile profile) (and cwd (list :cwd cwd)))
                            (lambda (r err)
                              (if err (message "agents/start: %s" err)
                                (drgnx-agent-panel-open (plist-get r :id)))))))

(defun drgnx-agent-panel--compact-after-preview (buffer preview)
  "Show PREVIEW, what a compaction would free and keep, and send /compact to BUFFER's agent when you agree."
  (with-current-buffer (drgnx-agent-panel-explain--fresh "*agent compact preview*")
    (let ((inhibit-read-only t)) (insert (drgnx-agents-hooks--preview-text preview)))
    (special-mode)
    (display-buffer (current-buffer)))
  (when (y-or-n-p "Compact now? ")
    (with-current-buffer buffer (drgnx-agent-panel-composer--send-text "/compact"))))

(defun drgnx-agent-panel-compact ()
  "Compact the agent's context (`/compact').  An agent that can say what it keeps shows that first."
  (interactive)
  (let ((buffer (current-buffer)))
    (if (member "compact-preview" (append (plist-get (plist-get drgnx-agent-panel--snap :panel) :features) nil))
        (drgnx-agent-panel--ask "agents/compact-preview" (list :id drgnx-agent-panel--session)
                                (lambda (r err)
                                  (if err (message "agents/compact-preview: %s" err)
                                    (drgnx-agent-panel--compact-after-preview buffer r))))
      (when (y-or-n-p "Compact the agent's context? ")
        (drgnx-agent-panel-composer--send-text "/compact")))))

(defun drgnx-agent-panel-composer-setup ()
  (add-to-list 'drgnx-modal-input-modes 'drgnx-agent-panel-composer-mode)
  (dolist (c '((agents-panel-send "Send to the Agent" drgnx-agent-panel-send
                                  "Send the composer's message; while the agent works it is queued, never a cancel")
               (agents-panel-newline "New Line in the Message" drgnx-agent-panel-composer-newline
                                     "Break the line in the composer's message; nothing is sent")
               (agents-panel-back "Back to the Transcript" drgnx-agent-panel-composer-back
                                  "From the composer back to the panel's transcript")))
    (drgnx-command-define (nth 0 c) :category "Agents" :title (nth 1 c) :command (nth 2 c)
                          :map 'drgnx-agent-panel-composer-mode-map :doc (nth 3 c)))
  (dolist (c '((agents-panel-compose "Write to the Agent" drgnx-agent-panel-compose
                                     "Put point in the composer under the transcript")
               (agents-panel-stop "Stop the Agent" drgnx-agent-panel-stop
                                  "Stop the agent after a confirmation line; its turn stops after the current step")
               (agents-panel-pause "Stop the Agent After This Step" drgnx-agent-panel-pause
                                   "Hold the agent after its current step; the queue waits")
               (agents-panel-resume "Resume the Agent" drgnx-agent-panel-resume "A plain continue prompt")
               (agents-panel-edit-queued "Edit the Queued Note" drgnx-agent-panel-edit-queued
                                         "Change the queued note at point until it is sent")
               (agents-panel-drop-queued "Drop the Queued Note" drgnx-agent-panel-drop-queued
                                         "Take the queued note at point out of the queue")
               (agents-panel-fork "Fork the Chat" drgnx-agent-panel-fork
                                  "Start a second agent from the chat's last step (the composer's Fork)")
               (agents-panel-pair "Pair With the Agent" drgnx-agent-panel-pair "Pair mode, when it is available")
               (agents-panel-start "Start Another Agent Here" drgnx-agent-panel-start
                                   "Start an agent of a profile you choose in this session's folder")
               (agents-panel-move "Move to Another Profile" drgnx-agent-panel-move
                                  "Stop after the current tool call and continue in the same worktree with another profile")
               (agents-panel-compact "Compact the Context" drgnx-agent-panel-compact
                                     "/compact, with what it keeps shown first when the agent can say")
               (agents-panel-mode "Switch the Mode" drgnx-agent-panel-switch-mode
                                  "Switch the agent's mode to one its lock allows")
               (agents-panel-model "Switch the Model" drgnx-agent-panel-switch-model
                                   "Switch the agent's model")))
    (drgnx-command-define (nth 0 c) :category "Agents" :title (nth 1 c) :command (nth 2 c)
                          :map 'drgnx-agent-panel-mode-map :doc (nth 3 c))))

(provide 'drgnx-agent-panel-composer)
;;; drgnx-agent-panel-composer.el ends here
