;;; drgnx-agents-cards.el --- Agents: Answer Permission Card -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A matrix card that lists its answers (a browser row's: allow once, for this session, for this plan, a wider target,
;; refuse) comes down the daemon path as a hub notice, so nothing asks there: `drgnx-hub--note-card' only keeps the
;; card's choices (`drgnx-hub--card-choices') and gives the notice this file's command with the card's id.  Answering
;; is a command you run, from the notice or the palette: it offers the card's choices with the card's body as the
;; prompt's first line, and settles the card asynchronously (`cards/settle'); the hub writes the grant the choice
;; names.  See docs/guide/security.md, "Answering a browser card".

;;; Code:
(require 'cl-lib)
(require 'drgnx-notice)
(require 'drgnx-registry)

(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-hub--card-choices-live "drgnx-hub-client")
(declare-function drgnx-hub--card-notice-id "drgnx-hub-client")
(defvar drgnx-hub--card-choices)

(defun drgnx-agents-cards--waiting ()
  "The cards waiting for an answer here, newest first (see `drgnx-hub--card-choices')."
  (and (fboundp 'drgnx-hub--card-choices-live) (drgnx-hub--card-choices-live)))

(defun drgnx-agents-cards--pick ()
  "The card to answer: the only one waiting, else the one picked by its title."
  (pcase (drgnx-agents-cards--waiting)
    ('nil (user-error "No permission card is waiting for an answer"))
    (`(,only) (car only))
    (cards (let* ((names (mapcar (lambda (e) (cons (format "%d: %s" (car e) (plist-get (cdr e) :title)) (car e)))
                                 cards)))
             (cdr (assoc (completing-read "Card: " names nil t) names))))))

(defun drgnx-agents-answer-card (card)
  "Answer the permission card CARD: pick one of the answers it lists (allow once, for this session, for this plan, a
wider target, or refuse); the hub settles the card and writes the grant the answer names.  Asked for when several
cards wait.  The call does not wait: the answer is said when the hub has it."
  (interactive (list (drgnx-agents-cards--pick)))
  (let* ((entry (or (cdr (assq card (drgnx-agents-cards--waiting)))
                    (user-error "Card %s is not waiting for an answer" card)))
         (choices (plist-get entry :choices))
         (body (plist-get entry :body))
         (prompt (concat (and body (concat body "\n"))
                         (or (plist-get entry :title) (format "Card %d" card)) ": "))
         (label (completing-read prompt (mapcar #'cdr choices) nil t))
         (choice (car (rassoc label choices))))
    (unless choice (user-error "Not one of the card's answers"))
    (drgnx-hub-call "cards/settle" (list :card card :choice choice)
                    (lambda (result err) (drgnx-agents-cards--settled card label result err)))
    choice))

(defun drgnx-agents-cards--settled (card label result err)
  "The hub's answer to settling CARD with LABEL (RESULT, or ERR): the card's notice and its kept choices go; an error
is said and the card stays."
  (if err
      (message "Card %d was not answered: %s" card err)
    (drgnx-notice-clear 'hub (drgnx-hub--card-notice-id card))
    (setq drgnx-hub--card-choices (assq-delete-all card drgnx-hub--card-choices))
    (if (plist-get result :settled)
        (message "Card %d: %s" card label)
      (message "Card %d had been answered already" card))))

(defun drgnx-agents-browser-check--summary (result)
  "One line for RESULT, the hub's answer to `browser/check'."
  (if (plist-get result :ok)
      (format "ok: the browser started in %d ms, a screenshot of %d bytes%s"
              (or (plist-get result :start_ms) 0) (or (plist-get result :screenshot_bytes) 0)
              (if-let* ((peak (plist-get result :peak_bytes)))
                  (format ", peak memory %d MiB" (/ peak 1048576))
                ""))
    (format "failed: %s" (or (plist-get result :why) "unknown"))))

(defun drgnx-agents-browser-check ()
  "Start a throwaway session with the agent browser, take a screenshot in it and say how it went.  The hub keeps the
result, which `drgnx doctor' shows on its agent-browser line.  It takes a few seconds, up to 45; the call does not wait."
  (interactive)
  (message "Checking the agent browser (up to 45 s)...")
  (drgnx-hub-call "browser/check" nil
                  (lambda (result err)
                    (if err
                        (message "Agent browser check: the hub gave no answer: %s" err)
                      (message "Agent browser check %s" (drgnx-agents-browser-check--summary result))))
                  :deadline 50))

(defun drgnx-agents-cards-register-commands ()
  "The permission card commands (`drgnx--core-commands' calls this)."
  (drgnx-command-define 'agents-browser-check :category "Agents" :title "Agents: Check the Agent Browser"
                        :command #'drgnx-agents-browser-check
                        :doc "Run a throwaway browser session and take a screenshot in it; the doctor's agent-browser line shows the result")
  (drgnx-command-define 'agents-answer-card :category "Agents" :title "Agents: Answer Permission Card"
                        :command #'drgnx-agents-answer-card
                        :doc "Answer a permission card that lists its answers (the agent browser's): once, this session, this plan, a wider target, or refuse"))

(provide 'drgnx-agents-cards)
;;; drgnx-agents-cards.el ends here
