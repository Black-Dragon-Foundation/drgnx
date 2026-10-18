;;; dape-live-test.el --- live test: dape drives a real adapter (debugpy) to a breakpoint -*- lexical-binding: t -*-
;; The unit tests check dape against its source; this runs it once against debugpy.  It needs python3 with debugpy and
;; dape, so it skips on a machine without them: test/container/Containerfile.tools has both (docs/develop/harness.md,
;; "Real-tool tests").  dape comes from $DRGNX_TOOLS_ELPA when set, else from the load path; nothing under ~ is used.
(require 'ert)
(require 'cl-lib)

(defun drgnx-dape-live--ready ()
  "Whether python3 has debugpy and dape can be loaded (its directory, $DRGNX_TOOLS_ELPA, joins the load path)."
  (let ((elpa (getenv "DRGNX_TOOLS_ELPA")))
    (when (and elpa (file-directory-p elpa))
      (dolist (d (directory-files elpa t "\\`dape-[0-9]")) (add-to-list 'load-path d))))
  (and (executable-find "python3")
       (eql 0 (call-process "python3" nil nil nil "-c" "import debugpy.adapter"))
       (locate-library "dape")))

(defun drgnx-dape-live--wait (pred secs)
  (let ((deadline (+ (float-time) secs)))
    (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.1))
    (funcall pred)))

(ert-deftest drgnx-dape-live/debugpy-stops-at-the-breakpoint-on-line-2 ()
  (skip-unless (drgnx-dape-live--ready))
  (require 'dape)
  (let* ((dir (file-name-as-directory (make-temp-file "drgnx-dape" t)))
         (script (expand-file-name "prog.py" dir))
         (default-directory dir)
         (stopped nil)
         (dape-stopped-hook (cons (lambda () (setq stopped t)) dape-stopped-hook))
         (dape-buffer-window-arrangement 'right))
    (write-region "x = 1\ny = x + 1\nprint(y)\n" nil script nil 'silent)
    (unwind-protect
        (with-current-buffer (find-file-noselect script)
          (goto-char (point-min)) (forward-line 1)                       ; line 2
          (dape-breakpoint-toggle)
          (let ((config (copy-tree (alist-get 'debugpy dape-configs))))
            (setq config (plist-put config 'command "python3")           ; Fedora has no `python'
                  config (plist-put config :program script)
                  config (plist-put config :cwd dir)                      ; dape-cwd is a symbol dape resolves when asked interactively
                  config (plist-put config :console "internalConsole"))   ; no terminal in a batch Emacs
            (dape config))
          (should (drgnx-dape-live--wait (lambda () (and stopped (dape--live-connection 'stopped t))) 60))
          (let* ((conn (dape--live-connection 'stopped t))
                 (frame (progn (should (drgnx-dape-live--wait (lambda () (dape--current-stack-frame conn)) 30))
                               (dape--current-stack-frame conn))))
            (should (equal (plist-get frame :line) 2))
            (should (equal (file-name-nondirectory (plist-get (plist-get frame :source) :path)) "prog.py"))))
      (ignore-errors (dape--kill-busy-wait))
      (dolist (b (buffer-list)) (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b)))
                                  (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
      (delete-directory dir t))))
