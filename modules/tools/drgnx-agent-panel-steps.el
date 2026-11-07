;;; drgnx-agent-panel-steps.el --- The agent panel's rows: header, chips, steps, messages (library of tools/agent-panel) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; How the panel's rows look.  A tool call is a step on one line: a dot for its state, its title, its result after `·',
;; its time and cost right-aligned in the code face (the warning face when slow or expensive).  Thinking folds under
;; its step.  Loaded by tools/agent-panel (drgnx-agent-panel.el); defines no module.  See docs/guide/agent-panel.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-setting)
(require 'drgnx-view)
(require 'drgnx-registry)

(defvar drgnx-agent-panel--session)
(defvar drgnx-agent-panel--shown-keys)
(defvar drgnx-agent-panel--snap)
(defvar drgnx-agent-panel--busy-since)
(defvar drgnx-agent-panel--entries)
(defvar drgnx-agent-panel--steps)
(defvar drgnx-agent-panel--open)
(defvar drgnx-agent-panel-slow-seconds)
(defvar drgnx-agent-panel-expensive-cost)
(declare-function drgnx-agent-panel--entry "drgnx-agent-panel")
(declare-function drgnx-agent-panel--blocks "drgnx-agent-panel")
(declare-function drgnx-agent-panel--ask "drgnx-agent-panel")
(declare-function drgnx-agent-panel--thoughts-of "drgnx-agent-panel")
(declare-function drgnx-agent-panel--duration-string "drgnx-agent-panel")
(declare-function drgnx-agent-panel--type "drgnx-agent-panel")
(declare-function drgnx-agent-panel--text-of "drgnx-agent-panel")
(declare-function drgnx-agent-panel--one-line "drgnx-agent-panel")
(declare-function drgnx-agent-panel--seconds "drgnx-agent-panel")
(declare-function drgnx-agent-panel--cost-of "drgnx-agent-panel")
(declare-function drgnx-agent-panel-explain-step-lines "drgnx-agent-panel-explain")
(declare-function drgnx-history-revert-to-here "drgnx-history-revert")
(declare-function drgnx-history-fork-here "drgnx-history-revert")

(defun drgnx-agent-panel--align (meta)
  "A space that pushes META to the right edge, then META."
  (concat (propertize " " 'display `(space :align-to (- right ,(1+ (string-width meta))))) meta))

(defun drgnx-agent-panel--status-line (snap since now)
  "What the agent is doing, for the header: \"Claude · running 6 min\", \"held by you\" or \"Pair · editing your checkout\".
SNAP is the snapshot, SINCE when it began running (float seconds) and NOW the time."
  (let* ((who (or (plist-get snap :profile) "Agent"))
         (status (format "%s" (plist-get snap :status)))
         (what (cond ((plist-get snap :paused) "held by you")
                     ((and (plist-get snap :paired) (not (eq (plist-get snap :paired) :json-false))) "Pair · editing your checkout")
                     ((equal status "busy")
                      (if since (format "running %d min" (max 1 (round (/ (- now since) 60.0)))) "running"))
                     ((equal status "waiting") "waiting for you")
                     ((equal status "exited") "ended")
                     ((equal status "idle") "idle")
                     (t status))))
    (if (and (plist-get snap :paired) (not (plist-get snap :paused))
             (not (eq (plist-get snap :paired) :json-false)))
        what
      (format "%s · %s" who what))))

(defun drgnx-agent-panel--header-row ()
  (let* ((snap drgnx-agent-panel--snap)
         (name (or (plist-get snap :name) drgnx-agent-panel--session "agent")))
    (concat (propertize (format " %s" name) 'face 'drgnx-agent-panel-title)
            (propertize (format "  %s" (drgnx-agent-panel--status-line snap drgnx-agent-panel--busy-since
                                                                       (float-time)))
                        'face 'drgnx-agent-panel-subtle)
            "\n")))

(defun drgnx-agent-panel--chips (snap)
  "The chips the snapshot feeds, a list of strings; one the hub did not feed is not there."
  (let* ((usage (plist-get snap :usage))
         (used (plist-get usage :used)) (size (plist-get usage :size)) (cost (plist-get usage :cost))
         (files (plist-get snap :files_edited)) (checks (plist-get snap :checkpoints))
         (mcp (plist-get snap :mcp)) (sandbox (plist-get snap :sandbox))
         (model (plist-get snap :model)) (mode (plist-get snap :mode)))
    (delq nil
          (list (and (stringp model) (propertize model 'drgnx-agent-panel-chip 'model))
                (and (numberp used) (numberp size) (> size 0)
                     (let ((p (round (* 100 (/ (float used) size)))))
                       (propertize (format "%s %d%%" (cond ((< p 13) "○") ((< p 38) "◔") ((< p 63) "◑") ((< p 88) "◕") (t "●")) p)
                                   'drgnx-agent-panel-chip 'context)))
                (and cost (let ((c (if (listp cost) (plist-get cost :amount) cost)))
                            (and (numberp c) (propertize (format "$%.2f" c) 'drgnx-agent-panel-chip 'cost))))
                (and mode (propertize (format "%s" mode) 'drgnx-agent-panel-chip 'mode))
                (and sandbox (format "%s" (if (eq sandbox t) "sandboxed" sandbox)))
                (and mcp (propertize (format "MCP %s" (if (numberp mcp) mcp (length mcp))) 'drgnx-agent-panel-chip 'mcp))
                (and (numberp files) (format "%d files" files))
                (and (numberp checks)
                     (let ((level (plist-get snap :restore_level)))
                       (format "%d checkpoints%s" checks (if (stringp level) (concat " · " level) ""))))))))

(defun drgnx-agent-panel--chips-row ()
  (let ((chips (drgnx-agent-panel--chips drgnx-agent-panel--snap)))
    (concat " " (mapconcat (lambda (c) (propertize (concat " " c " ") 'face 'drgnx-agent-panel-chip)) chips " ") "\n")))

(defun drgnx-agent-panel--dot (status)
  (pcase status
    ((or "completed" "done") (propertize "●" 'face 'drgnx-agent-panel-ok))
    ("failed" (propertize "●" 'face 'drgnx-agent-panel-fail))
    (_ (propertize "○" 'face 'drgnx-agent-panel-run))))

(defun drgnx-agent-panel--meta (entry)
  "The right-hand time and cost of tool ENTRY, a propertized string, or nil."
  (when-let* ((seq (plist-get entry :step)) (step (gethash seq drgnx-agent-panel--steps)))
    (let* ((secs (drgnx-agent-panel--seconds step)) (cost (drgnx-agent-panel--cost-of step))
           (slow (and secs (> secs drgnx-agent-panel-slow-seconds)))
           (dear (and cost (> cost drgnx-agent-panel-expensive-cost)))
           (parts (delq nil (list (and secs (propertize (drgnx-agent-panel--duration-string secs)
                                                        'face (if slow '(drgnx-agent-panel-warn drgnx-agent-panel-code)
                                                                'drgnx-agent-panel-code)))
                                  (and cost (propertize (format "$%.2f" cost)
                                                        'face (if dear '(drgnx-agent-panel-warn drgnx-agent-panel-code)
                                                                'drgnx-agent-panel-code)))))))
      (and parts (mapconcat #'identity parts (propertize " · " 'face 'drgnx-agent-panel-code))))))

(defun drgnx-agent-panel--indented (text face &optional limit)
  "TEXT as lines indented by four columns in FACE, at most LIMIT lines (default 40)."
  (let* ((lines (split-string (string-trim-right (or text "")) "\n")) (limit (or limit 40)))
    (mapconcat (lambda (l) (propertize (concat "    " l "\n") 'face face))
               (append (seq-take lines limit) (and (> (length lines) limit) (list "…"))) "")))

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
    (drgnx-view-dirty drgnx-view (list key))))

(defun drgnx-agent-panel--redraw-steps ()
  "Every step row and the strip are drawn again."
  (when (drgnx-view-p drgnx-view)
    (drgnx-view-dirty drgnx-view
                      (cons (list :strip)
                            (seq-filter (lambda (k) (eq (car-safe k) :e)) (hash-table-keys drgnx-agent-panel--shown-keys))))))

(defun drgnx-agent-panel--set-disclosure (types)
  "TYPES are the open step types of this chat; rows you opened or folded by hand are back under the toggles."
  (setq drgnx-agent-panel--disclosure (copy-sequence types))
  (clrhash drgnx-agent-panel--open)
  (drgnx-agent-panel--redraw-steps))

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

(defun drgnx-agent-panel--strip-row ()
  "The disclosure strip: a toggle for each step type, and the presets."
  (concat " "
          (mapconcat (lambda (ty)
                       (propertize (format " %s %s " (if (memq ty drgnx-agent-panel--disclosure) "▾" "▸") ty)
                                   'face 'drgnx-agent-panel-chip))
                     drgnx-agent-panel-step-types " ")
          (propertize "  1 watch · 2 review · 3 debug · T toggle · M make default" 'face 'drgnx-agent-panel-subtle)
          "\n"))

(defun drgnx-agent-panel-steps-setup ()
  (drgnx-command-define 'agents-panel-toggle-type :category "Agents" :title "Open or Close a Step Type"
                        :command #'drgnx-agent-panel-toggle-type :map 'drgnx-agent-panel-mode-map
                        :doc "Show or hide the detail of every step of one type in this chat")
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

(defun drgnx-agent-panel--large-p (e lines)
  "Whether tool entry E's output, LINES in the text the panel holds, is larger than head and tail show."
  (or (> (length lines) (* 2 drgnx-agent-panel-output-edge))
      (let ((total (plist-get e :outputBytes)))
        (and (numberp total) (> total (drgnx-agent-panel--utf8-length (string-join lines "\n")))))))

(defun drgnx-agent-panel--detail (e)
  "The detail of tool entry E: its output, or for a large one its first and last lines and a line saying what is
hidden (an estimate, marked ~, when the hub kept only the ends of a huge output)."
  (let* ((text (string-trim-right (drgnx-agent-panel--text-of (plist-get e :content))))
         (lines (split-string text "\n")))
    (if (not (drgnx-agent-panel--large-p e lines))
        (drgnx-agent-panel--indented text 'default 12)
      (let* ((n drgnx-agent-panel-output-edge) (have (length lines))
             (bytes (max 1 (drgnx-agent-panel--utf8-length text))) (total (plist-get e :outputBytes))
             (whole (if (and (numberp total) (> total bytes)) (ceiling (* have (/ (float total) bytes))) have))
             (hidden (max 0 (- whole (* 2 n)))))
        (concat (drgnx-agent-panel--indented (string-join (seq-take lines n) "\n") 'default n)
                (propertize (format "    %s%d lines hidden · / search · O open in a buffer\n"
                                    (if (= whole have) "" "~") hidden)
                            'face 'drgnx-agent-panel-subtle)
                (drgnx-agent-panel--indented (string-join (last lines n) "\n") 'default n))))))

(defun drgnx-agent-panel--output-fetch (session tool from callback)
  "Ask the hub for the page of TOOL's output in SESSION that starts at byte FROM; CALLBACK gets (TEXT TOTAL ERROR)."
  (drgnx-agent-panel--ask
   "agents/tool-output" (list :id session :tool_call tool :from from :to (+ from drgnx-agent-panel-output-page))
   (lambda (r err) (funcall callback (and (not err) (or (plist-get r :text) "")) (and (not err) (plist-get r :total_bytes)) err))))

(defun drgnx-agent-panel--tool-at-point ()
  "The tool entry at point, or a user error."
  (let* ((key (and (drgnx-view-p drgnx-view) (drgnx-view-key-at)))
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

(defun drgnx-agent-panel--undone-p (e)
  "Whether a revert undid the step of tool entry E."
  (integerp (plist-get (drgnx-agent-panel--step-row e) :undone_by)))

(defun drgnx-agent-panel--step-at-point ()
  "The timeline row of the step at point, or a user error."
  (let* ((key (and (drgnx-view-p drgnx-view) (drgnx-view-key-at)))
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

(defun drgnx-agent-panel--parent-tool (e)
  "The `Task' call that E's step ran under (a subagent's step), or nil."
  (when-let* ((seq (plist-get e :step)) (step (gethash seq drgnx-agent-panel--steps)))
    (plist-get (plist-get step :detail) :parent_tool)))

(defun drgnx-agent-panel--child-face (parent)
  "The agent colour a subagent's steps (those under PARENT) are drawn in."
  (intern (format "drgnx-agent-%d" (1+ (mod (sxhash-equal parent) 6)))))

(defun drgnx-agent-panel--tool-row (idx e)
  (let* ((key (list :e idx)) (status (format "%s" (or (plist-get e :status) "")))
         (title (drgnx-agent-panel--one-line (or (plist-get e :title) (plist-get e :kind) "tool") 50))
         (result (drgnx-agent-panel--one-line (drgnx-agent-panel--text-of (plist-get e :content)) 40))
         (meta (drgnx-agent-panel--meta e))
         (parent (drgnx-agent-panel--parent-tool e))
         (thoughts (drgnx-agent-panel--thoughts-of idx))
         (open-thinking (drgnx-agent-panel--thinking-open-p key))
         (open-detail (drgnx-agent-panel--detail-open-p key e)))
    (concat (format "%s%s %s" (if parent "      " "  ") (drgnx-agent-panel--dot status)
                    (if parent (propertize title 'face (drgnx-agent-panel--child-face parent)) title))
            (if (string-empty-p result) ""
              (propertize (concat "  · " result) 'face 'drgnx-agent-panel-subtle))
            (if (drgnx-agent-panel--undone-p e) (propertize "  ↶ undone" 'face 'drgnx-agent-panel-subtle) "")
            (if meta (drgnx-agent-panel--align meta) "")
            "\n"
            (drgnx-agent-panel-explain-step-lines e)
            (when thoughts
              (let ((text (mapconcat (lambda (th) (or (plist-get th :text) "")) thoughts "\n")))
                (if open-thinking
                    (concat (propertize "    ▾ thinking\n" 'face 'drgnx-agent-panel-subtle)
                            (drgnx-agent-panel--indented text 'drgnx-agent-panel-subtle))
                  (propertize (format "    ▸ thinking · %d lines\n" (length (split-string (string-trim-right text) "\n")))
                              'face 'drgnx-agent-panel-subtle))))
            (when (and open-detail (drgnx-agent-panel--text-of (plist-get e :content)))
              (drgnx-agent-panel--detail e)))))

;;;; Agent messages as Markdown blocks

(defun drgnx-agent-panel--style-face (style)
  "The faces for STYLE, `text' or a space-joined mix of emph, strong, strike, link, code and h1..h6."
  (let (faces)
    (dolist (s (split-string (or style "text")))
      (when-let* ((f (cond ((equal s "emph") 'drgnx-agent-panel-md-emph)
                           ((equal s "strong") 'drgnx-agent-panel-md-strong)
                           ((equal s "strike") 'drgnx-agent-panel-md-strike)
                           ((equal s "link") 'drgnx-agent-panel-md-link)
                           ((equal s "code") 'drgnx-agent-panel-md-code)
                           ((string-match-p "\\`h[1-6]\\'" s) 'drgnx-agent-panel-md-heading))))
        (push f faces)))
    (nreverse faces)))

(defun drgnx-agent-panel--block-row (idx n)
  "Block N of the agent message at IDX, one row: its spans in their faces, indented two columns."
  (let* ((block (let ((bs (drgnx-agent-panel--blocks idx))) (and bs (< n (length bs)) (aref bs n))))
         (kind (plist-get block :kind))
         (base (pcase kind
                 ("code" 'drgnx-agent-panel-md-code)
                 ("quote" 'drgnx-agent-panel-md-quote)
                 ("heading" 'drgnx-agent-panel-md-heading)))
         (pad (if (equal kind "quote") (propertize "  ▎ " 'face 'drgnx-agent-panel-md-quote) "  ")))
    (if (equal kind "rule")
        (concat "  " (propertize (make-string 24 ?─) 'face 'drgnx-agent-panel-md-rule) "\n")
      (let ((text (mapconcat
                   (lambda (span)
                     (let ((faces (drgnx-agent-panel--style-face (plist-get span :style))))
                       (propertize (replace-regexp-in-string "\n" (concat "\n" pad) (or (plist-get span :text) ""))
                                   'face (delq nil (append faces (list base))))))
                   (plist-get block :spans) "")))
        (concat pad text "\n")))))

(defun drgnx-agent-panel--entry-row (idx)
  (let ((e (drgnx-agent-panel--entry idx)))
    (pcase (drgnx-agent-panel--type e)
      ('tool (drgnx-agent-panel--tool-row idx e))
      ('user (concat (propertize "  ▍ you  " 'face 'drgnx-agent-panel-you)
                     (drgnx-agent-panel--one-line (plist-get e :text) 70) "\n"))
      ('agent (concat (propertize (concat "  " (replace-regexp-in-string "\n" "\n  " (string-trim-right (or (plist-get e :text) ""))))
                                  'face 'default)
                      "\n"))
      ('thought (concat (propertize "  ▸ thinking\n" 'face 'drgnx-agent-panel-subtle)
                        (if (drgnx-agent-panel--thinking-open-p (list :e idx))
                            (drgnx-agent-panel--indented (plist-get e :text) 'drgnx-agent-panel-subtle) "")))
      ('stop (propertize "  — turn ended\n" 'face 'drgnx-agent-panel-subtle))
      ('error (propertize (format "  ✗ %s\n" (drgnx-agent-panel--one-line (or (plist-get e :text) (plist-get e :title) "error") 80))
                          'face 'drgnx-agent-panel-fail))
      ('compaction (propertize "  — context compacted\n" 'face 'drgnx-agent-panel-subtle))
      (_ (propertize (format "  %s\n" (drgnx-agent-panel--one-line (plist-get e :text) 80)) 'face 'drgnx-agent-panel-subtle)))))


(provide 'drgnx-agent-panel-steps)
;;; drgnx-agent-panel-steps.el ends here
