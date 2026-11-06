;;; look-follow-orders-test.el --- the follower in every order of the desktop's answers and the user's theme -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: orders
;; Pattern A.  A theme loaded in config.el, ui/look's setup, the portal's colour scheme, contrast and accent, and a
;; setting change arrive in any order.  The oracle is independent of the follower's code: in every order that
;; includes the user's theme, that theme is still enabled and the follower is paused; in every order without it, the
;; enabled theme is `drgnx-look-follow-pick's answer for the last values the portal gave.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-paths)
(require 'drgnx-color)
(require 'drgnx-faces)
(load (expand-file-name "modules/ui/drgnx-look-derive" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-look-follow" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)
(add-to-list 'custom-theme-load-path (expand-file-name "test/fixtures/themes" drgnx-dir))

(defvar drgnx-look-theme)
(defvar nhwl-settings-changed-functions)

(defvar look-follow-orders-test--portal nil "The fake portal's values, a plist.")

(defun look-follow-orders-test--init ()
  (drgnx-look-follow-off)
  (mapc #'disable-theme custom-enabled-themes)
  (setq drgnx-look-follow--paused nil
        look-follow-orders-test--portal '(:scheme 0 :contrast 0 :accent nil :answered nil))
  nil)

(defun look-follow-orders-test--step (_st ev)
  (pcase ev
    (`(config-load-theme) (load-theme 'doom-one-fixture t))
    (`(config-load-own-theme) (load-theme 'drgnx-light t))
    (`(module-setup) (drgnx-look-follow-on))
    (`(setting-change) (drgnx-look-follow-apply))
    (`(,(and kind (or 'portal-color-scheme 'portal-contrast 'portal-accent)) ,value)
     (let ((key (pcase kind ('portal-color-scheme :scheme) ('portal-contrast :contrast) (_ :accent))))
       (setq look-follow-orders-test--portal
             (plist-put (plist-put (copy-sequence look-follow-orders-test--portal) key value) :answered t))
       (run-hook-with-args 'nhwl-settings-changed-functions
                           (pcase kind ('portal-color-scheme 'color-scheme) ('portal-contrast 'contrast) (_ 'accent-color))
                           value))))
  (cons nil nil))

(defun look-follow-orders-test--check-chosen (_st _order)
  (cond ((not (memq 'doom-one-fixture custom-enabled-themes)) "the user's theme was replaced")
        ((not drgnx-look-follow--paused) "the follower is not paused")))

(defun look-follow-orders-test--check-pick (_st _order)
  (let* ((p look-follow-orders-test--portal)
         (want (drgnx-look-follow-pick (plist-get p :scheme) (plist-get p :contrast) (plist-get p :answered))))
    (unless (equal custom-enabled-themes (list want))
      (format "themes are %S, wanted (%s)" custom-enabled-themes want))))

(defmacro look-follow-orders-test--fake (&rest body)
  "BODY with the fake portal, the loader and the notices; the follower and the themes put back after."
  `(let ((drgnx-look-theme 'auto) (drgnx-look-accent 'system) (drgnx-look-follow--paused nil)
         (nhwl-settings-changed-functions nil))
     (cl-letf (((symbol-function 'drgnx-look-follow--read) (lambda () look-follow-orders-test--portal))
               ((symbol-function 'drgnx-look--load)
                (lambda (theme) (mapc #'disable-theme custom-enabled-themes) (load-theme theme t)))
               ((symbol-function 'drgnx-notify) #'ignore)
               ((symbol-function 'drgnx-look-follow--has-entry-p) (lambda () t)))
       (unwind-protect (progn ,@body)
         (drgnx-look-follow-off)
         (mapc #'disable-theme custom-enabled-themes)))))

(ert-deftest drgnx-look-follow/never-replaces-a-chosen-theme ()
  "Pattern A: in every order that includes the user's theme, it stays enabled and the follower is paused."
  (look-follow-orders-test--fake
   (drgnx-test-every-order
    :kinds '(config-load-theme module-setup portal-color-scheme portal-contrast portal-accent setting-change)
    :sources (list (cons 'setup '((module-setup)))
                   (cons 'scheme '((portal-color-scheme 1) (portal-color-scheme 2)))
                   (cons 'contrast '((portal-contrast 1) (portal-contrast 0)))
                   (cons 'accent '((portal-accent (0.2 0.4 0.9))))
                   (cons 'setting '((setting-change)))
                   (cons 'config '((config-load-theme))))
    :init #'look-follow-orders-test--init :step #'look-follow-orders-test--step
    :check #'look-follow-orders-test--check-chosen)))

(defun look-follow-orders-test--check-chosen-own (_st _order)
  (cond ((not (memq 'drgnx-light custom-enabled-themes)) "the user's drgnx-light was replaced")
        ((not drgnx-look-follow--paused) "the follower is not paused")))

(ert-deftest drgnx-look-follow/never-replaces-a-chosen-drgnx-theme ()
  "Pattern A: one of drgnx's own themes loaded in config.el is chosen too: in every order it stays enabled and the
follower is paused, whatever the desktop says (here Dark, against the user's Light)."
  (look-follow-orders-test--fake
   (drgnx-test-every-order
    :kinds '(config-load-own-theme module-setup portal-color-scheme portal-contrast setting-change)
    :sources (list (cons 'setup '((module-setup)))
                   (cons 'scheme '((portal-color-scheme 1)))
                   (cons 'contrast '((portal-contrast 1) (portal-contrast 0)))
                   (cons 'setting '((setting-change)))
                   (cons 'config '((config-load-own-theme))))
    :init #'look-follow-orders-test--init :step #'look-follow-orders-test--step
    :check #'look-follow-orders-test--check-chosen-own)))

(ert-deftest drgnx-look-follow/without-a-chosen-theme-the-pick-wins ()
  "Pattern A: in every order without the user's theme, the enabled theme is the pick for the portal's last values."
  (look-follow-orders-test--fake
   (drgnx-test-every-order
    :kinds '(module-setup portal-color-scheme portal-contrast portal-accent setting-change)
    :sources (list (cons 'setup '((module-setup)))
                   (cons 'scheme '((portal-color-scheme 1) (portal-color-scheme 2)))
                   (cons 'contrast '((portal-contrast 1) (portal-contrast 0)))
                   (cons 'accent '((portal-accent (0.2 0.4 0.9))))
                   (cons 'setting '((setting-change))))
    :init #'look-follow-orders-test--init :step #'look-follow-orders-test--step
    :check #'look-follow-orders-test--check-pick)))

(provide 'look-follow-orders-test)
;;; look-follow-orders-test.el ends here
