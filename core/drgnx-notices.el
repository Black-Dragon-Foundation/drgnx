;;; drgnx-notices.el --- The Notices list and the mode-line pair of counts -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Two readers of the notice model (drgnx-notice.el).  The Notices list, `drgnx-notices-show', is one buffer in three
;; sections -- Needs you, Problems, Recent -- drawn through the render pipeline's views (wb/drgnx-view.el, loaded
;; when the list is first shown): a row per notice, patched in place when its notice changes.  It follows the model
;; on the `now' lane with one idle timer that only marks the view.  The mode-line pair, `drgnx-notice-mode-line-mode',
;; puts the needs-you and problems counts in `global-mode-string'; their texts are memoised on the model's tick, so a
;; redisplay reads cached strings and allocates nothing.  Core: nothing here needs the workbench except the view
;; library the list is drawn with.  See docs/develop/core.md, "Notices", and docs/guide/notices.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-notice)
(require 'drgnx-registry)
(require 'drgnx-timer)
(require 'drgnx-ui-kit)

(declare-function drgnx-view-define "drgnx-view")
(declare-function drgnx-view-type-p "drgnx-view")
(declare-function drgnx-view-attach "drgnx-view")
(declare-function drgnx-view-touch "drgnx-view")
(declare-function drgnx-view-draw-now "drgnx-view")
(declare-function drgnx-view-key-at "drgnx-view")
(declare-function drgnx-view-sync-rows "drgnx-view")
(declare-function drgnx-view-p "drgnx-view")
(defvar drgnx-view)

(defconst drgnx-notices-buffer-name "*drgnx Notices*" "The Notices list's buffer.")

;;;; Rows

(defvar drgnx-notices--rows (make-hash-table :test #'equal)
  "KEY → what the list draws for it: a notice (a plist) or a heading's text.  Filled by `drgnx-notices--sync'.")

(defun drgnx-notices--source-title (source)
  (or (plist-get (gethash source drgnx-notice--sources) :title) (symbol-name source)))

(defun drgnx-notices--action (command)
  "COMMAND (a registry id, a command, or (FN . ARGS)) as an action for `drgnx-ui-button'."
  (if (consp command)
      (lambda () (if (fboundp (car command)) (apply (car command) (cdr command))
                   (user-error "%s is not available (its module is off)" (car command))))
    command))

(defun drgnx-notices--command-title (command)
  "The registry title of COMMAND, else its name."
  (let ((id (if (consp command) (car command) command)))
    (let ((cmd (drgnx-commands-get id)))
      (if cmd (drgnx-cmd-title cmd) (symbol-name id)))))

(defun drgnx-notices--render-notice (n)
  "The rows of notice N: its status, source and text; the fix; the buttons."
  (let* ((life (plist-get n :life)) (command (plist-get n :command)) (fix (plist-get n :fix))
         (count (plist-get n :count))
         (key (cons (plist-get n :source) (plist-get n :id)))
         (buttons nil))
    (unless (eq life 'attention)
      (push (drgnx-ui-button "Dismiss" (lambda () (drgnx-notice-dismiss key))) buttons))
    (when command
      (push (drgnx-ui-button (drgnx-notices--command-title command) (drgnx-notices--action command)) buttons))
    (concat (drgnx-ui-status (plist-get n :severity)) " "
            (propertize (drgnx-notices--source-title (plist-get n :source)) 'face 'shadow) "  "
            (plist-get n :text)
            (if (and count (> count 1)) (format " ×%d" count) "")
            "\n"
            (if fix (concat "    " (propertize fix 'face 'drgnx-status-info) "\n") "")
            (if buttons (concat "    " (string-join buttons "  ") "\n") ""))))

(defun drgnx-notices--render (key)
  "The text of the list's row KEY (see `drgnx-notices--sync')."
  (let ((what (gethash key drgnx-notices--rows)))
    (cond ((stringp what) (if (eq (car-safe key) 'none) (concat "  " what "\n")
                            (concat (if (eq (cdr key) 'needs-you) "" "\n") (propertize what 'face 'bold) "\n")))
          (what (drgnx-notices--render-notice what))
          (t "\n"))))

(defun drgnx-notices--sig (key)
  "KEY's signature: what its row says (a notice and its repeat count; a heading's text)."
  (let ((what (gethash key drgnx-notices--rows)))
    (cond ((stringp what) (sxhash-equal what))
          (what (vector what (plist-get what :count)))
          (t nil))))

(defun drgnx-notices--section (name heading notices)
  "The keys of the section NAME: its HEADING, then a row per notice in NOTICES, or \"Nothing here.\""
  (let ((keys (list (cons 'head name))))
    (puthash (car keys) heading drgnx-notices--rows)
    (if (null notices)
        (let ((none (cons 'none name))) (puthash none "Nothing here." drgnx-notices--rows) (push none keys))
      (dolist (n notices)
        (let ((k (if (eq (plist-get n :life) 'attention)
                     (cons 'attention (plist-get n :id))
                   (cons (plist-get n :life) (cons (plist-get n :source) (plist-get n :id))))))
          (puthash k n drgnx-notices--rows)
          (push k keys))))
    (nreverse keys)))

(defun drgnx-notices--sync (view)
  "Make VIEW's rows the model's now: the three sections."
  (clrhash drgnx-notices--rows)
  (let* ((needs (drgnx-needs-you-items)) (problems (drgnx-problems-count)))
    (drgnx-view-sync-rows
     view
     (append (drgnx-notices--section 'needs-you (format "Needs you (%d)" (length needs)) needs)
             (drgnx-notices--section 'problems
                                     (format "Problems (%s %d %s %d)" (drgnx-face-glyph 'fail) (cdr problems)
                                             (drgnx-face-glyph 'warn) (car problems))
                                     (drgnx-notices :life 'condition))
             (drgnx-notices--section 'recent "Recent" (drgnx-notices :life 'event)))
     #'drgnx-notices--sig)))

;;;; The buffer

(define-derived-mode drgnx-notices-mode special-mode "Notices"
  "Problems, things waiting on you and recent events, in one list.  \\`g' redraws."
  (setq-local revert-buffer-function #'drgnx-notices--revert)
  (add-hook 'kill-buffer-hook #'drgnx-notices--killed nil t))

(defun drgnx-notices--view ()
  "The list's view, or nil when its buffer is not live."
  (when-let* ((buffer (get-buffer drgnx-notices-buffer-name)))
    (let ((view (buffer-local-value 'drgnx-view buffer)))
      (and (drgnx-view-p view) view))))

(defun drgnx-notices--revert (&rest _)
  "`g': draw the list again now."
  (when-let* ((view (drgnx-notices--view)))
    (drgnx-view-touch view)
    (drgnx-view-draw-now view)))

(defun drgnx-notices--killed ()
  "The list's buffer is going: stop following the model."
  (remove-hook 'drgnx-notice-functions #'drgnx-notices--changed)
  (drgnx-timer-cancel 'notices-list))

(defun drgnx-notices--redraw ()
  "The idle timer: the model changed; mark the view (it draws only while shown)."
  (when-let* ((view (drgnx-notices--view)))
    (drgnx-view-touch view)))

(defun drgnx-notices--changed (_change)
  "On the model's `now' lane: arm one idle redraw.  Nothing else."
  (drgnx-timer-start 'notices-list 0.1 #'drgnx-notices--redraw :idle t :owner :core))

(defun drgnx-notices--define-view ()
  (require 'drgnx-view)
  (unless (drgnx-view-type-p 'notices-list)
    (drgnx-view-define 'notices-list :render #'drgnx-notices--render :sync #'drgnx-notices--sync :delay 0)))

;;;###autoload
(defun drgnx-notices-show ()
  "Show the Notices list: what needs you, the problems now and what happened lately."
  (interactive)
  (drgnx-notices--define-view)
  (let ((buffer (get-buffer-create drgnx-notices-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-notices-mode) (drgnx-notices-mode))
      (unless (drgnx-notices--view) (drgnx-view-attach 'notices-list))
      (drgnx-notices--revert))
    (add-hook 'drgnx-notice-functions #'drgnx-notices--changed)
    (pop-to-buffer buffer)))

(defun drgnx-notices-dismiss-at-point ()
  "Dismiss the event or condition on this row: it stays hidden until it is posted again with other text."
  (interactive)
  (let* ((what (gethash (drgnx-view-key-at) drgnx-notices--rows)))
    (cond ((not (consp what)) (user-error "No notice here"))
          ((eq (plist-get what :life) 'attention)
           (user-error "This waits on you; it goes when its source no longer holds it"))
          (t (drgnx-notice-dismiss (cons (plist-get what :source) (plist-get what :id)))))))

(defun drgnx-notices-register-commands ()
  "The commands of the list."
  (drgnx-command-define 'notices :category "View" :title "Show Notices" :command #'drgnx-notices-show
                        :menu '("View") :doc "Problems, things waiting on you and recent events, in one list")
  (drgnx-command-define 'notices-dismiss :category "Notices" :title "Dismiss Notice"
                        :command #'drgnx-notices-dismiss-at-point :map 'drgnx-notices-mode-map
                        :when (lambda () (derived-mode-p 'drgnx-notices-mode))
                        :doc "Hide the event or condition on this row until it is posted again with other text"))

;;;; The texts

(defvar drgnx-notice--needs-memo (vector -1 nil nil nil)
  "[TICK GLYPHS TABLE TEXT] of the last `drgnx-notice-needs-you-text'.")

(defvar drgnx-notice--problems-memo (vector -1 nil nil nil)
  "[TICK GLYPHS TABLE TEXT] of the last `drgnx-notice-problems-text'.")

(defvar drgnx-notice--line-memo (vector nil nil nil)
  "[NEEDS-YOU-TEXT PROBLEMS-TEXT LINE] of the last `drgnx-notice-mode-line'.")

(defun drgnx-notice-needs-you-click ()
  "The needs-you count was clicked: with every item from one source, do what its newest item says; else show the list."
  (interactive)
  (let* ((items (drgnx-needs-you-items)) (first (car items)) (one t))
    (dolist (item (cdr items))
      (unless (eq (plist-get item :source) (plist-get first :source)) (setq one nil)))
    (if (and first one (plist-get first :command))
        (drgnx-ui--run (drgnx-notices--action (plist-get first :command)))
      (drgnx-notices-show))))

(defun drgnx-notice-needs-you-text ()
  "`◐ N waiting on you' in `drgnx-status-needs-you', or nil.  Memoised on the tick: a read allocates nothing."
  (let ((m drgnx-notice--needs-memo))
    (if (and (eq (aref m 0) drgnx-notice--tick) (eq (aref m 1) drgnx-face-glyphs) (eq (aref m 2) drgnx-notice--table))
        (aref m 3)
      (let ((n drgnx-notice--needs-you))
        (aset m 3 (and (> n 0)
                       (drgnx-ui-button (format "%s %d waiting on you" (drgnx-face-glyph 'waiting) n)
                                        #'drgnx-notice-needs-you-click :face 'drgnx-status-needs-you
                                        :where 'mode-line :help "Things waiting on you (mouse-1: act or list)")))
        (aset m 0 drgnx-notice--tick) (aset m 1 drgnx-face-glyphs) (aset m 2 drgnx-notice--table)
        (aref m 3)))))

(defun drgnx-notice-problems-text ()
  "`✕ F', `⚠ W' or `✕ F ⚠ W' (failed, then warned conditions), or nil.  Memoised like the needs-you text."
  (let ((m drgnx-notice--problems-memo))
    (if (and (eq (aref m 0) drgnx-notice--tick) (eq (aref m 1) drgnx-face-glyphs) (eq (aref m 2) drgnx-notice--table))
        (aref m 3)
      (let* ((p drgnx-notice--problems) (warn (car p)) (fail (cdr p)))
        (aset m 3 (and (or (> warn 0) (> fail 0))
                       (drgnx-ui-button
                        (cond ((and (> fail 0) (> warn 0))
                               (format "%s %d %s %d" (drgnx-face-glyph 'fail) fail (drgnx-face-glyph 'warn) warn))
                              ((> fail 0) (format "%s %d" (drgnx-face-glyph 'fail) fail))
                              (t (format "%s %d" (drgnx-face-glyph 'warn) warn)))
                        #'drgnx-notices-show :face (if (> fail 0) 'drgnx-status-fail 'drgnx-status-warn)
                        :where 'mode-line :help "Problems (mouse-1: the Notices list)")))
        (aset m 0 drgnx-notice--tick) (aset m 1 drgnx-face-glyphs) (aset m 2 drgnx-notice--table)
        (aref m 3)))))

(defun drgnx-notice-mode-line ()
  "The two texts joined by a space, or nil; the same string while neither text changed."
  (let ((a (drgnx-notice-needs-you-text)) (b (drgnx-notice-problems-text)) (m drgnx-notice--line-memo))
    (if (and (eq a (aref m 0)) (eq b (aref m 1)))
        (aref m 2)
      (aset m 0 a) (aset m 1 b)
      (aset m 2 (if (and a b) (concat a " " b) (or a b))))))

;;;; The mode

(defconst drgnx-notice--mode-line-form '(:eval (drgnx-notice-mode-line))
  "What `drgnx-notice-mode-line-mode' puts in `global-mode-string'.")

(defun drgnx-notice--mode-line-changed (_change)
  "On the model's `now' lane: redraw the mode lines (they read the memoised texts)."
  (force-mode-line-update t))

(define-minor-mode drgnx-notice-mode-line-mode
  "Show the needs-you and problems counts in the mode line."
  :global t :group 'drgnx
  (setq global-mode-string (delete drgnx-notice--mode-line-form global-mode-string))
  (if drgnx-notice-mode-line-mode
      (progn (setq global-mode-string (append (ensure-list global-mode-string) (list drgnx-notice--mode-line-form)))
             (add-hook 'drgnx-notice-functions #'drgnx-notice--mode-line-changed))
    (remove-hook 'drgnx-notice-functions #'drgnx-notice--mode-line-changed))
  (force-mode-line-update t))

(provide 'drgnx-notices)
;;; drgnx-notices.el ends here
