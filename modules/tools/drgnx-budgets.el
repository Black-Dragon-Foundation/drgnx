;;; drgnx-budgets.el --- The Budgets page: the meters and the scope tree, limits set in place (library of tools/agent-panel) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The hub builds the rows (`budgets/page/subscribe', runtime/crates/drgnx-ratatoskr/src/view/budgets.rs): the
;; subscriptions' meters with their pace, then every budget scope as a tree (meter, spent per unit, the limit cell,
;; forecast, burn, state, a run's share of its plan).  This library is the editor tab they land in and its commands: a
;; limit cell's new amount asks `budget/set' for that scope alone, and RET on a row selects its item in Work.  Loaded
;; by tools/agent-panel (drgnx-agent-panel.el); defines no module.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-registry)
(require 'drgnx-hub-client)

(declare-function drgnx-view-patch-attach "drgnx-view")
(declare-function drgnx-view-env-register "drgnx-view-env")
(declare-function drgnx-view-env-unregister "drgnx-view-env")
(declare-function drgnx-wb-rows-setup "drgnx-wb")
(declare-function drgnx-work-select "drgnx-work-map" (kind id))
(defvar drgnx-hub--events)

(defconst drgnx-budgets-view-id "budgets" "The hub-fed view of the Budgets page.")
(defconst drgnx-budgets-buffer-name "*Budgets*" "The page's buffer.")

(defun drgnx-budgets--hub-p ()
  (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events)))

(defun drgnx-budgets--call (method params &optional then)
  "Ask the hub METHOD with PARAMS; THEN gets the result.  Nothing waits."
  (drgnx-hub-call method params
                  (lambda (result error)
                    (if error (message "Budgets: %s" (if (stringp error) error (plist-get error :message)))
                      (when then (funcall then result))))))

(defun drgnx-budgets--subscribe (&optional _view)
  "Tell the hub the page shows (at attach, and again on a reconnect)."
  (when (drgnx-budgets--hub-p)
    (drgnx-budgets--call "budgets/page/subscribe" (list :view drgnx-budgets-view-id))))

(defvar drgnx-budgets-mode-map (make-sparse-keymap) "Keys of the Budgets page (the key profiles bind them).")

(define-derived-mode drgnx-budgets-mode special-mode "Budgets"
  "The Budgets page: the subscriptions' meters, then every budget scope (the hub builds the rows)."
  (setq-local truncate-lines t cursor-type nil)
  (buffer-disable-undo)
  (when (fboundp 'drgnx-wb-rows-setup) (drgnx-wb-rows-setup)))

(defun drgnx-budgets--buffer ()
  "The page's buffer, attached as the hub-fed view the first time."
  (or (get-buffer drgnx-budgets-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-budgets-buffer-name)
        (drgnx-budgets-mode)
        (if (not (fboundp 'nidhogg-view--call))
            (let ((inhibit-read-only t))
              (insert (propertize "  The Budgets page needs drgnx's own Emacs (Nidhogg).\n" 'face 'shadow)))
          (drgnx-view-patch-attach drgnx-budgets-view-id "unshown" :sja t)
          (require 'drgnx-view-env)
          (drgnx-view-env-register drgnx-budgets-view-id (current-buffer) #'drgnx-budgets--subscribe)
          (drgnx-budgets--subscribe))
        (current-buffer))))

(defun drgnx-budgets-open ()
  "Show the Budgets page in the selected window."
  (interactive)
  (switch-to-buffer (drgnx-budgets--buffer)))

(defun drgnx-budgets-refresh ()
  "Read the scopes and the meters again."
  (interactive)
  (when (get-buffer drgnx-budgets-buffer-name)
    (drgnx-budgets--call "budgets/page/set" (list :view drgnx-budgets-view-id :refresh t))))

(defun drgnx-budgets-set-limit (scope unit amount)
  "Set SCOPE's (KIND ID) limit in UNIT to AMOUNT with `budget/set': that one limit, nothing else."
  (drgnx-budgets--call "budget/set"
                       (list :scope (list (intern (concat ":" (car scope))) (cadr scope))
                             :limits (vector (list :unit unit :amount amount)))
                       (lambda (_) (drgnx-budgets-refresh))))

(defun drgnx-budgets-select (scope)
  "Select SCOPE's (KIND ID) item in Work: a plan, a spec, a task, a run's job, a session."
  (pcase-let ((`(,kind ,id) scope))
    (drgnx-work-select (pcase kind ("run" "job") ((or "manager" "worker") "agent") (_ kind)) id)))

(defun drgnx-budgets--scope-at-point ()
  (when-let* ((s (get-text-property (point) 'drgnx-budget-scope))) (append s nil)))

(defun drgnx-budgets-edit-limit ()
  "Edit the limit cell of the scope at point: the new amount goes to the hub at once."
  (interactive)
  (let* ((cell (or (cl-loop for p from (pos-bol) below (pos-eol)
                            for a = (get-text-property p 'drgnx-action)
                            when (and a (equal (elt a 0) "budget-limit")) return (append a nil))
                   (user-error "No scope on this row")))
         (amount (read-number (format "Limit of %s (%s): " (nth 2 cell) (nth 3 cell)))))
    (drgnx-budgets-set-limit (list (nth 1 cell) (nth 2 cell)) (nth 3 cell) (float amount))))

(defun drgnx-budgets-select-at-point ()
  "Select the scope on this row in Work."
  (interactive)
  (drgnx-budgets-select (or (drgnx-budgets--scope-at-point) (user-error "No scope on this row"))))

(defun drgnx-budgets-setup ()
  "tools/agent-panel's setup: the Budgets commands."
  (drgnx-command-define 'budgets-open :category "Budgets" :title "Open" :command #'drgnx-budgets-open
                        :doc "The subscriptions' meters and every budget scope, limits edited in place")
  (drgnx-command-define 'budgets-refresh :category "Budgets" :title "Refresh" :command #'drgnx-budgets-refresh
                        :doc "Read the scopes and the meters again")
  (drgnx-command-define 'budgets-edit-limit :category "Budgets" :title "Edit Limit" :command #'drgnx-budgets-edit-limit
                        :map 'drgnx-budgets-mode-map :doc "Set the limit of the scope on this row")
  (drgnx-command-define 'budgets-select :category "Budgets" :title "Select in Work"
                        :command #'drgnx-budgets-select-at-point :map 'drgnx-budgets-mode-map
                        :doc "Select the scope on this row in Work"))

(defun drgnx-budgets-teardown ()
  "Turning tools/agent-panel off: the page's buffer goes (the hub forgets the view with it)."
  (when (get-buffer drgnx-budgets-buffer-name)
    (when (drgnx-budgets--hub-p)
      (drgnx-budgets--call "budgets/page/close" (list :view drgnx-budgets-view-id)))
    (when (fboundp 'drgnx-view-env-unregister) (drgnx-view-env-unregister drgnx-budgets-view-id))
    (kill-buffer drgnx-budgets-buffer-name)))

(provide 'drgnx-budgets)
;;; drgnx-budgets.el ends here
