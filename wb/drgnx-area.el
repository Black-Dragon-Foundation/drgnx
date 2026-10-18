;;; drgnx-area.el --- Tabbed areas: the bottom panel and the right dock -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; An area is one side window whose buffer is swapped in place: the bottom **panel** (tabs
;; Terminal, Problems, Output, Results, Help) and the **right dock** (agents, chat, … — tabs come
;; with their modules).  Showing a tab never selects the area, keeps the window (so nothing
;; around it moves) and puts back the tab's buffer, start and point as they were left.  The tab
;; row lives in the `header-line-format' window parameter, so no mode can erase it; the area's
;; pixel size is kept across hiding and showing.  Killing the buffer an area shows puts the tab's
;; placeholder there — another buffer never slips into the area.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-rules)
(require 'tab-line)                     ; the tab faces we inherit

(defface drgnx-wb-tab '((t :inherit tab-line-tab-inactive)) "A tab in an area's tab row." :group 'drgnx)
(defface drgnx-wb-tab-current '((t :inherit tab-line-tab-current)) "The shown tab in an area's tab row." :group 'drgnx)

(defvar drgnx-wb--areas nil "Alist AREA → plist (:side SIDE :size N :tabs ((TAB . PLIST) …)).")

(cl-defun drgnx-wb-define-area (area &key side size)
  "Define AREA on SIDE (`bottom' or `right'), SIZE lines or columns the first time it shows."
  (setf (alist-get area drgnx-wb--areas)
        (list :side side :size size :tabs (plist-get (alist-get area drgnx-wb--areas) :tabs)))
  area)

(cl-defun drgnx-wb-define-tab (area tab &key title placeholder)
  "Add TAB to AREA, titled TITLE; PLACEHOLDER returns the buffer shown while the tab has none."
  (let* ((spec (alist-get area drgnx-wb--areas)) (tabs (copy-alist (plist-get spec :tabs)))
         (props (list :title (or title (capitalize (symbol-name tab))) :placeholder placeholder)))
    (if (assq tab tabs) (setf (alist-get tab tabs) props)
      (setq tabs (append tabs (list (cons tab props)))))         ; in the order they are defined
    (setf (alist-get area drgnx-wb--areas) (plist-put spec :tabs tabs))
    tab))

(defun drgnx-wb-area-window (area &optional frame)
  "The window showing AREA on FRAME, or nil."
  (seq-find (lambda (w) (eq (window-parameter w 'drgnx-role) area)) (window-list frame 'nomini)))

;;;; Per-frame state: the shown tab, and each tab's buffer, start and point

(defun drgnx-area--state (area)
  (alist-get area (frame-parameter nil 'drgnx-wb-areas)))

(defun drgnx-area--set-state (area state)
  (let ((all (copy-alist (frame-parameter nil 'drgnx-wb-areas))))
    (setf (alist-get area all) state)
    (set-frame-parameter nil 'drgnx-wb-areas all)))

(defun drgnx-wb-area-tab (area)
  "The tab AREA shows (or showed last), or its first tab."
  (or (plist-get (drgnx-area--state area) :tab)
      (car (car (plist-get (alist-get area drgnx-wb--areas) :tabs)))))

(defun drgnx-area--remember (area window)
  "Remember the buffer, start and point WINDOW shows, for AREA's shown tab."
  (when (window-live-p window)
    (let* ((state (drgnx-area--state area)) (tabs (copy-alist (plist-get state :tabs))))
      (setf (alist-get (drgnx-wb-area-tab area) tabs)
            (list (window-buffer window) (window-start window) (window-point window)))
      (drgnx-area--set-state area (plist-put (copy-sequence state) :tabs tabs)))))

(defun drgnx-area--placeholder (area tab)
  (let ((fn (plist-get (alist-get tab (plist-get (alist-get area drgnx-wb--areas) :tabs)) :placeholder)))
    (if fn (funcall fn)
      (or (get-buffer (format " *drgnx %s*" (or tab area)))
          (with-current-buffer (get-buffer-create (format " *drgnx %s*" (or tab area)) t)
            (special-mode)
            (current-buffer))))))

;;;; The tab row

(defun drgnx-area--tab-click (event)
  "Show the tab clicked in an area's tab row."
  (interactive "e")
  (let* ((posn (event-start event)) (s (posn-string posn)))
    (when-let* ((s) (spec (get-text-property (cdr s) 'drgnx-tab (car s))))
      (drgnx-wb-area-show (car spec) (cdr spec)))))

(defvar drgnx-area--tab-map
  (let ((m (make-sparse-keymap))) (define-key m [header-line mouse-1] #'drgnx-area--tab-click) m))

(defun drgnx-area--tab-row (area)
  (let ((shown (drgnx-wb-area-tab area)))
    (mapconcat (lambda (tab)
                 (propertize (format " %s " (plist-get (cdr tab) :title))
                             'face (if (eq (car tab) shown) 'drgnx-wb-tab-current 'drgnx-wb-tab)
                             'drgnx-tab (cons area (car tab)) 'mouse-face 'highlight
                             'local-map drgnx-area--tab-map 'help-echo "Show this tab"))
               (plist-get (alist-get area drgnx-wb--areas) :tabs) " ")))

;;;; Show, hide

(defun drgnx-area--px-param (area) (intern (format "drgnx-wb-%s-px" area)))

(defun drgnx-area--horizontal-p (area) (memq (plist-get (alist-get area drgnx-wb--areas) :side) '(left right)))

(defun drgnx-area--create (area buffer)
  (let* ((spec (alist-get area drgnx-wb--areas)) (side (plist-get spec :side))
         (horizontal (drgnx-area--horizontal-p area))
         (w (let ((drgnx-rules--placing t))           ; ours: not redirected by the rules
              (display-buffer-in-side-window
               buffer `((side . ,side) (slot . 0)
                        (,(if horizontal 'window-width 'window-height) . ,(plist-get spec :size))
                        (dedicated . drgnx)
                        (window-parameters . ((drgnx-role . ,area) (no-delete-other-windows . t)
                                              (no-other-window . t)
                                              (delete-window . drgnx-area--delete-window))))))))
    (when-let* ((px (frame-parameter nil (drgnx-area--px-param area))))
      (let ((window-resize-pixelwise t))             ; or the size is rounded to whole lines
        (ignore-errors (window-resize w (- px (if horizontal (window-pixel-width w) (window-pixel-height w)))
                                      horizontal nil t))))
    (set-window-parameter w 'quit-restore nil)  ; `q' there must not go back to the window of its birth
    (window-preserve-size w horizontal t)
    (set-window-scroll-bars w nil nil nil nil t)
    w))

(declare-function drgnx-popup--end "drgnx-popup")

(defun drgnx-area--end-popup (w)
  "A popup borrowing W ends before the area changes (the tab must not remember the popup)."
  (when (and w (window-parameter w 'drgnx-popup)) (drgnx-popup--end w)))

(defun drgnx-wb-set-area-buffer (window buffer)
  "Show BUFFER in the area or lane WINDOW, which stays dedicated (`set-window-buffer' would undo it)."
  (unless (eq (window-buffer window) buffer) (set-window-buffer window buffer))
  (set-window-dedicated-p window 'drgnx))

(defun drgnx-wb-area-show (area &optional tab buffer)
  "Show AREA's TAB (default: the shown one) with BUFFER (default: the tab's last); never select it.
Returns the window — the same one across tab switches."
  (drgnx-area--end-popup (drgnx-wb-area-window area))
  (let* ((w (drgnx-wb-area-window area)) (tab (or tab (drgnx-wb-area-tab area))))
    (when w (drgnx-area--remember area w))
    (let* ((saved (alist-get tab (plist-get (drgnx-area--state area) :tabs)))
           (buffer (or buffer (and (buffer-live-p (car saved)) (car saved)) (drgnx-area--placeholder area tab))))
      (if w (drgnx-wb-set-area-buffer w buffer)
        (setq w (drgnx-area--create area buffer)))
      (when (eq (car saved) buffer)
        (set-window-start w (nth 1 saved) t)
        (set-window-point w (nth 2 saved)))
      (drgnx-area--set-state area (plist-put (copy-sequence (drgnx-area--state area)) :tab tab))
      (set-window-parameter w 'header-line-format (drgnx-area--tab-row area))
      (with-current-buffer buffer (add-hook 'kill-buffer-hook #'drgnx-area--killed nil t))
      w)))

(defun drgnx-area--killed ()
  "The current buffer is being killed: areas showing it show their tab's placeholder instead."
  (let ((dying (current-buffer)))
    (dolist (f (frame-list))
      (dolist (w (window-list f 'nomini))
        (when-let* ((area (window-parameter w 'drgnx-role))
                    ((alist-get area drgnx-wb--areas))
                    ((eq (window-buffer w) dying)))
          (with-selected-frame f
            (let ((tab (drgnx-wb-area-tab area)))
              (drgnx-wb-set-area-buffer w (drgnx-area--placeholder area tab))
              (drgnx-area--remember area w))))))))

(defun drgnx-wb-area-hide (area)
  "Hide AREA, remembering its pixel size and its tabs."
  (when-let* ((w (drgnx-wb-area-window area)))
    (drgnx-area--end-popup w)
    (drgnx-area--remember area w)
    (set-frame-parameter nil (drgnx-area--px-param area)
                         (if (drgnx-area--horizontal-p area) (window-pixel-width w) (window-pixel-height w)))
    (when (eq (selected-window) w) (drgnx-wb-focus-editor))
    (set-window-parameter w 'delete-window nil)
    (delete-window w)))

(defun drgnx-area--delete-window (window)
  "`delete-window' on an area's window (C-x 0, or a package deleting a window it once had): hide the
area, so its size and tabs are kept."
  (with-selected-frame (window-frame window)     ; the frame it is on, not the selected one
    (drgnx-wb-area-hide (window-parameter window 'drgnx-role))))

(defun drgnx-wb-area-toggle (area)
  "Show or hide AREA."
  (if (drgnx-wb-area-window area) (drgnx-wb-area-hide area) (drgnx-wb-area-show area)))

(defun drgnx-wb-area-focus (area)
  "Show AREA and move focus to it."
  (select-window (drgnx-wb-area-show area)))

(defun drgnx-wb-toggle-panel () "Show or hide the bottom panel." (interactive) (drgnx-wb-area-toggle 'panel))
(defun drgnx-wb-focus-panel () "Show the bottom panel and move focus to it." (interactive) (drgnx-wb-area-focus 'panel))
(defun drgnx-wb-toggle-right-dock () "Show or hide the right dock." (interactive) (drgnx-wb-area-toggle 'right))

;;;; Places and the default areas

(defun drgnx-area--place (area)
  (lambda (buffer alist props)
    (let ((w (drgnx-wb-area-show area (plist-get props :tab) buffer)))
      (drgnx-wb-run-body-function w alist)
      w)))

(drgnx-wb-define-place 'panel (drgnx-area--place 'panel))
(drgnx-wb-define-place 'right (drgnx-area--place 'right))

(drgnx-wb-define-area 'panel :side 'bottom :size 12)
(drgnx-wb-define-area 'right :side 'right :size 50)
(dolist (tab '(problems output results terminal help)) (drgnx-wb-define-tab 'panel tab))

(pcase-dolist (`(,matcher ,tab)
               '(((help-mode apropos-mode Info-mode Man-mode shortdoc-mode finder-mode) help)
                 ("\\`\\*\\(Help\\|info\\|eldoc.*\\|Apropos\\|Shortdoc .*\\|Finder.*\\|Holidays\\)\\*\\'" help)
                 ((compilation-mode occur-mode xref--xref-buffer-mode) results)
                 ((flymake-diagnostics-buffer-mode flymake-project-diagnostics-mode) problems)
                 ("\\`\\*Flycheck errors\\*\\'" problems)
                 ((messages-buffer-mode debugger-mode ert-results-mode process-menu-mode timer-list-mode) output)
                 ("\\`\\*\\(Warnings\\|Backtrace\\|Messages\\|timer-list\\|Process List\\)\\*\\'" output)
                 ((shell-mode eshell-mode eat-mode term-mode vterm-mode inferior-emacs-lisp-mode comint-mode) terminal)
                 ;; shell, eshell and eat show their buffer before setting its mode.
                 ("\\`\\*\\(shell\\|eshell\\|eat\\|ielm\\|terminal\\|ansi-term\\|vterm\\)\\*\\(<[0-9]+>\\)?\\'" terminal)))
  (drgnx-wb-place matcher 'panel :tab tab))

(provide 'drgnx-area)
;;; drgnx-area.el ends here
