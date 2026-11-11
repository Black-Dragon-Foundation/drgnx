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

;;;; Keys, mouse, copy mode, links and the program's requests

(defun drgnx-term-test--row-matching (buffer regexp)
  "The first of BUFFER's rows (as drawn now) that matches REGEXP, or nil."
  (seq-find (lambda (l) (string-match-p regexp l)) (drgnx-term-test--lines buffer)))

(ert-deftest drgnx-term/shell-key-sends-term-key ()
  ;; C-d is a raw key: it reaches the shell, which ends at an empty prompt, and its buffer goes
  (drgnx-term-test--with
    (let ((b (drgnx-term-test--start)))
      (with-current-buffer b
        (should (eq (key-binding [?\C-d]) #'drgnx-term-send-event))
        (let ((last-command-event ?\C-d)) (drgnx-term-send-event)))
      (drgnx-term-test--settle (lambda () (not (buffer-live-p b))) "the shell ended, its buffer gone"))))

(ert-deftest drgnx-term/paste-is-bracketed-when-asked ()
  (drgnx-term-test--with
    (let ((b (drgnx-term-test--start)) (kill-ring nil))
      (drgnx-term-test--run b "printf '\\033[?2004h'; echo pa''ste-ready; cat -v")
      (drgnx-term-test--until-line b "paste-ready" "bracketed paste asked for")
      (kill-new "pasted")
      (with-current-buffer b (drgnx-term-paste))
      ;; the tty echoes what reached it: the paste inside its brackets
      (drgnx-term-test--settle (lambda () (drgnx-term-test--row-matching b "\\^\\[\\[200~pasted"))
                               "the bracketed paste"))))

(ert-deftest drgnx-term/mouse-goes-to-program-only-while-tracking ()
  (drgnx-term-test--with
    (let ((b (drgnx-term-test--start)))
      (drgnx-term-test--run b "echo no-mo''use")
      (drgnx-term-test--until-line b "no-mouse" "the echo")
      (with-current-buffer b (should-not (eq (key-binding [down-mouse-1]) #'drgnx-term-mouse)))
      (drgnx-term-test--run b "printf '\\033[?1000h'; echo mo''use-ready; cat -v")
      (drgnx-term-test--until-line b "mouse-ready" "mouse tracking asked for")
      (drgnx-term-test--settle
       (lambda () (with-current-buffer b
                    (eq (plist-get (drgnx-view-patch-term drgnx-view-patch) :mouse_tracking) t)))
       "the patch says the program tracks the mouse")
      (let ((w (get-buffer-window b t)))
        (with-current-buffer b
          (should (eq (key-binding [down-mouse-1]) #'drgnx-term-mouse))
          (drgnx-term-mouse (list 'down-mouse-1 (posn-at-point (save-excursion (goto-char (point-max))
                                                                               (line-beginning-position))
                                                               w)))))
      (drgnx-term-test--settle (lambda () (drgnx-term-test--row-matching b "\\^\\[\\[M")) "the press reached the program"))))

(ert-deftest drgnx-term/key-release-reaches-a-program-that-asks ()
  ;; CSI > 11 u: every key as an escape code, with its event type; the tty echoes what reached it
  (drgnx-term-test--with
    (let ((b (drgnx-term-test--start)) (drgnx-term--held nil) (drgnx-term-scroll-to-bottom nil))
      (drgnx-term-test--run b "printf '\\033[>11u'; echo kk''p-ready; cat -v")
      (drgnx-term-test--until-line b "kkp-ready" "event types asked for")
      (drgnx-term-test--settle (lambda () (drgnx-term--key-events-p b)) "the patch says the program wants key events")
      (with-current-buffer b (let ((last-command-event ?a)) (drgnx-term-send-event)))
      (drgnx-term-key-release '(key-release ?a))
      (drgnx-term-test--settle (lambda () (drgnx-term-test--row-matching b "\\^\\[\\[97;1:3u"))
                               "the release reached the program"))))

(ert-deftest drgnx-term/copy-mode-pauses-and-isearch-works ()
  (drgnx-term-test--with
    (let ((b (drgnx-term-test--start)))
      (drgnx-term-test--run b "echo before-co''py")
      (drgnx-term-test--until-line b "before-copy" "the echo")
      (with-current-buffer b (drgnx-term-copy-mode 1))
      (drgnx-term-test--run b "echo during-co''py")
      (drgnx-term-test--settle
       (lambda () (with-current-buffer b (> (car (drgnx-view-patch-paused drgnx-view-patch)) 0)))
       "a patch kept while paused")
      (with-current-buffer b
        ;; the screen stands still, and the buffer has Emacs's keys: isearch finds the text
        (should-not (member "during-copy" (mapcar #'string-trim-right (drgnx-term-test--lines b))))
        (should-not (eq (key-binding "a") #'drgnx-term-send-event))
        (should (eq (key-binding [remap keyboard-quit]) #'drgnx-term-copy-mode))
        (goto-char (point-max))
        (let ((isearch-forward nil)) (should (isearch-search-string "before-copy" nil t)))
        (drgnx-term-copy-mode -1)
        (should (eq (key-binding "a") #'drgnx-term-send-event)))
      (drgnx-term-test--until-line b "during-copy" "the kept output drawn on leaving"))))

(ert-deftest drgnx-term/find-in-terminal-jumps ()
  (drgnx-term-test--with
    (let ((b (drgnx-term-test--start)))
      (drgnx-term-test--run b "echo find-me-here")
      (drgnx-term-test--until-line b "find-me-here" "the echo")
      (with-current-buffer b (drgnx-term-find "find-me"))
      (drgnx-term-test--settle (lambda () (buffer-local-value 'drgnx-term-copy-mode b)) "the match shown")
      (with-current-buffer b
        ;; newest first: the echoed row, not the typed command above it
        (should (looking-at "find-me-here"))
        (should (eq (overlay-get drgnx-term--find-overlay 'face) 'drgnx-term-search-selected))
        (drgnx-term-copy-mode -1)))))

(ert-deftest drgnx-term/find-next-and-previous-walk-the-replica ()
  ;; pattern C (handshake: each step settles on the condition the hub's lines bring)
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
  (drgnx-term-test--with
    (let ((b (drgnx-term-test--start)) (asked 0))
      (drgnx-term-test--run b "printf 'f%s\\n' x-1 x-2 x-3")
      (drgnx-term-test--until-line b "fx-3" "the three rows")
      (cl-letf* ((call (symbol-function 'drgnx-hub--call-on))
                 ((symbol-function 'drgnx-hub--call-on)
                  (lambda (proc method &rest args)
                    (when (equal method "term/search") (cl-incf asked))
                    (apply call proc method args))))
        (with-current-buffer b (drgnx-term-find "fx-"))
        (drgnx-term-test--settle (lambda () (buffer-local-value 'drgnx-term-copy-mode b)) "the first match shown")
        (with-current-buffer b
          ;; newest first, then older, then back; only the first Find asked the hub
          (should (looking-at "fx-3"))
          (drgnx-term-find-next)
          (should (looking-at "fx-2"))
          (drgnx-term-find-next)
          (should (looking-at "fx-1"))
          (drgnx-term-find-previous)
          (should (looking-at "fx-2"))
          (drgnx-term-find "fx-")          ; asked again with the same text: the next older one
          (should (looking-at "fx-1"))
          (should (eq (overlay-get drgnx-term--find-overlay 'face) 'drgnx-term-search-selected))
          (should (= (overlay-end drgnx-term--find-overlay) (+ (point) 3)))
          (should (= asked 1))
          (drgnx-term-copy-mode -1))))))

(ert-deftest drgnx-term/osc8-link-opens-file ()
  (drgnx-term-test--with
    (let* ((b (drgnx-term-test--start)) (file (make-temp-file "drgnx-term-link")) (uri (concat "file://" file)))
      (unwind-protect
          (progn
            (drgnx-term-test--run b (concat "printf '\\033]8;;" uri "\\033\\\\link-text\\033]8;;\\033\\\\\\n'"))
            (drgnx-term-test--settle (lambda () (drgnx-term-test--row-matching b "\\`link-text")) "the link")
            (with-current-buffer b
              (let ((pos (save-excursion (goto-char (point-min)) (re-search-forward "^link-text") (match-beginning 0))))
                (should (equal (get-text-property pos 'drgnx-term-link) uri))
                (should (get-text-property pos 'mouse-face))
                (drgnx-term-open-link pos)))
            (should (get-file-buffer file)))
        (when (get-file-buffer file) (kill-buffer (get-file-buffer file)))
        (delete-file file)))))

(ert-deftest drgnx-term/osc52-write-reaches-kill-ring ()
  (drgnx-term-test--with
    (let ((b (drgnx-term-test--start)) (kill-ring nil) (interprogram-cut-function nil))
      (drgnx-term-test--run b (format "printf '\\033]52;c;%s\\007'" (base64-encode-string "from-osc52")))
      (drgnx-term-test--settle (lambda () (equal (car kill-ring) "from-osc52")) "the program's copy in the kill ring"))))

(ert-deftest drgnx-term/osc52-read-refused-by-default ()
  ;; a read gets no answer: nothing reaches the program before what is typed after it
  (drgnx-term-test--with
    (let ((b (drgnx-term-test--start)))
      (drgnx-term-test--run b "printf '\\033]52;c;?\\007'; cat -v")
      (drgnx-term-test--settle (lambda () (drgnx-term-test--row-matching b "cat -v")) "the command typed")
      (drgnx-term-test--run b "end52")
      (drgnx-term-test--settle
       (lambda () (>= (seq-count (lambda (l) (equal (string-trim-right l) "end52")) (drgnx-term-test--lines b)) 2))
       "the typed line echoed and printed")
      (should-not (drgnx-term-test--row-matching b "\\^\\[\\]52")))))

(ert-deftest drgnx-term/osc7-sets-default-directory ()
  (drgnx-term-test--with
    (let* ((b (drgnx-term-test--start)) (dir (file-name-as-directory (make-temp-file "drgnx-term-cwd" t))))
      (unwind-protect
          (progn
            (drgnx-term-test--run b (format "printf '\\033]7;file://%s\\007'" (directory-file-name dir)))
            (drgnx-term-test--settle (lambda () (equal (buffer-local-value 'default-directory b) dir))
                                     "the buffer's directory follows the shell"))
        (delete-directory dir t)))))

(ert-deftest drgnx-term/resize-debounced ()
  (drgnx-term-test--with
    (let* ((b (drgnx-term-test--start)) (w (get-buffer-window b t)) (before (buffer-local-value 'drgnx-term--resizes b)))
      (with-selected-window w
        (split-window w nil 'below)
        (drgnx-term--windows-changed)
        (drgnx-term--windows-changed))
      ;; two changes within the 50 ms: one resize
      (drgnx-test-advance 0.06)
      (should (= (buffer-local-value 'drgnx-term--resizes b) (1+ before)))
      (let ((size (buffer-local-value 'drgnx-term--size b)))
        (drgnx-term-test--run b "stty size")
        (drgnx-term-test--settle (lambda () (drgnx-term-test--row-matching b "\\`[0-9]+ [0-9]+ *\\'")) "stty's answer")
        (should (equal (string-trim-right (drgnx-term-test--row-matching b "\\`[0-9]+ [0-9]+ *\\'"))
                       (format "%d %d" (nth 1 size) (nth 0 size))))))))

;;;; Quitting

(ert-deftest drgnx-term/quit-question-lists-running-terminal ()
  ;; a terminal whose shell runs a program is named by the quit question; one at its prompt is not
  (drgnx-term-test--with
    (let ((busy (drgnx-term-test--start)) (idle (drgnx-term-test--start)))
      (drgnx-term-test--run busy "echo g''o; sleep 30")
      (drgnx-term-test--until-line busy "go" "the echo before the sleep")
      (let ((rows (drgnx-term-test--ask "term/list" nil)))
        (should (equal (drgnx-term--running-names rows (list busy idle)) (list (buffer-name busy))))
        (should (memq 'drgnx-term-running drgnx-session-running-functions))))))

(ert-deftest drgnx-term-settings/live-setting-reaches-worker ()
  ;; a change of `drgnx-term-cursor-style' reaches the open terminal's worker at once: its cursor is drawn as a bar
  (drgnx-term-test--with
    (let ((b (drgnx-term-test--start)))
      (should (eq (buffer-local-value 'cursor-type b) 'box))
      (let ((drgnx-term-cursor-style "bar")) (drgnx-term--apply-config))
      (drgnx-term-test--settle (lambda () (equal (buffer-local-value 'cursor-type b) '(bar . 2))) "the bar cursor")
      (should (equal (buffer-local-value 'cursor-type b) '(bar . 2))))))

(provide 'term-test)
;;; term-test.el ends here
