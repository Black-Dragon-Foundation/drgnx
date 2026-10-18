;;; drgnx-terminal-eat.el --- Module tools/terminal-eat: a real terminal (eat) for New Terminal -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; New Terminal runs the user's shell in eat when this module has run (its package is synced); the
;; terminal's environment names this Emacs's server (`drgnx-terminal-environment').  Setup only sets
;; variables: eat itself loads when the first terminal starts.  See docs/guide/modules.md.

;;; Code:
(require 'drgnx-modules)
(defvar eat-eshell-fallback-if-stty-not-available)
(defvar eat-query-before-killing-running-terminal)
(defvar eat-kill-buffer-on-exit)
(defvar eat-term-terminfo-directory)
(declare-function drgnx-terminal-environment "drgnx-terminal")
(declare-function drgnx-terminal-shell "drgnx-terminal")
(declare-function eat-mode "eat")
(declare-function eat-exec "eat")

(defun drgnx-terminal-eat-start (dir)
  "A new eat terminal in DIR running the user's shell, shown by `pop-to-buffer' (the rules put it in the
panel); returns its buffer.  Its environment starts with `drgnx-terminal-environment'."
  (require 'eat)
  (let* ((default-directory (file-name-as-directory (expand-file-name dir)))
         (process-environment (append (drgnx-terminal-environment) process-environment))
         (buffer (generate-new-buffer "*eat*"))   ; *eat*, *eat*<2>, … (eat-make would reuse a running one)
         (ok nil))
    (unwind-protect
        (progn
          (with-current-buffer buffer (eat-mode))
          (eat-exec buffer "eat" (drgnx-terminal-shell) nil nil)
          (setq ok t))
      (unless ok (kill-buffer buffer)))
    (pop-to-buffer buffer)
    buffer))

(defun drgnx-terminal-eat--doctor ()
  "Problems that make eat ask or fail (eat is not loaded for this: its terminfo is found beside its library)."
  (let ((terminfo (if (boundp 'eat-term-terminfo-directory) eat-term-terminfo-directory
                    (when-let* ((lib (locate-library "eat"))) (expand-file-name "terminfo" (file-name-directory lib))))))
    (append (when (eq eat-eshell-fallback-if-stty-not-available 'ask)
              (list "eat would ask when stty is missing (eat-eshell-fallback-if-stty-not-available is ask)"))
            (unless (and terminfo (file-directory-p terminfo))
              (list "eat's terminfo is missing: drgnx sync")))))

(drgnx-module-define 'tools/terminal-eat
                     :doc "New Terminal is your shell in a real terminal (eat)."
                     :stage 'startup :requires '(tools/terminal) :packages '(eat)
                     :doctor #'drgnx-terminal-eat--doctor
                     :setup
                     (lambda ()
                       ;; never `ask' (a hidden prompt freezes the daemon); drgnx's quit asks once about running programs
                       (setq-default eat-eshell-fallback-if-stty-not-available nil
                                     eat-query-before-killing-running-terminal 'auto
                                     eat-kill-buffer-on-exit t)))

(provide 'drgnx-terminal-eat)
;;; drgnx-terminal-eat.el ends here
