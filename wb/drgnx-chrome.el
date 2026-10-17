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
;; bus's window setup); tabs and breadcrumbs follow the bus's edges.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'project)
(require 'tab-line)                     ; the tab faces we inherit
(require 'drgnx-area)

(defface drgnx-chrome-tab '((t :inherit tab-line-tab-inactive)) "A tab in an editor's tab line." :group 'drgnx)
(defface drgnx-chrome-tab-current '((t :inherit tab-line-tab-current)) "The shown tab." :group 'drgnx)
(defface drgnx-chrome-crumb '((t :inherit shadow)) "The folders of a breadcrumb." :group 'drgnx)

(defun drgnx-chrome--role (w)
  "W's chrome role: `editor', `dock', `area', `lane', or nil (left alone)."
  (let ((role (window-parameter w 'drgnx-role)))
    (cond ((window-minibuffer-p w) nil)
          ((frame-parent (window-frame w)) nil)   ; child frames: posframe, corfu, eldoc-box keep theirs
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
  "Add W's buffer to its tabs (at the end; never reordered); drop transient tabs not shown.
Called on the bus's edges and by commands — never while drawing, so a buffer shown for a moment
(a preview) does not become a tab."
  (let* ((b (window-buffer w)) (before (drgnx-chrome-tabs w))
         (after (let ((tabs (seq-remove (lambda (x) (and (not (eq x b)) (string-match-p drgnx-chrome-transient-tabs (buffer-name x))))
                                        before)))
                  (if (and (drgnx-chrome--tab-buffer-p b) (not (memq b tabs))) (append tabs (list b)) tabs))))
    (unless (equal before after)
      (set-window-parameter w 'drgnx-tabs after)
      (drgnx-signal-post 'tabs-changed))))

(defun drgnx-chrome--text (s)
  "S shown as is in a tab or header line (% would be a format directive)."
  (string-replace "%" "%%" (drgnx-wb-display-name s)))

(defun drgnx-chrome--select-tab (event)
  "Show the tab clicked in a tab line."
  (interactive "e")
  (when-let* ((posn (event-start event)) (s (posn-string posn))
              (b (get-text-property (cdr s) 'drgnx-buffer (car s))) (w (posn-window posn)))
    (when (buffer-live-p b) (set-window-buffer w b) (drgnx-chrome-apply (window-frame w) t))))

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
                   (concat (propertize (format " %s%s " (drgnx-chrome--text (buffer-name b))
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
    (drgnx-signal-post 'tabs-changed)
    (when (eq (window-buffer w) b)
      (set-window-buffer w (or (car rest) (car (last before)) (get-scratch-buffer-create))))
    (drgnx-chrome-apply (window-frame w) t)))

(defun drgnx-chrome-close-tab ()
  "Close the shown tab (the buffer stays open; Close in the Buffers panel closes it)."
  (interactive)
  (drgnx-chrome--close (selected-window) (window-buffer)))

(defun drgnx-chrome--step (n)
  (let* ((tabs (drgnx-chrome-tabs (selected-window))) (i (seq-position tabs (window-buffer))))
    (when (and tabs i)
      (set-window-buffer (selected-window) (nth (mod (+ i n) (length tabs)) tabs))
      (drgnx-chrome-apply nil t))))

(defun drgnx-chrome-next-tab () "Show the next tab (wraps)." (interactive) (drgnx-chrome--step 1))
(defun drgnx-chrome-previous-tab () "Show the previous tab (wraps)." (interactive) (drgnx-chrome--step -1))

;;;; Breadcrumbs

(defvar-local drgnx-chrome--root nil "(DEFAULT-DIRECTORY . PROJECT-ROOT-or-nil), looked up once.")

(defun drgnx-chrome--project-root (file)
  "The project root of the current buffer (FILE), cached: outside a repository the lookup walks the tree."
  (unless (equal (car drgnx-chrome--root) default-directory)
    (setq drgnx-chrome--root
          (cons default-directory
                (unless (file-remote-p file)
                  (when-let* ((p (let ((non-essential t)) (project-current)))) (project-root p))))))
  (cdr drgnx-chrome--root))

(defun drgnx-chrome-breadcrumb (w)
  "W's breadcrumb: project › folders › file (● when unsaved), or the buffer's name."
  (let* ((b (window-buffer w)) (file (buffer-file-name b)))
    (concat
     " "
     (if (not file)
         (drgnx-chrome--text (buffer-name b))
       (let* ((root (with-current-buffer b (drgnx-chrome--project-root file)))
              (rel (if root (file-relative-name file root) (abbreviate-file-name file)))
              (parts (split-string rel "/" t)))
         (concat (if root (propertize (concat (drgnx-chrome--text (file-name-nondirectory (directory-file-name root))) " › ")
                                      'face 'drgnx-chrome-crumb)
                   "")
                 (propertize (mapconcat #'drgnx-chrome--text (butlast parts) " › ") 'face 'drgnx-chrome-crumb)
                 (if (cdr parts) " › " "")
                 (drgnx-chrome--text (car (last parts))))))
     (if (and file (buffer-modified-p b)) " ●" ""))))

;;;; Applying

(defconst drgnx-chrome--mode-line '(:eval (or mode-line-format (default-value 'mode-line-format)))
  "An editor window's mode line: its buffer's, or the default when the buffer has none.")

(defconst drgnx-chrome--own-header '(:eval header-line-format)
  "The header of a buffer that has its own (tabulated-list column headings, clicked to sort).")

(defun drgnx-chrome--set (w param value)
  "Set W's PARAM to VALUE only if it changed: setting a window parameter redraws the window."
  (unless (equal-including-properties (window-parameter w param) value)
    (set-window-parameter w param value)))

(defun drgnx-chrome--apply-window (w note)
  (pcase (drgnx-chrome--role w)
    ('editor
     (when note (drgnx-chrome--note w))
     (drgnx-chrome--set w 'tab-line-format (let ((s (drgnx-chrome--tab-line w))) (if (equal s "") " " s)))
     (drgnx-chrome--set w 'header-line-format
                        (with-current-buffer (window-buffer w)
                          (if (and (local-variable-p 'header-line-format) header-line-format)
                              drgnx-chrome--own-header
                            (drgnx-chrome-breadcrumb w))))
     (drgnx-chrome--set w 'mode-line-format drgnx-chrome--mode-line))
    ((or 'dock 'area)
     (drgnx-chrome--set w 'tab-line-format 'none)
     (drgnx-chrome--set w 'mode-line-format 'none))
    ('lane
     (dolist (p '(tab-line-format mode-line-format)) (drgnx-chrome--set w p 'none)))))

(defun drgnx-chrome-apply (&optional frame note)
  "Set every window's chrome on FRAME (default: the selected one) by its role; NOTE: also add the
shown buffers to their windows' tabs."
  (unless (frame-parent frame)
    (dolist (w (window-list frame 'nomini)) (drgnx-chrome--apply-window w note))))

(defun drgnx-chrome--refresh (&rest _)
  "On a bus edge: tabs and breadcrumbs of every frame (no new tabs while the minibuffer is active:
those are previews)."
  (let ((note (not (active-minibuffer-window))))
    (dolist (f (frame-list)) (drgnx-chrome-apply f note))))

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
