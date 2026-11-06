;;; drgnx-search-setup.el --- Semantic Search: set it up -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Set Up Semantic Search wizard (docs/guide/search.md, "Setting up"), a client of the hub's `search/*' methods:
;;
;; - `drgnx-search-setup-detect': what the non-interactive onboarding step reports.  Looks, never starts the hub,
;;   never asks, changes nothing.
;; - `drgnx-search-setup': the wizard behind the command and onboarding step 5.  It shows what is present, offers to
;;   download the built-in model (saying its size), offers a server only when this machine can run one, and indexes
;;   the project in the background (or runs a test query when the index is current).  It asks (`y-or-n-p') only
;;   in a frame, for a command the user ran; anywhere else it says how to run it and starts nothing.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-frame-kind)
(declare-function project-current "project")
(declare-function project-root "project")
(declare-function drgnx-hub-call-sync "drgnx-hub-client")
(declare-function drgnx-hub-ensure "drgnx-hub-client")
(declare-function drgnx-hub-running-p "drgnx-hub-client")
(declare-function drgnx-settings-defaults-save "drgnx-settings-defaults")
(declare-function drgnx-settings-runtime-changed "drgnx-settings-runtime")
(declare-function drgnx-ai-set-role "drgnx-ai")
(declare-function drgnx-ai-user-role "drgnx-ai")

(defconst drgnx-search-setup-test-query "where does the program start"
  "The question of the wizard's test query.")

(defconst drgnx-search-setup-guard-text
  "run M-x Set Up Semantic Search in a frame to download a model or start a server"
  "What the wizard answers where it may not ask: a daemon with no frame, a batch Emacs, a call that is not a command.")

(defun drgnx-search-setup--current-root ()
  "The current project's root without a trailing slash, or nil.  Never asks."
  (require 'project)
  (when-let* ((project (ignore-errors (project-current nil))))
    (directory-file-name (expand-file-name (project-root project)))))

;;;; What is present

(defun drgnx-search-setup--mb (bytes)
  "BYTES as whole megabytes, at least 1."
  (max 1 (round (/ (float (or bytes 0)) 1048576))))

(defun drgnx-search-setup--present (embedders)
  "EMBEDDERS (the answer of `search/embedders') as one sentence: the built-in model's state and the servers."
  (let* ((builtin (plist-get embedders :builtin)) (state (or (plist-get builtin :state) "unknown"))
         (servers (plist-get embedders :servers)) (device (plist-get builtin :device)))
    (concat (format "built-in model %s %s" (plist-get builtin :model)
                    (pcase state
                      ("ready" (if device (format "ready (%s %s)" (upcase (or (plist-get device :kind) "")) (plist-get device :name))
                                 "ready"))
                      ("missing" (format "not downloaded (%d MB)" (drgnx-search-setup--mb (plist-get builtin :bytes))))
                      ("partial" "partly downloaded")
                      ("downloading" "downloading")
                      ("corrupt" "corrupt: it is downloaded again on yes")
                      (_ state)))
            (if servers
                (format "; servers: %s" (mapconcat (lambda (s) (format "%s %s" (plist-get s :kind)
                                                                       (if (plist-get s :answering) "answering" "not answering")))
                                                   servers ", "))
              "; no server"))))

(defun drgnx-search-setup--why (err)
  "ERR (a signal's data) as the sentence the wizard says when the hub cannot be asked."
  (format "the drgnx hub is not available (%s)" (error-message-string err)))

(defun drgnx-search-setup-detect ()
  "What the non-interactive onboarding step reports: (STATUS MESSAGE).  Looks at the hub if it runs; never starts it,
never asks and changes nothing."
  (condition-case err
      (progn
        (require 'drgnx-hub-client)
        (if (not (drgnx-hub-running-p))
            (list 'info "the hub is not running: semantic search lives in it and starts with it; run Set Up Semantic Search in a frame")
          (let* ((e (drgnx-hub-call-sync "search/embedders" nil 3))
                 (ready (or (equal (plist-get (plist-get e :builtin) :state) "ready")
                            (seq-some (lambda (s) (plist-get s :answering)) (plist-get e :servers)))))
            (list (if ready 'ok 'info)
                  (concat (drgnx-search-setup--present e)
                          (unless ready "; run Set Up Semantic Search in a frame to download the model"))))))
    (error (list 'info (drgnx-search-setup--why err)))))

;;;; Where it may ask

(defun drgnx-search-setup--frame-p ()
  "Non-nil when a frame of a terminal or a window system exists to ask in (a daemon's own is not one)."
  (seq-some #'drgnx-state-workbench-frame-p (frame-list)))

(defun drgnx-search-setup--may-ask-p (interactive)
  "Non-nil when the wizard may ask and start things: INTERACTIVE (a command the user ran), not in batch, and in a
daemon only with a frame."
  (and interactive (not noninteractive) (not (bound-and-true-p inhibit-interaction))
       (or (not (daemonp)) (drgnx-search-setup--frame-p))))

;;;; Servers

(defun drgnx-search-setup--provider (entry)
  "The hub's provider ENTRY (:id :kind :base :auth :caps) as an entry of `drgnx-ai-providers'."
  (let ((id (intern (plist-get entry :id))))
    (append (list id :name (plist-get entry :id) :kind (intern (plist-get entry :kind)) :url (plist-get entry :base)
                  :caps (mapcar #'intern (plist-get entry :caps)))
            (and (not (member (plist-get entry :auth) '(nil "none"))) (list :auth (intern (plist-get entry :auth)))))))

(defun drgnx-search-setup--add-provider (entry)
  "Add the hub's provider ENTRY to the user's providers (settings.el) and tell the hub.  The hub writes no settings."
  (require 'drgnx-ai)
  (let* ((p (drgnx-search-setup--provider entry))
         (providers (append (seq-remove (lambda (q) (eq (car q) (car p))) (default-value 'drgnx-ai-providers))
                            (list p))))
    (drgnx-settings-defaults-save 'drgnx-ai-providers providers)
    (require 'drgnx-settings-runtime)
    (drgnx-settings-runtime-changed)))

(defun drgnx-search-setup--server-plan (embedders)
  "The first server plan that says it is available, as (KIND . PLAN), or nil.  Nothing is offered while a server
already answers: the built-in model needs none, and a server is a choice."
  (unless (seq-some (lambda (s) (plist-get s :answering)) (plist-get embedders :servers))
    (seq-some (lambda (kind)
                (let ((plan (drgnx-hub-call-sync "search/server-plan" (list :kind kind) 5)))
                  (and (plist-get plan :available) (cons kind plan))))
              '("tei" "ollama"))))

(defun drgnx-search-setup--ask-server (kind plan)
  "Ask whether to start the server of KIND as PLAN says (its commands, memory cap and GPU); non-nil on yes."
  (y-or-n-p (format "Start %s for semantic search%s? It would run: %s.%s%s "
                    (if (equal kind "tei") "Text Embeddings Inference (a container)" "Ollama")
                    (if (plist-get plan :model) (format " with %s" (plist-get plan :model)) "")
                    (string-join (plist-get plan :commands) "; ")
                    (if (and (plist-get plan :memory_cap) (not (string-empty-p (plist-get plan :memory_cap))))
                        (format " Memory cap %s." (plist-get plan :memory_cap)) "")
                    (if (plist-get plan :gpu) " The GPU image would run." ""))))

(defun drgnx-search-setup--start-server (kind plan)
  "Start the server of KIND after the user confirmed PLAN, add its provider to the settings, tell the hub; a sentence."
  (let ((started (drgnx-hub-call-sync "search/server-start" (list :kind kind :confirm t) 60)))
    (drgnx-search-setup--add-provider (plist-get started :provider))
    (when (equal kind "ollama")
      (require 'drgnx-ai)
      (drgnx-ai-set-role 'embed (cons (cons (intern (plist-get (plist-get started :provider) :id)) (plist-get plan :model))
                                      (drgnx-ai-user-role 'embed))))
    (format "started %s (%s)" kind (plist-get started :unit))))

;;;; The wizard

(defun drgnx-search-setup--index-step (root)
  "The last step for the project at ROOT: a test query when its index is current, else the hub indexes it in the
background; a sentence."
  (let* ((status (drgnx-hub-call-sync "search/status" (list :root root) 10))
         (current (and (> (or (plist-get status :chunks) 0) 0) (plist-get status :models)
                       (eql 0 (plist-get (plist-get status :lag) :chunks_behind))))
         (name (abbreviate-file-name root)))
    (if (not current)
        (progn (drgnx-hub-call-sync "search/index" (list :root root) 10)
               (format "%s is being indexed in the background — Index Status shows how far it is" name))
      (let ((hit (car (plist-get (drgnx-hub-call-sync "search/query" (list :root root :text drgnx-search-setup-test-query :k 1) 20)
                                 :hits))))
        (if hit
            (format "%s is indexed (%d chunks); test query \"%s\": %s:%d" name (plist-get status :chunks)
                    drgnx-search-setup-test-query (plist-get hit :path) (plist-get hit :line_start))
          (format "%s is indexed (%d chunks), but the test query found nothing" name (plist-get status :chunks)))))))

(defun drgnx-search-setup--run (root)
  "The wizard's steps (the caller has checked it may ask): (STATUS MESSAGE)."
  (require 'drgnx-hub-client)
  (drgnx-hub-ensure)
  (let* ((embedders (drgnx-hub-call-sync "search/embedders" nil 5))
         (builtin (plist-get embedders :builtin))
         (state (plist-get builtin :state))
         (notes (list (drgnx-search-setup--present embedders)))
         (status 'ok))
    ;; the built-in model: asked for, with its size
    (when (member state '("missing" "partial" "corrupt"))
      (if (y-or-n-p (format "Download %s (%d MB) for semantic search? It runs on this machine, on the GPU when one is fast enough. "
                            (plist-get builtin :model) (drgnx-search-setup--mb (plist-get builtin :bytes))))
          (progn (drgnx-hub-call-sync "search/model-download"
                                      (list :model (plist-get builtin :model) :consent (list :bytes (plist-get builtin :bytes))) 10)
                 (push (format "downloading %s in the background" (plist-get builtin :model)) notes))
        (push "the model stays undownloaded: keyword and symbol search only" notes)
        (setq status 'info)))
    ;; a server, only when this machine can run one
    (when-let* ((offer (drgnx-search-setup--server-plan embedders)))
      (if (drgnx-search-setup--ask-server (car offer) (cdr offer))
          (push (drgnx-search-setup--start-server (car offer) (cdr offer)) notes)
        (push "no server started" notes)))
    ;; the project
    (push (if root (drgnx-search-setup--index-step root)
            "open a project and run Set Up Semantic Search there to index it")
          notes)
    (list status (string-join (nreverse notes) "; "))))

(cl-defun drgnx-search-setup (root &key interactive)
  "Set up Semantic Search for the project at ROOT (nil: only the model and a server): (STATUS MESSAGE).
INTERACTIVE: a command the user ran.  Only then, and only in a frame, does it ask; anywhere else it answers
`drgnx-search-setup-guard-text' and starts nothing."
  (if (not (drgnx-search-setup--may-ask-p interactive))
      (list 'info drgnx-search-setup-guard-text)
    (condition-case err
        (drgnx-search-setup--run (and root (directory-file-name (expand-file-name root))))
      (quit (list 'info "set up cancelled"))
      (error (list 'warn (drgnx-search-setup--why err))))))

(provide 'drgnx-search-setup)
;;; drgnx-search-setup.el ends here
