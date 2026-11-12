;;; drgnx-debug-console.el --- the debug console: the hub's output lines, an input that evaluates -*- lexical-binding: t -*-
;; Part of extra/debug (docs/develop/debugging.md, "The debug console"; spec §10).  The Debug Console tab of the bottom
;; panel: the hub sends `debug-output' batches of lines it has already split, styled and counted; this file only inserts
;; them (keeping the last `drgnx-debug-console-max-lines'), evaluates what is typed in the selected frame
;; (`debug/evaluate', context `repl') and opens a structured result in place (`debug/children').

;;; Code:

(require 'cl-lib)
(require 'seq)

(declare-function drgnx-hub-call "drgnx-hub-client" (method params callback &rest keys))
(declare-function drgnx-hub-call-sync "drgnx-hub-client" (method params &optional timeout))
(declare-function drgnx-wb-area-show "drgnx-area" (area &optional tab buffer))
(declare-function drgnx-debug--session "drgnx-debug" (&optional state))
(defvar drgnx-debug--sessions)

(defgroup drgnx-debug-console nil "The debug console." :group 'drgnx)

(defcustom drgnx-debug-console-max-lines 10000
  "The most lines the debug console keeps; older ones go (VS Code's `debug.console.maximumLines')."
  :type 'natnum :group 'drgnx-debug-console)

(defcustom drgnx-debug-console-clear-on-restart t
  "Non-nil: starting a configuration again clears what its last run printed (once that run has ended)."
  :type 'boolean :group 'drgnx-debug-console)

(defface drgnx-debug-console-stderr '((t :inherit drgnx-status-warn)) "A program's stderr." :group 'drgnx-debug-console)
(defface drgnx-debug-console-important '((t :inherit error)) "An adapter's important message." :group 'drgnx-debug-console)
(defface drgnx-debug-console-console '((t :inherit shadow)) "The adapter's own messages." :group 'drgnx-debug-console)
(defface drgnx-debug-console-input '((t :inherit font-lock-keyword-face)) "What was evaluated." :group 'drgnx-debug-console)
(defface drgnx-debug-console-result '((t :inherit default)) "An evaluation's result." :group 'drgnx-debug-console)
(defface drgnx-debug-console-logpoint '((t :inherit success)) "A logpoint's message." :group 'drgnx-debug-console)
(defface drgnx-debug-console-source '((t :inherit shadow)) "Where a logpoint's message came from." :group 'drgnx-debug-console)
(defface drgnx-debug-console-count '((t :inherit drgnx-chip-quiet)) "How many times a line came in a row." :group 'drgnx-debug-console)
(defface drgnx-debug-console-stale '((t :inherit shadow)) "A result whose stop is over." :group 'drgnx-debug-console)
(defface drgnx-debug-console-prompt '((t :inherit minibuffer-prompt)) "The input's prompt." :group 'drgnx-debug-console)
(defface drgnx-debug-console-bold '((t :weight bold)) "ANSI bold." :group 'drgnx-debug-console)
(defface drgnx-debug-console-faint '((t :inherit shadow)) "ANSI faint." :group 'drgnx-debug-console)
(defface drgnx-debug-console-italic '((t :slant italic)) "ANSI italic." :group 'drgnx-debug-console)
(defface drgnx-debug-console-underline '((t :underline t)) "ANSI underline." :group 'drgnx-debug-console)
(dolist (c '("black" "red" "green" "yellow" "blue" "magenta" "cyan" "white"))
  (custom-declare-face (intern (format "drgnx-debug-console-%s" c)) `((t :inherit ,(intern (format "ansi-color-%s" c))))
                       (format "ANSI %s." c) :group 'drgnx-debug-console)
  (custom-declare-face (intern (format "drgnx-debug-console-bright-%s" c))
                       `((t :inherit ,(intern (format "ansi-color-bright-%s" c))))
                       (format "ANSI bright %s." c) :group 'drgnx-debug-console))

(defconst drgnx-debug-console-buffer-name "*Debug Console*")
(defconst drgnx-debug-console-prompt "› ")

(defvar-local drgnx-debug-console--end nil "Marker: the end of the output, where the input's prompt starts.")
(defvar-local drgnx-debug-console--lines 0 "How many lines the output holds.")
(defvar-local drgnx-debug-console--last nil "The last output line's start (a marker) and its count: (MARKER . COUNT).")
(defvar-local drgnx-debug-console--history nil "What was evaluated, newest first.")
(defvar-local drgnx-debug-console--history-at -1 "The history entry the input shows (-1: the one being typed).")
(defvar drgnx-debug-console--names nil
  "Alist (SESSION . NAME) of the sessions whose output the console holds, to clear it when NAME starts again.")

(defvar-keymap drgnx-debug-console-mode-map
  :doc "The debug console's keys; the profiles add theirs (`debug-console-*' in keys/*.eld)."
  "RET" #'drgnx-debug-console-send
  "S-<return>" #'drgnx-debug-console-newline
  "TAB" #'drgnx-debug-console-toggle)

(define-derived-mode drgnx-debug-console-mode fundamental-mode "Debug Console"
  "The debug console: the program's and the adapter's output, and an input at the bottom (RET evaluates it in the
selected frame, S-RET adds a line)."
  (setq-local truncate-lines nil)
  (setq-local header-line-format '(:eval (drgnx-debug-console--header)))
  (setq-local completion-at-point-functions (list #'drgnx-debug-console-complete-at-point))
  (buffer-disable-undo))

(defun drgnx-debug-console--header ()
  "The header: the session the input evaluates in (a click picks another)."
  (let ((s (and (fboundp 'drgnx-debug--session) (drgnx-debug--session))))
    (concat " "
            (if s
                (propertize (format " %s ▾ " (plist-get s :name)) 'face 'drgnx-chip-quiet 'mouse-face 'highlight
                            'help-echo "Pick the session the console evaluates in"
                            'keymap (let ((m (make-sparse-keymap)))
                                      (define-key m [header-line mouse-1] #'drgnx-debug-console-pick-session) m))
              (propertize "No debug session" 'face 'shadow)))))

(defun drgnx-debug-console-pick-session ()
  "Pick the session the console (and the toolbar) acts on."
  (interactive)
  (when (fboundp 'drgnx-debug-pick-session) (call-interactively #'drgnx-debug-pick-session)))

(defun drgnx-debug-console--buffer ()
  "The console's buffer, made the first time with its prompt."
  (or (get-buffer drgnx-debug-console-buffer-name)
      (with-current-buffer (generate-new-buffer drgnx-debug-console-buffer-name t)
        (drgnx-debug-console-mode)
        (setq drgnx-debug-console--end (copy-marker (point-min)))
        (drgnx-debug-console--prompt)
        (current-buffer))))

(defun drgnx-debug-console--prompt ()
  "The input's prompt after the output: read-only, not to be typed before."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char drgnx-debug-console--end)
      (insert (propertize drgnx-debug-console-prompt 'face 'drgnx-debug-console-prompt 'read-only t
                          'rear-nonsticky t 'front-sticky '(read-only) 'drgnx-debug-console-prompt t)))))

(defun drgnx-debug-console--input-start ()
  "Where the input's text starts."
  (+ drgnx-debug-console--end (length drgnx-debug-console-prompt)))

(defun drgnx-debug-console--category-face (category)
  "The face of a line of CATEGORY."
  (pcase category
    ("stderr" 'drgnx-debug-console-stderr) ("important" 'drgnx-debug-console-important)
    ("console" 'drgnx-debug-console-console) ("input" 'drgnx-debug-console-input)
    ("result" 'drgnx-debug-console-result) ("logpoint" 'drgnx-debug-console-logpoint)))

(defun drgnx-debug-console--text (line)
  "LINE (a plist of the hub's line) as the text to insert, faces and node included, without its newline."
  (let* ((text (copy-sequence (plist-get line :text))) (node (plist-get line :node))
         (face (if (plist-get line :source) 'drgnx-debug-console-logpoint
                 (drgnx-debug-console--category-face (plist-get line :category))))
         (lead (concat (make-string (* 2 (or (plist-get line :depth) 0)) ?\s) (if node "▸ " ""))))
    (pcase-dolist (`(,from ,to ,face) (plist-get line :runs)) ; the hub's (FROM TO FACE), in characters
      (add-face-text-property from to (intern face) t text))
    (when face (add-face-text-property 0 (length text) face t text))
    (concat (propertize lead 'drgnx-debug-console-node node)
            (if node (propertize text 'drgnx-debug-console-node node 'mouse-face 'highlight) text)
            (if-let* ((src (plist-get line :source)))
                (propertize (format "  %s:%s" (file-name-nondirectory (plist-get src :path)) (plist-get src :line))
                            'face 'drgnx-debug-console-source)
              ""))))

(defun drgnx-debug-console--count-text (n)
  (if (> n 1) (propertize (format " ×%d" n) 'face 'drgnx-debug-console-count 'drgnx-debug-console-count t) ""))

(defun drgnx-debug-console--insert (lines &optional skipped)
  "LINES (the hub's, plists) at the end of the output; SKIPPED lines the hub dropped are said first.  Past
`drgnx-debug-console-max-lines' the oldest go."
  (with-current-buffer (drgnx-debug-console--buffer)
    (let ((inhibit-read-only t)
          (windows (seq-filter (lambda (w) (>= (window-point w) (drgnx-debug-console--input-start)))
                               (get-buffer-window-list nil nil t))))
      (save-excursion
        (when (and skipped (> skipped 0))
          (drgnx-debug-console--line (list :text (format "%d lines skipped" skipped) :category "console")))
        (dolist (l lines)
          (if (and (plist-get l :more) drgnx-debug-console--last)
              (drgnx-debug-console--recount (+ (cdr drgnx-debug-console--last) (or (plist-get l :count) 1)))
            (drgnx-debug-console--line l)))
        (drgnx-debug-console--trim))
      (dolist (w windows) (set-window-point w (point-max))))))

(defun drgnx-debug-console--line (line)
  "One LINE inserted at the output's end."
  (goto-char drgnx-debug-console--end)
  (let ((start (point)) (n (or (plist-get line :count) 1)))
    (insert (drgnx-debug-console--text line) (drgnx-debug-console--count-text n) "\n")
    (put-text-property start (point) 'read-only t)
    (set-marker drgnx-debug-console--end (point))
    (when drgnx-debug-console--last (set-marker (car drgnx-debug-console--last) nil))
    (setq drgnx-debug-console--last (cons (copy-marker start) n))
    (cl-incf drgnx-debug-console--lines)))

(defun drgnx-debug-console--recount (n)
  "The last line stands for N lines now."
  (let ((start (car drgnx-debug-console--last)))
    (goto-char start)
    (let* ((eol (line-end-position))
           (old (text-property-any start eol 'drgnx-debug-console-count t)))
      (when old (delete-region old eol))
      (goto-char (line-end-position))
      (insert (propertize (drgnx-debug-console--count-text n) 'read-only t)))
    (setcdr drgnx-debug-console--last n)))

(defun drgnx-debug-console--trim ()
  "The oldest lines past `drgnx-debug-console-max-lines' go."
  (when (> drgnx-debug-console--lines drgnx-debug-console-max-lines)
    (goto-char (point-min))
    (forward-line (- drgnx-debug-console--lines drgnx-debug-console-max-lines))
    (delete-region (point-min) (point))
    (setq drgnx-debug-console--lines drgnx-debug-console-max-lines)))

(defun drgnx-debug-console-clear ()
  "Clear the console's output (the input stays)."
  (interactive)
  (with-current-buffer (drgnx-debug-console--buffer)
    (let ((inhibit-read-only t))
      (delete-region (point-min) drgnx-debug-console--end)
      (setq drgnx-debug-console--lines 0)
      (when drgnx-debug-console--last (set-marker (car drgnx-debug-console--last) nil))
      (setq drgnx-debug-console--last nil))))

(defun drgnx-debug-console-output (data)
  "A `debug-output' event's DATA: its lines inserted, its session remembered by name."
  (let* ((id (plist-get data :session)) (lines (append (plist-get data :lines) nil)))
    (when-let* ((s (seq-find (lambda (s) (equal (plist-get s :id) id)) drgnx-debug--sessions)))
      (setf (alist-get id drgnx-debug-console--names nil nil #'equal) (plist-get s :name)))
    ;; a structured value opens in its session's stop
    (dolist (l lines)
      (when-let* ((node (plist-get l :node))) (plist-put l :node (plist-put node :session id))))
    (drgnx-debug-console--insert lines (plist-get data :skipped))))

(defun drgnx-debug-console-sessions (sessions)
  "The sessions now (`debug-state'): a configuration started again while its last run is over clears the console."
  (when drgnx-debug-console-clear-on-restart
    (let* ((live (mapcar (lambda (s) (plist-get s :id)) sessions))
           (fresh (seq-remove (lambda (s) (assoc (plist-get s :id) drgnx-debug-console--names)) sessions)))
      (when (and fresh (get-buffer drgnx-debug-console-buffer-name)
                 (seq-some (lambda (s) (rassoc (plist-get s :name) drgnx-debug-console--names)) fresh)
                 (not (seq-some (lambda (e) (member (car e) live)) drgnx-debug-console--names)))
        (drgnx-debug-console-clear)
        (setq drgnx-debug-console--names nil))
      (dolist (s fresh)
        (push (cons (plist-get s :id) (plist-get s :name)) drgnx-debug-console--names)))))

(defun drgnx-debug-console--input ()
  (buffer-substring-no-properties (drgnx-debug-console--input-start) (point-max)))

(defun drgnx-debug-console--set-input (text)
  (let ((inhibit-read-only t))
    (delete-region (drgnx-debug-console--input-start) (point-max))
    (goto-char (point-max))
    (insert text)))

(defun drgnx-debug-console-send ()
  "Evaluate the input in the selected frame of the console's session; on an expandable result, open it."
  (interactive)
  (if (< (point) (drgnx-debug-console--input-start))
      (drgnx-debug-console-toggle)
    (let ((expr (string-trim (drgnx-debug-console--input))) (s (drgnx-debug--session)))
      (cond ((string-empty-p expr))
            ((not s) (user-error "No debug session to evaluate in"))
            (t (drgnx-debug-console--set-input "")
               (drgnx-debug-console--evaluate s expr))))))

(defun drgnx-debug-console--evaluate (session expr)
  "Evaluate EXPR in SESSION's selected frame (`repl') as if typed: echoed, kept in the history, answered below."
  (with-current-buffer (drgnx-debug-console--buffer)
    (push expr drgnx-debug-console--history)
    (setq drgnx-debug-console--history-at -1)
    (drgnx-debug-console--insert (list (list :text expr :category "input")))
    (drgnx-hub-call "debug/evaluate" (list :session (plist-get session :id) :expr expr :context "repl")
                    (drgnx-debug-console--answer (plist-get session :id)))))

(defun drgnx-debug-console-evaluate (expr &optional select)
  "Evaluate EXPR in the Debug Console, in the stopped frame, keeping what its input holds; its tab shows without
taking the focus, or selected with SELECT."
  (let ((s (or (drgnx-debug--session) (user-error "No debug session to evaluate in")))
        (b (drgnx-debug-console--buffer)))
    (let ((w (if (fboundp 'drgnx-wb-area-show)
                 (save-selected-window (drgnx-wb-area-show 'panel 'debug-console b))
               (display-buffer b))))
      (drgnx-debug-console--evaluate s expr)
      (when (and select w) (select-window w)))))

(defun drgnx-debug-console-complete-at-point ()
  "Completion in the input from the session's adapter (`debug/completions'): the span a target names, else the
word before point; nil outside the input, with no session, or when the adapter has none."
  (when-let* (((>= (point) (drgnx-debug-console--input-start)))
              (s (drgnx-debug--session))
              (start (drgnx-debug-console--input-start))
              (r (condition-case nil
                     (drgnx-hub-call-sync "debug/completions"
                                          (list :session (plist-get s :id) :text (drgnx-debug-console--input)
                                                :column (- (point) start))
                                          2)
                   (error nil)))
              (targets (append (plist-get r :targets) nil)))
    (let* ((first (car targets))
           (beg (if (plist-get first :start) (+ start (plist-get first :start))
                  (save-excursion (skip-syntax-backward "w_" start) (point))))
           (end (if (plist-get first :length) (min (point-max) (+ beg (plist-get first :length))) (point)))
           (types (mapcar (lambda (tg) (cons (or (plist-get tg :text) (plist-get tg :label)) (plist-get tg :type)))
                          targets)))
      (list beg end (mapcar #'car types)
            :exclusive 'no
            :annotation-function (lambda (c) (when-let* ((ty (cdr (assoc c types)))) (concat " " ty)))))))

(defun drgnx-debug-console--answer (session)
  "The callback that inserts an evaluation's answer in SESSION."
  (lambda (result error)
    (drgnx-debug-console--insert
     (list (if error (list :text (format "%s" error) :category "stderr")
             (list :text (plist-get result :result) :category "result"
                   :node (and (plist-get result :reference)
                              (list :session session :reference (plist-get result :reference)
                                    :epoch (plist-get result :epoch)))))))))

(defun drgnx-debug-console-newline ()
  "Add a line to the input."
  (interactive)
  (when (>= (point) (drgnx-debug-console--input-start)) (insert "\n")))

(defun drgnx-debug-console-history-previous ()
  "The input before this one; in the output, the line above."
  (interactive)
  (cond
   ((< (point) (drgnx-debug-console--input-start)) (forward-line -1))
   ((< (1+ drgnx-debug-console--history-at) (length drgnx-debug-console--history))
    (cl-incf drgnx-debug-console--history-at)
    (drgnx-debug-console--set-input (nth drgnx-debug-console--history-at drgnx-debug-console--history)))))

(defun drgnx-debug-console-history-next ()
  "The input after this one (the empty one after the newest); in the output, the line below."
  (interactive)
  (cond
   ((< (point) (drgnx-debug-console--input-start)) (forward-line 1))
   ((>= drgnx-debug-console--history-at 0)
    (cl-decf drgnx-debug-console--history-at)
    (drgnx-debug-console--set-input (if (< drgnx-debug-console--history-at 0) ""
                                      (nth drgnx-debug-console--history-at drgnx-debug-console--history))))))

(defun drgnx-debug-console-toggle ()
  "Open the structured value at point in place (its children below it), or close it.  A value of a stop that is over
does not open."
  (interactive)
  (let ((node (get-text-property (point) 'drgnx-debug-console-node)))
    (unless node (user-error "Nothing to open here"))
    (let ((bol (line-beginning-position)) (eol (line-end-position)))
      (if (get-text-property bol 'drgnx-debug-console-open)
          (drgnx-debug-console--close bol)
        (drgnx-hub-call "debug/children" (list :session (plist-get node :session) :reference (plist-get node :reference)
                                               :epoch (plist-get node :epoch))
                        (drgnx-debug-console--children (copy-marker bol) (copy-marker eol) node))))))

(defun drgnx-debug-console--depth (bol)
  "The depth of the line at BOL (its leading spaces, two a level)."
  (save-excursion (goto-char bol) (/ (skip-chars-forward " ") 2)))

(defun drgnx-debug-console--children (bol eol node)
  "The callback that inserts NODE's children under its line (BOL to EOL), or marks it stale."
  (lambda (result error)
    (with-current-buffer (marker-buffer bol)
      (let ((inhibit-read-only t) (depth (1+ (drgnx-debug-console--depth bol))))
        (save-excursion
          (if error
              (progn (add-face-text-property bol eol 'drgnx-debug-console-stale)
                     (put-text-property bol eol 'drgnx-debug-console-node nil)
                     (message "Debug Console: %s" error))
            (goto-char bol)
            (when (looking-at "\\( *\\)▸") (replace-match "\\1▾" t nil nil 0))
            (put-text-property bol (1+ bol) 'drgnx-debug-console-open t)
            (goto-char (1+ eol))
            (dolist (v (append (plist-get result :variables) nil))
              (let ((start (point)))
                ;; at the output's end, the end marker moves past the child
                (funcall (if (= (point) drgnx-debug-console--end) #'insert-before-markers #'insert)
                         (drgnx-debug-console--text
                          (list :text (format "%s: %s" (plist-get v :name) (plist-get v :value)) :depth depth
                                :node (and (plist-get v :reference)
                                           (list :session (plist-get node :session) :reference (plist-get v :reference)
                                                 :epoch (plist-get node :epoch)))))
                         "\n")
                (put-text-property start (point) 'read-only t)
                (put-text-property start (point) 'drgnx-debug-console-child depth)
                (cl-incf drgnx-debug-console--lines))))))
      (set-marker bol nil) (set-marker eol nil))))

(defun drgnx-debug-console--close (bol)
  "Close the open value at BOL: the lines below it deeper than it go."
  (let ((inhibit-read-only t) (depth (drgnx-debug-console--depth bol)))
    (save-excursion
      (goto-char bol)
      (when (looking-at "\\( *\\)▾") (replace-match "\\1▸" t nil nil 0))
      (put-text-property bol (1+ bol) 'drgnx-debug-console-open nil)
      (forward-line 1)
      (let ((start (point)))
        (while (and (< (point) drgnx-debug-console--end)
                    (when-let* ((d (get-text-property (point) 'drgnx-debug-console-child))) (> d depth)))
          (forward-line 1)
          (cl-decf drgnx-debug-console--lines))
        (delete-region start (point))))))

(defun drgnx-debug-console-show ()
  "Show the Debug Console tab of the panel and put point in its input."
  (interactive)
  (let ((b (drgnx-debug-console--buffer)))
    (if (fboundp 'drgnx-wb-area-show)
        (select-window (drgnx-wb-area-show 'panel 'debug-console b))
      (pop-to-buffer b))
    (goto-char (point-max))))

(defun drgnx-debug-console--teardown ()
  "The console's buffer goes with the module."
  (setq drgnx-debug-console--names nil)
  (when-let* ((b (get-buffer drgnx-debug-console-buffer-name))) (kill-buffer b)))

(defconst drgnx-debug-console-commands
  '((debug-console "Show Debug Console" drgnx-debug-console-show "Show the panel's Debug Console and type in it")
    (debug-console-clear "Clear Console" drgnx-debug-console-clear "Clear the debug console's output")
    (debug-console-history-previous "Debug Console: Previous Input" drgnx-debug-console-history-previous
                                    "The input evaluated before this one")
    (debug-console-history-next "Debug Console: Next Input" drgnx-debug-console-history-next
                                "The input evaluated after this one"))
  "The console's commands, for the module's setup: (ID TITLE FUNCTION DOC); the history ones are keys of the console.")

(provide 'drgnx-debug-console)
;;; drgnx-debug-console.el ends here
