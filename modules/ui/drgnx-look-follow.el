;;; drgnx-look-follow.el --- ui/look: the theme follows the desktop and never replaces yours -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; With `drgnx-look-theme' at `auto' (the default) the theme is drgnx Dark, Light or High Contrast as the desktop's
;; portal says (Nidhogg's `nhwl-settings': `color-scheme', `contrast', `accent-color'), switching when an answer
;; comes and when it changes.  The portal is read asynchronously by `nhwl-settings', so the first frame never waits:
;; until it answers, the theme is Dark.  `auto' acts only while no theme but drgnx's three is on: one loaded any other
;; way (`load-theme' in config.el, a package, Color Theme) pauses it for the session, with one notice.  With
;; `drgnx-look-accent' `system' the accent and focus faces take the portal's accent colour as text for the variant.
;; Nothing here prompts or blocks: it runs in the portal's signal handler.  See docs/guide/look.md ("Following the
;; desktop").

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-setting)
(require 'drgnx-paths)
(require 'drgnx-color)
(unless (featurep 'drgnx-theme-gen)
  (load (expand-file-name "themes/drgnx-theme-gen" drgnx-dir) nil t))
(unless (featurep 'drgnx-look-derive)
  (load (expand-file-name "drgnx-look-derive" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(defvar drgnx-look-theme)
(defvar nhwl-settings-changed-functions)
(defvar ns-system-appearance)
(defvar ns-system-appearance-change-functions)
(declare-function drgnx-look--load "drgnx-look" (theme))
(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))
(declare-function drgnx-look-accent-text "drgnx-look-derive" (rgb variant))
(declare-function drgnx-look-variant "drgnx-theme-gen" (&optional frame))
(declare-function drgnx-settings-area-has-entry-p "drgnx-settings-area" (var))
(declare-function drgnx-settings-area-update "drgnx-settings-area" (vars fn &optional always))
(declare-function nhwl-settings-get "nhwl-settings" (key))
(declare-function nhwl-settings-answered-p "nhwl-settings" (key))

(drgnx-defsetting drgnx-look-accent 'system
  "Where the accent colour comes from: `system' (the desktop's accent colour, as text for the theme's variant) or
`theme' (the theme's own).  A change applies at once."
  :type '(choice (const :tag "The desktop's" system) (const :tag "The theme's" theme)) :group 'drgnx-look
  :scope 'global :agents 'never :apply #'drgnx-look-follow-apply
  :schema '(enum system theme))

(drgnx-defsetting drgnx-look-themes-notice nil
  "Whether the one-time notice that drgnx now has its own themes was shown.  drgnx sets it; there is no reason to."
  :type 'boolean :group 'drgnx-look
  :scope 'global :agents 'never
  :schema 'boolean)

(defconst drgnx-look-follow--own-themes '(drgnx-dark drgnx-light drgnx-high-contrast)
  "The themes the follower switches between.")

(defvar drgnx-look-follow--on nil "Non-nil while the follower runs.")

(defvar drgnx-look-follow--paused nil
  "Non-nil once a theme other than drgnx's was enabled by anything but the follower; for the session.")

(defvar drgnx-look-follow--loading nil
  "Non-nil while drgnx itself enables a theme (the follower, Color Theme): that is not a theme from elsewhere.")

(defvar drgnx-look-follow--accent-faces nil "The faces whose override spec the follower wrote.")

;;;; The portal

(defun drgnx-look-follow-pick (scheme contrast answered)
  "The theme for the desktop's SCHEME (1 dark, 2 light, 0 none), CONTRAST (1 more) and ANSWERED (the portal spoke).
Contrast 1 is High Contrast; scheme 1 is Dark; 0 or 2 is Light once the portal answered; no answer is Dark."
  (cond ((eql contrast 1) 'drgnx-high-contrast)
        ((eql scheme 1) 'drgnx-dark)
        ((and answered (memq scheme '(0 2))) 'drgnx-light)
        (t 'drgnx-dark)))

(defun drgnx-look-follow--read ()
  "What the desktop says now: a plist (:scheme N :contrast N :accent (R G B) :answered BOOL).  Never blocks: the
store holds what the asynchronous reads brought, and the defaults until they come; `nhwl-settings-answered-p' says
whether the colour scheme was answered (0 is both GNOME's Light and the default).  nil when there is no store.
`contrast' is read when the store knows the key (a Nidhogg without it answers 0)."
  (cond ((and (eq system-type 'darwin) (boundp 'ns-system-appearance))
         (list :scheme (if (eq ns-system-appearance 'dark) 1 2) :contrast 0 :accent nil :answered t))
        ((fboundp 'nhwl-settings-get)
         (list :scheme (nhwl-settings-get 'color-scheme)
               :contrast (condition-case nil (nhwl-settings-get 'contrast) (error 0))
               :accent (nhwl-settings-get 'accent-color)
               :answered (and (fboundp 'nhwl-settings-answered-p) (nhwl-settings-answered-p 'color-scheme) t)))))

;;;; The theme

(defun drgnx-look-follow--themes ()
  "The enabled themes, without the pseudo-theme Customize saves into."
  (remq 'user custom-enabled-themes))

(defun drgnx-look-follow--pause (theme)
  "Stop following for this session, because THEME was enabled by something else: one notice, the accent given back."
  (unless drgnx-look-follow--paused
    (setq drgnx-look-follow--paused t)
    (drgnx-look-follow--clear-accent)
    (drgnx-notify 'config 'info (format "Theme follows the desktop: paused while %s is on" theme)
                  :id 'look-follow-paused)))

(defun drgnx-look-follow--foreign-theme ()
  "An enabled theme that is not drgnx's, or nil."
  (seq-find (lambda (th) (not (memq th drgnx-look-follow--own-themes))) (drgnx-look-follow--themes)))

(defun drgnx-look-follow--apply-theme ()
  "Make the picked theme the only one, when it is not already, unless paused."
  (unless drgnx-look-follow--paused
    (if-let* ((foreign (drgnx-look-follow--foreign-theme)))
        (drgnx-look-follow--pause foreign)
      (when-let* ((desktop (drgnx-look-follow--read)))
        (let ((want (drgnx-look-follow-pick (plist-get desktop :scheme) (plist-get desktop :contrast)
                                            (plist-get desktop :answered))))
          (unless (equal (drgnx-look-follow--themes) (list want))
            (condition-case e (let ((drgnx-look-follow--loading t)) (drgnx-look--load want))
              (error (drgnx-notify 'config 'warn (format "the colour theme %s does not load (%s)" want
                                                         (error-message-string e))
                                   :id 'look-theme)))))))))

;;;; The accent

(defun drgnx-look-follow--set-override (face spec)
  "FACE's override spec, only when it changes."
  (unless (equal spec (get face 'face-override-spec))
    (face-spec-set face spec)))

(defun drgnx-look-follow--clear-accent ()
  "Give the accent and focus faces back to the theme."
  (dolist (face drgnx-look-follow--accent-faces) (drgnx-look-follow--set-override face nil))
  (setq drgnx-look-follow--accent-faces nil))

(defun drgnx-look-follow--apply-accent ()
  "The accent and focus faces from the portal's accent, as text for the variant; the theme's own otherwise."
  (let ((rgb (and (eq drgnx-look-accent 'system) (not drgnx-look-follow--paused)
                  (plist-get (drgnx-look-follow--read) :accent))))
    (if (not rgb)
        (drgnx-look-follow--clear-accent)
      (let ((text (drgnx-look-accent-text rgb (drgnx-look-variant))))
        (drgnx-look-follow--set-override 'drgnx-accent `((t :foreground ,text)))
        (drgnx-look-follow--set-override 'drgnx-focus `((t :box (:line-width (-2 . -2) :color ,text))))
        (setq drgnx-look-follow--accent-faces '(drgnx-accent drgnx-focus))))))

;;;; Migration

(defun drgnx-look-follow--has-entry-p ()
  "Non-nil when settings.el names a theme (an explicit symbol or nil).  Unreadable counts as yes: no notice."
  (condition-case nil (and (drgnx-settings-area-has-entry-p 'drgnx-look-theme) t) (error t)))

(defun drgnx-look-follow--notice-seen-p ()
  drgnx-look-themes-notice)

(defun drgnx-look-follow--remember-notice ()
  "Write that the notice was shown (settings.el); this session remembers it whatever the file says."
  (setq-default drgnx-look-themes-notice t)
  (condition-case nil
      (drgnx-settings-area-update '(drgnx-look-themes-notice) (lambda (_) '((drgnx-look-themes-notice . t))))
    (error nil)))

(defun drgnx-look-follow--migrate ()
  "A settings.el without a theme entry got `auto': say so once."
  (unless (or (drgnx-look-follow--has-entry-p) (drgnx-look-follow--notice-seen-p))
    (drgnx-notify 'config 'info "drgnx now has its own themes; Color Theme picks another"
                  :id 'look-themes :command 'preferences-theme)
    (drgnx-look-follow--remember-notice)))

;;;; Running

(defun drgnx-look-follow-apply ()
  "Follow the desktop now, while the follower runs and `drgnx-look-theme' is `auto'."
  (when drgnx-look-follow--on
    (if (eq drgnx-look-theme 'auto)
        (progn (drgnx-look-follow--apply-theme) (drgnx-look-follow--apply-accent))
      (drgnx-look-follow--clear-accent))))

(defun drgnx-look-follow--on-theme (theme &rest _)
  "`enable-theme-functions': a theme from elsewhere pauses `auto'; the accent follows the variant."
  (when (and (eq drgnx-look-theme 'auto) (not drgnx-look-follow--loading) (not drgnx-look-follow--paused)
             (not (memq theme drgnx-look-follow--own-themes)) (not (eq theme 'user)))
    (drgnx-look-follow--pause theme))
  (when (eq drgnx-look-theme 'auto) (drgnx-look-follow--apply-accent)))

(defun drgnx-look-follow--on-setting (_key _value)
  "`nhwl-settings-changed-functions': the portal said something."
  (drgnx-look-follow-apply))

(defun drgnx-look-follow--on-ns (&rest _)
  "`ns-system-appearance-change-functions': macOS changed its appearance."
  (drgnx-look-follow-apply))

(defun drgnx-look-follow-on ()
  "Follow the desktop: listen to the portal and to themes, say the migration notice, and switch now."
  (setq drgnx-look-follow--on t)
  (add-hook 'enable-theme-functions #'drgnx-look-follow--on-theme)
  (add-hook 'nhwl-settings-changed-functions #'drgnx-look-follow--on-setting)
  (add-hook 'ns-system-appearance-change-functions #'drgnx-look-follow--on-ns)
  (when (eq drgnx-look-theme 'auto) (drgnx-look-follow--migrate))
  (drgnx-look-follow-apply))

(defun drgnx-look-follow-off ()
  "Undo `drgnx-look-follow-on': the listeners off, the accent back to the theme's.  The theme stays."
  (setq drgnx-look-follow--on nil)
  (remove-hook 'enable-theme-functions #'drgnx-look-follow--on-theme)
  (remove-hook 'nhwl-settings-changed-functions #'drgnx-look-follow--on-setting)
  (remove-hook 'ns-system-appearance-change-functions #'drgnx-look-follow--on-ns)
  (drgnx-look-follow--clear-accent))

(provide 'drgnx-look-follow)
;;; drgnx-look-follow.el ends here
