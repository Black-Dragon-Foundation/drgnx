;;; terminal-bin-test.el --- batch tests: `drgnx PATH' typed in drgnx's own terminal -*- lexical-binding: t -*-
;; A fake emacsclient records its argv; bin/drgnx runs in a temp dir with it first on PATH, never a real server.
(require 'ert)
(require 'seq)

(defconst drgnx-terminal-bin-test--bin
  (expand-file-name "../../bin/drgnx" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-terminal-bin-test--fakes (dir)
  "Fake `emacs' and `emacsclient' in DIR/path: emacsclient logs each call to DIR/client.log (each argument followed
by \\037, one line per call), says the server runs (`-e t') and has a window (`(drgnx-session-gui-frame-p)')."
  (let ((pathdir (expand-file-name "path" dir))
        (log (shell-quote-argument (expand-file-name "client.log" dir))))
    (make-directory pathdir)
    (dolist (spec `(("nidhogg" . "exit 0")
                    ("emacsclient" . ,(format "printf '%%s\\037' \"$@\" >> %s; echo >> %s
for a in \"$@\"; do last=\"$a\"; done
case \"$last\" in '(drgnx-session-gui-frame-p)') echo t ;; esac" log log))))
      (let ((file (expand-file-name (car spec) pathdir)))
        (write-region (concat "#!/bin/sh\n" (cdr spec) "\n") nil file)
        (set-file-modes file #o755)))
    pathdir))

(defun drgnx-terminal-bin-test--calls (dir)
  "The fake emacsclient's calls, each a list of its arguments."
  (let ((file (expand-file-name "client.log" dir)))
    (and (file-exists-p file)
         (mapcar (lambda (line) (split-string line "\037" t))
                 (split-string (with-temp-buffer (insert-file-contents file) (buffer-string)) "\n" t)))))

(defun drgnx-terminal-bin-test--run (dir env &rest args)
  "Run bin/drgnx ARGS in DIR with the fakes first on PATH and ENV (\"K=V\", or a bare name to unset); (EXIT . OUTPUT)."
  (let ((process-environment
         (append env (list (concat "PATH=" (expand-file-name "path" dir) ":/usr/bin:/bin")
                           (concat "XDG_STATE_HOME=" (expand-file-name "state" dir))
                           (concat "DRGNX_CONFIG_DIR=" (expand-file-name "config" dir))
                           "DRGNX_EMACS")
                 process-environment))
        (default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (cons (apply #'call-process drgnx-terminal-bin-test--bin nil t nil args) (buffer-string)))))

(defmacro drgnx-terminal-bin-test--with-dir (&rest body)
  "BODY with DIR a temp directory holding the fakes, a file `My \"File\" café.py' and a folder `a b'."
  (declare (indent 0))
  `(let ((dir (make-temp-file "drgnx-terminal-bin" t)))
     (unwind-protect
         (progn
           (drgnx-terminal-bin-test--fakes dir)
           (write-region "" nil (expand-file-name "My \"File\" café.py" dir))
           (make-directory (expand-file-name "a b" dir))
           ,@body)
       (delete-directory dir t))))

(ert-deftest drgnx-bin/inside-eat-opens-in-this-drgnx ()
  ;; In drgnx's own terminal (eat sets INSIDE_EMACS, drgnx sets DRGNX_SERVER_NAME to its server's socket) `drgnx FILE'
  ;; opens in that Emacs, in its selected frame: never a new window (-c) or a terminal frame (-t), no raise.
  (drgnx-terminal-bin-test--with-dir
    (let* ((sock "/tmp/x/sock")
           (env (list "INSIDE_EMACS=31.1,eat" (concat "DRGNX_SERVER_NAME=" sock)))
           (file (expand-file-name "My \"File\" café.py" dir))
           (folder (expand-file-name "a b" dir)))
      (should (equal (drgnx-terminal-bin-test--run dir env "My \"File\" café.py" "a b") '(0 . "")))
      (let ((calls (drgnx-terminal-bin-test--calls dir)))
        (should (equal calls
                       (list (list "-a" "false" "-s" sock "-n" "--" file)
                             (list "-a" "false" "-s" sock "-n" "-e" (format "(drgnx-session-open-folder %S)" folder)))))
        (should-not (seq-some (lambda (c) (or (member "-c" c) (member "-t" c))) calls)))
      ;; --wait (an $EDITOR of the user's own, `drgnx open --wait'): this drgnx too, until C-x #
      (delete-file (expand-file-name "client.log" dir))
      (should (eql 0 (car (drgnx-terminal-bin-test--run dir env "open" "--wait" "My \"File\" café.py"))))
      (should (equal (drgnx-terminal-bin-test--calls dir) (list (list "-a" "false" "-s" sock "--" file))))
      ;; --wait still takes files only
      (should (eql 2 (car (drgnx-terminal-bin-test--run dir env "open" "--wait" "a b")))))))

(ert-deftest drgnx-bin/outside-eat-opens-as-before ()
  ;; Without eat's INSIDE_EMACS (another terminal, or Emacs's shell-mode) `drgnx FILE' is today's: the server is asked
  ;; whether it runs and has a window, the window is raised, then the file opens.
  (drgnx-terminal-bin-test--with-dir
    (let ((file (expand-file-name "My \"File\" café.py" dir))
          (c (lambda (&rest args) (append (list "-a" "false" "-s" "drgnx-terminal-bin-test") args))))
      (dolist (inside '("INSIDE_EMACS" "INSIDE_EMACS=31.1,comint"))
        (when (file-exists-p (expand-file-name "client.log" dir)) (delete-file (expand-file-name "client.log" dir)))
        (should (equal (drgnx-terminal-bin-test--run dir (list inside "DRGNX_SERVER_NAME=drgnx-terminal-bin-test")
                                                     "My \"File\" café.py")
                       '(0 . "")))
        (should (equal (drgnx-terminal-bin-test--calls dir)
                       (list (funcall c "--timeout=5" "-e" "t")
                             (funcall c "--timeout=5" "-e" "(drgnx-session-gui-frame-p)")
                             (funcall c "-n" "-e" "(drgnx-session-raise)")
                             (funcall c "-n" "-e" "(progn (require 'drgnx-ai) (drgnx-ai-load-keys-soon))")
                             (funcall c "-n" "--" file))))))))

;;; terminal-bin-test.el ends here
