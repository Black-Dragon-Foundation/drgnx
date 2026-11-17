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

(defconst drgnx-kit-catalogue--stateless '(agent-mark progress card range-bar)
  "The components that show no state (nothing to hover or select): drawn at rest only.")

(defconst drgnx-kit-catalogue--hub '(row button key-hint agent-mark progress section-header card chip status-dot range-bar)
  "The components the hub expands: their cells are drawn as hub rows.")

(defconst drgnx-kit-catalogue--meters
  (cl-loop for size in '(row card wide)
           append (cl-loop for (state spent limit forecast text unit)
                           in '((ok 10 40 [20 30] "$10 / $40" "usd") (nearing 36 40 [39 44] "$36 / $40" "usd")
                                (reached 40 40 nil "$40 / $40" "usd") (over 43 40 nil "$43 / $40" "usd")
                                (forecast-over 20 40 [34 52] "$20 / $40" "usd") (none 12 nil nil "$12" "usd")
                                (inherited 4 9 nil "$4 · of plan's $9 left" "usd")
                                (unpriced 12000 nil nil "12k tokens" "tokens"))
                           collect (cons (intern (format "%s-%s" size state))
                                         (list :c "meter" :spent spent :limit limit :unit unit :forecast forecast
                                               :state (symbol-name state) :size (symbol-name size)
                                               :width (pcase size ('card 160) ('wide 240) (_ 0)) :text text))))
  "The meter's cells, each state at each size: (SIZE-STATE . PROPS), the hub's `Comp::Meter' plist.")

(defun drgnx-kit-catalogue--props (id variants state)
  "The props of a cell of component ID with VARIANTS ((AXIS . VALUE)...) in STATE (a meter's: SIZE-STATE): as a hub
`Comp' plist."
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
    ('agent-mark (list :c "agent-mark" :slot 2 :handle "Co"))
    ('progress (if (eq (alist-get 'kind variants) 'meter)
                   (alist-get state drgnx-kit-catalogue--meters)
                 (list :c "progress" :kind (symbol-name (alist-get 'kind variants)) :value 0.6 :width 120)))
    ('chip (let ((tone (alist-get 'tone variants)))
             (list :c "chip" :label (format "%s" tone) :tone (if (eq tone 'agent) (list :agent 3) (symbol-name tone))
                   :fill (symbol-name (alist-get 'fill variants)) :state (symbol-name state))))
    ('range-bar (pcase (alist-get 'variant variants)
                  ('schedule (list :c "range-bar" :variant "schedule" :from 0 :to 100 :width 160 :state "on-track"
                                   :label "build: on track"
                                   :spans (list :done_to 40 :p50 60 :p90 80 :baseline 30 :target 90)))
                  ('cost (list :c "range-bar" :variant "cost" :from 0 :to 100 :width 160 :state "on-track"
                               :spans (list :p50 40 :p90 70 :limit 90)))
                  (_ (list :c "range-bar" :variant (list :segment "edit") :from 0 :to 10 :width 120 :state "on-track"))))
    ('status-dot (list :c "status-dot" :status (symbol-name (alist-get 'status variants)) :word t))
    (_ (list :c (symbol-name id) :text (format "%s · %s" id state) :state (symbol-name state)))))

(defun drgnx-kit-catalogue--hub-row (_id props scale tty state)
  "PROPS (its component the one its :c names) expanded at SCALE (TTY on a terminal) and dressed as the inserter
dresses a hub row, in STATE (a patch state); the cell's text, its line's height in device px (the expansion's
:height) as `drgnx-kit-line-height'."
  (let* ((e (let ((drgnx-ui-kit--icons (and (not tty) (drgnx-ui-kit-icon-function nil))))
              (drgnx-ui-kit-expand (intern (plist-get props :c)) props scale tty)))
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
    ;; progress beside its caption, as it is used: the bar and the ring on the caption's centre line (a meter has its
    ;; text)
    (if (and (eq id 'progress) (not tty) (not (eq (alist-get 'kind variants) 'meter)))
        (concat s (propertize " " 'display `(space :width (,(drgnx-px 12 nil scale))))
                (propertize (get-text-property 0 'help-echo s) 'face 'drgnx-ui-caption))
      s)))

(defun drgnx-kit-catalogue--combos (entry)
  "Every combination of ENTRY's variant axes, as ((AXIS . VALUE)...), the last axis fastest; (nil) for none."
  (let ((out '(nil)))
    (dolist (axis (reverse (plist-get entry :variants)) out)
      (setq out (cl-loop for v in (cdr axis) append (mapcar (lambda (rest) (cons (cons (car axis) v) rest)) out))))))

(defun drgnx-kit-catalogue--shown-p (component id variants)
  "Non-nil when the catalogue of COMPONENT (nil: every one) shows ID's cells of VARIANTS: `meter' is progress's kind
`meter' alone, `progress' its other kinds."
  (let ((meter (and (eq id 'progress) (eq (alist-get 'kind variants) 'meter))))
    (pcase component
      ('nil t)
      ('meter meter)
      (_ (and (eq component id) (not meter))))))

(defun drgnx-kit-catalogue-insert (&optional component scale)
  "Insert the catalogue of COMPONENT (default every one; `meter': progress's meters) at point, at SCALE (default the
frame's)."
  (let* ((frame (selected-frame)) (gui (display-graphic-p frame))
         (scale (or scale (if gui (drgnx-pixels-scale frame) 1.0)))
         (tty (cond (gui nil) ((drgnx-ui-ascii-frame-p frame) 'ascii) (t t)))
         (patch (drgnx-view-patch--make :view "kit-catalogue" :class "kit" :epoch 1)))
    (dolist (c (alist-get 'components (drgnx-ui-kit-components)))
      (when (and (not (and (plist-member (cdr c) :sheet) (null (plist-get (cdr c) :sheet))))   ; hub-only: no cells
                 (or (null component) (eq component (car c)) (and (eq component 'meter) (eq (car c) 'progress))))
        (insert (propertize (format "%s\n" (car c)) 'face 'drgnx-ui-heading) "\n")
        (dolist (variants (drgnx-kit-catalogue--combos (cdr c)))
          (when (drgnx-kit-catalogue--shown-p component (car c) variants)
            (when variants
              (insert (propertize (mapconcat (lambda (v) (format "%s %s" (car v) (cdr v))) variants ", ")
                                  'face 'drgnx-text-muted)
                      "\n"))
            (dolist (state (cond ((and (eq (car c) 'progress) (eq (alist-get 'kind variants) 'meter))
                                  (mapcar #'car drgnx-kit-catalogue--meters))
                                 ((memq (car c) drgnx-kit-catalogue--stateless) '(rest))
                                 (t drgnx-ui-kit-states)))
              (let ((s (drgnx-kit-catalogue--cell (car c) variants state scale tty patch)))
                ;; a hub row's newline carries its height, as the inserter's render puts it
                (insert s (propertize "\n" 'line-height (get-text-property 0 'drgnx-kit-line-height s)))))
            (insert "\n")))))))

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
