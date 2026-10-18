;;; early-init.el --- drgnx: early startup -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Used with `emacs --init-directory <checkout>/init' (and by the harness's config=drgnx).
;; Packages are not activated: drgnx manages them itself (M5).

;;; Code:
(setq gc-cons-threshold (* 512 1024 1024)       ; hardly any collection while starting (drgnx-gc.el sets the steady one)
      gc-cons-percentage 0.6)
(add-hook 'emacs-startup-hook                  ; and never left there, even if drgnx did not start
          (lambda () (when (> gc-cons-threshold (* 256 1024 1024)) (setq gc-cons-threshold (* 64 1024 1024) gc-cons-percentage 0.1))))
(setq load-prefer-newer t              ; a stale .elc (drgnx build) never shadows newer source
      package-enable-at-startup nil
      inhibit-startup-screen t
      frame-resize-pixelwise t)
(push '(tool-bar-lines . 0) default-frame-alist)
(unless (eq system-type 'darwin)                          ; (on a Mac the system menu bar is shared, never ours to hide)
  (push '(menu-bar-lines . 0) default-frame-alist))       ; no flash of a light menu bar or GTK scroll bar before the theme loads
(push '(vertical-scroll-bars . nil) default-frame-alist)  ; (ui/face puts them back when `drgnx-face-menu-bar' / `-scroll-bars' ask)
;; Emacs's own state (auto-save list, histories, …) in drgnx's state dir and native code in its cache dir —
;; never in the checkout's init/.  A harness session keeps both in its run directory (its prelude).
(unless (getenv "DRGNX_UI_RUN")
  (load (expand-file-name "../core/drgnx-paths" (file-name-directory (or load-file-name buffer-file-name))) nil t)
  (setq user-emacs-directory (expand-file-name "emacs/" (drgnx-state-dir))
        auto-save-list-file-prefix (expand-file-name "auto-save-list/.saves-" user-emacs-directory))
  (ignore-errors (make-directory user-emacs-directory t))   ; Emacs and packages expect it to exist
  (when (featurep 'native-compile)
    (startup-redirect-eln-cache (expand-file-name "eln-cache/" (drgnx-cache-dir))))
  ;; What Customize and `package-install' save goes to custom.el in your config dir — else they would write it into
  ;; the init file, the checkout's tracked init/init.el; made when missing (a save never asks); `drgnx-init' loads it
  ;; once the packages are active (a package's mode saved there then turns on).
  (setq custom-file (expand-file-name "custom.el" (drgnx-user-dir)))
  (unless (file-exists-p custom-file)
    (ignore-errors
      (make-directory (file-name-directory custom-file) t)
      (write-region ";;; custom.el --- what Customize saves (drgnx loads it at start) -*- lexical-binding: t -*-\n"
                    nil custom-file nil 'silent))))
(when (getenv "DRGNX_STARTUP_TRACE")      ; where startup time goes (docs/develop/perf.md)
  (load (expand-file-name "../core/drgnx-startup-trace" (file-name-directory (or load-file-name buffer-file-name))) nil t))

;;; early-init.el ends here
