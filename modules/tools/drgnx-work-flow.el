;;; drgnx-work-flow.el --- The Work space's Flow lens: a plan run's tasks by gate (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Flow is the fourth view of the lens (Map · Board · Timeline · Flow): a plan run as the hub's records, a row per
;; task and a column per gate (Brief, Red first, Build, Author check, Merge batch, Review), each cell a chip of the
;; gate's state; under them the merge batch and the rule pack.  The hub builds it (`work/flow/subscribe'): its rows,
;; and a model of its own (Sjá) whose selection is the Flow's alone, with the held tasks in its list `held'.  `e' shows
;; the selected task's evidence (`orch/evidence'), `R' the rule pack's rows.  Off the rows path it says so.
;; Loaded by tools/work-space (drgnx-work-space.el); defines no module.  See docs/develop/orchestration.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(require 'drgnx-work-client)
(unless (featurep 'drgnx-work-map)
  (load (expand-file-name "drgnx-work-map" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(declare-function drgnx-view-env-register "drgnx-view-env")
(declare-function drgnx-view-env-twin "drgnx-view-env" (class prefixes &optional setup))
(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function nidhogg-view-set "nidhogg-views" (h what value))
(declare-function drgnx-work-lens-string "drgnx-work-map")
(defvar drgnx-work-lens--map)
(defvar drgnx-work-lens-nav)
(defvar drgnx-work-lens-map)
(defvar drgnx-work-map--lens)

;;;; What the Flow asks and shows: pure

(defun drgnx-work-flow--ask (view map job)
  "Ask the hub for the Flow VIEW beside map view MAP: job JOB's, else (nil) the newest running job's."
  (drgnx-work-client--call "work/flow/subscribe"
                           (append (list :view view :map map) (and job (list :job job)))
                           #'ignore))

(defun drgnx-work-flow--evidence-line (e)
  "Record E (a plist as `orch/evidence' answers it) as one line: its kind, job, tree and command, then its failing
rows or its pass count; a waiver says its reason."
  (let* ((facts (plist-get e :facts))
         (tree (substring (or (plist-get facts :tree_key) "") 0 (min 7 (length (or (plist-get facts :tree_key) "")))))
         (kind (plist-get e :kind)))
    (if (equal kind "waiver")
        (format "%-7s  %s  by you: %s" kind tree (or (plist-get e :note) ""))
      (let* ((rows (append (plist-get e :rows) nil))
             (failed (seq-filter (lambda (r) (equal (plist-get r :verdict) "fail")) rows))
             (pass (seq-count (lambda (r) (equal (plist-get r :verdict) "pass")) rows))
             (command (or (cadr (split-string (or (plist-get facts :selector) "") "\n")) "")))
        (format "%-7s  job %s  %s  %s  %s" kind (plist-get e :job) tree command
                (if failed
                    (format "%d failed: %s" (length failed)
                            (mapconcat (lambda (r) (plist-get r :name)) failed ", "))
                  (format "%d pass" pass)))))))

(defun drgnx-work-flow--evidence-lines (evidence)
  "EVIDENCE (a vector of records, oldest first) as lines; a line saying so when there is none."
  (if (seq-empty-p evidence)
      (list "No evidence yet.")
    (mapcar #'drgnx-work-flow--evidence-line evidence)))

;;;; The Flow buffer

(defvar-local drgnx-work-flow--map nil "The map buffer this Flow is a view of.")
(defvar-local drgnx-work-flow--job nil "The job this Flow shows; nil: the newest running job.")

(defvar drgnx-work-flow-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m drgnx-work-lens-map) m)
  "Keys of the Flow.  The key profiles bind them (`drgnx-command-define' with this map or the lens map).")

(define-derived-mode drgnx-work-flow-mode special-mode "Work flow"
  "The Work space's Flow lens: a plan run's tasks by gate, its merge batch and its rule pack."
  (setq-local truncate-lines t cursor-type nil
              tab-line-format '("" drgnx-work-map--lens)))

(defun drgnx-work-flow--twin (class)
  "The Flow's buffer in display CLASS (`drgnx-view-patch-twin-function')."
  (drgnx-view-env-twin class '("drgnx-work-flow-" "drgnx-work-lens-")))

(defun drgnx-work-flow-buffers ()
  "The live Flow buffers."
  (seq-filter (lambda (b) (and (eq (buffer-local-value 'major-mode b) 'drgnx-work-flow-mode)
                               (not (drgnx-view-patch-twin-p b))))
              (buffer-list)))

(defun drgnx-work-flow--rows-p ()
  "Whether this Flow is a hub-fed view with its model in Sjá (the rows path)."
  (and (not drgnx-view-old-path) drgnx-view-patch (drgnx-view-patch-handle drgnx-view-patch) t))

(defun drgnx-work-flow-refresh (&optional buffer)
  "Ask the hub for BUFFER's Flow (default: the current one) again; off the rows path nothing is asked."
  (with-current-buffer (or buffer (current-buffer))
    (when (and (drgnx-work-flow--rows-p) (buffer-live-p drgnx-work-flow--map))
      (ignore-errors
        (drgnx-work-flow--ask (drgnx-view-patch-view drgnx-view-patch)
                              (drgnx-view-patch-view (buffer-local-value 'drgnx-view-patch drgnx-work-flow--map))
                              drgnx-work-flow--job)))))

(defun drgnx-work-flow--nav (dir)
  "A key of the lens in the Flow: DIR `up' or `down' follows the `flow' form's link, `next-agent' and
`previous-agent' walk the held tasks; the others move nothing.  Off the rows path the keys move nothing."
  (when (drgnx-work-flow--rows-p)
    (pcase dir
      ((or 'up 'down) (drgnx-view-nav 'follow (symbol-name dir)))
      ('next-agent (drgnx-view-nav 'walk "held" 1))
      ('previous-agent (drgnx-view-nav 'walk "held" -1))))
  t)

(defun drgnx-work-flow--name (map-buffer)
  (format "*drgnx work flow: %s*" (string-trim (buffer-name map-buffer) "\\*drgnx work: " "\\*")))

(defun drgnx-work-flow-open (map-buffer)
  "The Flow of MAP-BUFFER, made when there is none; it asks the hub for the Flow and does not show itself.  Beside a
map that is not on the rows path it says so instead."
  (let ((buffer (get-buffer-create (drgnx-work-flow--name map-buffer)))
        (rows (with-current-buffer map-buffer
                (when-let* ((state (and (not drgnx-view-old-path) drgnx-view-patch)))
                  (cons (concat (drgnx-view-patch-view state) "/flow") (drgnx-view-patch-class state))))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-work-flow-mode)
        (drgnx-work-flow-mode)
        (setq drgnx-work-lens-nav #'drgnx-work-flow--nav)
        (if rows
            (progn (drgnx-view-patch-attach (car rows) (cdr rows))
                   (setq-local drgnx-view-patch-twin-function #'drgnx-work-flow--twin)
                   (require 'drgnx-view-env)
                   (drgnx-view-env-register (car rows) buffer)
                   (nidhogg-view-set (drgnx-view-patch-handle drgnx-view-patch) 'form "flow"))
          (let ((inhibit-read-only t))
            (insert "The Flow needs Sjá, Nidhogg's view model: it is drawn from the hub's rows, and this Emacs has"
                    " no Sjá (or `drgnx-view-old-path' is set).\n"))))
      (setq drgnx-work-flow--map map-buffer drgnx-work-lens--map map-buffer
            drgnx-work-map--lens (drgnx-work-lens-string 'flow))
      (drgnx-work-flow-refresh buffer))
    buffer))

;;;; The Flow's own keys

(defun drgnx-work-flow-evidence ()
  "Show the selected task's evidence: the hub's records of its runs, its gates' findings and waivers, oldest first."
  (interactive)
  (let ((task (and (drgnx-work-flow--rows-p) (drgnx-view-nav-selection))))
    (unless task (user-error "Work: select a task first"))
    (drgnx-hub-call "orch/evidence" (list :task task)
                    (lambda (result err)
                      (if err
                          (message "Work: no evidence for %s (%s)" task (or (plist-get err :message) err))
                        ;; a fresh buffer each time: the list is a one-off answer, never patched
                        (when-let* ((old (get-buffer "*drgnx evidence*"))) (kill-buffer old))
                        (with-current-buffer (get-buffer-create "*drgnx evidence*")
                          (let ((inhibit-read-only t))
                            (insert (propertize (format "Evidence · %s\n\n" task) 'face 'bold))
                            (dolist (l (drgnx-work-flow--evidence-lines (plist-get result :evidence)))
                              (insert l "\n")))
                          (special-mode)
                          (goto-char (point-min))
                          (display-buffer (current-buffer))))))))

(defun drgnx-work-flow-rules ()
  "Show the rule pack's rows: the window scrolls to them."
  (interactive)
  (let ((at (save-excursion (goto-char (point-min)) (search-forward "Rules · " nil t))))
    (unless at (user-error "Work: this run has no rule pack"))
    (set-window-start (selected-window) (save-excursion (goto-char at) (line-beginning-position)))))

(defun drgnx-work-lens-show-flow ()
  "Show the Flow lens of the map's newest running job."
  (interactive)
  (pop-to-buffer-same-window (drgnx-work-flow-open (drgnx-work-lens-map-buffer))))

(declare-function drgnx-work-lens-map-buffer "drgnx-work-board")

(provide 'drgnx-work-flow)
;;; drgnx-work-flow.el ends here
