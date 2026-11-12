;;; drgnx-debug-view.el --- The Run and Debug view  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Run and Debug view (docs/develop/debugging.md, "The Run and Debug view"; spec §7): a sidebar view the hub
;; builds (`debug/view'), as the Explorer is.  Its sections are VARIABLES, WATCH, CALL STACK and BREAKPOINTS; the hub
;; sends the model (a `tree': a node per row, its kind, whether it is open, its label, value and what the commands
;; read as fields) and the rows.  Keys answer from the model in the key's own frame (Sjá); opening a node asks the hub
;; (`debug/expand'), which fetches what it needs and patches the rows.  The header line holds Start and the
;; configuration picker.

;;; Code:

(require 'drgnx-view-nav)
(require 'drgnx-debug-launch (expand-file-name "drgnx-debug-launch" (file-name-directory (macroexp-file-name))))

(declare-function nidhogg-view-get "nidhogg-views" (h what &optional arg arg2))
(declare-function drgnx-view-env-register "drgnx-view-env" (view buffer &optional resubscribe headless))
(declare-function drgnx-view-env-twin "drgnx-view-env" (class prefixes &optional setup))
(declare-function drgnx-wb-show-view "drgnx-wb" (view))
(declare-function drgnx-hub--call-on "drgnx-hub-client" (conn method params callback &rest keys))
(declare-function drgnx-hub-call "drgnx-hub-client" (method params callback &rest keys))
(declare-function drgnx-hub-call-sync "drgnx-hub-client" (method params &optional timeout))
(defvar drgnx-hub--events)

(defgroup drgnx-debug-view nil "The Run and Debug view." :group 'drgnx)

(defface drgnx-debug-view-section '((t :inherit bold)) "A section's title." :group 'drgnx-debug-view)
(defface drgnx-debug-view-scope '((t :inherit bold)) "A scope (Locals, Globals)." :group 'drgnx-debug-view)
(defface drgnx-debug-view-name '((t :inherit font-lock-variable-name-face)) "A variable's name." :group 'drgnx-debug-view)
(defface drgnx-debug-view-value '((t :inherit default)) "A value." :group 'drgnx-debug-view)
(defface drgnx-debug-view-string '((t :inherit font-lock-string-face)) "A string value." :group 'drgnx-debug-view)
(defface drgnx-debug-view-number '((t :inherit font-lock-number-face)) "A number value." :group 'drgnx-debug-view)
(defface drgnx-debug-view-type '((t :inherit drgnx-text-muted)) "A type, a frame's place, a hint." :group 'drgnx-debug-view)
(defface drgnx-debug-view-changed '((t :inherit drgnx-status-warn))
  "A value that changed since the last stop." :group 'drgnx-debug-view)
(defface drgnx-debug-view-error '((t :inherit drgnx-status-fail)) "A watch that failed." :group 'drgnx-debug-view)
(defface drgnx-debug-view-link '((t :inherit link)) "Something to click: `(…)', Load more frames." :group 'drgnx-debug-view)
(defface drgnx-debug-view-chip '((t :inherit drgnx-chip-warn)) "A thread's state." :group 'drgnx-debug-view)
(defface drgnx-debug-view-current '((t :inherit (drgnx-debug-stopped bold))) "The selected frame." :group 'drgnx-debug-view)
(defface drgnx-debug-view-tick '((t :inherit drgnx-text-muted)) "A tick box." :group 'drgnx-debug-view)
(defface drgnx-debug-view-breakpoint '((t :inherit drgnx-debug-breakpoint)) "A breakpoint's dot." :group 'drgnx-debug-view)
(defface drgnx-debug-view-guide '((t :inherit drgnx-text-muted)) "The indent and chevrons." :group 'drgnx-debug-view)
(defface drgnx-debug-view-dim '((t :inherit drgnx-text-disabled))
  "An old stop's row, an unverified breakpoint, a hidden frame." :group 'drgnx-debug-view)

(defconst drgnx-debug-view-id "debug" "The hub's view id of Run and Debug.")

(defconst drgnx-debug-view-buffer-name "*Run and Debug*" "The view's buffer.")

(defvar-local drgnx-debug-view--session nil "The session Variables and Watch show (nil: the first stopped one).")
(defvar-local drgnx-debug-view--filter nil "The text the rows are filtered by, or nil.")
(defvar-local drgnx-debug-view--root nil "The project the view shows.")

(defvar drgnx-debug-view-await-limit 0.012
  "Seconds a key that opens or closes a node waits for the hub's rows, so they show in the key's own frame.")

(defvar-keymap drgnx-debug-view-mode-map
  :doc "Keys of the Run and Debug view (key profiles: `:map drgnx-debug-view-mode-map').")

(define-derived-mode drgnx-debug-view-mode special-mode "Run and Debug"
  "The Run and Debug view: variables, watches, the call stack and the breakpoints of the project's sessions."
  (setq-local truncate-lines t)
  (buffer-disable-undo)
  (setq-local header-line-format '(:eval (drgnx-debug-view--header))))

;;;; The header: Start and the picker

(defvar-local drgnx-debug-view--config nil "The configuration Start runs: (ID . NAME), or nil (pick one).")

(defun drgnx-debug-view--header ()
  "Start (▶) and the picked configuration (its name, a chevron): a click on either runs it or picks another."
  (concat " "
          (propertize "▶ Start" 'face 'drgnx-status-ok 'mouse-face 'highlight 'help-echo "Start Debugging"
                      'keymap (drgnx-debug-view--click #'drgnx-debug-view-start))
          "  "
          (propertize (concat (or (cdr drgnx-debug-view--config) "No Configuration") " ▾")
                      'mouse-face 'highlight 'help-echo "Select a launch configuration"
                      'keymap (drgnx-debug-view--click #'drgnx-debug-view-pick))))

(defun drgnx-debug-view--click (fn)
  "A header-line keymap whose click runs FN."
  (let ((m (make-sparse-keymap))) (define-key m [header-line mouse-1] fn) m))

(defun drgnx-debug-view-pick ()
  "Pick the configuration Start runs."
  (interactive)
  (let* ((root (drgnx-debug-view--project)) (id (drgnx-debug-launch-read-config root)))
    (with-current-buffer (drgnx-debug-view--buffer)
      (setq drgnx-debug-view--config (cons id (drgnx-debug-view--config-name root id)))
      (force-mode-line-update))))

(defun drgnx-debug-view--config-name (root id)
  "The name of configuration ID of ROOT."
  (let ((c (seq-find (lambda (c) (equal (plist-get c :id) id))
                     (append (plist-get (drgnx-debug-launch-configs root) :configs) nil))))
    (or (plist-get c :name) id)))

(defun drgnx-debug-view-start ()
  "Start the picked configuration (pick one first when none is)."
  (interactive)
  (let ((root (drgnx-debug-view--project)))
    (unless (buffer-local-value 'drgnx-debug-view--config (drgnx-debug-view--buffer)) (drgnx-debug-view-pick))
    (when-let* ((c (buffer-local-value 'drgnx-debug-view--config (drgnx-debug-view--buffer))))
      (drgnx-debug-launch-start root (car c)))))

(defun drgnx-debug-view--project ()
  "The project the view shows: the editor's, else the one it showed."
  (or (and (fboundp 'drgnx-state-editor-window) (window-live-p (drgnx-state-editor-window))
           (with-current-buffer (window-buffer (drgnx-state-editor-window)) (drgnx-debug-launch-root)))
      (when-let* ((b (get-buffer drgnx-debug-view-buffer-name))) (buffer-local-value 'drgnx-debug-view--root b))
      (drgnx-debug-launch-root)))

;;;; The buffer, hub-fed

(defun drgnx-debug-view--twin (class)
  "The view's buffer in display CLASS (`drgnx-view-patch-twin-function')."
  (drgnx-view-env-twin class '("drgnx-debug-view-")))

(defun drgnx-debug-view--buffer ()
  "The view's buffer, attached as the hub-fed view `debug' the first time."
  (or (get-buffer drgnx-debug-view-buffer-name)
      (let ((root (drgnx-debug-launch-root)))
        (with-current-buffer (generate-new-buffer drgnx-debug-view-buffer-name t)
          (drgnx-debug-view-mode)
          (setq drgnx-debug-view--root root)
          (if (not (fboundp 'nidhogg-view--call))
              (let ((inhibit-read-only t))
                (insert (propertize "  Run and Debug needs drgnx's own Emacs (Nidhogg).\n" 'face 'shadow)))
            (drgnx-view-patch-attach drgnx-debug-view-id "unshown")
            (setq-local drgnx-view-patch-twin-function #'drgnx-debug-view--twin)
            (require 'drgnx-view-env)
            (drgnx-view-env-register drgnx-debug-view-id (current-buffer) #'drgnx-debug-view--ask)
            (drgnx-debug-view--ask))
          (current-buffer)))))

(defun drgnx-debug-view--indent ()
  "A level's indent in logical px: the density's `tree-indent'."
  (if (fboundp 'drgnx-look-density-value) (drgnx-look-density-value 'tree-indent) 12))

(defun drgnx-debug-view--call (method params &optional callback)
  "Ask the hub METHOD with PARAMS on the connection the view's rows come on (the hub keeps the view per connection);
CALLBACK gets the result and the error.  Nothing waits; nothing while the hub is down."
  (when (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
    (condition-case nil (drgnx-hub--call-on drgnx-hub--events method params (or callback #'ignore)) (error nil))))

(defun drgnx-debug-view--ask (&optional _view)
  "Ask the hub for the view of the project (`debug/view'): at attach, on a reconnect, when the session or filter
changes."
  (with-current-buffer (get-buffer drgnx-debug-view-buffer-name)
    (drgnx-debug-view--call "debug/view"
                            (append (list :view drgnx-debug-view-id :root drgnx-debug-view--root
                                          :indent (drgnx-debug-view--indent))
                                    (and drgnx-debug-view--session (list :session drgnx-debug-view--session))
                                    (and drgnx-debug-view--filter (list :filter drgnx-debug-view--filter))))))

(defun drgnx-debug-view--await ()
  "In a user's command, after asking the hub: read its connection until the view's rows change, at most
`drgnx-debug-view-await-limit', and draw them now, so the key's own redisplay shows them."
  (when-let* ((state drgnx-view-patch) ((boundp 'drgnx-hub--events)) (proc drgnx-hub--events)
              ((process-live-p proc)))
    (let ((before (drgnx-view-patch-version state)) (end (+ (float-time) drgnx-debug-view-await-limit)))
      (with-local-quit
        (while (and (eql before (drgnx-view-patch-version state)) (< (float-time) end))
          (accept-process-output proc (max 0.001 (- end (float-time))) nil t)))
      (unless (eql before (drgnx-view-patch-version state)) (drgnx-view-draw-now drgnx-view)))))

;;;; The node at point

(defun drgnx-debug-view--here ()
  "The node of the row at point, made the selection, or nil."
  (when-let* ((id (get-text-property (pos-bol) drgnx-view-patch-id-prop)))
    (unless (equal id (drgnx-view-nav-selection)) (drgnx-view-nav 'select id))
    id))

(defun drgnx-debug-view--node ()
  "The node at point, or a `user-error'."
  (or (drgnx-debug-view--here) (user-error "No row here")))

(defun drgnx-debug-view--kind (id)
  "Node ID's kind."
  (when-let* ((h (drgnx-view-patch-handle drgnx-view-patch))) (nidhogg-view-get h 'kind id)))

(defun drgnx-debug-view--open-p (id)
  "Whether node ID is open."
  (when-let* ((h (drgnx-view-patch-handle drgnx-view-patch))) (eql 1 (nidhogg-view-get h 'open id))))

(defun drgnx-debug-view--field (name id) (drgnx-view-nav-field name id))

(defun drgnx-debug-view--toggle (id open)
  "Open (OPEN) or close node ID: the hub fetches what it needs and sends the rows, drawn in this key's frame when
they come within `drgnx-debug-view-await-limit'.  An old stop's node does not open."
  (when (eql 1 (drgnx-debug-view--field "dim" id)) (user-error "Not paused here: the values are from the last stop"))
  (drgnx-debug-view--call "debug/expand" (list :view drgnx-debug-view-id :node id :open (if open t :false)))
  (drgnx-debug-view--await))

;;;; Commands

(defun drgnx-debug-view ()
  "Show the Run and Debug view in the sidebar."
  (interactive)
  (let ((root (drgnx-debug-view--project)))
    (with-current-buffer (drgnx-debug-view--buffer)
      (unless (equal root drgnx-debug-view--root)
        (setq drgnx-debug-view--root root drgnx-debug-view--session nil)
        (drgnx-debug-view--ask))))
  (drgnx-wb-show-view 'debug))

(defun drgnx-debug-view-next () "Next row." (interactive) (drgnx-debug-view--here) (drgnx-view-nav 'follow "down"))
(defun drgnx-debug-view-previous () "Previous row." (interactive) (drgnx-debug-view--here) (drgnx-view-nav 'follow "up"))

(defun drgnx-debug-view-expand ()
  "Open the node, or go to its first child when it is open."
  (interactive)
  (let ((id (drgnx-debug-view--node)))
    (cond ((drgnx-debug-view--open-p id) (drgnx-view-nav 'follow "right"))
          ((eql 1 (drgnx-debug-view--field "openable" id)) (drgnx-debug-view--toggle id t)))))

(defun drgnx-debug-view-collapse ()
  "Close the node, or go to its parent when it is closed."
  (interactive)
  (let ((id (drgnx-debug-view--node)))
    (if (drgnx-debug-view--open-p id) (drgnx-debug-view--toggle id nil) (drgnx-view-nav 'follow "left"))))

(defun drgnx-debug-view-activate ()
  "The row's action: a frame is shown (its scopes in Variables); a tick box toggles; Load more frames loads them;
`(…)' fetches the value; another node opens or closes."
  (interactive)
  (let* ((id (drgnx-debug-view--node)) (kind (drgnx-debug-view--kind id)) (f (lambda (n) (drgnx-debug-view--field n id))))
    (pcase kind
      ("frame" (drgnx-hub-call "debug/select" (list :session (funcall f "session") :thread (funcall f "thread")
                                                    :frame (funcall f "frame"))
                               #'ignore))
      ("more" (drgnx-debug-view--toggle id t))
      ("filter" (drgnx-debug-view--bp-op (list :op "filter" :adapter (funcall f "type") :name (funcall f "filter")
                                               :enabled (if (eql 1 (funcall f "ticked")) :false t))))
      ("breakpoint" (drgnx-debug-view--bp-op (list :op "edit" :id (funcall f "id")
                                                   :enabled (if (eql 1 (funcall f "ticked")) :false t))))
      ((or "session" "thread")
       (when (equal kind "session") (drgnx-debug-view-select-session (funcall f "session")))
       (when (eql 1 (funcall f "openable")) (drgnx-debug-view--toggle id (not (drgnx-debug-view--open-p id)))))
      (_ (cond ((eql 1 (funcall f "lazy")) (drgnx-debug-view--toggle id t))
               ((eql 1 (funcall f "openable")) (drgnx-debug-view--toggle id (not (drgnx-debug-view--open-p id)))))))))

(defun drgnx-debug-view-select-session (id)
  "Show session ID's variables and watches."
  (with-current-buffer (drgnx-debug-view--buffer)
    (setq drgnx-debug-view--session id)
    (drgnx-debug-view--ask)))

(defun drgnx-debug-view--bp-op (op)
  "Breakpoint operation OP on the view's project (`debug/breakpoints')."
  (drgnx-hub-call "debug/breakpoints" (list :root drgnx-debug-view--root :op op) #'ignore))

(defun drgnx-debug-view--value-node ()
  "The variable or watch at point, or a `user-error'."
  (let ((id (drgnx-debug-view--node)))
    (unless (member (drgnx-debug-view--kind id) '("var" "watch")) (user-error "Not a variable"))
    id))

(defun drgnx-debug-set-value ()
  "Set the variable (or watched expression) at point to a new value, in the debugged program."
  (interactive)
  (let* ((id (drgnx-debug-view--value-node))
         (value (read-string (format "Set %s to: " (drgnx-debug-view--field "label" id))
                             (drgnx-debug-view--field "value" id))))
    (drgnx-debug-view--call "debug/set-value" (list :view drgnx-debug-view-id :node id :value value)
                            #'drgnx-debug-view--set-answered)))

(defun drgnx-debug-view--set-answered (_result error)
  "Set Value's answer: its ERROR in the echo area."
  (when error (message "Set Value: %s" error)))

(defun drgnx-debug-copy-value ()
  "Copy the value at point (the adapter's text for the clipboard when it gives one)."
  (interactive)
  (let* ((id (drgnx-debug-view--value-node)) (expr (drgnx-debug-view--field "evaluate_name" id))
         (s (drgnx-debug-view--shown-session))
         (caps (and s (plist-get s :caps)))
         (r (and expr caps (eq t (plist-get caps :supportsClipboardContext))
                 (ignore-errors (drgnx-hub-call-sync "debug/evaluate" (list :session (plist-get s :id) :expr expr
                                                                            :context "clipboard"))))))
    (kill-new (or (plist-get r :result) (drgnx-debug-view--field "value" id) ""))
    (message "Copied the value")))

(defun drgnx-debug-view--shown-session ()
  "The session Variables shows, as `debug-state' tells it, or nil."
  (when (boundp 'drgnx-debug--sessions)
    (let ((want (buffer-local-value 'drgnx-debug-view--session (drgnx-debug-view--buffer))))
      (or (seq-find (lambda (s) (equal (plist-get s :id) want)) drgnx-debug--sessions)
          (seq-find (lambda (s) (equal (plist-get s :state) "stopped")) drgnx-debug--sessions)))))

(defun drgnx-debug-copy-expression ()
  "Copy the expression that reads the variable at point (its `evaluateName')."
  (interactive)
  (let ((e (drgnx-debug-view--field "evaluate_name" (drgnx-debug-view--value-node))))
    (unless e (user-error "The adapter gives no expression for this variable"))
    (kill-new e)
    (message "Copied %s" e)))

(defun drgnx-debug-add-to-watch ()
  "Watch the variable at point (its expression)."
  (interactive)
  (let* ((id (drgnx-debug-view--value-node))
         (e (or (drgnx-debug-view--field "evaluate_name" id) (drgnx-debug-view--field "label" id))))
    (drgnx-debug-view--watch (list :op "add" :expr e))))

(defun drgnx-debug-view--watch (params)
  "A watch operation PARAMS on the view's project (`debug/watch')."
  (drgnx-hub-call "debug/watch" (append (list :root (drgnx-debug-view--project)) params) #'ignore))

(defun drgnx-debug-watch-add (expr)
  "Watch EXPR (default: the selection or the symbol at point in the editor)."
  (interactive (list (read-string "Watch expression: "
                                  (if (use-region-p) (buffer-substring-no-properties (region-beginning) (region-end))
                                    (thing-at-point 'symbol t)))))
  (unless (string-empty-p expr) (drgnx-debug-view--watch (list :op "add" :expr expr))))

(defun drgnx-debug-view--watch-index (id)
  "The place of watch node ID among the watches."
  (seq-position (seq-filter (lambda (n) (equal (drgnx-debug-view--kind n) "watch"))
                            (append (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'list "order") nil))
                id))

(defun drgnx-debug-watch-edit ()
  "Edit the watch expression at point."
  (interactive)
  (let* ((id (drgnx-debug-view--node)) (i (drgnx-debug-view--watch-index id)))
    (unless i (user-error "Not a watch"))
    (drgnx-debug-view--watch (list :op "edit" :index i
                                   :expr (read-string "Watch expression: " (drgnx-debug-view--field "label" id))))))

(defun drgnx-debug-watch-remove ()
  "Stop watching the expression at point."
  (interactive)
  (let ((i (drgnx-debug-view--watch-index (drgnx-debug-view--node))))
    (unless i (user-error "Not a watch"))
    (drgnx-debug-view--watch (list :op "remove" :index i))))

(defun drgnx-debug-watch-move-up () "Move the watch at point up." (interactive) (drgnx-debug-view--watch-move -1))
(defun drgnx-debug-watch-move-down () "Move the watch at point down." (interactive) (drgnx-debug-view--watch-move 1))

(defun drgnx-debug-view--watch-move (by)
  "Move the watch at point BY places."
  (let ((i (drgnx-debug-view--watch-index (drgnx-debug-view--node))))
    (unless i (user-error "Not a watch"))
    (drgnx-debug-view--watch (list :op "move" :index i :to (max 0 (+ i by))))))

(defun drgnx-debug-view-filter (text)
  "Show only the rows whose name or value contains TEXT (with the rows above them); empty shows all."
  (interactive (list (minibuffer-with-setup-hook
                         (lambda () (add-hook 'after-change-functions #'drgnx-debug-view--filter-typed nil t))
                       (read-string "Filter: " (buffer-local-value 'drgnx-debug-view--filter (drgnx-debug-view--buffer))))))
  (drgnx-timer-cancel 'debug-view-filter)
  (drgnx-debug-view--filter-apply text))

(defun drgnx-debug-view--filter-typed (&rest _)
  "The filter's text changed: filter once typing pauses (the idle debounce `debug-view-filter', 0.1 s)."
  (drgnx-timer-debounce 'debug-view-filter 0.1 #'drgnx-debug-view--filter-apply :idle t
                        :args (list (minibuffer-contents-no-properties)) :owner (drgnx-debug-view--buffer)))

(defun drgnx-debug-view--filter-apply (text)
  "Filter the view by TEXT (empty: none)."
  (with-current-buffer (drgnx-debug-view--buffer)
    (setq drgnx-debug-view--filter (unless (string-empty-p text) text))
    (drgnx-debug-view--ask)))

(defun drgnx-debug-remove-all-breakpoints ()
  "Remove every breakpoint of the project (function breakpoints too)."
  (interactive)
  (when (yes-or-no-p "Remove every breakpoint of this project? ")
    (drgnx-hub-call "debug/breakpoints" (list :root (drgnx-debug-view--project) :op (list :op "remove-all")) #'ignore)))

(defun drgnx-debug-enable-all-breakpoints (enable)
  "Enable every breakpoint of the project; with a prefix argument (ENABLE nil), disable them."
  (interactive (list (not current-prefix-arg)))
  (drgnx-hub-call "debug/breakpoints" (list :root (drgnx-debug-view--project)
                                            :op (list :op "enable-all" :enabled (if enable t :false)))
                  #'ignore))

(defun drgnx-debug-view--teardown ()
  "The view goes with the module: its buffer (and so its hub view)."
  (when-let* ((b (get-buffer drgnx-debug-view-buffer-name))) (kill-buffer b))
  (drgnx-timer-cancel 'debug-view-filter))

(defconst drgnx-debug-view-commands
  '((debug-view "Run and Debug" drgnx-debug-view "Show the Run and Debug view: variables, watches, call stack, breakpoints")
    (debug-view-next "Next Row" drgnx-debug-view-next "Move the selection down")
    (debug-view-previous "Previous Row" drgnx-debug-view-previous "Move the selection up")
    (debug-view-expand "Expand" drgnx-debug-view-expand "Open the node, or go to its first child")
    (debug-view-collapse "Collapse" drgnx-debug-view-collapse "Close the node, or go to its parent")
    (debug-view-activate "Open" drgnx-debug-view-activate "Show the frame, tick the box, or open the node")
    (debug-view-filter "Filter…" drgnx-debug-view-filter "Show only the rows whose name or value contains the text")
    (debug-set-value "Set Value…" drgnx-debug-set-value "Give the variable a new value in the program")
    (debug-copy-value "Copy Value" drgnx-debug-copy-value "Copy the variable's value")
    (debug-copy-expression "Copy as Expression" drgnx-debug-copy-expression "Copy the expression that reads the variable")
    (debug-add-to-watch "Add to Watch" drgnx-debug-add-to-watch "Watch the variable's expression")
    (debug-view-memory "View Binary Data" drgnx-debug-view-memory "Show the variable's bytes in memory, and write them")
    (debug-watch-add "Add Watch Expression…" drgnx-debug-watch-add "Watch an expression at every stop")
    (debug-watch-edit "Edit Watch Expression…" drgnx-debug-watch-edit "Change the watched expression")
    (debug-watch-remove "Remove Watch Expression" drgnx-debug-watch-remove "Stop watching the expression")
    (debug-watch-move-up "Move Watch Up" drgnx-debug-watch-move-up "Move the watch expression up")
    (debug-watch-move-down "Move Watch Down" drgnx-debug-watch-move-down "Move the watch expression down")
    (debug-remove-all-breakpoints "Remove All Breakpoints" drgnx-debug-remove-all-breakpoints "Remove every breakpoint of the project")
    (debug-enable-all-breakpoints "Enable All Breakpoints" drgnx-debug-enable-all-breakpoints "Enable every breakpoint (with a prefix, disable)"))
  "The view's commands, for the module's setup: (ID TITLE FUNCTION DOC).")

(defconst drgnx-debug-view-global-commands
  '(debug-view debug-watch-add debug-remove-all-breakpoints debug-enable-all-breakpoints)
  "The view's commands that work anywhere; the others are keys of the view (`drgnx-debug-view-mode-map').")

(provide 'drgnx-debug-view)
;;; drgnx-debug-view.el ends here
