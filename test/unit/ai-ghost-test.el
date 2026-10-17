;;; ai-ghost-test.el --- batch tests: ghost-text completion and the Tab arbiter -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "modules/tools/drgnx-ai-ui" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)

(defmacro drgnx-ai-ghost-test--with (spec &rest body)
  "BODY in an Emacs Lisp buffer with ghost text on, its `complete' role on provider `o' (Ollama) served by a mock
LLM answering SPEC; `o' found running."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-ai-ghost" t)))
          (port (+ 20000 (random 20000))) (script (concat root "llm.eld"))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config")) process-environment))
          (drgnx-ai-detected '((o :up t))) (drgnx-ai-ghost--said-unavailable nil)
          (mock nil))
     (unwind-protect
         (progn
           (make-directory (concat root "config") t)
           (with-temp-file script (prin1 ,spec (current-buffer)))
           (with-temp-file (concat root "config/ai.eld")
             (prin1 `(:version 1 :providers ((o :name "O" :kind ollama :url ,(format "http://127.0.0.1:%d" port) :caps (chat fim)))
                               :roles ((complete (o . "coder"))))
                    (current-buffer)))
           (setq mock (drgnx-ai-test-mock-llm port script))
           (with-temp-buffer
             (emacs-lisp-mode)
             (drgnx-ai-ghost-mode 1)
             (insert "(defun greet (name)\n  ")
             (save-excursion (insert "\n  name)\n"))
             ,@body))
       (when mock (delete-process mock))
       (delete-directory root t))))

(defun drgnx-ai-ghost-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 5)))) (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.02)))
  (funcall pred))

(ert-deftest drgnx-ai-ghost/a-pause-shows-the-model-s-middle-as-ghost-text ()
  (drgnx-ai-ghost-test--with '((:path "/api/generate" :body "{\"response\":\"(message \\\"hi %s\\\" name)\"}"))
    (drgnx-ai-ghost--trigger)
    (should (drgnx-ai-ghost-test--wait (lambda () (drgnx-ai-ghost-text))))
    (should (equal (drgnx-ai-ghost-text) "(message \"hi %s\" name)"))
    (should (eq (get-text-property 0 'face (drgnx-ai-ghost-text-shown)) 'drgnx-ai-ghost))
    (should (equal (buffer-substring-no-properties (point) (min (point-max) (+ (point) 6))) "\n  nam"))))   ; not inserted

(ert-deftest drgnx-ai-ghost/the-pause-asks-for-the-buffer-on-screen-whatever-buffer-is-current ()
  ;; the idle timer may fire inside other code's wait (a server request, a sync call) with another buffer current
  (drgnx-ai-ghost-test--with '((:path "/api/generate" :body "{\"response\":\"(message name)\"}"))
    (let ((buf (current-buffer)) (win-buf (window-buffer (selected-window))))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) buf)
            (let ((this-command 'self-insert-command)) (drgnx-ai-ghost--post-command))
            (with-temp-buffer (funcall (timer--function drgnx-ai-ghost--timer)))   ; the pause, elsewhere
            (should (drgnx-ai-ghost-test--wait (lambda () (with-current-buffer buf (drgnx-ai-ghost-text)))))
            (should (equal (with-current-buffer buf (drgnx-ai-ghost-text)) "(message name)")))
        (set-window-buffer (selected-window) win-buf)))))

(ert-deftest drgnx-ai-ghost/the-pause-asks-nothing-for-a-buffer-no-longer-on-screen ()
  (drgnx-ai-ghost-test--with '((:path "/api/generate" :body "{\"response\":\"(message name)\"}"))
    (let ((this-command 'self-insert-command)) (drgnx-ai-ghost--post-command))
    (funcall (timer--function drgnx-ai-ghost--timer))                  ; this buffer is not the selected window's
    (should-not drgnx-ai-ghost--request)))

(ert-deftest drgnx-ai-ghost/with-no-provider-it-looks-again-now-and-then ()
  ;; a runner started after Emacs (LM Studio, llama-server) is found without a restart
  (drgnx-ai-ghost-test--with '()
    (let ((drgnx-ai-detected nil) (probes 0) (drgnx-ai-ghost--last-probe 0) (inhibit-message t))
      (cl-letf (((symbol-function 'drgnx-ai-probe) (lambda (&rest _) (cl-incf probes))))
        (drgnx-ai-ghost--trigger)
        (drgnx-ai-ghost--trigger)
        (should (= probes 1))                                               ; not on every pause
        (setq drgnx-ai-ghost--last-probe (- (float-time) 61))
        (drgnx-ai-ghost--trigger)
        (should (= probes 2))))))

(ert-deftest drgnx-ai-ghost/an-answer-to-text-since-changed-never-shows ()
  (drgnx-ai-ghost-test--with '((:path "/api/generate" :delay 0.5 :body "{\"response\":\"stale\"}"))
    (drgnx-ai-ghost--trigger)
    (insert "x")                                                   ; typed while the model thinks
    (drgnx-ai-ghost--post-command)
    (accept-process-output nil 1.0)
    (drgnx-ai-ghost-test--wait (lambda () nil) 1)
    (should-not (drgnx-ai-ghost-text))))

(ert-deftest drgnx-ai-ghost/an-answer-after-a-change-no-command-made-never-shows ()
  ;; an agent, a process or a revert changes the buffer: no command ran, nothing cancelled the question
  (drgnx-ai-ghost-test--with '((:path "/api/generate" :delay 0.3 :body "{\"response\":\"stale\"}"))
    (drgnx-ai-ghost--trigger)
    (save-excursion (goto-char (point-min)) (insert ";; written by someone else\n"))
    (drgnx-ai-ghost-test--wait (lambda () (null drgnx-ai-ghost--request)) 3)   ; the answer came
    (should-not (drgnx-ai-ghost-text))))

(ert-deftest drgnx-ai-ghost/accept-all-a-word-or-a-line ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (drgnx-ai-ghost-mode 1)
    (drgnx-ai-ghost--show "foo bar\nbaz qux")
    (drgnx-ai-accept-word)
    (should (equal (buffer-string) "foo"))
    (should (equal (drgnx-ai-ghost-text) " bar\nbaz qux"))          ; the rest still shows
    (drgnx-ai-accept-line)
    (should (equal (buffer-string) "foo bar"))
    (drgnx-ai-accept)
    (should (equal (buffer-string) "foo bar\nbaz qux"))
    (should-not (drgnx-ai-ghost-text))))

(defmacro drgnx-ai-ghost-test--keys (&rest body)
  "BODY with the module's commands registered and the default key profile applied (undone after)."
  `(let* ((dir (make-temp-file "drgnx-ai-keys" t))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir) (concat "XDG_STATE_HOME=" dir "/state"))
                                       process-environment))
          (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
          (drgnx-keys--applied nil) (drgnx-keys--session-layers nil) (drgnx-keys-profiles nil)
          (drgnx-keys-problems nil) (drgnx-keys-last nil))
     (unwind-protect
         (progn (funcall (plist-get (alist-get 'tools/ai drgnx-modules--table) :setup))
                (drgnx-keys-apply)
                ,@body)
       (drgnx-keys--restore)
       (remove-hook 'prog-mode-hook #'drgnx-ai-ghost--maybe-enable)
       (delete-directory dir t))))

(ert-deftest drgnx-ai-ghost/c-right-accepts-a-word-only-while-a-suggestion-shows ()
  (drgnx-ai-ghost-test--keys
   (with-temp-buffer
     (emacs-lisp-mode)
     (drgnx-ai-ghost-mode 1)
     (should (eq (key-binding (kbd "TAB")) 'drgnx-ai-tab))           ; the one Tab, in code buffers
     (should-not (eq (key-binding [C-right]) 'drgnx-ai-accept-word))
     (drgnx-ai-ghost--show "abc")
     (should (eq (key-binding [C-right]) 'drgnx-ai-accept-word))
     (should (eq (key-binding [escape]) 'drgnx-ai-dismiss))
     (drgnx-ai-dismiss)
     (should-not (drgnx-ai-ghost-text))
     (should-not (eq (key-binding [C-right]) 'drgnx-ai-accept-word)))))

(ert-deftest drgnx-ai-ghost/any-other-command-clears-it ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (drgnx-ai-ghost-mode 1)
    (drgnx-ai-ghost--show "abc")
    (let ((this-command 'forward-char)) (drgnx-ai-ghost--post-command))
    (should-not (drgnx-ai-ghost-text))))

(ert-deftest drgnx-ai-ghost/no-provider-asks-nothing-and-says-so-once ()
  (drgnx-ai-ghost-test--with '((:path "/api/generate" :body "{\"response\":\"never\"}"))
    (let ((drgnx-ai-detected nil) (said nil))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
        (drgnx-ai-ghost--trigger)
        (drgnx-ai-ghost--trigger))
      (accept-process-output nil 0.3)
      (should-not (drgnx-ai-ghost-text))
      (should (= 1 (seq-count (lambda (m) (string-match-p "no provider" m)) said))))))

(ert-deftest drgnx-ai-tab/one-tab-in-five-states ()
  ;; 1: a suggestion shows → accept it
  (with-temp-buffer
    (emacs-lisp-mode) (drgnx-ai-ghost-mode 1)
    (drgnx-ai-ghost--show "abc")
    (should (eq (drgnx-ai-tab-command) 'drgnx-ai-accept)))
  ;; 2: a completion popup is up → its own Tab
  (with-temp-buffer
    (emacs-lisp-mode) (drgnx-ai-ghost-mode 1)
    (let ((completion-in-region-mode t))
      (should (eq (drgnx-ai-tab-command) 'completion-at-point))))
  ;; 3: inside a snippet field → the next field
  (with-temp-buffer
    (emacs-lisp-mode) (drgnx-ai-ghost-mode 1)
    (cl-letf (((symbol-function 'yas-active-snippets) (lambda (&rest _) '(snippet))))
      (should (eq (drgnx-ai-tab-command) 'yas-next-field-or-maybe-expand))))
  ;; 4: on an org heading → cycle it
  (with-temp-buffer
    (org-mode) (drgnx-ai-ghost-mode 1)
    (insert "* Heading\nbody\n") (goto-char (point-min))
    (should (eq (drgnx-ai-tab-command) 'org-cycle)))
  ;; 5: otherwise → indent
  (with-temp-buffer
    (emacs-lisp-mode) (drgnx-ai-ghost-mode 1)
    (should (eq (drgnx-ai-tab-command) 'indent-for-tab-command))
    (insert "(foo\nbar)") (forward-line 0)
    (drgnx-ai-tab)
    (should (equal (buffer-substring (line-beginning-position) (line-end-position)) " bar)"))))

(define-derived-mode drgnx-ai-ghost-test--own-tab-mode prog-mode "OwnTab")
(define-key drgnx-ai-ghost-test--own-tab-mode-map (kbd "TAB") #'completion-at-point)

(ert-deftest drgnx-ai-tab/otherwise-the-mode-s-own-tab ()
  ;; cperl, octave, ESS…: a mode's own Tab, not a plain indent
  (let ((was (lookup-key drgnx-ai-ghost-mode-map (kbd "TAB"))))
    (unwind-protect
        (with-temp-buffer
          (define-key drgnx-ai-ghost-mode-map (kbd "TAB") #'drgnx-ai-tab)    ; as the key profiles bind it
          (drgnx-ai-ghost-test--own-tab-mode) (drgnx-ai-ghost-mode 1)
          (should (eq (key-binding (kbd "TAB")) 'drgnx-ai-tab))              ; ghost mode has Tab…
          (should (eq (drgnx-ai-tab-command) 'completion-at-point)))        ; …and hands it on
      (define-key drgnx-ai-ghost-mode-map (kbd "TAB") was))))

(ert-deftest drgnx-ai/every-ai-command-is-registered ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (funcall (plist-get (alist-get 'tools/ai drgnx-modules--table) :setup))
    (dolist (id '(ai-accept ai-accept-word ai-accept-line ai-dismiss ai-tab ai-complete-toggle
                            ai-edit ai-edit-apply-hunk ai-edit-done ai-edit-reject))
      (should (drgnx-commands-get id)))))

;;; ai-ghost-test.el ends here
