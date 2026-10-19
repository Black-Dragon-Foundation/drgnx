;;; drgnx-commit-message.el --- Module tools/commit-message: Git: Generate Commit Message -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; In a commit message buffer (magit's, or VC's log-edit), Git: Generate Commit Message sends the staged diff (VC:
;; the diff of the files being committed) and the repository's last ten subjects, for style, to the AI registry's
;; `chat' role.  The answer fills an empty message; a message you already typed is left alone and the suggestion
;; goes to the kill ring.  The message never carries a trailer (Co-authored-by, Signed-off-by…) or a mention of AI:
;; the model is told so, and whatever it adds anyway is stripped.  See docs/guide/git.md.

;;; Code:
(require 'subr-x)
(require 'seq)
(require 'drgnx-modules)
(require 'drgnx-registry)

(declare-function drgnx-ai-request "drgnx-ai-client")
(declare-function drgnx-ai-cancel "drgnx-ai-client")
(declare-function drgnx-ai-confirm-project-route "drgnx-ai")
(declare-function log-edit-files "log-edit")
(defvar git-commit-mode)

(defvar drgnx-commit-message-max-chars 24000 "The longest diff sent; a longer one is cut (and says so).")

(defconst drgnx-commit-message--instructions
  "Write a git commit message for the diff the user sends. First line: an imperative summary of at most 72 \
characters, no trailing period. Then, only if it adds the why, a blank line and a short body wrapped at 72 columns. \
No trailers, no Co-authored-by, no mention of AI or tools. Match the style of these recent subjects from this \
repository:"
  "What the chat role is told (the subjects follow).")

(defvar drgnx-commit-message--request nil "The request still writing a message.")

(defun drgnx-commit-message--git (root &rest args)
  "git ARGS' output in ROOT, or nil when git fails."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory root)))
      (and (eql 0 (apply #'call-process "git" nil '(t nil) nil args)) (buffer-string)))))

(defun drgnx-commit-message--kind (root)
  "How the commit being written is made: `amend' (git commit --amend), `amend-all' (--amend -a), `reword' (--amend
--only: HEAD's own tree), `all' (-a) or nil (the index as it is).  Magit's record of the command it ran, else the
git commit process whose buffer says it runs in ROOT (a process without a buffer cannot be told from another
repository's, so it is not used).  Short flags bundled with others (-am) are not seen: the index is described."
  (let ((cmd (and (fboundp 'magit-repository-local-get)
                  (let ((default-directory root)) (ignore-errors (magit-repository-local-get 'this-commit-command))))))
    (or (pcase cmd
          ('magit-commit-amend 'amend)
          ('magit-commit-reword 'reword)
          ('magit-commit--all 'all))
        (seq-some (lambda (p)
                    (let ((c (and (process-live-p p) (process-command p))) (buf (process-buffer p)))
                      (when (and (equal (file-name-nondirectory (or (car-safe c) "")) "git") (member "commit" c)
                                 (buffer-live-p buf)
                                 (file-equal-p (buffer-local-value 'default-directory buf) root))
                        (let ((all (or (member "--all" c) (member "-a" c))))
                          (cond ((and (member "--amend" c) (member "--only" c)) 'reword)
                                ((member "--amend" c) (if all 'amend-all 'amend))
                                (all 'all))))))
                  (process-list)))))

(defun drgnx-commit-message--diff (root files)
  "The diff to describe: FILES' against HEAD (what VC commits), else what the commit will hold: the index's, with
--amend the index against HEAD's parent (the empty tree for the first commit), with --amend -a the working tree
against it, with --amend --only HEAD against its parent, with -a the working tree against HEAD.
The index of a repository with no commit yet is against the empty tree already."
  (let ((kind (and (null files) (drgnx-commit-message--kind root)))
        (head (drgnx-commit-message--git root "rev-parse" "--verify" "-q" "HEAD")))
    (or (apply #'drgnx-commit-message--git root "diff" "--no-color" "--no-ext-diff"
               (cond (files (append '("HEAD" "--") files))
                     ((and (memq kind '(amend amend-all reword)) head)
                      (let ((parent (if (drgnx-commit-message--git root "rev-parse" "--verify" "-q" "HEAD^") "HEAD^"
                                      (string-trim (or (drgnx-commit-message--git root "hash-object" "-t" "tree" "/dev/null") "")))))
                        (pcase kind
                          ('amend (list "--cached" parent))
                          ('amend-all (list parent))
                          ('reword (list parent "HEAD")))))
                     ((and (eq kind 'all) head) '("HEAD"))
                     (t '("--cached"))))
        "")))

(defun drgnx-commit-message--subjects (root)
  (split-string (or (drgnx-commit-message--git root "log" "-10" "--format=%s") "") "\n" t))

(defun drgnx-commit-message--payload (diff subjects)
  "The chat request for DIFF (cut at `drgnx-commit-message-max-chars'), in the style of SUBJECTS."
  (list :messages
        (vector (list :role "system" :content (concat drgnx-commit-message--instructions "\n" (string-join subjects "\n")))
                (list :role "user" :content (if (> (length diff) drgnx-commit-message-max-chars)
                                                (concat (substring diff 0 drgnx-commit-message-max-chars) "\n[diff truncated]")
                                              diff)))))

(defun drgnx-commit-message--clean (text)
  "TEXT without code fences, trailers (…-by: lines) or lines naming a tool (\"🤖 Generated with …\", \"made by …\"),
trimmed."
  (let* ((case-fold-search t)
         (lines (seq-remove (lambda (l)
                              (or (string-match-p "\\`\\(```.*\\|[A-Za-z-]+-by:.*\\)\\'" l)
                                  (string-match-p "\\`[^[:alnum:]]*\\(generated\\|made\\|created\\|written\\)[ \t]+\\(with\\|by\\)\\b" l)))
                            (split-string text "\n"))))
    (string-trim (replace-regexp-in-string "\n\n\n+" "\n\n" (string-join lines "\n")))))

(defun drgnx-commit-message--buffer-p ()
  (or (bound-and-true-p git-commit-mode) (derived-mode-p 'log-edit-mode)))

(defun drgnx-commit-message--area-end ()
  "Where the message ends: before git's first comment line (log-edit: the end)."
  (save-excursion
    (goto-char (point-min))
    (if (and (bound-and-true-p git-commit-mode) (re-search-forward "^#" nil t)) (match-beginning 0) (point-max))))

(defun drgnx-commit-message--answer (buf text info)
  "The chat role's answer TEXT (INFO) for the commit buffer BUF."
  (setq drgnx-commit-message--request nil)
  (let ((msg (and text (drgnx-commit-message--clean text))))
    (cond
     ((null text) (message "drgnx: no commit message: %s" (or (plist-get info :error) "no answer")))
     ((string-empty-p msg) (message "drgnx: the answer held no commit message"))
     ((not (buffer-live-p buf)))
     (t (with-current-buffer buf
          (if (string-blank-p (buffer-substring-no-properties (point-min) (drgnx-commit-message--area-end)))
              (save-excursion
                (goto-char (point-min))
                (delete-region (point-min) (drgnx-commit-message--area-end))
                (insert msg "\n"))
            (kill-new msg)
            (message "drgnx: a commit message is in the kill ring (C-y)")))))))

(defun drgnx-commit-message-generate ()
  "Git: Generate Commit Message — the staged diff, described by the `chat' role, in this commit message buffer."
  (interactive)
  (unless (drgnx-commit-message--buffer-p) (user-error "Not a commit message buffer"))
  (let* ((root default-directory)
         (files (and (derived-mode-p 'log-edit-mode) (fboundp 'log-edit-files) (log-edit-files)))
         (diff (drgnx-commit-message--diff root files))
         (buf (current-buffer)))
    (when (string-blank-p diff) (user-error "Nothing staged"))
    (require 'drgnx-ai)
    (let ((default-directory root)) (drgnx-ai-confirm-project-route))   ; a project's remote route: asked here, once
    (require 'drgnx-ai-client)
    (when drgnx-commit-message--request (drgnx-ai-cancel drgnx-commit-message--request))
    (message "drgnx: writing a commit message…")
    (setq drgnx-commit-message--request
          (drgnx-ai-request 'chat 'chat (drgnx-commit-message--payload diff (drgnx-commit-message--subjects root))
                            (lambda (text info) (drgnx-commit-message--answer buf text info))
                            :interactive t :timeout 60))))

(drgnx-module-define 'tools/commit-message
                     :doc "Git: Generate Commit Message — the staged diff through the chat role; never a trailer."
                     :stage 'idle
                     :setup (lambda ()
                              (drgnx-command-define 'git-generate-commit-message :category "Source Control"
                                                    :title "Git: Generate Commit Message" :command #'drgnx-commit-message-generate
                                                    :doc "A message for the staged changes, written by the chat role")))

(provide 'drgnx-commit-message)
;;; drgnx-commit-message.el ends here
