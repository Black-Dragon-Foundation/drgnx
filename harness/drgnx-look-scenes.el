;;; drgnx-look-scenes.el --- The look's scenes, drawn in a session for a side-by-side with the mockups -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx ui look-scenes OUT' starts a session with the drgnx configuration at 1500x1000 logical pixels (times
;; $DRGNX_UI_SCALE), opens a git project in it, and takes one screenshot per scene into OUT, named after the approved
;; mockup it is compared with (`drgnx-look-scenes'), plus the scene's facts (NAME-facts.eld).  No pixel is asserted:
;; a look task is done only when its scene has been put beside its mockup at scales 1 and 2 and looked at
;; (docs/develop/harness.md, "Look scenes").  Packages come from $DRGNX_LOOK_ELPA (a package directory), the mock
;; agent from $DRGNX_RATATOSKR_BIN (a test-hooks ratatoskr); without them those scenes say what is missing.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(declare-function drgnx-ui-start "drgnx-ui")
(declare-function drgnx-ui-stop "drgnx-ui")
(declare-function drgnx-ui-call "drgnx-ui")
(declare-function drgnx-ui-act "drgnx-ui")
(declare-function drgnx-ui-wait "drgnx-ui")
(declare-function drgnx-ui-el "drgnx-ui")
(declare-function drgnx-ui-screenshot "drgnx-ui")
(defvar drgnx-ui-repo-dir)
(defvar drgnx-ui-harness-dir)

(defconst drgnx-look-scenes
  '((window-dark :agent t)
    (agent-panel)
    (palette :keys "C-S-p" :type "run te" :then "C-g")
    (window-light)
    (window-hc)
    (magit)
    (shell-heredoc)
    (work-space-dark))
  "The scenes in the order they are drawn: (NAME . PLIST).  NAME is the mockup's (docs/specs, the-look/NAME.png) and
the session's `drgnx-look-scene-NAME' sets it up.  :agent t starts the mock agent first; :keys and :type are typed
after the setup and before the shot, :then after it.")

(defun drgnx-look-scenes--size (scale)
  "The session's size in device pixels: 1500x1000 logical pixels at SCALE."
  (format "%dx%d" (round (* 1500 scale)) (round (* 1000 scale))))

(defun drgnx-look-scenes--git (dir &rest args)
  (let ((default-directory dir))
    (unless (zerop (apply #'call-process "git" nil nil nil "-c" "user.name=look" "-c" "user.email=look@localhost"
                          "-c" "commit.gpgsign=false" args))
      (error "git %S failed in %s" args dir))))

(defun drgnx-look-scenes-project (dir)
  "Make the scene's project under DIR and return it: a copy of drgnx's core, wb, themes and test/unit on branch main,
two files modified, one untracked, and a shell script with a Python heredoc."
  (let ((proj (file-name-as-directory (expand-file-name "drgnx" dir)))
        (repo (file-name-as-directory (or (bound-and-true-p drgnx-ui-repo-dir)
                                          (expand-file-name ".." (file-name-directory (or load-file-name
                                                                                          buffer-file-name)))))))
    (make-directory proj t)
    (dolist (sub '("core" "wb" "themes" "test/unit"))
      (copy-directory (expand-file-name sub repo) (expand-file-name sub proj) nil t t))
    (dolist (f (directory-files-recursively proj "\\.elc\\'")) (delete-file f))
    (copy-file (expand-file-name "README.md" repo) (expand-file-name "README.md" proj) t)
    (drgnx-look-scenes--git proj "init" "-q" "-b" "main")
    (drgnx-look-scenes--git proj "add" "-A")
    (drgnx-look-scenes--git proj "commit" "-q" "-m" "init")
    (dolist (f '("core/drgnx-palette.el" "core/drgnx-palette-frame.el"))
      (write-region "\n;; changed\n" nil (expand-file-name f proj) t 'silent))
    (write-region ";; new\n" nil (expand-file-name "test/unit/gateway-new-test.el" proj) nil 'silent)
    (write-region (concat "#!/bin/sh\nL=/tmp/l\npython3 - <<PY\nimport ast, subprocess\nFILES=[\"a.py\",\"b.py\"]\n"
                          "def els(src):\n    out={}; imp=[]\n    return out\nfor p in FILES:\n    print(\"moved\", p)\n"
                          "PY\necho \"AST check: $(head -1 $L/ast.log)\"\ngit diff --quiet HEAD -- docs; "
                          "echo \"changed: $?\"\n")
                  nil (expand-file-name "p2-verify.sh" proj) nil 'silent)
    proj))

(defun drgnx-look-scenes--call (sess form &optional timeout)
  "FORM (a string) in SESS; its errors, as a list of strings."
  (append (plist-get (drgnx-ui-call sess form (or timeout 60)) :errors) nil))

(defun drgnx-look-scenes-run (out)
  "Draw every scene into OUT (made if missing); return a plist :shots (paths) :errors (per scene)."
  (require 'drgnx-ui)
  (let* ((out (file-name-as-directory (expand-file-name out)))
         (scale (string-to-number (or (getenv "DRGNX_UI_SCALE") "1")))
         (scale (if (> scale 0) scale 1))
         (tag (format "s%s" (if (= scale (round scale)) (round scale) scale)))
         (tmp (make-temp-file "look-scenes" t))
         (elpa (getenv "DRGNX_LOOK_ELPA"))
         (bin (getenv "DRGNX_RATATOSKR_BIN"))
         (sess nil) shots errors)
    (make-directory out t)
    (unwind-protect
        (let ((proj (drgnx-look-scenes-project tmp)))
          (setq sess (drgnx-ui-start "drgnx" (drgnx-look-scenes--size scale) 180))   ; a first boot compiles
          (drgnx-ui-call sess (format "(progn (load %s nil t) (drgnx-uitest--json (list :ok t)))"
                                      (drgnx-ui-el (expand-file-name "drgnx-look-scenes-session" drgnx-ui-harness-dir))))
          (push (cons 'setup (drgnx-look-scenes--call sess (format "(drgnx-look-scene-setup %s %s)" (drgnx-ui-el proj)
                                                                   (drgnx-ui-el elpa))
                                                      120))
                errors)
          (pcase-dolist (`(,name . ,plist) drgnx-look-scenes)
            (let ((errs nil) (png (expand-file-name (format "%s-%s.png" name tag) out)))
              (when (plist-get plist :agent)
                (setq errs (drgnx-look-scenes--call sess (format "(drgnx-look-scene-agent %s)" (drgnx-ui-el bin)) 150)))
              (setq errs (append errs (drgnx-look-scenes--call sess (format "(drgnx-look-scene-%s)" name))))
              (when-let* ((k (plist-get plist :keys))) (drgnx-ui-act sess (list :keys k)) (sleep-for 1.5))
              (when-let* ((s (plist-get plist :type))) (drgnx-ui-act sess (list :type s)) (sleep-for 1.5))
              (drgnx-ui-wait sess 400 10)
              (drgnx-ui-screenshot sess png)
              (push png shots)
              (setq errs (append errs (drgnx-look-scenes--call
                                       sess (format "(drgnx-look-scene-facts %s)"
                                                    (drgnx-ui-el (expand-file-name (format "%s-%s-facts.eld" name tag)
                                                                                   out))))))
              (when-let* ((k (plist-get plist :then))) (drgnx-ui-act sess (list :keys k)) (sleep-for 1))
              (push (cons name errs) errors))))
      (when sess (ignore-errors (drgnx-ui-stop (plist-get sess :name))))
      (delete-directory tmp t))
    (let ((res (list :shots (vconcat (nreverse shots))
                     :errors (vconcat (delq nil (mapcar (lambda (e) (and (cdr e) (format "%s: %s" (car e)
                                                                                         (string-join (cdr e) "; "))))
                                                        (nreverse errors)))))))
      (with-temp-file (expand-file-name (format "scenes-%s.eld" tag) out) (pp res (current-buffer)))
      res)))

(provide 'drgnx-look-scenes)
;;; drgnx-look-scenes.el ends here
