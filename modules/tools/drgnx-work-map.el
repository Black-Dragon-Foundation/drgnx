;;; drgnx-work-map.el --- The Work map's buffer: mode, view type and rows (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The map is one read-only buffer, `*drgnx work: NAME*', in `drgnx-work-map-mode': a `drgnx-view' whose rows are
;; the layout's sub-rows `(:row LAYER BLOCK-LINE SUB)' and the bands between them `(:band LAYER BLOCK-LINE SUB)', in
;; the order of their y.  A row's text is a function of the cached frame (core/drgnx-work-client.el).  The buffer's
;; view id is `drgnx-work-space--view'.  Keys come from the key profiles (keys/*.eld), never from this file.
;; Loaded by tools/work-space (drgnx-work-space.el); defines no module.  See docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-view)
(require 'drgnx-work-client)

(defvar-local drgnx-work-space--view nil
  "The id of the map view this buffer shows (`drgnx-work-client-open'), or nil for an empty map.")
(defvar-local drgnx-work-space--message nil
  "The text an empty map (no workspace) shows.")

(defvar drgnx-work-map-mode-map (make-sparse-keymap)
  "Keys of the map buffer.  The key profiles bind them (`drgnx-command-define' with this map).")

(define-derived-mode drgnx-work-map-mode special-mode "Work map"
  "The Work space's map: layers of asks, specs, plans, agents, branches and files, and the edges between them."
  (setq-local truncate-lines t cursor-type nil))

(defconst drgnx-work-map--layer-names
  ["You asked" "Specs" "Plans" "Agents" "Branches" "Files and machines"]
  "The six layers' labels, sentence case (the look).")

(defun drgnx-work-map-buffers ()
  "The live map buffers."
  (seq-filter (lambda (b) (eq (buffer-local-value 'major-mode b) 'drgnx-work-map-mode)) (buffer-list)))

(defun drgnx-work-map-buffer (view-id)
  "The map buffer showing view VIEW-ID, or nil."
  (seq-find (lambda (b) (equal (buffer-local-value 'drgnx-work-space--view b) view-id)) (drgnx-work-map-buffers)))

(defun drgnx-work-map--state (&optional buffer)
  "The client state of BUFFER's (default: the current) view, or nil."
  (when-let* ((id (buffer-local-value 'drgnx-work-space--view (or buffer (current-buffer)))))
    (drgnx-work-client-view-state id)))

;;;; Keys of the rows

(defvar drgnx-work-map--index (make-hash-table :test #'eq :weakness 'key)
  "Layout (the plist of a state's frame) → hash row key → the ids in that row, left to right.  Weak on the layout: a
new frame has a new layout, and the old index goes with it.")

(defun drgnx-work-map--row-key (r)
  (list :row (plist-get r :layer) (plist-get r :block_line) (plist-get r :sub)))

(defun drgnx-work-map--index-of (state)
  "STATE's row index (see `drgnx-work-map--index')."
  (let ((layout (drgnx-work-client-layout state)))
    (or (gethash layout drgnx-work-map--index)
        (let ((h (make-hash-table :test #'equal)))
          (dolist (id (drgnx-work-client-ids state))
            (dolist (key (drgnx-work-client-rows-of state id)) (push id (gethash key h))))
          (maphash (lambda (key ids)
                     (puthash key (sort ids (lambda (a b) (< (plist-get (drgnx-work-client-rect state a) :x)
                                                             (plist-get (drgnx-work-client-rect state b) :x))))
                              h))
                   h)
          (puthash layout h drgnx-work-map--index)))))

(defun drgnx-work-map--keys (state)
  "The row keys of STATE's layout in y order: each band above its row."
  (let* ((layout (drgnx-work-client-layout state))
         (rows (sort (copy-sequence (plist-get layout :rows)) (lambda (a b) (< (plist-get a :y) (plist-get b :y)))))
         (original (plist-get layout :rows)) out)
    (dolist (r rows)
      (let ((i (cl-position r original :test #'eq)))
        (when (seq-find (lambda (b) (eql (plist-get b :row) i)) (plist-get layout :bands))
          (push (cons :band (cdr (drgnx-work-map--row-key r))) out)))
      (push (drgnx-work-map--row-key r) out))
    (nreverse out)))

;;;; Rows

(defun drgnx-work-map--label (state id)
  (let ((it (drgnx-work-client-item state id)))
    (or (plist-get it :label) id)))

(defun drgnx-work-map--first-row-p (state key)
  "Whether KEY is the first row of its layer."
  (let ((layer (nth 1 key)))
    (equal key (seq-find (lambda (k) (and (eq (car k) :row) (eq (nth 1 k) layer))) (drgnx-work-map--keys state)))))

(defun drgnx-work-map--render (key)
  "The text of row KEY in the current buffer's map."
  (let ((state (drgnx-work-map--state)))
    (cond
     ((equal key '(:empty)) (concat (or drgnx-work-space--message "") "\n"))
     ((null state) "\n")
     ((eq (car key) :band) "\n")
     (t (let* ((ids (gethash key (drgnx-work-map--index-of state)))
               (label (if (drgnx-work-map--first-row-p state key)
                          (aref drgnx-work-map--layer-names (1- (nth 1 key)))
                        "")))
          (concat (format "%-20s" label)
                  (mapconcat (lambda (id) (drgnx-work-map--label state id)) ids " · ")
                  "\n"))))))

(defun drgnx-work-map--sig (key)
  "KEY's signature for `drgnx-view-sync-rows': the rows' items and rectangles themselves (`eq' tells a change)."
  (let ((state (drgnx-work-map--state)))
    (if (or (null state) (not (eq (car key) :row)))
        key
      (vconcat (list (plist-get (drgnx-work-client-layout state) :rows))
               (mapcar (lambda (id) (drgnx-work-client-item state id)) (gethash key (drgnx-work-map--index-of state)))))))

(defun drgnx-work-map--sync (view)
  "The view type's SYNC: the rows are the layout's."
  (let ((state (drgnx-work-map--state)))
    (drgnx-view-sync-rows view (if state (drgnx-work-map--keys state) '((:empty))) #'drgnx-work-map--sig)))

(drgnx-view-define 'work-map :render #'drgnx-work-map--render :sync #'drgnx-work-map--sync
                   :slice drgnx-view-slice)

;;;; Marks from the client

(defun drgnx-work-map--changed (view-id marks)
  "`drgnx-work-client-change-functions': draw what MARKS name in the buffer of VIEW-ID."
  (when-let* ((buffer (drgnx-work-map-buffer view-id)))
    (with-current-buffer buffer
      (when (drgnx-view-p drgnx-view)
        (if (or (eq (plist-get marks :rows) t) (plist-get marks :keys) (plist-get marks :layout))
            (drgnx-view-touch drgnx-view)
          (when (plist-get marks :rows) (drgnx-view-dirty drgnx-view (plist-get marks :rows))))))))

(provide 'drgnx-work-map)
;;; drgnx-work-map.el ends here
