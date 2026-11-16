;;; scm-view-test.el --- Scenarios: the Source Control side bar by hand -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; SPDX-License-Identifier: GPL-3.0-or-later
;; UX audit S1-3 (2026-11-16): the Source Control view, driven as a user does in VS Code.  Ctrl+Shift+G opens it with
;; both repositories of the folder under Repositories (the project and the one nested in it), the row's + stages the
;; changed file, a click in the message box and typing give the message, Ctrl+Enter commits, and the view says the
;; working tree matches HEAD.  Each step settles within 200 ms of its input (`:settle_ms', the last visible change
;; after it, with the scenario's 1 s quiet period, so a late hub patch counts), and leaves a screenshot in the run's
;; evidence folder (one per run: run it at scale 1 and 1.25, DRGNX_UI_SCALE).  See docs/develop/scenarios.md.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-scenario)
(require 'drgnx-uitest)

(declare-function drgnx-driver--key "drgnx" (id))
(declare-function drgnx-module-running-p "drgnx-modules" (name))
(declare-function drgnx-modules--run-one "drgnx-modules" (name spec stage))
(declare-function drgnx-wb-section-window "drgnx-wb" (name &optional frame))
(defvar drgnx-modules--table)
(defvar drgnx-modules--report)

(defconst drgnx-scn-scm--budget-ms 200 "The most a step may take to settle after its input.")

(defun drgnx-scn-scm--git (dir &rest args)
  "Setup: git ARGS in DIR, or an error."
  (let ((default-directory (file-name-as-directory dir)))
    (unless (zerop (apply #'call-process "git" nil nil nil args))
      (error "scenario setup: git %S in %s failed" args dir))))

(defun drgnx-scn-scm--row (pred)
  "The position of the first Source Control row whose `drgnx-scm' plist satisfies PRED, or nil."
  (when-let* ((buf (get-buffer "*Source Control*")))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-min))
        (let (found)
          (while (and (not found) (not (eobp)))
            (let ((w (get-text-property (point) 'drgnx-scm)))
              (when (and w (funcall pred w)) (setq found (point))))
            (forward-line 1))
          found)))))

(defun drgnx-scn-scm--file-row (root path section)
  (drgnx-scn-scm--row (lambda (w) (and (equal (plist-get w :kind) "file") (equal (plist-get w :root) root)
                                       (equal (plist-get w :path) path) (equal (plist-get w :section) section)))))

(defun drgnx-scn-scm--repo-row (root)
  (drgnx-scn-scm--row (lambda (w) (and (equal (plist-get w :kind) "repo") (equal (plist-get w :root) root)))))

(defun drgnx-scn-scm--button (row action)
  "The position of the button doing ACTION (a string) on the row at ROW, or nil."
  (with-current-buffer "*Source Control*"
    (save-excursion
      (goto-char row)
      (let ((end (line-end-position)) (pos row) found)
        (while (and (not found) pos (< pos end))
          (if (equal (get-text-property pos 'drgnx-scm-action) action)
              (setq found pos)
            (setq pos (next-single-property-change pos 'drgnx-scm-action nil end))))
        found))))

(defun drgnx-scn-scm--matches-head-p (root)
  "Whether the view says ROOT's working tree matches HEAD: its empty-state rows read the whole sentence, wrapped to
the side bar's width, never cut (`…')."
  (when-let* ((buf (get-buffer "*Source Control*")))
    (with-current-buffer buf
      (let (lines)
        (save-excursion
          (goto-char (point-min))
          (while (not (eobp))
            (let ((w (get-text-property (point) 'drgnx-scm)))
              (when (and (equal (plist-get w :kind) "note") (equal (plist-get w :root) root))
                (push (string-trim (buffer-substring-no-properties (pos-bol) (pos-eol))) lines)))
            (forward-line 1)))
        (equal (string-join (nreverse lines) " ") "No changes. Your working tree matches HEAD.")))))

(defun drgnx-scn-scm--text ()
  (if-let* ((buf (get-buffer "*Source Control*")))
      (with-current-buffer buf (buffer-substring-no-properties (point-min) (min (point-max) 1200)))
    "(no Source Control buffer)"))

(defun drgnx-scn-scm--evidence (name)
  "NAME in the run's evidence folder (DRGNX_UI_EVIDENCE), or nil without one."
  (when-let* ((dir (getenv "DRGNX_UI_EVIDENCE")) ((file-directory-p dir)))
    (expand-file-name name dir)))

(defvar drgnx-wb--selected-overlay)

(defvar drgnx-scn-scm--pred nil "The step's state as a function of no arguments, while it is timed.")
(defvar drgnx-scn-scm--reached nil "`float-time' at which the step's state was first seen, or nil.")

(defvar drgnx-scn-scm--patches nil "The step's drawn patches, newest first: (TIME . KEYS).")

(defun drgnx-scn-scm--patched (_view keys)
  "A drawn patch of the rows: note its time and keys (the step's evidence), then whether the state is reached."
  (push (cons (float-time) (length keys)) drgnx-scn-scm--patches)
  (drgnx-scn-scm--seen))

(defun drgnx-scn-scm--seen (&rest _)
  "On a drawn patch, after a command and after an edit: note when the step's state is first on screen."
  (when (and drgnx-scn-scm--pred (not drgnx-scn-scm--reached) (funcall drgnx-scn-scm--pred))
    (setq drgnx-scn-scm--reached (float-time))))

(defun drgnx-scn-scm--lines (win)
  "The visible lines of WIN: ((TEXT Y HEIGHT) …), Y the line's top in frame pixels, HEIGHT its height."
  (redisplay t)
  (let ((top (cdr (drgnx-uitest--text-origin win))) (i 0) out lh)
    (while (and (< i 200) (setq lh (window-line-height i win)))
      (let* ((pos (posn-point (or (posn-at-x-y 1 (+ (nth 2 lh) 1) win) (list win))))
             (text (and pos (with-current-buffer (window-buffer win)
                              (save-excursion (goto-char pos)
                                              (buffer-substring-no-properties (pos-bol) (pos-eol)))))))
        (push (list (or text "") (+ top (nth 2 lh)) (car lh)) out))
      (setq i (1+ i)))
    (nreverse out)))

(defun drgnx-scn-scm--overflowing (win)
  "The texts of WIN's visible rows laid out wider than its text area (a row the hub's fit let past the edge, or one
pushed out by a stretch left at its start): each with its width and the selected row's overlay."
  (let ((room (window-body-width win t)) out)
    (with-current-buffer (window-buffer win)
      (save-excursion
        (goto-char (window-start win))
        (while (< (point) (window-end win t))
          ;; X-LIMIT past the room: nil would cap the measure at the body's width
          (let ((w (car (window-text-pixel-size win (pos-bol) (pos-eol) (* 4 room)))))
            (when (> w room)
              (push (format "%S (%d px > %d; row %d-%d, selection overlay %S)"
                            (buffer-substring-no-properties (pos-bol) (pos-eol)) w room (pos-bol) (pos-eol)
                            (and (overlayp drgnx-wb--selected-overlay) (overlay-buffer drgnx-wb--selected-overlay)
                                 (cons (overlay-start drgnx-wb--selected-overlay)
                                       (overlay-end drgnx-wb--selected-overlay))))
                    out)))
          (forward-line 1))))
    (nreverse out)))

(defun drgnx-scn-scm--blank-rows (win)
  "The texts of WIN's visible rows that hold text but are drawn with none: on screen (the snapshot), the row's strip
across the text area is one colour but for a few pixels."
  (let* ((snap (drgnx-uitest-snapshot)) (s (drgnx-uitest-device-scale (window-frame win)))
         (box (drgnx-uitest--text-box win)) (x0 (round (* s (aref box 0)))) (x1 (round (* s (aref box 2))))
         out)
    (pcase-dolist (`(,text ,y ,h) (drgnx-scn-scm--lines win))
      (when (and (string-match-p "[[:alnum:]]" text) h (> h 2))
        (let ((y0 (round (* s (+ y 2)))) (y1 (round (* s (+ y h -2)))) (counts (make-hash-table :test #'equal)) (n 0))
          (cl-loop for yy from y0 below y1 do
                   (cl-loop for xx from x0 below x1 by 2 do
                            (cl-incf (gethash (cdr (drgnx-uitest-pixel snap xx yy)) counts 0))
                            (cl-incf n)))
          (let ((most 0)) (maphash (lambda (_ c) (setq most (max most c))) counts)
               (when (< (- n most) 12) (push text out))))))
    (nreverse out)))

(defun drgnx-scn-scm--drawn-right (win)
  "Nil when WIN's rows are drawn as they are: none wider than the window, none blank on screen; else a string saying
which."
  (let ((wide (drgnx-scn-scm--overflowing win)) (blank (drgnx-scn-scm--blank-rows win)))
    (when (or wide blank)
      (format "rows wider than the window: %S; rows with text drawn blank: %S" wide blank))))

(defun drgnx-scn-scm--step (step events pred)
  "Run STEP's input EVENTS and judge it: settled, PRED (its state) true, and within the budget twice over: the last
visible change after the input (`:settle_ms') and the moment PRED was first true (a drawn patch of the rows, a
command, an edit: the rows' text changes inside Sjá, which the recorder's window signatures do not see).  The step's
screenshot, its numbers and its trace go to the evidence folder."
  (let* ((drgnx-scn-scm--pred pred) (drgnx-scn-scm--reached nil) (drgnx-scn-scm--patches nil) (t0 (float-time))
         (report (unwind-protect
                     (progn (add-hook 'drgnx-view-patch-patched-functions #'drgnx-scn-scm--patched)
                            (add-hook 'post-command-hook #'drgnx-scn-scm--seen)
                            (add-hook 'after-change-functions #'drgnx-scn-scm--seen)
                            (drgnx-uitest-run events))
                   (remove-hook 'drgnx-view-patch-patched-functions #'drgnx-scn-scm--patched)
                   (remove-hook 'post-command-hook #'drgnx-scn-scm--seen)
                   (remove-hook 'after-change-functions #'drgnx-scn-scm--seen)))
         (reached (funcall pred))
         (ms (plist-get report :settle_ms))
         (seen-ms (and drgnx-scn-scm--reached (round (* 1000 (- drgnx-scn-scm--reached t0)))))
         (shot (plist-get (drgnx-uitest-capture (make-temp-file "scm-scenario" t)) :root))
         (win (get-buffer-window "*Source Control*"))
         (drawn (and win (drgnx-scn-scm--drawn-right win)))
         (base (format "scm-%s" step)))
    (when-let* ((png (drgnx-scn-scm--evidence (concat base ".png"))))
      (copy-file shot png t)
      (write-region (format "%s settle_ms=%s reached_ms=%s reached=%s patches=%S%s\n%s" base ms seen-ms (and reached t)
                            (mapcar (lambda (p) (format "+%d ms %d rows" (round (* 1000 (- (car p) t0))) (cdr p)))
                                    (reverse drgnx-scn-scm--patches))
                            (if drawn (concat " " drawn) "")
                            (mapconcat (lambda (l) (concat "  " l "\n")) (drgnx-scenario-trace-lines report) ""))
                    nil
                    (drgnx-scn-scm--evidence "scm-steps.txt") t 'silent))
    (drgnx-scenario-check (and reached (numberp ms) (< ms drgnx-scn-scm--budget-ms)
                               seen-ms (< seen-ms drgnx-scn-scm--budget-ms) (not drawn))
                          (format "%s: reached %s (first seen %s ms after the input), settled %d ms after it (budget %d ms)%s; rows: %s"
                                  step (and reached t) seen-ms (or ms -1) drgnx-scn-scm--budget-ms
                                  (if drawn (concat "; " drawn) "") (drgnx-scn-scm--text))
                          report)))

(ert-deftest drgnx-scenario/scm-stage-and-commit-by-hand ()
  "Ctrl+Shift+G, the row's +, a message, Ctrl+Enter: each step on screen within 200 ms, two repositories listed."
  (drgnx-scenario-settling
   (drgnx-scenario-load-driver)
   (drgnx-scenario-with-fixture (root 'basic)
     ;; the project, its own identity for the commit, a changed README; a repository nested in it (kept out of the
     ;; project's status, as a vendored checkout is)
     (let ((lib (expand-file-name "vendor/lib" root)) (readme (expand-file-name "README.md" root)))
       (drgnx-scn-scm--git root "config" "user.name" "fixture")
       (drgnx-scn-scm--git root "config" "user.email" "fixture@drgnx")
       (drgnx-scn-scm--git root "config" "commit.gpgsign" "false")
       (with-temp-file (expand-file-name ".git/info/exclude" root) (insert "vendor/\n"))
       (make-directory lib t)
       (with-temp-file (expand-file-name "lib.txt" lib) (insert "lib\n"))
       (drgnx-scn-scm--git lib "init" "-q")
       (drgnx-scn-scm--git lib "add" "-A")
       (drgnx-scn-scm--git lib "-c" "user.email=fixture@drgnx" "-c" "user.name=fixture" "commit" "-qm" "lib")
       (with-temp-file readme (insert "# Fixture\n\nmore\n"))
       (drgnx-driver-reset)
       (drgnx-driver-open-file readme)
       (drgnx-driver-show-sidebar)
       (drgnx-uitest-run nil)
       ;; the Source Control module on, as in a user's session that chose it
       (require 'drgnx-scm nil t)
       (unless (drgnx-module-running-p 'tools/scm)
         (when-let* ((spec (cdr (assq 'tools/scm drgnx-modules--table))))
           (drgnx-modules--run-one 'tools/scm spec 'startup)))
       (drgnx-scenario-require (drgnx-module-running-p 'tools/scm)
                               (format "module tools/scm running (in the table: %s; report: %S)"
                                       (and (assq 'tools/scm drgnx-modules--table) t)
                                       (alist-get 'tools/scm drgnx-modules--report)))
       ;; 1. Ctrl+Shift+G: the view, both repositories under Repositories, the README under Changes
       (drgnx-scn-scm--step
        "open" (drgnx-uitest-key-events (drgnx-driver--key 'scm-view))
        (lambda () (and (drgnx-scn-scm--repo-row root) (drgnx-scn-scm--repo-row lib)
                        (drgnx-scn-scm--file-row root "README.md" "changes"))))
       ;; 2. the README row's +: hovered (the real pointer, when the compositor gives one), then clicked
       (let* ((win (get-buffer-window "*Source Control*"))
              (row (drgnx-scn-scm--file-row root "README.md" "changes"))
              (plus (and row (drgnx-scn-scm--button row "stage")))
              (xy (and win plus (drgnx-uitest-pos-xy win plus))))
         (drgnx-scenario-require xy (format "the README row's + on screen (row %s, + %s)" row plus))
         (when (drgnx-uitest-pointer-available-p) (drgnx-uitest-pointer-move (car xy) (cdr xy)))
         (drgnx-scn-scm--step
          "stage" (drgnx-uitest-click-events (drgnx-uitest-posn (car xy) (cdr xy)))
          (lambda () (and (drgnx-scn-scm--file-row root "README.md" "staged")
                          (not (drgnx-scn-scm--file-row root "README.md" "changes"))))))
       ;; 3. a click in the message box, then the message typed
       (let* ((box (drgnx-wb-section-window 'scm-message))
              (edges (and box (window-inside-pixel-edges box))))
         (drgnx-scenario-require box "the commit message box on screen")
         (drgnx-scn-scm--step
          "message" (append (drgnx-uitest-click-events (drgnx-uitest-posn (+ (nth 0 edges) 6) (+ (nth 1 edges) 6)))
                            (drgnx-uitest-type-events "M"))
          (lambda () (and (eq (selected-window) box)
                          (equal (with-current-buffer (window-buffer box) (buffer-string)) "M"))))
         ;; the rest of the message (each key is a command like the first; the pacing of typed keys is no latency)
         (should (eq t (plist-get (drgnx-uitest-run (drgnx-uitest-type-events "ore in the README")) :settled)))
         (should (equal (with-current-buffer (window-buffer box) (buffer-string)) "More in the README")))
       ;; 4. Ctrl+Enter: committed, the box empty, the working tree matches HEAD
       (drgnx-scn-scm--step
        "commit" (drgnx-uitest-key-events (drgnx-driver--key 'scm-commit-message))
        (lambda () (and (drgnx-scn-scm--matches-head-p root)
                        (with-current-buffer "*Source Control Message*" (zerop (buffer-size))))))
       (should (equal "More in the README"
                      (let ((default-directory (file-name-as-directory root)))
                        (with-temp-buffer
                          (call-process "git" nil t nil "log" "-1" "--format=%s")
                          (string-trim (buffer-string))))))))))

;;; scm-view-test.el ends here
