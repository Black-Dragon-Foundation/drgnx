;;; drgnx-debug-timeline.el --- Recorded runs: probes, the stop timeline, past stops -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The editor's half of recorded runs (docs/guide/debugging.md, "Recorded runs"; docs/develop/debugging.md).  The hub
;; records every debug session against a snapshot of the files that ran; this file shows it.
;;
;; - **Probes**: a logpoint whose values are recorded, never printed.  Its glyph (a ring with a dot) sits in a column of
;;   the left margin claimed through `drgnx-margins' (`debug-probe', after the breakpoint column), and its newest values
;;   show as a sparkline at the line's end.  "Probe the Result" puts the probe on the line after an assignment, where
;;   the assigned value exists (a logpoint runs before its line).
;; - **The stop timeline**: a strip of the run's stops and one lane per probe.  The hub builds its rows
;;   (`debug/run/get''s `strip', docs/develop/hub.md "Rows"); this file only inserts them.
;; - **Past stops**: `Alt ←' / `Alt →' (per key profile) or a click on the strip opens a stop read-only, with the file
;;   as it ran (from the launch snapshot) under a banner, its stack and variables as captured; "Back to Live" returns.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-margins)
(require 'drgnx-pixels)
(require 'drgnx-ui-kit)
(require 'drgnx-faces)
(require 'drgnx-timer)
(require 'drgnx-debug-gutter (expand-file-name "drgnx-debug-gutter" (file-name-directory (macroexp-file-name))))
(require 'drgnx-debug-launch (expand-file-name "drgnx-debug-launch" (file-name-directory (macroexp-file-name))))
(declare-function drgnx-hub-call "drgnx-hub-client")
(defvar drgnx-hub-event-functions)

(defface drgnx-debug-probe '((t :inherit drgnx-accent))
  "A probe's glyph, sparkline and lane." :group 'drgnx)
(defface drgnx-debug-probe-values '((t :inherit drgnx-text-muted))
  "A probe's newest value at its line's end." :group 'drgnx)
(defface drgnx-debug-timeline-head '((t :inherit bold))
  "The strip's run name and a lane's name." :group 'drgnx)
(defface drgnx-debug-timeline-dim '((t :inherit drgnx-text-muted))
  "The strip's counts and numbers." :group 'drgnx)
(defface drgnx-debug-timeline-step '((t :inherit drgnx-text-disabled))
  "A step's (or a pause's) stop on the strip." :group 'drgnx)
(defface drgnx-debug-timeline-current '((t :inherit drgnx-debug-stopped))
  "The ring around the stop shown." :group 'drgnx)
(defface drgnx-debug-past-banner '((t :inherit drgnx-chip-attention))
  "The banner over a past stop." :group 'drgnx)
(defface drgnx-debug-past-line '((t :inherit drgnx-selected-quiet))
  "A past stop's line." :group 'drgnx)
(defface drgnx-debug-not-what-ran '((t :inherit drgnx-status-warn))
  "The banner's warning: the file was unsaved at the launch, so the editor's text was not what ran." :group 'drgnx)

(defconst drgnx-debug-timeline-spark-max 24 "The most values a sparkline shows (the newest).")
(defconst drgnx-debug-timeline--bars "▁▂▃▄▅▆▇█")

;;;; State

(defvar drgnx-debug-timeline--runs nil
  "The runs `debug-run' told of, newest first: plists (:run :n :root :state …); at most 16.")
(defvar drgnx-debug-timeline--probes (make-hash-table :test 'equal)
  "ROOT → its probes (plists :id :path :line :expr :enabled), as `debug/probe/op' last said.")
(defvar drgnx-debug-timeline--values (make-hash-table :test 'equal)
  "\"ROOT\\0PROBE\" → its newest values (strings, newest first), at most `drgnx-debug-timeline-spark-max'.  Pruned
with the probes: a key whose probe is gone is removed.")
(defvar-local drgnx-debug-timeline--overlays nil "This file's probe overlays (glyphs and values).")
(defvar drgnx-debug-probes-mode)

;;;; Sparklines

(defun drgnx-debug-timeline-spark (values)
  "VALUES (strings, oldest first) as a sparkline of the numeric ones, the newest `drgnx-debug-timeline-spark-max';
\"\" when none is a number (the hub's `debug::strip::sparkline')."
  (let* ((nums (delq nil (mapcar (lambda (v)
                                   (let ((s (string-trim (string-trim v) "['\"]" "['\"]")))
                                     (when (string-match-p "\\`[-+]?[0-9]*\\.?[0-9]+\\([eE][-+]?[0-9]+\\)?\\'" s)
                                       (string-to-number s))))
                                 values)))
         (nums (last nums drgnx-debug-timeline-spark-max)))
    (if (null nums) ""
      (let ((lo (apply #'min nums)) (hi (apply #'max nums)))
        (mapconcat (lambda (n)
                     (string (aref drgnx-debug-timeline--bars
                                   (if (<= hi lo) 3 (min 7 (round (* 7.0 (/ (- n lo) (float (- hi lo))))))))))
                   nums "")))))

;;;; Probes in a file

(defun drgnx-debug-timeline--svg (h w colour &optional pad)
  "The probe glyph (a ring with a dot) as SVG text, H by W pixels after PAD pixels of nothing, in COLOUR."
  (let* ((pad (or pad 0)) (vw (/ (* 16.0 (+ w pad)) h)) (x0 (- (/ (- 16 (/ (* 16.0 w) h)) 2) (/ (* 16.0 pad) h))))
    (format "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='%.3f 0 %.3f 16'><circle cx='8' cy='8' r='5' fill='none' stroke='%s' stroke-width='1.6'/><circle cx='8' cy='8' r='2' fill='%s'/></svg>"
            (+ w pad) h x0 vw colour colour)))

(defun drgnx-debug-timeline--glyph (help)
  "The probe glyph's `before-string', HELP its tooltip: an image on a graphical frame with SVG, else a character."
  (propertize " " 'display
              (list '(margin left-margin)
                    (if (and (display-graphic-p) (image-type-available-p 'svg))
                        (let ((w (* (drgnx-debug-gutter--columns) (frame-char-width)))
                              (h (min (drgnx-px 16) (frame-char-height))))
                          (create-image (drgnx-debug-timeline--svg
                                         h w (drgnx-debug-gutter--colour 'drgnx-debug-probe)
                                         (* (or (drgnx-margins-offset 'debug-probe) 0) (frame-char-width)))
                                        'svg t :ascent 'center :scale 1))
                      (concat (drgnx-margins-pad 'debug-probe)
                              (propertize (if (drgnx-ui-ascii-frame-p) "o" "◉") 'face 'drgnx-debug-probe))))
              'help-echo help))

(defun drgnx-debug-timeline--root ()
  "This buffer's project root, as the hub keys probes."
  (drgnx-debug-launch-root))

(defun drgnx-debug-timeline--mine (root)
  "ROOT's probes on this buffer's file."
  (let ((file (and buffer-file-name (expand-file-name buffer-file-name))))
    (seq-filter (lambda (p) (equal (plist-get p :path) file)) (gethash root drgnx-debug-timeline--probes))))

(defun drgnx-debug-timeline--values-text (root probe)
  "PROBE's (of ROOT) newest values as the line's end shows them: a sparkline and the newest value."
  (when-let* ((vals (gethash (concat root "\0" probe) drgnx-debug-timeline--values)))
    (let ((spark (drgnx-debug-timeline-spark (reverse vals))) (last (truncate-string-to-width (car vals) 40 nil nil "…")))
      (concat "  " (propertize spark 'face 'drgnx-debug-probe)
              (propertize (concat (if (string-empty-p spark) "" " ") last) 'face 'drgnx-debug-probe-values)))))

(defun drgnx-debug-timeline--draw ()
  "Draw this file's probes: the column (claimed while it has some), each glyph, and the values at each line's end.
The claim comes first: a moved column calls this again (`drgnx-debug-timeline--restring'), and the drawing after it
replaces that one's."
  (let* ((root (drgnx-debug-timeline--root))
         (mine (seq-filter (lambda (p) (not (eq (plist-get p :enabled) :false))) (drgnx-debug-timeline--mine root))))
    (drgnx-margins-claim 'debug-probe (and mine (drgnx-debug-gutter--columns)) :order 1)
    (mapc #'delete-overlay drgnx-debug-timeline--overlays)
    (setq drgnx-debug-timeline--overlays nil)
    (save-excursion
      (dolist (p mine)
        (goto-char (point-min))
        (when (zerop (forward-line (1- (plist-get p :line))))
          (let ((g (make-overlay (point) (point) nil t nil))
                (v (make-overlay (line-end-position) (line-end-position) nil t nil)))
            (overlay-put g 'drgnx-debug-probe (plist-get p :id))
            (overlay-put g 'before-string (drgnx-debug-timeline--glyph (format "Probe: %s" (plist-get p :expr))))
            (overlay-put v 'drgnx-debug-probe-values (plist-get p :id))
            (overlay-put v 'after-string (drgnx-debug-timeline--values-text root (plist-get p :id)))
            (push g drgnx-debug-timeline--overlays)
            (push v drgnx-debug-timeline--overlays)))))))

(defun drgnx-debug-timeline--restring (buffer)
  "`drgnx-margins-changed-functions': the probe column moved in BUFFER; its glyphs take the new pad."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when drgnx-debug-probes-mode (drgnx-debug-timeline--draw)))))

(defun drgnx-debug-timeline--redraw-root (root)
  "Draw the probes again in every buffer of ROOT."
  (dolist (b (buffer-list))
    (when (buffer-local-value 'drgnx-debug-probes-mode b)
      (with-current-buffer b
        (when (equal (drgnx-debug-timeline--root) root) (drgnx-debug-timeline--draw))))))

(defun drgnx-debug-timeline--take (result)
  "Keep `debug/probe/op''s RESULT and draw it; values of probes now gone are forgotten."
  (let* ((root (plist-get result :root)) (probes (append (plist-get result :probes) nil))
         (ids (mapcar (lambda (p) (plist-get p :id)) probes)) (prefix (concat root "\0")))
    (puthash root probes drgnx-debug-timeline--probes)
    (let (gone)
      (maphash (lambda (k _) (when (and (string-prefix-p prefix k)
                                        (not (member (substring k (length prefix)) ids)))
                               (push k gone)))
               drgnx-debug-timeline--values)
      (dolist (k gone) (remhash k drgnx-debug-timeline--values)))
    (drgnx-debug-timeline--redraw-root root)))

(defun drgnx-debug-timeline--probe-op (op)
  "Send OP (nil: only ask) for this buffer's project; draw the answer."
  (drgnx-hub-call "debug/probe/op" (append (list :root (drgnx-debug-timeline--root)) (and op (list :op op)))
                  (lambda (result error)
                    (if error (message "Probe: %s" (or (plist-get error :message) error))
                      (drgnx-debug-timeline--take result)))))

(define-minor-mode drgnx-debug-probes-mode
  "This file's probes: their column in the left margin and their values at each line's end."
  :group 'drgnx
  (if drgnx-debug-probes-mode
      (progn
        (add-hook 'drgnx-margins-changed-functions #'drgnx-debug-timeline--restring)
        (let ((root (drgnx-debug-timeline--root)))
          (if (gethash root drgnx-debug-timeline--probes)
              (drgnx-debug-timeline--draw)
            ;; asked from `find-file-hook' (and the mode's start): with no hub to answer, the file has no probes to
            ;; show; it never fails the visit (`drgnx-hub-call' signals when no hub serves)
            (condition-case nil (drgnx-debug-timeline--probe-op nil) (error nil)))))
    (mapc #'delete-overlay drgnx-debug-timeline--overlays)
    (setq drgnx-debug-timeline--overlays nil)
    (drgnx-margins-claim 'debug-probe nil)
    (unless (seq-some (lambda (b) (buffer-local-value 'drgnx-debug-probes-mode b)) (buffer-list))
      (remove-hook 'drgnx-margins-changed-functions #'drgnx-debug-timeline--restring))))

(defun drgnx-debug-timeline--probe-at (line)
  "The probe on LINE of this file, or nil."
  (seq-find (lambda (p) (eql (plist-get p :line) line)) (drgnx-debug-timeline--mine (drgnx-debug-timeline--root))))

(defun drgnx-debug-timeline--assigned ()
  "What this line assigns (`name =', `obj.attr +=', `let name ='), or nil."
  (save-excursion
    (beginning-of-line)
    (when (looking-at "[ \t]*\\(?:\\(?:let\\|const\\|var\\)[ \t]+\\)?\\([[:alpha:]_][[:alnum:]_.]*\\)[ \t]*\\(?:[-+*/%|&^]\\|//\\|:\\)?=[^=]")
      (match-string-no-properties 1))))

(defun drgnx-debug-probe-add (expr)
  "A probe recording EXPR at this line, every time the line runs (it runs before the line)."
  (interactive (list (read-string "Probe expression: " (thing-at-point 'symbol t))))
  (unless buffer-file-name (user-error "Probes go in a file"))
  (drgnx-debug-timeline--probe-op (list :op "add" :path (expand-file-name buffer-file-name)
                                        :line (line-number-at-pos) :expr expr)))

(defun drgnx-debug-probe-result (expr)
  "Probe the Result: record EXPR (what this line assigns) on the next line that runs, where its new value exists."
  (interactive (list (let ((a (drgnx-debug-timeline--assigned)))
                       (read-string "Probe the result of: " (or a (thing-at-point 'symbol t))))))
  (unless buffer-file-name (user-error "Probes go in a file"))
  (drgnx-debug-timeline--probe-op
   (list :op "result" :path (expand-file-name buffer-file-name) :line (line-number-at-pos) :expr expr
         :text (buffer-substring-no-properties (point-min) (point-max))
         :language (or (drgnx-debug-launch-language) ""))))

(defun drgnx-debug-probe-remove ()
  "Remove this line's probe."
  (interactive)
  (let ((p (drgnx-debug-timeline--probe-at (line-number-at-pos))))
    (unless p (user-error "No probe on this line"))
    (drgnx-debug-timeline--probe-op (list :op "remove" :id (plist-get p :id)))))

;;;; The strip

(defconst drgnx-debug-timeline-buffer "*drgnx-debug timeline*" "The strip's buffer.")
(defconst drgnx-debug-timeline-past-buffer "*drgnx-debug past stop*" "A past stop's file, as it ran.")
(defconst drgnx-debug-timeline-vars-buffer "*drgnx-debug past variables*" "A past stop's stack and variables.")

(defvar drgnx-debug-timeline--run nil "The run the strip shows (its id).")
(defvar drgnx-debug-timeline--root-shown nil "The project whose newest run the strip follows.")
(defvar drgnx-debug-timeline--stops nil "The strip's stops (plists, `debug/run/get''s), in order.")
(defvar drgnx-debug-timeline--current nil "The stop (its `index') shown in the past stop's buffer, or nil: live.")

(declare-function drgnx-debug-origin-click-value "drgnx-debug-origin" (event))

(defvar drgnx-debug-past-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [M-mouse-1] #'drgnx-debug-origin-click-value)
    m)
  "Keys of the strip and a past stop (key profiles: `:map drgnx-debug-past-mode-map'): `Alt ←' / `Alt →' move between
stops there, and only there (elsewhere they keep their own commands).  Alt-click on a name asks where its value came
from (`drgnx-debug-origin').")

(define-minor-mode drgnx-debug-past-mode
  "On in the strip and a past stop's buffers: their keys (`drgnx-debug-past-mode-map')."
  :group 'drgnx :keymap drgnx-debug-past-mode-map)

(defvar drgnx-debug-strip-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-1] #'drgnx-debug-timeline-click)
    (define-key m [drag-mouse-1] #'drgnx-debug-timeline-click)
    m)
  "The strip's mouse: a click or a drag's end opens that stop.  Its keys come from the key profiles (`:map
drgnx-debug-strip-mode-map'); `Alt ←' / `Alt →' are `drgnx-debug-past-mode-map''s.")

(define-derived-mode drgnx-debug-strip-mode special-mode "Timeline"
  "The stop timeline of a recorded run."
  :group 'drgnx
  (setq-local truncate-lines t cursor-type nil)
  (buffer-disable-undo)
  (drgnx-debug-past-mode 1))

(defun drgnx-debug-timeline--row-string (row)
  "ROW (a hub row, docs/develop/hub.md \"Rows\") as text: its runs' faces and its properties.  A face or property name
the editor does not know is dropped, never interned."
  (let ((s (copy-sequence (plist-get row :text))))
    (seq-doseq (run (plist-get row :runs))
      (let ((face (intern-soft (aref run 2))))
        (when (and face (facep face))
          (add-face-text-property (aref run 0) (aref run 1) face t s))))
    (seq-doseq (p (plist-get row :props))
      (when-let* ((name (intern-soft (aref p 2))))
        (put-text-property (aref p 0) (aref p 1) name (aref p 3) s)))
    s))

(defun drgnx-debug-timeline--render (view)
  "Insert VIEW's strip rows (`debug/run/get''s answer) in the strip's buffer."
  (with-current-buffer (get-buffer-create drgnx-debug-timeline-buffer)
    (unless (derived-mode-p 'drgnx-debug-strip-mode) (drgnx-debug-strip-mode))
    (setq drgnx-debug-timeline--stops (append (plist-get view :stops) nil))
    (let ((inhibit-read-only t) (at (point)))
      (erase-buffer)
      (seq-doseq (row (plist-get view :strip))
        (insert (drgnx-debug-timeline--row-string row) "\n"))
      (goto-char (min at (point-max))))))

(defun drgnx-debug-timeline--refresh ()
  "Ask the hub for the strip of `drgnx-debug-timeline--run' and draw it."
  (when drgnx-debug-timeline--run
    (drgnx-hub-call "debug/run/get"
                    (append (list :run drgnx-debug-timeline--run :from 0 :count 1000)
                            (and drgnx-debug-timeline--current (list :current drgnx-debug-timeline--current)))
                    (lambda (result error)
                      (unless error (drgnx-debug-timeline--render result))))))

(defun drgnx-debug-timeline--refresh-soon ()
  "Draw the strip again soon (at most four times a second)."
  (when (get-buffer drgnx-debug-timeline-buffer)
    (drgnx-timer-soon 'debug-timeline 0.05 #'drgnx-debug-timeline--refresh :min-interval 0.25)))

(defun drgnx-debug-timeline-show (&optional run)
  "Show the stop timeline of RUN (default: the newest run of this project)."
  (interactive)
  (let ((root (drgnx-debug-timeline--root)))
    (setq drgnx-debug-timeline--root-shown root
          drgnx-debug-timeline--run
          (or run (plist-get (seq-find (lambda (r) (equal (plist-get r :root) root)) drgnx-debug-timeline--runs) :run)
              (let ((runs (plist-get (drgnx-hub-call-sync "debug/runs/list" (list :root root) 5) :runs)))
                (and (> (length runs) 0) (plist-get (aref runs 0) :id)))))
    (unless drgnx-debug-timeline--run (user-error "No recorded run in %s" (abbreviate-file-name root)))
    (get-buffer-create drgnx-debug-timeline-buffer)
    (drgnx-debug-timeline--refresh)
    (display-buffer drgnx-debug-timeline-buffer
                    '((display-buffer-in-side-window) (side . top) (slot . 0) (window-height . fit-window-to-buffer)
                      (preserve-size . (nil . t))))))

;;;; Past stops

(defvar-local drgnx-debug-timeline--past nil "The past stop this buffer shows (`debug/run/stop''s answer).")

(defun drgnx-debug-timeline--position (index)
  "The position (0-based) of the stop numbered INDEX on the strip, or nil."
  (cl-position index drgnx-debug-timeline--stops :key (lambda (s) (plist-get s :index))))

(defun drgnx-debug-timeline--mode-for (path)
  "The major mode `auto-mode-alist' gives PATH, or `fundamental-mode'."
  (let ((m (assoc-default path auto-mode-alist #'string-match)))
    (if (and m (symbolp m) (fboundp m)) m #'fundamental-mode)))

(defun drgnx-debug-timeline--banner (n total stop not-what-ran)
  "The header line of stop N of TOTAL (STOP's plist), NOT-WHAT-RAN when the file was unsaved at the launch."
  (concat (propertize (format " Stop %d of %d · %s · as it ran " n total (plist-get stop :reason))
                      'face 'drgnx-debug-past-banner)
          (and not-what-ran
               (propertize " not what ran: this file was unsaved in the editor at the launch "
                           'face 'drgnx-debug-not-what-ran))
          " "
          (propertize "Back to Live" 'face 'drgnx-accent 'mouse-face 'highlight
                      'local-map (let ((m (make-sparse-keymap)))
                                   (define-key m [header-line mouse-1] #'drgnx-debug-timeline-live) m))))

(defun drgnx-debug-timeline--inline (capture)
  "The variables of CAPTURE's first scope as \"name = value\" pairs, for the stop's line."
  (let* ((scope (car (append (plist-get capture :scopes) nil)))
         (vars (append (plist-get scope :variables) nil)))
    (mapconcat (lambda (v) (format "%s = %s" (plist-get v :name)
                                   (truncate-string-to-width (or (plist-get v :value) "") 30 nil nil "…")))
               (seq-take vars 4) "  ")))

(defun drgnx-debug-timeline--show-vars (capture)
  "CAPTURE's stack and variables in the variables buffer."
  (with-current-buffer (get-buffer-create drgnx-debug-timeline-vars-buffer)
    (let ((inhibit-read-only t))
      (special-mode)
      (buffer-disable-undo)
      (erase-buffer)
      (insert (propertize "Call Stack\n" 'face 'drgnx-debug-timeline-head))
      (seq-doseq (f (plist-get capture :frames))
        (insert (format "  %s  %s:%s\n" (plist-get f :name)
                        (file-name-nondirectory (or (plist-get (plist-get f :source) :path) ""))
                        (plist-get f :line))))
      (seq-doseq (s (plist-get capture :scopes))
        (insert (propertize (format "%s\n" (plist-get (plist-get s :scope) :name)) 'face 'drgnx-debug-timeline-head))
        (if (null (plist-get s :variables))
            (insert (propertize "  not captured: Replay to here\n" 'face 'drgnx-debug-timeline-dim))
          (seq-doseq (v (plist-get s :variables))
            (insert (format "  %s = %s\n" (plist-get v :name) (plist-get v :value))))))
      (when (> (or (plist-get capture :cut) 0) 0)
        (insert (propertize (format "(%d more not kept: a stop keeps 64 KB)\n" (plist-get capture :cut))
                            'face 'drgnx-debug-timeline-dim)))
      (goto-char (point-min)))))

(defun drgnx-debug-timeline--show-past (past)
  "Show PAST (`debug/run/stop''s answer) read-only: the file as it ran, the stop's line, the banner, the variables."
  (let* ((stop (plist-get past :stop)) (source (plist-get past :source))
         (path (plist-get source :path)) (text (plist-get source :text))
         (pos (drgnx-debug-timeline--position (plist-get stop :index)))
         (buf (get-buffer-create drgnx-debug-timeline-past-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (delay-mode-hooks (funcall (drgnx-debug-timeline--mode-for (or path ""))))
        (buffer-disable-undo)
        (erase-buffer)
        (insert (if (stringp text) text (format "%s is not in the launch snapshot.\n" (or path "The file"))))
        (remove-overlays)
        (goto-char (point-min))
        (when (and (stringp text) (zerop (forward-line (1- (or (plist-get stop :line) 1)))))
          (let ((o (make-overlay (line-beginning-position) (line-beginning-position 2))))
            (overlay-put o 'face 'drgnx-debug-past-line)
            (overlay-put o 'drgnx-debug-past-stop (plist-get stop :index)))
          (let ((v (make-overlay (line-end-position) (line-end-position)))
                (inline (drgnx-debug-timeline--inline (plist-get past :capture))))
            (unless (string-empty-p inline)
              (overlay-put v 'after-string (propertize (concat "  " inline) 'face 'drgnx-debug-probe-values))))))
      (setq buffer-read-only t)
      (drgnx-debug-past-mode 1)
      (setq-local drgnx-debug-timeline--past past)
      (setq header-line-format
            (drgnx-debug-timeline--banner (1+ (or pos 0)) (length drgnx-debug-timeline--stops) stop
                                          (eq (plist-get source :not_what_ran) t))))
    (drgnx-debug-timeline--show-vars (plist-get past :capture))
    buf))

(defun drgnx-debug-timeline-open (index)
  "Open stop INDEX of the strip's run, read-only, with the file as it ran."
  (unless drgnx-debug-timeline--run (user-error "No run on the strip"))
  (setq drgnx-debug-timeline--current index)
  (drgnx-hub-call "debug/run/stop" (list :run drgnx-debug-timeline--run :stop index)
                  (lambda (result error)
                    (if error (message "Past stop: %s" (or (plist-get error :message) error))
                      (let ((b (drgnx-debug-timeline--show-past result)))
                        (display-buffer b '((display-buffer-reuse-window display-buffer-use-some-window)))
                        (when-let* ((w (get-buffer-window b)))
                          (with-selected-window w
                            (goto-char (point-min))
                            (forward-line (1- (or (plist-get (plist-get result :stop) :line) 1)))))))
                    (drgnx-debug-timeline--refresh))))

(defun drgnx-debug-timeline--step (delta)
  "Open the stop DELTA places from the one shown (from the newest when live)."
  (unless drgnx-debug-timeline--stops (user-error "No stops on the strip"))
  (let* ((n (length drgnx-debug-timeline--stops))
         (at (or (and drgnx-debug-timeline--current (drgnx-debug-timeline--position drgnx-debug-timeline--current))
                 n))
         (to (max 0 (min (1- n) (+ at delta)))))
    (drgnx-debug-timeline-open (plist-get (nth to drgnx-debug-timeline--stops) :index))))

(defun drgnx-debug-timeline-back ()
  "The stop before the one shown (from live: the newest)."
  (interactive)
  (drgnx-debug-timeline--step -1))

(defun drgnx-debug-timeline-forward ()
  "The stop after the one shown; past the newest, back to live."
  (interactive)
  (if (and drgnx-debug-timeline--current
           (eql (drgnx-debug-timeline--position drgnx-debug-timeline--current) (1- (length drgnx-debug-timeline--stops))))
      (drgnx-debug-timeline-live)
    (drgnx-debug-timeline--step 1)))

(defun drgnx-debug-timeline-open-at-point ()
  "Open the stop at point on the strip."
  (interactive)
  (let ((i (get-text-property (point) 'drgnx-debug-stop)))
    (unless i (user-error "No stop here"))
    (drgnx-debug-timeline-open i)))

(defun drgnx-debug-timeline-click (event)
  "Open the stop under EVENT (a click, or the end of a drag: scrubbing)."
  (interactive "e")
  (let* ((end (event-end event)) (pos (posn-point end)))
    (when (and pos (windowp (posn-window end)))
      (with-current-buffer (window-buffer (posn-window end))
        (when-let* ((i (get-text-property pos 'drgnx-debug-stop)))
          (drgnx-debug-timeline-open i))))))

(defun drgnx-debug-timeline-live ()
  "Back to Live: the past stop's buffers go and the strip follows the run again."
  (interactive)
  (setq drgnx-debug-timeline--current nil)
  (dolist (name (list drgnx-debug-timeline-past-buffer drgnx-debug-timeline-vars-buffer))
    (when-let* ((b (get-buffer name))) (kill-buffer b)))
  (drgnx-debug-timeline--refresh))

;;;; The hub's events

(defun drgnx-debug-timeline--event (event data)
  "`drgnx-hub-event-functions': a run started, stopped or ended (`debug-run'); probe hits came (`debug-probe-hits')."
  (pcase event
    ("debug-run"
     (let ((run (plist-get data :run)))
       (setq drgnx-debug-timeline--runs
             (seq-take (cons data (seq-remove (lambda (r) (equal (plist-get r :run) run)) drgnx-debug-timeline--runs))
                       16))
       ;; the strip follows its project's newest run while it is live
       (when (and (null drgnx-debug-timeline--current)
                  (equal (plist-get data :root) drgnx-debug-timeline--root-shown))
         (setq drgnx-debug-timeline--run run))
       (when (equal run drgnx-debug-timeline--run) (drgnx-debug-timeline--refresh-soon))))
    ("debug-probe-hits"
     (let* ((run (plist-get data :run))
            (root (plist-get (seq-find (lambda (r) (equal (plist-get r :run) run)) drgnx-debug-timeline--runs) :root)))
       (when root
         (seq-doseq (h (plist-get data :hits))
           (let ((k (concat root "\0" (plist-get h :probe))))
             (puthash k (seq-take (cons (plist-get h :value) (gethash k drgnx-debug-timeline--values))
                                  drgnx-debug-timeline-spark-max)
                      drgnx-debug-timeline--values)))
         (drgnx-timer-soon (cons 'debug-probe-values root) 0.05 #'drgnx-debug-timeline--values-changed
                           :args (list root) :min-interval 0.1)
         (when (equal run drgnx-debug-timeline--run) (drgnx-debug-timeline--refresh-soon)))))))

(defun drgnx-debug-timeline--values-changed (root)
  "ROOT's probe values changed: each probe's line end shows its newest."
  (dolist (b (buffer-list))
    (when (buffer-local-value 'drgnx-debug-probes-mode b)
      (with-current-buffer b
        (when (equal (drgnx-debug-timeline--root) root)
          (let ((root root))
            (dolist (o drgnx-debug-timeline--overlays)
              (when-let* ((id (overlay-get o 'drgnx-debug-probe-values)))
                (overlay-put o 'after-string (drgnx-debug-timeline--values-text root id))))))))))

;;;; On and off

(defun drgnx-debug-timeline--probes-on ()
  "`find-file-hook': a file's buffer shows its probes."
  (when buffer-file-name (drgnx-debug-probes-mode 1)))

(define-minor-mode drgnx-debug-timeline-mode
  "Recorded runs in the editor: probes in every file's buffer, the hub's run events, the strip."
  :global t :group 'drgnx
  (if drgnx-debug-timeline-mode
      (progn
        (add-hook 'find-file-hook #'drgnx-debug-timeline--probes-on)
        (add-hook 'drgnx-hub-event-functions #'drgnx-debug-timeline--event)
        (dolist (b (buffer-list))
          (with-current-buffer b (when buffer-file-name (drgnx-debug-probes-mode 1)))))
    (remove-hook 'find-file-hook #'drgnx-debug-timeline--probes-on)
    (remove-hook 'drgnx-hub-event-functions #'drgnx-debug-timeline--event)
    (drgnx-timer-cancel 'debug-timeline)
    (dolist (b (buffer-list))
      (when (buffer-local-value 'drgnx-debug-probes-mode b)
        (with-current-buffer b (drgnx-debug-probes-mode -1))))
    (dolist (name (list drgnx-debug-timeline-buffer drgnx-debug-timeline-past-buffer drgnx-debug-timeline-vars-buffer))
      (when-let* ((b (get-buffer name))) (kill-buffer b)))
    (clrhash drgnx-debug-timeline--probes)
    (clrhash drgnx-debug-timeline--values)
    (setq drgnx-debug-timeline--runs nil drgnx-debug-timeline--run nil drgnx-debug-timeline--stops nil
          drgnx-debug-timeline--current nil drgnx-debug-timeline--root-shown nil)))

(defconst drgnx-debug-timeline-commands
  '((debug-probe "Add Probe…" drgnx-debug-probe-add "Record an expression each time this line runs, without stopping")
    (debug-probe-result "Probe the Result…" drgnx-debug-probe-result "Record what this line assigns, on the next line that runs")
    (debug-probe-remove "Remove Probe" drgnx-debug-probe-remove "Remove this line's probe")
    (debug-timeline "Show Stop Timeline" drgnx-debug-timeline-show "The recorded run's stops and probe values")
    (debug-timeline-back "Previous Stop (Recorded)" drgnx-debug-timeline-back "Open the stop before, as it ran")
    (debug-timeline-forward "Next Stop (Recorded)" drgnx-debug-timeline-forward "Open the stop after, or go back to live")
    (debug-timeline-open "Open Stop (Recorded)" drgnx-debug-timeline-open-at-point "Open the stop at point on the strip, as it ran")
    (debug-timeline-live "Back to Live" drgnx-debug-timeline-live "Leave the past stop and follow the run again"))
  "The commands of recorded runs: (ID TITLE FUNCTION DOC).")

(provide 'drgnx-debug-timeline)
;;; drgnx-debug-timeline.el ends here
