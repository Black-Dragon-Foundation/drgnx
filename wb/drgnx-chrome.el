;;; drgnx-chrome.el --- Chrome by role: tab lines, breadcrumbs, mode lines -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Every window's chrome is decided by its role, never by its buffer (invariant I3): an editor
;; window has a tab line (the buffers shown in it, in the order they were opened — switching
;; never reorders them), a breadcrumb header (project › folders › file, ● when unsaved) and a
;; mode line; a dock section has its title only; the panel and the right dock have their tab row
;; only.  The chrome lives in window parameters, which win over any mode's own
;; `header-line-format', `tab-line-format' or `mode-line-format', so no buffer can make a
;; window's text jump.  New windows get their chrome before they are first drawn (the change
;; bus's window setup); tabs and breadcrumbs follow the bus's edges.  See docs/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'project)
(require 'drgnx-area)

(defface drgnx-chrome-tab '((t :inherit tab-line-tab-inactive)) "A tab in an editor's tab line." :group 'drgnx)
(defface drgnx-chrome-tab-current '((t :inherit tab-line-tab-current)) "The shown tab." :group 'drgnx)
(defface drgnx-chrome-crumb '((t :inherit shadow)) "The folders of a breadcrumb." :group 'drgnx)

(defun drgnx-chrome--role (w)
  "W's chrome role: `editor', `dock', `area', `lane', or nil (left alone)."
  (let ((role (window-parameter w 'drgnx-role)))
    (cond ((window-minibuffer-p w) nil)
          ((window-parameter w 'drgnx-popup) 'lane)
          ((eq role 'popup) 'lane)
          ((eq role 'dock) 'dock)
          ((memq role '(panel right)) 'area)
          ((drgnx-signal-editor-window-p w) 'editor))))

;;;; Tabs

(defun drgnx-chrome--tab-buffer-p (b)
  (and (buffer-live-p b) (not (string-prefix-p " " (buffer-name b)))))

(defun drgnx-chrome-tabs (w)
  "The buffers W has shown, in the order they were opened (live ones)."
  (seq-filter #'buffer-live-p (window-parameter w 'drgnx-tabs)))

(defcustom drgnx-chrome-transient-tabs "\\`\\*scratch\\*\\'"
  "Buffers that are a tab only while shown (like VS Code's welcome tab)."
  :type 'regexp :group 'drgnx)

(defun drgnx-chrome--note (w)
  "Add W's buffer to its tabs (at the end; never reordered); drop transient tabs not shown."
  (let ((b (window-buffer w)))
    (set-window-parameter
     w 'drgnx-tabs
     (let ((tabs (seq-remove (lambda (x) (and (not (eq x b)) (string-match-p drgnx-chrome-transient-tabs (buffer-name x))))
                             (drgnx-chrome-tabs w))))
       ;; Buffers it showed since it was last drawn (one command visiting several files), oldest first.
       (dolist (x (append (reverse (mapcar #'car (window-prev-buffers w))) (list b)))
         (when (and (drgnx-chrome--tab-buffer-p x) (not (memq x tabs))
                    (or (eq x b) (not (string-match-p drgnx-chrome-transient-tabs (buffer-name x))))
                    (or (eq x b) (not (memq x (window-parameter w 'drgnx-closed)))))
           (setq tabs (append tabs (list x)))))
       tabs))))

(defun drgnx-chrome--select-tab (event)
  "Show the tab clicked in a tab line."
  (interactive "e")
  (when-let* ((posn (event-start event)) (s (posn-string posn))
              (b (get-text-property (cdr s) 'drgnx-buffer (car s))) (w (posn-window posn)))
    (when (buffer-live-p b) (set-window-buffer w b) (drgnx-chrome-apply (window-frame w)))))

(defun drgnx-chrome--close-clicked (event)
  "Close the tab whose × was clicked."
  (interactive "e")
  (when-let* ((posn (event-start event)) (s (posn-string posn))
              (b (get-text-property (cdr s) 'drgnx-buffer (car s))) (w (posn-window posn)))
    (drgnx-chrome--close w b)))

(defvar drgnx-chrome--tab-map
  (let ((m (make-sparse-keymap)))
    (define-key m [tab-line mouse-1] #'drgnx-chrome--select-tab)
    (define-key m [tab-line mouse-2] #'drgnx-chrome--close-clicked)
    m))

(defvar drgnx-chrome--close-map
  (let ((m (make-sparse-keymap))) (define-key m [tab-line mouse-1] #'drgnx-chrome--close-clicked) m))

(defun drgnx-chrome--tab-line (w)
  (let ((shown (window-buffer w)))
    (mapconcat (lambda (b)
                 (let ((face (if (eq b shown) 'drgnx-chrome-tab-current 'drgnx-chrome-tab)))
                   (concat (propertize (format " %s%s " (drgnx-wb-display-name (buffer-name b))
                                               (if (and (buffer-file-name b) (buffer-modified-p b)) " ●" ""))
                                       'face face 'drgnx-buffer b 'local-map drgnx-chrome--tab-map
                                       'mouse-face 'highlight 'help-echo "Show; middle-click closes")
                           (propertize "× " 'face face 'drgnx-buffer b 'local-map drgnx-chrome--close-map
                                       'mouse-face 'highlight 'help-echo "Close this tab"))))
               (drgnx-chrome-tabs w) "")))

(defun drgnx-chrome--close (w b)
  "Take B out of W's tabs; if W shows it, show the tab to its right, else its left, else *scratch*."
  (let* ((tabs (drgnx-chrome-tabs w)) (rest (cdr (memq b tabs))) (before (seq-take-while (lambda (x) (not (eq x b))) tabs)))
    (set-window-parameter w 'drgnx-tabs (remq b tabs))
    (set-window-parameter w 'drgnx-closed (cons b (seq-filter #'buffer-live-p (window-parameter w 'drgnx-closed))))
    (set-window-prev-buffers w (assq-delete-all b (copy-sequence (window-prev-buffers w))))
    (when (eq (window-buffer w) b)
      (set-window-buffer w (or (car rest) (car (last before)) (get-scratch-buffer-create))))
    (drgnx-chrome-apply (window-frame w))))

(defun drgnx-chrome-close-tab ()
  "Close the shown tab (the buffer stays open; Close in the Buffers panel closes it)."
  (interactive)
  (drgnx-chrome--close (selected-window) (window-buffer)))

(defun drgnx-chrome--step (n)
  (let* ((tabs (drgnx-chrome-tabs (selected-window))) (i (seq-position tabs (window-buffer))))
    (when (and tabs i)
      (set-window-buffer (selected-window) (nth (mod (+ i n) (length tabs)) tabs))
      (drgnx-chrome-apply))))

(defun drgnx-chrome-next-tab () "Show the next tab (wraps)." (interactive) (drgnx-chrome--step 1))
(defun drgnx-chrome-previous-tab () "Show the previous tab (wraps)." (interactive) (drgnx-chrome--step -1))

;;;; Breadcrumbs

(defun drgnx-chrome-breadcrumb (w)
  "W's breadcrumb: project › folders › file (● when unsaved), or the buffer's name."
  (let* ((b (window-buffer w)) (file (buffer-file-name b)))
    (concat
     " "
     (if (not file)
         (drgnx-wb-display-name (buffer-name b))
       (let* ((root (with-current-buffer b
                      (when-let* ((p (and (not (file-remote-p file)) (project-current)))) (project-root p))))
              (rel (if root (file-relative-name file root) (abbreviate-file-name file)))
              (parts (split-string rel "/" t)))
         (concat (if root (propertize (concat (file-name-nondirectory (directory-file-name root)) " › ")
                                      'face 'drgnx-chrome-crumb)
                   "")
                 (propertize (mapconcat #'identity (butlast parts) " › ") 'face 'drgnx-chrome-crumb)
                 (if (cdr parts) " › " "")
                 (drgnx-wb-display-name (car (last parts))))))
     (if (and file (buffer-modified-p b)) " ●" ""))))

;;;; Applying

(defconst drgnx-chrome--mode-line '(:eval (or mode-line-format (default-value 'mode-line-format)))
  "An editor window's mode line: its buffer's, or the default when the buffer has none.")

(defun drgnx-chrome--apply-window (w)
  (pcase (drgnx-chrome--role w)
    ('editor
     (drgnx-chrome--note w)
     (set-window-parameter w 'tab-line-format (let ((s (drgnx-chrome--tab-line w))) (if (equal s "") " " s)))
     (set-window-parameter w 'header-line-format (drgnx-chrome-breadcrumb w))
     (set-window-parameter w 'mode-line-format drgnx-chrome--mode-line))
    ((or 'dock 'area)
     (set-window-parameter w 'tab-line-format 'none)
     (set-window-parameter w 'mode-line-format 'none))
    ('lane
     (dolist (p '(tab-line-format mode-line-format)) (set-window-parameter w p 'none)))))

(defun drgnx-chrome-apply (&optional frame)
  "Set every window's chrome on FRAME (default: the selected one) by its role."
  (dolist (w (window-list frame 'nomini)) (drgnx-chrome--apply-window w)))

(defun drgnx-chrome--refresh (&rest _)
  "On a bus edge: tabs and breadcrumbs of every frame."
  (dolist (f (frame-list)) (drgnx-chrome-apply f)))

(define-minor-mode drgnx-chrome-mode
  "Chrome by role: tab lines and breadcrumbs in editor windows, titles only elsewhere."
  :global t :group 'drgnx
  (if drgnx-chrome-mode
      (progn
        (add-hook 'drgnx-signal-window-functions #'drgnx-chrome-apply)
        (dolist (e '(editor-changed buffer-set-changed modified-changed))
          (drgnx-signal-subscribe e #'drgnx-chrome--refresh))
        (drgnx-chrome--refresh))
    (remove-hook 'drgnx-signal-window-functions #'drgnx-chrome-apply)
    (dolist (e '(editor-changed buffer-set-changed modified-changed))
      (drgnx-signal-unsubscribe e #'drgnx-chrome--refresh))
    (dolist (f (frame-list))
      (dolist (w (window-list f 'nomini))
        (pcase (drgnx-chrome--role w)
          ('editor (dolist (p '(tab-line-format header-line-format mode-line-format)) (set-window-parameter w p nil)))
          ((or 'dock 'area 'lane) (dolist (p '(tab-line-format mode-line-format)) (set-window-parameter w p nil))))))))

(provide 'drgnx-chrome)
;;; drgnx-chrome.el ends here
