;;; work-code-test.el --- files an agent is still editing open read-only; take the wheel -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The hub runs as its own process; this Emacs plays the editor inside the delivery gate.  The agents are real children
;; (mock-acp) in a linked worktree of the test's home folder: a file there is the agent's while the agent is live.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-agents)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/unit/agents-mirror-test" drgnx-dir) nil t)   ; its helpers and the hub fixtures
(drgnx-test-modules-preload '(tools/work-space))

(defvar drgnx-work-live-file-mode)
(defvar drgnx-work-live-file--lighter)
(declare-function drgnx-work-take-wheel "drgnx-work-space")

(defmacro drgnx-work-code-test--with (&rest body)
  "BODY with the module `tools/work-space' set up, a gated hub, this Emacs mirroring its sessions, and `wt' a linked
worktree (its .git is a file) and `own' a checkout of the user's (its .git is a directory) under the test's home."
  (declare (indent 0))
  ;; the clock first: the timers the modules' setups arm are then on its lists, and its end drops them
  `(drgnx-test-with-clock (:allow-pending t)
     (drgnx-test-with-modules '(tools/work-space)
       (drgnx-agents-mirror-test--with '()
         (drgnx-agents-mirror-sync)
         (let* ((home (file-name-as-directory (getenv "HOME")))
                (wt (file-name-as-directory (expand-file-name "agent-worktree" home)))
                (own (file-name-as-directory (expand-file-name "own-checkout" home))))
           (make-directory wt t) (make-directory (concat own ".git") t)
           (with-temp-file (concat wt ".git") (insert "gitdir: /elsewhere/.git/worktrees/agent\n"))
           (dolist (d (list wt own)) (with-temp-file (concat d "a.txt") (insert "one\n")))
           ,@body)))))

(defun drgnx-work-code-test--start (cwd)
  "A mock session in CWD; its mirror once it is idle."
  (let ((id (plist-get (drgnx-agents-mirror-test--ask "agents/start" (list :profile "mock" :cwd (directory-file-name cwd)))
                       :id)))
    (drgnx-agents-mirror-test--settle (lambda () (drgnx-agents-mirror-test--idle-mirror id)) "the session's mirror, idle")))

(ert-deftest drgnx-work-code/live-agent-file-opens-read-only ()
  (drgnx-work-code-test--with
    (let* ((m (drgnx-work-code-test--start wt)) (buf (find-file-noselect (concat wt "a.txt"))))
      (unwind-protect
          (with-current-buffer buf
            (should drgnx-work-live-file-mode)
            (should buffer-read-only)
            ;; the chip is the mode's lighter: " live · NAME"
            (should (equal (concat " live · " (drgnx-agent-session-name m)) drgnx-work-live-file--lighter))
            (should (assq 'drgnx-work-live-file-mode minor-mode-alist))
            (should (equal 'drgnx-work-live-file--lighter (cadr (assq 'drgnx-work-live-file-mode minor-mode-alist)))))
        (kill-buffer buf)))))

(ert-deftest drgnx-work-code/take-the-wheel-pauses-and-makes-it-editable ()
  (drgnx-work-code-test--with
    (let* ((m (drgnx-work-code-test--start wt)) (buf (find-file-noselect (concat wt "a.txt"))))
      (unwind-protect
          (with-current-buffer buf
            (should buffer-read-only)
            (drgnx-work-take-wheel)
            (should-not buffer-read-only)
            ;; the hub paused the agent: the mirror hears it in the next snapshot
            (drgnx-agents-mirror-test--settle (lambda () (drgnx-agent-session-paused m)) "the agent is paused")
            ;; the user's edit queues as a message to the agent on save
            (goto-char (point-max)) (insert "two\n")
            (let ((sent nil))
              (cl-letf (((symbol-function 'drgnx-hub-call)
                         (lambda (method params &rest _) (push (cons method params) sent) 1)))
                (save-buffer))
              (should (seq-some (lambda (c) (and (equal (car c) "agents/send")
                                                 (string-search "a.txt" (plist-get (cdr c) :text))))
                                sent))))
        (set-buffer-modified-p nil)
        (kill-buffer buf)))))

(ert-deftest drgnx-work-code/own-checkout-stays-editable ()
  ;; an agent working in the user's own checkout (not a linked worktree) does not lock the file
  (drgnx-work-code-test--with
    (drgnx-work-code-test--start own)
    (let ((buf (find-file-noselect (concat own "a.txt"))))
      (unwind-protect
          (with-current-buffer buf
            (should-not drgnx-work-live-file-mode)
            (should-not buffer-read-only))
        (kill-buffer buf)))))

(ert-deftest drgnx-work-code/finished-agent-file-is-editable ()
  (drgnx-work-code-test--with
    (let ((m (drgnx-work-code-test--start wt)))
      (setf (drgnx-agent-session-status m) 'exited)
      (let ((buf (find-file-noselect (concat wt "a.txt"))))
        (unwind-protect
            (with-current-buffer buf
              (should-not drgnx-work-live-file-mode)
              (should-not buffer-read-only))
          (kill-buffer buf))))))

;;;; Open at the agent's line, the files picker, who is here
;; The hub's answers are stubbed at `drgnx-hub-call' in the shape of the wire types (`agents/presence/get', `work/files',
;; `work/hunks'): the mock agent reports a path and no line, so a line can only come from a stub.  The sessions are the
;; mirror's structs, each with its worktree as `cwd'.

(load (expand-file-name "test/fixtures/work-space-fixture" drgnx-dir) nil t)
(defvar drgnx-work-map--selection)
(declare-function drgnx-work-code-open-file "drgnx-work-code")
(declare-function drgnx-work-code-files "drgnx-work-code")
(declare-function drgnx-work-code-hint-keys "drgnx-work-code")
(declare-function drgnx-work-who-is-here "drgnx-work-code")
(declare-function drgnx-work-map-open-selection "drgnx-work-map")
(defvar drgnx-work-files-mode-map)
(declare-function drgnx-work-files-hint "drgnx-work-code")
(defvar drgnx-work-code--file-only)

(defmacro drgnx-work-code-test--answering (answers &rest body)
  "BODY with `drgnx-hub-call' answering from ANSWERS, an alist (METHOD . FUNCTION of the params → the result); the
callback runs at once.  `calls' holds (METHOD . PARAMS), newest first."
  (declare (indent 1))
  `(let ((calls nil))
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params callback &rest _)
                  (push (cons method params) calls)
                  (let ((f (cdr (assoc method ,answers)))) (funcall callback (and f (funcall f params)) nil))
                  1)))
       ,@body)))

(defmacro drgnx-work-code-test--ws (&rest body)
  "BODY with `repo' (the user's checkout of \"drgnx\", .git a directory), two agent worktrees `wt1' `wt2' (their .git a
file into it), session a1 in wt1 and a2 in wt2 as the mirror's sessions, each holding src/session.rs of 40 lines,
`state' the fixture frame's client state and `rel' the file's path in the repository."
  (declare (indent 0))
  `(let* ((ws (file-name-as-directory (expand-file-name "ws" (getenv "HOME"))))
          (repo (concat ws "drgnx/")) (wt1 (concat ws "wt1/")) (wt2 (concat ws "wt2/"))
          (rel "src/session.rs") (state (drgnx-work-client-init (drgnx-work-fixture-frame)))
          (drgnx-agents--sessions
           (list (drgnx-agents--make :name "hub rows" :cwd wt1 :remote "a1" :status 'running)
                 (drgnx-agents--make :name "fx-sess" :cwd wt2 :remote "a2" :status 'running))))
     (make-directory (concat repo ".git") t)
     (dolist (wt (list wt1 wt2))
       (make-directory wt t)
       (with-temp-file (concat wt ".git") (insert (format "gitdir: %s.git/worktrees/x\n" repo))))
     (dolist (d (list repo wt1 wt2))
       (make-directory (concat d "src") t)
       (with-temp-file (concat d rel) (dotimes (i 40) (insert (format "line %d\n" (1+ i))))))
     (cl-letf (((symbol-function 'drgnx-work-code--roots) (lambda () (list repo))))
       (unwind-protect (progn ,@body)
         (dolist (d (list repo wt1 wt2))
           (when-let* ((b (get-file-buffer (concat d rel)))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))))))

(cl-defun drgnx-work-code-test--entry (session file line at &optional (mode "edit"))
  (append (list :session session :file file :mode mode :source "edit" :step 3 :at at) (and line (list :line line))))

(defun drgnx-work-code-test--presence (table)
  "A `agents/presence/get' answer from TABLE, an alist file → entries."
  (lambda (params) (list :file (plist-get params :file) :entries (cdr (assoc (plist-get params :file) table)))))

(ert-deftest drgnx-work-code/enter-opens-at-the-agents-line ()
  (drgnx-work-code-test--ws
    (let ((table (list (cons (concat wt1 rel) (list (drgnx-work-code-test--entry "a1" (concat wt1 rel) 5 100.0)))
                       (cons (concat wt2 rel) (list (drgnx-work-code-test--entry "a2" (concat wt2 rel) 20 200.0))))))
      (drgnx-work-code-test--answering `(("agents/presence/get" . ,(drgnx-work-code-test--presence table)))
        ;; Enter on the file in the map: the most recent agent on its chain, in its own worktree
        (drgnx-work-fixture-with-buffer
          (setq drgnx-work-map--selection '(file . "file:drgnx/src/session.rs"))
          (cl-letf (((symbol-function 'drgnx-work-map--state) (lambda (&optional _) state)))
            (drgnx-work-map-open-selection)))
        (with-current-buffer (get-file-buffer (concat wt2 rel))
          (should (= 20 (line-number-at-pos)))
          (should-not drgnx-work-code--file-only))
        ;; opened for one agent (the picker's way): its line, its worktree
        (drgnx-work-code-open-file state '(file . "file:drgnx/src/session.rs") :agents '("a1"))
        (with-current-buffer (get-file-buffer (concat wt1 rel))
          (should (= 5 (line-number-at-pos))))))))

(ert-deftest drgnx-work-code/no-line-is-file-only ()
  (drgnx-work-code-test--ws
    (let ((table (list (cons (concat wt1 rel) (list (drgnx-work-code-test--entry "a1" (concat wt1 rel) nil 100.0 "read"))))))
      (drgnx-work-code-test--answering `(("agents/presence/get" . ,(drgnx-work-code-test--presence table)))
        (let ((buf (drgnx-work-code-open-file state '(file . "file:drgnx/src/session.rs"))))
          (with-current-buffer buf
            (should (equal (concat wt1 rel) buffer-file-name))
            (should (= 1 (line-number-at-pos)))
            (should drgnx-work-code--file-only)))))))

(ert-deftest drgnx-work-code/picker-one-key-opens ()
  (drgnx-work-code-test--ws
    (let ((table (list (cons (concat wt1 rel) nil)
                       (cons (concat wt1 "src/new.rs") (list (drgnx-work-code-test--entry "a1" (concat wt1 "src/new.rs") 7 100.0))))))
      (with-temp-file (concat wt1 "src/new.rs") (dotimes (i 20) (insert (format "n %d\n" i))))
      (drgnx-work-code-test--answering
          `(("agents/presence/get" . ,(drgnx-work-code-test--presence table))
            ("work/files" . ,(lambda (_) (list :files (list (list :path "src/session.rs" :plus 40 :minus 3 :untracked :false)
                                                            (list :path "src/new.rs" :plus 12 :minus 0 :untracked t))))))
        ;; the hint keys: 1-9 first, then letters, never the picker's own
        (should (equal '("1" "2" "3" "4" "5" "6" "7" "8" "9" "a" "b" "c")
                       (drgnx-work-code-hint-keys 12)))
        (should-not (member "q" (drgnx-work-code-hint-keys 40)))
        (let ((picker (drgnx-work-code-files state '(agent . "agent:a1") t)))
          (unwind-protect
              (with-current-buffer picker
                (should (string-search "+40 −3" (buffer-string)))
                (should (string-search "new file" (buffer-string)))
                ;; one key: the second row
                (should (eq 'drgnx-work-files-hint (lookup-key drgnx-work-files-mode-map [remap self-insert-command])))
                (let ((last-command-event ?2)) (call-interactively #'drgnx-work-files-hint)))
            (when (buffer-live-p picker) (kill-buffer picker))))
        (with-current-buffer (get-file-buffer (concat wt1 "src/new.rs"))
          (should (= 7 (line-number-at-pos))))
        (kill-buffer (get-file-buffer (concat wt1 "src/new.rs")))
        (should (assoc "work/files" calls))))))

(ert-deftest drgnx-work-code/who-is-here-names-both-agents-with-lines ()
  (drgnx-work-code-test--ws
    (let ((table (list (cons (concat wt1 rel) (list (drgnx-work-code-test--entry "a1" (concat wt1 rel) 5 100.0)))
                       (cons (concat wt2 rel) (list (drgnx-work-code-test--entry "a2" (concat wt2 rel) 20 200.0 "read")))))
          (selected nil) (said nil))
      (drgnx-work-code-test--answering `(("agents/presence/get" . ,(drgnx-work-code-test--presence table)))
        (cl-letf (((symbol-function 'drgnx-work-map-buffers) (lambda () (list (current-buffer))))
                  ((symbol-function 'drgnx-work-map--state) (lambda (&optional _) state))
                  ((symbol-function 'drgnx-work-map-select) (lambda (sel) (setq selected sel)))
                  ((symbol-function 'message) (lambda (f &rest a) (push (apply #'format f a) said))))
          (with-current-buffer (find-file-noselect (concat repo rel))
            (drgnx-work-who-is-here))
          (should (equal '(file . "file:drgnx/src/session.rs") selected))
          (let ((text (car said)))
            (should (string-search "hub rows" text)) (should (string-search "line 5" text))
            (should (string-search "fx-sess" text)) (should (string-search "line 20" text))))))))

(ert-deftest drgnx-work-code/nobody-here-moves-nothing ()
  (drgnx-work-code-test--ws
    (let ((selected nil) (said nil))
      (drgnx-work-code-test--answering `(("agents/presence/get" . ,(drgnx-work-code-test--presence nil)))
        (cl-letf (((symbol-function 'drgnx-work-map-buffers) (lambda () (list (current-buffer))))
                  ((symbol-function 'drgnx-work-map--state) (lambda (&optional _) state))
                  ((symbol-function 'drgnx-work-map-select) (lambda (sel) (setq selected sel)))
                  ((symbol-function 'message) (lambda (f &rest a) (push (apply #'format f a) said))))
          (with-current-buffer (find-file-noselect (concat repo rel))
            (drgnx-work-who-is-here))
          (should-not selected)
          (should (equal "No agent in this file" (car said))))))))

;;;; Side-by-side diffs

(declare-function drgnx-work-code-diffs "drgnx-work-code")
(declare-function drgnx-work-diff-quit "drgnx-work-code")
(defun drgnx-work-code-test--diff-buffer-p (b)
  (eq 'drgnx-work-diff-mode (buffer-local-value 'major-mode b)))

(defun drgnx-work-code-test--diff-answers (names)
  "Hub answers for `work/files' (NAMES, each with +1 −1) and `work/hunks' (a one-hunk diff naming the path)."
  `(("work/files" . ,(lambda (_) (list :files (mapcar (lambda (n) (list :path n :plus 1 :minus 1 :untracked :false)) names))))
    ("work/hunks" . ,(lambda (p) (list :diff (format "--- a/%s\n+++ b/%s\n@@ -1 +1 @@\n-old\n+new\n"
                                                     (plist-get p :path) (plist-get p :path)))))))

(defmacro drgnx-work-code-test--windows (&rest body)
  "BODY in a frame with two windows (`a-buf' and `b-buf'), the window configuration given back after it and the
diff buffers killed."
  (declare (indent 0))
  `(let ((orig (current-window-configuration)) (a-buf (generate-new-buffer " *a*")) (b-buf (generate-new-buffer " *b*")))
     (unwind-protect
         (progn (delete-other-windows)
                (set-window-buffer (selected-window) a-buf)
                (set-window-buffer (split-window-right) b-buf)
                ,@body)
       (set-window-configuration orig)
       (dolist (b (buffer-list))
         (when (drgnx-work-code-test--diff-buffer-p b) (kill-buffer b)))
       (kill-buffer a-buf) (kill-buffer b-buf))))

(defun drgnx-work-code-test--diff-windows ()
  (seq-filter (lambda (w) (drgnx-work-code-test--diff-buffer-p (window-buffer w))) (window-list nil 'never)))

(ert-deftest drgnx-work-code/diffs-at-most-three-wide ()
  (drgnx-work-code-test--ws
    (drgnx-work-code-test--windows
      (drgnx-work-code-test--answering (drgnx-work-code-test--diff-answers '("a.el" "b.el" "c.el" "d.el" "e.el"))
        (let ((buffers (drgnx-work-code-diffs state '(agent . "agent:a1"))))
          (should (= 5 (length buffers)))
          (let ((wins (drgnx-work-code-test--diff-windows)))
            (should (= 3 (length wins)))
            ;; the first two files have a window each, the other three are tabs of the third
            (should (equal '("a.el" "b.el") (mapcar (lambda (w) (string-remove-suffix "*" (cadr (split-string (buffer-name (window-buffer w)) ": ")))) (seq-take wins 2))))
            (should (= 3 (length (window-parameter (nth 2 wins) 'drgnx-work-diff-tabs))))
            (should (equal (window-parameter (nth 2 wins) 'drgnx-work-diff-tabs)
                           (with-selected-window (nth 2 wins) (funcall tab-line-tabs-function))))))))))

(ert-deftest drgnx-work-code/q-restores-the-windows ()
  (drgnx-work-code-test--ws
    (drgnx-work-code-test--windows
      (let ((before (mapcar #'window-buffer (window-list nil 'never))))
        (drgnx-work-code-test--answering (drgnx-work-code-test--diff-answers '("a.el" "b.el" "c.el"))
          (drgnx-work-code-diffs state '(agent . "agent:a1"))
          (should (= 3 (length (drgnx-work-code-test--diff-windows))))
          ;; opening them again keeps the first saved arrangement
          (drgnx-work-code-diffs state '(agent . "agent:a1"))
          (with-selected-window (car (drgnx-work-code-test--diff-windows)) (drgnx-work-diff-quit))
          (should (equal before (mapcar #'window-buffer (window-list nil 'never))))
          (should-not (seq-some #'drgnx-work-code-test--diff-buffer-p (buffer-list))))))))

(ert-deftest drgnx-work-code/diffs-are-against-the-base ()
  (drgnx-work-code-test--ws
    (drgnx-work-code-test--windows
      (drgnx-work-code-test--answering (drgnx-work-code-test--diff-answers '("src/session.rs"))
        (let ((buffers (drgnx-work-code-diffs state '(agent . "agent:a1"))))
          ;; the hub's diff against the recorded base is the whole content; nothing else is asked
          (with-current-buffer (car buffers)
            (should (derived-mode-p 'diff-mode))
            (should buffer-read-only)
            (should (string-search "@@ -1 +1 @@\n-old\n+new\n" (buffer-string))))
          (should (equal '("work/files" "work/hunks") (sort (delete-dups (mapcar #'car calls)) #'string<)))
          (should (equal "a1" (plist-get (cdr (assoc "work/hunks" calls)) :session)))
          (should (equal "src/session.rs" (plist-get (cdr (assoc "work/hunks" calls)) :path))))))))

(provide 'work-code-test)
;;; work-code-test.el ends here
