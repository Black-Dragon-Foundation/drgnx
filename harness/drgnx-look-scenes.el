;;; drgnx-look-scenes.el --- The look's scenes, drawn in a session for a side-by-side with the mockups -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx ui look-scenes OUT' starts a session with the drgnx configuration at the mockups' 1440x900 logical pixels
;; (times $DRGNX_UI_SCALE), sets up the mockups' git project and files in it, and takes one screenshot per scene into OUT, named after the approved
;; mockup it is compared with (`drgnx-look-scenes'), plus the scene's facts (NAME-facts.eld).  One pixel rule is
;; asserted, no hub-fed row wider than its window nor cut where its full text fits (NAME-widths.eld); beyond it a look task is done only when its scene has been put beside its mockup at scales 1 and 2 and looked at
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
    (agent-panel :agent t)
    (agent-panel-long :agent t :mockup agent-panel)
    (palette :keys "C-S-p" :type "run te" :then "C-g")
    (palette-light :keys "C-S-p" :type "run te" :then "C-g")
    (palette-hc :keys "C-S-p" :type "run te" :then "C-g")
    (window-light)
    (window-hc)
    (title-row-dark)
    (title-row-light)
    (inbox-dropdown)
    (inbox-pinned)
    (magit)
    (org :mockup magit)
    (shell-heredoc)
    (work-flow :mockup hub-orchestration)
    (start-page)
    (start-page-light)
    (notebook-dark :mockup notebook)
    (notebook-light :mockup notebook)
    (notebook-views :mockup notebook-views)
    (notebook-views-light :mockup notebook-views)
    (notebook-views-running :mockup notebook-views)
    (highlights-dark)
    (highlights-light)
    (highlights-hc)
    (explorer-focused-dark)
    (explorer-focused-light)
    (explorer-focused-hc)
    (extensions-dark)
    (extensions-light)
    (extensions-hc)
    (search-preview :mockup search-view)
    (search-sheet :mockup search-view :then "<escape>")
    (search-ask :mockup search-view :then "<escape>")
    (search-handed :mockup search-view)
    (search-kinds :mockup search-view)
    (debugging)
    (debug-extras)
    (debug-extras-light)
    (debug-extras-views)
    (debug-extras-views-light)
    (send-run)
    (send-run-code :mockup send-run)
    (send-run-light :mockup send-run)
    (send-run-code-light :mockup send-run)
    (heap-graph :mockup debugging-extras)
    (heap-graph-light :mockup debugging-extras)
    ;; their hub seeds the map's graph, which no other scene's hub can share: a session of their own
    (scrollbars-editor :mockup minimap-folding)
    (scrollbars-panel :mockup minimap-folding)
    (scrollbars-terminal :mockup minimap-folding)
    (scrollbars-settings :mockup minimap-folding)
    (scrollbars-shortcuts :mockup minimap-folding)
    (work-space-dark :seed "map")
    (work-space-light :seed "map")
    (work-space-hc :seed "map"))
  "The scenes in the order they are drawn: (NAME . PLIST).  Each starts in the editor layout
\(`drgnx-look-scene-begin').  NAME is the mockup's (docs/specs, the-look/NAME.png; the
start page, the highlights, the focused Explorer and the Extensions list have none: they are judged against the
components' spec and the tokens) and the session's `drgnx-look-scene-NAME' sets it up.  :agent t starts the mock
agent first; :keys and :type are typed after the setup and before the shot, :then after it; :seed (default \"1\") is
what the session's hub seeds (`drgnx-look-scene-seed'): the scenes of another seed are drawn in a session of their
own.")

(defun drgnx-look-scenes--only ()
  "The scenes to draw: those whose name matches $DRGNX_LOOK_ONLY (a regexp), or all of them."
  (let ((re (getenv "DRGNX_LOOK_ONLY")))
    (if (and re (not (string-empty-p re)))
        (seq-filter (lambda (s) (string-match-p re (symbol-name (car s)))) drgnx-look-scenes)
      drgnx-look-scenes)))

(defun drgnx-look-scenes--size (scale)
  "The session's size in device pixels: the mockups' window, 1440x900 logical pixels, at SCALE."
  (format "%dx%d" (round (* 1440 scale)) (round (* 900 scale))))

(defun drgnx-look-scenes--call (sess form &optional timeout)
  "FORM (a string) in SESS; its errors, as a list of strings.  A call that fails (a timeout, a prompt) is an error
of the scene, not of the run: the other scenes are still drawn."
  (condition-case err (append (plist-get (drgnx-ui-call sess form (or timeout 60)) :errors) nil)
    (error (list (error-message-string err)))))

(defun drgnx-look-scenes--session (scenes seed out scale tag)
  "Draw SCENES ((NAME . PLIST) ...) in one session whose hub is seeded with SEED (`drgnx-look-scene--hub-seed'), into
OUT at SCALE (TAG: `s1', `s2'); return (SHOTS . ERRORS), each in drawing order, ERRORS ((NAME . STRINGS) ...)."
  (let ((elpa (getenv "DRGNX_LOOK_ELPA"))
        (bin (getenv "DRGNX_RATATOSKR_BIN"))
        (sess nil) shots errors)
    (unwind-protect
        (progn
          (setq sess (drgnx-ui-start "drgnx" (drgnx-look-scenes--size scale) 180))   ; a first boot compiles
          (drgnx-ui-call sess (format "(progn (load %s nil t) (drgnx-uitest--json (list :ok t)))"
                                      (drgnx-ui-el (expand-file-name "drgnx-look-scenes-session" drgnx-ui-harness-dir))))
          (when bin                       ; the session's own hub for the scenes that need one (the Search view's)
            (drgnx-look-scenes--call sess (format "(setenv \"DRGNX_RATATOSKR_BIN\" %s)" (drgnx-ui-el bin))))
          (drgnx-look-scenes--call sess (format "(setenv \"DRGNX_LOOK_ONLY\" %s)"   ; long transcript for agent-panel-long
                                                (drgnx-ui-el (or (getenv "DRGNX_LOOK_ONLY") ""))))
          (drgnx-look-scenes--call sess (format "(setq drgnx-look-scene-seed %s)" (drgnx-ui-el seed)))
          ;; "1": a scene's error carries its backtrace; the pack-built grammars the hub reads code with (inline values,
          ;; outlines, symbol rows); the one theme every scene draws in: the session starts with an environment of its own
          (dolist (var '("DRGNX_LOOK_BT" "DRGNX_PACK_LOCK" "DRGNX_PACK_GRAMMARS" "DRGNX_LOOK_THEME"))
            (when-let* ((v (getenv var)))
              (drgnx-look-scenes--call sess (format "(setenv %s %s)" (drgnx-ui-el var) (drgnx-ui-el v)))))
          (let ((errs (drgnx-look-scenes--call sess (format "(drgnx-look-scene-setup %s)" (drgnx-ui-el elpa)) 120)))
            (when errs                    ; what stopped it
              (drgnx-ui-screenshot sess (expand-file-name (format "setup-%s%s.png" (if (equal seed "1") "" (concat seed "-"))
                                                                  tag)
                                                          out)))
            (push (cons (if (equal seed "1") 'setup (intern (format "setup-%s" seed))) errs) errors))
          (pcase-dolist (`(,name . ,plist) scenes)
            (let ((errs (drgnx-look-scenes--call sess "(drgnx-look-scene-begin)"))   ; the editor layout again
                  (png (expand-file-name (format "%s-%s.png" name tag) out)))
              (when (plist-get plist :agent)
                (setq errs (append errs (drgnx-look-scenes--call
                                         sess (format "(drgnx-look-scene-agent %s)" (drgnx-ui-el bin)) 150))))
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
              ;; every scrollable surface has the scroll bar, drawn exactly when its content runs past it
              (setq errs (append errs (drgnx-look-scenes--call
                                       sess (format "(drgnx-look-scene-scrollbars %s)"
                                                    (drgnx-ui-el (expand-file-name (format "%s-%s-scrollbars.eld" name tag)
                                                                                   out)))
                                       60)))
              ;; no hub-fed row wider than its window, as drawn, narrower and wider (after the shot: it resizes)
              (setq errs (append errs (drgnx-look-scenes--call
                                       sess (format "(drgnx-look-scene-widths %s)"
                                                    (drgnx-ui-el (expand-file-name (format "%s-%s-widths.eld" name tag)
                                                                                   out)))
                                       180)))
              (when-let* ((k (plist-get plist :then))) (drgnx-ui-act sess (list :keys k)) (sleep-for 1))
              (push (cons name errs) errors))))
      (when sess (ignore-errors (drgnx-ui-stop (plist-get sess :name)))))
    (cons (nreverse shots) (nreverse errors))))

(defun drgnx-look-scenes-run (out)
  "Draw every scene into OUT (made if missing); return a plist :shots (paths) :errors (per scene).  The scenes whose
hub needs another seed (:seed) are drawn in a session of their own, after the others."
  (require 'drgnx-ui)
  (let* ((out (file-name-as-directory (expand-file-name out)))
         (scale (string-to-number (or (getenv "DRGNX_UI_SCALE") "1")))
         (scale (if (> scale 0) scale 1))
         (tag (format "s%s" (if (= scale (round scale)) (round scale) scale)))
         (groups nil) shots errors)
    (make-directory out t)
    (dolist (s (drgnx-look-scenes--only))
      (let* ((seed (or (plist-get (cdr s) :seed) "1")) (g (assoc seed groups)))
        (if g (setcdr g (append (cdr g) (list s))) (setq groups (append groups (list (list seed s)))))))
    (pcase-dolist (`(,seed . ,scenes) groups)
      (let ((r (drgnx-look-scenes--session scenes seed out scale tag)))
        (setq shots (append shots (car r)) errors (append errors (cdr r)))))
    (let ((res (list :theme (or (getenv "DRGNX_LOOK_THEME") "")
                     :shots (vconcat shots)
                     :errors (vconcat (delq nil (mapcar (lambda (e) (and (cdr e) (format "%s: %s" (car e)
                                                                                         (string-join (cdr e) "; "))))
                                                        errors))))))
      (with-temp-file (expand-file-name (format "scenes-%s.eld" tag) out) (pp res (current-buffer)))
      res)))

(provide 'drgnx-look-scenes)
;;; drgnx-look-scenes.el ends here
