;;; drgnx-agents-hooks.el --- What hooks said about an agent's steps, and the context map -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The parts of the agent view that tell what the hub's hooks did (docs/guide/plugins.md): a verdict line under a
;; step (refused, noted, changed, busy), the provenance behind it, the header's facts about what is hooked, and the
;; context breakdown bar of an agent that sends one (`_drgnx/panel').  All of it is built from state the mirror
;; already holds (`drgnx-agent-session-hooks', `-hooked', `-panel', `-plugins-changed'): nothing here asks the hub
;; while a buffer is drawn, and an agent that offers none of it shows none of it (never faked).  The actions (drop,
;; pin, what a compaction keeps) are the user's commands and ask the hub only when clicked.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-agents)
(require 'drgnx-ui-kit)

(declare-function drgnx-hub-call "drgnx-hub-client" (method params callback &rest keys))

(defface drgnx-agents-hooks-refused '((t :inherit error)) "A hook refused the step." :group 'drgnx)
(defface drgnx-agents-hooks-note '((t :inherit shadow)) "A hook's note under a step." :group 'drgnx)
(defface drgnx-agents-hooks-changed '((t :inherit warning)) "A hook changed what the agent asked." :group 'drgnx)
(defface drgnx-agents-hooks-busy '((t :inherit warning :slant italic)) "A hook could not run: the host was busy."
  :group 'drgnx)

(defface drgnx-context-system '((t :inherit font-lock-keyword-face)) "System prompt in the context bar." :group 'drgnx)
(defface drgnx-context-tools '((t :inherit font-lock-function-name-face)) "Tool definitions in the context bar."
  :group 'drgnx)
(defface drgnx-context-files '((t :inherit font-lock-string-face)) "Files in the context bar." :group 'drgnx)
(defface drgnx-context-tool-output '((t :inherit font-lock-type-face)) "Tool output in the context bar." :group 'drgnx)
(defface drgnx-context-conversation '((t :inherit font-lock-constant-face)) "The conversation in the context bar."
  :group 'drgnx)
(defface drgnx-context-free '((t :inherit shadow)) "The free part of the context bar." :group 'drgnx)

;;;; Verdict lines

(defun drgnx-agents-hooks-source (source)
  "SOURCE (`rule:ID' or `plugin:NAME@VERSION#HASH') as a plist (:kind :name :version :hash :text); :text is how a line
names it (`deny-rm 0.1', `rule no-rm')."
  (cond ((not (stringp source)) (list :kind 'unknown :name "" :text "a hook"))
        ((string-match "\\`plugin:\\([^@#]*\\)\\(?:@\\([^#]*\\)\\)?\\(?:#\\(.*\\)\\)?\\'" source)
         (let ((name (match-string 1 source)) (version (match-string 2 source)) (hash (match-string 3 source)))
           (list :kind 'plugin :name name :version version :hash hash
                 :text (if (and version (not (string-empty-p version))) (concat name " " version) name))))
        ((string-prefix-p "rule:" source)
         (let ((id (substring source 5)))
           (list :kind 'rule :name id :text (concat "rule " id))))
        (t (list :kind 'unknown :name source :text source))))

(defun drgnx-agents-hooks--busy-p (reason)
  "Non-nil when REASON, the text of a failed hook run, says the plugin host was busy."
  (and (stringp reason) (string-match-p "\\`\\(?:busy\\|.*\\bbusy\\b\\)" reason)))

(defun drgnx-agents-hooks--glyph (name) (or (drgnx-face-glyph name) ""))

(defun drgnx-agents-hooks--quoted (reason)
  (if (and (stringp reason) (not (string-empty-p reason))) (format " · \"%s\"" reason) ""))

(defun drgnx-agents-hooks-lines (rows)
  "One entry per verdict worth a line in ROWS, the hub's hook rows of a step (oldest first): a plist (:text :row
:record :kind), :kind among `refused', `changed', `failed', `busy' and `at-server'.  An allow and an annotation make
no line here (a note has its own entry in the transcript, `drgnx-agents-hooks-note-line').  The text carries its face."
  (let (out)
    (dolist (row rows)
      (if (equal (plist-get row :outcome) "at-server")
          (push (list :kind 'at-server :row row
                      :text (propertize (format "%s hooked at the hub's server" (drgnx-agents-hooks--glyph 'note))
                                        'face 'drgnx-agents-hooks-note))
                out)
        (dolist (rec (append (plist-get row :records) nil))
          (let* ((verdict (plist-get rec :verdict)) (src (drgnx-agents-hooks-source (plist-get rec :source)))
                 (who (plist-get src :text)) (reason (plist-get rec :reason)))
            (pcase verdict
              ("deny"
               (push (list :kind 'refused :row row :record rec
                           :text (propertize (format "%s refused by %s%s" (drgnx-agents-hooks--glyph 'refused) who
                                                     (drgnx-agents-hooks--quoted reason))
                                             'face 'drgnx-agents-hooks-refused))
                     out))
              ("change"
               (push (list :kind 'changed :row row :record rec
                           :text (propertize (format "%s changed by %s" (drgnx-agents-hooks--glyph 'changed) who)
                                             'face 'drgnx-agents-hooks-changed))
                     out))
              ("error"
               (if (drgnx-agents-hooks--busy-p reason)
                   (push (list :kind 'busy :row row :record rec
                               :text (propertize (format "%s %s was busy: its hook did not run%s"
                                                         (drgnx-agents-hooks--glyph 'hook-busy) who
                                                         (drgnx-agents-hooks--quoted reason))
                                                 'face 'drgnx-agents-hooks-busy))
                         out)
                 (push (list :kind 'failed :row row :record rec
                             :text (propertize (format "%s %s failed%s" (drgnx-agents-hooks--glyph 'fail) who
                                                       (drgnx-agents-hooks--quoted reason))
                                               'face 'drgnx-agents-hooks-refused))
                       out))))))))
    (nreverse out)))

(defun drgnx-agents-hooks-note-line (entry)
  "The line of the `note' transcript ENTRY (a hook's annotation): `✎ note by annotate-edit · text'."
  (let ((who (plist-get (drgnx-agents-hooks-source (plist-get entry :source)) :text)))
    (propertize (format "%s note by %s%s" (drgnx-agents-hooks--glyph 'note) who
                        (drgnx-agents-hooks--quoted (plist-get entry :text)))
                'face 'drgnx-agents-hooks-note)))

(defun drgnx-agents-hooks-rows-for-tool (s tool-id)
  "The hook rows (oldest first) of the steps that ran on tool entry TOOL-ID of session S."
  (let (rows)
    (dolist (e (reverse (drgnx-agent-session-hooks s)))
      (when (and tool-id (equal (nth 1 e) tool-id)) (setq rows (append rows (nth 2 e)))))
    rows))

(defun drgnx-agents-hooks-row-of-note (s entry)
  "The hook row behind note ENTRY of session S (same step, a record from the entry's source), or nil."
  (let ((step (plist-get entry :step)) (source (plist-get entry :source)))
    (when-let* ((e (assq step (drgnx-agent-session-hooks s))))
      (seq-find (lambda (row) (seq-some (lambda (r) (equal (plist-get r :source) source)) (append (plist-get row :records) nil)))
                (nth 2 e)))))

(defun drgnx-agents-hooks-provenance (row record)
  "The provenance of RECORD (a verdict) in hook ROW, as text: who (source, version, hash), what, how long, and the
input's summary (the point, where it ran, the tool, the step)."
  (let* ((src (drgnx-agents-hooks-source (plist-get record :source))) (reason (plist-get record :reason)))
    (concat
     (format "Source:   %s\n" (plist-get src :text))
     (when (eq (plist-get src :kind) 'plugin)
       (format "Version:  %s\nHash:     %s\n" (or (plist-get src :version) "unknown") (or (plist-get src :hash) "unknown")))
     (format "Verdict:  %s\n" (or (plist-get record :verdict) "none"))
     (when reason (format "Reason:   %s\n" reason))
     (when (numberp (plist-get record :ms)) (format "Time:     %s ms\n" (plist-get record :ms)))
     (format "Input:    %s\n"
             (string-join
              (delq nil (list (and (plist-get row :point) (format "point %s" (plist-get row :point)))
                              (and (plist-get row :at) (format "at the %s" (plist-get row :at)))
                              (and (plist-get row :tool) (format "tool %s" (plist-get row :tool)))
                              (and (plist-get row :step) (format "step %s" (plist-get row :step)))
                              (and (plist-get row :outcome) (format "outcome %s" (plist-get row :outcome)))))
              ", ")))))

(defun drgnx-agents-hooks-show-provenance (row record)
  "Show the provenance of RECORD in ROW in its own buffer."
  (with-current-buffer (get-buffer-create "*agent hook*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (drgnx-agents-hooks-provenance row record)))
    (special-mode)
    (goto-char (point-min))
    (pop-to-buffer (current-buffer))))

;;;; The header

(defun drgnx-agents-hooks-header-parts (s)
  "What the header of session S's transcript tells about hooks and plugins, as a list of strings (nil: nothing).
`not hooked: KINDS' for the tool kinds no hook reaches (with the hub's reason), `hooked by the adapter: KINDS' for those
the agent's adapter enforces, and the restart notice when the approved plugin set changed since the session began."
  (let* ((h (drgnx-agent-session-hooked s)) (kinds (lambda (key) (string-join (append (plist-get h key) nil) ", "))))
    (delq nil
          (list (when (plist-get h :unhooked)
                  (propertize (format "not hooked: %s%s" (funcall kinds :unhooked)
                                      (if-let* ((why (plist-get h :why))) (format " (%s)" why) ""))
                              'face 'drgnx-agents-hooks-changed))
                (when (plist-get h :by_adapter)
                  (propertize (format "hooked by the adapter: %s" (funcall kinds :by_adapter)) 'face 'drgnx-agents-hooks-note))
                (when (drgnx-agent-session-plugins-changed s)
                  (propertize "plugins changed: restart the session to use the new set" 'face 'drgnx-agents-hooks-changed))))))

(defun drgnx-agents-hooks-context (s)
  "Session S's context breakdown (the panel's `:context'), or nil when its agent sends none."
  (plist-get (drgnx-agent-session-panel s) :context))

(defun drgnx-agents-hooks-offers-p (s feature)
  "Non-nil when session S's agent advertised FEATURE (`context', `drop', `pin', `compact-preview', `before-tool')."
  (and (member feature (append (plist-get (drgnx-agent-session-panel s) :features) nil)) t))

;;;; The context breakdown

(defconst drgnx-agents-hooks-bar-width 48 "Columns of the context bar.")

(defun drgnx-agents-hooks--kind-face (kind)
  (pcase kind
    ("system" 'drgnx-context-system) ("tools" 'drgnx-context-tools) ("files" 'drgnx-context-files)
    ("tool-output" 'drgnx-context-tool-output) (_ 'drgnx-context-conversation)))

(defun drgnx-agents-hooks-bar (context)
  "The bar of CONTEXT (`{used size parts}'): one run of blocks per part in its face, the free window dimmed."
  (let* ((size (max 1 (or (plist-get context :size) 1))) (w drgnx-agents-hooks-bar-width) (used 0) (parts nil))
    (dolist (p (append (plist-get context :parts) nil))
      (let* ((tokens (or (plist-get p :tokens) 0))
             (n (if (> tokens 0) (max 1 (round (* w (/ (float tokens) size)))) 0)))
        (push (propertize (make-string (min n (max 0 (- w used))) ?█) 'face (drgnx-agents-hooks--kind-face (plist-get p :kind)))
              parts)
        (setq used (min w (+ used n)))))
    (concat (apply #'concat (nreverse parts)) (propertize (make-string (max 0 (- w used)) ?░) 'face 'drgnx-context-free))))

(defun drgnx-agents-hooks--act (s method params)
  "Ask the hub METHOD with PARAMS for session S (the user clicked), and say how it went."
  (require 'drgnx-hub-client)
  (drgnx-hub-call method (append (list :id (drgnx-agent-session-remote s)) params)
                  (lambda (_r err) (message "%s" (if err (format "%s: %s" method err) (format "%s: done" method))))))

(defun drgnx-agents-hooks--button (label action)
  (make-text-button (copy-sequence label) nil 'action (lambda (_) (funcall action)) 'follow-link t))

(defun drgnx-agents-hooks-context-insert (s)
  "Insert the context breakdown of session S at point: the bar, each part with its items (drop and pin buttons for an
agent that offers them) and, for one that advertised `compact-preview', what /compact keeps.  Nothing for an agent that
sends no breakdown."
  (when-let* ((c (drgnx-agents-hooks-context s)))
    (let ((used (or (plist-get c :used) 0)) (size (or (plist-get c :size) 0)))
      (insert (format "Context  %d of %d tokens (%d%%)\n" used size (if (> size 0) (round (* 100.0 used) size) 0)))
      (insert (drgnx-agents-hooks-bar c) "\n\n")
      (dolist (p (append (plist-get c :parts) nil))
        (insert (propertize "██ " 'face (drgnx-agents-hooks--kind-face (plist-get p :kind)))
                (format "%-13s %7d tokens\n" (plist-get p :kind) (or (plist-get p :tokens) 0)))
        (dolist (it (append (plist-get p :items) nil))
          (let ((item (plist-get it :id)))
            (insert (format "    %-40s %7d  " (truncate-string-to-width (or (plist-get it :label) item) 40) (or (plist-get it :tokens) 0)))
            (when (drgnx-agents-hooks-offers-p s "drop")
              (insert (drgnx-agents-hooks--button "[drop]" (lambda () (drgnx-agents-hooks--act s "agents/context-drop" (list :item item)))) " "))
            (when (drgnx-agents-hooks-offers-p s "pin")
              (insert (drgnx-agents-hooks--button "[pin]" (lambda () (drgnx-agents-hooks--act s "agents/context-pin" (list :item item :pinned t)))) " "
                      (drgnx-agents-hooks--button "[unpin]" (lambda () (drgnx-agents-hooks--act s "agents/context-pin" (list :item item :pinned :false))))))
            (insert "\n"))))
      (when (plist-get c :compact_frees)
        (insert (format "\n/compact would free %d tokens\n" (plist-get c :compact_frees))))
      (when (drgnx-agents-hooks-offers-p s "compact-preview")
        (insert "\n" (drgnx-agents-hooks--button "[What /compact keeps]" (lambda () (drgnx-agents-hooks-compact-preview s))) "\n")))))

(defun drgnx-agents-hooks--preview-text (r)
  "The preview R (`{frees kept summarised note}') as text."
  (let ((items (lambda (label key)
                 (when-let* ((l (append (plist-get r key) nil)))
                   (concat label "\n" (mapconcat (lambda (it) (format "  %s (%s tokens)" (plist-get it :label) (plist-get it :tokens))) l "\n") "\n")))))
    (concat (when (plist-get r :frees) (format "A compaction frees %d tokens.\n" (plist-get r :frees)))
            (funcall items "Kept:" :kept) (funcall items "Summarised:" :summarised)
            (when (plist-get r :note) (concat (plist-get r :note) "\n")))))

(defun drgnx-agents-hooks-compact-preview (s)
  "Ask what a compaction of session S would keep (nothing is compacted) and show it below the breakdown."
  (require 'drgnx-hub-client)
  (drgnx-hub-call "agents/compact-preview" (list :id (drgnx-agent-session-remote s))
                  (lambda (r err)
                    (if err (message "agents/compact-preview: %s" err)
                      (with-current-buffer (get-buffer-create "*agent compact preview*")
                        (let ((inhibit-read-only t)) (erase-buffer) (insert (drgnx-agents-hooks--preview-text r)))
                        (special-mode)
                        (pop-to-buffer (current-buffer)))))))

(defun drgnx-agents-hooks-context-buffer (s)
  "The breakdown buffer of session S, drawn from what the mirror holds (it is drawn again when the session changes)."
  (with-current-buffer (get-buffer-create (format "*agent context: %s*" (drgnx-agent-session-name s)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (unless (drgnx-agents-hooks-context s) (insert "This agent sends no context breakdown.\n"))
      (drgnx-agents-hooks-context-insert s))
    (special-mode)
    (buffer-disable-undo)
    (goto-char (point-min))
    (current-buffer)))

(provide 'drgnx-agents-hooks)
;;; drgnx-agents-hooks.el ends here
