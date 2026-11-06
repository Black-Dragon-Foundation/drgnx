;;; drgnx-extensions-trust.el --- Trust: the card before an unsigned install, inert text, review before an update -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Three things that decide how far a package's code and text are trusted.
;; - The trust card.  The first install of a package from a source that does not sign (MELPA, a directory archive, a
;;   Git repository) shows a card in a buffer of its own: where it comes from, the commit, the downloads, who keeps
;;   it, and every package it brings from an unsigned source.  Install records those names in
;;   <state>/extensions/trusted.eld (this machine: a new machine shows the card again) and queues the install; Cancel
;;   queues nothing.  A signed source (GNU and NonGNU ELPA) has no card.  The card has buttons and asks no question,
;;   and it only comes from a command: called from a timer, a hook or a process it shows nothing and installs nothing.
;; - Inert text.  Every readme fetched from an archive, every reviewed diff and every file of a package that is not
;;   installed goes through `drgnx-extensions-inert-insert': no mode function and no mode hook runs on it, no local
;;   variable is applied, nothing in it is evaluated or becomes a link, and it is never trusted content.
;; - Review before an update.  For the packages and archives in `drgnx-extensions-review', Update downloads and checks
;;   the update (`drgnx upgrade --only NAME --stage'), the page shows it against the installed copy, and Apply installs
;;   exactly what was checked (`drgnx upgrade --staged', which checks the hashes again).
;; The Extensions module's setup calls `drgnx-extensions-trust-setup', its teardown `drgnx-extensions-trust-teardown'.
;; See docs/guide/extensions.md, "Where it comes from" and "Review before an update".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-guard)
(require 'drgnx-ui-kit)

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))
(declare-function drgnx-extensions-jobs-queue "drgnx-extensions-jobs")
(declare-function drgnx-extensions-jobs-run "drgnx-extensions-jobs")
(declare-function drgnx-extensions-list--normalize "drgnx-extensions-list")
(declare-function drgnx-extensions-list--trust "drgnx-extensions-list")
(declare-function drgnx-extensions-details-open "drgnx-extensions-details")
(declare-function drgnx-extensions-details--package-dir "drgnx-extensions-details")
(declare-function drgnx-extensions-details--refresh "drgnx-extensions-details")
(declare-function drgnx-extensions-details--fetch "drgnx-extensions-details")
(declare-function drgnx-pkg-staged-file "drgnx-pkg")
(declare-function diff-mode "diff-mode")
(defvar drgnx-extensions-list--rows)
(defvar drgnx-extensions-review)
(defvar drgnx-extensions-jobs-done-functions)
(defvar drgnx-extensions-details--id)
(defvar drgnx-extensions-details--info)
(defvar drgnx-extensions-details--readme)
(defvar drgnx-extensions-details--files)

(defconst drgnx-extensions-trust-line "Runs inside Emacs as you: it can read your files and reach the network."
  "Said on the page and the card of everything that is code.")

;;;; Inert text

(defun drgnx-extensions-inert-insert (text kind)
  "Insert TEXT, which came from a package or an archive, into the current buffer as inert text.  KIND `text' leaves
the buffer in `fundamental-mode'; KIND `diff' puts it in `diff-mode' for the hunks' colours only.  The mode is entered
with its hooks delayed and the delayed hooks dropped, so no mode hook and no `after-change-major-mode-hook' runs;
`diff-font-lock-syntax' and `diff-refine' are nil here from the start (the first picks a major mode for each hunk's
file name and runs it, the second runs a process per hunk); local variables are off; the buffer is never trusted
content.  TEXT's own properties are dropped.  Nothing in TEXT is evaluated and none of it becomes a link."
  (let ((enable-local-variables nil) (enable-local-eval nil) (enable-dir-local-variables nil))
    (delay-mode-hooks                   ; diff-mode reads directory locals for a buffer with no file: off here
      (if (eq kind 'diff)
          (progn (require 'diff-mode)
                 ;; dynamic bindings: diff-mode's options are not known when this file is compiled
                 (cl-progv '(diff-font-lock-syntax diff-refine) '(nil nil) (diff-mode)))
        (unless (eq major-mode 'fundamental-mode) (fundamental-mode)))))
  (kill-local-variable 'delayed-mode-hooks)       ; dropped: a later mode never runs them
  (kill-local-variable 'delayed-after-hook-functions)
  (when (eq kind 'diff)
    (set (make-local-variable 'diff-font-lock-syntax) nil)
    (set (make-local-variable 'diff-refine) nil))
  (setq-local enable-local-variables nil enable-local-eval nil enable-dir-local-variables nil)
  (when (boundp 'trusted-content) (set (make-local-variable 'trusted-content) nil))
  (insert (substring-no-properties (or text ""))))

(defun drgnx-extensions-trust-inert-string (text kind)
  "TEXT made inert as `drgnx-extensions-inert-insert' makes it, as a string ending in a newline: KIND `text' has no
properties, KIND `diff' only diff-mode's faces.  Called when the text arrives, never while drawing."
  (with-temp-buffer
    (drgnx-extensions-inert-insert text kind)
    (when (eq kind 'diff) (font-lock-ensure))
    (let ((s (buffer-string))) (if (string-suffix-p "\n" s) s (concat s "\n")))))

(defun drgnx-extensions-trust--line (x &optional max)
  "X (a package's or an archive's words) on one line: control characters become spaces, at most MAX (200) characters."
  (let ((s (replace-regexp-in-string "[[:cntrl:]]+" " " (substring-no-properties (format "%s" (or x ""))))))
    (truncate-string-to-width (string-trim s) (or max 200) nil nil "…")))

;;;; Seen here: trusted.eld

(defun drgnx-extensions-trust-file ()
  "The packages whose trust card was seen on this machine: <state>/extensions/trusted.eld, a list of names."
  (expand-file-name "extensions/trusted.eld" (drgnx-state-dir)))

(defun drgnx-extensions-trust--names ()
  (let ((data (plist-get (ignore-errors (drgnx-file-read (drgnx-extensions-trust-file))) :data)))
    (and (proper-list-p data) (seq-filter #'symbolp data))))

(defun drgnx-extensions-trusted-p (name)
  "Non-nil when the trust card of the package NAME was seen here."
  (memq (if (stringp name) (intern name) name) (drgnx-extensions-trust--names)))

(defun drgnx-extensions-trust--record (names)
  "Add NAMES (symbols) to the packages seen here."
  (drgnx-file-write (drgnx-extensions-trust-file)
                    (sort (delete-dups (append (drgnx-extensions-trust--names) names)) #'string<)
                    :header ";; drgnx: the packages whose trust card you saw on this machine (Extensions)" :pretty t))

;;;; Asking the hub

(defun drgnx-extensions-trust--details (id callback)
  "Ask the hub, without waiting, for ID's details: CALLBACK gets (DETAILS ERROR)."
  (unless (fboundp 'drgnx-hub-call) (require 'drgnx-hub-client))
  (condition-case err
      (drgnx-hub-call "extensions/details" (list :id id) callback)
    (error (funcall callback nil (error-message-string err)))))

(defun drgnx-extensions-trust--notice (text)
  (if (fboundp 'drgnx-notify) (drgnx-notify 'config 'info text :id 'extensions-trust) (message "%s" text)))

(defun drgnx-extensions-trust--known-row (id)
  "ID's row as the list or an open page has it, or nil."
  (or (and (boundp 'drgnx-extensions-list--rows) (gethash id drgnx-extensions-list--rows))
      (cl-loop for b in (buffer-list)
               when (and (equal (buffer-local-value 'drgnx-extensions-details--id b) id)
                         (plist-get (buffer-local-value 'drgnx-extensions-details--info b) :row))
               return (drgnx-extensions-list--normalize
                       (plist-get (buffer-local-value 'drgnx-extensions-details--info b) :row)))))

(defun drgnx-extensions-trust--installed-p (row)
  (memq (plist-get row :state) '(installed update held dependency incompat)))

;;;; The card

(defvar drgnx-extensions-trust-mode-map (make-sparse-keymap) "Keys of a trust card (the key profiles bind them).")

(define-derived-mode drgnx-extensions-trust-mode special-mode "Trust"
  "The trust card of a package from a source that does not sign."
  (setq-local truncate-lines nil cursor-type nil)
  (buffer-disable-undo))

(defvar-local drgnx-extensions-trust--card nil
  "The card's state: (:id ID :name NAME :row ROW :info DETAILS :then FN :deps NAMES :seen TABLE :pending N :done
BOOL).  DEPS are the unsigned packages it brings that are not installed.")

(defun drgnx-extensions-trust-card-name (name) (format "*Extension trust: %s*" name))

(defun drgnx-extensions-trust--render (buffer)
  "Draw BUFFER's card again from its state."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((card drgnx-extensions-trust--card) (row (plist-get card :row)) (info (plist-get card :info))
             (name (plist-get card :name)) (deps (sort (copy-sequence (plist-get card :deps)) #'string<))
             (inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (drgnx-extensions-trust--line name) 'face 'bold)
                (format " comes from %s (%s)\n" (or (drgnx-extensions-list--trust row) "a source that does not sign")
                        (drgnx-extensions-trust--line (plist-get row :source)))
                (propertize (concat drgnx-extensions-trust-line "\n") 'face 'drgnx-status-warn) "\n")
        (insert (string-join
                 (delq nil (list (and (plist-get row :summary) (drgnx-extensions-trust--line (plist-get row :summary)))
                                 (and (plist-get info :commit)
                                      (format "Commit: %s" (drgnx-extensions-trust--line (plist-get info :commit) 40)))
                                 (and (numberp (plist-get row :downloads))
                                      (format "Downloads: %s" (plist-get row :downloads)))
                                 (format "Maintainer: %s" (if (plist-get info :maintainer)
                                                              (drgnx-extensions-trust--line (plist-get info :maintainer))
                                                            "not named"))))
                 "\n")
                "\n")
        (insert (cond ((not (plist-get card :done)) (format "Checking the packages %s needs…\n" name))
                      (deps (format "It also brings %d unsigned package%s it needs: %s\n" (length deps)
                                    (if (= (length deps) 1) "" "s") (string-join deps ", ")))
                      (t "It brings no other unsigned package.\n"))
                "After this install drgnx pins its hash in the lock.\n\n")
        (insert (drgnx-ui-button "[Cancel]" 'extensions-trust-cancel :help "Close the card; nothing is installed"))
        (when (plist-get card :done)
          (insert " " (drgnx-ui-button "[Install]" 'extensions-trust-install
                                       :help "Install it and what it brings; this card is not shown for them again")))
        (insert "\n")
        (goto-char (point-min))))))

(defun drgnx-extensions-trust--visit (buffer requires)
  "Walk REQUIRES (the details' requirements) for BUFFER's card: each package not seen yet is asked for; one that is
not installed and comes from an unsigned source is listed, and what it requires is walked too.  The card is done when
no answer is left to wait for."
  (let (ask)
    (with-current-buffer buffer
      (let ((seen (plist-get drgnx-extensions-trust--card :seen)))
        (dolist (r (append requires nil))
          (let ((name (plist-get r :name)))
            (when (and (stringp name) (not (equal name "emacs")) (not (gethash name seen)) (< (hash-table-count seen) 200))
              (puthash name t seen)
              (push (concat "pkg:" name) ask)))))
      ;; every one is counted before the first answer, which may come at once
      (cl-incf (plist-get drgnx-extensions-trust--card :pending) (length ask)))
    (dolist (id (nreverse ask))
      (drgnx-extensions-trust--details id (lambda (info err) (drgnx-extensions-trust--visited buffer info err)))))
  (drgnx-extensions-trust--maybe-done buffer))

(defun drgnx-extensions-trust--visited (buffer info err)
  "A requirement's details came for BUFFER's card (ERR: it is not in the catalog, a built-in: skipped)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (cl-decf (plist-get drgnx-extensions-trust--card :pending))
      (let ((row (and (not err) info (drgnx-extensions-list--normalize (plist-get info :row)))))
        (when (and row (not (drgnx-extensions-trust--installed-p row)))
          (unless (eq (plist-get row :signed) 'signed)
            (push (plist-get row :name) (plist-get drgnx-extensions-trust--card :deps)))
          (drgnx-extensions-trust--visit buffer (plist-get info :requires))))
      (drgnx-extensions-trust--maybe-done buffer))))

(defun drgnx-extensions-trust--maybe-done (buffer)
  (with-current-buffer buffer
    (when (and (<= (plist-get drgnx-extensions-trust--card :pending) 0) (plist-get drgnx-extensions-trust--card :info)
               (not (plist-get drgnx-extensions-trust--card :done)))
      (setq drgnx-extensions-trust--card (plist-put drgnx-extensions-trust--card :done t)))
    (drgnx-extensions-trust--render buffer)))

(defun drgnx-extensions-trust--show-card (id row info then)
  "Show the trust card of ID (its ROW, its DETAILS when known); THEN runs on Install."
  (let* ((name (plist-get row :name)) (buffer (get-buffer-create (drgnx-extensions-trust-card-name name))))
    (with-current-buffer buffer
      (drgnx-extensions-trust-mode)
      (setq drgnx-extensions-trust--card (list :id id :name name :row row :info info :then then :deps nil
                                               :seen (make-hash-table :test #'equal) :pending 0 :done nil))
      (puthash name t (plist-get drgnx-extensions-trust--card :seen)))
    (drgnx-extensions-trust--render buffer)
    (if info
        (drgnx-extensions-trust--visit buffer (plist-get info :requires))
      (drgnx-extensions-trust--details
       id (lambda (info err)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (setq drgnx-extensions-trust--card (plist-put drgnx-extensions-trust--card :info (or info (list :error err)))))
              (drgnx-extensions-trust--visit buffer (plist-get info :requires))))))
    (pop-to-buffer buffer)
    buffer))

(defun drgnx-extensions-trust--decide (id row info then)
  "THEN at once for a signed source or a package whose card was seen here; else its card."
  (if (or (eq (plist-get row :signed) 'signed) (drgnx-extensions-trusted-p (plist-get row :name)))
      (progn (funcall then) t)
    (drgnx-extensions-trust--show-card id row info then)
    t))

(defun drgnx-extensions-trust-before-install (id then)
  "Before installing the package ID (\"pkg:NAME\"): THEN (a function of no arguments) runs at once for a signed
source or a package whose trust card was seen here; else the package's trust card is shown and THEN runs when its
Install is clicked.  Only from a command: called with no `this-command' (a timer, a hook, a process) it shows
nothing, calls nothing and posts a notice.  Never asks a question.  Non-nil when THEN ran or a card is shown."
  (let ((name (substring id (1+ (or (string-search ":" id) -1)))))
    (if (null this-command)
        (progn (drgnx-extensions-trust--notice
                (format "%s was not installed: an install starts only from your click in Extensions" name))
               nil)
      (if-let* ((row (drgnx-extensions-trust--known-row id)))
          (drgnx-extensions-trust--decide id row nil then)
        (drgnx-extensions-trust--details
         id (lambda (info err)
              (if (or err (null (plist-get info :row)))
                  (drgnx-extensions-trust--notice (format "%s was not installed: %s" name (or err "it is not in the catalog")))
                (drgnx-extensions-trust--decide id (drgnx-extensions-list--normalize (plist-get info :row)) info then))))
        t))))

(defun drgnx-extensions-trust-install ()
  "Install the package of this trust card: its name and the unsigned packages it brings are recorded as seen here,
then the install is queued."
  (interactive)
  (let ((card drgnx-extensions-trust--card))
    (unless (derived-mode-p 'drgnx-extensions-trust-mode) (user-error "Not a trust card"))
    (unless (plist-get card :done) (user-error "The card is still checking what %s needs" (plist-get card :name)))
    (drgnx-extensions-trust--record (mapcar #'intern (cons (plist-get card :name) (plist-get card :deps))))
    (kill-buffer (current-buffer))
    (funcall (plist-get card :then))))

(defun drgnx-extensions-trust-cancel ()
  "Close this trust card: nothing is installed or recorded."
  (interactive)
  (unless (derived-mode-p 'drgnx-extensions-trust-mode) (user-error "Not a trust card"))
  (let ((name (plist-get drgnx-extensions-trust--card :name)))
    (kill-buffer (current-buffer))
    (message "%s was not installed" name)))

;;;; Review before an update

(defvar drgnx-extensions-trust--reviews (make-hash-table :test #'equal)
  "Package name → its review: (:state S :job ID :entry STAGED :diff TEXT :error TEXT), S `staging', `comparing',
`ready', `applying' or `failed'; STAGED the entry `drgnx upgrade --stage' wrote (NAME :version :file :sha256
:verified).  An entry goes when its update was applied or discarded; emptied by the teardown.")

(defun drgnx-extensions-trust-review (name)
  "NAME's review, or nil."
  (gethash name drgnx-extensions-trust--reviews))

(defun drgnx-extensions-trust--review-put (name &rest kvs)
  (let ((r (gethash name drgnx-extensions-trust--reviews)))
    (while kvs (setq r (plist-put r (pop kvs) (pop kvs))))
    (puthash name r drgnx-extensions-trust--reviews)
    (drgnx-extensions-trust--refresh-pages (concat "pkg:" name))))

(defun drgnx-extensions-trust--refresh-pages (id)
  (dolist (b (buffer-list))
    (when (equal (buffer-local-value 'drgnx-extensions-details--id b) id)
      (with-current-buffer b (drgnx-extensions-details--refresh)))))

(defun drgnx-extensions-trust-review-p (name &optional source)
  "Non-nil when updates of the package NAME (from the archive SOURCE) are reviewed first (`drgnx-extensions-review'
names the package or the archive)."
  (let ((l (bound-and-true-p drgnx-extensions-review)))
    (or (memq (intern name) l) (member name l) (and source (member source l)))))

(defun drgnx-extensions-trust-update (name)
  "Update the package NAME: a job, or, when its updates are reviewed first, a job that downloads and checks the update
for its page to show.  `review' in that case (the caller shows the page), else nil."
  (let ((row (drgnx-extensions-trust--known-row (concat "pkg:" name))))
    (if (not (drgnx-extensions-trust-review-p name (plist-get row :source)))
        (progn (drgnx-extensions-jobs-run 'upgrade (list name)) nil)
      (puthash name (list :state 'staging) drgnx-extensions-trust--reviews)
      (drgnx-extensions-jobs-run 'upgrade (list name) :stage t
                                 :callback (lambda (id why)
                                             (if id (drgnx-extensions-trust--review-put name :job id)
                                               (drgnx-extensions-trust--review-put name :state 'failed :error why))))
      'review)))

(defun drgnx-extensions-trust--staged ()
  "The entries `drgnx upgrade --stage' listed last, or nil."
  (unless (fboundp 'drgnx-pkg-staged-file) (require 'drgnx-pkg))
  (let ((data (plist-get (ignore-errors (drgnx-file-read (drgnx-pkg-staged-file))) :data)))
    (and (proper-list-p data) data)))

(defun drgnx-extensions-trust--diff (name entry callback)
  "Compare the staged ENTRY of NAME (its file in the package cache) with the installed copy: CALLBACK gets (TEXT
ERROR), TEXT the output of `diff -ruN'.  Two processes (unpack, compare), never waited on."
  (let* ((file (expand-file-name (plist-get (cdr entry) :file) (drgnx-package-cache-dir)))
         (old (or (drgnx-extensions-details--package-dir name) (make-temp-file "drgnx-review-none" t)))
         (tmp (make-temp-file "drgnx-review" t))
         (new (expand-file-name (format "%s-%s" name (plist-get (cdr entry) :version)) tmp))
         (done (lambda (text err) (ignore-errors (delete-directory tmp t)) (funcall callback text err)))
         (compare
          (lambda ()
            (let ((out (generate-new-buffer " *extension review*" t)))
              (make-process
               :name "extension-review-diff" :buffer out :noquery t :connection-type 'pipe
               :command (list "diff" "-ruN" "-x" "*.elc" "-x" "*-autoloads.el" old new)
               :sentinel (drgnx-guard-wrap
                          (lambda (proc _event)
                            (unless (process-live-p proc)
                              (let ((text (with-current-buffer out (buffer-string))) (rc (process-exit-status proc)))
                                (kill-buffer out)
                                (if (memq rc '(0 1))
                                    (funcall done (string-replace new "update" (string-replace old "installed" text)) nil)
                                  (funcall done nil (format "diff failed: %s" (string-trim text)))))))
                          "the diff of a reviewed update"))))))
    (cond ((not (file-readable-p file)) (funcall done nil (format "%s is not in the package cache" (plist-get (cdr entry) :file))))
          ((string-suffix-p ".el" file)
           (make-directory new t)
           (copy-file file (expand-file-name (concat name ".el") new) t)
           (funcall compare))
          (t
           (make-process
            :name "extension-review-unpack" :noquery t :connection-type 'pipe :buffer nil
            :command (list "tar" "-xf" file "-C" tmp)
            :sentinel (drgnx-guard-wrap
                       (lambda (proc _event)
                         (unless (process-live-p proc)
                           (if (eql (process-exit-status proc) 0) (funcall compare)
                             (funcall done nil (format "cannot unpack %s" (file-name-nondirectory file))))))
                       "unpacking a reviewed update"))))))

(defun drgnx-extensions-trust--staging-done (name result)
  "NAME's staging job ended with RESULT: compare what it fetched with the installed copy."
  (if (not (eq (plist-get result :status) 'done))
      (drgnx-extensions-trust--review-put name :state 'failed :error (or (plist-get result :error) "the download failed"))
    (if-let* ((entry (assq (intern name) (drgnx-extensions-trust--staged))))
        (progn
          (drgnx-extensions-trust--review-put name :state 'comparing :entry entry)
          (drgnx-extensions-trust--diff
           name entry
           (lambda (text err)
             (if err (drgnx-extensions-trust--review-put name :state 'failed :error err)
               (drgnx-extensions-trust--review-put
                name :state 'ready
                :diff (if (string-empty-p text) "No file differs.\n" (drgnx-extensions-trust-inert-string text 'diff)))))))
      (drgnx-extensions-trust--review-put name :state 'failed :error "nothing to update: the archive has no newer version"))))

(defun drgnx-extensions-trust-apply (&optional name)
  "Install the reviewed update of NAME (the page's package): exactly what was downloaded and checked."
  (interactive)
  (let* ((name (or name (and drgnx-extensions-details--id (substring drgnx-extensions-details--id 4))
                   (user-error "No extension here")))
         (review (drgnx-extensions-trust-review name)) (entry (plist-get review :entry)))
    (unless (eq (plist-get review :state) 'ready) (user-error "No reviewed update of %s is ready" name))
    (let ((staged (drgnx-extensions-trust--staged)))
      (unless (and (= (length staged) 1) (equal (car staged) entry))
        (drgnx-extensions-trust--review-put name :state 'failed
                                            :error "the downloaded update changed since you reviewed it: Update again")
        (user-error "The downloaded update of %s changed since you reviewed it: Update again" name)))
    (drgnx-extensions-trust--review-put name :state 'applying)
    (drgnx-extensions-jobs-run 'upgrade (list name) :staged t
                               :callback (lambda (id why)
                                           (if id (drgnx-extensions-trust--review-put name :job id)
                                             (drgnx-extensions-trust--review-put name :state 'failed :error why))))))

(defun drgnx-extensions-trust-discard (name)
  "Forget the review of NAME: nothing is installed."
  (remhash name drgnx-extensions-trust--reviews)
  (drgnx-extensions-trust--refresh-pages (concat "pkg:" name)))

(defun drgnx-extensions-trust-review-text (name)
  "The page's review section for NAME, or nil when none runs.  Cached text only."
  (when-let* ((r (drgnx-extensions-trust-review name)))
    (let ((entry (cdr (plist-get r :entry))))
      (concat (propertize "Review the update\n" 'face 'bold)
              (pcase (plist-get r :state)
                ('staging "Downloading and checking the update…\n")
                ('comparing "Comparing it with the installed copy…\n")
                ('applying "Installing the reviewed update…\n")
                ('failed (propertize (format "%s\n" (drgnx-extensions-trust--line (plist-get r :error))) 'face 'drgnx-status-fail))
                (_ ""))
              (if entry (format "%s %s · sha256 %s%s\n" name (plist-get entry :version) (plist-get entry :sha256)
                                (if (plist-get entry :verified) " · signed" ""))
                "")
              (or (plist-get r :diff) "")
              "\n"))))

;;;; Readmes fetched from an archive, files of a package not installed

(defun drgnx-extensions-trust-fetch-readme (buffer)
  "BUFFER's page shows a package that is not installed and whose readme the hub has not cached: start the job that
fetches it, once for the page.  Its end (`drgnx-extensions-trust--job-done') asks for the details again."
  (with-current-buffer buffer
    (let* ((info drgnx-extensions-details--info) (row (drgnx-extensions-list--normalize (plist-get info :row)))
           (source (plist-get row :source)) (name (plist-get row :name)))
      (when (and (eq (plist-get row :kind) 'package) (not (drgnx-extensions-trust--installed-p row))
                 (null (plist-get info :readme)) (null drgnx-extensions-details--readme)
                 (stringp source) (not (member source '("git" "builtin" "emacs"))))
        (setq drgnx-extensions-details--readme (list :state 'fetching))
        (drgnx-extensions-jobs-run
         'fetch-readme source name
         :callback (lambda (id why)
                     (when (buffer-live-p buffer)
                       (with-current-buffer buffer
                         (setq drgnx-extensions-details--readme
                               (if id (list :state 'fetching :job id) (list :state 'failed :error why)))
                         (drgnx-extensions-details--refresh)))))))))

(defun drgnx-extensions-trust-list-files (buffer file)
  "List the files of the package archive FILE (a tarball in the package cache) for BUFFER's Files tab, inert: `tar
-tf', never waited on."
  (with-current-buffer buffer (setq drgnx-extensions-details--files (list :state 'listing)))
  (let ((out (generate-new-buffer " *extension files*" t)))
    (make-process
     :name "extension-files" :buffer out :noquery t :connection-type 'pipe :command (list "tar" "-tf" file)
     :sentinel (drgnx-guard-wrap
                (lambda (proc _event)
                  (unless (process-live-p proc)
                    (let ((text (with-current-buffer out (buffer-string))))
                      (kill-buffer out)
                      (when (buffer-live-p buffer)
                        (with-current-buffer buffer
                          (setq drgnx-extensions-details--files
                                (if (eql (process-exit-status proc) 0)
                                    (list :state 'ready :text (drgnx-extensions-trust-inert-string text 'text))
                                  (list :state 'failed :error (string-trim text))))
                          (drgnx-extensions-details--refresh))))))
                "the file list of a package"))))

;;;; Jobs that ended

(defun drgnx-extensions-trust--job-done (job result)
  "`drgnx-extensions-jobs-done-functions': a review's job, or a page's readme job, ended."
  (let (staged applied)
    (maphash (lambda (name r)
               (when (equal (plist-get r :job) job)
                 (pcase (plist-get r :state)
                   ('staging (push name staged))
                   ('applying (push name applied)))))
             drgnx-extensions-trust--reviews)
    (dolist (name staged) (drgnx-extensions-trust--staging-done name result))
    (dolist (name applied)
      (if (eq (plist-get result :status) 'done)
          (drgnx-extensions-trust-discard name)
        (drgnx-extensions-trust--review-put name :state 'failed :error (or (plist-get result :error) "the update failed")))))
  (dolist (b (buffer-list))
    (when (equal (plist-get (buffer-local-value 'drgnx-extensions-details--readme b) :job) job)
      (with-current-buffer b
        (if (eq (plist-get result :status) 'done)
            (progn (setq drgnx-extensions-details--readme (list :state 'fetched))
                   (drgnx-extensions-details--fetch b drgnx-extensions-details--id))
          (setq drgnx-extensions-details--readme
                (list :state 'failed :error (or (plist-get result :error) "the archive has no readme for it")))
          (drgnx-extensions-details--refresh))))))

;;;; Setup

(defun drgnx-extensions-trust-setup ()
  "Follow the ends of review and readme jobs (the Extensions module's setup calls it).  Idempotent."
  (add-hook 'drgnx-extensions-jobs-done-functions #'drgnx-extensions-trust--job-done))

(defun drgnx-extensions-trust-teardown ()
  "Stop following jobs, forget the reviews and close the cards."
  (remove-hook 'drgnx-extensions-jobs-done-functions #'drgnx-extensions-trust--job-done)
  (clrhash drgnx-extensions-trust--reviews)
  (dolist (b (buffer-list))
    (when (eq (buffer-local-value 'major-mode b) 'drgnx-extensions-trust-mode) (kill-buffer b))))

(provide 'drgnx-extensions-trust)
;;; drgnx-extensions-trust.el ends here
