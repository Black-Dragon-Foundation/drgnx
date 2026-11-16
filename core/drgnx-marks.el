;;; drgnx-marks.el --- The scroll bar's marks: changes, problems and search hits, each produced once -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The producers of the scroll bar's marks (docs/guide/minimap.md, "Marks").  Each kind is produced once, when its
;; source changes, and handed to the strip's owner (`drgnx-ruler-source', core/drgnx-ruler.el):
;;
;; - changes against the last commit (the gutter's change bars, `drgnx-hunks'), in the left lane, one mark per run of
;;   changed lines, reaching to the run's last line;
;; - Flymake's errors, warnings and notes, in the right lane, after Flymake reports (its listings' update);
;; - search hits while isearch runs, in the middle lane: the whole buffer, scanned once per change of the search
;;   string on an idle debounce, at most `drgnx-marks-search-max' hits;
;; - in the Problems list, its error and warning rows.
;;
;; Nothing here runs on a scroll or a keystroke that changes no source.  The module editor/minimap turns the
;; producers on (`drgnx-marks-on') and off.

;;; Code:
(require 'cl-lib)
(require 'drgnx-ruler)
(require 'drgnx-timer)
(require 'drgnx-faces)
(require 'drgnx-ui-kit)

(defvar drgnx-hunks--marks)
(defvar drgnx-hunks-mode)
(defvar isearch-string)
(defvar isearch-regexp)
(defvar isearch-case-fold-search)
(defvar flymake-mode)
(declare-function flymake-diagnostics "flymake" (&optional beg end))
(declare-function flymake-diagnostic-type "flymake" (diag))
(declare-function flymake-diagnostic-beg "flymake" (diag))
(declare-function flymake--lookup-type-property "flymake" (type prop &optional default))

(defface drgnx-marks-added '((t :inherit drgnx-status-ok)) "A scroll bar mark of added lines." :group 'drgnx-minimap)
(defface drgnx-marks-changed '((t :inherit drgnx-status-info)) "A scroll bar mark of changed lines." :group 'drgnx-minimap)
(defface drgnx-marks-deleted '((t :inherit drgnx-status-fail)) "A scroll bar mark of deleted lines." :group 'drgnx-minimap)
(defface drgnx-marks-error '((t :inherit drgnx-status-fail)) "A scroll bar mark of an error." :group 'drgnx-minimap)
(defface drgnx-marks-warning '((t :inherit drgnx-status-warn)) "A scroll bar mark of a warning." :group 'drgnx-minimap)
(defface drgnx-marks-info '((t :inherit drgnx-status-info)) "A scroll bar mark of a note." :group 'drgnx-minimap)
(defface drgnx-marks-hit '((t :inherit drgnx-accent)) "A scroll bar mark of a search hit." :group 'drgnx-minimap)

(defvar drgnx-marks-search-max 5000 "The most search hits marked on the scroll bar; past it the scan stops.")

;;;; Changes

(defun drgnx-marks--hunks ()
  "The change bars of the buffer (`drgnx-hunks--marks', one per line) as scroll bar marks: a run of lines of the same
kind, one after another, is one mark from its first line to its last."
  (let (out run-pos run-end run-kind run-line)
    (dolist (m (sort (copy-sequence drgnx-hunks--marks) (lambda (a b) (< (car a) (car b)))))
      (let ((pos (car m)) (line (cadr m)) (kind (cddr m)))
        (if (and run-kind (eq kind run-kind) (eql line (1+ run-line)))
            (setq run-end pos run-line line)
          (when run-kind (push (drgnx-marks--hunk-mark run-pos run-end run-kind) out))
          (setq run-pos pos run-end pos run-kind kind run-line line))))
    (when run-kind (push (drgnx-marks--hunk-mark run-pos run-end run-kind) out))
    (nreverse out)))

(defun drgnx-marks--hunk-mark (beg end kind)
  "The mark of a run of KIND lines from BEG to the line starting at END."
  (list beg 'left (pcase kind ('added 'drgnx-marks-added) ('deleted 'drgnx-marks-deleted) (_ 'drgnx-marks-changed))
        1 nil (and (> end beg) end)))

(defun drgnx-marks--hunks-drawn (&rest _)
  "After `drgnx-hunks--draw' and `drgnx-hunks--clear': the change marks again."
  (drgnx-ruler-source 'hunks (and drgnx-hunks-mode drgnx-hunks--marks #'drgnx-marks--hunks)))

;;;; Problems (Flymake)

(defun drgnx-marks--flymake ()
  "Flymake's diagnostics of the buffer as scroll bar marks: errors over warnings over notes."
  (when (bound-and-true-p flymake-mode)
    (mapcar (lambda (d)
              (pcase (flymake--lookup-type-property (flymake-diagnostic-type d) 'flymake-category)
                ('flymake-error (list (flymake-diagnostic-beg d) 'right 'drgnx-marks-error 3))
                ('flymake-warning (list (flymake-diagnostic-beg d) 'right 'drgnx-marks-warning 2))
                (_ (list (flymake-diagnostic-beg d) 'right 'drgnx-marks-info 1))))
            (flymake-diagnostics))))

(defun drgnx-marks--flymake-now (buffer)
  "BUFFER's Flymake marks, set once (the debounce's end)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (drgnx-ruler-source 'flymake (and (bound-and-true-p flymake-mode) #'drgnx-marks--flymake)))))

(defun drgnx-marks--flymake-reported (&optional buffer &rest _)
  "After `flymake--update-diagnostics-listings': BUFFER's problem marks, debounced 100 ms (a report comes per backend)."
  (let ((b (or buffer (current-buffer))))
    (drgnx-timer-debounce (cons 'marks-flymake b) 0.1 #'drgnx-marks--flymake-now :args (list b) :owner b)))

;;;; Search hits

(defvar-local drgnx-marks--search-hits nil "The hits of the running isearch: (POS LANE FACE PRIORITY) each.")
(defvar-local drgnx-marks--search-for nil "The (STRING REGEXP CASE-FOLD) `drgnx-marks--search-hits' were found for.")

(defun drgnx-marks--search-scan (buffer)
  "BUFFER's isearch hits, the whole accessible text, once per search string (the debounce's end)."
  (when (and (buffer-live-p buffer) (buffer-local-value 'isearch-mode buffer))
    (with-current-buffer buffer
      (let ((key (list isearch-string isearch-regexp isearch-case-fold-search)))
        (unless (equal key drgnx-marks--search-for)
          (setq drgnx-marks--search-for key drgnx-marks--search-hits nil)
          (unless (string-empty-p isearch-string)
            (let ((case-fold-search isearch-case-fold-search) (n 0) hits)
              (save-excursion
                (goto-char (point-min))
                (while (and (< n drgnx-marks-search-max)
                            (condition-case nil
                                (if isearch-regexp (re-search-forward isearch-string nil t)
                                  (search-forward isearch-string nil t))
                              (invalid-regexp nil)))
                  (push (list (match-beginning 0) 'middle 'drgnx-marks-hit 2) hits)
                  (setq n (1+ n))
                  (when (= (match-beginning 0) (match-end 0)) (forward-char 1))))
              (setq drgnx-marks--search-hits (nreverse hits))))
          (drgnx-ruler-source 'search (and drgnx-marks--search-hits (lambda () drgnx-marks--search-hits))))))))

(defun drgnx-marks--search-changed ()
  "`isearch-update-post-hook': the hits again once the search string rests."
  (drgnx-timer-debounce (cons 'marks-search (current-buffer)) 0.15 #'drgnx-marks--search-scan
                        :args (list (current-buffer)) :owner (current-buffer)))

(defun drgnx-marks--search-ended ()
  "`isearch-mode-end-hook': the hits go."
  (drgnx-timer-cancel (cons 'marks-search (current-buffer)))
  (setq drgnx-marks--search-hits nil drgnx-marks--search-for nil)
  (drgnx-ruler-source 'search nil))

;;;; The Problems list's rows

(defun drgnx-marks--problem-rows ()
  "The Problems list's error and warning rows as marks (the row's `drgnx-problem' property and its severity glyph)."
  (let (out (pos (point-min)))
    (while (setq pos (text-property-not-all pos (point-max) 'drgnx-problem nil))
      (let ((face (get-text-property (+ pos 4) 'face)))
        (pcase face
          ('drgnx-status-fail (push (list pos 'right 'drgnx-marks-error 3) out))
          ('drgnx-status-warn (push (list pos 'right 'drgnx-marks-warning 2) out))))
      (setq pos (or (next-single-property-change pos 'drgnx-problem) (point-max))))
    (nreverse out)))

(defun drgnx-marks--problems-listed (&rest _)
  "After the Problems list is drawn again: its row marks."
  (when (derived-mode-p 'special-mode)
    (drgnx-ruler-source 'problems #'drgnx-marks--problem-rows)))

;;;; On and off

(defun drgnx-marks-on ()
  "The producers on: advice on the change bars' draw, Flymake's report and the Problems list's draw, isearch's hooks."
  (advice-add 'drgnx-hunks--draw :after #'drgnx-marks--hunks-drawn)
  (advice-add 'drgnx-hunks--clear :after #'drgnx-marks--hunks-drawn)
  (advice-add 'flymake--update-diagnostics-listings :after #'drgnx-marks--flymake-reported)
  (advice-add 'drgnx-problems--revert :after #'drgnx-marks--problems-listed)
  (add-hook 'isearch-update-post-hook #'drgnx-marks--search-changed)
  (add-hook 'isearch-mode-end-hook #'drgnx-marks--search-ended))

(defun drgnx-marks-off ()
  "The producers off, and their marks gone from every buffer."
  (advice-remove 'drgnx-hunks--draw #'drgnx-marks--hunks-drawn)
  (advice-remove 'drgnx-hunks--clear #'drgnx-marks--hunks-drawn)
  (advice-remove 'flymake--update-diagnostics-listings #'drgnx-marks--flymake-reported)
  (advice-remove 'drgnx-problems--revert #'drgnx-marks--problems-listed)
  (remove-hook 'isearch-update-post-hook #'drgnx-marks--search-changed)
  (remove-hook 'isearch-mode-end-hook #'drgnx-marks--search-ended)
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when drgnx-ruler-mode
        (dolist (owner '(hunks flymake search problems)) (drgnx-ruler-source owner nil))))))

(provide 'drgnx-marks)
;;; drgnx-marks.el ends here
