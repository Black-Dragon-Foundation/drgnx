;;; drgnx-runners-view.el --- The runner list: a view with a row per runner (library of tools/runners) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Rows of the Runners list, drawn through the render pipeline's views (wb/drgnx-view.el): a runner is its state dot,
;; name, trust, profile and what it accepts; then its size, running jobs, free disk and last check; a runner out of
;; rotation says why on lines of its own.  The text is the CLI's (`drgnx runner list'), in the code face for numbers and
;; the `drgnx-runners-*' faces, in at most 60 columns.  Module `tools/runners' (drgnx-runners.el) owns the commands,
;; the key handover and the cards.  See docs/guide/runners.md, "The runner list".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-ui-kit)

(declare-function drgnx-view-define "drgnx-view")
(declare-function drgnx-view-attach "drgnx-view")
(declare-function drgnx-view-touch "drgnx-view")
(declare-function drgnx-view-draw-now "drgnx-view")
(declare-function drgnx-view-key-at "drgnx-view")
(declare-function drgnx-view-sync-rows "drgnx-view")
(declare-function drgnx-view-p "drgnx-view")
(defvar drgnx-view)

(defface drgnx-runners-number '((t :inherit fixed-pitch)) "Numbers in the runner list: cores, memory, jobs, disk, times."
  :group 'drgnx)
(defface drgnx-runners-name '((t :inherit bold)) "A runner's name." :group 'drgnx)
(defface drgnx-runners-ready '((t :inherit success)) "The dot of a runner that takes jobs." :group 'drgnx)
(defface drgnx-runners-out '((t :inherit warning)) "The dot of a runner out of rotation." :group 'drgnx)
(defface drgnx-runners-reason '((t :inherit warning)) "Why a runner is out of rotation." :group 'drgnx)
(defface drgnx-runners-header '((t :inherit header-line)) "The runner list's column titles." :group 'drgnx)
(defface drgnx-runners-dim '((t :inherit shadow)) "Trust, profile and the separators of a runner's row." :group 'drgnx)

(defface drgnx-runners-running '((t :inherit drgnx-accent)) "The dot of a runner that is running jobs." :group 'drgnx)
(defface drgnx-runners-attention '((t :inherit drgnx-status-attention))
  "The dot of a runner that needs a login, your keys or your confirm." :group 'drgnx)
(defface drgnx-runners-error '((t :inherit error)) "The dot of a runner that cannot be reached." :group 'drgnx)
(defface drgnx-runners-subtle '((t :inherit shadow)) "The dot of a runner that is draining or being preempted." :group 'drgnx)

(defconst drgnx-runners-view-buffer-name "*drgnx Runners*" "The runner list's buffer.")

(defun drgnx-runners-view-dot-face (state jobs)
  "The face of a runner's dot for its STATE text (as the list says it) and JOBS running there: in rotation and idle,
running, out of rotation, needing you, unreachable, or going away."
  (cond ((equal state "ready") (if (and (numberp jobs) (> jobs 0)) 'drgnx-runners-running 'drgnx-runners-ready))
        ((string-prefix-p "benched" state) 'drgnx-runners-out)
        ((or (string-prefix-p "needs" state) (string-prefix-p "waits for your" state)) 'drgnx-runners-attention)
        ((string-prefix-p "unreachable" state) 'drgnx-runners-error)
        ((or (string-prefix-p "draining" state) (string-prefix-p "preempting" state)) 'drgnx-runners-subtle)
        (t 'drgnx-runners-out)))

(defconst drgnx-runners-view-titles '("Runner" "Trust" "Profile" "Accepts")
  "The first line's column titles, in sentence case.")

(defconst drgnx-runners-view-width 60 "The most columns a line of the list takes.")

;;;; The text of a row

(defun drgnx-runners-view--num (n)
  "N as text in the number face."
  (propertize (format "%s" n) 'face 'drgnx-runners-number))

(defun drgnx-runners-view--clock (secs)
  "SECS since the epoch as HH:MM (UTC), or nil."
  (and (numberp secs) (format-time-string "%H:%M" (seconds-to-time secs) t)))

(defun drgnx-runners-view--wrap (text indent)
  "TEXT in lines of at most `drgnx-runners-view-width' columns, each starting with INDENT spaces."
  (let ((lines nil) (cur (make-string indent ?\s)) (empty t))
    (dolist (w (split-string text "[ \t\n]+" t))
      (when (and (not empty) (> (+ (string-width cur) 1 (string-width w)) drgnx-runners-view-width))
        (push cur lines)
        (setq cur (make-string indent ?\s) empty t))
      (setq cur (concat cur (if empty "" " ") w) empty nil))
    (nreverse (cons cur lines))))

(defun drgnx-runners-view-ready-p (runner)
  "Whether RUNNER takes jobs: its state is `ready'."
  (equal (plist-get runner :state) "ready"))

(defun drgnx-runners-view-row (runner)
  "The text of RUNNER's row (a runner as `runners/list' gives it): two lines, and lines of the reason when it is out of
rotation.  The last line ends in a newline."
  (let* ((ready (drgnx-runners-view-ready-p runner))
         (dot (propertize (drgnx-face-glyph (if ready 'dot 'circle)) 'face (if ready 'drgnx-runners-ready 'drgnx-runners-out)))
         (name (truncate-string-to-width (or (plist-get runner :name) "") 14 nil ?\s))
         (head (concat dot " " (propertize name 'face 'drgnx-runners-name) " "
                       (propertize (truncate-string-to-width (or (plist-get runner :trust) "") 9 nil ?\s) 'face 'drgnx-runners-dim)
                       " " (propertize (format "%s · %s" (plist-get runner :profile) (plist-get runner :accept))
                                       'face 'drgnx-runners-dim)
                       (if (equal (plist-get runner :trust) "my-cloud")
                           (propertize (concat " " (drgnx-face-glyph 'cloud)) 'face 'drgnx-runners-dim)
                         "")))
         (sep (propertize " · " 'face 'drgnx-runners-dim))
         (clock (drgnx-runners-view--clock (plist-get runner :checked)))
         (size (concat "  " (drgnx-runners-view--num (or (plist-get runner :cores) 0)) " cores" sep
                       (drgnx-runners-view--num (/ (or (plist-get runner :mem_mib) 0) 1024)) "G" sep
                       (drgnx-runners-view--num (or (plist-get runner :jobs) 0)) " running" sep
                       (drgnx-runners-view--num (or (plist-get runner :disk_free_gb) 0)) "G free"
                       (if clock (concat sep (drgnx-runners-view--num clock)) ""))))
    (concat (truncate-string-to-width head drgnx-runners-view-width) "\n"
            (truncate-string-to-width size drgnx-runners-view-width) "\n"
            (if ready ""
              (mapconcat (lambda (l) (concat (propertize l 'face 'drgnx-runners-reason) "\n"))
                         (drgnx-runners-view--wrap (or (plist-get runner :state) "") 2) "")))))

(defun drgnx-runners-view-titles-line ()
  "The column titles as the list's first line."
  (propertize (format "  %-14s %-9s %-9s %s\n" (nth 0 drgnx-runners-view-titles) (nth 1 drgnx-runners-view-titles)
                      (nth 2 drgnx-runners-view-titles) (nth 3 drgnx-runners-view-titles))
              'face 'drgnx-runners-header))

;;;; The view

(defvar drgnx-runners-view--rows (make-hash-table :test #'equal)
  "NAME → the runner (a plist) the list draws a row for; `head' is the titles.  Filled by `drgnx-runners-view--sync'.")

(defvar drgnx-runners-view--list nil "The runners the list shows, as the hub last said (a list of plists).")

(defun drgnx-runners-view--render (key)
  "The text of the list's row KEY."
  (if (eq key 'head)
      (drgnx-runners-view-titles-line)
    (if-let* ((r (gethash key drgnx-runners-view--rows)))
        (drgnx-runners-view-row r)
      "\n")))

(defun drgnx-runners-view--sig (key)
  "KEY's signature: what its row says."
  (if (eq key 'head) 0 (sxhash-equal (gethash key drgnx-runners-view--rows))))

(defun drgnx-runners-view--sync (view)
  "Make VIEW's rows the runners now: the titles, then a row per runner."
  (clrhash drgnx-runners-view--rows)
  (dolist (r drgnx-runners-view--list) (puthash (plist-get r :name) r drgnx-runners-view--rows))
  (drgnx-view-sync-rows view (cons 'head (mapcar (lambda (r) (plist-get r :name)) drgnx-runners-view--list))
                        #'drgnx-runners-view--sig))

(defun drgnx-runners-view-define ()
  "Define the view type `runners-list' (undone with the module that calls this in its setup)."
  (require 'drgnx-view)
  (drgnx-view-define 'runners-list :render #'drgnx-runners-view--render :sync #'drgnx-runners-view--sync :delay 0))

(defun drgnx-runners-view-buffer ()
  "The list's buffer, or nil."
  (get-buffer drgnx-runners-view-buffer-name))

(defun drgnx-runners-view--view ()
  "The list's view, or nil when its buffer is not live."
  (when-let* ((b (drgnx-runners-view-buffer)))
    (let ((view (buffer-local-value 'drgnx-view b)))
      (and (drgnx-view-p view) view))))

(defun drgnx-runners-view-set (runners)
  "RUNNERS (a list of plists, as `runners/list' gives them) are the list's rows now; the view is marked (it draws only
while a window shows it)."
  (setq drgnx-runners-view--list runners)
  (when-let* ((view (drgnx-runners-view--view))) (drgnx-view-touch view)))

(defun drgnx-runners-view-runner-at (&optional pos)
  "The runner (a plist) whose row holds POS (default: point), or nil."
  (let ((key (drgnx-view-key-at pos)))
    (and key (not (eq key 'head)) (gethash key drgnx-runners-view--rows))))

(defun drgnx-runners-view-forget ()
  "Forget the runners the list holds (the module is turned off)."
  (setq drgnx-runners-view--list nil)
  (clrhash drgnx-runners-view--rows))

(provide 'drgnx-runners-view)
;;; drgnx-runners-view.el ends here
