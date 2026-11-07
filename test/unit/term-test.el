;;; term-test.el --- batch tests: drgnx's own terminal against a real hub and its worker -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The hub runs as its own process (a test-hooks Ratatoskr behind the delivery gate) and starts the real terminal
;; worker (`drgnx-term', beside the hub's binary) for each terminal; this Emacs plays the editor with the module
;; tools/term on.  The shell is /bin/sh with a plain prompt.  What the shell printed is a condition the tests settle on
;; after each release of the hub's lines, never a deadline.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/delivery-gate-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/unit/hub-client-test" drgnx-dir) nil t)   ; its Ratatoskr helpers
(load (expand-file-name "modules/tools/drgnx-terminal" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-term" drgnx-dir) nil t)

(defun drgnx-term-test--worker ()
  "The terminal worker beside the hub's binary, or nil."
  (when-let* ((bin (drgnx-hub-client-test--bin))
              (w (expand-file-name "drgnx-term" (file-name-directory bin))))
    (and (file-executable-p w) w)))

(defmacro drgnx-term-test--with (&rest body)
  "BODY inside `drgnx-test-gated' with a gated Ratatoskr serving drgnx's dirs under ROOT, the module tools/term on,
this Emacs subscribed and $SHELL /bin/sh with the prompt \"$ \".  Every terminal is gone after.  Skipped without the
hub or its worker."
  (declare (indent 0))
  `(drgnx-hub-client-test--with-hub
     (skip-unless (drgnx-term-test--worker))
     (drgnx-test-gated '()
       (let ((drgnx-view-patch--buffers (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
             (env (append (list "SHELL=/bin/sh" "PS1=$ " "ENV" "BASH_ENV" "HISTFILE=/dev/null") process-environment)))
         (drgnx-test-with-modules '(tools/term)
           (let ((process-environment env) (drgnx-term--buffers (make-hash-table :test #'equal))
                 (drgnx-term-scrollback-lines 10000))
             (unwind-protect
                 (progn
                   (drgnx-hub-connect)
                   (drgnx-term-test--settle (lambda () (process-live-p drgnx-hub--events)) "the subscription")
                   (drgnx-test-deliver-all)
                   ,@body)
               (dolist (b (buffer-list))
                 (when (eq (buffer-local-value 'major-mode b) 'drgnx-term-mode)
                   (let ((kill-buffer-query-functions nil)) (kill-buffer b)))))))))))

(defun drgnx-term-test--settle (pred what)
  "Wait until PRED holds, the hub's clock moved and what it has written released before each look."
  (drgnx-test-wait (lambda () (drgnx-test-hub-advance 100) (funcall pred)) :what what)
  (drgnx-test-deliver-all))

(defun drgnx-term-test--lines (buffer)
  "BUFFER's rows as drawn now (its view drawn first), a list of strings."
  (with-current-buffer buffer
    (when drgnx-view (drgnx-view-draw-now drgnx-view))
    (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n")))

(defun drgnx-term-test--until-line (buffer line what)
  "Wait until BUFFER shows a row that is exactly LINE (trailing blanks aside)."
  (drgnx-term-test--settle
   (lambda () (member line (mapcar #'string-trim-right (drgnx-term-test--lines buffer))))
   what))

(defun drgnx-term-test--start ()
  "A new terminal running the shell, its first prompt shown: its buffer."
  (let ((b (drgnx-terminal-new temporary-file-directory)))
    (should (eq (buffer-local-value 'major-mode b) 'drgnx-term-mode))
    (drgnx-term-test--settle (lambda () (seq-some (lambda (l) (string-prefix-p "$" l)) (drgnx-term-test--lines b)))
                             "the first prompt")
    b))

(defun drgnx-term-test--run (buffer command)
  "Type COMMAND and Return into BUFFER's terminal."
  (with-current-buffer buffer
    (drgnx-term-send-string command)
    (drgnx-term-send-key "return")))

(defun drgnx-term-test--numbers (buffer)
  "The rows of BUFFER that are a number alone, as numbers, in order."
  (delq nil (mapcar (lambda (l) (and (string-match-p "\\`[0-9]+\\'" l) (string-to-number l)))
                    (mapcar #'string-trim-right (drgnx-term-test--lines buffer)))))

(defun drgnx-term-test--ask (method params)
  "The hub's answer to METHOD with PARAMS, asked without a wait of its own."
  (let (done answer)
    (drgnx-hub-call method params (lambda (r e) (setq answer (or r e) done t)))
    (drgnx-term-test--settle (lambda () done) (format "the hub's answer to %s" method))
    answer))

(ert-deftest drgnx-term/new-terminal-runs-the-shell-in-a-worker ()
  (drgnx-term-test--with
    (let* ((b (drgnx-term-test--start)) (id (buffer-local-value 'drgnx-term--id b))
           (row (seq-find (lambda (r) (equal (plist-get r :id) id)) (drgnx-term-test--ask "term/list" nil))))
      (should (stringp id))
      (should (equal (drgnx-view-patch-view (buffer-local-value 'drgnx-view-patch b)) (concat "term:" id)))
      (should row)
      ;; the worker is a process of its own, not this Emacs's child
      (should (natnump (plist-get row :pid)))
      (should-not (memq (plist-get row :pid) (mapcar #'process-id (process-list))))
      (should (eq (buffer-local-value 'drgnx-term--shell b) t)))))

(ert-deftest drgnx-term/echo-appears ()
  (drgnx-term-test--with
    (let ((b (drgnx-term-test--start)))
      (drgnx-term-test--run b "echo hel''lo-term")
      (drgnx-term-test--until-line b "hello-term" "the echo")
      ;; the cursor follows the worker's: on the prompt after the echo
      (drgnx-term-test--settle
       (lambda () (with-current-buffer b
                    (and (drgnx-view-patch-term drgnx-view-patch)
                         (string-prefix-p "$" (buffer-substring (line-beginning-position) (line-end-position)))
                         (> (point) (save-excursion (goto-char (point-min)) (search-forward "hello-term" nil t))))))
       "point on the prompt after the echo"))))

(ert-deftest drgnx-term/flood-keeps-window-stale-then-backfills ()
  ;; during the flood the patches carry the screen only; after it, the rows that scrolled past fill in, newest first
  (drgnx-term-test--with
    (let ((b (drgnx-term-test--start)))
      (drgnx-term-test--run b "seq 1 3000")
      (drgnx-term-test--settle (lambda () (equal (drgnx-term-test--numbers b) (number-sequence 1 3000)))
                               "every row of the flood, in order"))))

(ert-deftest drgnx-term/scrollback-setting-trims-live ()
  (drgnx-term-test--with
    (let ((b (drgnx-term-test--start)))
      (drgnx-term-test--run b "seq 1 500")
      (drgnx-term-test--settle (lambda () (equal (drgnx-term-test--numbers b) (number-sequence 1 500))) "500 rows")
      (setq drgnx-term-scrollback-lines 50)
      (drgnx-term--apply-scrollback)
      (let ((screen (window-body-height (get-buffer-window b t))))
        (drgnx-term-test--settle
         (lambda () (let ((n (drgnx-term-test--numbers b)))
                      (and (member 500 n) (not (member 1 n))
                           (<= (length (drgnx-term-test--lines b)) (+ 50 screen 1)))))
         "the buffer trimmed to 50 rows above the screen")))))

(ert-deftest drgnx-term/scrollback-setting-raises-live ()
  (drgnx-term-test--with
    (setq drgnx-term-scrollback-lines 50)
    (let ((b (drgnx-term-test--start)))
      (drgnx-term-test--run b "seq 1 500")
      (drgnx-term-test--settle (lambda () (let ((n (drgnx-term-test--numbers b))) (and (member 500 n) (not (member 1 n)))))
                               "the last rows, the first gone")
      (setq drgnx-term-scrollback-lines 1000)
      (drgnx-term--apply-scrollback)
      (drgnx-term-test--settle (lambda () (equal (drgnx-term-test--numbers b) (number-sequence 1 500)))
                               "the rows above filled in again"))))

(ert-deftest drgnx-term/undo-is-off ()
  (drgnx-term-test--with
    (let ((b (drgnx-term-test--start)))
      (drgnx-term-test--run b "echo undo-off")
      (drgnx-term-test--until-line b "undo-off" "the echo")
      (should (eq (buffer-local-value 'buffer-undo-list b) t)))))

(ert-deftest drgnx-term/hub-away-queues-keys-then-flushes ()
  (drgnx-term-test--with
    (let ((b (drgnx-term-test--start)))
      (drgnx-hub-disconnect)
      (should-not (process-live-p drgnx-hub--events))
      (drgnx-term-test--run b "echo que''ued-ok")
      (with-current-buffer b
        (should (= (length drgnx-term--queue) 2))
        ;; the queue is bounded: past 4 kB input is dropped
        (drgnx-term-send-string (make-string 5000 ?x))
        (should (= (length drgnx-term--queue) 2))
        (should (<= drgnx-term--queued drgnx-term-queue-max)))
      (drgnx-hub-connect)
      (drgnx-term-test--settle (lambda () (process-live-p drgnx-hub--events)) "subscribed again")
      (drgnx-term-test--until-line b "queued-ok" "the queued command ran")
      (should-not (buffer-local-value 'drgnx-term--queue b)))))

(deftheme drgnx-term-test "A theme that changes the terminal's red, for the repaint row.")

(defun drgnx-term-test--bg-at (buffer text)
  "The background of the face on the first character of BUFFER's row that starts with TEXT (not the typed command)."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward (concat "^" (regexp-quote text)) nil t)
        (let ((f (get-text-property (match-beginning 0) 'face)))
          (plist-get (if (keywordp (car-safe f)) f (car-safe f)) :background))))))

(ert-deftest drgnx-term/theme-change-repaints-without-reset ()
  (drgnx-term-test--with
    (let ((b (drgnx-term-test--start)) keys before)
      (drgnx-term-test--run b "printf '\\033[41mRED\\033[0m\\n'")
      (drgnx-term-test--settle (lambda () (and (drgnx-term-test--lines b) (drgnx-term-test--bg-at b "RED"))) "red cells")
      (setq before (drgnx-term-test--bg-at b "RED")
            keys (with-current-buffer b (sort (hash-table-keys (drgnx-view-patch-rows drgnx-view-patch)) #'string<)))
      (custom-theme-set-faces 'drgnx-term-test '(ansi-color-red ((t :foreground "#aa0011"))))
      (unwind-protect
          (progn
            (enable-theme 'drgnx-term-test)
            (drgnx-term-test--lines b)
            (should (equal (drgnx-term-test--bg-at b "RED") "#aa0011"))
            (should-not (equal before "#aa0011"))
            ;; no reset: a reset gives every row a new key
            (should (equal (with-current-buffer b
                             (sort (hash-table-keys (drgnx-view-patch-rows drgnx-view-patch)) #'string<))
                           keys)))
        (disable-theme 'drgnx-term-test)))))

(ert-deftest drgnx-term/tty-frame-shows-terminal ()
  ;; a batch Emacs's frame is a terminal frame: the rows are text, the cursor a plain cursor
  (drgnx-term-test--with
    (should-not (display-graphic-p))
    (let ((b (drgnx-term-test--start)))
      (drgnx-term-test--run b "echo on-a-tty")
      (drgnx-term-test--until-line b "on-a-tty" "the echo")
      (with-current-buffer b
        (should (memq cursor-type '(box hollow)))
        (should-not (text-property-not-all (point-min) (point-max) 'display nil))))))

(provide 'term-test)
;;; term-test.el ends here
