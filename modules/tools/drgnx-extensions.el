;;; drgnx-extensions.el --- Module tools/extensions: one place for packages, plugins and modules -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Extensions view (drgnx-extensions-list.el) and its details pages: what is installed, what has an update, what a
;; project recommends, the editor's modules and Emacs's built-ins, in one list with filters.  This file is the module:
;; its settings, its commands, the status-bar segment and the daily check of the catalog.  Installing, updating and
;; removing are jobs of the job layer; this module only asks for them and shows how they go.  See
;; docs/guide/extensions.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-setting)
(require 'drgnx-timer)
(unless (featurep 'drgnx-extensions-list)
  (load (expand-file-name "drgnx-extensions-list" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-extensions-details)
  (load (expand-file-name "drgnx-extensions-details" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(dolist (part '(drgnx-extensions-jobs drgnx-extensions-live drgnx-extensions-project drgnx-extensions-trust))
  (unless (featurep part)
    (load (expand-file-name (symbol-name part) (file-name-directory (or load-file-name buffer-file-name))) nil t)))
(require 'drgnx-restart)

(declare-function drgnx-statusbar-define-segment "drgnx-statusbar")
(declare-function drgnx-extensions-jobs-run "drgnx-extensions-jobs")
(declare-function drgnx-extensions-jobs-setup "drgnx-extensions-jobs")
(declare-function drgnx-extensions-jobs-teardown "drgnx-extensions-jobs")
(declare-function drgnx-extensions-live-setup "drgnx-extensions-live")
(declare-function drgnx-extensions-project-setup "drgnx-extensions-project")
(declare-function drgnx-extensions-project-teardown "drgnx-extensions-project")
(declare-function drgnx-extensions-trust-setup "drgnx-extensions-trust")
(declare-function drgnx-extensions-trust-teardown "drgnx-extensions-trust")
(declare-function drgnx-extensions-trust-install "drgnx-extensions-trust")
(declare-function drgnx-extensions-trust-cancel "drgnx-extensions-trust")
(declare-function drgnx-extensions-trust-apply "drgnx-extensions-trust")
(declare-function drgnx-extensions-details--define-view "drgnx-extensions-details")
(declare-function drgnx-extensions-details-forget-generations "drgnx-extensions-details")
(declare-function drgnx-extensions-list--define-view "drgnx-extensions-list")
(declare-function drgnx-extensions-list--jobs-changed "drgnx-extensions-list")
(declare-function drgnx-extensions-list--teardown "drgnx-extensions-list")
(declare-function drgnx-extensions-list-catalog-stale-p "drgnx-extensions-list")
(defvar drgnx-extensions-jobs-changed-functions)
(defvar drgnx-extensions-list--updates)
(defvar drgnx-extensions-list--restart)

(drgnx-defsetting drgnx-packages-off nil
  "Packages that are off in this project: their file modes and minor modes fall back to Emacs's own here.  The
Extensions view writes it."
  :type '(repeat symbol) :group 'drgnx :scope 'project :workspace 'data :agents 'never :schema '(list-of symbol))

(drgnx-defsetting drgnx-extensions-recommended nil
  "Packages this project recommends: the Extensions view lists them under Recommended, with an Install button."
  :type '(repeat symbol) :group 'drgnx :scope 'project :workspace 'data :agents 'never :schema '(list-of symbol))

(drgnx-defsetting drgnx-extensions-review nil
  "Packages and archives (\"melpa\") whose updates you review before they install."
  :type '(repeat sexp) :group 'drgnx :scope 'global :workspace 'never :agents 'never
  :schema '(list-of (or symbol string)))

(drgnx-defsetting drgnx-extensions-check-updates 'daily
  "How the Extensions view learns of updates: `daily' reads the archives in the background once a day, `manual' only
when you ask (the Refresh command)."
  :type '(choice (const daily) (const manual)) :group 'drgnx :scope 'global :workspace 'never :agents 'never
  :schema '(enum daily manual))

;;;; The status bar

(defun drgnx-extensions--segment ()
  "The `extensions' segment: how many updates wait, and a restart mark.  Cached values."
  (let ((n drgnx-extensions-list--updates) (r (length drgnx-extensions-list--restart)))
    (when (or (> n 0) (> r 0))
      (string-join (delq nil (list (and (> n 0) (format "%d update%s" n (if (= n 1) "" "s")))
                                   (and (> r 0) (concat (drgnx-face-glyph 'waiting) " restart"))))
                   " "))))

;;;; The daily check

(defun drgnx-extensions--daily-check ()
  "The check's timer: when you are idle and the catalog is a day old, start the refresh job."
  (when (and (current-idle-time) (eq drgnx-extensions-check-updates 'daily) (drgnx-extensions-list-catalog-stale-p)
             (fboundp 'drgnx-extensions-jobs-run))
    (drgnx-extensions-jobs-run 'refresh)))

(defun drgnx-extensions--start-daily-check ()
  "Look at the catalog's age every hour, the first time ten minutes from now (never at startup)."
  (drgnx-timer-start 'extensions-daily-check 600 #'drgnx-extensions--daily-check :repeat 3600))

(defun drgnx-extensions--stop-daily-check ()
  (drgnx-timer-cancel 'extensions-daily-check))

;;;; The module

(defconst drgnx-extensions--local-map '(drgnx-extensions-list . drgnx-extensions-mode-map)
  "The keymap of the list's own keys.")

(defconst drgnx-extensions--trust-map '(drgnx-extensions-trust . drgnx-extensions-trust-mode-map)
  "The keymap of a trust card.")

(defun drgnx-extensions--define-commands ()
  (pcase-dolist (`(,id ,title ,fn ,doc ,local)
                 '((extensions-open "Open Extensions" drgnx-extensions-open
                                    "Packages, plugins and modules: what is installed, what has an update, what to add" nil)
                   (extensions-search "Search Extensions" drgnx-extensions-search
                                      "Search the list as you type; @ words filter (@installed @updates @failed …)" t)
                   (extensions-details "Extension Details" drgnx-extensions-details
                                       "The page of the extension on this line; again keeps it open" t)
                   (extensions-install "Install Extension" drgnx-extensions-install
                                       "Queue the install of the package on this line" t)
                   (extensions-update "Update Extension" drgnx-extensions-update "Update the package on this line" t)
                   (extensions-update-all "Update All Extensions" drgnx-extensions-update-all
                                          "Update every package that has an update" t)
                   (extensions-uninstall "Uninstall Extension" drgnx-extensions-uninstall
                                         "Remove the package on this line; a rollback brings it back" t)
                   (extensions-toggle-project "Turn Extension On or Off Here" drgnx-extensions-toggle-project
                                              "Turn the package on this line on or off in this project" t)
                   (extensions-refresh "Refresh Extensions" drgnx-extensions-refresh
                                       "Read the archives again (a background job)" t)
                   (extensions-cancel "Cancel Extension Job" drgnx-extensions-cancel
                                      "Cancel the job or queued click of the row on this line" t)
                   (extensions-show-log "Show Extension Job Log" drgnx-extensions-show-log
                                        "The log of the job of the row on this line" t)
                   (extensions-rollback "Roll Back Packages" drgnx-extensions-rollback
                                        "Put the packages back as they were after an earlier change (a background job)" nil)
                   (extensions-restart "Restart drgnx" drgnx-restart
                                       "Restart drgnx to use what changed; asks about unsaved work first" nil)
                   (extensions-more "More About Extension" drgnx-extensions-more
                                    "Install another version, copy the name, open the repository, show the settings or the log" nil)))
    (apply #'drgnx-command-define id :category "Extensions" :title title :command fn :doc doc
           (append (and local (list :map drgnx-extensions--local-map))
                   (and (eq id 'extensions-open) (list :menu '("View"))))))
  ;; the trust card's buttons and the reviewed update's Apply: a click of yours, never an automatic path
  (drgnx-command-define 'extensions-trust-install :category "Extensions" :title "Install After the Trust Card"
                        :command #'drgnx-extensions-trust-install :map drgnx-extensions--trust-map
                        :doc "Install the package of this trust card and what it brings; the card is not shown for them again")
  (drgnx-command-define 'extensions-trust-cancel :category "Extensions" :title "Cancel the Trust Card"
                        :command #'drgnx-extensions-trust-cancel :map drgnx-extensions--trust-map
                        :doc "Close this trust card; nothing is installed")
  (drgnx-command-define 'extensions-review-apply :category "Extensions" :title "Apply Reviewed Update"
                        :command #'drgnx-extensions-trust-apply
                        :doc "Install exactly the update this page shows, as it was downloaded and checked"))

(defun drgnx-extensions--setup ()
  (drgnx-extensions-list--define-view)
  (drgnx-extensions-details--define-view)
  (drgnx-extensions--define-commands)
  (add-hook 'drgnx-extensions-jobs-changed-functions #'drgnx-extensions-list--jobs-changed)
  (when (fboundp 'drgnx-statusbar-define-segment)
    (drgnx-statusbar-define-segment 'extensions :fn #'drgnx-extensions--segment :click 'extensions-open
                                    :help "Extensions; click to open the list"))
  (when (fboundp 'drgnx-wb-place) (drgnx-wb-place "\\`\\*Extensions\\*\\'" 'editor))
  (drgnx-extensions-jobs-setup)
  (drgnx-extensions-live-setup)
  (drgnx-extensions-project-setup)
  (drgnx-extensions-trust-setup)
  (when (eq drgnx-extensions-check-updates 'daily) (drgnx-extensions--start-daily-check)))

(defun drgnx-extensions--teardown ()
  "Close the list, stop the timers and let go of the job layer's hook."
  (remove-hook 'drgnx-extensions-jobs-changed-functions #'drgnx-extensions-list--jobs-changed)
  (drgnx-extensions--stop-daily-check)
  (drgnx-extensions-trust-teardown)
  (drgnx-extensions-project-teardown)
  (drgnx-extensions-jobs-teardown)
  (dolist (b (buffer-list))
    (when (eq (buffer-local-value 'major-mode b) 'drgnx-extensions-details-mode) (kill-buffer b)))
  (drgnx-extensions-details-forget-generations)
  (drgnx-extensions-list--teardown))

(drgnx-module-define 'tools/extensions
                     :doc "Extensions: one list of packages, plugins and modules — install, update, remove, with filters and live rows."
                     :stage 'startup
                     :setup #'drgnx-extensions--setup
                     :teardown #'drgnx-extensions--teardown)

(provide 'drgnx-extensions)
;;; drgnx-extensions.el ends here
