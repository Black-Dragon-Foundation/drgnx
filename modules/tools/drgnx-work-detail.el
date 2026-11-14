;;; drgnx-work-detail.el --- The Work map's side panel and huddle key (library of tools/work-space) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The side panel of a map is the hub's Detail view (VIEW/detail beside the map's VIEW): its rows come as patches and
;; follow the map's selection in the hub, so nothing here draws it.  Beside a map without Sjá the panel says the map
;; needs it.  Also here: the job log of the panel's queue (`l') and the huddle key (`H'), which read the map's model.
;; Loaded by tools/work-space (drgnx-work-space.el); defines no module.  See docs/develop/work-space.md.

;;; Code:
(require 'seq)
(require 'subr-x)
(require 'text-property-search)
(require 'drgnx-view)
(require 'drgnx-work-client)
(unless (featurep 'drgnx-work-map)
  (load (expand-file-name "drgnx-work-map" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(declare-function drgnx-work-map--sja "drgnx-work-map")
(declare-function nidhogg-view-get "nidhogg-views" (h what &optional arg arg2))
(declare-function drgnx-agents-editor-here-huddle "drgnx-agents-editor-here")
(defvar drgnx-work-map--selection)
(defvar drgnx-work-map-no-sja)

(defun drgnx-work-huddle-overlap ()
  "Start a huddle between the selected agent and an agent its card overlaps (the map model's `overlaps' field; a choice
when it has several)."
  (interactive)
  (let* ((h (or (drgnx-work-map--sja) (user-error "%s" drgnx-work-map-no-sja)))
         (id (cdr drgnx-work-map--selection))
         (others (and id (equal (car drgnx-work-map--selection) 'agent)
                      (seq-filter (lambda (o) (string-prefix-p "agent:" o))
                                  (split-string (or (nidhogg-view-get h 'field "overlaps" id) "")))))
         (other (cond ((null others) (user-error "This agent has no overlap with another agent"))
                      ((cdr others)
                       (let ((names (mapcar (lambda (o) (cons (or (nidhogg-view-get h 'field "label" o) o) o)) others)))
                         (cdr (assoc (completing-read "Huddle with: " names nil t) names))))
                      (t (car others)))))
    (unless (fboundp 'drgnx-agents-editor-here-huddle) (user-error "Agents in the editor is not loaded"))
    (drgnx-agents-editor-here-huddle (substring id (length "agent:")) (substring other (length "agent:")))))

;;;; The panel

(defvar drgnx-area-own-title)
(declare-function drgnx-face-glyph "drgnx-ui-kit")

(defvar-local drgnx-work-detail--map nil "The map buffer a detail buffer shows the selection of.")

(define-derived-mode drgnx-work-detail-mode special-mode "Work detail"
  "The Work space's side panel: why the selected item exists, what it touches, its conclusions and what you can do."
  ;; work-space-dark.html `.det': the island's header is "Detail", drawn by the tile (the right dock's tabs stay off it)
  (setq-local truncate-lines nil cursor-type nil
              drgnx-area-own-title (propertize (concat " " (or (drgnx-face-glyph 'panel-right) "") " Detail ")
                                               'face 'drgnx-wb-tab-current)))

(declare-function drgnx-view-env-register "drgnx-view-env")

(defun drgnx-work-detail--rows-view (map-buffer)
  "The hub's Detail view beside MAP-BUFFER's map view, (VIEW . CLASS), when the map is on the hub's rows, else nil."
  (with-current-buffer map-buffer
    (when drgnx-view-patch
      (cons (concat (drgnx-view-patch-view drgnx-view-patch) "/detail") (drgnx-view-patch-class drgnx-view-patch)))))

(defun drgnx-work-detail-buffer (map-buffer)
  "The side panel's buffer for MAP-BUFFER, made when there is none: the hub's view VIEW/detail beside the map's VIEW,
following the map's selection there.  Beside a map without Sjá it says the map needs it."
  (let ((buffer (get-buffer-create (format "*drgnx work detail: %s*" (string-trim (buffer-name map-buffer) "\\*drgnx work: " "\\*"))))
        (rows (drgnx-work-detail--rows-view map-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-work-detail-mode)
        (drgnx-work-detail-mode)
        (if rows
            (progn (drgnx-view-patch-attach (car rows) (cdr rows))
                   (setq-local drgnx-view-patch-twin-function #'drgnx-work-detail--twin)
                   (require 'drgnx-view-env)
                   (drgnx-view-env-register (car rows) buffer))
          (let ((inhibit-read-only t)) (insert drgnx-work-map-no-sja "\n"))))
      (setq drgnx-work-detail--map map-buffer))
    buffer))

(declare-function drgnx-hub-call "drgnx-hub-client")

(defun drgnx-work-job-log ()
  "Show the end of the log of the job on this row of the queue (the first job of the panel when point is on none).
Press it again for what came since."
  (interactive)
  (let ((id (or (get-text-property (line-beginning-position) 'drgnx-work-job)
                (get-text-property (point) 'drgnx-work-job)
                (save-excursion (goto-char (point-min))
                                (when-let* ((m (text-property-search-forward 'drgnx-work-job)))
                                  (prop-match-value m))))))
    (unless id (user-error "No job in this queue"))
    (drgnx-hub-call "exec/log" (list :id id :tail_bytes 65536)
                    (lambda (result err)
                      (if err (message "Work: the log of %s: %s" id err)
                        (with-current-buffer (let ((name (format "*drgnx job log: %s*" id)))
                                               (when-let* ((old (get-buffer name))) (kill-buffer old))
                                               (generate-new-buffer name))
                          (insert (string-join (plist-get result :lines) "\n") "\n")
                          (special-mode)
                          (goto-char (point-max))
                          (display-buffer (current-buffer)))))
                    :deadline 10)))

(declare-function drgnx-view-env-twin "drgnx-view-env" (class prefixes &optional setup))

(defun drgnx-work-detail--twin (class)
  "The detail's buffer in display CLASS (`drgnx-view-patch-twin-function')."
  (drgnx-view-env-twin class '("drgnx-work-detail-")))

(defun drgnx-work-detail-buffers ()
  (seq-filter (lambda (b) (and (eq (buffer-local-value 'major-mode b) 'drgnx-work-detail-mode) (not (drgnx-view-patch-twin-p b)))) (buffer-list)))

(provide 'drgnx-work-detail)
;;; drgnx-work-detail.el ends here
