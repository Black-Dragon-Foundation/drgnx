;;; drgnx-quick-open.el --- Quick Open: the project's files, ranked by the hub as you type -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; With the hub up, the hub ranks: each key sends `search/files' (the query, the root) and the table shows the rows the
;; hub answers with, the best 100 of the root's names (Hrafn's list: git's in a repository, a walk elsewhere; the
;; setting `drgnx-search-ignore-rules' decides whether dot paths and secret-looking names are in it).  A key never
;; waits for rows: the rows shown stay until the answer's patch arrives, and a patch of an older query is dropped by
;; the patch rules (`drgnx-view-patch--accept': its base is behind the version).  The rows are kept as a list of keys
;; here, not in a view buffer: vertico does the moving.  Nothing is matched or ranked in Lisp.
;;
;; Without the hub, or on a remote folder, Quick Open is `project-find-file'.  As in VS Code, `>' typed first leaves
;; the files for the command palette, with what follows it typed already.  See docs/guide/modules.md ("Quick Open").

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-view)

(defvar drgnx-hub--events)
(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-view-env-register "drgnx-view-env")
(declare-function drgnx-view-env-unregister "drgnx-view-env")
(declare-function drgnx-palette "drgnx-palette")

;;;; The shell: the minibuffer, vertico

(defvar drgnx-quick-open--buffer nil "The minibuffer Quick Open feeds.")

(defvar vertico--input)
(declare-function vertico--exhibit "vertico")
(declare-function project-current "project")
(declare-function project-root "project")
(declare-function project-find-file "project")

(defun drgnx-quick-open--style-all (string table pred _point)
  "A completion style that keeps what the table gives: the hub has matched and ranked the candidates already, and the
user's styles (prefix, orderless) would filter them again by another rule."
  (when-let* ((all (all-completions string table pred))) (nconc all 0)))               ; base size 0: they are whole names

(defun drgnx-quick-open--style-try (string table pred _point)
  "The `try-completion' side of `drgnx-quick-open--style-all'."
  (let ((c (try-completion string table pred)))
    (cond ((eq c t) t) ((stringp c) (cons c (length c))))))

(defconst drgnx-quick-open--style
  '(drgnx-quick-open drgnx-quick-open--style-try drgnx-quick-open--style-all "The candidates the hub chose.")
  "The entry for `completion-styles-alist', bound only while Quick Open reads.")

(defvar drgnx-quick-open--commands nil
  "The text after `>' once Quick Open turned into the command palette (VS Code's `>'), else nil.")

(defun drgnx-quick-open--command-mode (&rest _)
  "Quick Open's minibuffer `after-change-functions' (the first, before the listing hears it): input that starts with
`>' asks for a command, so Quick Open ends and the palette opens with the rest (`drgnx-quick-open--then')."
  (let ((input (minibuffer-contents-no-properties)))
    (when (string-prefix-p ">" input)
      (setq drgnx-quick-open--commands (string-trim-left (substring input 1)))
      ;; out of the minibuffer to the catch around it
      (throw 'drgnx-quick-open--commands nil))))

(defun drgnx-quick-open--then (choice root)
  "After Quick Open of ROOT read CHOICE: the palette when `>' asked for it, else the file opened."
  (if drgnx-quick-open--commands
      (progn (unless (fboundp 'drgnx-palette) (require 'drgnx-palette))
             (drgnx-palette drgnx-quick-open--commands))
    (find-file (expand-file-name choice root))))

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
  "Non-nil when the hub ranks ROOT's files: a local ROOT, and the hub connected."
  (and (not (file-remote-p root))
       (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events)))

(cl-defstruct (drgnx-quick-open--rows (:constructor drgnx-quick-open--rows--make) (:copier nil))
  "A hub-ranked list: VIEW (its id), ROOT, RULES (a `drgnx-view-patch': the base and version rules), KEYS (the rows'
paths, in order) and TEXT (KEY → the candidate, its words marked)."
  view root rules keys (text (make-hash-table :test #'equal)))

(defun drgnx-quick-open--rows-make (view root)
  (drgnx-quick-open--rows--make :view view :root root :rules (drgnx-view-patch--make :view view)))

(defun drgnx-quick-open--rows-query (r input &optional n more)
  "Ask the hub for R's N best rows (default `drgnx-quick-open-rows') for INPUT; the rows shown stay until the answer's
patch.  MORE is a plist of further `search/files' params (the Explorer's Find: `:name', `:exclude')."
  (funcall drgnx-quick-open-send-function "search/files"
           (append (list :view (drgnx-quick-open--rows-view r) :root (drgnx-quick-open--rows-root r) :query input
                         :n (or n drgnx-quick-open-rows))
                   more)))

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
  (add-hook 'after-change-functions #'drgnx-quick-open--command-mode -10 t)
  (drgnx-quick-open--rows-query drgnx-quick-open--current ""))

(defun drgnx-quick-open--read-rows (root)
  "Quick Open of ROOT ranked by the hub; the file chosen is opened."
  (let* ((view (format "quick-open-%d" (cl-incf drgnx-quick-open--views)))
         (drgnx-quick-open--current (drgnx-quick-open--rows-make view root))
         (drgnx-quick-open--buffer nil) (drgnx-quick-open--commands nil))
    (add-hook 'drgnx-hub-event-functions #'drgnx-quick-open--rows-event)
    (unwind-protect
        (let ((choice (catch 'drgnx-quick-open--commands
                        (let ((completion-styles-alist (cons drgnx-quick-open--style completion-styles-alist))
                              (completion-styles '(drgnx-quick-open))
                              (completion-category-overrides nil) (completion-category-defaults nil))
                          (minibuffer-with-setup-hook #'drgnx-quick-open--rows-setup
                            (completing-read "Quick Open: " #'drgnx-quick-open--rows-table nil t))))))
          (drgnx-quick-open--then choice root))
      (remove-hook 'drgnx-hub-event-functions #'drgnx-quick-open--rows-event)
      (drgnx-view-env-unregister view)
      (funcall drgnx-quick-open-send-function "view/close" (list :view view)))))

;;;###autoload
(defun drgnx-quick-open ()
  "Open a file of the project by name: the hub ranks the project's files as you type.
Without the hub (or on a remote folder) this is `project-find-file'."
  (interactive)
  (let ((root (drgnx-quick-open--root)))
    (if (drgnx-quick-open--hub-p root)
        (drgnx-quick-open--read-rows root)
      (call-interactively #'project-find-file))))

(provide 'drgnx-quick-open)
;;; drgnx-quick-open.el ends here
