;;; work-map-graph-test.el --- Scenarios: the Work map draws its graph on a folder like yours -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; SPDX-License-Identifier: GPL-3.0-or-later
;; UX audit (2026-11-16): on the user's install the Work map stayed empty, with no cards, no edges and no message,
;; on a folder holding nested repositories, specs and plans.  These rows open Work the way the user does (its key)
;; on such a folder, with the hub the scenario tier starts, and judge what the map draws.  See
;; docs/develop/scenarios.md.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-scenario)
(require 'drgnx-uitest)

(declare-function drgnx-driver--key "drgnx" (id))
(declare-function drgnx-work-map-buffers "drgnx-work-map")
(declare-function drgnx-work-map--drawn-ids "drgnx-work-map")
(declare-function drgnx-work-client--get "drgnx-work-client" (id))
(declare-function drgnx-work-client--view-status "drgnx-work-client" (view))
(declare-function drgnx-view-env-classes "drgnx-view-env" (view))
(defvar drgnx-work-space--view)

(defun drgnx-scn-wmap--git (dir &rest args)
  "Run git ARGS in DIR, as a fixture identity; its output, trimmed."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (apply #'call-process "git" nil t nil "-c" "user.name=fixture" "-c" "user.email=fixture@drgnx"
             "-c" "commit.gpgsign=false" args)
      (string-trim (buffer-string)))))

(defun drgnx-scn-wmap--repo (dir file text)
  "DIR as a repository with FILE (TEXT) committed."
  (make-directory dir t)
  (drgnx-scn-wmap--git dir "init" "-q" "-b" "main")
  (write-region text nil (expand-file-name file dir) nil 'silent)
  (drgnx-scn-wmap--git dir "add" "-A")
  (drgnx-scn-wmap--git dir "commit" "-qm" (concat "add " file)))

(defun drgnx-scn-wmap--folder (root)
  "ROOT made like the user's org folder: its own repository with specs and plans, two repositories nested in it."
  (make-directory (expand-file-name "docs/specs" root) t)
  (make-directory (expand-file-name "docs/plans" root) t)
  (write-region "# Search view design\n\nThe search view lists matches by file.\n" nil
                (expand-file-name "docs/specs/2026-11-16-search-view.md" root) nil 'silent)
  (write-region "# Search view plan\n\n### Task 1: Rows\n- [ ] the rows\n\n### Task 2: Keys\n- [ ] the keys\n" nil
                (expand-file-name "docs/plans/2026-11-16-search-view.md" root) nil 'silent)
  (unless (file-directory-p (expand-file-name ".git" root)) (drgnx-scn-wmap--git root "init" "-q" "-b" "main"))
  (write-region "drgnx/\nnidhogg/\n" nil (expand-file-name ".gitignore" root) nil 'silent)
  (drgnx-scn-wmap--git root "add" "-A")
  (drgnx-scn-wmap--git root "commit" "-qm" "specs and plans")
  (drgnx-scn-wmap--repo (expand-file-name "drgnx" root) "README.md" "# drgnx\n")
  (drgnx-scn-wmap--repo (expand-file-name "nidhogg" root) "README" "nidhogg\n"))

(defun drgnx-scn-wmap--bulk (root specs plans)
  "SPECS specs and PLANS plans (with tasks) more in ROOT, the size of the org folder's."
  (dotimes (i specs)
    (write-region (format "# Spec %02d: the thing %d\n\nWhy it is done.\n" i i) nil
                  (expand-file-name (format "docs/specs/2026-11-%02d-spec-%02d.md" (1+ (% i 28)) i) root) nil 'silent))
  (dotimes (i plans)
    (write-region (format "# Plan %02d: build the thing %d\n\n### Task 1: first\n- [ ] a\n\n### Task 2: second\n- [x] b\n" i i) nil
                  (expand-file-name (format "docs/plans/2026-11-%02d-plan-%02d.md" (1+ (% i 28)) i) root) nil 'silent))
  (drgnx-scn-wmap--git root "add" "-A")
  (drgnx-scn-wmap--git root "commit" "-qm" "bulk records"))

(defun drgnx-scn-wmap--map ()
  "The Work map's buffer, or nil."
  (car (and (fboundp 'drgnx-work-map-buffers) (drgnx-work-map-buffers))))

(defun drgnx-scn-wmap--drawn-p ()
  "Whether the map's buffer draws at least one card."
  (when-let* ((b (drgnx-scn-wmap--map)))
    (and (> (buffer-size b) 0) (> (hash-table-count (with-current-buffer b (drgnx-work-map--drawn-ids))) 0))))

(defun drgnx-scn-wmap--state (buf)
  "What BUF's map shows and why, for a failure: its text, cards, view, client status, env classes."
  (if (not (buffer-live-p buf))
      (format "no map buffer (buffers: %S)" (mapcar #'buffer-name (buffer-list)))
    (with-current-buffer buf
      (let ((view drgnx-work-space--view))
        (format "buffer %s, %d chars, cards %d, view %S, client status %S, env classes %S, shown in %S; hub: %S; messages: %S; events live %S; text: %S"
                (buffer-name) (buffer-size)
                (if (fboundp 'drgnx-work-map--drawn-ids) (hash-table-count (drgnx-work-map--drawn-ids)) -1)
                view
                (ignore-errors (drgnx-work-client--view-status (drgnx-work-client--get view)))
                (ignore-errors (drgnx-view-env-classes view))
                (get-buffer-window-list buf nil t)
                (list :running (ignore-errors (drgnx-hub-running-p))
                      :subscribing (and (boundp 'drgnx-hub--subscribing) drgnx-hub--subscribing)
                      :ensuring (and (boundp 'drgnx-hub--ensuring) drgnx-hub--ensuring)
                      :no-start (getenv "DRGNX_NO_HUB_START") :inhibit inhibit-interaction)
                (with-current-buffer "*Messages*" (buffer-substring-no-properties (max (point-min) (- (point-max) 1200)) (point-max)))
                (and (boundp 'drgnx-hub--events) drgnx-hub--events t)
                (buffer-substring-no-properties (point-min) (min (point-max) 600)))))))

(defun drgnx-scn-wmap--evidence (name text)
  "Write TEXT as NAME in the run's evidence folder (DRGNX_UI_EVIDENCE), when there is one."
  (when-let* ((dir (getenv "DRGNX_UI_EVIDENCE")) ((file-directory-p dir)))
    (write-region text nil (expand-file-name name dir) t 'silent)))

(defun drgnx-scn-wmap--shot (name)
  "Keep a screenshot of the frame as NAME.png in the evidence folder."
  (when-let* ((dir (getenv "DRGNX_UI_EVIDENCE")) ((file-directory-p dir))
              (shot (plist-get (drgnx-uitest-capture (make-temp-file "work-map" t)) :root)))
    (copy-file shot (expand-file-name (concat name ".png") dir) t)))

(defun drgnx-scn-wmap--wait (pred)
  "Wait up to 15 s, in the harness's own pauses (the hub starts, subscribes, adopts, sends the rows), until PRED holds;
the last report and whether it held."
  (let ((report nil) (n 0) ok)
    (while (and (not (setq ok (funcall pred))) (< n 15))
      (setq report (drgnx-uitest-run (list (cons 'drgnx-uitest-pause 1)) 10) n (1+ n)))
    (list report ok n)))

(defvar drgnx-scn-wmap--bulk-sizes nil "When non-nil, (SPECS . PLANS) more records the folder gets.")

(defmacro drgnx-scn-wmap--with-work (&rest body)
  "Run BODY with Work opened by its key on a folder like yours: its own repository with specs and plans, two
repositories nested in it, the store empty (a first start); `report' is the key's report."
  (declare (indent 0))
  `(drgnx-scenario-settling
    (drgnx-scenario-load-driver)
    (drgnx-scenario-with-fixture (root 'basic)
      (drgnx-scn-wmap--folder root)
      (when drgnx-scn-wmap--bulk-sizes
        (drgnx-scn-wmap--bulk root (car drgnx-scn-wmap--bulk-sizes) (cdr drgnx-scn-wmap--bulk-sizes)))
      (drgnx-driver-reset)
      (drgnx-driver-open-file (expand-file-name "docs/plans/2026-11-16-search-view.md" root))
      (drgnx-driver-show-sidebar)             ; the driver's hub: a session starts none (DRGNX_NO_HUB_START)
      (drgnx-uitest-run nil)
      (let ((report (drgnx-uitest-run (drgnx-uitest-key-events (drgnx-driver--key 'work-view)))))
        ,@body))))

(defun drgnx-scn-wmap--text-p (text)
  "Whether the map's buffer shows TEXT."
  (when-let* ((b (drgnx-scn-wmap--map)))
    (with-current-buffer b (string-search text (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest drgnx-scenario/work-map-draws-on-a-folder-like-yours ()
  "Work on a folder that is a repository with specs and plans and two repositories nested in it, the store empty (a
first start): the map draws, at once, its strip and the machine's card; never a blank buffer."
  (drgnx-scn-wmap--with-work
    (pcase-let ((`(,r ,drawn ,n) (drgnx-scn-wmap--wait #'drgnx-scn-wmap--drawn-p))
                (state nil))
      (setq state (drgnx-scn-wmap--state (drgnx-scn-wmap--map)))
      (drgnx-scn-wmap--evidence "work-map.txt" (format "first start: drawn %s after %d s; %s\n" drawn n state))
      (drgnx-scenario-check drawn (concat "the Work map drew nothing within 15 s: " state) (or r report)))))

(ert-deftest drgnx-scenario/work-map-adopts-and-draws-the-folders-specs-and-plans ()
  "The same first start: the folder's spec and plan are adopted (\"drgnx takes over\") and drawn as cards, without
the user asking; no silent blank while it works."
  (drgnx-scn-wmap--with-work
    (pcase-let ((`(,r ,ok ,n) (drgnx-scn-wmap--wait (lambda () (drgnx-scn-wmap--text-p "Search view")))))
      (drgnx-scn-wmap--shot "work-map-adopted")
      (drgnx-scn-wmap--evidence "work-map-adopted.txt"
                                (format "adopted: shown %s after %d s; %s\n" ok n
                                        (drgnx-scn-wmap--state (drgnx-scn-wmap--map))))
      (drgnx-scenario-check ok (concat "the folder's spec and plan were not drawn within 15 s: "
                                       (drgnx-scn-wmap--state (drgnx-scn-wmap--map)))
                            (or r report)))))

(ert-deftest drgnx-scenario/work-map-on-an-org-folder-sized-store ()
  "The org folder's shape (about 40 specs and 60 plans, nested repositories): adopted and drawn, a screenshot of what
the user sees (kept in the evidence folder at the run's scale)."
  (let ((drgnx-scn-wmap--bulk-sizes '(40 . 60)))
    (drgnx-scn-wmap--with-work
      (pcase-let ((`(,r ,ok ,n) (drgnx-scn-wmap--wait (lambda () (drgnx-scn-wmap--text-p "Plan 59")))))
        (drgnx-uitest-run (list (cons 'drgnx-uitest-pause 1)) 10)
        (drgnx-scn-wmap--shot (format "work-map-org-%s" (or (getenv "DRGNX_UI_SCALE") "1")))
        (drgnx-scn-wmap--evidence "work-map-org.txt"
                                  (format "org-sized: shown %s after %d s; %s\n" ok n
                                          (drgnx-scn-wmap--state (drgnx-scn-wmap--map))))
        (drgnx-scenario-check ok (concat "the org-sized store was not drawn within 15 s: "
                                         (drgnx-scn-wmap--state (drgnx-scn-wmap--map)))
                              (or r report))))))

(defun drgnx-scn-wmap--lens-click-xy (label)
  "Root-frame pixel (X . Y) of the middle of LABEL on the map's lens bar (its tab line), or nil."
  (when-let* ((buf (drgnx-scn-wmap--map)) (win (get-buffer-window buf)))
    (with-current-buffer buf
      (let* ((bar (format-mode-line drgnx-work-map--lens nil win buf))
             (i (string-match (concat " " (regexp-quote label) " ") bar)))
        (when i
          (let* ((x0 (string-pixel-width (substring bar 0 i) buf))
                 (w (string-pixel-width (substring bar i (+ i (length label) 2)) buf))
                 (edges (window-pixel-edges win)))
            (cons (+ (nth 0 edges) x0 (/ w 2)) (+ (nth 1 edges) (/ (window-tab-line-height win) 2)))))))))

(ert-deftest drgnx-scenario/work-lens-names-switch-the-view-on-a-click ()
  "A click on a lens name (Board, Timeline, Flow) of the map's bar shows that view (audit W2: the names lit on hover
and did nothing)."
  (drgnx-scn-wmap--with-work
    (drgnx-scn-wmap--wait #'drgnx-scn-wmap--drawn-p)
    (dolist (lens '(("Board" . drgnx-work-board-mode) ("Flow" . drgnx-work-flow-mode)))
      (select-window (get-buffer-window (drgnx-scn-wmap--map)))
      (let ((xy (drgnx-scn-wmap--lens-click-xy (car lens))))
        (drgnx-scenario-check xy (format "no %s label on the lens bar: %S" (car lens)
                                         (format-mode-line (buffer-local-value 'drgnx-work-map--lens (drgnx-scn-wmap--map))))
                              nil)
        (drgnx-uitest-run (drgnx-uitest-click-events (drgnx-uitest-posn (car xy) (cdr xy)) 1 1 0.1))
        (pcase-let ((`(,r ,ok ,_) (drgnx-scn-wmap--wait
                                   (lambda () (seq-some (lambda (w) (eq (buffer-local-value 'major-mode (window-buffer w)) (cdr lens)))
                                                        (window-list nil 'no-minibuf))))))
          (drgnx-scenario-check ok (format "a click on %s at %S did not show %s; windows: %S" (car lens) xy (cdr lens)
                                           (mapcar (lambda (w) (buffer-local-value 'major-mode (window-buffer w))) (window-list)))
                                r))
        ;; back to the map for the next label
        (drgnx-uitest-run (drgnx-uitest-key-events (drgnx-driver--key 'work-view)))))))

;;; work-map-graph-test.el ends here
