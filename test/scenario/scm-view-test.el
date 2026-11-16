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
  "Whether the view says ROOT's working tree matches HEAD (its empty-state row, whose text a narrow side bar cuts)."
  (drgnx-scn-scm--row (lambda (w) (and (equal (plist-get w :kind) "note") (equal (plist-get w :root) root)))))

(defun drgnx-scn-scm--text ()
  (if-let* ((buf (get-buffer "*Source Control*")))
      (with-current-buffer buf (buffer-substring-no-properties (point-min) (min (point-max) 1200)))
    "(no Source Control buffer)"))

(defun drgnx-scn-scm--evidence (name)
  "NAME in the run's evidence folder (DRGNX_UI_EVIDENCE), or nil without one."
  (when-let* ((dir (getenv "DRGNX_UI_EVIDENCE")) ((file-directory-p dir)))
    (expand-file-name name dir)))

(defun drgnx-scn-scm--step (step report reached)
  "Judge STEP's REPORT: settled, REACHED (non-nil when the step's state is on screen) and within the budget.  The
step's screenshot and its line (STEP settle_ms reached) go to the evidence folder."
  (let* ((ms (plist-get report :settle_ms))
         (shot (plist-get (drgnx-uitest-capture (make-temp-file "scm-scenario" t)) :root))
         (base (format "scm-%s" step)))
    (when-let* ((png (drgnx-scn-scm--evidence (concat base ".png"))))
      (copy-file shot png t)
      (write-region (format "%s settle_ms=%s reached=%s\n" base ms (and reached t)) nil
                    (drgnx-scn-scm--evidence "scm-steps.txt") t 'silent))
    (drgnx-scenario-check (and reached (numberp ms) (< ms drgnx-scn-scm--budget-ms))
                          (format "%s: reached %s, settled %d ms after the input (budget %d ms); rows: %s"
                                  step (and reached t) (or ms -1) drgnx-scn-scm--budget-ms (drgnx-scn-scm--text))
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
        "open" (drgnx-uitest-run (drgnx-uitest-key-events (drgnx-driver--key 'scm-view)))
        (and (drgnx-scn-scm--repo-row root) (drgnx-scn-scm--repo-row lib)
             (drgnx-scn-scm--file-row root "README.md" "changes")))
       ;; 2. the README row's +: hovered (the real pointer, when the compositor gives one), then clicked
       (let* ((win (get-buffer-window "*Source Control*"))
              (row (drgnx-scn-scm--file-row root "README.md" "changes"))
              (plus (and row (drgnx-scn-scm--button row "stage")))
              (xy (and win plus (drgnx-uitest-pos-xy win plus))))
         (drgnx-scenario-require xy (format "the README row's + on screen (row %s, + %s)" row plus))
         (when (drgnx-uitest-pointer-available-p) (drgnx-uitest-pointer-move (car xy) (cdr xy)))
         (drgnx-scn-scm--step
          "stage" (drgnx-uitest-run (drgnx-uitest-click-events (drgnx-uitest-posn (car xy) (cdr xy))))
          (and (drgnx-scn-scm--file-row root "README.md" "staged")
               (not (drgnx-scn-scm--file-row root "README.md" "changes")))))
       ;; 3. a click in the message box, then the message typed
       (let* ((box (drgnx-wb-section-window 'scm-message))
              (edges (and box (window-inside-pixel-edges box))))
         (drgnx-scenario-require box "the commit message box on screen")
         (drgnx-scn-scm--step
          "message" (drgnx-uitest-run (append (drgnx-uitest-click-events
                                               (drgnx-uitest-posn (+ (nth 0 edges) 6) (+ (nth 1 edges) 6)))
                                              (drgnx-uitest-type-events "More in the README")))
          (and (eq (selected-window) box)
               (equal (with-current-buffer (window-buffer box) (buffer-string)) "More in the README"))))
       ;; 4. Ctrl+Enter: committed, the box empty, the working tree matches HEAD
       (drgnx-scn-scm--step
        "commit" (drgnx-uitest-run (drgnx-uitest-key-events (drgnx-driver--key 'scm-commit-message)))
        (and (drgnx-scn-scm--matches-head-p root)
             (with-current-buffer "*Source Control Message*" (zerop (buffer-size)))))
       (should (equal "More in the README"
                      (let ((default-directory (file-name-as-directory root)))
                        (with-temp-buffer
                          (call-process "git" nil t nil "log" "-1" "--format=%s")
                          (string-trim (buffer-string))))))))))

;;; scm-view-test.el ends here
