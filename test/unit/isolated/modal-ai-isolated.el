;;; modal-ai-isolated.el --- batch tests (own Emacs, test/unit/modal-ai-test.el): AI ghost text and the selection under Vim keys -*- lexical-binding: t -*-
;; Needs the real evil: DRGNX_MODAL_ELPA (docs/develop/harness.md, "Modal tests"); without it these tests skip.
;; The full registry and the startup modules run in a temp configuration (editor/evil chosen, the Vim stack
;; applied), so the keys are the shipped ones; the `complete' role is a mock LLM, as in test/unit/ai-ghost-test.el.
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'drgnx)
(require 'drgnx-modal)
(load (expand-file-name "test/fixtures/modal-elpa" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)

(defvar evil-state)
(defvar drgnx-ai-detected)
(defvar drgnx-ai-ghost--request)
(defvar drgnx-ai-ghost--timer)
(declare-function evil-insert-state "evil-states")
(declare-function drgnx-evil-stop "drgnx-evil")
(declare-function drgnx-ai-ghost-text "drgnx-ai-ui")
(declare-function drgnx-ai-ghost-text-shown "drgnx-ai-ui")
(declare-function drgnx-ai-ghost--post-command "drgnx-ai-ui")

(defconst drgnx-modal-ai-test--answer "(message name)" "What the mock `complete' provider suggests.")

(defvar drgnx-modal-ai-test--asked 0 "How many suggestions were asked for.")

(defun drgnx-modal-ai-test--count (&rest _)
  "Advice before `drgnx-ai-request': count the questions of the `complete' role."
  (cl-incf drgnx-modal-ai-test--asked))

(defmacro drgnx-modal-ai-test--with (&rest body)
  "BODY with evil running in the Vim stack, all startup modules run, in a temp configuration whose `complete' role
is a mock LLM (found running) answering `drgnx-modal-ai-test--answer'."
  (declare (indent 0))
  `(drgnx-modal-test-with-evil
     (let* ((dir (file-name-as-directory (make-temp-file "drgnx-modal-ai" t)))
            (port nil) (script (concat dir "llm.eld"))
            (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir "config")
                                               (concat "DRGNX_DATA_DIR=" dir "data")
                                               (concat "XDG_STATE_HOME=" dir "state")
                                               (concat "HOME=" dir "home"))
                                         process-environment))
            (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
            (drgnx-commands-problems nil) (drgnx-modules--table nil) (drgnx-modules--report nil)
            (drgnx-modules--state nil) (drgnx-modal-engines nil) (drgnx-modal-running nil)
            (drgnx-keys--applied nil) (drgnx-keys-profiles nil) (drgnx-keys-problems nil) (drgnx-keys-last nil)
            (drgnx-keys--session-layers nil)
            (drgnx-ai-detected '((o :up t)))
            (emulation-mode-map-alists emulation-mode-map-alists)
            (mode-line-saved (default-value 'mode-line-format))
            (drgnx-modal-ai-test--asked 0)
            (mock nil))
       (make-directory (concat dir "config") t)
       (make-directory (concat dir "home") t)
       (write-region "(:version 1 :enabled (editor/evil))\n" nil (concat dir "config/modules.eld") nil 'silent)
       (with-temp-file script
         (prin1 `((:path "/api/generate" :body ,(json-encode (list :response drgnx-modal-ai-test--answer)))) (current-buffer)))
       (unwind-protect
           (progn
             (setq mock (drgnx-ai-test-mock-llm nil script)
                   port (process-get mock :port))
             (with-temp-file (concat dir "config/ai.eld")
               (prin1 `(:version 1 :providers ((o :name "O" :kind ollama :url ,(format "http://127.0.0.1:%d" port) :caps (chat fim)))
                                 :roles ((complete (o . "coder"))))
                      (current-buffer)))
             (drgnx--core-commands)
             (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
             (drgnx-modules-run 'startup)
             (drgnx-keys-use '((vim app editing window)))
             (should (eq drgnx-modal-running 'evil))
             (advice-add 'drgnx-ai-request :before #'drgnx-modal-ai-test--count)
             ,@body)
         (advice-remove 'drgnx-ai-request #'drgnx-modal-ai-test--count)
         (when (timerp drgnx-ai-ghost--timer) (cancel-timer drgnx-ai-ghost--timer))
         (when (fboundp 'drgnx-evil-stop) (drgnx-evil-stop))
         (drgnx-keys--restore)
         (setq-default mode-line-format mode-line-saved)
         (when mock (delete-process mock))
         (delete-directory dir t)))))

(defmacro drgnx-modal-ai-test--buffer (text &rest body)
  "BODY in a new Emacs Lisp buffer holding TEXT, point at its start, shown in the selected window (the pause asks
only for the buffer on screen), in the state evil gives it; killed after."
  (declare (indent 1))
  `(let ((buf (generate-new-buffer "modal-ai-test")))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer buf)
           (with-current-buffer buf
             (emacs-lisp-mode)
             (insert ,text)
             (goto-char (point-min))
             ,@body))
       (kill-buffer buf))))

(defun drgnx-modal-ai-test--keys (keys)
  "Press KEYS (a `kbd' string) in the selected window, as the command loop runs them (with the hooks).
The macro's command loop runs `post-command-hook' once as it starts, before any key, for the command before it
\(`this-command'); a real key press has no such run.  A command the ghost keeps the suggestion for makes it a no-op,
so what clears a suggestion is the keys pressed."
  (let ((this-command 'drgnx-ai-accept))
    (execute-kbd-macro (kbd keys))))

(defun drgnx-modal-ai-test--pause ()
  "The pause after the last command: the idle timer the ghost's post-command set, run now as Emacs runs a due timer
\(`timer-event-handler', which also takes it off the idle list)."
  (when (timerp drgnx-ai-ghost--timer)
    (timer-event-handler drgnx-ai-ghost--timer)))

(defun drgnx-modal-ai-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 5)))) (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.02)))
  (funcall pred))

(defun drgnx-modal-ai-test--suggest ()
  "Enter insert state with `a' after the first character, pause, and wait for the mock's suggestion."
  (drgnx-modal-ai-test--keys "a")
  (should (eq evil-state 'insert))
  (drgnx-modal-ai-test--pause)
  (should (drgnx-modal-ai-test--wait #'drgnx-ai-ghost-text))
  (should (equal (drgnx-ai-ghost-text) drgnx-modal-ai-test--answer)))

;;;; Ghost text

(ert-deftest drgnx-modal-ai/no-suggestion-outside-insert ()
  (drgnx-modal-ai-test--with
    (drgnx-modal-ai-test--buffer "(defun greet (name)\n  )\n"
      (should (eq evil-state 'normal))
      (should drgnx-ai-ghost-mode)
      (drgnx-modal-ai-test--keys "l")                              ; a motion in normal state, then the pause
      (drgnx-modal-ai-test--pause)
      (should (= drgnx-modal-ai-test--asked 0))
      (should-not drgnx-ai-ghost--request)
      (drgnx-modal-ai-test--keys "V")                              ; visual state: nothing either
      (drgnx-modal-ai-test--pause)
      (should (= drgnx-modal-ai-test--asked 0))
      (drgnx-modal-ai-test--keys "<escape>")
      (drgnx-modal-ai-test--suggest)                               ; insert state: one question, its answer shows
      (should (= drgnx-modal-ai-test--asked 1))
      (drgnx-modal-ai-test--keys "<escape> C-z")                   ; emacs state types with Emacs' keys: it asks
      (should (eq evil-state 'emacs))
      (drgnx-modal-ai-test--pause)
      (should (= drgnx-modal-ai-test--asked 2))
      (drgnx-modal-ai-test--keys "C-z R")                          ; replace state: Tab's insert would not overwrite
      (should (eq evil-state 'replace))
      (drgnx-modal-ai-test--pause)
      (should (= drgnx-modal-ai-test--asked 2)))))

(ert-deftest drgnx-modal-ai/one-escape-dismisses-and-leaves-insert ()
  (drgnx-modal-ai-test--with
    (drgnx-modal-ai-test--buffer "(defun greet (name)\n  )\n"
      (drgnx-modal-ai-test--suggest)
      (let ((before (buffer-string)))
        (drgnx-modal-ai-test--keys "<escape>")
        (should (eq evil-state 'normal))
        (should-not (drgnx-ai-ghost-text))
        (should-not (drgnx-ai-ghost-text-shown))
        (should (equal (buffer-string) before))))))

(ert-deftest drgnx-modal-ai/tab-accepts-in-insert ()
  (drgnx-modal-ai-test--with
    (drgnx-modal-ai-test--buffer "(defun greet (name)\n  )\n"
      (drgnx-modal-ai-test--suggest)
      (let ((pt (point)))
        (drgnx-modal-ai-test--keys "TAB")
        (should (equal (buffer-substring-no-properties pt (point)) drgnx-modal-ai-test--answer))
        (should-not (drgnx-ai-ghost-text))
        (should (eq evil-state 'insert))))))

;;;; The selection

(ert-deftest drgnx-modal-ai/visual-line-edits-whole-lines ()
  (drgnx-modal-ai-test--with
    (drgnx-modal-ai-test--buffer "one\ntwo\nthree\nfour\n"
      (forward-line 1)
      (let ((beg (line-beginning-position 1)) (end (line-beginning-position 3)) (got nil))
        (drgnx-modal-ai-test--keys "V j")
        (should (eq evil-state 'visual))
        (should (equal (drgnx-modal-selection) (cons beg end)))
        ;; the spec, as the palette or a key evaluates it: lines 2 and 3, with the last newline
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "shorter")))
          (should (equal (advice-eval-interactive-spec (cadr (interactive-form 'drgnx-ai-edit)))
                         (list "shorter" beg end)))
          ;; and Vim's own key for it, from visual state
          (let ((record (lambda (&rest args) (setq got args))))
            (advice-add 'drgnx-ai-edit :override record)
            (unwind-protect (drgnx-modal-ai-test--keys "SPC a e")
              (advice-remove 'drgnx-ai-edit record))))
        (should (equal got (list "shorter" beg end)))
        ;; out of visual state there is no selection: the defun at point again
        (drgnx-modal-ai-test--keys "<escape>")
        (should (eq evil-state 'normal))
        (should-not (drgnx-modal-selection))))))

(defun drgnx-modal-ai-test--spec ()
  "Edit with AI's interactive spec evaluated here, the instruction answered \"shorter\"."
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "shorter")))
    (advice-eval-interactive-spec (cadr (interactive-form 'drgnx-ai-edit)))))

(ert-deftest drgnx-modal-ai/visual-block-edits-the-lines-it-touches ()
  ;; one region cannot be a rectangle: the stream between the corners would send text outside the columns
  (drgnx-modal-ai-test--with
    (drgnx-modal-ai-test--buffer "one\ntwo\nthree\nfour\n"
      (forward-line 1)
      (let ((beg (line-beginning-position 1)) (end (line-beginning-position 3)))
        (drgnx-modal-ai-test--keys "C-v j l")
        (should (eq evil-state 'visual))
        (should (equal (drgnx-modal-selection) (cons beg end)))
        (should (equal (drgnx-modal-ai-test--spec) (list "shorter" beg end)))))))

(ert-deftest drgnx-modal-ai/visual-edits-the-characters-under-both-ends ()
  (drgnx-modal-ai-test--with
    (drgnx-modal-ai-test--buffer "one\ntwo\nthree\nfour\n"
      (forward-line 1)
      (let ((beg (point)))
        (drgnx-modal-ai-test--keys "v l l")                        ; "two"
        (should (equal (drgnx-modal-selection) (cons beg (+ beg 3))))
        (should (equal (drgnx-modal-ai-test--spec) (list "shorter" beg (+ beg 3))))
        (drgnx-modal-ai-test--keys "<escape> v h")                 ; backwards from the last o: "wo", in order
        (should (equal (drgnx-modal-selection) (cons (1+ beg) (+ beg 3))))))
    ;; an empty buffer: an empty selection is none, Edit with AI falls back to the line
    (drgnx-modal-ai-test--buffer ""
      (drgnx-modal-ai-test--keys "v")
      (should (eq evil-state 'visual))
      (should-not (drgnx-modal-selection))
      (should (equal (drgnx-modal-ai-test--spec) '("shorter" 1 1))))))

(ert-deftest drgnx-modal-ai/stop-gives-the-hooks-back ()
  (drgnx-modal-ai-test--with
    (should (memq 'drgnx-evil--ghost-inhibit drgnx-ai-ghost-inhibit-functions))
    (should (eq drgnx-modal-selection-function 'drgnx-evil--selection))
    (drgnx-evil-stop)
    (should-not (memq 'drgnx-evil--ghost-inhibit drgnx-ai-ghost-inhibit-functions))
    (should-not drgnx-modal-selection-function)))

(provide 'modal-ai-isolated)
;;; modal-ai-isolated.el ends here
