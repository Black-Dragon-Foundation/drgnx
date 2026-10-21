;;; drgnx-prs.el --- Module tools/prs: the Pull Requests tab, on forge -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The pull requests of this repository, from forge's local database, in the right dock: number, title, author,
;; state, last update; a PR whose base is another PR's branch sits under it (a stack).  RET opens forge's view of
;; it (the reviews, comments and commits); d shows its changes in the diff view (git fetches the PR's head first).
;; Pull Requests: Fetch asks the forge (GitHub, Codeberg/Forgejo as far as forge supports it) — the only thing here
;; that touches the network, and only when you run it.  In a commit message, # completes PR and issue numbers.
;; See docs/guide/git.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'drgnx-modules)
(require 'drgnx-notice)
(require 'drgnx-registry)

(declare-function eieio-oref "eieio-core")
(declare-function drgnx-diff-show "drgnx-diff")
(declare-function drgnx-wb-define-tab "drgnx-area")
(declare-function drgnx-wb-area-show "drgnx-area")
(declare-function forge-get-repository "forge-repo")
(declare-function forge--get-remote "forge-core")
(declare-function forge-get-pullreq "forge-pullreq")
(declare-function forge-pull "forge-commands")
(declare-function forge-topic-setup-buffer "forge-topic")
(declare-function forge-visit-topic "forge-commands")
(declare-function forge-topic-completion-at-point "forge-topic")

(defconst drgnx-prs--placeholder "No pull requests here yet — Pull Requests: Fetch (forge) gets them.")

(defvar-local drgnx-prs--root nil "The repository this list is of.")
(defvar-local drgnx-prs--all nil "Every PR read (plists), or :untracked.")
(defvar-local drgnx-prs--why nil "Why the last read of forge failed (a string), or nil: the placeholder says it.")
(defvar-local drgnx-prs-show-closed nil "Are merged and closed PRs listed too?")

;;;; Reading forge (the only code that touches its API)

(defun drgnx-prs--slot (obj slot)
  "OBJ's SLOT (forge's classes are not known when this file is compiled)."
  (eieio-oref obj slot))

(defun drgnx-prs--state (pr)
  "Forge PR object's state as `open', `draft', `merged' or `closed'."
  (let ((s (drgnx-prs--slot pr 'state)))
    (cond ((and (eq s 'open) (ignore-errors (drgnx-prs--slot pr 'draft-p))) 'draft)
          ((eq s 'open) 'open)
          ((memq s '(merged completed)) 'merged)
          (t 'closed))))

(defun drgnx-prs--pullreqs (root)
  "The pull requests forge knows for the repository at ROOT: plists (:number :title :author :state :base :head
:updated), or :untracked when forge is missing or does not track it."
  (if (not (require 'forge nil t)) :untracked
    (let* ((default-directory (file-name-as-directory root))
           (repo (ignore-errors (forge-get-repository :tracked?))))
      (if (not repo) :untracked
        (mapcar (lambda (pr)
                  (list :number (drgnx-prs--slot pr 'number) :title (or (drgnx-prs--slot pr 'title) "")
                        :author (or (drgnx-prs--slot pr 'author) "(ghost)") :state (drgnx-prs--state pr)
                        :base (drgnx-prs--slot pr 'base-ref) :head (drgnx-prs--slot pr 'head-ref)
                        :updated (or (drgnx-prs--slot pr 'updated) "")
                        :cross (ignore-errors (drgnx-prs--slot pr 'cross-repo-p))))
                (drgnx-prs--slot repo 'pullreqs))))))

(defun drgnx-prs--read (root)
  "`drgnx-prs--pullreqs' for ROOT; a forge whose classes are not what we read is the warn condition `(prs . fetch)'
\(the tab says why, `drgnx-prs--why') and :untracked; a good read clears it."
  (condition-case err (prog1 (drgnx-prs--pullreqs root)
                        (setq drgnx-prs--why nil)
                        (drgnx-notice-clear 'prs 'fetch))
    (error (setq drgnx-prs--why (error-message-string err))
           (drgnx-notify 'prs 'warn (format "Pull requests: the forge did not answer: %s" drgnx-prs--why)
                         :id 'fetch :life 'condition :command 'prs-fetch)
           :untracked)))

(defun drgnx-prs--remote (root)
  "The remote forge uses for ROOT, else origin."
  (or (and (featurep 'forge) (let ((default-directory root)) (ignore-errors (forge--get-remote)))) "origin"))

;;;; Stacks

(defun drgnx-prs-stacks (prs)
  "PRS in display order as (PR . DEPTH): a PR whose base is another listed PR's head (a branch of this repository,
not a fork's) right after it, one deeper;
newest first at each level.  Every PR appears once, a cycle cut where it is found."
  (let ((seen (make-hash-table)) (out nil)
        (by-base (make-hash-table :test #'equal)) (by-head (make-hash-table :test #'equal))   ; each PR looked up once, not scanned for
        (newest (lambda (l) (sort (copy-sequence l) (lambda (a b) (> (plist-get a :number) (plist-get b :number)))))))
    (dolist (p prs)
      (push p (gethash (plist-get p :base) by-base))
      (unless (plist-get p :cross) (push p (gethash (plist-get p :head) by-head))))
    (cl-labels ((children (p) (and (not (plist-get p :cross))   ; a fork's branch (often its main) is no base here
                                   (seq-remove (lambda (q) (eq q p)) (gethash (plist-get p :head) by-base))))
                (walk (p depth)
                  (unless (gethash (plist-get p :number) seen)
                    (puthash (plist-get p :number) t seen)
                    (push (cons p depth) out)
                    (dolist (c (funcall newest (children p))) (walk c (1+ depth))))))
      (dolist (r (funcall newest (seq-remove (lambda (p) (seq-some (lambda (q) (not (eq q p))) (gethash (plist-get p :base) by-head)))
                                             prs)))
        (walk r 0))
      (dolist (p (funcall newest prs)) (walk p 0)))       ; what a cycle left
    (nreverse out)))

;;;; The tab

(defvar drgnx-prs-mode-map (make-sparse-keymap) "Keys come from the key profiles (prs-* commands).")

(define-derived-mode drgnx-prs-mode tabulated-list-mode "Pull Requests"
  "The pull requests of this repository (forge): RET opens one, d shows its changes."
  (setq tabulated-list-format [("#" 6 nil :right-align t) ("Title" 50 nil) ("Author" 14 nil) ("State" 8 nil) ("Updated" 12 nil)]
        tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun drgnx-prs--entries ()
  (let ((prs (if (listp drgnx-prs--all)
                 (seq-filter (lambda (p) (or drgnx-prs-show-closed (memq (plist-get p :state) '(open draft)))) drgnx-prs--all)
               nil)))
    (mapcar (lambda (e)
              (let ((p (car e)) (d (cdr e)))
                (list p (vector (number-to-string (plist-get p :number))
                                (concat (if (> d 0) (concat (make-string (* 2 (1- d)) ?\s) "└ ") "") (plist-get p :title))
                                (plist-get p :author) (symbol-name (plist-get p :state))
                                (substring (plist-get p :updated) 0 (min 10 (length (plist-get p :updated))))))))
            (drgnx-prs-stacks prs))))

(defun drgnx-prs--draw ()
  (setq tabulated-list-entries (drgnx-prs--entries))
  (tabulated-list-print t)
  (when (null tabulated-list-entries)
    (let ((inhibit-read-only t) (hidden (and (listp drgnx-prs--all) (length drgnx-prs--all))))
      (goto-char (point-max))
      (insert "\n "
              (if (and hidden (> hidden 0))                 ; they are all merged or closed, and hidden
                  (format "No open pull requests — %d merged or closed (Pull Requests: Show Closed lists them)." hidden)
                (if drgnx-prs--why
                    (format "Pull requests: the forge did not answer: %s" drgnx-prs--why)
                  drgnx-prs--placeholder))
              "\n"))))

(defun drgnx-prs--toplevel (dir)
  (with-temp-buffer
    (let ((default-directory dir))
      (if (eql 0 (call-process "git" nil '(t nil) nil "rev-parse" "--show-toplevel"))
          (file-name-as-directory (string-trim (buffer-string)))
        (user-error "Not in a git repository")))))

(defun drgnx-prs-view ()
  "Pull Requests — this repository's pull requests (forge's database), in the right dock."
  (interactive)
  (let ((root (drgnx-prs--toplevel default-directory)) (b (get-buffer-create "*drgnx pull requests*")))
    (with-current-buffer b
      (unless (derived-mode-p 'drgnx-prs-mode) (drgnx-prs-mode))
      (setq default-directory root drgnx-prs--root root drgnx-prs--all (drgnx-prs--read root))
      (drgnx-prs--draw))
    (if (fboundp 'drgnx-wb-area-show) (drgnx-wb-area-show 'right 'prs b) (display-buffer b))
    b))

(defun drgnx-prs-toggle-closed ()
  "Pull Requests: Show Closed — merged and closed ones too, or not."
  (interactive)
  ;; the tab's list, wherever it is run from (the palette): never the buffer it is run in
  (with-current-buffer (or (get-buffer "*drgnx pull requests*") (user-error "No Pull Requests tab: run Pull Requests first"))
    (setq drgnx-prs-show-closed (not drgnx-prs-show-closed))
    (drgnx-prs--draw)))

(defun drgnx-prs--at-point () (or (tabulated-list-get-id) (user-error "No pull request here")))

(defun drgnx-prs-fetch ()
  "Pull Requests: Fetch — ask the forge for this repository's pull requests (forge-pull; needs a token)."
  (interactive)
  (unless (require 'forge nil t) (user-error "forge is not installed: add it with drgnx sync (module tools/prs)"))
  (forge-pull))

(defun drgnx-prs-open ()
  "Pull Requests: Open — forge's view of the pull request at point: its reviews, comments and commits."
  (interactive)
  (let ((p (drgnx-prs--at-point)))
    (unless (require 'forge nil t) (user-error "forge is not installed"))
    (let ((obj (forge-get-pullreq (forge-get-repository :tracked) (plist-get p :number))))
      (if (fboundp 'forge-topic-setup-buffer) (forge-topic-setup-buffer obj) (forge-visit-topic obj)))))

(defun drgnx-prs-changes ()
  "Pull Requests: Show Changes — the pull request at point in the diff view (git fetches its head first)."
  (interactive)
  (let* ((p (drgnx-prs--at-point)) (root drgnx-prs--root) (remote (drgnx-prs--remote root))
         (n (plist-get p :number)) (ref (format "refs/pullreqs/%d" n)) (default-directory root)
         (err (generate-new-buffer " *drgnx-prs fetch err*" t))
         (process-environment (cons "GIT_TERMINAL_PROMPT=0" process-environment)))   ; never a hidden password prompt
    (message "drgnx: fetching pull request #%d…" n)
    (make-process :name "drgnx-prs-fetch" :buffer nil :stderr err :noquery t :connection-type 'pipe
                  :command (list "git" "fetch" remote (format "+refs/pull/%d/head:%s" n ref))
                  :sentinel (lambda (_proc event)
                              (let ((why (and (buffer-live-p err)
                                              (with-current-buffer err
                                                (car (last (split-string (string-trim (buffer-string)) "\n" t)))))))
                                (cond ((equal event "finished\n")
                                       (when (buffer-live-p err) (when-let* ((ep (get-buffer-process err))) (delete-process ep)) (kill-buffer err))
                                       (drgnx-diff-show (list 'range (format "%s/%s" remote (plist-get p :base)) ref) root))
                                      ((string-match-p "exited\\|failed\\|signal" event)
                                       (when (buffer-live-p err) (when-let* ((ep (get-buffer-process err))) (delete-process ep)) (kill-buffer err))
                                       (drgnx-notify 'prs 'warn
                                                     (format "Fetching pull request #%d failed: %s" n (or why (string-trim event)))
                                                     :command 'prs-fetch))))))))

(defun drgnx-prs--commit-setup ()
  "`git-commit-setup-hook': # completes PR and issue numbers (forge)."
  (when (fboundp 'forge-topic-completion-at-point)
    (add-hook 'completion-at-point-functions #'forge-topic-completion-at-point nil t)))

(defun drgnx-prs--teardown ()
  "Turned off: the Pull Requests tab is closed."
  (dolist (b (buffer-list))
    (when (provided-mode-derived-p (buffer-local-value 'major-mode b) 'drgnx-prs-mode)
      (let ((kill-buffer-query-functions nil)) (kill-buffer b)))))

(drgnx-module-define 'tools/prs
                     :doc "The Pull Requests tab on forge: stacks, forge's review view, Changes in the diff view, # in commits."
                     :stage 'idle :packages '(forge) :requires '(tools/diff) :teardown #'drgnx-prs--teardown
                     :setup
                     (lambda ()
                       (add-hook 'git-commit-setup-hook #'drgnx-prs--commit-setup)
                       (drgnx-notice-define-source 'prs :title "Pull requests" :command 'prs-fetch)
                       (when (fboundp 'drgnx-wb-define-tab) (drgnx-wb-define-tab 'right 'prs :title "Pull Requests"))
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((prs-view "Pull Requests" drgnx-prs-view "This repository's pull requests (forge)")
                                        (prs-fetch "Pull Requests: Fetch" drgnx-prs-fetch "Ask the forge for them (network)")
                                        (prs-open "Pull Requests: Open" drgnx-prs-open "Its reviews, comments and commits (forge)")
                                        (prs-changes "Pull Requests: Show Changes" drgnx-prs-changes "Its changes in the diff view")
                                        (prs-toggle-closed "Pull Requests: Show Closed" drgnx-prs-toggle-closed "Merged and closed ones too")))
                         (drgnx-command-define id :category "Source Control" :title title :command fn :doc doc))))

(provide 'drgnx-prs)
;;; drgnx-prs.el ends here
