;;; drgnx-extensions-list.el --- The Extensions view: one list of packages, plugins and modules -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One list for everything that extends drgnx: packages (installed, with updates, recommended), plugins, the editor's
;; modules and Emacs's built-ins.  The rows come from the hub's `extensions/search' (a catalog it reads from disk) and are
;; drawn as a view (wb/drgnx-view.el), patched in place.  The editor never installs and never touches the network here:
;; a click is a queued entry or a job of the job layer (drgnx-extensions-jobs.el), and a row's progress is a cache read
;; of that layer's state, redrawn once a second only while a row is busy.  Everything a timer, a hook or redisplay runs
;; here reads cached values; the hub's answers arrive in callbacks.  See docs/guide/extensions.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-timer)
(require 'drgnx-view)
(require 'drgnx-ui-kit)
(require 'drgnx-view-nav)
(require 'drgnx-extensions-refresh)

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-hub-call-sync "drgnx-hub-client")
(declare-function drgnx-exec-log "drgnx-exec")
(declare-function drgnx-statusbar-refresh "drgnx-statusbar")
(declare-function drgnx-extensions-jobs-state "drgnx-extensions-jobs")
(declare-function drgnx-extensions-jobs-queue "drgnx-extensions-jobs")
(declare-function drgnx-extensions-jobs-run "drgnx-extensions-jobs")
(declare-function drgnx-extensions-jobs-cancel "drgnx-extensions-jobs")
(declare-function drgnx-extensions-live-restart-pending "drgnx-extensions-live")
(declare-function drgnx-extensions-project-toggle "drgnx-extensions-project" (pkg root))
(declare-function drgnx-extensions-project-describe "drgnx-extensions-project" (pkg root))
(declare-function drgnx-extensions-project--root "drgnx-extensions-project" (file))
(declare-function drgnx-setting-for-root "drgnx-settings-workspace" (var root))
(declare-function drgnx-extensions-trust-before-install "drgnx-extensions-trust")
(declare-function drgnx-extensions-trust-update "drgnx-extensions-trust")
(declare-function drgnx-extensions-trust-review-p "drgnx-extensions-trust")
(declare-function drgnx-extensions-recommend-ids "drgnx-extensions-recommend")
(defvar drgnx-extensions-review)
(declare-function drgnx-extensions-details-open "drgnx-extensions-details")
(declare-function drgnx-extensions-details-generation-keys "drgnx-extensions-details")
(declare-function drgnx-extensions-details-generation-row "drgnx-extensions-details")
(declare-function drgnx-extensions-details-generations "drgnx-extensions-details")
(declare-function drgnx-extensions-details-forget-generations "drgnx-extensions-details")
(defvar drgnx-extensions-jobs-changed-functions)
(defvar drgnx-extensions-recommended)
(defvar drgnx-packages-off)
(defvar drgnx-extensions-check-updates)

(defconst drgnx-extensions-list-buffer-name "*Extensions*" "The name of the Extensions list's buffer.")

(defcustom drgnx-extensions-list-density 'comfortable
  "Rows of the Extensions list: `comfortable' (two lines, the summary on the second) or `dense' (one line)."
  :type '(choice (const comfortable) (const dense)) :group 'drgnx)

(defconst drgnx-extensions-list--page 200 "Rows one search answer holds (the hub's default).")

;;;; The query language

(defconst drgnx-extensions-list--flags
  '(("installed" . :installed) ("updates" . :updates) ("enabled" . :enabled) ("disabled" . :disabled)
    ("builtin" . :builtin) ("plugins" . :plugins) ("unsigned" . :unsigned))
  "Query words that are flags of the hub's search.")

(defconst drgnx-extensions-list--valued
  '(("archive" . :archive) ("kind" . :kind) ("keyword" . :keyword))
  "Query words that carry a value (`@archive:melpa').")

(defconst drgnx-extensions-list--local-words '("recommended" "this-project" "failed" "restart" "generations")
  "Query words the editor answers itself: they reach the hub as the ids they name.")

(defconst drgnx-extensions-list--sorts '("name" "downloads" "updated" "installed") "The orders `@sort:' knows.")

(defun drgnx-extensions-parse-query (string)
  "STRING, what is typed in the search, as (:text S :filters PLIST :local WORDS :sort S :unknown TOKENS).
Words that start with @ are filters (`@installed', `@updates', `@enabled', `@disabled', `@builtin', `@plugins',
`@unsigned', `@archive:A', `@kind:K', `@keyword:W'), local ones the editor answers (`@recommended', `@this-project',
`@failed', `@restart', `@generations') or `@sort:name|downloads|updated|installed'.  The other words are the text.  A
word that starts with @ and is none of these is listed under :unknown, never an error."
  (let (text filters local sort unknown)
    (dolist (token (split-string string))
      (if (not (string-prefix-p "@" token))
          (push token text)
        (let* ((word (substring token 1)) (colon (string-search ":" word))
               (name (if colon (substring word 0 colon) word)) (value (and colon (substring word (1+ colon)))))
          (cond ((and (null colon) (assoc name drgnx-extensions-list--flags))
                 (setq filters (plist-put filters (cdr (assoc name drgnx-extensions-list--flags)) t)))
                ((and (null colon) (member name drgnx-extensions-list--local-words))
                 (push (intern name) local))
                ((and value (not (string-empty-p value)) (assoc name drgnx-extensions-list--valued))
                 (setq filters (plist-put filters (cdr (assoc name drgnx-extensions-list--valued)) value)))
                ((and value (equal name "sort") (member value drgnx-extensions-list--sorts)) (setq sort value))
                (t (push token unknown))))))
    (list :text (string-join (nreverse text) " ") :filters filters :local (nreverse local) :sort sort
          :unknown (nreverse unknown))))

(defun drgnx-extensions-list--chips (query)
  "The chips under the search for the parsed QUERY: each filter, and a quiet \"not a filter\" for an unknown word."
  (let ((out nil))
    (cl-loop for (k v) on (plist-get query :filters) by #'cddr
             do (push (propertize (format "[%s%s]" (substring (symbol-name k) 1) (if (eq v t) "" (concat ":" v)))
                                  'face 'drgnx-status-info)
                      out))
    (dolist (l (plist-get query :local)) (push (propertize (format "[%s]" l) 'face 'drgnx-status-info) out))
    (when (plist-get query :sort) (push (propertize (format "[sort:%s]" (plist-get query :sort)) 'face 'drgnx-status-info) out))
    (dolist (u (plist-get query :unknown)) (push (propertize (format "[%s: not a filter]" u) 'face 'shadow) out))
    (string-join (nreverse out) " ")))

;;;; The model: rows by id, the sections that hold them, what the job layer says

(defvar drgnx-extensions-list--rows (make-hash-table :test 'equal)
  "Row id → its row plist, as the hub sent it (:state, :kind and :signed as symbols).  Emptied by the reset.")

(defvar drgnx-extensions-list--sections nil
  "Alist SECTION → (:ids IDS :total N): the rows loaded for each section.  `search' holds the typed query's.")

(defvar drgnx-extensions-list--jobs (make-hash-table :test 'equal)
  "Row id → the job layer's state for it (`drgnx-extensions-jobs-state'), kept by its changed-functions.")

(defvar drgnx-extensions-list--asked (make-hash-table :test 'equal)
  "(SECTION . OFFSET) → t: the pages asked since the last refresh, so a page is asked once.")

(defvar drgnx-extensions-list--query "" "What is typed in the search.")
(defvar drgnx-extensions-list--parsed nil "The parsed `drgnx-extensions-list--query'.")
(defvar drgnx-extensions-list--epoch 0 "Bumped by each refresh and each new query: an older answer is dropped.")
(defvar drgnx-extensions-list--error nil "The text of the last search the hub could not answer, or nil.")
(defvar drgnx-extensions-list--restart nil "The ids that wait for a restart (a cached copy of the live layer's answer).")
(defvar drgnx-extensions-list--updates 0 "How many updates the last unfiltered search found: the status bar's number.")
(defvar drgnx-extensions-list--installed-ids nil
  "Installed's ids without the rows that wait in Updates, made once per answer: emptied by the reset and by each
answer the hub sends (which may change a row's state).")
(defvar drgnx-extensions-list--root nil
  "The root of the project the list or a page was last opened from (a file buffer's), or nil: where `p' and a page's
toggle turn a package off, and what @this-project reads.")

(defvar drgnx-extensions-list--limits nil "Alist SECTION → the rows the list asks of it (a page more at each end).")

(defvar drgnx-extensions-list--chips (make-hash-table :test 'equal)
  "Row id → the overlay showing its job's chip on the rows path.  Emptied with the list.")

(defun drgnx-extensions-list--reset ()
  "Forget every row, section, job state and query."
  (clrhash drgnx-extensions-list--rows)
  (clrhash drgnx-extensions-list--jobs)
  (clrhash drgnx-extensions-list--asked)
  (maphash (lambda (_ ov) (delete-overlay ov)) drgnx-extensions-list--chips)
  (clrhash drgnx-extensions-list--chips)
  (setq drgnx-extensions-list--sections nil drgnx-extensions-list--installed-ids nil drgnx-extensions-list--limits nil
        drgnx-extensions-list--query "" drgnx-extensions-list--parsed nil
        drgnx-extensions-list--error nil drgnx-extensions-list--restart nil drgnx-extensions-list--updates 0
        drgnx-extensions-list--epoch (1+ drgnx-extensions-list--epoch)))

(defun drgnx-extensions-list--parsed ()
  (or drgnx-extensions-list--parsed
      (setq drgnx-extensions-list--parsed (drgnx-extensions-parse-query drgnx-extensions-list--query))))

(defun drgnx-extensions-list--typed-p ()
  "Non-nil while something is typed in the search: the sections fold into the search results."
  (not (string-empty-p (string-trim drgnx-extensions-list--query))))

(defun drgnx-extensions-list--normalize (row)
  "ROW as the hub sent it, with :kind, :state and :signed as symbols."
  (let ((r (copy-sequence row)))
    (dolist (k '(:kind :state :signed))
      (when (stringp (plist-get r k)) (setq r (plist-put r k (intern (plist-get r k))))))
    r))

(defconst drgnx-extensions-list--sections-order '(installed updates recommended plugins builtin)
  "The sections of the list when nothing is typed, in order.")

(defconst drgnx-extensions-list--titles
  '((installed . "Installed") (updates . "Updates") (recommended . "Recommended") (plugins . "Plugins")
    (builtin . "Built-in") (search . "Search results") (generations . "Generations"))
  "SECTION → the header's text.")

(defun drgnx-extensions-list--section-ids (section)
  "The ids SECTION shows: a row with an update waits in Updates, not in Installed."
  (let ((ids (plist-get (cdr (assq section drgnx-extensions-list--sections)) :ids)))
    (if (eq section 'installed)
        (or drgnx-extensions-list--installed-ids
            (setq drgnx-extensions-list--installed-ids
                  (cl-remove-if (lambda (id) (eq (plist-get (gethash id drgnx-extensions-list--rows) :state) 'update)) ids)))
      ids)))

(defun drgnx-extensions-list--keys ()
  "The keys of the rows the view shows now, in order: a header (`(section . NAME)') then its row ids, one row once.
While a query is typed: the search results alone, or with @generations the generations."
  (cond ((memq 'generations (plist-get (drgnx-extensions-list--parsed) :local))
         (and (fboundp 'drgnx-extensions-details-generation-keys) (drgnx-extensions-details-generation-keys)))
        ((drgnx-extensions-list--typed-p)
         (cons (cons 'section 'search) (drgnx-extensions-list--section-ids 'search)))
        (t
         (let ((seen (make-hash-table :test 'equal)) (out nil))
           (dolist (s drgnx-extensions-list--sections-order)
             (let ((ids (cl-remove-if (lambda (id) (gethash id seen)) (drgnx-extensions-list--section-ids s))))
               (when ids
                 (push (cons 'section s) out)
                 (dolist (id ids) (puthash id t seen) (push id out)))))
           (nconc (nreverse out)
                  (and (fboundp 'drgnx-extensions-details-generation-keys) (drgnx-extensions-details-generation-keys)))))))

(defun drgnx-extensions-list--receive (section rows total offset)
  "The hub answered a search for SECTION with ROWS (TOTAL matched), starting at OFFSET: keep them and show them."
  (let ((ids (mapcar (lambda (r)
                       (let ((n (drgnx-extensions-list--normalize r)))
                         (puthash (plist-get n :id) n drgnx-extensions-list--rows)
                         (plist-get n :id)))
                     rows))
        (old (plist-get (cdr (assq section drgnx-extensions-list--sections)) :ids)))
    (setq drgnx-extensions-list--sections
          (cons (cons section (list :ids (if (> offset 0) (append old ids) ids) :total total))
                (assq-delete-all section drgnx-extensions-list--sections))
          drgnx-extensions-list--installed-ids nil)
    (when (eq section 'updates) (setq drgnx-extensions-list--updates total))
    (drgnx-extensions-list--changed)))

;;;; Asking the hub

(defun drgnx-extensions-list--recommended-ids ()
  "The ids Recommended lists: what the project you work in recommends (drgnx-extensions-recommend.el), else the
global `drgnx-extensions-recommended'."
  (if (fboundp 'drgnx-extensions-recommend-ids)
      (drgnx-extensions-recommend-ids)
    (mapcar (lambda (n) (format "pkg:%s" n)) (bound-and-true-p drgnx-extensions-recommended))))

(defun drgnx-extensions-list--local-ids (local)
  "(PRESENT . IDS) for the LOCAL words: PRESENT when one asks for a set of ids, IDS their intersection, in order."
  (let (present ids)
    (dolist (word local)
      (let ((set (pcase word
                   ('failed (let (out) (maphash (lambda (id st) (when (eq (plist-get st :status) 'failed) (push id out)))
                                                drgnx-extensions-list--jobs)
                                 (sort out #'string<)))
                   ('restart (copy-sequence drgnx-extensions-list--restart))
                   ('recommended (drgnx-extensions-list--recommended-ids))
                   ('this-project (append (drgnx-extensions-list--recommended-ids)
                                          (mapcar (lambda (n) (format "pkg:%s" n))
                                                  (and drgnx-extensions-list--root
                                                       (seq-filter #'symbolp
                                                                   (ensure-list (drgnx-setting-for-root
                                                                                 'drgnx-packages-off
                                                                                 drgnx-extensions-list--root)))))))
                   (_ 'none))))
        (unless (eq set 'none)
          (setq ids (if present (cl-remove-if-not (lambda (id) (member id set)) ids) set) present t))))
    (cons present ids)))

(defun drgnx-extensions-list-search-params (query &optional offset)
  "The params of `extensions/search' for the parsed QUERY: the words, the filters (the local words as `:ids'), the sort."
  (let* ((filters (copy-sequence (plist-get query :filters)))
         (local (drgnx-extensions-list--local-ids (plist-get query :local))))
    (when (car local) (setq filters (plist-put filters :ids (vconcat (cdr local)))))
    (append (list :query (plist-get query :text))
            (and filters (list :filters filters))
            (and (plist-get query :sort) (list :sort (plist-get query :sort)))
            (list :offset (or offset 0) :limit drgnx-extensions-list--page))))

(defun drgnx-extensions-list--section-params (section &optional offset)
  (pcase section
    ('search (drgnx-extensions-list-search-params (drgnx-extensions-list--parsed) offset))
    (_ (append (list :query "")
               (list :filters
                     (pcase section
                       ('installed '(:installed t)) ('updates '(:updates t)) ('plugins '(:plugins t)) ('builtin '(:builtin t))
                       ('recommended (list :ids (vconcat (drgnx-extensions-list--recommended-ids))))))
               (list :offset (or offset 0) :limit drgnx-extensions-list--page)))))

(defun drgnx-extensions-list--fetch (section offset)
  "Ask the hub, without waiting, for SECTION's rows from OFFSET.  The answer goes to `drgnx-extensions-list--receive'
\(on the rows path: the whole list again, a page more of SECTION when OFFSET is past 0)."
  (unless (fboundp 'drgnx-hub-call) (require 'drgnx-hub-client))
  (let ((epoch drgnx-extensions-list--epoch))
    (puthash (cons section offset) t drgnx-extensions-list--asked)
    (if (drgnx-extensions-list--hub-fed-p)
        (if (> offset 0) (drgnx-extensions-list--rows-more section offset) (drgnx-extensions-list--ask))
      (condition-case err
          (drgnx-hub-call "extensions/search" (drgnx-extensions-list--section-params section offset)
                          (lambda (result error)
                            (when (eql epoch drgnx-extensions-list--epoch)
                              (if error
                                  (progn (setq drgnx-extensions-list--error (format "%s" error))
                                         (drgnx-extensions-list--changed))
                                (setq drgnx-extensions-list--error nil)
                                (drgnx-extensions-list--receive section (append (plist-get result :rows) nil)
                                                                (or (plist-get result :total) 0) offset)))))
        (error (setq drgnx-extensions-list--error (error-message-string err))
               (drgnx-extensions-list--changed))))))

(defun drgnx-extensions-list-refresh ()
  "Ask for every section again (or the search results while a query is typed)."
  (interactive)
  (setq drgnx-extensions-list--epoch (1+ drgnx-extensions-list--epoch))
  (clrhash drgnx-extensions-list--asked)
  (drgnx-extensions-list--note-restart)
  (when (fboundp 'drgnx-extensions-details-forget-generations) (drgnx-extensions-details-forget-generations))
  (if (drgnx-extensions-list--hub-fed-p)
      (drgnx-extensions-list--ask)
    (dolist (s (if (drgnx-extensions-list--typed-p) '(search) drgnx-extensions-list--sections-order))
      (drgnx-extensions-list--fetch s 0))))

(defun drgnx-extensions-list--last-section ()
  "The section whose rows end the list, with rows still to load: (SECTION . LOADED), or nil."
  (let ((s (if (drgnx-extensions-list--typed-p) 'search
             (car (last (cl-remove-if-not (lambda (s) (drgnx-extensions-list--section-ids s))
                                          drgnx-extensions-list--sections-order))))))
    (when s
      (let* ((data (cdr (assq s drgnx-extensions-list--sections))) (loaded (length (plist-get data :ids))))
        (when (< loaded (or (plist-get data :total) 0)) (cons s loaded))))))

(defun drgnx-extensions-list--post-command ()
  "`post-command-hook' of the list: near the end of the rows, ask for the next page, once.  Reads cached numbers."
  (when (> (+ (point) 3000) (point-max))
    (when-let* ((last (if (drgnx-extensions-list--hub-fed-p) (drgnx-extensions-list--rows-last)
                        (drgnx-extensions-list--last-section)))
                ((not (gethash last drgnx-extensions-list--asked))))
      (drgnx-extensions-list--fetch (car last) (cdr last)))))

;;;; The catalog's age

(defun drgnx-extensions-list-catalog-stale-p ()
  "Non-nil when the catalog is missing or older than a day."
  (let ((attrs (file-attributes (drgnx-extensions-refresh-file))))
    (or (null attrs) (> (- (float-time) (float-time (file-attribute-modification-time attrs))) 86400))))

(defun drgnx-extensions-list--maybe-refresh-catalog ()
  "Start the refresh job when the catalog is old and the setting asks for daily checks."
  (when (and (eq (bound-and-true-p drgnx-extensions-check-updates) 'daily)
             (drgnx-extensions-list-catalog-stale-p)
             (fboundp 'drgnx-extensions-jobs-run))
    (drgnx-extensions-jobs-run 'refresh)))

;;;; The job layer's state: busy rows, drawn once a second

(defun drgnx-extensions-list--busy-ids ()
  "The ids of the rows in the list whose job is busy."
  (let (out)
    (maphash (lambda (id st) (when (and (eq (plist-get st :status) 'busy) (drgnx-extensions-list-row id))
                               (push id out)))
             drgnx-extensions-list--jobs)
    (sort out #'string<)))

(defun drgnx-extensions-list--view ()
  "The view of the list's buffer, or nil."
  (when-let* ((b (get-buffer drgnx-extensions-list-buffer-name)))
    (buffer-local-value 'drgnx-view b)))

(defun drgnx-extensions-list--tick ()
  "The one-second timer: draw the busy rows again (their elapsed time); stop when none is busy."
  (let ((view (drgnx-extensions-list--view)) (busy (drgnx-extensions-list--busy-ids)))
    (cond ((not (and view busy)) (drgnx-timer-cancel 'extensions-list-tick))
          ((drgnx-extensions-list--hub-fed-p) (drgnx-extensions-list--rows-chips busy))
          (t (drgnx-view-dirty view busy)))))

(defun drgnx-extensions-list--tick-update ()
  "Run the one-second timer while a row is busy, and not otherwise."
  (let ((buffer (get-buffer drgnx-extensions-list-buffer-name)))
    (if (and buffer (drgnx-extensions-list--busy-ids))
        (unless (drgnx-timer-active-p 'extensions-list-tick)
          (drgnx-timer-start 'extensions-list-tick 1 #'drgnx-extensions-list--tick :repeat 1 :owner buffer))
      (drgnx-timer-cancel 'extensions-list-tick))))

(defun drgnx-extensions-list--note-restart ()
  "Keep a copy of the ids that wait for a restart (the live layer's answer: a list of names or ids, or a count)."
  (setq drgnx-extensions-list--restart
        (when (fboundp 'drgnx-extensions-live-restart-pending)
          (let ((r (drgnx-extensions-live-restart-pending)))
            (when (listp r)
              (mapcar (lambda (x) (let ((s (format "%s" x))) (if (string-search ":" s) s (concat "pkg:" s)))) r))))))

(defun drgnx-extensions-list--row-id (x)
  "The row id of X as the job layer names it: a package (a symbol or a bare name) is \"pkg:NAME\", an id stays; a
ticket (an integer) has no row, nil."
  (cond ((integerp x) nil)
        ((and (stringp x) (string-search ":" x)) x)
        (t (concat "pkg:" (format "%s" x)))))

(defun drgnx-extensions-list--jobs-changed (ids)
  "`drgnx-extensions-jobs-changed-functions': read the state of IDS, draw their rows, start or stop the timer."
  (let (shown)
    (dolist (name ids)
      (let* ((id (drgnx-extensions-list--row-id name))
             (st (and id (fboundp 'drgnx-extensions-jobs-state) (drgnx-extensions-jobs-state name))))
        (when id
          (if st (puthash id st drgnx-extensions-list--jobs) (remhash id drgnx-extensions-list--jobs))
          (when (drgnx-extensions-list-row id) (push id shown)))))
    (let ((restart drgnx-extensions-list--restart))
      (drgnx-extensions-list--note-restart)
      (when-let* ((view (drgnx-extensions-list--view)))
        (cond ((not (drgnx-extensions-list--hub-fed-p)) (when shown (drgnx-view-dirty view shown)))
              ((equal restart drgnx-extensions-list--restart) (drgnx-extensions-list--rows-chips shown))
              (t (drgnx-extensions-list--rows-chips shown) (drgnx-extensions-list--ask)))   ; "restart to use" is the hub's
        (drgnx-extensions-list--header)))
    (drgnx-extensions-list--tick-update)))

;;;; Drawing

(defun drgnx-extensions-list--glyph (row)
  (drgnx-face-glyph (pcase (plist-get row :kind) ('plugin 'plugin) ('module 'module) (_ 'package))))

(defun drgnx-extensions-list--trust (row)
  "The trust word of ROW's source, or nil."
  (pcase (plist-get row :signed)
    ('signed "signed") ('signing-archive "signed archive") ('unsigned-archive "unsigned archive") ('local "local") ('git-commit "Git commit")
    ('hash-approved "hash approved") (_ nil)))

(defun drgnx-extensions-list--job-chip (st)
  "The chip the job layer's state ST gives a row, or nil."
  (let ((warnings (plist-get st :warnings)))
    (concat
     (pcase (plist-get st :status)
       ('busy (propertize (format "%s %s%s · %ds" (drgnx-face-glyph 'busy) (or (plist-get st :step) "working")
                                  (if (and (plist-get st :i) (plist-get st :n)) (format " %d/%d" (plist-get st :i) (plist-get st :n)) "")
                                  (if (plist-get st :since) (max 0 (floor (- (float-time) (float-time (plist-get st :since))))) 0))
                          'face 'drgnx-status-info))
       ('queued (propertize "queued" 'face 'shadow))
       ('refused (propertize (or (plist-get st :error) "busy, try again") 'face 'drgnx-status-warn))
       ('failed (propertize (format "%s %s" (drgnx-face-glyph 'fail) (or (plist-get st :error) "failed with the batch"))
                            'face 'drgnx-status-fail))
       ('stopped (propertize "stopped" 'face 'shadow))
       (_ nil))
     (when warnings
       (propertize (format "%spartly compiled: %s" (if (plist-get st :status) " " "") (string-join (mapcar (lambda (w) (format "%s" w)) warnings) ", "))
                   'face 'drgnx-status-warn)))))

(defun drgnx-extensions-list--attention ()
  "The face of what needs you: the look's attention face when it exists, else the kit's needs-you face."
  (if (facep 'drgnx-status-attention) 'drgnx-status-attention 'drgnx-status-needs-you))

(defun drgnx-extensions-list--state-chip (row)
  "The chip the hub's state of ROW gives it, or nil."
  (pcase (plist-get row :state)
    ('unapproved (propertize "not approved: it does not run" 'face (drgnx-extensions-list--attention)))
    ('changed (propertize "changed: approve it again" 'face (drgnx-extensions-list--attention)))
    ('disabled (propertize "disabled" 'face 'shadow))
    ('broken (propertize "broken" 'face 'drgnx-status-fail))
    ('update (propertize (if (plist-get row :latest) (format "update to %s" (plist-get row :latest)) "update")
                         'face 'drgnx-status-warn))
    ('held (propertize "held" 'face 'drgnx-status-warn))
    ('incompat (propertize "needs a newer Emacs" 'face 'drgnx-status-warn))
    ('missing (propertize "missing: no archive you use has it" 'face 'drgnx-status-fail))
    ('failed (propertize "failed" 'face 'drgnx-status-fail))
    ('needs-package (propertize "waits for a package" 'face 'drgnx-status-warn))
    ('dependency (propertize "dependency" 'face 'drgnx-status-info))
    ('on (propertize "on" 'face 'drgnx-status-ok))
    ('off (propertize "off" 'face 'shadow))
    (_ nil)))

(defun drgnx-extensions-list--render-row (id)
  "The text of row ID: two lines (one when dense)."
  (let* ((row (gethash id drgnx-extensions-list--rows))
         (st (gethash id drgnx-extensions-list--jobs))
         (chip (or (and st (drgnx-extensions-list--job-chip st)) (drgnx-extensions-list--state-chip row)))
         (restart (and (member id drgnx-extensions-list--restart) (propertize "restart to use" 'face 'drgnx-status-warn))))
    (propertize
     (if (null row)
         (concat id "\n")
       (concat (drgnx-extensions-list--glyph row) " " (propertize (plist-get row :name) 'face 'bold)
               (if (plist-get row :version) (propertize (concat " " (plist-get row :version)) 'face 'shadow) "")
               (if chip (concat "  " chip) "")
               (if restart (concat "  " restart) "")
               "\n"
               (if (eq drgnx-extensions-list-density 'dense) ""
                 (concat "    " (propertize (string-join (delq nil (list (plist-get row :summary) (plist-get row :source)
                                                                         (drgnx-extensions-list--trust row)))
                                                         " · ")
                                            'face 'shadow)
                         "\n"))))
     'drgnx-extensions-id id)))

(defun drgnx-extensions-list--render (key)
  "The view's RENDER: KEY is a header `(section . NAME)' or a row id."
  (cond ((eq (car-safe key) 'gen) (drgnx-extensions-details-generation-row (cdr key)))
        ((equal key '(section . generations)) (propertize "Generations\n" 'face 'bold))
        ((consp key)
         (let ((data (cdr (assq (cdr key) drgnx-extensions-list--sections))))
           (propertize (format "%s (%d)\n" (cdr (assq (cdr key) drgnx-extensions-list--titles))
                               (if (eq (cdr key) 'search) (or (plist-get data :total) 0)
                                 (length (drgnx-extensions-list--section-ids (cdr key)))))
                       'face 'bold)))
        (t (drgnx-extensions-list--render-row key))))

(defun drgnx-extensions-list--sig (key)
  "The signature of KEY's row: what makes it draw again when it changes (headers: their count)."
  (cond ((eq (car-safe key) 'gen) (drgnx-extensions-details-generations))
        ((consp key)
         (vector (plist-get (cdr (assq (cdr key) drgnx-extensions-list--sections)) :total)
                 (length (drgnx-extensions-list--section-ids (cdr key)))))
        (t (gethash key drgnx-extensions-list--rows key))))

(defun drgnx-extensions-list--sync (_view)
  (drgnx-view-sync-rows drgnx-view (drgnx-extensions-list--keys) #'drgnx-extensions-list--sig))

(defun drgnx-extensions-list--define-view ()
  "Define the view type `extensions' (its undo goes with the module that calls this in its setup)."
  (drgnx-view-define 'extensions :render #'drgnx-extensions-list--render :sync #'drgnx-extensions-list--sync :delay 0
                     :slice drgnx-view-slice))

(defun drgnx-extensions-list--header ()
  "Set the header line of the list: the query and its chips, an error, and the restart note.  Cached values only."
  (when-let* ((b (get-buffer drgnx-extensions-list-buffer-name)))
    (with-current-buffer b
      (let* ((n (length drgnx-extensions-list--restart))
             (text (string-replace
                    "%" "%%"
                    (concat "Extensions"
                            (if (drgnx-extensions-list--typed-p) (concat "  /" drgnx-extensions-list--query "  "
                                                                         (drgnx-extensions-list--chips (drgnx-extensions-list--parsed)))
                              "  / to search, @ for filters")
                            (if drgnx-extensions-list--error (propertize (concat "  " drgnx-extensions-list--error) 'face 'drgnx-status-fail) "")
                            (if (> n 0) (propertize (format "  %d update%s wait%s for a restart  " n (if (= n 1) "" "s") (if (= n 1) "s" ""))
                                                    'face 'drgnx-status-warn)
                              "")))))
        (setq header-line-format
              (list text (and (> n 0) (drgnx-ui-button "Restart drgnx" 'extensions-restart :where 'header-line
                                                       :help "Restart drgnx to use what changed"))))))))

(defun drgnx-extensions-list--changed ()
  "The model changed: the view takes the new rows, the header and the status bar are drawn again."
  (unless (drgnx-extensions-list--hub-fed-p)       ; the hub's rows come as patches
    (when-let* ((view (drgnx-extensions-list--view))) (drgnx-view-touch view)))
  (drgnx-extensions-list--header)
  (when (fboundp 'drgnx-statusbar-refresh) (drgnx-statusbar-refresh t)))

;;;; The buffer

(defvar drgnx-extensions-mode-map (make-sparse-keymap)
  "Keys of the Extensions list.  The key profiles bind them (`drgnx-command-define', keys/*.eld).")

(define-derived-mode drgnx-extensions-mode special-mode "Extensions"
  "The Extensions list: packages, plugins and modules in one place."
  (setq-local truncate-lines t cursor-type nil
              revert-buffer-function (lambda (&rest _) (drgnx-extensions-list-refresh)))
  (buffer-disable-undo)
  (add-hook 'post-command-hook #'drgnx-extensions-list--post-command nil t))

(defun drgnx-extensions-list--buffer ()
  "The list's buffer: made with its view when it does not exist yet."
  (or (get-buffer drgnx-extensions-list-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-extensions-list-buffer-name)
        (unless (drgnx-view-type-p 'extensions) (drgnx-extensions-list--define-view))
        (drgnx-extensions-mode)
        (if (drgnx-extensions-list-rows-p)
            (drgnx-extensions-list--rows-attach)
          (drgnx-view-attach 'extensions)
          (drgnx-view-touch drgnx-view))
        (drgnx-extensions-list--header)
        (drgnx-extensions-list--tick-update)
        (current-buffer))))

(defun drgnx-extensions-list--teardown ()
  "Close the list and stop what it started."
  (when-let* ((b (get-buffer drgnx-extensions-list-buffer-name))) (kill-buffer b))
  (drgnx-timer-cancel 'extensions-list-tick)
  (drgnx-timer-cancel 'extensions-list-search)
  (drgnx-extensions-list--reset))

;;;; On the rows path: the hub builds the list, its model holds the rows (Sjá)
;; Off `drgnx-view-old-path' in an Emacs with Sjá, the list is the hub-fed view `extensions': `extensions/list' names
;; the sections (each a search, as `drgnx-extensions-list--section-params' makes it) and the hub sends the model (a
;; `tree': a node per header and per row, the row's name, kind, state, signed, source, version and latest as fields)
;; and the rows, headers and lines included.  The answer is each section's total.  A row's data is read from the model
;; (`drgnx-extensions-list-row'), point's row is the model's selection, and a job's chip is an overlay at the end of
;; the row's first line, put back after each draw: the busy tick moves overlays, never rows.

(declare-function nidhogg-view-get "nidhogg-views" (h what &optional arg arg2))
(declare-function drgnx-view-env-register "drgnx-view-env" (view buffer &optional resubscribe))

(defconst drgnx-extensions-list-view "extensions" "The hub's view id of the list.")

(defun drgnx-extensions-list-rows-p ()
  "Non-nil when the list goes on the hub's rows: not `drgnx-view-old-path', and this Emacs has Sjá."
  (and (not drgnx-view-old-path) (fboundp 'nidhogg-view--call)))

(defun drgnx-extensions-list--hub-fed-p ()
  "Non-nil when the list's buffer is the hub-fed view."
  (when-let* ((b (get-buffer drgnx-extensions-list-buffer-name))) (buffer-local-value 'drgnx-view-patch b)))

(defun drgnx-extensions-list-row (id)
  "Row ID as the list knows it (:id :name :kind :state :signed :source :version :latest, the symbols interned), or
nil: the hub's answer kept off the rows path, the model's fields on it."
  (if (not (drgnx-extensions-list--hub-fed-p))
      (gethash id drgnx-extensions-list--rows)
    (with-current-buffer drgnx-extensions-list-buffer-name
      (when-let* ((h (drgnx-view-patch-handle drgnx-view-patch)) (kind (nidhogg-view-get h 'kind id))
                  ((not (equal kind "section"))))
        (let ((f (lambda (name) (nidhogg-view-get h 'field name id))))
          (list :id id :name (funcall f "name") :kind (intern kind) :state (intern (funcall f "state"))
                :signed (intern (funcall f "signed")) :source (funcall f "source")
                :version (funcall f "version") :latest (funcall f "latest")))))))

(defun drgnx-extensions-list--list-params ()
  "The params of `extensions/list': the sections shown now, each with the rows loaded of it, the density, the glyphs
and the rows that wait for a restart."
  (let ((sections (if (drgnx-extensions-list--typed-p) '(search) drgnx-extensions-list--sections-order)))
    (list :view drgnx-extensions-list-view
          :sections (vconcat
                     (mapcar (lambda (s)
                               (let ((params (drgnx-extensions-list--section-params s)))
                                 (list :name (symbol-name s) :title (cdr (assq s drgnx-extensions-list--titles))
                                       :search (plist-put params :limit (or (alist-get s drgnx-extensions-list--limits)
                                                                            drgnx-extensions-list--page))
                                       :minus_updates (if (eq s 'installed) t :false))))
                             sections))
          :dense (if (eq drgnx-extensions-list-density 'dense) t :false)
          :glyphs (vconcat (mapcar (lambda (k) (list :kind (symbol-name k) :gui (or (drgnx-face-glyph k) "")
                                                     :tty (or (cdr (alist-get k (append drgnx-face-glyphs drgnx-ui--default-glyphs))) "")))
                                   '(package plugin module)))
          :restart (vconcat drgnx-extensions-list--restart))))

(defun drgnx-extensions-list--ask (&optional _view)
  "Ask the hub for the list's rows, without waiting; the answer's totals go to `drgnx-extensions-list--listed'.  Also
the env's resubscribe."
  (unless (fboundp 'drgnx-hub-call) (require 'drgnx-hub-client))
  (let ((epoch drgnx-extensions-list--epoch))
    (condition-case err
        (drgnx-hub-call "extensions/list" (drgnx-extensions-list--list-params)
                        (lambda (result error)
                          (when (eql epoch drgnx-extensions-list--epoch)
                            (if error
                                (setq drgnx-extensions-list--error (format "%s" error))
                              (setq drgnx-extensions-list--error nil)
                              (drgnx-extensions-list--listed (plist-get result :sections)))
                            (drgnx-extensions-list--changed))))
      (error (setq drgnx-extensions-list--error (error-message-string err))
             (drgnx-extensions-list--changed)))))

(defun drgnx-extensions-list--listed (totals)
  "The hub's TOTALS for the sections it listed: what each matched and how many rows the list holds of it."
  (setq drgnx-extensions-list--sections
        (mapcar (lambda (s) (cons (intern (plist-get s :name)) (list :total (plist-get s :total) :loaded (plist-get s :loaded))))
                totals))
  (when-let* ((u (assq 'updates drgnx-extensions-list--sections)))
    (setq drgnx-extensions-list--updates (plist-get (cdr u) :total))))

(defun drgnx-extensions-list--update-ids ()
  "The ids Updates lists: its answer's off the rows path, the model's rows of the section `updates' on it."
  (if (not (drgnx-extensions-list--hub-fed-p))
      (plist-get (cdr (assq 'updates drgnx-extensions-list--sections)) :ids)
    (with-current-buffer drgnx-extensions-list-buffer-name
      (let ((h (drgnx-view-patch-handle drgnx-view-patch)))
        (seq-filter (lambda (id) (and (equal (nidhogg-view-get h 'field "section" id) "updates")
                                      (not (equal (nidhogg-view-get h 'kind id) "section"))))
                    (append (nidhogg-view-get h 'list "order") nil))))))

(defun drgnx-extensions-list--rows-more (section loaded)
  "Ask for a page more of SECTION, which holds LOADED rows."
  (setf (alist-get section drgnx-extensions-list--limits) (+ loaded drgnx-extensions-list--page))
  (drgnx-extensions-list--ask))

(defun drgnx-extensions-list--rows-last ()
  "On the rows path, the section whose rows end the list, with rows still to load: (SECTION . LOADED), or nil."
  (when-let* ((s (car (last (seq-filter (lambda (s) (> (or (plist-get (cdr s) :loaded) 0) 0))
                                        drgnx-extensions-list--sections))))
              ((< (plist-get (cdr s) :loaded) (or (plist-get (cdr s) :total) 0))))
    (cons (car s) (plist-get (cdr s) :loaded))))

(defun drgnx-extensions-list--rows-chips (ids)
  "Show the job chips of IDS at the end of their rows' first lines (an overlay each; none when no job is there)."
  (when-let* ((b (get-buffer drgnx-extensions-list-buffer-name)))
    (with-current-buffer b
      (dolist (id ids)
        (let* ((st (gethash id drgnx-extensions-list--jobs)) (chip (and st (drgnx-extensions-list--job-chip st)))
               (ov (gethash id drgnx-extensions-list--chips))
               (beg (and chip drgnx-view (drgnx-view-row-start drgnx-view id))))
          (if (not beg)
              (when ov (delete-overlay ov) (remhash id drgnx-extensions-list--chips))
            (let ((end (save-excursion (goto-char beg) (line-end-position))))
              (if ov (move-overlay ov end end) (setq ov (make-overlay end end)) (puthash id ov drgnx-extensions-list--chips))
              (overlay-put ov 'after-string (concat "  " chip)))))))))

(defun drgnx-extensions-list--rows-patched (_view keys)
  "`drgnx-view-patch-patched-functions' of the list: the chips of the rows KEYS that were drawn go back on."
  (drgnx-extensions-list--rows-chips (seq-filter (lambda (k) (gethash k drgnx-extensions-list--jobs)) keys)))

(defun drgnx-extensions-list--rows-attach ()
  "Make the current buffer the hub-fed view of the list: its env goes when it is shown, and it asks again then."
  (drgnx-view-patch-attach drgnx-extensions-list-view "unshown")
  (add-hook 'drgnx-view-patch-patched-functions #'drgnx-extensions-list--rows-patched nil t)
  (require 'drgnx-view-env)
  (drgnx-view-env-register drgnx-extensions-list-view (current-buffer) #'drgnx-extensions-list--ask))

;;;; Commands

(defun drgnx-extensions-list--id-at-point ()
  "The id of the row at point, or a `user-error'.  On the rows path it becomes the model's selection."
  (let ((id (or (get-text-property (point) 'drgnx-extensions-id)
                (and (> (point) (point-min)) (get-text-property (1- (point)) 'drgnx-extensions-id))
                (user-error "No extension on this line"))))
    (when (and drgnx-view-patch (drgnx-view-patch-handle drgnx-view-patch) (not (equal id (drgnx-view-nav-selection))))
      (drgnx-view-nav 'select id))
    id))

(defun drgnx-extensions-list--name (id)
  "The name part of the row id ID (`pkg:magit' → \"magit\")."
  (substring id (1+ (or (string-search ":" id) -1))))

(defun drgnx-extensions-list--package-name ()
  "The name of the package at point; other kinds are a `user-error'."
  (let ((id (drgnx-extensions-list--id-at-point)))
    (unless (string-prefix-p "pkg:" id) (user-error "%s is not a package" (drgnx-extensions-list--name id)))
    (drgnx-extensions-list--name id)))

(defun drgnx-extensions-list-note-root ()
  "Remember the current buffer's project, unless it is the list or a page (opening one from another keeps it)."
  (unless (or (derived-mode-p 'drgnx-extensions-mode) (bound-and-true-p drgnx-extensions-details--id))
    (setq drgnx-extensions-list--root
          (and buffer-file-name (fboundp 'drgnx-extensions-project--root)
               (drgnx-extensions-project--root buffer-file-name)))))

(defun drgnx-extensions-list--require (fn)
  (unless (fboundp fn) (user-error "%s is not available (its module is off)" fn)))

;;;###autoload
(defun drgnx-extensions-open ()
  "Open the Extensions list.  Opened from a file of a project, it remembers that project (`p', @this-project)."
  (interactive)
  (drgnx-extensions-list-note-root)
  (let ((b (drgnx-extensions-list--buffer)))
    (drgnx-extensions-list-refresh)
    (drgnx-extensions-list--maybe-refresh-catalog)
    (pop-to-buffer b)))

(defun drgnx-extensions-list--apply-query (text)
  "TEXT is the search now: show its results (or the sections, when it is empty)."
  (unless (equal text drgnx-extensions-list--query)
    (setq drgnx-extensions-list--query text drgnx-extensions-list--parsed nil
          drgnx-extensions-list--epoch (1+ drgnx-extensions-list--epoch))
    (clrhash drgnx-extensions-list--asked)
    (setq drgnx-extensions-list--limits nil)
    (setq drgnx-extensions-list--sections (assq-delete-all 'search drgnx-extensions-list--sections))
    (when (plist-get (plist-get (drgnx-extensions-list--parsed) :filters) :updates)
      (drgnx-extensions-list--maybe-refresh-catalog))
    (if (drgnx-extensions-list--typed-p)
        (drgnx-extensions-list--fetch 'search 0)
      (drgnx-extensions-list-refresh))
    (drgnx-extensions-list--changed)))

(defun drgnx-extensions-list--typing ()
  "`after-change-functions' of the search's minibuffer: apply the text a moment after the last key."
  (drgnx-timer-debounce 'extensions-list-search 0.15 #'drgnx-extensions-list--apply-query
                        :args (list (minibuffer-contents-no-properties)) :owner (current-buffer)))

(defun drgnx-extensions-list--minibuffer-setup ()
  (add-hook 'after-change-functions (lambda (&rest _) (drgnx-extensions-list--typing)) nil t))

(defun drgnx-extensions-search ()
  "Search the extensions; the list follows what you type.  Words after @ filter: @installed @updates @recommended
@enabled @disabled @builtin @plugins @generations @this-project @failed @archive:A @kind:K @keyword:W @unsigned @restart
@sort:name|downloads|updated|installed."
  (interactive)
  (drgnx-extensions-list--buffer)
  (let ((text (minibuffer-with-setup-hook #'drgnx-extensions-list--minibuffer-setup
                (read-from-minibuffer "Search extensions: " drgnx-extensions-list--query))))
    (drgnx-extensions-list--apply-query text)))

(defvar drgnx-extensions-list--details-id nil "The id the last RET opened: a second RET on it pins the page.")

(defun drgnx-extensions-details ()
  "Open the details page of the extension at point; again on the same one keeps the page."
  (interactive)
  (drgnx-extensions-list--require 'drgnx-extensions-details-open)
  (let ((id (drgnx-extensions-list--id-at-point)))
    (pop-to-buffer (drgnx-extensions-details-open id (equal id drgnx-extensions-list--details-id)))
    (setq drgnx-extensions-list--details-id id)))

(defun drgnx-extensions--before-install (entry)
  "Queue ENTRY (an `:add' entry) once the trust layer lets it through: at once for a signed source or a package whose
trust card was seen here, else when the card's Install is clicked (`drgnx-extensions-trust-before-install').  Without
the trust layer nothing is queued: an install never skips its card."
  (unless (fboundp 'drgnx-extensions-trust-before-install)
    (user-error "Extensions: the trust check is not loaded, so nothing was installed"))
  (drgnx-extensions-trust-before-install (format "pkg:%s" (plist-get entry :add))
                                         (lambda () (drgnx-extensions-jobs-queue entry))))

(defun drgnx-extensions-install ()
  "Queue the install of the package at point: the job layer runs it, the row shows its progress.  A package from a
source that does not sign shows its trust card first, the first time."
  (interactive)
  (drgnx-extensions-list--require 'drgnx-extensions-jobs-queue)
  (drgnx-extensions--before-install (list :add (intern (drgnx-extensions-list--package-name)))))

(defun drgnx-extensions-uninstall ()
  "Queue the removal of the package at point (no question: a rollback brings it back).  A package something else
needs is refused, and the row says why."
  (interactive)
  (drgnx-extensions-list--require 'drgnx-extensions-jobs-queue)
  (drgnx-extensions-jobs-queue (list :remove (intern (drgnx-extensions-list--package-name)))))

(defun drgnx-extensions--update (name)
  "Update the package NAME; when its updates are reviewed first (`drgnx-extensions-review'), show its page, where the
update is compared with the installed copy before Apply."
  (if (and (fboundp 'drgnx-extensions-trust-update) (eq (drgnx-extensions-trust-update name) 'review))
      (pop-to-buffer (drgnx-extensions-details-open (concat "pkg:" name) t))
    (unless (fboundp 'drgnx-extensions-trust-update) (drgnx-extensions-jobs-run 'upgrade (list name)))))

(defun drgnx-extensions-update ()
  "Update the package at point."
  (interactive)
  (drgnx-extensions-list--require 'drgnx-extensions-jobs-run)
  (drgnx-extensions--update (drgnx-extensions-list--package-name)))

(defun drgnx-extensions-update-all ()
  "Update every package that has an update, except those whose updates you review first: they wait on their pages."
  (interactive)
  (drgnx-extensions-list--require 'drgnx-extensions-jobs-run)
  (if (not (bound-and-true-p drgnx-extensions-review))
      (drgnx-extensions-jobs-run 'upgrade-all)
    (let (names reviewed)
      (dolist (id (drgnx-extensions-list--update-ids))
        (let* ((row (drgnx-extensions-list-row id)) (name (plist-get row :name)))
          (when (and name (eq (plist-get row :kind) 'package))
            (if (and (fboundp 'drgnx-extensions-trust-review-p) (drgnx-extensions-trust-review-p name (plist-get row :source)))
                (push name reviewed)
              (push name names)))))
      (when names (drgnx-extensions-jobs-run 'upgrade (nreverse names)))
      (when reviewed
        (message "Not updated, you review them first: %s (Update on each)" (string-join (nreverse reviewed) ", "))))))

(defun drgnx-extensions-refresh ()
  "Read the archives again (a job), then the list again."
  (interactive)
  (drgnx-extensions-list--require 'drgnx-extensions-jobs-run)
  (drgnx-extensions-jobs-run 'refresh)
  (drgnx-extensions-list-refresh))

(defun drgnx-extensions-cancel ()
  "Cancel the job or the queued click of the row at point.  C-g never stops a job; this does."
  (interactive)
  (drgnx-extensions-list--require 'drgnx-extensions-jobs-cancel)
  (let* ((id (drgnx-extensions-list--id-at-point)) (st (gethash id drgnx-extensions-list--jobs)))
    (cond ((plist-get st :job) (drgnx-extensions-jobs-cancel (plist-get st :job)))
          ((plist-get st :tickets) (dolist (tk (plist-get st :tickets)) (drgnx-extensions-jobs-cancel tk)))
          (t (user-error "Nothing runs for %s" (drgnx-extensions-list--name id))))))

(defun drgnx-extensions-show-log (&optional id)
  "Show the log of the job of the row at point (or of ID)."
  (interactive)
  (let* ((id (or id (drgnx-extensions-list--id-at-point))) (job (plist-get (gethash id drgnx-extensions-list--jobs) :job)))
    (unless job (user-error "%s has no job" (drgnx-extensions-list--name id)))
    (unless (fboundp 'drgnx-exec-log) (require 'drgnx-exec))
    (let ((text (drgnx-exec-log job 65536)))
      (when-let* ((old (get-buffer "*Extensions log*"))) (kill-buffer old))   ; a new buffer, not an erased one
      (with-current-buffer (get-buffer-create "*Extensions log*")
        (buffer-disable-undo)
        (insert text)
        (goto-char (point-min))
        (special-mode)
        (pop-to-buffer (current-buffer))))))

(defun drgnx-extensions-list-project-root ()
  "The project the list was opened from (`drgnx-extensions-list--root'), or a `user-error' when there is none."
  (or drgnx-extensions-list--root
      (user-error "Extensions: open the list from a file of a project to turn a package off there")))

(defun drgnx-extensions-toggle-project ()
  "Turn the package at point on or off in the project the list was opened from (drgnx-extensions-project.el)."
  (interactive)
  (drgnx-extensions-list--require 'drgnx-extensions-project-toggle)
  (let ((name (drgnx-extensions-list--package-name)))
    (drgnx-extensions-project-toggle (intern name) (drgnx-extensions-list-project-root))
    (message "%s: %s" name (drgnx-extensions-project-describe (intern name) drgnx-extensions-list--root))
    (drgnx-extensions-list--changed)))

(provide 'drgnx-extensions-list)
;;; drgnx-extensions-list.el ends here
