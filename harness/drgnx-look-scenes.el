;;; drgnx-look-scenes.el --- The look's scenes, drawn in a session for a side-by-side with the mockups -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx ui look-scenes OUT' starts a session with the drgnx configuration at the mockups' 1440x900 logical pixels
;; (times $DRGNX_UI_SCALE), sets up the mockups' git project and files in it, and takes one screenshot per scene into OUT, named after the approved
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
    (work-space-dark)
    (start-page)
    (highlights-dark)
    (highlights-light)
    (highlights-hc)
    (explorer-focused-dark)
    (explorer-focused-light)
    (explorer-focused-hc))
  "The scenes in the order they are drawn: (NAME . PLIST).  NAME is the mockup's (docs/specs, the-look/NAME.png; the
start page, the highlights and the focused Explorer have none: they are judged against the components' spec and the tokens) and the session's `drgnx-look-scene-NAME' sets it
up.  :agent t starts the mock agent first; :keys and :type are typed after the setup and before the shot, :then after
it.")

(defun drgnx-look-scenes--size (scale)
  "The session's size in device pixels: the mockups' window, 1440x900 logical pixels, at SCALE."
  (format "%dx%d" (round (* 1440 scale)) (round (* 900 scale))))

(defun drgnx-look-scenes--call (sess form &optional timeout)
  "FORM (a string) in SESS; its errors, as a list of strings.  A call that fails (a timeout, a prompt) is an error
of the scene, not of the run: the other scenes are still drawn."
  (condition-case err (append (plist-get (drgnx-ui-call sess form (or timeout 60)) :errors) nil)
    (error (list (error-message-string err)))))

(defun drgnx-look-scenes-run (out)
  "Draw every scene into OUT (made if missing); return a plist :shots (paths) :errors (per scene)."
  (require 'drgnx-ui)
  (let* ((out (file-name-as-directory (expand-file-name out)))
         (scale (string-to-number (or (getenv "DRGNX_UI_SCALE") "1")))
         (scale (if (> scale 0) scale 1))
         (tag (format "s%s" (if (= scale (round scale)) (round scale) scale)))
         (elpa (getenv "DRGNX_LOOK_ELPA"))
         (bin (getenv "DRGNX_RATATOSKR_BIN"))
         (sess nil) shots errors)
    (make-directory out t)
    (unwind-protect
        (progn
          (setq sess (drgnx-ui-start "drgnx" (drgnx-look-scenes--size scale) 180))   ; a first boot compiles
          (drgnx-ui-call sess (format "(progn (load %s nil t) (drgnx-uitest--json (list :ok t)))"
                                      (drgnx-ui-el (expand-file-name "drgnx-look-scenes-session" drgnx-ui-harness-dir))))
          (let ((errs (drgnx-look-scenes--call sess (format "(drgnx-look-scene-setup %s)" (drgnx-ui-el elpa)) 120)))
            (when errs (drgnx-ui-screenshot sess (expand-file-name (format "setup-%s.png" tag) out)))   ; what stopped it
            (push (cons 'setup errs) errors))
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
                                       sess (format "(drgnx-look-scene-facts %s '%s)"
                                                    (drgnx-ui-el (expand-file-name (format "%s-%s-facts.eld" name tag)
                                                                                   out))
                                                    name))))
              (when-let* ((k (plist-get plist :then))) (drgnx-ui-act sess (list :keys k)) (sleep-for 1))
              (push (cons name errs) errors))))
      (when sess (ignore-errors (drgnx-ui-stop (plist-get sess :name)))))
    (let ((res (list :shots (vconcat (nreverse shots))
                     :errors (vconcat (delq nil (mapcar (lambda (e) (and (cdr e) (format "%s: %s" (car e)
                                                                                         (string-join (cdr e) "; "))))
                                                        (nreverse errors)))))))
      (with-temp-file (expand-file-name (format "scenes-%s.eld" tag) out) (pp res (current-buffer)))
      res)))

(provide 'drgnx-look-scenes)
;;; drgnx-look-scenes.el ends here
