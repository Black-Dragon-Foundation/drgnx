;;; drgnx-settings-review.el --- Settings: Review and Allow, and the quiet path -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 19 (design §9; docs/guide/settings.md, "Reviewing a workspace's code").
;; A workspace's code never runs until you allow it.  What waits is `drgnx-settings-trust-waiting'; this file shows it
;; and calls Task 18 to allow or deny it.
;; - `drgnx-settings-review-code' (Settings: Review Workspace Code): a buffer with each waiting piece of code at
;;   file:line with its value, and for a changed one the diff against the value you allowed; [Allow] [Deny] per piece
;;   and [Allow All].  Allow and Deny apply at once (Task 18 re-hacks the open buffers) and the list redraws.  An
;;   untrusted workspace lists what waits for trust, with Trust This Folder as the way on, and no Allow.
;; - `drgnx-settings-workspace-waiting-summary' gives the Workspace group its counts.
;; - `drgnx-settings-review-notify': one notice per workspace and session, never a prompt.  It is posted from a timer
;;   function after the workspace filters ran (`drgnx-settings-review--schedule'), so a filter or hook path never waits.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'pp)
(require 'drgnx-settings-trust)

(declare-function drgnx-notify "drgnx-notice")
(declare-function drgnx-command-define "drgnx-command")

;;;; The summary

(defun drgnx-settings-workspace-waiting-summary (root)
  "What waits in the workspace ROOT, as (:settings N :code M): N pieces of data (values that wait for trust), M pieces
of code (that wait for review).  Never signals."
  (let ((settings 0) (code 0))
    (dolist (i (ignore-errors (drgnx-settings-trust-waiting root)))
      (pcase (plist-get i :class) ('code (cl-incf code)) ('data (cl-incf settings))))
    (list :settings settings :code code)))

;;;; The quiet path

(defvar drgnx-settings-review--notified nil "The roots a waiting notice was posted for this session.")

(defun drgnx-settings-review--plural (n one many) (format "%d %s" n (if (= n 1) one many)))

(defun drgnx-settings-review--text (summary)
  "The notice text for SUMMARY, or nil when nothing waits."
  (let ((s (plist-get summary :settings)) (c (plist-get summary :code)))
    (cond ((and (> s 0) (> c 0))
           (format "%s and %s wait" (drgnx-settings-review--plural s "setting" "settings")
                   (drgnx-settings-review--plural c "piece of code" "pieces of code")))
          ((> s 0) (format "%s wait%s" (drgnx-settings-review--plural s "setting" "settings") (if (= s 1) "s" "")))
          ((> c 0) (format "%s wait%s" (drgnx-settings-review--plural c "piece of code" "pieces of code")
                           (if (= c 1) "s" ""))))))

(defun drgnx-settings-review-notify (root)
  "Post the one notice for the workspace ROOT this session: what waits, with Review Workspace Code as its command
(Trust This Folder is named in its fix).  Nothing waiting, or already posted: nothing.  Never prompts, never signals.
Returns the notice key, or nil."
  (condition-case nil
      (let* ((root (drgnx-settings-trust--norm root))
             (text (and (not (member root drgnx-settings-review--notified))
                        (drgnx-settings-review--text (drgnx-settings-workspace-waiting-summary root)))))
        (when (and text (require 'drgnx-notice nil t))
          (push root drgnx-settings-review--notified)
          (drgnx-notify 'config 'info (format "%s in %s" text (abbreviate-file-name root))
                        :id (concat "workspace-waiting:" root)
                        :fix "Trust This Folder (File menu), or review the code first"
                        :command (list 'drgnx-settings-review-code (abbreviate-file-name root)))))
    (error nil)))

(defvar drgnx-settings-review--scheduled nil "Roots whose notice is queued.")

(defun drgnx-settings-review--run (root)
  (setq drgnx-settings-review--scheduled (delete root drgnx-settings-review--scheduled))
  (drgnx-settings-review-notify root))

(defun drgnx-settings-review--schedule (root)
  "Queue `drgnx-settings-review-notify' for ROOT after the current command (a workspace filter calls this when
something waits).  Never signals."
  (ignore-errors
    (unless (or (member root drgnx-settings-review--notified) (member root drgnx-settings-review--scheduled))
      (push root drgnx-settings-review--scheduled)
      (run-at-time 0 nil #'drgnx-settings-review--run root))))

;;;; The diff of a changed value

(defun drgnx-settings-review--lines (value)
  (split-string (string-trim-right (let ((print-length nil) (print-level nil)) (pp-to-string value))) "\n"))

(defun drgnx-settings-review--diff (old new)
  "A line diff of the lists of lines OLD and NEW: strings prefixed \"  \", \"- \" or \"+ \"."
  (let* ((n (length old)) (m (length new)) (old (vconcat old)) (new (vconcat new))
         (tab (make-vector (1+ n) nil)) (out nil))
    (dotimes (i (1+ n)) (aset tab i (make-vector (1+ m) 0)))
    (cl-loop for i from (1- n) downto 0 do
             (cl-loop for j from (1- m) downto 0 do
                      (aset (aref tab i) j
                            (if (equal (aref old i) (aref new j)) (1+ (aref (aref tab (1+ i)) (1+ j)))
                              (max (aref (aref tab (1+ i)) j) (aref (aref tab i) (1+ j)))))))
    (let ((i 0) (j 0))
      (while (or (< i n) (< j m))
        (cond ((and (< i n) (< j m) (equal (aref old i) (aref new j)))
               (push (concat "  " (aref old i)) out) (cl-incf i) (cl-incf j))
              ((and (< i n) (or (>= j m) (>= (aref (aref tab (1+ i)) j) (aref (aref tab i) (1+ j)))))
               (push (concat "- " (aref old i)) out) (cl-incf i))
              (t (push (concat "+ " (aref new j)) out) (cl-incf j)))))
    (nreverse out)))

(defun drgnx-settings-review-item-diff (item)
  "ITEM's diff against the allowed value it replaces, as a list of lines, or nil when ITEM is not a changed pair."
  (when (plist-member item :was)
    (drgnx-settings-review--diff (drgnx-settings-review--lines (plist-get item :was))
                                 (drgnx-settings-review--lines (plist-get item :value)))))

;;;; The buffer

(defvar-local drgnx-settings-review--root nil "The workspace this buffer reviews.")

(defvar-keymap drgnx-settings-review-mode-map
  :doc "Keys of the Review Workspace Code buffer."
  :parent special-mode-map
  "a" #'drgnx-settings-review-allow-at-point
  "A" #'drgnx-settings-review-allow-all
  "d" #'drgnx-settings-review-deny-at-point
  "t" #'drgnx-settings-review-trust-folder)

(define-derived-mode drgnx-settings-review-mode special-mode "Review"
  "The code a workspace's files wait to run: allow or deny each piece.  Nothing here runs it without an Allow."
  (setq-local truncate-lines nil))

(defun drgnx-settings-review--item-at-point ()
  (or (get-text-property (point) 'drgnx-review-item)
      (and (not (bobp)) (get-text-property (1- (point)) 'drgnx-review-item))
      (user-error "No piece of code here")))

(defun drgnx-settings-review--button (label action)
  (insert-text-button (format "[%s]" label) 'action (lambda (_) (funcall action)) 'follow-link t
                      'help-echo label 'face 'button))

(defun drgnx-settings-review--insert-item (item trusted)
  (let ((start (point)) (diff (drgnx-settings-review-item-diff item)))
    (insert (format "%s:%s  %s  (%s)\n" (plist-get item :file) (or (plist-get item :line) "?") (plist-get item :var)
                    (plist-get item :class)))
    (if diff
        (progn (insert "    changed since you allowed it:\n")
               (dolist (l diff) (insert "    " l "\n")))
      (dolist (l (drgnx-settings-review--lines (plist-get item :value))) (insert "    " l "\n")))
    (when trusted
      (insert "    ")
      (drgnx-settings-review--button "Allow" #'drgnx-settings-review-allow-at-point)
      (insert " ")
      (drgnx-settings-review--button "Deny" #'drgnx-settings-review-deny-at-point)
      (insert "\n"))
    (insert "\n")
    (put-text-property start (point) 'drgnx-review-item item)))

(defun drgnx-settings-review--draw ()
  "Draw the buffer's workspace again, keeping the line."
  (let* ((root drgnx-settings-review--root) (line (line-number-at-pos))
         (state (drgnx-settings-trust-state root))
         (items (drgnx-settings-trust-waiting root))
         (code (seq-filter (lambda (i) (eq (plist-get i :class) 'code)) items))
         (data (seq-filter (lambda (i) (eq (plist-get i :class) 'data)) items))
         (trusted (memq state '(location trusted)))
         (inhibit-read-only t))
    (erase-buffer)
    (insert (format "Workspace code waiting in %s\n" (abbreviate-file-name root)))
    (insert (format "State: %s.  Code runs only after an Allow; a change waits again.\n\n" state))
    (cond
     ((null items) (insert "Nothing waits.\n"))
     (t
      (unless trusted
        (insert "This workspace is not trusted, so nothing here can be allowed yet: ")
        (drgnx-settings-review--button "Trust This Folder" #'drgnx-settings-review-trust-folder)
        (insert "\n\n"))
      (when code
        (insert (format "Code (%d)\n\n" (length code)))
        (when trusted (drgnx-settings-review--button "Allow All" #'drgnx-settings-review-allow-all) (insert "\n\n"))
        (dolist (i code) (drgnx-settings-review--insert-item i trusted)))
      (when data
        (insert (format "Settings waiting for trust (%d)\n\n" (length data)))
        (dolist (i data) (drgnx-settings-review--insert-item i nil)))))
    (goto-char (point-min))
    (forward-line (1- line))))

;;;###autoload
(defun drgnx-settings-review-code (&optional root)
  "Settings: Review Workspace Code.  List what waits in the workspace ROOT (default: this buffer's) at file:line, with
the diff of a changed value, and allow or deny it piece by piece.  Never runs anything itself."
  (interactive)
  (let ((root (drgnx-settings-trust--norm
               (or root (drgnx-settings-trust--buffer-root) (user-error "Review works in a file's buffer")))))
    (with-current-buffer (get-buffer-create (format "*Review Workspace Code: %s*" (abbreviate-file-name root)))
      (drgnx-settings-review-mode)
      (buffer-disable-undo)
      (setq drgnx-settings-review--root root)
      (drgnx-settings-review--draw)
      (pop-to-buffer (current-buffer))
      (current-buffer))))

(defun drgnx-settings-review--act (fn items)
  (when items
    (funcall fn drgnx-settings-review--root items)
    (drgnx-settings-review--draw)))

(defun drgnx-settings-review-allow-at-point ()
  "Allow the piece of code at point."
  (interactive)
  (drgnx-settings-review--act #'drgnx-settings-trust-allow (list (drgnx-settings-review--item-at-point))))

(defun drgnx-settings-review-deny-at-point ()
  "Deny the piece of code at point; it is ignored silently from now on."
  (interactive)
  (drgnx-settings-review--act #'drgnx-settings-trust-deny (list (drgnx-settings-review--item-at-point))))

(defun drgnx-settings-review-allow-all ()
  "Allow every piece of code listed, exactly as shown."
  (interactive)
  (drgnx-settings-review--act
   #'drgnx-settings-trust-allow
   (seq-filter (lambda (i) (eq (plist-get i :class) 'code)) (drgnx-settings-trust-waiting drgnx-settings-review--root))))

(defun drgnx-settings-review-trust-folder ()
  "Trust This Folder from the review buffer (it shows the code and asks)."
  (interactive)
  (drgnx-settings-trust-this-folder drgnx-settings-review--root :ask)
  (drgnx-settings-review--draw))

;;;; The command

(defun drgnx-settings-review-setup ()
  "Register Settings: Review Workspace Code (`drgnx-trust-setup' calls this)."
  (drgnx-command-define 'review-workspace-code :category "Settings" :title "Review Workspace Code"
                        :command #'drgnx-settings-review-code :when (lambda () buffer-file-name)
                        :doc "List the code this project's files wait to run, with the diff of what changed, and allow or deny each piece"))

(provide 'drgnx-settings-review)
;;; drgnx-settings-review.el ends here
