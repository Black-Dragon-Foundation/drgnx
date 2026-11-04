;;; drgnx-freezes.el --- Show Freezes: the day's ranking of stalls and the GC row -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Help → Show Freezes draws `nidhogg-watchdog-ranking' through the render pipeline's views (wb/drgnx-view.el): the GC
;; row on top (with the largest owner of the last heap audit when there is a snapshot), then a row per package with
;; its signatures and call tree, and a felt column.  Each row has its actions: the package's source, its homepage,
;; the drgnx module that enables it.  The header has "Copy report" (names, durations, stacks and the Nidhogg version;
;; no path) and "Sample the next freeze in depth".  The GC row has "Run a heap audit" and "Show collections".
;; The view is drawn when the command runs and on `g'; it does not follow the log.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-registry)
(require 'drgnx-ui-kit)
(require 'drgnx-notice)

(defvar nidhogg-watchdog-record-functions)
(defvar nidhogg-version)
(defvar package-alist)
(declare-function drgnx-view-define "drgnx-view")
(declare-function drgnx-view-type-p "drgnx-view")
(declare-function drgnx-view-attach "drgnx-view")
(declare-function drgnx-view-touch "drgnx-view")
(declare-function drgnx-view-draw-now "drgnx-view")
(declare-function drgnx-view-sync-rows "drgnx-view")
(declare-function drgnx-view-p "drgnx-view")
(declare-function nidhogg-watchdog-ranking "nidhogg-watchdog-report")
(declare-function nidhogg-watchdog--deep "nidhogg-watchdog")
(declare-function drgnx-heap-audit-command "drgnx-heap")
(declare-function drgnx-gc-census-show "drgnx-gc-census")
(declare-function drgnx-modules-list "drgnx-modules")
(declare-function drgnx-owner-module-for-package "drgnx-owner")
(declare-function drgnx-watchdog-doctor--largest-owner "drgnx-watchdog-doctor")
(declare-function drgnx-watchdog-doctor-start "drgnx-watchdog-doctor")
(declare-function package-desc-extras "package")
(declare-function package-desc-dir "package")

(defconst drgnx-freezes-buffer-name "*drgnx Freezes*" "The view's buffer.")
(defconst drgnx-freezes-tree-lines 8 "The most lines of a package row's call tree.")

(defvar drgnx-freezes--rows (make-hash-table :test 'equal) "KEY → the row's data, filled by `drgnx-freezes--sync'.")

;;;; The data

(defun drgnx-freezes-ranking ()
  "The watchdog's ranking (the GC row first, then packages by score), or nil without the watchdog."
  (when (and (require 'nidhogg-watchdog-report nil t) (fboundp 'nidhogg-watchdog-ranking))
    (condition-case nil (nidhogg-watchdog-ranking) (error nil))))

(defun drgnx-freezes--module (package)
  "The name of the drgnx module that enables PACKAGE, or nil."
  (when-let* ((m (and (fboundp 'drgnx-owner-module-for-package) (drgnx-owner-module-for-package package))))
    (symbol-name m)))

(defun drgnx-freezes--ms (ms) (if (>= ms 1000) (format "%.1f s" (/ ms 1000.0)) (format "%d ms" (round ms))))

;;;; The rows

(defun drgnx-freezes--keys (ranking)
  "The view's keys for RANKING, filling `drgnx-freezes--rows': the header, the GC row, a row per package."
  (clrhash drgnx-freezes--rows)
  (let ((keys (list 'head)))
    (puthash 'head ranking drgnx-freezes--rows)
    (dolist (row ranking)
      (let ((key (if (plist-get row :gc) 'gc (cons 'package (plist-get row :package)))))
        (puthash key row drgnx-freezes--rows)
        (push key keys)))
    (nreverse keys)))

(defun drgnx-freezes--tree-lines (node depth limit)
  "NODE, a call tree (NAME COUNT . CHILDREN), as at most LIMIT indented lines, the biggest branches first."
  (let (out)
    (cl-labels ((walk (n d)
                  (when (< (length out) limit)
                    (push (format "%s%s  %d" (make-string (* 2 d) ?\s) (car n) (cadr n)) out)
                    (dolist (c (cddr n)) (walk c (1+ d))))))
      (dolist (c (cddr node)) (walk c depth)))
    (nreverse out)))

(defun drgnx-freezes--gc-text (row)
  "The text of the GC row."
  (let ((detail (plist-get row :detail)) (owner (and (fboundp 'drgnx-watchdog-doctor--largest-owner)
                                                     (drgnx-watchdog-doctor--largest-owner))))
    (concat (drgnx-ui-status (if (plist-get detail :meets) 'ok 'warn)) " "
            (propertize "GC" 'face 'bold) "  "
            (format "%d collections · %d felt · longest %s · total %s" (plist-get row :count) (plist-get row :felt)
                    (drgnx-freezes--ms (plist-get row :max)) (drgnx-freezes--ms (plist-get row :total)))
            (cond ((plist-get detail :meets) "  (meets its target)") (detail "  (missed its target)") (t ""))
            "\n"
            (if owner (format "    largest retainer in the last audit: %s, %s MB%s\n" (nth 0 owner) (nth 1 owner)
                              (if (nth 2 owner) (format " (module %s)" (nth 2 owner)) ""))
              "")
            "    " (drgnx-ui-button "Run a heap audit" #'drgnx-freezes-heap-audit) "  "
            (drgnx-ui-button "Show collections" #'drgnx-freezes-show-collections) "\n")))

(defun drgnx-freezes--package-text (row)
  "The text of a package ROW: its numbers, felt column, signatures, call tree and actions."
  (let* ((name (plist-get row :package)) (module (drgnx-freezes--module name)))
    (concat (drgnx-ui-status (if (> (plist-get row :felt) 0) 'warn 'info)) " "
            (propertize name 'face 'bold)
            (if module (format "  (module %s)" module) "") "  "
            (format "%d stalls · felt %d · %s in all · longest %s" (plist-get row :count) (plist-get row :felt)
                    (drgnx-freezes--ms (plist-get row :total)) (drgnx-freezes--ms (plist-get row :max)))
            "\n"
            (mapconcat (lambda (s) (format "    %s  %d × · felt %d\n" (plist-get s :name) (plist-get s :count)
                                           (plist-get s :felt)))
                       (seq-take (plist-get row :signatures) 3) "")
            (mapconcat (lambda (l) (concat "      " l "\n"))
                       (drgnx-freezes--tree-lines (plist-get row :tree) 0 drgnx-freezes-tree-lines) "")
            "    " (drgnx-ui-button "Source" (lambda () (drgnx-freezes-open-source name))) "  "
            (drgnx-ui-button "Homepage" (lambda () (drgnx-freezes-open-homepage name)))
            (if module (concat "  " (drgnx-ui-button "Module" (lambda () (drgnx-freezes-open-module name)))) "")
            "\n")))

(defun drgnx-freezes--head-text (ranking)
  "The header: what the page is and its two actions."
  (concat (propertize "Freezes" 'face 'bold) " · "
          (if ranking "the stalls of the kept days, worst first" "the watchdog has not recorded anything yet") "\n    "
          (drgnx-ui-button "Copy report" #'drgnx-freezes-copy-report) "  "
          (drgnx-ui-button "Sample the next freeze in depth" #'drgnx-freezes-sample-deep) "\n\n"))

(defun drgnx-freezes--render (key)
  "The text of the row KEY, ending in a newline."
  (let ((data (gethash key drgnx-freezes--rows)))
    (cond ((eq key 'head) (drgnx-freezes--head-text data))
          ((eq key 'gc) (drgnx-freezes--gc-text data))
          (data (drgnx-freezes--package-text data))
          (t "\n"))))

(defun drgnx-freezes--sig (key)
  "What of the row KEY changes its drawing."
  (let ((d (gethash key drgnx-freezes--rows)))
    (if (eq key 'head) (and d t) (vector (plist-get d :count) (plist-get d :felt) (plist-get d :total)))))

(defun drgnx-freezes--sync (view)
  "Make VIEW's rows the ranking's now."
  (drgnx-view-sync-rows view (drgnx-freezes--keys (drgnx-freezes-ranking)) #'drgnx-freezes--sig))

;;;; The buffer

(define-derived-mode drgnx-freezes-mode special-mode "Freezes"
  "The stalls of the watchdog's kept days and the GC row.  \\`g' redraws."
  (setq-local revert-buffer-function #'drgnx-freezes--revert))

(defun drgnx-freezes--view ()
  "The page's view, or nil when its buffer is not live."
  (when-let* ((buffer (get-buffer drgnx-freezes-buffer-name)))
    (let ((view (buffer-local-value 'drgnx-view buffer)))
      (and (drgnx-view-p view) view))))

(defun drgnx-freezes--revert (&rest _)
  "`g': draw the page again now."
  (when-let* ((view (drgnx-freezes--view)))
    (drgnx-view-touch view)
    (drgnx-view-draw-now view)))

;;;###autoload
(defun drgnx-freezes-show ()
  "Show Freezes: the watchdog's ranking of stalls, the GC row on top."
  (interactive)
  (require 'drgnx-view)
  (unless (drgnx-view-type-p 'freezes-list)
    (drgnx-view-define 'freezes-list :render #'drgnx-freezes--render :sync #'drgnx-freezes--sync :delay 0))
  (let ((buffer (get-buffer-create drgnx-freezes-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-freezes-mode) (drgnx-freezes-mode))
      (unless (drgnx-freezes--view) (drgnx-view-attach 'freezes-list))
      (drgnx-freezes--revert))
    (pop-to-buffer buffer)))

;;;; The actions

(defun drgnx-freezes--package-desc (package)
  "The installed package PACKAGE's description, or nil."
  (and (require 'package nil t) (cadr (assq (intern package) package-alist))))

(defun drgnx-freezes-open-source (package)
  "Open the source of PACKAGE, the culprit's: its library, else its folder."
  (let ((lib (ignore-errors (find-library-name package))) (desc (drgnx-freezes--package-desc package)))
    (cond (lib (find-file lib))
          (desc (dired (package-desc-dir desc)))
          (t (user-error "No source found for %s" package)))))

(defun drgnx-freezes-open-homepage (package)
  "Open PACKAGE's homepage, when its package says one."
  (let* ((desc (drgnx-freezes--package-desc package))
         (url (and desc (cdr (assq :url (package-desc-extras desc))))))
    (if (stringp url) (browse-url url) (user-error "%s names no homepage" package))))

(defun drgnx-freezes-open-module (package)
  "Show the modules list, where the module that enables PACKAGE can be turned off."
  (if-let* ((m (drgnx-freezes--module package)))
      (progn (message "%s is enabled by the module %s" package m) (drgnx-modules-list))
    (user-error "No drgnx module enables %s" package)))

(defun drgnx-freezes-heap-audit ()
  "The GC row's action: the heap audit (it asks first: Emacs stops while it runs)."
  (interactive)
  (drgnx-heap-audit-command))

(defun drgnx-freezes-show-collections ()
  "The GC row's action: every collection, by day."
  (interactive)
  (drgnx-gc-census-show))

(defun drgnx-freezes--scrub (text)
  "TEXT without file system paths: each is replaced by its last component."
  (replace-regexp-in-string "\\(?:~\\|[A-Za-z]:\\)?\\(?:/[^/[:space:])\"]+\\)+/\\([^/[:space:])\"]+\\)" "\\1" text))

(defun drgnx-freezes-report-text (ranking)
  "RANKING as a report to paste: the Nidhogg version, each row's names, durations and stacks.  No file path."
  (drgnx-freezes--scrub
   (concat (format "Nidhogg %s\n" (or (bound-and-true-p nidhogg-version) "unknown"))
           (mapconcat
            (lambda (row)
              (if (plist-get row :gc)
                  (format "GC: %d collections, %d felt, longest %s, total %s\n" (plist-get row :count)
                          (plist-get row :felt) (drgnx-freezes--ms (plist-get row :max))
                          (drgnx-freezes--ms (plist-get row :total)))
                (concat (format "%s: %d stalls, %d felt, %s in all, longest %s\n" (plist-get row :package)
                                (plist-get row :count) (plist-get row :felt) (drgnx-freezes--ms (plist-get row :total))
                                (drgnx-freezes--ms (plist-get row :max)))
                        (mapconcat (lambda (s) (format "  %s: %d ×\n" (plist-get s :name) (plist-get s :count)))
                                   (plist-get row :signatures) "")
                        (mapconcat (lambda (l) (concat "    " l "\n"))
                                   (drgnx-freezes--tree-lines (plist-get row :tree) 0 drgnx-freezes-tree-lines) ""))))
            ranking ""))))

(defun drgnx-freezes-copy-report ()
  "Copy the report (names, durations, stacks, the Nidhogg version; no path) to the kill ring."
  (interactive)
  (let ((ranking (drgnx-freezes-ranking)))
    (unless ranking (user-error "Nothing to report yet"))
    (kill-new (drgnx-freezes-report-text ranking))
    (message "Freezes report copied")))

(defvar drgnx-freezes--deep-armed nil "Non-nil: the next stall record is the deep one the user asked for.")

(defun drgnx-freezes--deep-arrived (record)
  "A stall RECORD sampled in depth arrived after `drgnx-freezes-sample-deep': say so once.  A record hook: no prompt,
no I/O."
  (when (and drgnx-freezes--deep-armed (plist-get record :deep))
    (setq drgnx-freezes--deep-armed nil)
    (remove-hook 'nidhogg-watchdog-record-functions #'drgnx-freezes--deep-arrived)
    (drgnx-notify 'watchdog 'info "The deep sample of the freeze is in" :id 'deep :command 'freezes)))

(defun drgnx-freezes-sample-deep ()
  "Sample the next freeze in depth (the watchdog keeps more of its stack); a notice says when its record arrives."
  (interactive)
  (unless (fboundp 'nidhogg-watchdog--deep)
    (user-error "This Emacs has no stall watchdog (docs/guide/speed.md)"))
  (unless (bound-and-true-p nidhogg-watchdog-mode)
    (user-error "The watchdog is off: set drgnx-speed-watchdog to t first (docs/guide/speed.md)"))
  (nidhogg-watchdog--deep 1)
  (setq drgnx-freezes--deep-armed t)
  (add-hook 'nidhogg-watchdog-record-functions #'drgnx-freezes--deep-arrived)
  (message "The next freeze will be sampled in depth"))

;;;; The command

(defun drgnx-freezes-register-commands ()
  "The command of the page."
  (drgnx-command-define 'freezes :category "Help" :title "Show Freezes" :command #'drgnx-freezes-show
                        :menu '("Help") :doc "The stall watchdog's ranking: the GC row, packages, signatures and call trees"))

(provide 'drgnx-freezes)
;;; drgnx-freezes.el ends here
