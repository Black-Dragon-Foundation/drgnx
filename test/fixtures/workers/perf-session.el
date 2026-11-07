;;; perf-session.el --- session side of the off-the-main-thread workloads (§17.6) -*- lexical-binding: t -*-
;; Loaded into a perf session by the workloads' setup forms (harness/drgnx-perf-workloads.el).  Every workload follows one
;; shape: `:setup' builds its fixture, `:each' puts the session in its starting state and arms a fire function, the first
;; key typed runs that function from a timer (the work starts while the harness types, as it does for a user), the
;; function `drgnx-perf-w-X-done' says when the work is finished (the lab polls it at idle: `:complete-ms'),
;; `drgnx-perf-w-X-digest' returns a string that is equal whenever the work produced the same result (buffer text and
;; faces, messages, listings), and `:measure' returns the workload's own numbers (`drgnx-perf-w--stats').
;; Nothing here is a module: it registers nothing at top level and the teardown functions remove what a setup added.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'project)
(eval-and-compile
  (load (expand-file-name "generators" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(defvar drgnx-perf-w--root (file-name-directory (or load-file-name buffer-file-name)) "This directory.")
(defvar drgnx-perf-w--repo (expand-file-name "../../.." drgnx-perf-w--root) "The drgnx checkout.")
(defvar drgnx-perf-w--tmp nil "The temporary directory of the workload that is set up.")
(defvar drgnx-perf-w--fire nil "The function the first key starts.")
(defvar drgnx-perf-w--fired nil "Non-nil once the fire function was scheduled.")
(defvar drgnx-perf-w--stats nil "The numbers the workload measures itself (a plist; `:measure' returns it).")

(defun drgnx-perf-w--stat (key value) (setq drgnx-perf-w--stats (plist-put drgnx-perf-w--stats key value)))
(defun drgnx-perf-w--ms (since) (drgnx-perf--round (* 1000 (- (float-time) since))))

(defun drgnx-perf-w--key ()
  "Post-command: the first key schedules the fire function (from a timer, outside the command)."
  (when (and drgnx-perf-w--fire (not drgnx-perf-w--fired))
    (setq drgnx-perf-w--fired t)
    (run-with-timer 0 nil drgnx-perf-w--fire)))

(defun drgnx-perf-w--arm (fire)
  "Run FIRE after the first key; forget what an earlier run measured."
  (setq drgnx-perf-w--fire fire drgnx-perf-w--fired nil drgnx-perf-w--stats nil)
  (add-hook 'post-command-hook #'drgnx-perf-w--key))

(defun drgnx-perf-w--disarm ()
  (remove-hook 'post-command-hook #'drgnx-perf-w--key)
  (setq drgnx-perf-w--fire nil drgnx-perf-w--fired nil))

(defun drgnx-perf-w--tmpdir ()
  (or (and drgnx-perf-w--tmp (file-directory-p drgnx-perf-w--tmp) drgnx-perf-w--tmp)
      (setq drgnx-perf-w--tmp (make-temp-file "drgnx-perf-w" t))))

(defun drgnx-perf-w--clean ()
  (when (and drgnx-perf-w--tmp (file-directory-p drgnx-perf-w--tmp))
    (delete-directory drgnx-perf-w--tmp t))
  (setq drgnx-perf-w--tmp nil))

(defun drgnx-perf-w--kill-visiting (dir)
  (dolist (b (buffer-list))
    (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b)))
      (with-current-buffer b (set-buffer-modified-p nil))
      (kill-buffer b))))

;;;; What a window shows: faces, text

(defun drgnx-perf-w--visible-digest (&optional window)
  "md5 of the text and faces of the region WINDOW shows."
  (let* ((window (or window (selected-window))) (beg (window-start window)) (end (window-end window t)) (parts nil) (pos beg))
    (with-current-buffer (window-buffer window)
      (while (< pos end)
        (let ((next (min end (or (next-single-property-change pos 'face nil end) end))))
          (push (cons (buffer-substring-no-properties pos next) (get-text-property pos 'face)) parts)
          (setq pos next))))
    (secure-hash 'md5 (format "%S" (nreverse parts)))))

(defun drgnx-perf-w--colored-p (&optional window)
  "The region WINDOW shows is fontified and has a face somewhere in it."
  (let* ((window (or window (selected-window))) (beg (window-start window)) (end (window-end window t)))
    (and (> end beg)
         (with-current-buffer (window-buffer window)
           (and (not (text-property-any beg end 'fontified nil))
                (text-property-not-all beg end 'face nil))))))

;;;; Tree-sitter: ts-open, ts-paste, ts-typing, ts-typing-unclosed

(defconst drgnx-perf-w--ts-cases
  '((c-ts-mode c ".c" c) (typescript-ts-mode typescript ".ts" ts) (python-ts-mode python ".py" py))
  "(MODE GRAMMAR SUFFIX KIND): the languages of the tree-sitter workloads.")

(defvar drgnx-perf-w--ts-files nil "((MODE MB . FILE)…) written by `drgnx-perf-w-ts-setup'.")
(defvar drgnx-perf-w--ts-queue nil)
(defvar drgnx-perf-w--ts-digests nil)
(defvar drgnx-perf-w--ts-finished nil)
(defvar drgnx-perf-w--other-window nil "The window the ts-open files are shown in.")

(defun drgnx-perf-w--ts-visit (file mode &optional window)
  "FILE visited in MODE (the tree-sitter one) and shown in WINDOW (default: the selected one)."
  (let* ((case (assq mode drgnx-perf-w--ts-cases))
         (auto-mode-alist (cons (cons (concat (regexp-quote (nth 2 case)) "\\'") mode) auto-mode-alist)))
    (unless (treesit-language-available-p (nth 1 case)) (error "No tree-sitter grammar for %s" (nth 1 case)))
    (let ((buf (find-file-noselect file)))
      (unless (eq (buffer-local-value 'major-mode buf) mode) (error "%s opened in %s" file (buffer-local-value 'major-mode buf)))
      (set-window-buffer (or window (selected-window)) buf)
      buf)))

(defun drgnx-perf-w-ts-setup (&optional mbs)
  "The sources: each language at MBS (default (1 2)) megabytes."
  (drgnx-perf-w--tmpdir)
  (setq drgnx-perf-w--ts-files nil)
  (dolist (mb (or mbs '(1 2)))
    (dolist (c drgnx-perf-w--ts-cases)
      (let ((file (expand-file-name (format "src%d-%s%s" mb (nth 3 c) (nth 2 c)) drgnx-perf-w--tmp)))
        (with-temp-file file (insert (drgnx-perf-w-gen-source (nth 3 c) (* mb 1000 1000))))
        (push (list (car c) mb file) drgnx-perf-w--ts-files))))
  (setq drgnx-perf-w--ts-files (nreverse drgnx-perf-w--ts-files))
  t)

(defun drgnx-perf-w--ts-file (mode mb)
  (nth 2 (seq-find (lambda (f) (and (eq (car f) mode) (= (cadr f) mb))) drgnx-perf-w--ts-files)))

;; ts-open: the six files (3 languages x 1 and 2 MB) opened one after the other in a second window while the keys go to
;; the editor; each: the visit, the first draw, and the time until the visible region is coloured.

(defun drgnx-perf-w-ts-open-each ()
  (when (window-live-p drgnx-perf-w--other-window) (delete-window drgnx-perf-w--other-window))
  (setq drgnx-perf-w--other-window (split-window (selected-window) nil 'right)
        drgnx-perf-w--ts-queue (mapcar (lambda (f) f) drgnx-perf-w--ts-files)
        drgnx-perf-w--ts-digests nil drgnx-perf-w--ts-finished nil)
  (drgnx-perf-w--arm #'drgnx-perf-w--ts-open-next)
  t)

(defun drgnx-perf-w--ts-open-next ()
  (if (null drgnx-perf-w--ts-queue)
      (setq drgnx-perf-w--ts-finished t)
    (pcase-let* ((`(,mode ,mb ,file) (pop drgnx-perf-w--ts-queue)) (key (format "%s-%dMB" mode mb))
                 (t0 (float-time)))
      (drgnx-perf-w--ts-visit file mode drgnx-perf-w--other-window)
      (let ((visited (float-time)))
        (redisplay t)
        (drgnx-perf-w--stat :draw_ms (max (or (plist-get drgnx-perf-w--stats :draw_ms) 0) (drgnx-perf-w--ms visited)))
        (drgnx-perf-w--ts-await key visited t0)))))

(defun drgnx-perf-w--ts-await (key visited t0 &optional colored)
  "Poll until the other window shows colour (at most 5 s), then record and go on to the next file.
The latency stats are taken at the first colour (COLORED is when that was seen), but the digest waits for the colour to
settle (`drgnx-perf-w--ts-settled-p', at most 5 s more): with the workers' deferral a deferred chunk counts as
fontified while still plain, so a digest at first colour can catch a half-coloured window."
  (let ((now (float-time)))
    (when (and (not colored)
               (or (drgnx-perf-w--colored-p drgnx-perf-w--other-window) (> (- now visited) 5)))
      (setq colored now)
      (drgnx-perf-w--stat :colored_ms (max (or (plist-get drgnx-perf-w--stats :colored_ms) 0) (drgnx-perf-w--ms visited)))
      (drgnx-perf-w--stat :visit_ms (max (or (plist-get drgnx-perf-w--stats :visit_ms) 0)
                                         (drgnx-perf-w--ms t0))))
    (if (and colored
             (or (drgnx-perf-w--ts-settled-p drgnx-perf-w--other-window) (> (- now colored) 5)))
        (progn
          (push (cons key (drgnx-perf-w--visible-digest drgnx-perf-w--other-window)) drgnx-perf-w--ts-digests)
          (let ((buf (window-buffer drgnx-perf-w--other-window)))
            (set-window-buffer drgnx-perf-w--other-window (get-buffer-create "*scratch*"))
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf))
          (run-with-timer 0 nil #'drgnx-perf-w--ts-open-next))
      (run-with-timer 0.01 nil #'drgnx-perf-w--ts-await key visited t0 colored))))

(defun drgnx-perf-w-ts-open-done () drgnx-perf-w--ts-finished)
(defun drgnx-perf-w-ts-open-digest () (format "%S" (reverse drgnx-perf-w--ts-digests)))
(defun drgnx-perf-w-ts-open-measure () (list :ts drgnx-perf-w--stats))

(defun drgnx-perf-w-ts-open-teardown ()
  (drgnx-perf-w--disarm)
  (when (window-live-p drgnx-perf-w--other-window) (delete-window drgnx-perf-w--other-window))
  (setq drgnx-perf-w--other-window nil)
  (drgnx-perf-w--kill-visiting (or drgnx-perf-w--tmp "/nonexistent/"))
  (drgnx-perf-w--clean)
  t)

;; ts-paste, ts-typing, ts-typing-unclosed: a 1 MB C file in the editor window, point in the middle, the editing aids
;; a user has on (electric-pair, show-paren, which-function).

(defvar drgnx-perf-w--ts-base 0 "The buffer size when the keys began.")
(defvar drgnx-perf-w--ts-modes nil "((SYMBOL . WAS)…): the global modes `drgnx-perf-w-ts-edit-each' turned on.")
(defvar drgnx-perf-w--ts-commands 0 "The commands run since `drgnx-perf-w-ts-edit-each': one per typed character.")

(defun drgnx-perf-w--ts-count-command ()
  "`post-command-hook' while an edit workload runs: count the command."
  (setq drgnx-perf-w--ts-commands (1+ drgnx-perf-w--ts-commands)))

(defun drgnx-perf-w-ts-edit-each (&optional paste)
  "The 1 MB C file shown in the selected window, point mid-file; with PASTE a 500 kB text in the kill ring.
Every call starts from the file on disk: the buffer an earlier repeat edited (never saved) is killed first."
  (drgnx-perf-w--kill-visiting (drgnx-perf-w--tmpdir))
  (let ((buf (drgnx-perf-w--ts-visit (drgnx-perf-w--ts-file 'c-ts-mode 1) 'c-ts-mode)))
    (dolist (m '(electric-pair-mode show-paren-mode which-function-mode))
      (unless (assq m drgnx-perf-w--ts-modes) (push (cons m (symbol-value m)) drgnx-perf-w--ts-modes))
      (funcall m 1))
    (with-current-buffer buf
      (goto-char (/ (point-max) 2)) (beginning-of-line)
      (set-window-start (selected-window) (point))
      (setq drgnx-perf-w--ts-base (buffer-size)))
    (when paste (kill-new (drgnx-perf-w-gen-source 'c 500000)))
    (redisplay t)
    (setq drgnx-perf-w--ts-commands 0)
    (add-hook 'post-command-hook #'drgnx-perf-w--ts-count-command)
    t))

;; the edited buffer is the selected window's: the lab's calls run in the server's buffer, not that one
(defun drgnx-perf-w-ts-paste-done ()
  (and (> (buffer-size (window-buffer)) (+ drgnx-perf-w--ts-base 400000)) (drgnx-perf-w--colored-p)))

(defun drgnx-perf-w-ts-edit-done (keys)
  "KEYS typed characters' commands have run and the colour has settled (`drgnx-perf-w--ts-settled-p').  The lab
starts polling before the keys, when the unedited file is already coloured: the count keeps it from holding then."
  (and (>= drgnx-perf-w--ts-commands keys) (drgnx-perf-w--ts-settled-p)))

(defvar jit-lock-context-unfontify-pos)
(defvar nidhogg-workers-treesit--pending)
(declare-function nidhogg-workers--treesit-busy-p "nidhogg-treesit-bg.c" (buffer))

(defun drgnx-perf-w--ts-settled-p (&optional window)
  "WINDOW's region is coloured and its colour has settled, so a digest of it does not depend on when it is read: no
parse job runs for the buffer and no region waits for one (the workers' deferral), and jit-lock's contextual
refontification after the last edit has run (its idle timer, 0.5 s; up to `jit-lock-antiblink-grace' after an
unterminated string)."
  (let* ((window (or window (selected-window))) (buf (window-buffer window)))
    (and (drgnx-perf-w--colored-p window)
         (with-current-buffer buf
           (and (null (bound-and-true-p nidhogg-workers-treesit--pending))
                (not (and (fboundp 'nidhogg-workers--treesit-busy-p) (nidhogg-workers--treesit-busy-p buf)))
                (let ((pos (bound-and-true-p jit-lock-context-unfontify-pos)))
                  (or (null pos) (>= pos (point-max)))))))))
(defun drgnx-perf-w-ts-edit-digest () (format "%d %s" (buffer-size (window-buffer)) (drgnx-perf-w--visible-digest)))

(defun drgnx-perf-w-ts-edit-teardown ()
  (remove-hook 'post-command-hook #'drgnx-perf-w--ts-count-command)
  (pcase-dolist (`(,m . ,was) drgnx-perf-w--ts-modes) (funcall m (if was 1 -1)))
  (setq drgnx-perf-w--ts-modes nil)
  (drgnx-perf-w--kill-visiting (or drgnx-perf-w--tmp "/nonexistent/"))
  t)

;;;; LSP: lsp-burst and lsp-typing, on jsonrpc over test/fixtures/lsp-replay.el serving a recorded corpus

(require 'jsonrpc)

(defvar drgnx-perf-w--lsps nil "The jsonrpc connections, one replay server per recorded corpus (rust, c, ts).")
(defvar drgnx-perf-w--lsp-handled nil
  "((METHOD COUNT HANDLED-AT CONNECTION-NAME ID)…), newest first: the answers handled, HANDLED-AT a `float-time'.")
(defvar drgnx-perf-w--lsp-sent (make-hash-table :test #'equal)
  "(CONNECTION-NAME . ID) → when the server wrote the answer's last byte (lsp-replay.el's \"$/replaySent\").
The handlers are measured from it: advice on jsonrpc's filter would show when the main thread got the bytes, but it
keeps Nidhogg's framing off (jsonrpc with advice stays on its own filter), and framed, the bytes never reach a filter.")
(defvar drgnx-perf-w--lsp-notes nil "The server's own messages received, newest first: (METHOD . URI-OR-TOKEN).")
(defvar drgnx-perf-w--lsp-heads nil
  "Per server, its first `drgnx-perf-w--lsp-head' messages of the session, oldest last: (NAME . MESSAGES).  Rounds
clear `drgnx-perf-w--lsp-notes' but the flood goes on, so a round's first messages start at a different place each time.")
(defconst drgnx-perf-w--lsp-head 100)
(defvar drgnx-perf-w--lsp-rounds 3)

(defun drgnx-perf-w--lsp-count (result)
  "How many completion items RESULT (a list, or a list object) holds."
  (cond ((vectorp result) (length result)) ((listp result) (length (plist-get result :items))) (t 0)))

(defun drgnx-perf-w--lsp-note (conn method params)
  (if (equal (format "%s" method) "$/replaySent")
      (puthash (cons (jsonrpc-name conn) (plist-get params :id)) (plist-get params :t) drgnx-perf-w--lsp-sent)
    (let* ((name (jsonrpc-name conn))
           (note (list name method
                       (or (ignore-errors (plist-get (plist-get params :textDocument) :uri))
                           (ignore-errors (format "%s" (plist-get params :token))))))
           (head (assoc name drgnx-perf-w--lsp-heads)))
      (push note drgnx-perf-w--lsp-notes)
      (unless head (push (setq head (list name)) drgnx-perf-w--lsp-heads))
      (when (< (length (cdr head)) drgnx-perf-w--lsp-head) (setcdr head (cons note (cdr head)))))))

(defun drgnx-perf-w--lsp-start (corpus env)
  "A jsonrpc connection to a replay server for the recorded CORPUS (rust, c or ts) with ENV (VAR=VALUE strings), initialized.
The server's own messages wait for `initialized' (the fire function sends it)."
  (let* ((dir (expand-file-name "test/fixtures/workers" drgnx-perf-w--repo))
         (process-environment (append env (list (concat "LSP_REPLAY_CORPUS=" (expand-file-name (format "corpus-%s.eld.gz" corpus) dir)))
                                      process-environment))
         (name (format "perf-lsp-%s" corpus))
         (conn (make-instance 'jsonrpc-process-connection :name name :events-buffer-config '(:size 0)
                              :notification-dispatcher #'drgnx-perf-w--lsp-note
                              :request-dispatcher (lambda (_c _m _p) nil)
                              :process (lambda ()
                                         (make-process :name name :noquery t :connection-type 'pipe :coding 'utf-8-emacs-unix
                                                       :command (list (expand-file-name invocation-name invocation-directory)
                                                                      "--batch" "-Q" "-l"
                                                                      (expand-file-name "test/fixtures/lsp-replay.el" drgnx-perf-w--repo))
                                                       :stderr (get-buffer-create (format " *%s-err*" name)))))))
    (jsonrpc-request conn :initialize '(:processId nil :rootUri nil :capabilities (:textDocument nil)) :timeout 60)
    conn))

(defun drgnx-perf-w-lsp-setup (env)
  "The three replay servers (rust-analyzer's, clangd's and tsserver's recorded traffic), each started with ENV."
  (setq drgnx-perf-w--lsp-heads nil
        drgnx-perf-w--lsps (mapcar (lambda (c) (drgnx-perf-w--lsp-start c env)) '("rust" "c" "ts")))
  t)

(defvar drgnx-perf-w--lsp-timeout 60
  "Seconds a request may wait for its answer: the runner's own completion deadline (`drgnx-perf-run-complete-wait').
jsonrpc's default is 10 s and a late answer is then dropped without a word.")

(defun drgnx-perf-w--lsp-request (conn method params)
  (let ((id (1+ (jsonrpc--next-request-id conn))) (name (jsonrpc-name conn)))   ; the id jsonrpc gives this request
    (jsonrpc-async-request
     conn method params
     :timeout drgnx-perf-w--lsp-timeout
     :timeout-fn (lambda () (push (list method -2 nil name id 'timeout) drgnx-perf-w--lsp-handled))
     :success-fn (lambda (result)
                   (push (list method (drgnx-perf-w--lsp-count result) (float-time) name id) drgnx-perf-w--lsp-handled))
     :error-fn (lambda (e) (push (list method -1 nil name id e) drgnx-perf-w--lsp-handled)))))

(defun drgnx-perf-w--lsp-stamped-p ()
  "Non-nil once every answer handled has its server's write time."
  (seq-every-p (lambda (h) (or (eq (nth 5 h) 'timeout) (gethash (cons (nth 3 h) (nth 4 h)) drgnx-perf-w--lsp-sent)))
               drgnx-perf-w--lsp-handled))

(defun drgnx-perf-w--lsp-burst-round ()
  "One round, per server: three completion answers (0.5, 1 and 3 MB, in turn) and a small request."
  (dolist (conn drgnx-perf-w--lsps)
    (dotimes (_ 3)
      (drgnx-perf-w--lsp-request conn :textDocument/completion '(:textDocument (:uri "file:///perf.c") :position (:line 10 :character 5))))
    (drgnx-perf-w--lsp-request conn :textDocument/documentSymbol '(:textDocument (:uri "file:///perf.c")))))

(defun drgnx-perf-w--lsp-initialized ()
  (dolist (conn drgnx-perf-w--lsps) (jsonrpc-notify conn :initialized nil)))   ; the servers' recorded messages follow

(defun drgnx-perf-w--lsp-burst-fire ()
  (setq drgnx-perf-w--lsp-handled nil drgnx-perf-w--lsp-notes nil)
  (clrhash drgnx-perf-w--lsp-sent)
  (drgnx-perf-w--lsp-initialized)
  (dotimes (i drgnx-perf-w--lsp-rounds)
    (run-with-timer (* i 0.4) nil #'drgnx-perf-w--lsp-burst-round)))

(defun drgnx-perf-w-lsp-burst-each ()
  (setq drgnx-perf-w--lsp-handled nil drgnx-perf-w--lsp-notes nil)
  (clrhash drgnx-perf-w--lsp-sent)
  (drgnx-perf-w--arm #'drgnx-perf-w--lsp-burst-fire)
  t)

(defun drgnx-perf-w-lsp-burst-done ()
  "Every answer handled, and the server's write time of each one here (it follows the answer)."
  (and (>= (length drgnx-perf-w--lsp-handled) (* 4 drgnx-perf-w--lsp-rounds (length drgnx-perf-w--lsps)))
       (drgnx-perf-w--lsp-stamped-p)))

(defun drgnx-perf-w-lsp-burst-digest ()
  (format "%S %S" (sort (mapcar (lambda (h) (list (symbol-name (car h)) (cadr h))) drgnx-perf-w--lsp-handled)
                        (lambda (a b) (string< (format "%S" a) (format "%S" b))))
          (length drgnx-perf-w--lsp-notes)))

(defun drgnx-perf-w-lsp-burst-measure ()
  "The slowest handler start after the server wrote the last byte of its answer, in ms (`:lsp :handler_ms :max');
`:framed', how many connections are framed (`drgnx-perf-w--lsp-framed')."
  (list :lsp (list :handler_ms
                   (list :max (apply #'max 0 (delq nil (mapcar (lambda (h)
                                                                 (when-let* ((at (nth 2 h))
                                                                             (sent (gethash (cons (nth 3 h) (nth 4 h)) drgnx-perf-w--lsp-sent)))
                                                                   (drgnx-perf--round (* 1000 (- at sent)))))
                                                               drgnx-perf-w--lsp-handled))))
                   :answers (length drgnx-perf-w--lsp-handled)
                   :timeouts (length (drgnx-perf-w--lsp-timed-out))
                   :timeout_ids (mapcar (lambda (h) (format "%s/%s" (nth 3 h) (nth 4 h))) (drgnx-perf-w--lsp-timed-out))
                   :framed (drgnx-perf-w--lsp-framed))))

(defun drgnx-perf-w--lsp-timed-out ()
  "The handled entries that timed out (their answer never came within `drgnx-perf-w--lsp-timeout')."
  (seq-filter (lambda (h) (eq (nth 5 h) 'timeout)) drgnx-perf-w--lsp-handled))

(defun drgnx-perf-w--lsp-framed ()
  "How many of the connections Nidhogg's reader frames (0 without `nidhogg-workers-framing')."
  (seq-count (lambda (c) (and (fboundp 'nidhogg-process-framing) (nidhogg-process-framing (jsonrpc--process c))))
             drgnx-perf-w--lsps))

;; lsp-typing: after `initialized' the server floods the recorded diagnostics and progress messages at 300 a second.

(defvar drgnx-perf-w--lsp-flood-want 600)

(defun drgnx-perf-w--lsp-flood-fire ()
  (setq drgnx-perf-w--lsp-notes nil)
  (drgnx-perf-w--lsp-initialized))

(defun drgnx-perf-w-lsp-typing-each ()
  (setq drgnx-perf-w--lsp-notes nil)
  (drgnx-perf-w--arm #'drgnx-perf-w--lsp-flood-fire)
  t)

(defun drgnx-perf-w-lsp-typing-done () (>= (length drgnx-perf-w--lsp-notes) drgnx-perf-w--lsp-flood-want))

(defun drgnx-perf-w-lsp-typing-measure () (list :lsp (list :framed (drgnx-perf-w--lsp-framed))))

(defun drgnx-perf-w-lsp-typing-digest ()
  "Each server's first 100 messages of the session, in order (the flood goes on across rounds, so later ones are not
compared, and a round's own list starts wherever the flood is)."
  (let (out)
    (dolist (head (sort (copy-sequence drgnx-perf-w--lsp-heads) (lambda (a b) (string< (car a) (car b)))))
      (push (cons (car head) (secure-hash 'md5 (format "%S" (reverse (cdr head))))) out))
    (format "%S" (nreverse out))))

(defun drgnx-perf-w-lsp-teardown ()
  (drgnx-perf-w--disarm)
  (dolist (conn drgnx-perf-w--lsps) (ignore-errors (jsonrpc-shutdown conn)))
  (setq drgnx-perf-w--lsps nil)
  (dolist (b (buffer-list)) (when (string-prefix-p " *perf-lsp-" (buffer-name b)) (kill-buffer b)))
  t)

;;;; compile-flood: a 200k-line log through a pty (comint)

(defvar drgnx-perf-w--compile-log nil)
(defvar drgnx-perf-w--compile-lines 200000)
(defvar drgnx-perf-w--compile-finished nil)
(defvar drgnx-perf-w--compile-buffer nil)

(defun drgnx-perf-w--compile-finish (buffer _status)
  (when (eq buffer drgnx-perf-w--compile-buffer) (setq drgnx-perf-w--compile-finished t)))

(defun drgnx-perf-w-compile-setup ()
  (setq drgnx-perf-w--compile-log (expand-file-name "build.log" (drgnx-perf-w--tmpdir)))
  (drgnx-perf-w-gen-compile-log drgnx-perf-w--compile-log drgnx-perf-w--compile-lines)
  t)

(defun drgnx-perf-w--compile-fire ()
  (add-hook 'compilation-finish-functions #'drgnx-perf-w--compile-finish)
  (let ((default-directory drgnx-perf-w--tmp) (compilation-ask-about-save nil) (compilation-window-height 8))
    (setq drgnx-perf-w--compile-buffer
          (compile (format "cat %s" (shell-quote-argument drgnx-perf-w--compile-log)) t))))   ; t: comint, a pty

(defun drgnx-perf-w-compile-each ()
  (setq drgnx-perf-w--compile-finished nil drgnx-perf-w--compile-buffer nil)
  (drgnx-perf-w--arm #'drgnx-perf-w--compile-fire)
  t)

(defun drgnx-perf-w-compile-done () drgnx-perf-w--compile-finished)

(defun drgnx-perf-w--compile-lines ()
  "The log's lines in the compilation buffer, carriage returns removed."
  (with-current-buffer drgnx-perf-w--compile-buffer
    (let (lines)
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward "^log[0-9]\\{6\\}.*$" nil t) (push (string-trim-right (match-string 0) "\r") lines)))
      (nreverse lines))))

(defun drgnx-perf-w-compile-digest ()
  "The number of log lines that arrived and the md5 of them: bytes delivered equal bytes written."
  (let ((lines (drgnx-perf-w--compile-lines)))
    (format "%d %s" (length lines) (secure-hash 'md5 (mapconcat #'identity lines "\n")))))

(defun drgnx-perf-w-compile-expected ()
  "The digest of the lines as written."
  (with-temp-buffer
    (insert-file-contents drgnx-perf-w--compile-log)
    (let ((lines (split-string (buffer-string) "\n" t)))
      (format "%d %s" (length lines) (secure-hash 'md5 (mapconcat #'identity lines "\n"))))))

(defun drgnx-perf-w-compile-teardown ()
  (drgnx-perf-w--disarm)
  (remove-hook 'compilation-finish-functions #'drgnx-perf-w--compile-finish)
  (when (buffer-live-p drgnx-perf-w--compile-buffer)
    (let ((kill-buffer-query-functions nil))
      (when-let* ((p (get-buffer-process drgnx-perf-w--compile-buffer))) (delete-process p))
      (kill-buffer drgnx-perf-w--compile-buffer)))
  (setq drgnx-perf-w--compile-buffer nil)
  (drgnx-perf-w--clean)
  t)

;;;; image-open: an agent screenshot (4K PNG) and a 20-image Markdown preview, in a second window

(defvar drgnx-perf-w--img-done nil)

(defun drgnx-perf-w--count-images (buffer)
  (with-current-buffer buffer
    ;; every run of text with an image display, the one at `point-min' included
    (let ((n 0) (pos (point-min)))
      (while pos
        (when (eq (car-safe (get-text-property pos 'display)) 'image) (setq n (1+ n)))
        (setq pos (next-single-property-change pos 'display)))
      n)))

(defun drgnx-perf-w-image-each ()
  (when (window-live-p drgnx-perf-w--other-window) (delete-window drgnx-perf-w--other-window))
  (setq drgnx-perf-w--other-window (split-window (selected-window) nil 'right) drgnx-perf-w--img-done nil)
  ;; every repeat decodes: the last repeat's pictures would otherwise be found in the image cache
  (clear-image-cache t)
  (drgnx-perf-w--arm #'drgnx-perf-w--image-fire)
  t)

(defun drgnx-perf-w--image-fire ()
  (let ((dir (expand-file-name "test/fixtures/workers" drgnx-perf-w--repo)) (win drgnx-perf-w--other-window))
    ;; the screenshot: inserted, then drawn
    (let ((buf (get-buffer-create "*perf-screenshot*")) (t0 (float-time)))
      (with-current-buffer buf
        (erase-buffer)
        (insert-image (create-image (expand-file-name "screenshot-4k.png" dir)) " "))
      (set-window-buffer win buf)
      (redisplay t)
      (drgnx-perf-w--stat :screenshot_ms (drgnx-perf-w--ms t0))
      (let ((size (with-current-buffer buf (image-size (get-text-property 1 'display) t))))
        (drgnx-perf-w--stat :screenshot_size (format "%dx%d" (car size) (cdr size)))))
    ;; the preview of 20 pictures, through the Markdown module's own path (shr)
    (require 'drgnx-markdown)
    (let* ((buf (get-buffer-create "*perf-preview*")) (t0 (float-time))
           (names (with-temp-buffer (insert-file-contents (expand-file-name "preview-20.md" dir))
                                    (let (l) (while (re-search-forward "!\\[[^]]*\\](\\([^)]+\\))" nil t) (push (match-string 1) l)) (nreverse l))))
           (html (mapconcat (lambda (n) (format "<p><img src=\"%s\"></p>" n)) names "")))
      (set-window-buffer win buf)
      (drgnx-markdown--insert-html buf html dir)
      (redisplay t)
      (drgnx-perf-w--stat :preview_ms (drgnx-perf-w--ms t0))
      (drgnx-perf-w--img-await buf t0))))

(defun drgnx-perf-w--img-pending ()
  "Image entries Nidhogg's image worker has not drawn the pixels of yet (0 without the worker)."
  (if (fboundp 'nidhogg-workers--test-image-info) (plist-get (nidhogg-workers--test-image-info) :pending) 0))

(defun drgnx-perf-w--img-await (buf t0)
  ;; drawn: all 20 pictures in the buffer and none still decoding (a deferred decode lands at a later redisplay)
  (if (or (and (>= (drgnx-perf-w--count-images buf) 20) (zerop (drgnx-perf-w--img-pending))) (> (- (float-time) t0) 5))
      (progn (drgnx-perf-w--stat :preview_drawn_ms (drgnx-perf-w--ms t0))
             (drgnx-perf-w--stat :preview_images (drgnx-perf-w--count-images buf))
             (setq drgnx-perf-w--img-done t))
    (run-with-timer 0.01 nil #'drgnx-perf-w--img-await buf t0)))

(defun drgnx-perf-w-image-done () drgnx-perf-w--img-done)
(defun drgnx-perf-w-image-digest ()
  (format "%S %d" (plist-get drgnx-perf-w--stats :screenshot_size) (or (plist-get drgnx-perf-w--stats :preview_images) 0)))
(defun drgnx-perf-w-image-measure () (list :image drgnx-perf-w--stats))

(defun drgnx-perf-w-image-teardown ()
  (drgnx-perf-w--disarm)
  (when (window-live-p drgnx-perf-w--other-window) (delete-window drgnx-perf-w--other-window))
  (setq drgnx-perf-w--other-window nil)
  (dolist (n '("*perf-screenshot*" "*perf-preview*")) (when (get-buffer n) (kill-buffer n)))
  t)

;;;; Listings: explorer-expand, explorer-git, quick-open-large

(defvar drgnx-perf-w--roots nil "The Explorer's roots before the workload.")

(defun drgnx-perf-w--explorer-open (root)
  (setq drgnx-perf-w--roots (drgnx-explorer-roots))
  (drgnx-explorer-set-roots (list root))
  (drgnx-wb-show-sidebar))

(defun drgnx-perf-w--explorer-close ()
  (ignore-errors (drgnx-explorer-set-roots drgnx-perf-w--roots))
  (ignore-errors (drgnx-wb-hide-sidebar)))

(defun drgnx-perf-w-explorer-expand-setup ()
  "A project with big/ of 5000 files, the Explorer on it."
  (let ((root (expand-file-name "proj" (drgnx-perf-w--tmpdir))))
    (drgnx-perf-w-gen-big-dir (expand-file-name "big" root) 5000)
    (setq drgnx-perf-w--stats nil)
    (drgnx-perf-w--explorer-open root)
    (redisplay t)
    t))

(defun drgnx-perf-w--big () (expand-file-name "proj/big" drgnx-perf-w--tmp))

(defun drgnx-perf-w--expand-fire ()
  (let ((big (drgnx-perf-w--big)) (t0 (float-time)))
    (drgnx-cache--clear 'explorer-listing)              ; read the disk, as the bench does
    (drgnx-explorer-toggle-at (with-current-buffer drgnx-explorer-buffer-name (drgnx-explorer--row-pos big)))
    (redisplay t)
    (drgnx-perf-w--stat :expand_ms (drgnx-perf-w--ms t0))))

(defun drgnx-perf-w-explorer-expand-each ()
  (let ((big (drgnx-perf-w--big)))
    (when (drgnx-explorer--expanded-p big)
      (drgnx-explorer-toggle-at (with-current-buffer drgnx-explorer-buffer-name (drgnx-explorer--row-pos big))))
    (drgnx-perf-w--arm #'drgnx-perf-w--expand-fire)
    t))

(defun drgnx-perf-w-explorer-expand-done ()
  (and (plist-get drgnx-perf-w--stats :expand_ms) (drgnx-explorer--expanded-p (drgnx-perf-w--big))))

(defun drgnx-perf-w-explorer-expand-digest ()
  (with-current-buffer drgnx-explorer-buffer-name
    (format "%d %s" (length drgnx-explorer--rows) (secure-hash 'md5 (buffer-substring-no-properties (point-min) (point-max))))))

(defun drgnx-perf-w-explorer-expand-measure () (list :expand_ms (plist-get drgnx-perf-w--stats :expand_ms)))

(defun drgnx-perf-w-explorer-expand-teardown ()
  (drgnx-perf-w--disarm)
  (drgnx-perf-w--explorer-close)
  (drgnx-perf-w--clean)
  t)

(defun drgnx-perf-w-explorer-git-setup ()
  "A git project of 25k files (200 x 100) with 50 changed, the Explorer on it with git decorations."
  (let ((root (drgnx-perf-w-gen-repo (expand-file-name "repo" (drgnx-perf-w--tmpdir)) 200 100 t)))
    (setq drgnx-perf-w--stats nil)
    (drgnx-perf-w--explorer-open root)
    (redisplay t)
    t))

(defun drgnx-perf-w--git-root () (file-name-as-directory (expand-file-name "repo" drgnx-perf-w--tmp)))
(defun drgnx-perf-w--git-probe () (expand-file-name "d000/f000.txt" (drgnx-perf-w--git-root)))

(defun drgnx-perf-w--git-fire ()
  (setq drgnx-perf-w--stats (plist-put drgnx-perf-w--stats :git_started (float-time)))
  (drgnx-git-refresh (drgnx-perf-w--git-root)))          ; in the background; the status is read as it arrives

(defun drgnx-perf-w-explorer-git-each ()
  (drgnx-cache--clear 'git-status)
  (setq drgnx-explorer-git t)
  (drgnx-perf-w--arm #'drgnx-perf-w--git-fire)
  t)

(defun drgnx-perf-w-explorer-git-done () (and (drgnx-git-status (drgnx-perf-w--git-probe)) t))

(defun drgnx-perf-w-explorer-git-digest ()
  (format "%S" (cl-loop for i below 50 collect (drgnx-git-status (expand-file-name (format "d%03d/f000.txt" i) (drgnx-perf-w--git-root))))))

(defun drgnx-perf-w-explorer-git-teardown ()
  (drgnx-perf-w--disarm)
  (drgnx-perf-w--explorer-close)
  (drgnx-cache--clear 'git-status)
  (drgnx-perf-w--clean)
  t)

(defvar drgnx-perf-w--qo-files nil "The candidates Quick Open listed.")

(defun drgnx-perf-w-quick-open-setup ()
  "A git repository of 200,000 files (400 folders of 500)."
  (drgnx-perf-w-gen-repo (expand-file-name "big" (drgnx-perf-w--tmpdir)) 400 500 t)
  t)

(defun drgnx-perf-w--qo-fire ()
  "Quick Open's listing (project-find-file asks the project for its files), then the first candidates are shown."
  (let ((t0 (float-time)))
    (setq drgnx-perf-w--qo-files (project-files (project-current nil (expand-file-name "big" drgnx-perf-w--tmp))))
    (drgnx-perf-w--stat :list_ms (drgnx-perf-w--ms t0))))

(defun drgnx-perf-w-quick-open-each ()
  (setq drgnx-perf-w--qo-files nil)
  (drgnx-perf-w--arm #'drgnx-perf-w--qo-fire)
  t)

(defun drgnx-perf-w-quick-open-done () (and drgnx-perf-w--qo-files t))
(defun drgnx-perf-w-quick-open-digest ()
  "The count and a hash of the files' paths under the repository (each session's temporary directory is its own)."
  (let ((root (file-name-as-directory (expand-file-name "big" drgnx-perf-w--tmp))))
    (format "%d %s" (length drgnx-perf-w--qo-files)
            (secure-hash 'md5 (mapconcat #'identity
                                         (sort (mapcar (lambda (f) (string-remove-prefix root f)) drgnx-perf-w--qo-files) #'string<)
                                         "\n")))))
(defun drgnx-perf-w-quick-open-measure () (list :list_ms (plist-get drgnx-perf-w--stats :list_ms)))

(defun drgnx-perf-w-quick-open-teardown ()
  (drgnx-perf-w--disarm)
  (setq drgnx-perf-w--qo-files nil)
  (drgnx-perf-w--clean)
  t)

;;;; quick-open-typing(-old): twelve keys typed into Quick Open over the same 200,000 files

(defvar drgnx-perf-w--qot-seen nil "(INPUT COUNT FIRST) of Quick Open after the last key, while it was open.")
(defvar drgnx-perf-w--qot-listed nil "Non-nil once Quick Open had its first list before the first key.")
(defvar drgnx-perf-w--qot-old nil "Non-nil: Quick Open's old path (the streamed listing), else the hub's rows.")
(defvar drgnx-perf-w--qot-log nil "What the run saw, newest first (at most 40): opened, errors, each command.")
(defvar drgnx-quick-open--state)
(defvar drgnx-quick-open--current)
(defvar drgnx-view-old-path)
(declare-function drgnx-quick-open "drgnx-quick-open")
(declare-function drgnx-quick-open--candidates "drgnx-quick-open")
(declare-function drgnx-quick-open--s-input "drgnx-quick-open")
(declare-function drgnx-quick-open--s-done "drgnx-quick-open")
(declare-function drgnx-quick-open--rows-candidates "drgnx-quick-open")
(declare-function drgnx-file-stream-available-p "drgnx-file-stream")

(defun drgnx-perf-w--qot-say (&rest item)
  (push item drgnx-perf-w--qot-log)
  (when (nthcdr 40 drgnx-perf-w--qot-log) (setcdr (nthcdr 39 drgnx-perf-w--qot-log) nil)))

(defvar drgnx-perf-w--qot-path nil "Which path the keys reached: `hub' (the hub's rows) or `stream' (the old path).")

(defun drgnx-perf-w--qot-note ()
  "Post-command: what Quick Open shows after the key (its state is bound only while it reads), on either path."
  (let ((rows (bound-and-true-p drgnx-quick-open--current)) (state (bound-and-true-p drgnx-quick-open--state)))
    (drgnx-perf-w--qot-say 'cmd this-command (and rows t) (and state t) (and (minibufferp) t) (point)
                           (and (minibufferp) (minibuffer-prompt-end)) (buffer-name) (minibuffer-depth))
    (when (and (minibufferp) (eq this-command 'drgnx-quick-open))
      (drgnx-perf-w--qot-say 'prompt (buffer-substring-no-properties 1 (minibuffer-prompt-end))))
    (when (and (or rows state) (minibufferp))
      (let ((names (if rows (drgnx-quick-open--rows-candidates rows) (drgnx-quick-open--candidates state))))
        (when (and (not drgnx-perf-w--qot-seen) (eq this-command 'self-insert-command))
          ;; the first typed key: was the first list there before it?
          (setq drgnx-perf-w--qot-listed (if rows (> (length names) 0) (and (drgnx-quick-open--s-done state) t))))
        (when (eq this-command 'self-insert-command)
          (setq drgnx-perf-w--qot-path (if rows 'hub 'stream)
                drgnx-perf-w--qot-seen (list (minibuffer-contents-no-properties) (length names) (car names))))))))

(defconst drgnx-perf-w--qot-query "d012/f001.txt"
  "What the workload types: no space (a plain `completing-read' takes SPC as `minibuffer-complete-word').")

(defun drgnx-perf-w--qot-each (old)
  "Show a file of the repository and queue Quick Open's key: the command loop runs it as the user's command (drgnx
refuses a prompt from a timer or this call), and the lab's settle lets the first list come before the typed keys;
OLD: on the old path."
  (require 'drgnx-quick-open)
  (setq drgnx-perf-w--qot-seen nil drgnx-perf-w--qot-listed nil drgnx-perf-w--qot-path nil drgnx-perf-w--qot-old old
        drgnx-perf-w--qot-log nil drgnx-view-old-path old)
  (switch-to-buffer (find-file-noselect (expand-file-name "big/d000/f000.txt" drgnx-perf-w--tmp)))
  (add-hook 'post-command-hook #'drgnx-perf-w--qot-note)
  (drgnx-perf-w--qot-say 'each (drgnx-file-stream-available-p (expand-file-name "big" drgnx-perf-w--tmp))
                         (bound-and-true-p nidhogg-workers-framing) (fboundp 'nidhogg-set-process-framing)
                         (and (executable-find "git") t))
  (setq unread-command-events (append unread-command-events (listify-key-sequence (kbd "C-p"))))
  t)

(defun drgnx-perf-w-quick-open-typing-each () (drgnx-perf-w--qot-each nil))
(defun drgnx-perf-w-quick-open-typing-old-each () (drgnx-perf-w--qot-each t))

(defun drgnx-perf-w-quick-open-typing-done ()
  "Every key reached Quick Open on the workload's path, whose first list was there before the first key, and it has
closed."
  (and drgnx-perf-w--qot-seen drgnx-perf-w--qot-listed (equal (car drgnx-perf-w--qot-seen) drgnx-perf-w--qot-query)
       (eq drgnx-perf-w--qot-path (if drgnx-perf-w--qot-old 'stream 'hub))
       (not (active-minibuffer-window))))

(defun drgnx-perf-w-quick-open-typing-check ()
  "t when the run did what it measures, else an error that says what it saw."
  (or (drgnx-perf-w-quick-open-typing-done)
      (error "quick-open-typing: after the keys %S on %S, first list before the first key %S, minibuffer open %S, \
streams %S, hub %S, C-p %S, saw %S, messages %S"
             drgnx-perf-w--qot-seen drgnx-perf-w--qot-path drgnx-perf-w--qot-listed (and (active-minibuffer-window) t)
             (drgnx-file-stream-available-p (expand-file-name "big" drgnx-perf-w--tmp))
             (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events) t)
             (key-binding (kbd "C-p"))
             (reverse drgnx-perf-w--qot-log)
             (with-current-buffer (messages-buffer)
               (buffer-substring-no-properties (max (point-min) (- (point-max) 1500)) (point-max))))))

(defun drgnx-perf-w-quick-open-typing-digest ()
  "The input, the count of candidates and the first one after the last key (relative names)."
  (format "%S" drgnx-perf-w--qot-seen))

(defun drgnx-perf-w-quick-open-typing-teardown ()
  (remove-hook 'post-command-hook #'drgnx-perf-w--qot-note)
  (setq drgnx-perf-w--qot-seen nil drgnx-perf-w--qot-listed nil drgnx-perf-w--qot-log nil drgnx-view-old-path nil)
  (drgnx-perf-w--kill-visiting (expand-file-name "big" drgnx-perf-w--tmp))
  (drgnx-perf-w--clean)
  t)

;;;; agents-line-motion(-old): an agent frame per command while point moves, three agents in a Lisp file

(defvar drgnx-perf-w--al-buf nil "The file the agents are in.")
(defvar drgnx-perf-w--al-frames 0 "The agent frames applied since the run began.")
(defvar drgnx-agents-editor-line--entries)
(defvar drgnx-agents-editor-line--names)
(declare-function drgnx-agents-editor-line--apply "drgnx-agents-editor-line")

(defun drgnx-perf-w--al-frame ()
  "Post-command: the hub's next frame for the file (three agents on their lines), as the agent line takes it."
  (when (eq (current-buffer) drgnx-perf-w--al-buf)
    (cl-incf drgnx-perf-w--al-frames)
    (drgnx-agents-editor-line--apply
     drgnx-perf-w--al-buf
     (list :agents (mapcar (lambda (o) (list :ordinal o :session (format "s%d" o) :handle (format "Agent%d" o)
                                             :mode "editing" :line (* o 300) :line_end (* o 300) :col 0))
                           '(1 2 3))))))

(defun drgnx-perf-w-agents-line-setup ()
  "A copy of a large Lisp file of the checkout (its symbols are what the line names)."
  (require 'drgnx-agents-editor-draw)
  (require 'drgnx-agents-editor-line)
  (copy-file (expand-file-name "wb/drgnx-view.el" drgnx-dir) (expand-file-name "view.el" (drgnx-perf-w--tmpdir)) t)
  t)

(defun drgnx-perf-w--al-each (old)
  "The file shown, point in it, no names kept; OLD: the old path (the name computed every frame)."
  (setq drgnx-view-old-path old drgnx-perf-w--al-frames 0
        drgnx-perf-w--al-buf (find-file-noselect (expand-file-name "view.el" drgnx-perf-w--tmp)))
  (switch-to-buffer drgnx-perf-w--al-buf)
  (setq drgnx-agents-editor-line--names nil)
  (goto-char (point-min)) (forward-line 100)
  (add-hook 'post-command-hook #'drgnx-perf-w--al-frame)
  t)

(defun drgnx-perf-w-agents-line-each () (drgnx-perf-w--al-each nil))
(defun drgnx-perf-w-agents-line-old-each () (drgnx-perf-w--al-each t))

(defun drgnx-perf-w-agents-line-done ()
  "Twenty frames applied, each naming its three agents."
  (and (>= drgnx-perf-w--al-frames 20)
       (= (length (buffer-local-value 'drgnx-agents-editor-line--entries drgnx-perf-w--al-buf)) 3)))

(defun drgnx-perf-w-agents-line-digest ()
  "The three lines as shown."
  (format "%S" (mapcar (lambda (e) (substring-no-properties (nth 3 e)))
                       (buffer-local-value 'drgnx-agents-editor-line--entries drgnx-perf-w--al-buf))))

(defun drgnx-perf-w-agents-line-teardown ()
  (remove-hook 'post-command-hook #'drgnx-perf-w--al-frame)
  (when (buffer-live-p drgnx-perf-w--al-buf) (kill-buffer drgnx-perf-w--al-buf))
  (setq drgnx-perf-w--al-buf nil drgnx-view-old-path nil)
  (drgnx-perf-w--clean)
  t)

;;;; autosave-typing: typing in a 50 MB buffer across an auto-save

(defvar drgnx-perf-w--as-buffer nil)
(defvar drgnx-perf-w--as-size 0 "The buffer's size when the auto-save started.")
(defvar drgnx-perf-w--as-file nil)
(defconst drgnx-perf-w--as-bytes 50000000 "The buffer's size before anything is typed.")
(defvar drgnx-perf-w--as-point 1 "Where the keys are typed (point, when the buffer was set up).")

(defun drgnx-perf-w--autosave-kill ()
  "Kill the workload's buffer (auto-save off first) and delete its auto-save file."
  (when (buffer-live-p drgnx-perf-w--as-buffer)
    (with-current-buffer drgnx-perf-w--as-buffer (set-buffer-modified-p nil) (auto-save-mode -1))
    (kill-buffer drgnx-perf-w--as-buffer))
  (when (and drgnx-perf-w--as-file (file-exists-p drgnx-perf-w--as-file)) (delete-file drgnx-perf-w--as-file))
  (setq drgnx-perf-w--as-buffer nil))

(defun drgnx-perf-w-autosave-each ()
  "A 50 MB buffer visiting a file, modified, shown in the selected window.  The buffer an earlier repeat made is
killed first: the teardown kills only the last one, so three repeats left two 50 MB buffers for the rest of the run
\(the memory row read them)."
  (drgnx-perf-w--autosave-kill)
  (let* ((file (expand-file-name "big.txt" (drgnx-perf-w--tmpdir))) (line (concat (make-string 99 ?x) "\n"))
         (chunk (apply #'concat (make-list 10000 line))) (buf (create-file-buffer file)))
    (with-current-buffer buf
      (setq buffer-file-name file default-directory (file-name-directory file))
      (dotimes (_ 50) (insert chunk))
      (goto-char (point-min)) (forward-line 100)
      (setq drgnx-perf-w--as-point (point))
      (set-buffer-modified-p t)
      (setq buffer-auto-save-file-name (make-auto-save-file-name))
      (auto-save-mode 1)
      (when (file-exists-p buffer-auto-save-file-name) (delete-file buffer-auto-save-file-name))
      (setq drgnx-perf-w--as-file buffer-auto-save-file-name))
    (setq drgnx-perf-w--as-buffer buf drgnx-perf-w--as-size 0)
    (switch-to-buffer buf)
    (redisplay t)
    (drgnx-perf-w--arm #'drgnx-perf-w--autosave-fire)
    t))

(declare-function nidhogg-workers--test-keyboard-auto-save "nidhogg-blk.c")

(defun drgnx-perf-w--autosave-fire ()
  "Auto-save as the keyboard loop does after typing.  Only that auto-save may write on a worker (`do-auto-save' from
Lisp stays synchronous), so on a Nidhogg with the workers this is `read_char''s own call; elsewhere `do-auto-save'."
  (with-current-buffer drgnx-perf-w--as-buffer
    (setq drgnx-perf-w--as-size (buffer-size)))
  (if (fboundp 'nidhogg-workers--test-keyboard-auto-save)
      (nidhogg-workers--test-keyboard-auto-save t)
    (do-auto-save t)))

(defun drgnx-perf-w-autosave-done ()
  (and (> drgnx-perf-w--as-size 0) (file-exists-p drgnx-perf-w--as-file)
       (>= (file-attribute-size (file-attributes drgnx-perf-w--as-file)) drgnx-perf-w--as-size)))

(defun drgnx-perf-w-autosave-digest ()
  "The md5 of the auto-save file's bytes, less the characters typed before the auto-save started (how many of the
keys that was varies; they sit at `drgnx-perf-w--as-point'), and whether the file holds as many bytes as the buffer did
then.  The same whenever the auto-save wrote the untouched 50 MB intact."
  (if (not (and drgnx-perf-w--as-file (file-exists-p drgnx-perf-w--as-file)))
      "missing"
    (let ((size (file-attribute-size (file-attributes drgnx-perf-w--as-file)))
          (typed (- drgnx-perf-w--as-size drgnx-perf-w--as-bytes)))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally drgnx-perf-w--as-file)
        (when (and (> typed 0) (<= (+ drgnx-perf-w--as-point typed -1) (point-max)))
          (delete-region drgnx-perf-w--as-point (+ drgnx-perf-w--as-point typed)))
        (format "%s %d %s" (= size drgnx-perf-w--as-size) (buffer-size) (md5 (current-buffer)))))))

(defun drgnx-perf-w-autosave-teardown ()
  (drgnx-perf-w--disarm)
  (drgnx-perf-w--autosave-kill)
  (drgnx-perf-w--clean)
  t)

(provide 'perf-session)
;;; perf-session.el ends here
