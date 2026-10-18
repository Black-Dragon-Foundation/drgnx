;;; agent-config-fixture.el --- for agent settings tests: temp agent homes, a temp project, fake CLIs -*- lexical-binding: t -*-
(require 'subr-x)

(defvar drgnx-agent-config-test--dir nil
  "The temp directory of the running `drgnx-agent-config-test-env' (with a trailing slash).")

(defun drgnx-agent-config-test-argv-log ()
  "The file the fake `claude', `codex' and `kimi' scripts append their arguments to (one line per run)."
  (expand-file-name "argv.log" drgnx-agent-config-test--dir))

(defun drgnx-agent-config-test-argv ()
  "The runs of the fake CLIs so far, as a list of lines `NAME ARG…'; nil when none ran."
  (let ((log (drgnx-agent-config-test-argv-log)))
    (when (file-exists-p log)
      (split-string (with-temp-buffer (insert-file-contents log) (buffer-string)) "\n" t))))

(defun drgnx-agent-config-test--make-fakes (bin log)
  "Make fake CLIs in BIN, each appending its name and arguments to LOG and exiting 0."
  (make-directory bin t)
  (dolist (name '("claude" "codex" "kimi"))
    (let ((script (expand-file-name name bin)))
      (write-region (format "#!/bin/sh\nprintf '%%s\\n' \"%s $*\" >> '%s'\nexit 0\n" name log) nil script nil 'silent)
      (set-file-modes script #o755))))

(defmacro drgnx-agent-config-test-env (&rest body)
  "BODY with fresh temp dirs for HOME (bound to `home'), CLAUDE_CONFIG_DIR, CODEX_HOME, KIMI_CODE_HOME and Gemini's
home (GEMINI_CLI_HOME, whose `.gemini' is the settings dir), a temp project (bound to `root'), and fake `claude',
`codex' and `kimi' scripts first on PATH and `exec-path'.  Nothing of the user's is read or written."
  (declare (indent 0))
  `(let* ((drgnx-agent-config-test--dir (file-name-as-directory (make-temp-file "drgnx-agentcfg" t)))
          (dir drgnx-agent-config-test--dir)
          (home (file-name-as-directory (expand-file-name "home" dir)))
          (root (file-name-as-directory (expand-file-name "project" dir)))
          (bin (expand-file-name "bin" dir))
          (process-environment
           (append (list (concat "HOME=" home)
                         (concat "CLAUDE_CONFIG_DIR=" (expand-file-name "claude" dir))
                         (concat "CODEX_HOME=" (expand-file-name "codex" dir))
                         (concat "KIMI_CODE_HOME=" (expand-file-name "kimi" dir))
                         (concat "GEMINI_CLI_HOME=" (expand-file-name "gemini" dir))
                         (concat "XDG_CONFIG_HOME=" (expand-file-name "xdg" dir))
                         (concat "PATH=" bin path-separator (or (getenv "PATH") "/usr/bin:/bin")))
                   process-environment))
          (exec-path (cons bin exec-path)))
     (ignore home root)
     (unwind-protect
         (progn
           (make-directory home t)
           (make-directory root t)
           (drgnx-agent-config-test--make-fakes bin (drgnx-agent-config-test-argv-log))
           ,@body)
       (delete-directory dir t))))

(provide 'agent-config-fixture)
;;; agent-config-fixture.el ends here
