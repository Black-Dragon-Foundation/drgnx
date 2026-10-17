;;; ai-edit-test.el --- batch tests: inline edit reviewed hunk by hunk -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "modules/tools/drgnx-ai-ui" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)

(defmacro drgnx-ai-edit-test--with (answer &rest body)
  "BODY with the `edit' role on provider `o' (Ollama), served by a mock answering ANSWER (a string) to every chat."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-ai-edit" t)))
          (port (+ 20000 (random 20000))) (script (concat root "llm.eld")) (log (concat root "llm.log"))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config")) process-environment))
          (drgnx-ai-detected '((o :up t)))
          (mock nil))
     (unwind-protect
         (progn
           (make-directory (concat root "config") t)
           (with-temp-file script
             (prin1 (list (list :path "/api/chat" :body (json-serialize (list :message (list :content ,answer))))) (current-buffer)))
           (with-temp-file (concat root "config/ai.eld")
             (prin1 `(:version 1 :providers ((o :name "O" :kind ollama :url ,(format "http://127.0.0.1:%d" port) :caps (chat fim)))
                               :roles ((edit (o . "m"))))
                    (current-buffer)))
           (setq mock (drgnx-ai-test-mock-llm port script log))
           ,@body)
       (when mock (delete-process mock))
       (dolist (b (buffer-list)) (when (string-prefix-p "*AI edit" (buffer-name b)) (kill-buffer b)))
       (delete-directory root t))))

(defun drgnx-ai-edit-test--review (&optional secs)
  "The review buffer, once the answer came."
  (let ((deadline (+ (float-time) (or secs 5))) b)
    (while (and (not (setq b (seq-find (lambda (x) (string-prefix-p "*AI edit" (buffer-name x))) (buffer-list))))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    b))

;; the two changes far enough apart (more than diff's 3 lines of context each side) to be two hunks
(defconst drgnx-ai-edit-test--gap ";; 1\n;; 2\n;; 3\n;; 4\n;; 5\n;; 6\n;; 7\n;; 8\n")
(defconst drgnx-ai-edit-test--code (concat "(defun a ()\n  1)\n" drgnx-ai-edit-test--gap "(defun b ()\n  2)\n"))

(ert-deftest drgnx-ai-edit/the-region-s-new-text-is-reviewed-hunk-by-hunk ()
  (drgnx-ai-edit-test--with (concat "(defun a ()\n  10)\n" drgnx-ai-edit-test--gap "(defun b ()\n  20)\n")
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert ";; header\n" drgnx-ai-edit-test--code ";; footer\n")
      (let ((start (save-excursion (goto-char (point-min)) (forward-line 1) (point)))
            (end (save-excursion (goto-char (point-max)) (forward-line -1) (point)))
            (src (current-buffer)))
        (drgnx-ai-edit "times ten" start end)
        (let ((review (drgnx-ai-edit-test--review)))
          (should review)
          (with-current-buffer review
            (should (string-search "+  10)" (buffer-string)))
            (should (string-search "+  20)" (buffer-string)))
            ;; apply only the second hunk, then Done
            (goto-char (point-min)) (diff-hunk-next) (diff-hunk-next)
            (let ((inhibit-message t)) (diff-apply-hunk))
            (drgnx-ai-edit-done))
          (with-current-buffer src
            (should (equal (buffer-string)
                           (concat ";; header\n(defun a ()\n  1)\n" drgnx-ai-edit-test--gap "(defun b ()\n  20)\n;; footer\n")))))))))

(ert-deftest drgnx-ai-edit/applying-a-hunk-keeps-the-review-on-screen ()
  ;; diff's own apply shows the file it patches — here the review's temporary copy, in the review's window
  (drgnx-ai-edit-test--with (concat "(defun a ()\n  10)\n" drgnx-ai-edit-test--gap "(defun b ()\n  20)\n")
    (let ((src (generate-new-buffer "src.el")) (was (window-buffer (selected-window))))
      (unwind-protect
          (with-current-buffer src
            (emacs-lisp-mode)
            (insert drgnx-ai-edit-test--code)
            (set-window-buffer (selected-window) src)
            (drgnx-ai-edit "times ten" (point-min) (point-max))
            (let ((review (drgnx-ai-edit-test--review)))
              (select-window (get-buffer-window review))
              (goto-char (point-min)) (diff-hunk-next) (diff-hunk-next)
              (let ((inhibit-message t)) (drgnx-ai-edit-apply-hunk))
              (should (eq (window-buffer (selected-window)) review))
              (should-not (seq-find (lambda (w) (string-prefix-p "now-" (buffer-name (window-buffer w)))) (window-list)))
              (with-current-buffer review (drgnx-ai-edit-done))
              (should (equal (with-current-buffer src (buffer-string))
                             (concat "(defun a ()\n  1)\n" drgnx-ai-edit-test--gap "(defun b ()\n  20)\n")))))
        (set-window-buffer (selected-window) was)
        (kill-buffer src)))))

(ert-deftest drgnx-ai-edit/text-typed-at-the-region-s-edges-while-it-answers-is-kept ()
  (drgnx-ai-edit-test--with "(defun a ()\n  10)\n"
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert "(defun a ()\n  1)\n")
      (let ((end (point-max)))
        (drgnx-ai-edit "times ten" (point-min) end)
        (goto-char end) (insert ";; typed after it\n")                         ; right at its end
        (goto-char (point-min)) (insert ";; typed before it\n")               ; right at its start
        (let ((review (drgnx-ai-edit-test--review)))
          (should review)
          (with-current-buffer review
            (should-not (string-search "-;; typed" (buffer-string)))         ; never shown as deleted
            (goto-char (point-min)) (diff-hunk-next) (let ((inhibit-message t)) (drgnx-ai-edit-apply-hunk))
            (drgnx-ai-edit-done))
          (should (equal (buffer-string) ";; typed before it\n(defun a ()\n  10)\n;; typed after it\n")))))))

(ert-deftest drgnx-ai-edit/a-region-edited-while-it-answers-gets-no-review ()
  (drgnx-ai-edit-test--with "(defun a ()\n  10)\n"
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert "(defun a ()\n  1)\n")
      (let ((said nil))
        (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) said)))))
          (drgnx-ai-edit "times ten" (point-min) (point-max))
          (goto-char 3) (insert "X")                                          ; inside the region
          (let ((deadline (+ (float-time) 5)))
            (while (and (not (seq-find (lambda (m) (string-match-p "changed while" m)) said)) (< (float-time) deadline))
              (accept-process-output nil 0.05))))
        (should (seq-find (lambda (m) (string-match-p "changed while" m)) said))
        (should-not (drgnx-ai-edit-test--review 0.2))
        (should (equal (buffer-string) "(dXefun a ()\n  1)\n"))))))

(ert-deftest drgnx-ai-edit/edits-elsewhere-meanwhile-are-kept-a-changed-region-is-not-overwritten ()
  (drgnx-ai-edit-test--with "(defun a ()\n  10)\n"
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert "(defun a ()\n  1)\n;; end\n")
      (let ((src (current-buffer)))
        (drgnx-ai-edit "times ten" 1 (save-excursion (goto-char (point-min)) (forward-line 2) (point)))
        (goto-char (point-max)) (insert ";; typed while the model thought\n")     ; outside the region
        (let ((review (drgnx-ai-edit-test--review)))
          (goto-char (point-max)) (insert ";; typed during the review\n")           ; outside the region, after the answer
          (with-current-buffer review
            (goto-char (point-min)) (diff-hunk-next) (let ((inhibit-message t)) (diff-apply-hunk))
            (drgnx-ai-edit-done))
          (with-current-buffer src
            (should (equal (buffer-string)
                           "(defun a ()\n  10)\n;; end\n;; typed while the model thought\n;; typed during the review\n")))))
      ;; a second edit; the region itself changes during the review: Done refuses, nothing is overwritten
      (erase-buffer) (insert "(defun a ()\n  1)\n")
      (drgnx-ai-edit "times ten" (point-min) (point-max))
      (let ((review (drgnx-ai-edit-test--review)))
        (goto-char (point-min)) (forward-line 1) (insert ";; ")                   ; inside the region
        (with-current-buffer review
          (goto-char (point-min)) (diff-hunk-next) (let ((inhibit-message t)) (diff-apply-hunk))
          (should-error (drgnx-ai-edit-done) :type 'user-error))
        (should (equal (buffer-string) "(defun a ()\n;;   1)\n"))))))

(ert-deftest drgnx-ai-edit/the-model-s-code-fence-is-not-code ()
  (drgnx-ai-edit-test--with "Here it is:\n```elisp\n(defun a ()\n  10)\n```\n"
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert "(defun a ()\n  1)\n")
      (drgnx-ai-edit "times ten" (point-min) (point-max))
      (let ((review (drgnx-ai-edit-test--review)))
        (with-current-buffer review
          (should-not (string-search "```" (buffer-string)))
          (should-not (string-search "Here it is" (buffer-string))))))))

(ert-deftest drgnx-ai-edit/reject-leaves-the-buffer-as-it-was ()
  (drgnx-ai-edit-test--with "(defun a ()\n  10)\n"
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert "(defun a ()\n  1)\n")
      (drgnx-ai-edit "times ten" (point-min) (point-max))
      (let ((review (drgnx-ai-edit-test--review)))
        (with-current-buffer review
          (goto-char (point-min)) (diff-hunk-next) (let ((inhibit-message t)) (diff-apply-hunk))
          (drgnx-ai-edit-reject))
        (should-not (buffer-live-p review))
        (should (equal (buffer-string) "(defun a ()\n  1)\n"))))))

(ert-deftest drgnx-ai-edit/no-provider-says-why-and-changes-nothing ()
  (drgnx-ai-edit-test--with "never"
    (let ((drgnx-ai-detected nil) (said nil))
      (with-temp-file (concat root "config/ai.eld") (prin1 '(:version 1 :roles ((edit (dead . "m")))) (current-buffer)))
      (with-temp-buffer
        (insert "x\n")
        (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
          (drgnx-ai-edit "y" (point-min) (point-max))
          (let ((deadline (+ (float-time) 3))) (while (and (not said) (< (float-time) deadline)) (accept-process-output nil 0.05))))
        (should (seq-find (lambda (m) (string-match-p "AI edit: no answer" m)) said))
        (should-not (drgnx-ai-edit-test--review 0.2))
        (should (equal (buffer-string) "x\n"))))))

(ert-deftest drgnx-ai-edit/never-on-c-i ()
  ;; C-i is Tab in a terminal: inline edit must never take it, in any profile
  (dolist (p (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir)))
    (let ((keys (cdr (assq 'ai-edit (plist-get (cdr p) :bind)))))
      (should keys)
      (dolist (k keys) (when (stringp k) (should-not (member k '("C-i" "TAB" "<tab>"))))))))

;;; ai-edit-test.el ends here
