;;; drgnx-quick-open.el --- Quick Open that shows files while they are still being listed -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; With the hub up, the hub ranks: each key sends `search/files' (the query, the root) and the table shows the rows the
;; hub answers with, the best 100 of the root's names (Hrafn's list: git's in a repository, a walk elsewhere; the
;; setting `drgnx-search-ignore-rules' decides whether dot paths and secret-looking names are in it).  A key never
;; waits for rows: the rows shown stay until the answer's patch arrives, and a patch of an older query is dropped by
;; the patch rules (`drgnx-view-patch--accept': its base is behind the version).  The rows are kept as a list of keys
;; here, not in a view buffer: vertico does the moving.
;;
;; Without the hub (or behind `drgnx-view-old-path'), Quick Open of a big project streams the listing: with Nidhogg's
;; framing on (see core/drgnx-file-stream.el) the files arrive in batches and the list grows under your cursor; without
;; it, or on a remote folder, Quick Open is `project-find-file' as before.
;;
;; The list and the highlight are a pure core, `drgnx-quick-open--step': a state and an event give a state.  The events
;; are (batch NAMES), (input STRING), (move N) and (done).  The candidates are the names containing every word of the
;; input, those whose file name contains them all first, then the shorter, then by name.  The highlighted candidate
;; is kept by its identity (its name): a batch adds candidates and re-sorts, and the highlight stays on the same
;; file wherever it moves to; it moves only on `input' (to the best match) and `move'.  The shell below feeds the
;; core and vertico.  See docs/guide/modules.md ("Quick Open").

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-file-stream)
(require 'drgnx-view)

(defvar drgnx-hub--events)
(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-view-env-register "drgnx-view-env")
(declare-function drgnx-view-env-unregister "drgnx-view-env")

;;;; The core

(cl-defstruct (drgnx-quick-open--s (:constructor drgnx-quick-open--s-make) (:copier drgnx-quick-open--s-copy))
  "NAMES: every name received (newest batch first); INPUT: what is typed; DONE: the listing ended; SEL: the
highlighted name, or nil; LIST: the matches, ranked, as (KEY . NAME)."
  names (input "") done sel list)

(defun drgnx-quick-open--init () (drgnx-quick-open--s-make))

(defun drgnx-quick-open--words (input) (split-string (downcase input) " " t))

(defun drgnx-quick-open--entry (name words)
  "(KEY . NAME) when NAME contains every one of WORDS (lower case), else nil.  KEY sorts: a file name that contains
them all (0) before a path that does (1), then the shorter."
  (let* ((low (downcase name)) (base (file-name-nondirectory low)))
    (when (cl-every (lambda (w) (string-search w low)) words)
      (cons (+ (* (if (cl-every (lambda (w) (string-search w base)) words) 0 1) 100000) (min (length name) 99999))
            name))))

(defun drgnx-quick-open--entry< (a b)
  (or (< (car a) (car b)) (and (= (car a) (car b)) (string< (cdr a) (cdr b)))))

(defun drgnx-quick-open--candidates (state)
  "STATE's matches, best first, as names."
  (mapcar #'cdr (drgnx-quick-open--s-list state)))

(defun drgnx-quick-open--step (state event)
  "STATE after EVENT, as (STATE . nil).  STATE is not changed.  See the commentary for the events."
  (let ((s (drgnx-quick-open--s-copy state)))
    (pcase event
      (`(batch ,names)
       (setf (drgnx-quick-open--s-names s) (cons names (drgnx-quick-open--s-names s)))
       (let* ((words (drgnx-quick-open--words (drgnx-quick-open--s-input s)))
              (new (delq nil (mapcar (lambda (n) (drgnx-quick-open--entry n words)) names))))
         (setf (drgnx-quick-open--s-list s)
               (sort (append new (drgnx-quick-open--s-list s) nil) #'drgnx-quick-open--entry<))) ; a copy: sort is destructive
       ;; the highlight stays where it is; the first candidate gets it when nothing has
       (unless (drgnx-quick-open--s-sel s)
         (setf (drgnx-quick-open--s-sel s) (cdr (car (drgnx-quick-open--s-list s))))))
      (`(input ,string)
       (setf (drgnx-quick-open--s-input s) string)
       (let ((words (drgnx-quick-open--words string)))
         (setf (drgnx-quick-open--s-list s)
               (sort (delq nil (mapcar (lambda (n) (drgnx-quick-open--entry n words))
                                       (apply #'append (drgnx-quick-open--s-names s))))
                     #'drgnx-quick-open--entry<)))
       (setf (drgnx-quick-open--s-sel s) (cdr (car (drgnx-quick-open--s-list s)))))
      (`(move ,n)
       (let* ((names (drgnx-quick-open--candidates s)) (at (cl-position (drgnx-quick-open--s-sel s) names :test #'equal)))
         (when (and names at)
           (setf (drgnx-quick-open--s-sel s) (nth (max 0 (min (1- (length names)) (+ at n))) names)))))
      (`(done) (setf (drgnx-quick-open--s-done s) t)))
    (cons s nil)))

;;;; The shell: the listing, the minibuffer, vertico

(defvar drgnx-quick-open--state nil "The core's state while Quick Open runs.")
(defvar drgnx-quick-open--stream nil "The running listing.")
(defvar drgnx-quick-open--buffer nil "The minibuffer Quick Open feeds.")

(defvar vertico--index)
(defvar vertico--input)
(defvar vertico--candidates)
(declare-function vertico--exhibit "vertico")
(declare-function vertico--candidate "vertico")
(declare-function project-current "project")
(declare-function project-root "project")
(declare-function project-find-file "project")

(defun drgnx-quick-open--table (string pred action)
  "The completion table: the core's candidates, in the core's order (the core filters; the style does not re-sort)."
  (let ((names (drgnx-quick-open--candidates drgnx-quick-open--state)))
    (cond ((eq action 'metadata)
           '(metadata (category . project-file) (display-sort-function . identity) (cycle-sort-function . identity)))
          ((eq action t) (copy-sequence names))        ; all of them: `complete-with-action' would keep only a prefix match
          ((null action) (try-completion string names pred))
          ((eq action 'lambda) (test-completion string names pred)))))

(defun drgnx-quick-open--style-all (string table pred _point)
  "A completion style that keeps what the table gives: the core has matched and ranked the candidates already, and the
user's styles (prefix, orderless) would filter them again by another rule."
  (when-let* ((all (all-completions string table pred))) (nconc all 0)))               ; base size 0: they are whole names

(defun drgnx-quick-open--style-try (string table pred _point)
  "The `try-completion' side of `drgnx-quick-open--style-all'."
  (let ((c (try-completion string table pred)))
    (cond ((eq c t) t) ((stringp c) (cons c (length c))))))

(defconst drgnx-quick-open--style
  '(drgnx-quick-open drgnx-quick-open--style-try drgnx-quick-open--style-all "The candidates the Quick Open core chose.")
  "The entry for `completion-styles-alist', bound only while Quick Open reads.")

(defun drgnx-quick-open--refresh ()
  "Show the core's candidates in the minibuffer, the highlight on its candidate.
Touches vertico's internals `vertico--input' (set to t so the next exhibit recomputes the candidates),
`vertico--candidates' and `vertico--index' (the position of the highlighted candidate) and `vertico--exhibit'; a vertico
update can break them, so each is checked and an error only reports.  Without vertico the list updates at the next key."
  (when (and (buffer-live-p drgnx-quick-open--buffer) (fboundp 'vertico--exhibit) (boundp 'vertico--input))
    (with-demoted-errors "Quick Open: %S"
      (with-current-buffer drgnx-quick-open--buffer
        (setq vertico--input t)
        (vertico--exhibit)
        (let ((at (cl-position (drgnx-quick-open--s-sel drgnx-quick-open--state) vertico--candidates :test #'equal)))
          (when (and at (not (eql at vertico--index)))
            (setq vertico--index at)
            (vertico--exhibit)))))))

(defun drgnx-quick-open--sync-highlight ()
  "Tell the core where the user moved the highlight in vertico (a `move' by the difference), before it changes the list."
  (when (and (buffer-live-p drgnx-quick-open--buffer) (fboundp 'vertico--candidate) (boundp 'vertico--candidates))
    (with-demoted-errors "Quick Open: %S"
      (let* ((shown (with-current-buffer drgnx-quick-open--buffer (vertico--candidate)))
             (names (drgnx-quick-open--candidates drgnx-quick-open--state))
             (to (cl-position shown names :test #'equal))
             (from (cl-position (drgnx-quick-open--s-sel drgnx-quick-open--state) names :test #'equal)))
        (when (and to from (/= to from)) (drgnx-quick-open--feed (list 'move (- to from)) t))))))

(defun drgnx-quick-open--feed (event &optional quiet)
  "Give EVENT to the core; show the result unless QUIET."
  (setq drgnx-quick-open--state (car (drgnx-quick-open--step drgnx-quick-open--state event)))
  (unless quiet (drgnx-quick-open--refresh)))

(defun drgnx-quick-open--input-changed (&rest _)
  (drgnx-quick-open--feed (list 'input (minibuffer-contents-no-properties))))

(defun drgnx-quick-open--setup ()
  (setq drgnx-quick-open--buffer (current-buffer))
  (add-hook 'after-change-functions #'drgnx-quick-open--input-changed nil t))

(defun drgnx-quick-open--root ()
  (require 'project)
  (expand-file-name (if-let* ((p (project-current nil))) (project-root p) default-directory)))

;;;; The hub path: the hub ranks, the table shows its rows

(defface drgnx-quick-open-match '((t :inherit completions-common-part))
  "The words of the query in a Quick Open or Find candidate."
  :group 'drgnx)

(defconst drgnx-quick-open-rows 100 "How many of the hub's best rows Quick Open shows.")

(defvar drgnx-quick-open-send-function #'drgnx-quick-open--send
  "Called with (METHOD PARAMS) to ask the hub without waiting (`search/files', `view/close'); tests capture it.")

(defvar drgnx-quick-open--views 0 "The number of the last Quick Open view (each run is a view of its own).")

(defun drgnx-quick-open--send (method params)
  "METHOD with PARAMS on the subscribed connection, the one the rows come on; nil while it is down."
  (when (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
    (require 'drgnx-hub-client)
    (drgnx-hub--call-on drgnx-hub--events method params #'ignore)
    t))

(defun drgnx-quick-open--hub-p (root)
  "Non-nil when the hub ranks ROOT's files: a local ROOT, the hub connected, and not the old path."
  (and (not drgnx-view-old-path) (not (file-remote-p root))
       (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events)))

(cl-defstruct (drgnx-quick-open--rows (:constructor drgnx-quick-open--rows--make) (:copier nil))
  "A hub-ranked list: VIEW (its id), ROOT, RULES (a `drgnx-view-patch': the base and version rules), KEYS (the rows'
paths, in order) and TEXT (KEY → the candidate, its words marked)."
  view root rules keys (text (make-hash-table :test #'equal)))

(defun drgnx-quick-open--rows-make (view root)
  (drgnx-quick-open--rows--make :view view :root root :rules (drgnx-view-patch--make :view view)))

(defun drgnx-quick-open--rows-query (r input &optional n)
  "Ask the hub for R's N best rows (default `drgnx-quick-open-rows') for INPUT; the rows shown stay until the answer's
patch."
  (funcall drgnx-quick-open-send-function "search/files"
           (list :view (drgnx-quick-open--rows-view r) :root (drgnx-quick-open--rows-root r) :query input
                 :n (or n drgnx-quick-open-rows))))

(defun drgnx-quick-open--rows-candidate (row)
  "ROW's candidate: its key, with its runs in `drgnx-quick-open-match'."
  (let ((c (copy-sequence (plist-get row :key))))
    (dolist (run (plist-get row :runs))
      (when (<= 0 (nth 0 run) (nth 1 run) (length c))
        (add-face-text-property (nth 0 run) (nth 1 run) 'drgnx-quick-open-match nil c)))
    c))

(defun drgnx-quick-open--rows-patch (r patch)
  "Apply PATCH (a `view-patch' event's data) to R when it is R's and the patch rules take it; non-nil when applied."
  (when (equal (plist-get patch :view) (drgnx-quick-open--rows-view r))
    (let ((state (drgnx-quick-open--rows-rules r)))
      (when (eq (drgnx-view-patch--accept state patch) 'apply)
        (let ((text (drgnx-quick-open--rows-text r)) (keys (drgnx-quick-open--rows-keys r)))
          (dolist (op (plist-get patch :ops))
            (cond
             ((plist-member op :reset)
              (clrhash text)
              (setq keys (mapcar (lambda (row) (puthash (plist-get row :key) (drgnx-quick-open--rows-candidate row) text)
                                   (plist-get row :key))
                                 (plist-get op :reset))))
             ((plist-member op :insert)
              (let* ((ins (plist-get op :insert)) (after (plist-get ins :after))
                     (new (mapcar (lambda (row) (puthash (plist-get row :key) (drgnx-quick-open--rows-candidate row) text)
                                    (plist-get row :key))
                                  (plist-get ins :rows))))
                (if (null after) (setq keys (append new keys))
                  (let ((tail (member after keys)))
                    (if tail (setcdr tail (append new (cdr tail))) (setq keys (append keys new)))))))
             ((plist-member op :replace)
              (dolist (row (plist-get op :replace))
                (puthash (plist-get row :key) (drgnx-quick-open--rows-candidate row) text)))
             ((plist-member op :remove)
              (let ((gone (plist-get op :remove)))
                (dolist (k gone) (remhash k text))
                (setq keys (seq-remove (lambda (k) (member k gone)) keys))))))
          (setf (drgnx-quick-open--rows-keys r) keys))
        t))))

(defun drgnx-quick-open--rows-candidates (r)
  "R's candidates, best first."
  (let ((text (drgnx-quick-open--rows-text r)))
    (mapcar (lambda (k) (gethash k text k)) (drgnx-quick-open--rows-keys r))))

(defvar drgnx-quick-open--current nil "The hub-ranked list while Quick Open reads.")

(defun drgnx-quick-open--rows-table (string pred action)
  "The completion table of the hub path: the hub's rows, in its order."
  (let ((names (and drgnx-quick-open--current (drgnx-quick-open--rows-candidates drgnx-quick-open--current))))
    (cond ((eq action 'metadata)
           '(metadata (category . project-file) (display-sort-function . identity) (cycle-sort-function . identity)))
          ((eq action t) (copy-sequence names))
          ((null action) (try-completion string names pred))
          ((eq action 'lambda) (test-completion string names pred)))))

(defun drgnx-quick-open--rows-event (event data)
  "A `drgnx-hub-event-functions' handler while Quick Open reads: its view's patches change the table."
  (when (and (equal event "view-patch") drgnx-quick-open--current
             (drgnx-quick-open--rows-patch drgnx-quick-open--current data))
    (drgnx-quick-open--rows-refresh)))

(defun drgnx-quick-open--rows-refresh ()
  "Show the rows in the minibuffer now (vertico; without it the list updates at the next key)."
  (when (and (buffer-live-p drgnx-quick-open--buffer) (fboundp 'vertico--exhibit) (boundp 'vertico--input))
    (with-demoted-errors "Quick Open: %S"
      (with-current-buffer drgnx-quick-open--buffer
        (setq vertico--input t)
        (vertico--exhibit)))))

(defun drgnx-quick-open--rows-input (&rest _)
  "The input changed: send its query and return; the rows come when the hub answers."
  (when drgnx-quick-open--current
    (drgnx-quick-open--rows-query drgnx-quick-open--current (minibuffer-contents-no-properties))))

(defun drgnx-quick-open--rows-setup ()
  (setq drgnx-quick-open--buffer (current-buffer))
  (require 'drgnx-view-env)
  (drgnx-view-env-register (drgnx-quick-open--rows-view drgnx-quick-open--current) (current-buffer))
  (add-hook 'after-change-functions #'drgnx-quick-open--rows-input nil t)
  (drgnx-quick-open--rows-query drgnx-quick-open--current ""))

(defun drgnx-quick-open--read-rows (root)
  "Quick Open of ROOT ranked by the hub; the file chosen is opened."
  (let* ((view (format "quick-open-%d" (cl-incf drgnx-quick-open--views)))
         (drgnx-quick-open--current (drgnx-quick-open--rows-make view root))
         (drgnx-quick-open--buffer nil))
    (add-hook 'drgnx-hub-event-functions #'drgnx-quick-open--rows-event)
    (unwind-protect
        (let ((choice (let ((completion-styles-alist (cons drgnx-quick-open--style completion-styles-alist))
                            (completion-styles '(drgnx-quick-open))
                            (completion-category-overrides nil) (completion-category-defaults nil))
                        (minibuffer-with-setup-hook #'drgnx-quick-open--rows-setup
                          (completing-read "Quick Open: " #'drgnx-quick-open--rows-table nil t)))))
          (find-file (expand-file-name choice root)))
      (remove-hook 'drgnx-hub-event-functions #'drgnx-quick-open--rows-event)
      (drgnx-view-env-unregister view)
      (funcall drgnx-quick-open-send-function "view/close" (list :view view)))))

;;;###autoload
(defun drgnx-quick-open ()
  "Open a file of the project by name: the hub ranks the project's files as you type.
Without the hub the list grows while the project is still being listed; without Nidhogg's framing too (or on a
remote folder) this is `project-find-file'."
  (interactive)
  (let ((root (drgnx-quick-open--root)))
    (cond ((file-remote-p root) (call-interactively #'project-find-file))
          ((drgnx-quick-open--hub-p root) (drgnx-quick-open--read-rows root))
          (t (drgnx-quick-open--read-stream root)))))

(defun drgnx-quick-open--read-stream (root)
  "Quick Open of ROOT while its listing streams (the path without the hub)."
  (let* ((drgnx-quick-open--state (drgnx-quick-open--init))
         (drgnx-quick-open--buffer nil)
         (drgnx-quick-open--stream
          (drgnx-file-stream-start root
                                   (lambda (names)
                                     (drgnx-quick-open--sync-highlight)
                                     (drgnx-quick-open--feed (list 'batch names)))
                                   (lambda (_ok) (drgnx-quick-open--feed '(done) t)))))
    (if (not drgnx-quick-open--stream)
        (call-interactively #'project-find-file)
      (unwind-protect
          (let ((choice (let ((completion-styles-alist (cons drgnx-quick-open--style completion-styles-alist))
                              (completion-styles '(drgnx-quick-open))
                              (completion-category-overrides nil) (completion-category-defaults nil))
                          (minibuffer-with-setup-hook #'drgnx-quick-open--setup
                            (completing-read "Quick Open: " #'drgnx-quick-open--table nil t)))))
            (find-file (expand-file-name choice root)))
        (drgnx-file-stream-stop drgnx-quick-open--stream)))))

(provide 'drgnx-quick-open)
;;; drgnx-quick-open.el ends here
