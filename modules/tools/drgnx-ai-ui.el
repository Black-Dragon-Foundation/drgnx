;;; drgnx-ai-ui.el --- Module tools/ai: ghost-text completion and the Tab arbiter -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Ghost text: a pause in a code buffer asks the `complete' role to fill in the middle (the text before and after
;; point); the answer shows after point, dimmed, only if nothing moved or changed meanwhile, and any other command
;; clears it.  Accept it whole (Tab), a word (C-<right>, bound only while it shows) or a line; C-g dismisses it (Escape stays Meta).
;; Tab is one arbiter: a suggestion → accept; a completion popup → its own Tab; a snippet field → the next field;
;; an org/outline heading → cycle; otherwise indent.  See docs/guide/ai.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-ai)
(require 'drgnx-ai-client)
(require 'drgnx-ai-probe)
(require 'diff)
(require 'diff-mode)

(defface drgnx-ai-ghost '((t :inherit shadow)) "A suggestion not yet accepted." :group 'drgnx)

(defvar drgnx-ai-ghost-delay 0.3 "Seconds of pause before a suggestion is asked for.")
(defvar drgnx-ai-ghost-before 2000 "Characters before point the model sees.")
(defvar drgnx-ai-ghost-after 1000 "Characters after point the model sees.")
(defvar drgnx-ai-ghost-max-tokens 64 "How long a suggestion may be.")

(defvar-local drgnx-ai-ghost--text nil "The suggestion still to accept.")
(defvar-local drgnx-ai-ghost--overlay nil)
(defvar-local drgnx-ai-ghost--tick nil "`buffer-chars-modified-tick' when the suggestion was shown.")
(defvar-local drgnx-ai-ghost--request nil "The request in flight.")
(defvar-local drgnx-ai-ghost--showing nil "Non-nil while a suggestion shows: its keys are active.")
(defvar drgnx-ai-ghost--timer nil)
(defvar drgnx-ai-ghost-mode)                            ; the minor mode, defined below
(defvar drgnx-ai-ghost--said-unavailable nil "Told once this session that no provider completes.")
(defvar drgnx-ai-ghost--last-probe 0 "When a pause with no provider last asked the probe to look again.")

(defvar drgnx-ai-ghost-showing-map (make-sparse-keymap) "Keys active only while a suggestion shows.")
(defvar drgnx-ai-ghost--emulation (list (cons 'drgnx-ai-ghost--showing drgnx-ai-ghost-showing-map)))
(add-to-list 'emulation-mode-map-alists 'drgnx-ai-ghost--emulation)

(defvar drgnx-ai-ghost-mode-map (make-sparse-keymap) "Keys of buffers with ghost text (Tab: `drgnx-ai-tab').")

;;;; Showing

(defun drgnx-ai-ghost-text () "The suggestion showing, or nil." drgnx-ai-ghost--text)

(defun drgnx-ai-ghost-text-shown ()
  "The suggestion as it shows (with its face), or nil."
  (and drgnx-ai-ghost--overlay (overlay-get drgnx-ai-ghost--overlay 'after-string)))

(defun drgnx-ai-ghost--clear ()
  (when drgnx-ai-ghost--overlay (delete-overlay drgnx-ai-ghost--overlay))
  (setq drgnx-ai-ghost--overlay nil drgnx-ai-ghost--text nil drgnx-ai-ghost--showing nil))

(defun drgnx-ai-ghost--show (text)
  "Show TEXT as a suggestion at point."
  (drgnx-ai-ghost--clear)
  (unless (string-empty-p text)
    (setq drgnx-ai-ghost--text text drgnx-ai-ghost--showing t drgnx-ai-ghost--tick (buffer-chars-modified-tick)
          drgnx-ai-ghost--overlay (make-overlay (point) (point) nil nil t))
    (overlay-put drgnx-ai-ghost--overlay 'after-string
                 (concat (propertize (substring text 0 1) 'cursor 1 'face 'drgnx-ai-ghost)
                         (propertize (substring text 1) 'face 'drgnx-ai-ghost)))))

;;;; Asking

(defun drgnx-ai-ghost--available-p ()
  "Some provider of the `complete' role can be asked: found running here, or remote with its key."
  (seq-some (lambda (step) (drgnx-ai-usable-p (car step) 'fim)) (drgnx-ai-role 'complete)))

(defun drgnx-ai-ghost--keyless ()
  "The first provider of the `complete' role that needs a key and has none loaded (the background never reads the
Keychain or the keyring), or nil."
  (car (seq-find (lambda (step) (and (plist-get (drgnx-ai-provider (car step)) :key-env) (not (drgnx-ai-key (car step)))))
                 (drgnx-ai-role 'complete))))

(defun drgnx-ai-ghost--typing-p ()
  "Non-nil unless evil is on and this buffer is in a state that does not type (normal, visual, …)."
  (or (not (bound-and-true-p evil-local-mode)) (memq (bound-and-true-p evil-state) '(insert emacs))))

(defun drgnx-ai-ghost--trigger ()
  "Ask for a suggestion at point (the pause has come).  Says once when no provider completes."
  (when (and drgnx-ai-ghost-mode (not buffer-read-only) (drgnx-ai-ghost--typing-p))
    (if (not (drgnx-ai-ghost--available-p))
        (progn
          (unless drgnx-ai-ghost--said-unavailable
            (setq drgnx-ai-ghost--said-unavailable t)
            (if-let* ((id (drgnx-ai-ghost--keyless)))
                (message "AI completion: no key for %s loaded — AI: Load Keys reads your key from %s" id
                         (if (eq (drgnx-platform) 'macos) "the Keychain" "your keyring"))
              (message "AI completion: no provider for `complete' is running (AI: Choose Provider/Model)")))
          ;; a runner started since: looked for at most once a minute (in the background)
          (when (> (- (float-time) drgnx-ai-ghost--last-probe) 60)
            (setq drgnx-ai-ghost--last-probe (float-time))
            (drgnx-ai-probe nil)))
      (when drgnx-ai-ghost--request (drgnx-ai-cancel drgnx-ai-ghost--request))
      (let ((buf (current-buffer)) (tick (buffer-chars-modified-tick)) (pt (point)))
        (setq drgnx-ai-ghost--request
              (drgnx-ai-request 'complete 'fim
                                (list :prefix (buffer-substring-no-properties (max (point-min) (- pt drgnx-ai-ghost-before)) pt)
                                      :suffix (buffer-substring-no-properties pt (min (point-max) (+ pt drgnx-ai-ghost-after)))
                                      :max-tokens drgnx-ai-ghost-max-tokens)
                                (lambda (text _info)
                                  (when (and text (buffer-live-p buf))
                                    (with-current-buffer buf
                                      (setq drgnx-ai-ghost--request nil)
                                      ;; only if nothing changed or moved since the question
                                      (when (and drgnx-ai-ghost-mode (= tick (buffer-chars-modified-tick)) (= pt (point)))
                                        (drgnx-ai-ghost--show (string-trim-right text))))))
                                :timeout 5))))))

(defconst drgnx-ai-ghost--keep-commands
  '(drgnx-ai-accept drgnx-ai-accept-word drgnx-ai-accept-line drgnx-ai-tab)
  "Commands that work with a suggestion rather than clear it.")

(defun drgnx-ai-ghost--post-command ()
  "After a command: anything but accepting clears the suggestion and the question in flight; a new pause asks."
  (unless (memq this-command drgnx-ai-ghost--keep-commands)
    (drgnx-ai-ghost--clear)
    (when drgnx-ai-ghost--request (drgnx-ai-cancel drgnx-ai-ghost--request) (setq drgnx-ai-ghost--request nil)))
  (when (timerp drgnx-ai-ghost--timer) (cancel-timer drgnx-ai-ghost--timer))
  (when (and drgnx-ai-ghost-mode (not drgnx-ai-ghost--text))
    (let ((buf (current-buffer)))
      (setq drgnx-ai-ghost--timer
            (run-with-idle-timer drgnx-ai-ghost-delay nil
                                 ;; the buffer on screen, whatever is current (the timer may fire inside a wait)
                                 (lambda () (when (and (buffer-live-p buf) (eq buf (window-buffer (selected-window))))
                                              (with-current-buffer buf
                                                (with-demoted-errors "AI completion: %S" (drgnx-ai-ghost--trigger))))))))))

(define-minor-mode drgnx-ai-ghost-mode
  "Ghost-text completion from the `complete' role; Tab is `drgnx-ai-tab'."
  :lighter nil :keymap drgnx-ai-ghost-mode-map
  (if drgnx-ai-ghost-mode
      (add-hook 'post-command-hook #'drgnx-ai-ghost--post-command nil t)
    (remove-hook 'post-command-hook #'drgnx-ai-ghost--post-command t)
    (drgnx-ai-ghost--clear)))

(defvar drgnx-ai-complete-enabled t "Non-nil: ghost text in code buffers (AI: Toggle Completion).")

(defun drgnx-ai-ghost--maybe-enable ()
  (when drgnx-ai-complete-enabled (drgnx-ai-ghost-mode 1)))

;;;; Accepting

(defun drgnx-ai-ghost--stale-p ()
  "Non-nil (and the suggestion dropped) when the buffer changed since it was shown: a revert, an agent or a
process changed it and no command cleared the suggestion."
  (when (and drgnx-ai-ghost--text (not (eql drgnx-ai-ghost--tick (buffer-chars-modified-tick))))
    (drgnx-ai-ghost--clear)
    t))

(defun drgnx-ai--accept-part (n)
  "Insert the first N characters of the suggestion; the rest keeps showing."
  (let ((text (and (not (drgnx-ai-ghost--stale-p)) drgnx-ai-ghost--text)))
    (when text
      (drgnx-ai-ghost--clear)
      (insert (substring text 0 n))
      (drgnx-ai-ghost--show (substring text n)))))

(defun drgnx-ai-accept ()
  "Insert the whole suggestion."
  (interactive)
  (when drgnx-ai-ghost--text (drgnx-ai--accept-part (length drgnx-ai-ghost--text))))

(defun drgnx-ai-accept-word ()
  "Insert the suggestion's next word."
  (interactive)
  (if (drgnx-ai-ghost--stale-p)
      ;; the key came from the showing map, which no longer applies: do what it does without a suggestion
      (let ((cmd (key-binding [C-right])))
        (call-interactively (if (and cmd (not (eq cmd 'drgnx-ai-accept-word))) cmd #'right-word)))
    (when-let* ((text drgnx-ai-ghost--text))
      (drgnx-ai--accept-part (if (string-match "\\`\\W*\\w+" text) (match-end 0) (length text))))))

(defun drgnx-ai-accept-line ()
  "Insert the suggestion up to its line's end."
  (interactive)
  (when-let* ((text drgnx-ai-ghost--text))
    (drgnx-ai--accept-part (if (string-match "\\`\n?[^\n]*" text) (match-end 0) (length text)))))

(defun drgnx-ai-dismiss ()
  "Drop the suggestion."
  (interactive)
  (drgnx-ai-ghost--clear))

(defun drgnx-ai-complete-toggle ()
  "Turn ghost-text completion on or off (code buffers)."
  (interactive)
  (setq drgnx-ai-complete-enabled (not drgnx-ai-complete-enabled))
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when (derived-mode-p 'prog-mode) (drgnx-ai-ghost-mode (if drgnx-ai-complete-enabled 1 -1)))))
  (message "AI completion %s" (if drgnx-ai-complete-enabled "on" "off")))

;;;; The Tab arbiter

(declare-function org-at-heading-p "org")
(declare-function outline-on-heading-p "outline")

(defun drgnx-ai-tab-command ()
  "What Tab does here: the first of — accept the suggestion; the completion popup's Tab; the next snippet
field; cycle the heading; indent."
  (cond ((and drgnx-ai-ghost--text (not (drgnx-ai-ghost--stale-p))) 'drgnx-ai-accept)
        ((and (bound-and-true-p corfu--frame) (frame-live-p corfu--frame) (frame-visible-p corfu--frame)) 'corfu-complete)
        ((bound-and-true-p company-candidates) 'company-complete-common)
        ((bound-and-true-p completion-in-region-mode) 'completion-at-point)
        ((and (fboundp 'yas-active-snippets) (yas-active-snippets)) 'yas-next-field-or-maybe-expand)
        ((bound-and-true-p tempel--active) 'tempel-next)
        ((and (derived-mode-p 'org-mode) (org-at-heading-p)) 'org-cycle)
        ((and (bound-and-true-p outline-minor-mode) (outline-on-heading-p)) 'outline-cycle)
        (t (drgnx-ai--own-tab))))

(defun drgnx-ai--own-tab ()
  "What Tab does here without ghost text's keys (a mode's own Tab: cperl, octave, ESS…), else indent."
  (let* ((drgnx-ai-ghost-mode nil) (drgnx-ai-ghost--showing nil)
         (cmd (or (key-binding [tab]) (key-binding (kbd "TAB")))))
    (if (and cmd (symbolp cmd) (not (eq cmd 'drgnx-ai-tab))) cmd 'indent-for-tab-command)))

(defun drgnx-ai-tab ()
  "Tab: accept a suggestion, else the popup's, the snippet's, the heading's or the indent Tab."
  (interactive)
  (let ((cmd (drgnx-ai-tab-command)))
    (setq this-command cmd)
    (call-interactively cmd)))

;;;; Stopping a request

(defvar drgnx-ai--active nil
  "Entries (STOPPER) of the Edit with AI and Ask the Codebase requests in flight; STOPPER is a function that
cancels one.  An entry leaves when its request answers or is stopped.")

(defun drgnx-ai--track (start)
  "Call START with a function DONE (call it when the request ends); START returns a function that stops the
request.  Until DONE is called or `drgnx-ai-stop' runs, the request is in `drgnx-ai--active'."
  (let* ((entry (list nil))
         (done (lambda () (setq drgnx-ai--active (delq entry drgnx-ai--active)))))
    (push entry drgnx-ai--active)
    ;; a start that signals leaves nothing stoppable behind
    (condition-case err
        (setcar entry (funcall start done))
      (error (funcall done) (signal (car err) (cdr err))))
    entry))

(defun drgnx-ai-stop ()
  "Stop the Edit with AI and Ask the Codebase requests in flight: their answers never arrive."
  (interactive)
  (let ((entries drgnx-ai--active))
    (setq drgnx-ai--active nil)
    (dolist (e entries) (when (functionp (car e)) (funcall (car e))))
    (if entries
        (message "AI: stopped %d request%s" (length entries) (if (cdr entries) "s" ""))
      (message "AI: nothing to stop"))))

;;;; Inline edit, reviewed hunk by hunk

(defconst drgnx-ai-edit-system
  "You edit code.  Rewrite the code you are given as the instruction says.  Answer with the complete replacement code
only: no explanation, no Markdown fence."
  "What the `edit' role is told.")

(defvar-local drgnx-ai--edit nil
  "In a review: (:buffer :start :end :old :prefix :suffix :copy :dir) — the region's markers, its text when the
answer came, how much of the copy is before and after it, the copy that takes the hunks you apply.")

(defvar drgnx-ai-edit-review-mode-map (make-sparse-keymap)
  "Keys come from the key profiles (commands `ai-edit-apply-hunk', `ai-edit-done', `ai-edit-reject').")

(define-minor-mode drgnx-ai-edit-review-mode
  "An AI edit: apply the hunks you want (C-c C-a), then Done puts them in the buffer; Reject drops it."
  :lighter " AI-Review")

(defun drgnx-ai--strip-fence (text)
  "TEXT without the Markdown fence (and the words around it) a model may wrap code in."
  (if (string-match "```[^\n]*\n\\(\\(?:.\\|\n\\)*?\\)\n?```" text) (match-string 1 text) text))

(defun drgnx-ai-edit (instruction start end)
  "Edit the region START..END (the defun at point without a region) as INSTRUCTION says; review the answer
hunk by hunk before anything changes."
  (interactive
   (let ((b (if (use-region-p) (cons (region-beginning) (region-end))
              (or (bounds-of-thing-at-point 'defun) (cons (line-beginning-position) (line-end-position))))))
     (list (read-string "Edit with AI: ") (car b) (cdr b))))
  (let* ((buf (current-buffer))
         ;; text typed right at either edge stays outside the region
         (s (copy-marker start t)) (e (copy-marker end))
         (text (buffer-substring-no-properties start end)))
    (message "AI edit: asking…")
    (drgnx-ai--track
     (lambda (done)
       (let ((h (drgnx-ai-request
                 'edit 'chat
                 (list :messages (vector (list :role "system" :content drgnx-ai-edit-system)
                                         (list :role "user" :content (format "Instruction: %s\n\nCode:\n%s" instruction text))))
                 (lambda (answer info)
                   (funcall done)
                   (cond
                    ((not answer) (message "AI edit: no answer (%s)" (plist-get info :error)))
                    ((not (buffer-live-p buf)))
                    ;; the answer rewrites the text that was sent: if that changed meanwhile, the review would
                    ;; drop the newer edits
                    ((not (equal (with-current-buffer buf (buffer-substring-no-properties s e)) text))
                     (message "AI edit: the region changed while the model answered; run Edit with AI again"))
                    (t (let ((new (drgnx-ai--strip-fence answer)))
                         (when (and (string-suffix-p "\n" text) (not (string-suffix-p "\n" new))) (setq new (concat new "\n")))
                         (drgnx-ai--edit-review buf s e new)))))
                 :interactive t)))
         (lambda () (drgnx-ai-cancel h)))))))

(defun drgnx-ai--edit-review (buf start end new)
  "Show NEW for BUF's region START..END (markers) as a diff against a copy of BUF as it is now."
  (let* ((cur (with-current-buffer buf (buffer-substring-no-properties (point-min) (point-max))))
         (s (with-current-buffer buf (- start (point-min)))) (e (with-current-buffer buf (- end (point-min))))
         (dir (make-temp-file "drgnx-ai-edit" t))
         (copy (expand-file-name (concat "now-" (file-name-nondirectory (or (buffer-file-name buf) "buffer"))) dir))
         (proposed (expand-file-name "proposed" dir)))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region cur nil copy nil 'silent)
      (write-region (concat (substring cur 0 s) new (substring cur e)) nil proposed nil 'silent))
    (let* ((out (generate-new-buffer (format "*AI edit: %s*" (buffer-name buf))))   ; its own: a second edit of this buffer
           (review (condition-case err                                              ; must not take this one's (and its dir)
                       (diff-no-select copy proposed "-u" t out)
                     (error (kill-buffer out) (ignore-errors (delete-directory dir t)) (signal (car err) (cdr err))))))
      (delete-file proposed)
      (with-current-buffer review
        (drgnx-ai-edit-review-mode 1)
        (setq drgnx-ai--edit (list :buffer buf :start start :end end :old (substring cur s e)
                                   :prefix s :suffix (- (length cur) e) :copy copy :dir dir))
        (setq header-line-format " AI edit of %s  (C-c C-a apply a hunk · C-c C-c done · C-c C-k reject)")
        (setq header-line-format (format header-line-format (buffer-name buf)))
        (add-hook 'kill-buffer-hook #'drgnx-ai--edit-cleanup nil t))
      (pop-to-buffer review)
      review)))

(defun drgnx-ai--edit-cleanup ()
  "The review goes: its copy and temporary files too (nothing reaches the buffer)."
  (when drgnx-ai--edit
    (let ((copy (plist-get drgnx-ai--edit :copy)) (dir (plist-get drgnx-ai--edit :dir)))
      (setq drgnx-ai--edit nil)
      (when-let* ((cb (find-buffer-visiting copy))) (with-current-buffer cb (set-buffer-modified-p nil)) (kill-buffer cb))
      (ignore-errors (delete-directory dir t)))))

(defun drgnx-ai-edit-apply-hunk ()
  "Apply the hunk at point to the review's copy; the review stays on screen (diff's own apply shows the copy)."
  (interactive)
  (unless drgnx-ai--edit (user-error "Not an AI edit"))
  (let ((pt (point)) (copy (plist-get drgnx-ai--edit :copy)))
    ;; the copy is only text for diff to patch: visited without its mode (and the hooks that start with it)
    (unless (find-buffer-visiting copy)
      (let ((auto-mode-alist nil) (interpreter-mode-alist nil) (magic-mode-alist nil) (magic-fallback-mode-alist nil)
            (enable-local-variables nil))
        (find-file-noselect copy)))
    (save-window-excursion (diff-apply-hunk))
    (goto-char pt)))

(defun drgnx-ai-edit-done ()
  "Put the hunks you applied into the buffer's region; edits made elsewhere meanwhile stay.  Refuses when the
region itself changed since the answer came."
  (interactive)
  (let* ((ed (or drgnx-ai--edit (user-error "Not an AI edit")))
         (buf (plist-get ed :buffer)) (start (plist-get ed :start)) (end (plist-get ed :end))
         (copy (plist-get ed :copy)) (cb (find-buffer-visiting copy))
         (text (if cb (with-current-buffer cb (buffer-substring-no-properties (point-min) (point-max)))
                 (with-temp-buffer (insert-file-contents copy) (buffer-string))))
         (middle (substring text (plist-get ed :prefix) (- (length text) (plist-get ed :suffix)))))
    (unless (buffer-live-p buf) (user-error "The buffer is gone"))
    (with-current-buffer buf
      (unless (equal (buffer-substring-no-properties start end) (plist-get ed :old))
        (user-error "The region changed since the answer: run Edit with AI again"))
      (save-excursion (goto-char start) (delete-region start end) (insert middle)))
    (kill-buffer (current-buffer))))

(defun drgnx-ai-edit-reject ()
  "Drop the AI edit: the buffer stays as it is."
  (interactive)
  (unless drgnx-ai--edit (user-error "Not an AI edit"))
  (kill-buffer (current-buffer)))

;;;; Ask the Codebase

(defvar drgnx-ai-retrievers (list #'drgnx-ai--grep-retriever)
  "Functions (QUESTION ROOT DONE) that find what a question is about under ROOT and call DONE with snippets
\((:file :line :text)…).  The text search is here; Semantic Search (tools/search) adds its index's retriever
when the project has one.")

(defconst drgnx-ai--stopwords
  '("where" "what" "which" "does" "this" "that" "with" "from" "have" "when" "there" "about" "into" "were" "they"
    "their" "would" "should" "could" "code" "codebase" "file" "files" "work" "works" "used" "uses" "using"))

(defun drgnx-ai--keywords (question)
  "Up to six words of QUESTION worth searching for (four letters or more; a plural's s dropped)."
  (seq-take (delete-dups
             (mapcar (lambda (w) (if (and (> (length w) 4) (string-suffix-p "s" w)) (substring w 0 -1) w))
                     (seq-remove (lambda (w) (member w drgnx-ai--stopwords))
                                 (seq-filter (lambda (w) (>= (length w) 4))
                                             (split-string (downcase question) "[^[:alnum:]_-]+" t)))))
            6))

(defvar drgnx-ai-search-timeout 10
  "Seconds the text search of Ask the Codebase may run before it is cut off (Ask then goes on without context).")

(defconst drgnx-ai--line-max 500 "Longest line of a search hit or an excerpt that goes to the model.")

(defun drgnx-ai--cut-lines (text)
  "TEXT with every line cut to `drgnx-ai--line-max' characters."
  (mapconcat (lambda (l) (if (> (length l) drgnx-ai--line-max) (substring l 0 drgnx-ai--line-max) l))
             (split-string text "\n") "\n"))

(defun drgnx-ai--grep-retriever (question root done)
  "Files under ROOT holding the most of QUESTION's keywords (ripgrep, else grep), a snippet of each, to DONE.
Returns the search process (or nil), so that a stopped Ask can end it.  A search still running after
`drgnx-ai-search-timeout' seconds is killed and DONE gets nil."
  (let* ((kws (drgnx-ai--keywords question))
         (out (generate-new-buffer " *drgnx-ai-grep*" t))
         (cmd (if (executable-find "rg")
                  (append (list "rg" "--no-heading" "--line-number" "--ignore-case" "--max-count" "5" "--max-columns" "300")
                          (seq-mapcat (lambda (k) (list "-e" k)) kws) (list "."))
                ;; as ripgrep does: never a dot file or directory (.env, .git, .authinfo) — what is found goes to a
                ;; model — nor the usual dependency and build trees (ripgrep also reads .gitignore; this cannot).
                ;; find prunes them (".?*": the starting "." itself is searched) and runs grep with options BSD grep
                ;; (macOS) has too: its --exclude/--exclude-dir are not GNU's
                (append (list "find" "." "(" "-name" ".?*" "-o" "-name" "node_modules" "-o" "-name" "vendor"
                              "-o" "-name" "target" "-o" "-name" "dist" "-o" "-name" "build" "-o" "-name" "__pycache__"
                              ")" "-prune" "-o" "-type" "f" "-exec" "grep" "-InHi" "-m" "5")
                        (seq-mapcat (lambda (k) (list "-e" k)) kws) (list "{}" "+")))))
    (if (null kws) (progn (kill-buffer out) (funcall done nil) nil)
      (let* ((default-directory (file-name-as-directory root))
             (timer nil)
             (proc
              (make-process
               :name "drgnx-ai-grep" :buffer out :command cmd :noquery t :connection-type 'pipe
               :sentinel
               (lambda (p _)
                 (unless (process-live-p p)
                   (when (timerp timer) (cancel-timer timer))
                   (let ((hits (make-hash-table :test #'equal)))
                     (with-current-buffer out
                       (goto-char (point-min))
                       (while (and (not (process-get p :cut)) (not (process-get p :dropped))
                                   ;; a hit's text is cut at the line maximum: a minified file is one huge line
                                   (re-search-forward "^\\(?:\\./\\)?\\([^:\n]+\\):\\([0-9]+\\):\\(.\\{0,500\\}\\).*$" nil t))
                         (let* ((file (match-string 1)) (line (string-to-number (match-string 2))) (text (downcase (match-string 3)))
                                (e (or (gethash file hits) (puthash file (list :line line :kws nil) hits))))
                           (dolist (k kws) (when (string-search k text) (cl-pushnew k (plist-get e :kws) :test #'equal)))
                           (puthash file (plist-put e :kws (plist-get e :kws)) hits))))
                     (kill-buffer out)
                     (cond
                      ((process-get p :dropped))                     ; stopped: nobody waits for the answer
                      ((process-get p :cut) (funcall done nil))
                      (t
                       (let ((ranked (seq-take (sort (let (l) (maphash (lambda (f e) (push (cons f e) l)) hits) l)
                                                     (lambda (a b) (> (length (plist-get (cdr a) :kws)) (length (plist-get (cdr b) :kws)))))
                                               5)))
                         (funcall done
                                  (mapcar (lambda (fe)
                                            (let ((line (plist-get (cdr fe) :line)))
                                              (list :file (car fe) :line line
                                                    :text (with-temp-buffer
                                                            (insert-file-contents (expand-file-name (car fe) root) nil 0 2000000)
                                                            (goto-char (point-min)) (forward-line (max 0 (- line 4)))
                                                            (drgnx-ai--cut-lines
                                                             (buffer-substring-no-properties (point) (progn (forward-line 10) (point))))))))
                                          ranked)))))))))))
        (setq timer (run-with-timer drgnx-ai-search-timeout nil
                                    (lambda () (when (process-live-p proc) (process-put proc :cut t) (delete-process proc)))))
        proc))))

(defun drgnx-ai--answer-buffer (question answer snippets root)
  (with-current-buffer (get-buffer-create "*AI answer*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (special-mode)
      (insert (propertize (concat "Q: " question) 'face 'bold) "\n\n" (or answer "") "\n\nSources:\n")
      (dolist (s snippets)
        (insert "  ")
        (insert-text-button (format "%s:%d" (plist-get s :file) (plist-get s :line))
                            'action (let ((f (expand-file-name (plist-get s :file) root)) (l (plist-get s :line)))
                                      (lambda (_) (pop-to-buffer (find-file-noselect f)) (goto-char (point-min)) (forward-line (1- l)))))
        (insert "\n"))
      (goto-char (point-min)))
    (pop-to-buffer (current-buffer))
    (current-buffer)))

(cl-defun drgnx-ai-ask-request (question root callback &key chain interactive)
  "Find what QUESTION is about under ROOT (`drgnx-ai-retrievers') and ask the `chat' role (or CHAIN) with the
snippets found: CALLBACK gets (ANSWER INFO SNIPPETS), ANSWER nil when no provider answered (INFO's :error says
why).  INTERACTIVE as for `drgnx-ai-request'.  Ask the Codebase, and onboarding's test of it.  Returns a function
that stops it (CALLBACK never runs)."
  (let ((left (length drgnx-ai-retrievers)) (snippets nil) (stopped nil) (h nil) (searches nil))
    (dolist (r drgnx-ai-retrievers)
      (push
       (funcall r question root
                (lambda (found)
                  (setq snippets (append snippets found))
                  (when (and (zerop (setq left (1- left))) (not stopped))
                    (setq h (drgnx-ai-request
                             'chat 'chat
                             (list :messages
                                   (vector (list :role "system" :content "Answer the question about this codebase from the excerpts given.  Cite the files you use as path:line.  Say so when the excerpts do not answer it.")
                                           (list :role "user"
                                                 :content (concat "Question: " question "\n\nExcerpts:\n"
                                                                  (mapconcat (lambda (s) (format "--- %s:%d\n%s" (plist-get s :file) (plist-get s :line) (plist-get s :text)))
                                                                             snippets "\n")))))
                             (lambda (answer info) (funcall callback answer info snippets))
                             :chain chain :interactive interactive)))))
       searches))
    (lambda ()
      (setq stopped t)
      (when h (drgnx-ai-cancel h))
      ;; a retriever that returns its process lets Stop end the search too
      (dolist (p searches) (when (processp p) (process-put p :dropped t) (delete-process p))))))

(defun drgnx-ai-ask (question &optional root)
  "Ask QUESTION about the project at ROOT (default: this project): what it names is looked up in the code, the
best snippets go to the `chat' role with it, the answer cites the files."
  (interactive (list (read-string "Ask the codebase: ")
                     (or (when-let* ((p (and (fboundp 'project-current) (project-current)))) (project-root p)) default-directory)))
  (let ((root (expand-file-name (or root default-directory))))
    (message "Ask the Codebase: looking…")
    (drgnx-ai--track
     (lambda (done)
       (drgnx-ai-ask-request question root
                             (lambda (answer info snippets)
                               (funcall done)
                               (drgnx-ai--answer-buffer question (or answer (format "No answer: %s" (plist-get info :error))) snippets root))
                             :interactive t)))))

;;;; Choose Provider/Model

(defun drgnx-ai-choose ()
  "Choose the provider and model of a role (from what runs here and what has a key), test it with one call,
and keep it in ai.eld (never a key)."
  (interactive)
  ;; what runs here now (a runner started since the last probe counts): at most the probe's one second
  (let ((done nil) (deadline (+ (float-time) 2)))
    (drgnx-ai-probe (lambda () (setq done t)))
    (while (and (not done) (< (float-time) deadline)) (accept-process-output nil 0.05)))
  (let* ((role (intern (completing-read "AI role: " '("complete" "edit" "chat" "embed") nil t)))
         (cap (pcase role ('complete 'fim) ('embed 'embed) (_ 'chat)))
         (ids (mapcar #'car (seq-filter (lambda (e) (drgnx-ai-usable-p (car e) cap t)) (drgnx-ai-providers))))
         (id (intern (completing-read (format "Provider for %s: " role) (mapcar #'symbol-name ids) nil t)))
         (model (completing-read "Model: " (plist-get (alist-get id drgnx-ai-detected) :models)))
         (keep (lambda ()
                 (drgnx-ai-set-role role (cons (cons id model) (seq-remove (lambda (s) (eq (car s) id)) (drgnx-ai-role role))))
                 (message "AI: %s/%s answered; %s uses it now (ai.eld)" id model role))))
    (if (eq cap 'embed) (funcall keep)
      (message "AI: asking %s/%s…" id model)
      (drgnx-ai-request role (if (eq cap 'fim) 'fim 'chat)
                        (if (eq cap 'fim) (list :prefix "(defun hello ()\n  " :suffix ")\n" :max-tokens 8)
                          (list :messages (vector (list :role "user" :content "Say OK."))))
                        (lambda (text info)
                          (if text (funcall keep)
                            (message "AI: %s/%s did not answer (%s); %s is unchanged" id model (plist-get info :error) role)))
                        :chain (list (cons id model)) :timeout 20 :interactive t))))

;;;; The module

(drgnx-module-define 'tools/ai
                     :doc "AI: ghost-text completion in code buffers (the `complete' role) and one Tab for everything."
                     :stage 'startup :requires '(core/workbench)
                     :setup
                     (lambda ()
                       (add-hook 'prog-mode-hook #'drgnx-ai-ghost--maybe-enable)
                       ;; which providers run here: asked once Emacs is idle, never while it works
                       (run-with-idle-timer 2 nil (lambda () (drgnx-ai-probe nil)))
                       (pcase-dolist (`(,id ,title ,fn ,doc ,map)
                                      '((ai-accept "Accept Suggestion" drgnx-ai-accept "Insert the whole suggestion" nil)
                                        (ai-accept-word "Accept Suggestion Word" drgnx-ai-accept-word "Insert its next word"
                                                        drgnx-ai-ghost-showing-map)
                                        (ai-accept-line "Accept Suggestion Line" drgnx-ai-accept-line "Insert it to the line's end" nil)
                                        (ai-dismiss "Dismiss Suggestion" drgnx-ai-dismiss "Drop the suggestion" drgnx-ai-ghost-showing-map)
                                        (ai-tab "Tab (Suggestion, Completion, Snippet, Heading, Indent)" drgnx-ai-tab
                                                "Accept a suggestion, else the popup's, snippet's, heading's or indent Tab" drgnx-ai-ghost-mode-map)
                                        (ai-complete-toggle "Toggle AI Completion" drgnx-ai-complete-toggle "Ghost text on or off" nil)
                                        (ai-edit "Edit with AI…" drgnx-ai-edit "Rewrite the region (or defun) as you say; review hunk by hunk" nil)
                                        (ai-edit-apply-hunk "Apply AI Edit Hunk" drgnx-ai-edit-apply-hunk
                                                            "Take the hunk at point; the review stays" drgnx-ai-edit-review-mode-map)
                                        (ai-edit-done "Done Reviewing AI Edit" drgnx-ai-edit-done "Put the hunks you applied in the buffer"
                                                      drgnx-ai-edit-review-mode-map)
                                        (ai-edit-reject "Reject AI Edit" drgnx-ai-edit-reject "Drop the edit; the buffer stays"
                                                        drgnx-ai-edit-review-mode-map)
                                        (ai-ask "Ask the Codebase…" drgnx-ai-ask "A question about this project, answered from its code" nil)
                                        (ai-stop "Stop AI Request" drgnx-ai-stop
                                                 "Cancel the Edit with AI or Ask the Codebase request in flight" nil)
                                        (ai-choose "Choose AI Provider/Model…" drgnx-ai-choose "A role's provider and model, tested first" nil)
                                        (ai-load-keys "Load Keys" drgnx-ai-load-keys
                                                      "Read your providers' keys from the Keychain or keyring, for ghost text and the background" nil)))
                         (apply #'drgnx-command-define id :category "AI" :title title :command fn :doc doc (and map (list :map map))))))

(provide 'drgnx-ai-ui)
;;; drgnx-ai-ui.el ends here
