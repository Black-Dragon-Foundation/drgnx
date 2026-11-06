;;; agents-follow-test.el --- the follow window: detach, resume, edit keys, safe opening, refresh -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  The hub's calls are recorded and its `agent-follow' events are fed by hand; files are real, in a
;; temp directory.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agents-in-editor))

(declare-function drgnx-agents-follow-start "drgnx-agents-follow")
(declare-function drgnx-agents-follow-stop "drgnx-agents-follow")
(declare-function drgnx-agents-follow-resume "drgnx-agents-follow")
(declare-function drgnx-agents-follow-edit-hint "drgnx-agents-follow")
(declare-function drgnx-agents-follow--event "drgnx-agents-follow")
(declare-function drgnx-agents-follow--open "drgnx-agents-follow")
(defvar drgnx-agents-follow--view)
(defvar drgnx-agents-follow--window)
(defvar drgnx-agents-follow--detached)
(defvar drgnx-agents-follow-test--evil nil "Set by a .dir-locals.el that must never run.")

(defmacro drgnx-agents-follow-test--with (&rest body)
  "BODY with the module on, a temp directory `root' and the hub's calls recorded in `calls' (newest first)."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "agents-follow" t)))) (calls nil))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-hub-call)
                    (lambda (method params &rest _) (push (cons method params) calls) 1)))
           (drgnx-test-with-modules '(tools/agents-in-editor)
             (save-window-excursion
               (delete-other-windows)
               (unwind-protect (progn ,@body) (drgnx-agents-follow-stop)))))
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p root (buffer-file-name b))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
       (delete-directory root t))))

(defun drgnx-agents-follow-test--write (file text)
  (make-directory (file-name-directory file) t)
  (write-region text nil file nil 'silent))

(defun drgnx-agents-follow-test--move (file line &optional changed)
  "Feed the follow feed's event: session s1 is at LINE of FILE."
  (drgnx-agents-follow--event
   "agent-follow"
   (append (list :view drgnx-agents-follow--view :session "s1" :file file :worktree (file-name-directory file) :line line :col 1
                 :mode "read" :step_title "Read a.el" :why_source "step_title")
           (and changed (list :changed t)))))

(defun drgnx-agents-follow-test--line (w) (with-current-buffer (window-buffer w) (line-number-at-pos (window-point w) t)))

(ert-deftest drgnx-agents-follow/navigation-detaches-and-f-resumes ()
  (drgnx-agents-follow-test--with
    (let ((file (expand-file-name "a.el" root)))
      (drgnx-agents-follow-test--write file "one\ntwo\nthree\nfour\nfive\nsix\n")
      (drgnx-agents-follow-start "s1")
      (should (equal (list :view drgnx-agents-follow--view :session "s1") (cdr (assoc "agents/follow" calls))))
      (drgnx-agents-follow-test--move file 3)
      (let ((w drgnx-agents-follow--window))
        (should (window-live-p w))
        (should (= 3 (drgnx-agents-follow-test--line w)))
        (should (string-search "Following" (window-parameter w 'header-line-format)))
        ;; a motion in the window detaches: the window stays where the user took it
        (with-selected-window w
          (forward-line 2)
          (let ((this-command 'next-line)) (run-hooks 'post-command-hook)))
        (should drgnx-agents-follow--detached)
        (should (string-search "Paused following" (window-parameter w 'header-line-format)))
        (drgnx-agents-follow-test--move file 6)
        (should (= 5 (drgnx-agents-follow-test--line w)))
        ;; F resumes and jumps to the agent
        (with-selected-window w (drgnx-agents-follow-resume))
        (should-not drgnx-agents-follow--detached)
        (should (= 6 (drgnx-agents-follow-test--line w)))
        (should (string-search "Following" (window-parameter w 'header-line-format)))))))

(ert-deftest drgnx-agents-follow/an-edit-key-hints-the-wheel ()
  (drgnx-agents-follow-test--with
    (let ((file (expand-file-name "a.el" root)) (said nil))
      (drgnx-agents-follow-test--write file "one\ntwo\n")
      (drgnx-agents-follow-start "s1")
      (drgnx-agents-follow-test--move file 1)
      (let* ((w drgnx-agents-follow--window) (buf (window-buffer w)))
        (with-current-buffer buf
          (should buffer-read-only)
          (should (eq 'drgnx-agents-follow-edit-hint (key-binding "a")))
          (should-error (insert "x") :type 'buffer-read-only))
        (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
          (with-selected-window w
            (drgnx-agents-follow-edit-hint)
            (let ((this-command 'drgnx-agents-follow-edit-hint)) (run-hooks 'post-command-hook))))
        (should (cl-some (lambda (s) (string-match-p "W takes the wheel from agent s1" s)) said))
        (should-not drgnx-agents-follow--detached)
        (should (equal "one\ntwo\n" (with-current-buffer buf (buffer-string))))))))

(ert-deftest drgnx-agents-follow/risky-dir-locals-never-prompt ()
  ;; a worktree an agent wrote may hold a .dir-locals.el with an `eval': following it asks nothing and runs nothing
  (drgnx-agents-follow-test--with
    (let ((file (expand-file-name "proj/a.el" root)) (buf nil))
      (drgnx-agents-follow-test--write file "(message \"x\")\n")
      (drgnx-agents-follow-test--write (expand-file-name "proj/.dir-locals.el" root)
                                       "((nil . ((eval . (setq drgnx-agents-follow-test--evil t)))))\n")
      (let ((enable-local-variables t) (enable-local-eval t) (inhibit-interaction t))   ; any question signals
        (setq buf (drgnx-agents-follow--open file)))
      (should (buffer-live-p buf))
      (should (equal file (buffer-file-name buf)))
      (should-not drgnx-agents-follow-test--evil))))

(ert-deftest drgnx-agents-follow/refresh-keeps-point-where-text-is-unchanged ()
  (drgnx-agents-follow-test--with
    (let ((file (expand-file-name "a.el" root)))
      (drgnx-agents-follow-test--write file "one\ntwo\nthree\nfour\nfive\n")
      (drgnx-agents-follow-start "s1")
      (drgnx-agents-follow-test--move file 4)
      (let* ((w drgnx-agents-follow--window) (buf (window-buffer w))
             (marker (with-current-buffer buf (save-excursion (goto-char (point-min)) (forward-line 2) (point-marker)))))
        ;; the agent rewrote the last line only
        (drgnx-agents-follow-test--write file "one\ntwo\nthree\nfour\nfive and more\n")
        (drgnx-agents-follow-test--move file 4 t)
        (with-current-buffer buf
          (should (equal "one\ntwo\nthree\nfour\nfive and more\n" (buffer-string)))
          (should-not (buffer-modified-p))
          (should (= (marker-position marker) (save-excursion (goto-char (point-min)) (forward-line 2) (point)))))
        (should (= 4 (drgnx-agents-follow-test--line w)))))))

(provide 'agents-follow-test)
;;; agents-follow-test.el ends here
