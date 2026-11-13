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
(require 'drgnx-icons)
(require 'drgnx-pixels)
(require 'drgnx-timer)
(require 'drgnx-palette-frame)
(require 'drgnx-debug-timeline (expand-file-name "drgnx-debug-timeline" (file-name-directory (macroexp-file-name))))
(declare-function drgnx-hub-call "drgnx-hub-client")
(declare-function drgnx-hub-call-sync "drgnx-hub-client")
(defvar desktop-save-buffer)

(defface drgnx-debug-share-warning '((t :inherit drgnx-tint-warn :box nil :extend t))
  "The card's warning that a sent run holds the program's real values: the text on the warning tint.  No box: the
tint's edge (high contrast's warn ring) is the warning's rounded block (`drgnx-debug-share--blocks')." :group 'drgnx)
(defface drgnx-debug-share-warning-icon '((t :inherit warning))
  "The warning's icon." :group 'drgnx)
(defface drgnx-debug-share-code '((t :inherit (drgnx-code-small drgnx-surface-panel) :height 1.25 :weight semibold
                                     :extend t))
  "The share code on the card, on the inset surface, which reaches the card's sides." :group 'drgnx)
(defface drgnx-debug-share-code-edge '((t :inherit drgnx-surface-panel :extend t))
  "The inset surface's rows above and below the share code." :group 'drgnx)
(defface drgnx-debug-share-label '((t :inherit drgnx-text-subtle))
  "A fact's name on the card (Run, Files, To) and the footer's hint." :group 'drgnx)
(defface drgnx-debug-share-path '((t :inherit (drgnx-code-small drgnx-text-muted)))
  "A file's path on the card." :group 'drgnx)
(defface drgnx-debug-share-note '((t :inherit drgnx-text-muted))
  "The card's notes about the code." :group 'drgnx)

(defconst drgnx-debug-share-buffer "*Send Run*" "The Send Run card.")
(defconst drgnx-debug-share-width 480 "The card's width in logical pixels (send-run.html `.sr').")
(defconst drgnx-debug-share-clipboard-secs 60 "Seconds after Copy Code that the clipboard is cleared (if it still holds the code).")

(defvar-local drgnx-debug-share--card nil
  "The card's state: (:run META :path FILE :state S :code CODE :bytes N :error TEXT), S `ask', `writing', `written' or
`failed'.  The code is held only here.")

(defvar drgnx-debug-share--frame nil "The card's child frame while it shows, else nil.")

(defvar-local drgnx-debug-share--blocks nil "The card's blocks as last set (`glitnir-blocks'), or nil.")

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
  "Drop the code from the card's state and its text (the buffer is going), and the card's frame if it still shows."
  (when (and drgnx-debug-share--frame (frame-live-p drgnx-debug-share--frame))
    (delete-frame drgnx-debug-share--frame))
  (setq drgnx-debug-share--frame nil drgnx-debug-share--card nil)
  (let ((inhibit-read-only t)) (erase-buffer)))

(defun drgnx-debug-share--size (bytes)
  "BYTES as the card says it (184 KB)."
  (cond ((< bytes 1024) (format "%d bytes" bytes))
        ((< bytes (* 1024 1024)) (format "%d KB" (round bytes 1024)))
        (t (format "%.1f MB" (/ bytes 1048576.0)))))

(defun drgnx-debug-share--facts (pairs)
  "Insert PAIRS ((LABEL TEXT FACE) …) as the card's facts: the values start 72 px in (send-run.html `.facts')."
  (pcase-dolist (`(,label ,text ,face) pairs)
    (insert (propertize label 'face 'drgnx-debug-share-label)
            (propertize " " 'display `(space :align-to (,(drgnx-px 72))))
            (if face (propertize text 'face face) text)
            "\n")))

(defun drgnx-debug-share--gap (px &optional face)
  "A blank row PX logical pixels tall, in FACE when given.  Its newline is in a small font: `line-height' only raises a
row, so a row in the card's font would be that font's height whatever PX says.  Not smaller: at a tenth of the size
the font that opens draws its newline as a 1 px bar at scale 1."
  (propertize "\n" 'face `(:inherit ,face :height 0.25) 'line-height (drgnx-px px)))

(defun drgnx-debug-share--text-width ()
  "The card's text width in device pixels: its width less the padding at either side."
  (drgnx-px (- drgnx-debug-share-width 32)))

(defun drgnx-debug-share--at-right (s)
  "A space that puts S (measured in this buffer's faces) against the card's right edge, then S."
  (concat (propertize " " 'display `(space :align-to (,(- (drgnx-debug-share--text-width)
                                                          (string-pixel-width s (current-buffer))
                                                          ;; a pixel's slack, or rounding wraps S to a row of its own
                                                          (drgnx-px 2)))))
          s))

(defun drgnx-debug-share--head (icon icon-face title &optional close)
  "The card's head row: ICON in ICON-FACE, the bold TITLE, and CLOSE (a close button) at the right."
  (concat (drgnx-look-icon icon icon-face) "  " (propertize title 'face 'drgnx-ui-heading)
          (when close
            (drgnx-debug-share--at-right (drgnx-ui-close-button 'drgnx-debug-share-cancel "Close the card" :where 'text)))
          "\n"))

(defun drgnx-debug-share--space (px)
  "A space PX logical pixels wide."
  (propertize " " 'display `(space :width (,(drgnx-px px)))))

(defun drgnx-debug-share--warning ()
  "The warning on its tint (send-run.html `.warn'): 8 px above and below, the icon 10 px in, the text 8 px after it,
and its wrapped rows start under the text, not the icon.  The tint's corners are its block's (`--blocks')."
  (let* ((icon (drgnx-look-icon 'triangle-alert 'drgnx-debug-share-warning-icon))
         (indent (+ (drgnx-px 18) (string-pixel-width icon (current-buffer))))
         (face 'drgnx-debug-share-warning))
    (propertize (concat (drgnx-debug-share--gap 8 face)
                        (propertize (concat (drgnx-debug-share--space 10) icon (drgnx-debug-share--space 8)) 'face face)
                        (propertize "This run holds your program's real values, unredacted." 'face `(bold ,face))
                        (propertize " Every variable, argument and output it captured, and the files as they ran. Whoever has the file and its code can read all of it."
                                    'face face)
                        (propertize "\n" 'face face)
                        (drgnx-debug-share--gap 8 face))
                'wrap-prefix (propertize " " 'display `(space :width (,indent)) 'face face)
                'drgnx-debug-share-warning t)))

(defun drgnx-debug-share--code-rows (code)
  "CODE (groups of four joined by dashes) on the inset surface across the card (send-run.html `.code'): eight groups,
then the rest, 12 px in, 8 px above and below.  Its hairline and corners are its block's (`--blocks')."
  (let* ((groups (split-string code "-" t)) (first (seq-take groups 8)) (rest (seq-drop groups 8))
         (edge (drgnx-debug-share--gap 8 'drgnx-debug-share-code-edge))
         (row (lambda (groups)
                (propertize (concat (drgnx-debug-share--space 12) (string-join groups " ") "\n")
                            'face 'drgnx-debug-share-code))))
    (propertize (concat edge (funcall row first) (if rest (funcall row rest) "") edge)
                'drgnx-debug-share-code t)))

(defun drgnx-debug-share--footer (left &rest buttons)
  "The footer (send-run.html `.ft'): a hairline across the card, 10 px, then LEFT (a hint or a button) at the left and
BUTTONS at the right, then 10 px."
  (concat (propertize (drgnx-debug-share--gap 1) 'drgnx-debug-share-rule t)
          (drgnx-debug-share--gap 10)
          left (drgnx-debug-share--at-right (string-join buttons " ")) "\n"
          (drgnx-debug-share--gap 10)))

(defun drgnx-debug-share--block (kind prop face &rest plist)
  "A KIND block (`glitnir-blocks') over the card's text with PROP, its line in FACE, with PLIST."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((m (text-property-search-forward prop t t)))
      `(,kind ,(copy-marker (prop-match-beginning m)) ,(copy-marker (prop-match-end m) t) :ring ,face ,@plist))))

(defun drgnx-debug-share--tint-edge ()
  "The warning's edge: the tint's own ring when the theme gives one (high contrast's warn line), else the tint."
  (let ((box (face-attribute 'drgnx-tint-warn :box nil t)))
    (or (and (consp box) (stringp (plist-get box :color)) (plist-get box :color))
        (face-background 'drgnx-tint-warn nil t))))

(defun drgnx-debug-share--blocks ()
  "Give the card's windows its blocks: the warning's and the code's rounded edges (radius 6, the card's surface
outside them) and the footer's hairline."
  (dolist (b drgnx-debug-share--blocks) (set-marker (nth 1 b) nil) (set-marker (nth 2 b) nil))
  (let ((round (list :radius (drgnx-px 6) :beneath 'drgnx-surface-raised)))
    (setq drgnx-debug-share--blocks
          (delq nil (list (apply #'drgnx-debug-share--block 'ring 'drgnx-debug-share-warning
                                 (drgnx-debug-share--tint-edge) round)
                          (apply #'drgnx-debug-share--block 'ring 'drgnx-debug-share-code 'drgnx-border round)
                          (drgnx-debug-share--block 'rule 'drgnx-debug-share-rule 'drgnx-border-subtle)))))
  (dolist (w (get-buffer-window-list (current-buffer) nil t))
    (set-window-parameter w 'glitnir-blocks drgnx-debug-share--blocks)))

(defun drgnx-debug-share--run-line (run)
  "RUN's line on the card: its name, when it ended, its stops and probes."
  (let ((probes (length (plist-get run :probes))))
    (concat (or (plist-get run :name) "the run")
            (and (numberp (plist-get run :ended)) (concat " · ended " (format-time-string "%H:%M" (plist-get run :ended))))
            (format " · %d stop%s" (or (plist-get run :stops) 0) (if (eql (plist-get run :stops) 1) "" "s"))
            (if (> probes 0) (format " · %d probe%s" probes (if (= probes 1) "" "s")) ""))))

(defun drgnx-debug-share--render ()
  "Draw the card from `drgnx-debug-share--card'."
  (let* ((card drgnx-debug-share--card) (run (plist-get card :run)) (n (plist-get run :n))
         (path (abbreviate-file-name (plist-get card :path))) (inhibit-read-only t))
    (erase-buffer)
    (pcase (plist-get card :state)
      ((or 'ask 'writing 'failed)
       (insert (drgnx-debug-share--gap 16)
               (drgnx-debug-share--head 'send 'drgnx-accent (format "Send Run %s" n) t)
               (drgnx-debug-share--gap 4)
               (drgnx-debug-share--warning)
               (drgnx-debug-share--gap 10))
       (drgnx-debug-share--facts `(("Run" ,(drgnx-debug-share--run-line run) nil)
                                   ("Files" "as they ran (the launch snapshot)" nil)
                                   ("To" ,path drgnx-debug-share-path)))
       (insert (drgnx-debug-share--gap 6))
       (pcase (plist-get card :state)
         ('writing (insert (propertize "Writing…" 'face 'drgnx-debug-share-note) "\n"))
         ('failed (insert (propertize (format "Not written: %s" (plist-get card :error)) 'face 'drgnx-status-warn)
                          "\n" (drgnx-debug-share--gap 8))))
       (unless (eq (plist-get card :state) 'writing)
         (insert (drgnx-debug-share--footer
                  (propertize "drgnx sends nothing itself" 'face 'drgnx-debug-share-label)
                  (drgnx-ui-button "Cancel" 'debug-share-cancel :help "Close the card; nothing is written")
                  (drgnx-ui-button "Write File" 'debug-share-write :face 'drgnx-ui-button-primary :focus t
                                   :help "Seal the run into the file and show its share code")))))
      ('written
       (insert (drgnx-debug-share--gap 16)
               (drgnx-debug-share--head 'key 'success
                                        (format "Run %s written · %s" n
                                                (drgnx-debug-share--size (or (plist-get card :bytes) 0))))
               (drgnx-debug-share--gap 4)
               (propertize "The file opens only with this code. Note it now: it is not shown again, and drgnx keeps no copy."
                           'face 'drgnx-debug-share-note)
               "\n" (drgnx-debug-share--gap 10)
               (drgnx-debug-share--code-rows (plist-get card :code))
               (drgnx-debug-share--gap 10))
       (drgnx-debug-share--facts `(("File" ,path drgnx-debug-share-path)))
       (insert (drgnx-debug-share--gap 6)
               (propertize "Send the file however you like, and the code another way." 'face 'drgnx-debug-share-note)
               "\n" (drgnx-debug-share--gap 6)
               (drgnx-debug-share--footer
                (drgnx-ui-button (concat (drgnx-look-icon 'copy nil 14) " Copy Code") 'debug-share-copy
                                 :help (format "Copies the code; cleared from the clipboard in %d s"
                                               drgnx-debug-share-clipboard-secs))
                (drgnx-ui-button "I've Noted It" 'debug-share-noted :face 'drgnx-ui-button-primary :focus t
                                 :help "Close the card: the code is not shown again")))))
    (goto-char (point-min))
    (drgnx-debug-share--blocks))
  (drgnx-debug-share--fit))

(defun drgnx-debug-share--require-card ()
  (unless (derived-mode-p 'drgnx-debug-share-mode) (user-error "Not the Send Run card"))
  drgnx-debug-share--card)

;;;; The card's frame: a modal card over the editor



(defun drgnx-debug-share--params (parent)
  "The card's frame parameters under PARENT: it takes the focus; the modal chrome (`drgnx-palette-frame-modal-chrome':
radius 12, the modal elevation, high contrast's 2 px ring).  The card's 16 px at either side are its fringes, in the
card's surface (`drgnx-debug-share--display'); above and below, its own rows."
  `((parent-frame . ,parent) (minibuffer . nil) (name . "drgnx-send-run")
    (undecorated . t) (no-other-frame . t) (skip-taskbar . t) (unsplittable . t) (no-special-glyphs . t)
    (desktop-dont-save . t) (border-width . 0) (internal-border-width . 0)
    (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0)
    (left-fringe . ,(drgnx-px 16 parent)) (right-fringe . ,(drgnx-px 16 parent))
    (vertical-scroll-bars) (horizontal-scroll-bars) (visibility . nil)
    ,@(seq-remove (lambda (p) (eq (car p) 'transition)) (drgnx-palette-frame-modal-chrome parent))))

(defun drgnx-debug-share--fit ()
  "Size the card's frame to its text, centred over its parent's upper third."
  (when-let* ((frame drgnx-debug-share--frame) ((frame-live-p frame)) (win (frame-root-window frame))
              ((eq (window-buffer win) (current-buffer))) (parent (frame-parent frame)))
    (let* ((width (drgnx-debug-share--text-width))
           (frame-resize-pixelwise t) (window-min-height 1) (window-min-width 1))
      (set-frame-size frame width 100 t)
      (set-frame-size frame width (cdr (window-text-pixel-size win nil nil width 10000)) t)
      (set-frame-position frame (max 0 (/ (- (frame-pixel-width parent) (frame-pixel-width frame)) 2))
                          (max 0 (round (* 0.18 (frame-pixel-height parent))))))))

(defun drgnx-debug-share--display (buffer)
  "Show BUFFER as the modal card over the selected frame (a window of its own on a terminal), and give it the focus."
  (if (not (display-graphic-p))
      (pop-to-buffer buffer)
    (let* ((parent (selected-frame))
           (frame (let ((after-make-frame-functions nil) (before-make-frame-hook nil))
                    (make-frame (drgnx-debug-share--params parent)))))
      (setq drgnx-debug-share--frame frame)
      ;; the padding (the fringes) in the card's surface: this frame's own `fringe' face
      (set-face-attribute 'fringe frame :background (face-background 'drgnx-surface-raised nil t))
      (with-current-buffer buffer
        (setq-local mode-line-format nil header-line-format nil tab-line-format nil word-wrap t
                    fringe-indicator-alist '((continuation nil nil) (truncation nil nil)))
        (face-remap-add-relative 'default 'drgnx-ui-text 'drgnx-surface-raised))
      (set-window-buffer (frame-root-window frame) buffer)
      (set-window-dedicated-p (frame-root-window frame) t)
      (with-current-buffer buffer (drgnx-debug-share--blocks) (drgnx-debug-share--fit))
      (make-frame-visible frame)
      (select-frame-set-input-focus frame))))

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
    (drgnx-debug-share--display buffer)
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
  "Close the card: its frame goes (the focus back to the editor's frame), then its buffer, with the code."
  (let ((buffer (current-buffer)) (frame drgnx-debug-share--frame))
    (setq drgnx-debug-share--frame nil)
    (if (and frame (frame-live-p frame))
        (let ((parent (frame-parent frame)))
          (delete-frame frame)
          (when (frame-live-p parent) (select-frame-set-input-focus parent)))
      (when-let* ((w (get-buffer-window buffer))) (ignore-errors (quit-window nil w))))
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
