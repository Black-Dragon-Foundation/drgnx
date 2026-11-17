;;; fold-hub-test.el --- batch tests: a file's folds are remembered by the real hub (module editor/fold) -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The hub runs as its own process (Ratatoskr from DRGNX_RATATOSKR_BIN, a test-hooks build) and keeps a file's folds
;; as Urdr records (`folds/save', `folds/load'); this Emacs, on Nidhogg's line model, folds, saves, kills and opens the
;; file again.  Each test runs inside the delivery gate, which serves the client's lines in the order written, so a
;; `folds/load' after a save reads what the save wrote; what the hub holds is read back with `folds/load'.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx)
(require 'drgnx-hub-client)
(load (expand-file-name "modules/editor/drgnx-fold" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/delivery-gate-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/hub-client-fixture" drgnx-dir) nil t)   ; its Ratatoskr helpers
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(declare-function drgnx-test-require-nidhogg "run-ert" (present what))

(defconst fold-hub-test--text
  "def a():\n    x = 1\n    if x:\n        y = 2\n    z = 3\ndef b():\n    w = 4\n"
  "Indentation ranges: a (lines 1–5), its `if' (3–4), b (6–7).")

(defmacro fold-hub-test--with (&rest body)
  "BODY with a gated hub serving ROOT's dirs (`drgnx-hub-client-test--with-hub'), this Emacs not connected: BODY
connects inside `drgnx-test-gated'.  FILE is a.txt (`fold-hub-test--text') in the git worktree PROJECT, the module
editor/fold is on (set up first: its fresh dirs would hide the hub's socket); FILE's buffers are gone at the end,
sending nothing."
  (declare (indent 0))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-lines-set-fold-sources) "nidhogg-lines-set-fold-sources")
     (drgnx-test-with-modules '(editor/fold)
       (drgnx-hub-client-test--with-hub
         (let* ((project (file-name-as-directory (concat root "proj"))) (file (concat project "a.txt")))
           (make-directory project t)
           (let ((default-directory project)) (call-process "git" nil nil nil "init" "-q"))
           (write-region fold-hub-test--text nil file nil 'silent)
           (unwind-protect (progn ,@body)
             (dolist (b (buffer-list))
               (when (equal (buffer-file-name b) file)
                 (with-current-buffer b (setq-local drgnx-fold-remember nil) (set-buffer-modified-p nil))
                 (kill-buffer b)))))))))

(defun fold-hub-test--line (n)
  "The start of line N."
  (save-excursion (goto-char (point-min)) (forward-line (1- n)) (point)))

(defun fold-hub-test--hidden ()
  "The lines hidden, as numbers."
  (cl-loop for n from 1 to (count-lines (point-min) (point-max)) when (invisible-p (fold-hub-test--line n)) collect n))

(defun fold-hub-test--select (from to)
  "Select lines FROM to TO."
  (transient-mark-mode 1)
  (goto-char (fold-hub-test--line from))
  (set-mark (point))
  (goto-char (fold-hub-test--line to))
  (end-of-line))

(defun fold-hub-test--kept (file)
  "The hub's records of FILE's folds, as `folds/load' gives them: (START END FOLD-KIND NAME OPEN) each."
  (mapcar (lambda (a) (list (plist-get a :start) (plist-get a :end) (plist-get a :fold_kind) (plist-get a :name)
                            (plist-get a :open)))
          (plist-get (drgnx-hub-call-sync "folds/load" (list :worktree (directory-file-name (file-name-directory file))
                                                             :path (file-name-nondirectory file))
                                          10)
                     :anchors)))

(defun fold-hub-test--fold-three ()
  "In the current buffer: the `if' (3–4) folded, a manual fold of b (6–7) named `bee' folded, and a manual fold of
lines 1–2 left open."
  (goto-char (fold-hub-test--line 3))
  (drgnx-fold-fold)
  (fold-hub-test--select 6 7)
  (drgnx-fold-create (region-beginning) (region-end) "bee")
  (fold-hub-test--select 1 2)
  (drgnx-fold-create (region-beginning) (region-end) nil)
  (goto-char (fold-hub-test--line 1))
  (drgnx-fold-unfold))

(defun fold-hub-test--open (file)
  "FILE opened again, its remembered folds waited for: its buffer."
  (let ((b (find-file-noselect file)))
    (drgnx-test-wait (lambda () (buffer-local-value 'drgnx-fold--sent b)) :secs 30 :what "the hub's folds of the file")
    b))

(defun fold-hub-test--manual (b)
  "B's manual folds: (FIRST-LINE NAME) each, by line."
  (with-current-buffer b
    (sort (mapcar (lambda (m) (list (line-number-at-pos (nth 0 m)) (nth 2 m))) drgnx-fold--manual)
          (lambda (x y) (< (car x) (car y))))))

(ert-deftest drgnx-fold-hub/folds-come-back-when-the-file-opens-again ()
  "Folds of the table, a named manual fold and an open one go to the hub an idle while after the change, and come
back, each on its line, when the file opens again."
  (fold-hub-test--with
    (drgnx-test-gated '((:answers t))
      (let* ((b (find-file-noselect file))
             (hidden (with-current-buffer b (fold-hub-test--fold-three) (fold-hub-test--hidden)))
             ;; a fold change waits for 30 s of idleness; the debounce's end sends
             (pending (drgnx-timer-active-p (cons 'drgnx-fold-save b))))
        (drgnx-fold--save-idle b)
        (drgnx-test-deliver-all)
        (should (equal hidden '(4 7)))
        (should pending)
        (should (equal (fold-hub-test--kept file) '((1 2 "manual" nil t) (3 4 "block" nil nil) (6 7 "manual" "bee" nil))))
        (kill-buffer b))
      (let ((b (fold-hub-test--open file)))
        (drgnx-test-deliver-all)
        (should (equal (with-current-buffer b (fold-hub-test--hidden)) '(4 7)))
        (should (equal (fold-hub-test--manual b) '((1 nil) (6 "bee"))))
        (with-current-buffer b
          (goto-char (fold-hub-test--line 6))
          (should (string-match-p "bee" (overlay-get (car (drgnx-fold--line-overlays)) 'display))))))))

(ert-deftest drgnx-fold-hub/a-fold-moved-down-is-found-and-one-whose-line-changed-is-dropped ()
  "Ten lines added above the folds: each is found ten lines down by its first line's text; the fold whose first line
changed is dropped, and the hub then keeps the others where they are now."
  (fold-hub-test--with
    (drgnx-test-gated '((:answers t))
      (let ((b (find-file-noselect file)))
        (with-current-buffer b
          (fold-hub-test--fold-three)
          (set-buffer-modified-p t)
          (save-buffer))
        (kill-buffer b))
      (with-temp-file file
        (insert (mapconcat (lambda (n) (format "# note %d\n" n)) (number-sequence 1 10) ""))
        (insert (string-replace "def b():" "def bee():" fold-hub-test--text)))
      (let* ((b (fold-hub-test--open file))
             (hidden (with-current-buffer b (fold-hub-test--hidden)))
             (manual (fold-hub-test--manual b)))
        (kill-buffer b)
        (drgnx-test-deliver-all)
        (should (equal hidden '(14)))
        (should (equal manual '((11 nil))))
        (should (equal (mapcar (lambda (k) (butlast k 3)) (fold-hub-test--kept file)) '((11 12) (13 14))))))))

(ert-deftest drgnx-fold-hub/folds-made-with-no-hub-stay-and-go-to-the-next-one ()
  "With no hub, the file's folds stay in the buffer and nothing waits; the hub that comes up gets them."
  (fold-hub-test--with
    (let (hidden unsent)
      ;; no hub where this Emacs looks for one: the socket is looked for under the state dir
      (let ((process-environment (cons (concat "XDG_RUNTIME_DIR=" root "no-hub") process-environment)))
        (with-current-buffer (find-file-noselect file)
          (fold-hub-test--fold-three)
          (set-buffer-modified-p t)
          (save-buffer)
          (setq hidden (fold-hub-test--hidden) unsent (mapcar #'car drgnx-fold--unsent))))
      (drgnx-test-gated '((:answers t))
        (drgnx-hub-connect)
        (drgnx-test-wait (lambda () (null drgnx-fold--unsent)) :secs 30 :what "the kept folds sent to the hub that came up")
        (drgnx-test-deliver-all)
        (should (equal hidden '(4 7)))
        (should (equal unsent (list (cons (directory-file-name project) "a.txt"))))
        (should-not drgnx-fold--unsent)
        (should (= (length (fold-hub-test--kept file)) 3))))))

;;; fold-hub-test.el ends here
