;;; drgnx-kit-catalogue.el --- Design: Component Catalogue: every kit component, every variant and state -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The kit's components (etc/ui/components.eld) drawn as the user's drgnx draws them: one section per component, a
;; cell per variant and state.  A component the hub expands (the row) is drawn as a hub row: `drgnx-ui-kit-expand'
;; then the inserter's dress (`drgnx-view-patch--dress'), as a hub-fed view would; a Lisp chrome component through
;; `drgnx-ui-kit-string'.  Each cell carries `drgnx-kit-cell' = (ID VARIANTS STATE), which the screenshot sheets read
;; (`drgnx-kit-catalogue-cells', test/ui/kit-sheets-gui-test.el).  The command is ui/look's
;; (`design-component-catalogue').  See docs/develop/design-system.md ("The catalogue and the sheets").

;;; Code:
(require 'cl-lib)
(require 'drgnx-ui-kit)
(require 'drgnx-pixels)
(require 'drgnx-view)

(defvar drgnx-look-density)

(defconst drgnx-kit-catalogue-buffer "*drgnx: Components*" "The catalogue's buffer.")

(defconst drgnx-kit-catalogue--stateless '(card)
  "The components with no states (a card's ring is its kind's): their cells are the rest state alone.")

(defconst drgnx-kit-catalogue--hub '(row button key-hint section-header card)
  "The components the hub expands: their cells are drawn as hub rows.")

(defun drgnx-kit-catalogue--props (id variants state)
  "The props of a cell of component ID with VARIANTS ((AXIS . VALUE)...) in STATE: as a hub `Comp' plist."
  (pcase id
    ('row (let ((kind (alist-get 'kind variants)))
            (list :c "row" :kind (symbol-name kind) :depth (if (eq kind 'tree) 1 0)
                  :twisty (and (eq kind 'tree) :false)
                  :icon (pcase kind ('tree "folder") ('list "file"))   ; the icon slot (a map row has none)
                  :text (format "%s · %s" kind state)
                  :state (symbol-name state))))
    ('button (list :c "button" :label "Button" :style (symbol-name (alist-get 'style variants))
                   :size (symbol-name (alist-get 'size variants)) :state (symbol-name state)))
    ('section-header (list :c "section-header" :title "Section" :count 3 :state (symbol-name state)
                           :collapsible (if (eq (alist-get 'collapsible variants) 'yes) t :false)))
    ('card (list :c "card" :kind (symbol-name (alist-get 'kind variants)) :shape (symbol-name (alist-get 'shape variants))
                 :text "Card" :state (symbol-name state)))
    ('key-hint (list :c "key-hint" :keys "C-k" :variant (symbol-name (alist-get 'variant variants))
                     :state (symbol-name state)))
    (_ (list :c (symbol-name id) :text (format "%s · %s" id state) :state (symbol-name state)))))

(defun drgnx-kit-catalogue--hub-row (id props scale tty state)
  "PROPS expanded at SCALE (TTY on a terminal) and dressed as the inserter dresses a hub row, in STATE (a patch
state); the cell's text, its line's height in device px (the expansion's :height) as `drgnx-kit-line-height'."
  (let* ((e (let ((drgnx-ui-kit--icons (and (not tty) (drgnx-ui-kit-icon-function nil))))
              (drgnx-ui-kit-expand id props scale tty)))
         (props (mapcar (lambda (p) (let ((l (append p nil))) (if (vectorp (nth 3 l)) (append (butlast l) (list (append (nth 3 l) nil))) l)))
                        (plist-get e :props)))
         ;; an icon (a `display' image of the Lisp expansion) goes as the hub sends it: an image of the row, its spec
         ;; in the state's table under its own id
         (images (delq nil (mapcar (lambda (p)
                                     (when (equal (nth 2 p) "display")
                                       (let ((id (format "kit-icon-%x" (sxhash-equal (nth 3 p)))))
                                         (puthash id (nth 3 p) (drgnx-view-patch-images state))
                                         (list (nth 0 p) id " "))))
                                   props)))
         (row (list :text (plist-get e :text)
                    :runs (mapcar (lambda (r) (append r nil)) (plist-get e :runs))
                    :props (seq-remove (lambda (p) (equal (nth 2 p) "display")) props)
                    :spaces (mapcar (lambda (s) (append s nil)) (plist-get e :spaces))
                    :images images)))
    (propertize (drgnx-view-patch--dress state "kit" row (copy-sequence (plist-get e :text)))
                'drgnx-kit-line-height (plist-get (plist-get e :height) :unit))))

(defun drgnx-kit-catalogue--cell (id variants state scale tty patch)
  "One cell's text: component ID with VARIANTS in STATE."
  (let* ((props (drgnx-kit-catalogue--props id variants state))
         (s (if (memq id drgnx-kit-catalogue--hub)
                (drgnx-kit-catalogue--hub-row id props scale tty patch)
              (drgnx-ui-kit-string id props 'text nil))))
    (put-text-property 0 (length s) 'drgnx-kit-cell (list id (mapcar #'cdr variants) state) s)
    s))

(defun drgnx-kit-catalogue--combos (entry)
  "Every combination of ENTRY's variant axes, as ((AXIS . VALUE)...), the last axis fastest; (nil) for none."
  (let ((out '(nil)))
    (dolist (axis (reverse (plist-get entry :variants)) out)
      (setq out (cl-loop for v in (cdr axis) append (mapcar (lambda (rest) (cons (cons (car axis) v) rest)) out))))))

(defun drgnx-kit-catalogue-insert (&optional component scale)
  "Insert the catalogue of COMPONENT (default every one) at point, at SCALE (default the frame's)."
  (let* ((frame (selected-frame)) (gui (display-graphic-p frame))
         (scale (or scale (if gui (drgnx-pixels-scale frame) 1.0)))
         (tty (cond (gui nil) ((drgnx-ui-ascii-frame-p frame) 'ascii) (t t)))
         (patch (drgnx-view-patch--make :view "kit-catalogue" :class "kit" :epoch 1)))
    (dolist (c (alist-get 'components (drgnx-ui-kit-components)))
      (when (or (null component) (eq component (car c)))
        (insert (propertize (format "%s\n" (car c)) 'face 'drgnx-ui-heading) "\n")
        (dolist (variants (drgnx-kit-catalogue--combos (cdr c)))
          (when variants
            (insert (propertize (mapconcat (lambda (v) (format "%s %s" (car v) (cdr v))) variants ", ")
                                'face 'drgnx-text-muted)
                    "\n"))
          (dolist (state (if (memq (car c) drgnx-kit-catalogue--stateless) '(rest) drgnx-ui-kit-states))
            (let ((s (drgnx-kit-catalogue--cell (car c) variants state scale tty patch)))
              ;; a hub row's newline carries its height, as the inserter's render puts it
              (insert s (propertize "\n" 'line-height (get-text-property 0 'drgnx-kit-line-height s)))))
          (insert "\n"))))))

(defun drgnx-kit-catalogue-open (&optional component theme density scale)
  "Open the component catalogue: COMPONENT (a symbol, default every one) in THEME (a theme to load first; default the
one on), at DENSITY (default the user's) and SCALE (default the frame's).  Returns the buffer."
  (interactive)
  (when theme
    (unless (memq theme custom-enabled-themes)
      (mapc #'disable-theme custom-enabled-themes)
      (load-theme theme t)))
  (let ((buf (get-buffer-create drgnx-kit-catalogue-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t) (drgnx-look-density (or density (bound-and-true-p drgnx-look-density) 'comfortable)))
        (buffer-disable-undo)
        (erase-buffer)
        (drgnx-kit-catalogue-insert component scale)
        (goto-char (point-min))
        (setq buffer-read-only t)))
    (when (called-interactively-p 'any) (pop-to-buffer buf))
    buf))

(defun drgnx-kit-catalogue-cells ()
  "The cells of the current catalogue buffer: ((ID VARIANTS STATE BEG END)...), in order."
  (let ((pos (point-min)) out)
    (while (setq pos (text-property-not-all pos (point-max) 'drgnx-kit-cell nil))
      (let ((end (or (next-single-property-change pos 'drgnx-kit-cell) (point-max)))
            (cell (get-text-property pos 'drgnx-kit-cell)))
        (push (append cell (list pos end)) out)
        (setq pos end)))
    (nreverse out)))

(provide 'drgnx-kit-catalogue)
;;; drgnx-kit-catalogue.el ends here
