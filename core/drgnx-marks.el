;;; drgnx-marks.el --- The scroll bar's marks: changes, problems and search hits, each produced once -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The producers of the scroll bar's marks (docs/guide/minimap.md, "Marks").  Each kind is produced once, when its
;; source changes, and handed to the strip's owner (`drgnx-ruler-source', core/drgnx-ruler.el):
;;
;; - changes against the last commit (the gutter's change bars, `drgnx-hunks'), in the left lane, one mark per run of
;;   changed lines, reaching to the run's last line;
;; - Flymake's errors, warnings and notes, in the right lane, after Flymake reports (its listings' update);
;; - search hits while isearch runs, in the middle lane: the whole buffer, scanned once per change of the search
;;   string on an idle debounce, at most `drgnx-marks-search-max' hits;
;; - in the Problems list, its error and warning rows;
;; - bookmarks in the file (a watch on `bookmark-alist'), in the middle lane;
;; - the uses of the symbol at point, after 400 ms idle, while `drgnx-marks-symbol-uses' is on;
;; - agent edits: the text an agent's change put in (the edit history's drains, origin "agent:…"), in the left lane,
;;   kept as markers (at most `drgnx-marks-agent-max').
;;
;; Nothing here runs on a scroll or a keystroke that changes no source.  The module editor/minimap turns the
;; producers on (`drgnx-marks-on') and off.
;;
;; The next-mark commands (`drgnx-marks-next' and the per-kind ones: changes, problems, bookmarks, agent edits) go to
;; the next mark after the current line, wrapping at the end, and say where they are: "error 2 of 7: MESSAGE, line
;; 41".  On Nidhogg the buffer text's line model answers (a binary search over its sorted marks); elsewhere the
;; marks as last asked.

;;; Code:
(require 'cl-lib)
(require 'drgnx-ruler)
(require 'drgnx-timer)
(require 'drgnx-faces)
(require 'drgnx-ui-kit)
(require 'drgnx-setting)
(require 'thingatpt)

(defvar drgnx-hunks--marks)
(defvar drgnx-hunks-mode)
(defvar isearch-string)
(defvar isearch-regexp)
(defvar isearch-case-fold-search)
(defvar flymake-mode)
(defvar bookmark-alist)
(defvar drgnx-history-drained-functions)
(defvar drgnx-ruler-mode)
(declare-function nidhogg-lines-next-mark "nidhogg-lines" (buffer pos &optional kinds dir))
(declare-function nidhogg-lines-counts "nidhogg-lines" (buffer beg end))
(declare-function nidhogg-lines-describe "nidhogg-lines" (&optional buffer))
(declare-function bookmark-get-filename "bookmark" (bookmark-name-or-record))
(declare-function bookmark-get-position "bookmark" (bookmark-name-or-record))
(declare-function flymake-diagnostic-text "flymake" (diag))
(declare-function flymake-goto-next-error "flymake" (&optional n filter interactive))
(declare-function flymake-goto-prev-error "flymake" (&optional n filter interactive))
(declare-function flymake-diagnostics "flymake" (&optional beg end))
(declare-function flymake-diagnostic-type "flymake" (diag))
(declare-function flymake-diagnostic-beg "flymake" (diag))
(declare-function flymake--lookup-type-property "flymake" (type prop &optional default))

(defface drgnx-marks-added '((t :inherit drgnx-status-ok)) "A scroll bar mark of added lines." :group 'drgnx-minimap)
(defface drgnx-marks-changed '((t :inherit drgnx-status-info)) "A scroll bar mark of changed lines." :group 'drgnx-minimap)
(defface drgnx-marks-deleted '((t :inherit drgnx-status-fail)) "A scroll bar mark of deleted lines." :group 'drgnx-minimap)
(defface drgnx-marks-error '((t :inherit drgnx-status-fail)) "A scroll bar mark of an error." :group 'drgnx-minimap)
(defface drgnx-marks-warning '((t :inherit drgnx-status-warn)) "A scroll bar mark of a warning." :group 'drgnx-minimap)
(defface drgnx-marks-info '((t :inherit drgnx-status-info)) "A scroll bar mark of a note." :group 'drgnx-minimap)
(defface drgnx-marks-hit '((t :inherit drgnx-accent)) "A scroll bar mark of a search hit." :group 'drgnx-minimap)
(defface drgnx-marks-bookmark '((t :inherit drgnx-status-attention)) "A scroll bar mark of a bookmark." :group 'drgnx-minimap)
(defface drgnx-marks-symbol '((t :inherit drgnx-text-muted)) "A scroll bar mark of a use of the symbol at point." :group 'drgnx-minimap)
(defface drgnx-marks-agent '((t :inherit drgnx-pill-agent)) "A scroll bar mark of an agent's edit." :group 'drgnx-minimap)

(defvar drgnx-marks-symbol-uses)

(defvar drgnx-marks--on nil "Whether the producers are on (`drgnx-marks-on').")

(defvar drgnx-marks-agent-max 500 "The most agent edits a buffer marks; past it the oldest go.")

(defvar drgnx-marks-search-max 5000 "The most search hits marked on the scroll bar; past it the scan stops.")

;;;; Changes

(defun drgnx-marks--hunks ()
  "The change bars of the buffer (`drgnx-hunks--marks', one per line) as scroll bar marks: a run of lines of the same
kind, one after another, is one mark from its first line to its last."
  (let (out run-pos run-end run-kind run-line)
    (dolist (m (sort (copy-sequence drgnx-hunks--marks) (lambda (a b) (< (car a) (car b)))))
      (let ((pos (car m)) (line (cadr m)) (kind (cddr m)))
        (if (and run-kind (eq kind run-kind) (eql line (1+ run-line)))
            (setq run-end pos run-line line)
          (when run-kind (push (drgnx-marks--hunk-mark run-pos run-end run-kind) out))
          (setq run-pos pos run-end pos run-kind kind run-line line))))
    (when run-kind (push (drgnx-marks--hunk-mark run-pos run-end run-kind) out))
    (nreverse out)))

(defun drgnx-marks--hunk-mark (beg end kind)
  "The mark of a run of KIND lines from BEG to the line starting at END."
  (list beg 'left (pcase kind ('added 'drgnx-marks-added) ('deleted 'drgnx-marks-deleted) (_ 'drgnx-marks-changed))
        1 nil (and (> end beg) end)))

(defun drgnx-marks--hunks-drawn (&rest _)
  "After `drgnx-hunks--draw' and `drgnx-hunks--clear': the change marks again."
  (drgnx-ruler-source 'hunks (and drgnx-hunks-mode drgnx-hunks--marks #'drgnx-marks--hunks)))

;;;; Problems (Flymake)

(defun drgnx-marks--flymake ()
  "Flymake's diagnostics of the buffer as scroll bar marks: errors over warnings over notes."
  (when (bound-and-true-p flymake-mode)
    (mapcar (lambda (d)
              (pcase (flymake--lookup-type-property (flymake-diagnostic-type d) 'flymake-category)
                ('flymake-error (list (flymake-diagnostic-beg d) 'right 'drgnx-marks-error 3))
                ('flymake-warning (list (flymake-diagnostic-beg d) 'right 'drgnx-marks-warning 2))
                (_ (list (flymake-diagnostic-beg d) 'right 'drgnx-marks-info 1))))
            (flymake-diagnostics))))

(defun drgnx-marks--flymake-now (buffer)
  "BUFFER's Flymake marks, set once (the debounce's end)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (drgnx-ruler-source 'flymake (and (bound-and-true-p flymake-mode) #'drgnx-marks--flymake)))))

(defun drgnx-marks--flymake-reported (&optional buffer &rest _)
  "After `flymake--update-diagnostics-listings': BUFFER's problem marks, debounced 100 ms (a report comes per backend)."
  (let ((b (or buffer (current-buffer))))
    (drgnx-timer-debounce (cons 'marks-flymake b) 0.1 #'drgnx-marks--flymake-now :args (list b) :owner b)))

;;;; Search hits

(defvar-local drgnx-marks--search-hits nil "The hits of the running isearch: (POS LANE FACE PRIORITY) each.")
(defvar-local drgnx-marks--search-for nil "The (STRING REGEXP CASE-FOLD) `drgnx-marks--search-hits' were found for.")

(defun drgnx-marks--search-scan (buffer)
  "BUFFER's isearch hits, the whole accessible text, once per search string (the debounce's end)."
  (when (and (buffer-live-p buffer) (buffer-local-value 'isearch-mode buffer))
    (with-current-buffer buffer
      (let ((key (list isearch-string isearch-regexp isearch-case-fold-search)))
        (unless (equal key drgnx-marks--search-for)
          (setq drgnx-marks--search-for key drgnx-marks--search-hits nil)
          (unless (string-empty-p isearch-string)
            (let ((case-fold-search isearch-case-fold-search) (n 0) hits)
              (save-excursion
                (goto-char (point-min))
                (while (and (< n drgnx-marks-search-max)
                            (condition-case nil
                                (if isearch-regexp (re-search-forward isearch-string nil t)
                                  (search-forward isearch-string nil t))
                              (invalid-regexp nil)))
                  (push (list (match-beginning 0) 'middle 'drgnx-marks-hit 2) hits)
                  (setq n (1+ n))
                  (when (= (match-beginning 0) (match-end 0)) (forward-char 1))))
              (setq drgnx-marks--search-hits (nreverse hits))))
          (drgnx-ruler-source 'search (and drgnx-marks--search-hits (lambda () drgnx-marks--search-hits))))))))

(defun drgnx-marks--search-changed ()
  "`isearch-update-post-hook': the hits again once the search string rests."
  (drgnx-timer-debounce (cons 'marks-search (current-buffer)) 0.15 #'drgnx-marks--search-scan
                        :args (list (current-buffer)) :owner (current-buffer)))

(defun drgnx-marks--search-ended ()
  "`isearch-mode-end-hook': the hits go."
  (drgnx-timer-cancel (cons 'marks-search (current-buffer)))
  (setq drgnx-marks--search-hits nil drgnx-marks--search-for nil)
  (drgnx-ruler-source 'search nil))

;;;; The Problems list's rows

(defun drgnx-marks--problem-rows ()
  "The Problems list's error and warning rows as marks (the row's `drgnx-problem' property and its severity glyph)."
  (let (out (pos (point-min)))
    (while (setq pos (text-property-not-all pos (point-max) 'drgnx-problem nil))
      (let ((face (get-text-property (+ pos 4) 'face)))
        (pcase face
          ('drgnx-status-fail (push (list pos 'right 'drgnx-marks-error 3) out))
          ('drgnx-status-warn (push (list pos 'right 'drgnx-marks-warning 2) out))))
      (setq pos (or (next-single-property-change pos 'drgnx-problem) (point-max))))
    (nreverse out)))

(defun drgnx-marks--problems-listed (&rest _)
  "After the Problems list is drawn again: its row marks."
  (when (derived-mode-p 'special-mode)
    (drgnx-ruler-source 'problems #'drgnx-marks--problem-rows)))

;;;; Bookmarks

(defun drgnx-marks--bookmarks ()
  "The bookmarks in this buffer's file as marks."
  (when-let* ((file (and buffer-file-name (featurep 'bookmark) (file-truename buffer-file-name))))
    (let (out)
      (dolist (b (bound-and-true-p bookmark-alist))
        (let ((f (bookmark-get-filename b)) (pos (bookmark-get-position b)))
          (when (and f pos (string= (file-truename (expand-file-name f)) file))
            (push (list pos 'middle 'drgnx-marks-bookmark 2) out))))
      out)))

(defun drgnx-marks--bookmarks-changed (&rest _)
  "The watch on `bookmark-alist': every file buffer's bookmark marks again."
  (drgnx-timer-debounce 'marks-bookmarks 0.1 #'drgnx-marks--bookmarks-now))

(defun drgnx-marks--bookmarks-now ()
  "Set each file buffer's bookmark marks (the debounce's end)."
  (dolist (b (buffer-list))
    (when (buffer-file-name b)
      (with-current-buffer b
        (let ((marks (drgnx-marks--bookmarks)))
          (when (or marks (assq 'bookmarks drgnx-ruler--sources))
            (drgnx-ruler-source 'bookmarks (and marks #'drgnx-marks--bookmarks))))))))

;;;; Uses of the symbol at point

(defvar-local drgnx-marks--symbol-for nil "The symbol whose uses are marked.")
(defvar drgnx-marks-symbol-max 2000 "The most uses of a symbol marked.")

(defun drgnx-marks--symbol-scan ()
  "Mark the uses of the symbol at point in the selected window's buffer (the idle timer)."
  (let ((sym (and (derived-mode-p 'prog-mode 'text-mode) (thing-at-point 'symbol t))))
    (unless (equal sym drgnx-marks--symbol-for)
      (setq drgnx-marks--symbol-for sym)
      (let (hits (n 0))
        (when sym
          (save-excursion
            (save-restriction
              (widen)
              (goto-char (point-min))
              (let ((re (concat "\\_<" (regexp-quote sym) "\\_>")) (case-fold-search nil))
                (while (and (< n drgnx-marks-symbol-max) (re-search-forward re nil t))
                  (push (list (match-beginning 0) 'middle 'drgnx-marks-symbol 1) hits)
                  (setq n (1+ n)))))))
        (setq hits (and (cdr hits) (nreverse hits)))
        (drgnx-ruler-source 'symbol (and hits (lambda () hits)))))))

(defun drgnx-marks--symbol-setting (&rest _)
  "`drgnx-marks-symbol-uses' changed: the idle timer on or off."
  (if (and drgnx-marks-symbol-uses drgnx-marks--on)
      (drgnx-timer-start 'marks-symbol 0.4 #'drgnx-marks--symbol-scan :repeat t :idle t)
    (drgnx-timer-cancel 'marks-symbol)
    (dolist (b (buffer-list))
      (when (buffer-local-value 'drgnx-marks--symbol-for b)
        (with-current-buffer b
          (setq drgnx-marks--symbol-for nil)
          (drgnx-ruler-source 'symbol nil))))))

(drgnx-defsetting drgnx-marks-symbol-uses nil
  "Non-nil: the scroll bar marks the uses of the symbol at point, after 400 ms idle."
  :type 'boolean :group 'drgnx-minimap :scope 'global :apply #'drgnx-marks--symbol-setting)

;;;; Agent edits

(defvar-local drgnx-marks--agent nil "This buffer's agent edits: (BEG-MARKER . END-MARKER) each, newest first.")

(defun drgnx-marks--agent-marks ()
  "The agent edits as marks, each from its start to its end."
  (let (out)
    (dolist (e drgnx-marks--agent)
      (when (marker-position (car e))
        (push (list (marker-position (car e)) 'left 'drgnx-marks-agent 2 nil
                    (and (> (cdr e) (car e)) (marker-position (cdr e))))
              out)))
    out))

(defun drgnx-marks--shift (pos changes)
  "Where POS (1-based) is after CHANGES (the hub's shape: :start 0-based, :old_len, :inserted), applied in order."
  (dolist (c changes pos)
    (let ((start (1+ (plist-get c :start))) (old (plist-get c :old_len)) (new (length (plist-get c :inserted))))
      (cond ((< pos start))
            ((>= pos (+ start old)) (setq pos (+ pos (- new old))))
            (t (setq pos start))))))

(defun drgnx-marks--agent-drained (buffer _counter changes)
  "`drgnx-history-drained-functions': BUFFER's changes whose origin is an agent's become marks."
  (when (and (listp changes) (buffer-live-p buffer))
    (with-current-buffer buffer
      (let ((rest changes) added)
        (while rest
          (let ((c (pop rest)))
            (when (string-prefix-p "agent:" (or (plist-get c :origin) ""))
              (let* ((beg (drgnx-marks--shift (1+ (plist-get c :start)) rest))
                     (end (drgnx-marks--shift (+ 1 (plist-get c :start) (length (plist-get c :inserted))) rest)))
                (push (cons (copy-marker beg) (copy-marker (max beg end))) drgnx-marks--agent)
                (setq added t)))))
        (when added
          (dolist (e (nthcdr drgnx-marks-agent-max drgnx-marks--agent))
            (set-marker (car e) nil) (set-marker (cdr e) nil))
          (when (nthcdr drgnx-marks-agent-max drgnx-marks--agent)
            (setcdr (nthcdr (1- drgnx-marks-agent-max) drgnx-marks--agent) nil))
          (drgnx-ruler-source 'agent #'drgnx-marks--agent-marks))))))

(defun drgnx-marks--agent-clear ()
  "Release this buffer's agent edit markers."
  (dolist (e drgnx-marks--agent) (set-marker (car e) nil) (set-marker (cdr e) nil))
  (setq drgnx-marks--agent nil))

;;;; Next and previous

(defconst drgnx-marks--names
  '((change . "change") (error . "error") (warning . "warning") (info . "note") (hit . "match")
    (breakpoint . "breakpoint") (bookmark . "bookmark") (symbol . "use") (agent . "agent edit") (pin . "pin")
    (other . "mark"))
  "What the announcement calls a mark of each kind.")

(defun drgnx-marks--model-p ()
  "Whether the buffer text's line model holds the marks (Nidhogg, with marks sent)."
  (and (fboundp 'nidhogg-lines-next-mark) drgnx-ruler-mode (nidhogg-lines-describe)))

(defun drgnx-marks--kind-numbers (kinds)
  "KINDS as the line model's numbers."
  (mapcar (lambda (k) (cl-position k drgnx-ruler-kinds)) kinds))

(defun drgnx-marks--next (pos kinds dir)
  "The position of the first mark of KINDS after POS (DIR > 0) or the last before it, or nil."
  (if (drgnx-marks--model-p)
      (nidhogg-lines-next-mark nil pos (drgnx-marks--kind-numbers kinds) dir)
    (let (best)
      (dolist (m drgnx-ruler--marks best)
        (when (memq (nth 6 m) kinds)
          (let ((p (car m)))
            (when (if (> dir 0) (and (> p pos) (or (null best) (< p best)))
                    (and (< p pos) (or (null best) (> p best))))
              (setq best p))))))))

(defun drgnx-marks--count (kinds beg end)
  "The marks of KINDS from BEG to before END."
  (if (drgnx-marks--model-p)
      (let ((c (nidhogg-lines-counts nil beg end)) (n 0))
        (dolist (k (drgnx-marks--kind-numbers kinds) n) (setq n (+ n (aref c k)))))
    (cl-count-if (lambda (m) (and (memq (nth 6 m) kinds) (<= beg (car m)) (< (car m) end))) drgnx-ruler--marks)))

(defun drgnx-marks--kind-at (pos kinds)
  "The kind of the mark at POS among KINDS (the first of them with one there)."
  (cl-find-if (lambda (k) (> (drgnx-marks--count (list k) pos (1+ pos)) 0)) kinds))

(defun drgnx-marks--message (pos kind)
  "What the mark of KIND at POS says, or nil: a problem's message."
  (when (and (memq kind '(error warning info)) (bound-and-true-p flymake-mode))
    (when-let* ((d (car (flymake-diagnostics pos (1+ pos)))))
      (car (split-string (flymake-diagnostic-text d) "\n")))))

(defun drgnx-marks-announcement (pos kinds)
  "The words for a jump to the mark at POS among KINDS: \"error 2 of 7: MESSAGE, line 41\"."
  (let* ((kind (or (drgnx-marks--kind-at pos kinds) (car kinds)))
         (msg (drgnx-marks--message pos kind)))
    (format "%s %d of %d%s, line %d" (alist-get kind drgnx-marks--names "mark")
            (1+ (drgnx-marks--count kinds 1 pos)) (drgnx-marks--count kinds 1 (1+ (buffer-size)))
            (if msg (concat ": " msg) "") (line-number-at-pos pos t))))

(defun drgnx-marks-step (kinds dir)
  "Go to the next mark of KINDS after the current line (DIR > 0) or the previous one before it, wrapping at the
buffer's end, and say where it is.  Nil when the buffer has none."
  (when drgnx-ruler-mode (drgnx-ruler-refresh))
  (let* ((from (if (> dir 0) (line-end-position) (line-beginning-position)))
         (pos (or (drgnx-marks--next from kinds dir)
                  (drgnx-marks--next (if (> dir 0) 0 (+ 2 (buffer-size))) kinds dir))))
    (if (not pos)
        (progn (message "No %s in this buffer" (alist-get (car kinds) drgnx-marks--names "mark")) nil)
      (push-mark nil t)
      (goto-char pos)
      (message "%s" (drgnx-marks-announcement pos kinds))
      pos)))

(defun drgnx-marks-next ()
  "Go to the next mark of any kind shown (`drgnx-marks-kinds')."
  (interactive)
  (drgnx-marks-step drgnx-marks-kinds 1))

(defun drgnx-marks-previous ()
  "Go to the previous mark of any kind shown."
  (interactive)
  (drgnx-marks-step drgnx-marks-kinds -1))

(defun drgnx-marks-next-change ()
  "Go to the next change against the last commit."
  (interactive)
  (drgnx-marks-step '(change) 1))

(defun drgnx-marks-previous-change ()
  "Go to the previous change against the last commit."
  (interactive)
  (drgnx-marks-step '(change) -1))

(defun drgnx-marks-next-bookmark ()
  "Go to the next bookmark in this file."
  (interactive)
  (drgnx-marks-step '(bookmark) 1))

(defun drgnx-marks-previous-bookmark ()
  "Go to the previous bookmark in this file."
  (interactive)
  (drgnx-marks-step '(bookmark) -1))

(defun drgnx-marks-next-agent-edit ()
  "Go to the next agent edit in this file."
  (interactive)
  (drgnx-marks-step '(agent) 1))

(defun drgnx-marks-previous-agent-edit ()
  "Go to the previous agent edit in this file."
  (interactive)
  (drgnx-marks-step '(agent) -1))

(defun drgnx-marks-next-problem ()
  "Go to the next error, warning or note in this file, and say which: from the marks, else Flymake's own."
  (interactive)
  (unless (drgnx-marks-step '(error warning info) 1)
    (when (bound-and-true-p flymake-mode) (call-interactively #'flymake-goto-next-error))))

(defun drgnx-marks-previous-problem ()
  "Go to the previous error, warning or note in this file."
  (interactive)
  (unless (drgnx-marks-step '(error warning info) -1)
    (when (bound-and-true-p flymake-mode) (call-interactively #'flymake-goto-prev-error))))

;;;; On and off

(defun drgnx-marks-on ()
  "The producers on: advice on the change bars' draw, Flymake's report and the Problems list's draw, isearch's hooks."
  (advice-add 'drgnx-hunks--draw :after #'drgnx-marks--hunks-drawn)
  (advice-add 'drgnx-hunks--clear :after #'drgnx-marks--hunks-drawn)
  (advice-add 'flymake--update-diagnostics-listings :after #'drgnx-marks--flymake-reported)
  (advice-add 'drgnx-problems--revert :after #'drgnx-marks--problems-listed)
  (add-hook 'isearch-update-post-hook #'drgnx-marks--search-changed)
  (add-hook 'isearch-mode-end-hook #'drgnx-marks--search-ended)
  (add-variable-watcher 'bookmark-alist #'drgnx-marks--bookmarks-changed)
  (add-hook 'drgnx-history-drained-functions #'drgnx-marks--agent-drained)
  (setq drgnx-marks--on t)
  (drgnx-marks--symbol-setting)
  (drgnx-marks--bookmarks-now))

(defun drgnx-marks-off ()
  "The producers off, and their marks gone from every buffer."
  (advice-remove 'drgnx-hunks--draw #'drgnx-marks--hunks-drawn)
  (advice-remove 'drgnx-hunks--clear #'drgnx-marks--hunks-drawn)
  (advice-remove 'flymake--update-diagnostics-listings #'drgnx-marks--flymake-reported)
  (advice-remove 'drgnx-problems--revert #'drgnx-marks--problems-listed)
  (remove-hook 'isearch-update-post-hook #'drgnx-marks--search-changed)
  (remove-hook 'isearch-mode-end-hook #'drgnx-marks--search-ended)
  (remove-variable-watcher 'bookmark-alist #'drgnx-marks--bookmarks-changed)
  (remove-hook 'drgnx-history-drained-functions #'drgnx-marks--agent-drained)
  (drgnx-timer-cancel 'marks-bookmarks)
  (setq drgnx-marks--on nil)
  (drgnx-marks--symbol-setting)
  (dolist (b (buffer-list))
    (with-current-buffer b
      (drgnx-marks--agent-clear)
      (when drgnx-ruler-mode
        (dolist (owner '(hunks flymake search problems bookmarks symbol agent)) (drgnx-ruler-source owner nil))))))

(provide 'drgnx-marks)
;;; drgnx-marks.el ends here
