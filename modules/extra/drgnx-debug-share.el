;;; drgnx-debug-share.el --- Debugging: Send Run and Open Sent Run -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The editor's half of sending a recorded run (docs/guide/debugging.md, "Sending a run"; the hub's `debug/run/export'
;; and `debug/run/import').
;;
;; - Send Run… shows a card before anything is written: the run holds the program's real values, unredacted.  Write
;;   File asks the hub to seal the run into the file; the card then shows the share code, once.  The code lives only in
;;   the card's buffer (undo off, never auto-saved or saved by desktop, the region commands copy nothing from it) and is
;;   dropped when the card closes, which only "I've Noted It" does without asking.  Copy Code puts it on the clipboard,
;;   never in the kill ring, and clears the clipboard 60 s later if it still holds the code.
;; - Open Sent Run… asks for the file and the code (hidden, no history) and adds the run to this project's runs; the
;;   strip then shows it, marked Sent and read-only (no forks: its program is the sender's).

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-ui-kit)
(require 'drgnx-timer)
(require 'drgnx-debug-timeline (expand-file-name "drgnx-debug-timeline" (file-name-directory (macroexp-file-name))))
(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-hub-call-sync "drgnx-hub-client")
(defvar desktop-save-buffer)

(defface drgnx-debug-share-warning '((t :inherit drgnx-chip-warn))
  "The card's warning that a sent run holds the program's real values." :group 'drgnx)
(defface drgnx-debug-share-code '((t :inherit (bold fixed-pitch)))
  "The share code on the card." :group 'drgnx)
(defface drgnx-debug-share-label '((t :inherit drgnx-text-subtle))
  "A fact's name on the card (Run, Files, To)." :group 'drgnx)

(defconst drgnx-debug-share-buffer "*Send Run*" "The Send Run card.")
(defconst drgnx-debug-share-clipboard-secs 60 "Seconds after Copy Code that the clipboard is cleared (if it still holds the code).")

(defvar-local drgnx-debug-share--card nil
  "The card's state: (:run META :path FILE :state S :code CODE :bytes N :error TEXT), S `ask', `writing', `written' or
`failed'.  The code is held only here.")

;;;; The card

(defun drgnx-debug-share--no-copy ()
  "The region commands in the card: the code is copied only by Copy Code."
  (interactive)
  (user-error "Nothing is copied from this card: use Copy Code"))

(defvar drgnx-debug-share-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [remap kill-ring-save] #'drgnx-debug-share--no-copy)
    (define-key m [remap kill-region] #'drgnx-debug-share--no-copy)
    (define-key m [remap copy-region-as-kill] #'drgnx-debug-share--no-copy)
    (define-key m [remap clipboard-kill-ring-save] #'drgnx-debug-share--no-copy)
    (define-key m [remap clipboard-kill-region] #'drgnx-debug-share--no-copy)
    m)
  "The card's keys (key profiles: `:map drgnx-debug-share-mode-map').  The region commands copy nothing.")

(define-derived-mode drgnx-debug-share-mode special-mode "Send Run"
  "The Send Run card."
  :group 'drgnx
  (buffer-disable-undo)
  (setq-local buffer-auto-save-file-name nil
              desktop-save-buffer nil
              filter-buffer-substring-function (lambda (&rest _) "")
              truncate-lines nil
              cursor-type nil)
  (add-hook 'kill-buffer-hook #'drgnx-debug-share--forget nil t))

(defun drgnx-debug-share--forget ()
  "Drop the code from the card's state and its text (the buffer is going)."
  (setq drgnx-debug-share--card nil)
  (let ((inhibit-read-only t)) (erase-buffer)))

(defun drgnx-debug-share--size (bytes)
  "BYTES as the card says it (184 KB)."
  (cond ((< bytes 1024) (format "%d bytes" bytes))
        ((< bytes (* 1024 1024)) (format "%d KB" (round bytes 1024)))
        (t (format "%.1f MB" (/ bytes 1048576.0)))))

(defun drgnx-debug-share--facts (pairs)
  "Insert PAIRS ((LABEL . TEXT) …) as the card's facts."
  (pcase-dolist (`(,label . ,text) pairs)
    (insert (propertize (string-pad label 7) 'face 'drgnx-debug-share-label) text "\n")))

(defun drgnx-debug-share--run-line (run)
  "RUN's line on the card: its name, when it ended, its stops and probes."
  (let ((probes (length (plist-get run :probes))))
    (concat (or (plist-get run :name) "the run")
            (and (numberp (plist-get run :ended)) (format-time-string " · ended %H:%M" (plist-get run :ended)))
            (format " · %d stop%s" (or (plist-get run :stops) 0) (if (eql (plist-get run :stops) 1) "" "s"))
            (if (> probes 0) (format " · %d probe%s" probes (if (= probes 1) "" "s")) ""))))

(defun drgnx-debug-share--render ()
  "Draw the card from `drgnx-debug-share--card'."
  (let* ((card drgnx-debug-share--card) (run (plist-get card :run)) (n (plist-get run :n))
         (path (abbreviate-file-name (plist-get card :path))) (inhibit-read-only t))
    (erase-buffer)
    (pcase (plist-get card :state)
      ((or 'ask 'writing 'failed)
       (insert (propertize (format "Send Run %s" n) 'face 'bold) "\n\n")
       (insert (propertize "This run holds your program's real values, unredacted." 'face '(bold drgnx-debug-share-warning))
               (propertize " Every variable, argument and output it captured, and the files as they ran.  Whoever has the file and its code can read all of it."
                           'face 'drgnx-debug-share-warning)
               "\n\n")
       (drgnx-debug-share--facts `(("Run" . ,(drgnx-debug-share--run-line run))
                                   ("Files" . "as they ran (the launch snapshot)")
                                   ("To" . ,path)))
       (insert "\n")
       (pcase (plist-get card :state)
         ('writing (insert (propertize "Writing…" 'face 'drgnx-text-muted) "\n"))
         ('failed (insert (propertize (format "Not written: %s" (plist-get card :error)) 'face 'drgnx-status-warn) "\n\n")))
       (unless (eq (plist-get card :state) 'writing)
         (insert (propertize "drgnx sends nothing itself  " 'face 'drgnx-text-subtle)
                 (drgnx-ui-button "Cancel" 'debug-share-cancel :help "Close the card; nothing is written")
                 " "
                 (drgnx-ui-button "Write File" 'debug-share-write :face 'drgnx-ui-button-primary
                                  :help "Seal the run into the file and show its share code")
                 "\n")))
      ('written
       (insert (propertize (format "Run %s written · %s" n (drgnx-debug-share--size (or (plist-get card :bytes) 0)))
                           'face 'bold)
               "\n\n"
               "The file opens only with this code.  Note it now: it is not shown again, and drgnx keeps no copy.\n\n"
               (propertize (string-replace "-" " " (plist-get card :code)) 'face 'drgnx-debug-share-code)
               "\n\n")
       (drgnx-debug-share--facts `(("File" . ,path)))
       (insert "\nSend the file however you like, and the code another way.\n\n"
               (drgnx-ui-button "Copy Code" 'debug-share-copy
                                :help (format "Copies the code; cleared from the clipboard in %d s"
                                              drgnx-debug-share-clipboard-secs))
               "  "
               (drgnx-ui-button "I've Noted It" 'debug-share-noted :face 'drgnx-ui-button-primary
                                :help "Close the card: the code is not shown again")
               "\n")))
    (goto-char (point-min))))

(defun drgnx-debug-share--require-card ()
  (unless (derived-mode-p 'drgnx-debug-share-mode) (user-error "Not the Send Run card"))
  drgnx-debug-share--card)

;;;; Commands

(defun drgnx-debug-share--default-run ()
  "The run Send Run offers: the strip's, else this project's newest ended run (its record)."
  (let* ((root (drgnx-debug-timeline--root))
         (runs (append (plist-get (drgnx-hub-call-sync "debug/runs/list" (list :root root) 5) :runs) nil))
         (ended (seq-filter (lambda (r) (plist-get r :ended)) runs)))
    (or (and drgnx-debug-timeline--run (seq-find (lambda (r) (equal (plist-get r :id) drgnx-debug-timeline--run)) ended))
        (car ended)
        (user-error "No ended run in %s to send" (abbreviate-file-name root)))))

(defun drgnx-debug-share--default-file (run)
  "RUN's file name: its name and number, `.drgnx-run'."
  (format "%s-run%s.drgnx-run"
          (let ((s (replace-regexp-in-string "[^[:alnum:]]+" "-" (downcase (or (plist-get run :name) "debug")))))
            (string-trim s "-" "-"))
          (plist-get run :n)))

(defun drgnx-debug-send-run (run path)
  "Show the Send Run card for RUN (its record) to be written to PATH; nothing is written until Write File.
Interactively RUN is the strip's run, else the project's newest ended run, and PATH is asked."
  (interactive
   (let* ((run (drgnx-debug-share--default-run))
          (path (expand-file-name (read-file-name "Write the run to: " nil nil nil
                                                  (drgnx-debug-share--default-file run)))))
     (when (and (file-exists-p path) (not (yes-or-no-p (format "%s exists.  Replace it? " (abbreviate-file-name path)))))
       (user-error "Not sent"))
     (list run path)))
  (let ((buffer (get-buffer-create drgnx-debug-share-buffer)))
    (with-current-buffer buffer
      (drgnx-debug-share-mode)
      (setq drgnx-debug-share--card (list :run run :path path :state 'ask))
      (drgnx-debug-share--render))
    (pop-to-buffer buffer)
    buffer))

(defun drgnx-debug-share-write ()
  "Write File on the card: the hub seals the run into the file and answers with the share code."
  (interactive)
  (let ((card (drgnx-debug-share--require-card)) (buffer (current-buffer)))
    (unless (memq (plist-get card :state) '(ask failed)) (user-error "The run is already written"))
    (setq drgnx-debug-share--card (plist-put card :state 'writing))
    (drgnx-debug-share--render)
    (drgnx-hub-call "debug/run/export" (list :run (plist-get (plist-get card :run) :id) :path (plist-get card :path))
                    (lambda (result error)
                      (when (buffer-live-p buffer)
                        (with-current-buffer buffer
                          (setq drgnx-debug-share--card
                                (if error
                                    (plist-put (plist-put drgnx-debug-share--card :state 'failed)
                                               :error (or (plist-get error :message) (format "%s" error)))
                                  (plist-put (plist-put (plist-put drgnx-debug-share--card :state 'written)
                                                        :code (plist-get result :code))
                                             :bytes (plist-get result :bytes))))
                          (drgnx-debug-share--render)))))))

(defun drgnx-debug-share--close ()
  (let ((buffer (current-buffer)))
    (when-let* ((w (get-buffer-window buffer))) (ignore-errors (quit-window nil w)))
    (kill-buffer buffer)))

(defun drgnx-debug-share-cancel ()
  "Close the card.  Before the run is written nothing is; after, it asks first, since the code is not shown again."
  (interactive)
  (let ((card (drgnx-debug-share--require-card)))
    (when (or (not (eq (plist-get card :state) 'written))
              (yes-or-no-p "Close the card?  The share code is not shown again "))
      (drgnx-debug-share--close))))

(defun drgnx-debug-share-noted ()
  "I've Noted It: close the card; the code goes with it."
  (interactive)
  (drgnx-debug-share--require-card)
  (drgnx-debug-share--close))

(defun drgnx-debug-share--clear-clipboard (hash)
  "Clear the clipboard if it still holds the code whose sha256 is HASH (never someone else's later copy)."
  (let ((now (ignore-errors (gui-get-selection 'CLIPBOARD))))
    (when (and (stringp now) (equal (secure-hash 'sha256 (substring-no-properties now)) hash))
      (gui-set-selection 'CLIPBOARD ""))))

(defun drgnx-debug-share-copy ()
  "Copy Code: the code on the clipboard (not the kill ring), cleared after `drgnx-debug-share-clipboard-secs'."
  (interactive)
  (let ((code (plist-get (drgnx-debug-share--require-card) :code)))
    (unless code (user-error "No code yet: write the file first"))
    (gui-set-selection 'CLIPBOARD (copy-sequence code))
    (drgnx-timer-start 'debug-share-clipboard drgnx-debug-share-clipboard-secs #'drgnx-debug-share--clear-clipboard
                       ;; the core owns it: the clipboard is cleared even if Debug is turned off meanwhile
                       :args (list (secure-hash 'sha256 code)) :owner :core)
    (message "Code copied; the clipboard is cleared in %d s" drgnx-debug-share-clipboard-secs)))

(defun drgnx-debug-open-sent-run (path code)
  "Add the run someone sent (PATH, opened with the share CODE) to this project's runs and show it, read-only.
Interactively both are asked; the code is hidden as typed and kept in no history."
  (interactive
   (let ((path (expand-file-name (read-file-name "Open sent run: " nil nil t))))
     (list path (read-passwd (format "Share code for %s: " (file-name-nondirectory path))))))
  (let ((root (drgnx-debug-timeline--root)))
    (drgnx-hub-call "debug/run/import" (list :root root :path path :code code)
                    (lambda (result error)
                      (if error
                          (message "Not opened: %s" (or (plist-get error :message) error))
                        (drgnx-debug-timeline-show (plist-get result :run)))))))

(defconst drgnx-debug-share-commands
  '((debug-send-run "Send Run…" drgnx-debug-send-run "Write an ended run, with the files that ran, into one encrypted file opened by a one-time code")
    (debug-open-sent-run "Open Sent Run…" drgnx-debug-open-sent-run "Add a run someone sent you (its file and code) to this project's runs, read-only")
    (debug-share-write "Write File" drgnx-debug-share-write "Seal the run into the file and show its share code")
    (debug-share-cancel "Cancel Send Run" drgnx-debug-share-cancel "Close the Send Run card")
    (debug-share-copy "Copy Code" drgnx-debug-share-copy "Copies the code; cleared from the clipboard in 60 s")
    (debug-share-noted "I've Noted It" drgnx-debug-share-noted "Close the card: the code is not shown again"))
  "The commands of sending a run: (ID TITLE FUNCTION DOC).  The last four are the card's.")

(provide 'drgnx-debug-share)
;;; drgnx-debug-share.el ends here
