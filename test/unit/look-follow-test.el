;;; look-follow-test.el --- ui/look: the theme follows the desktop -*- lexical-binding: t -*-
;; test-class: det
;; Pattern [D]: pure.  The portal is a fake: `drgnx-look-follow--read' answers from a variable, the hook
;; `nhwl-settings-changed-functions' is run by hand, and the loader and the notices are recorded.  No bus, no timer.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-paths)
(require 'drgnx-color)
(require 'drgnx-faces)
(load (expand-file-name "modules/ui/drgnx-look-derive" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-look-follow" drgnx-dir) nil t)

(defvar drgnx-look-theme)
(defvar nhwl-settings-changed-functions)

(defvar look-follow-test--portal nil "The fake portal: a plist (:scheme N :contrast N :accent RGB :answered BOOL).")
(defvar look-follow-test--notices nil "The notice ids posted, newest first.")
(defvar look-follow-test--entry t "Whether the fake settings.el has a theme entry.")
(defvar look-follow-test--seen nil "Whether the fake settings.el says the migration notice was shown.")

(defmacro look-follow-test--with (portal &rest body)
  "Run BODY with a fake PORTAL, themes recorded and put back, and the follower off again afterwards."
  (declare (indent 1))
  `(let ((look-follow-test--portal ,portal) (look-follow-test--notices nil)
         (drgnx-look-theme 'auto) (drgnx-look-accent 'system)
         (drgnx-look-follow--paused nil) (nhwl-settings-changed-functions nil))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-look-follow--read) (lambda () look-follow-test--portal))
                   ((symbol-function 'drgnx-look--load)
                    (lambda (theme) (mapc #'disable-theme custom-enabled-themes) (load-theme theme t)))
                   ((symbol-function 'drgnx-look-follow--has-entry-p) (lambda () look-follow-test--entry))
                   ((symbol-function 'drgnx-look-follow--notice-seen-p) (lambda () look-follow-test--seen))
                   ((symbol-function 'drgnx-look-follow--remember-notice) (lambda () (setq look-follow-test--seen t)))
                   ((symbol-function 'drgnx-notify)
                    (lambda (_source _severity _text &rest args) (push (plist-get args :id) look-follow-test--notices))))
           (mapc #'disable-theme custom-enabled-themes)
           ,@body)
       (drgnx-look-follow-off)
       (mapc #'disable-theme custom-enabled-themes))))

(ert-deftest drgnx-look-follow/pick-table ()
  "Pattern D: contrast 1 is High Contrast; scheme 1 is Dark; 0 and 2 are Light once the portal answered; no answer
is Dark."
  (pcase-dolist (`(,scheme ,contrast ,answered ,want)
                 '((1 0 t drgnx-dark) (0 0 t drgnx-light) (2 0 t drgnx-light)
                   (1 1 t drgnx-high-contrast) (2 1 t drgnx-high-contrast) (0 1 t drgnx-high-contrast)
                   (0 0 nil drgnx-dark) (2 0 nil drgnx-dark) (nil nil nil drgnx-dark)))
    (should (eq want (drgnx-look-follow-pick scheme contrast answered)))))

(ert-deftest drgnx-look-follow/no-answer-means-dark ()
  "Pattern D: a portal that never answers (the fake says so) leaves drgnx Dark on, and a late answer switches it."
  (look-follow-test--with '(:scheme 0 :contrast 0 :accent nil :answered nil)
    (drgnx-look-follow-on)
    (should (equal custom-enabled-themes '(drgnx-dark)))
    (setq look-follow-test--portal '(:scheme 2 :contrast 0 :accent nil :answered t))
    (run-hook-with-args 'nhwl-settings-changed-functions 'color-scheme 2)
    (should (equal custom-enabled-themes '(drgnx-light)))))

(ert-deftest drgnx-look-follow/an-answer-of-none-reaches-the-follower ()
  "Pattern D: the portal's first answer 0 (Light on GNOME) equals the store's default; Nidhogg runs the hook for a
first answer all the same, and the follower switches to Light on it."
  (look-follow-test--with '(:scheme 0 :contrast 0 :accent nil :answered nil)
    (drgnx-look-follow-on)
    (should (equal custom-enabled-themes '(drgnx-dark)))
    (setq look-follow-test--portal '(:scheme 0 :contrast 0 :accent nil :answered t))
    (run-hook-with-args 'nhwl-settings-changed-functions 'color-scheme 0)
    (should (equal custom-enabled-themes '(drgnx-light)))))

(ert-deftest drgnx-look-follow/the-desktop-is-read-through-the-public-store ()
  "Pattern D: what the follower reads comes from `nhwl-settings-get' and `nhwl-settings-answered-p' (the store's own
variables are Nidhogg's business), and it adds nothing to the store's functions."
  (let ((values '((color-scheme . 0) (contrast . 0) (accent-color . (0.2 0.4 0.9)))) (answered nil))
    (cl-letf (((symbol-function 'nhwl-settings-get) (lambda (key) (alist-get key values)))
              ((symbol-function 'nhwl-settings-answered-p) (lambda (key) (memq key answered))))
      (should (equal '(:scheme 0 :contrast 0 :accent (0.2 0.4 0.9) :answered nil) (drgnx-look-follow--read)))
      (setq answered '(color-scheme))
      (should (equal '(:scheme 0 :contrast 0 :accent (0.2 0.4 0.9) :answered t) (drgnx-look-follow--read)))))
  (unwind-protect
      (let ((drgnx-look-theme nil) (nhwl-settings-changed-functions nil))
        (drgnx-look-follow-on)
        (should-not (and (fboundp 'nhwl-settings--set) (advice--p (advice--symbol-function 'nhwl-settings--set)))))
    (drgnx-look-follow-off)))

(ert-deftest drgnx-look-follow/an-explicit-theme-is-left-alone ()
  "Pattern D: with a theme symbol, or nil, as `drgnx-look-theme', a portal change loads nothing."
  (dolist (choice '(nil doom-one-fixture))
    (look-follow-test--with '(:scheme 1 :contrast 0 :accent nil :answered t)
      (setq drgnx-look-theme choice)
      (drgnx-look-follow-on)
      (setq look-follow-test--portal '(:scheme 2 :contrast 0 :accent nil :answered t))
      (run-hook-with-args 'nhwl-settings-changed-functions 'color-scheme 2)
      (should-not custom-enabled-themes))))

(ert-deftest drgnx-look-follow/a-theme-from-elsewhere-pauses-with-one-notice ()
  "Pattern D: a theme of someone else's pauses the follower, with one notice, however often the portal speaks."
  (look-follow-test--with '(:scheme 1 :contrast 0 :accent nil :answered t)
    (drgnx-look-follow-on)
    (load-theme 'wombat t)
    (should drgnx-look-follow--paused)
    (setq look-follow-test--portal '(:scheme 2 :contrast 0 :accent nil :answered t))
    (run-hook-with-args 'nhwl-settings-changed-functions 'color-scheme 2)
    (run-hook-with-args 'nhwl-settings-changed-functions 'color-scheme 1)
    (should (memq 'wombat custom-enabled-themes))
    (should-not (memq 'drgnx-light custom-enabled-themes))
    (should (equal look-follow-test--notices '(look-follow-paused)))))

(ert-deftest drgnx-look-follow/migration-notice-once ()
  "Pattern D: a settings.el without a theme entry gets `auto' and one notice over two starts; an explicit entry,
including nil, gets none and loads no theme of its own."
  (let ((look-follow-test--entry nil) (look-follow-test--seen nil))
    (look-follow-test--with '(:scheme 1 :contrast 0 :accent nil :answered t)
      (drgnx-look-follow-on) (drgnx-look-follow-off)
      (drgnx-look-follow-on)
      (should (equal look-follow-test--notices '(look-themes)))
      (should look-follow-test--seen)))
  (let ((look-follow-test--entry t) (look-follow-test--seen nil))
    (look-follow-test--with '(:scheme 1 :contrast 0 :accent nil :answered t)
      (setq drgnx-look-theme nil)
      (drgnx-look-follow-on)
      (should-not look-follow-test--notices)
      (should-not custom-enabled-themes))))

(ert-deftest drgnx-look-follow/accent-from-the-portal ()
  "Pattern D: with `system' the accent and focus faces take the portal's accent as text for the variant, solved to
4.5:1 on the editor; `theme' and no portal accent take it off again."
  (look-follow-test--with '(:scheme 1 :contrast 0 :accent (0.2 0.4 0.9) :answered t)
    (drgnx-look-follow-on)
    (let ((want (drgnx-look-accent-text '(0.2 0.4 0.9) 'dark)))
      (should (equal want (plist-get (cdr (assq t (get 'drgnx-accent 'face-override-spec))) :foreground)))
      (should (equal want (plist-get (plist-get (cdr (assq t (get 'drgnx-focus 'face-override-spec))) :box) :color)))
      (should (>= (drgnx-color-contrast want (drgnx-look-token 'editor 'dark)) 4.5)))
    (setq drgnx-look-accent 'theme)
    (drgnx-look-follow-apply)
    (should-not (get 'drgnx-accent 'face-override-spec))
    (setq drgnx-look-accent 'system
          look-follow-test--portal '(:scheme 2 :contrast 0 :accent (0.2 0.4 0.9) :answered t))
    (run-hook-with-args 'nhwl-settings-changed-functions 'color-scheme 2)
    (should (equal (drgnx-look-accent-text '(0.2 0.4 0.9) 'light)
                   (plist-get (cdr (assq t (get 'drgnx-accent 'face-override-spec))) :foreground)))
    (drgnx-look-follow-off)
    (should-not (get 'drgnx-accent 'face-override-spec))
    (should-not (get 'drgnx-focus 'face-override-spec))))

(provide 'look-follow-test)
;;; look-follow-test.el ends here
