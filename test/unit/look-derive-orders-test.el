;;; look-derive-orders-test.el --- derived colours in every order frames, themes and the module come and go -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: orders
;; Pattern A.  A daemon's first terminal frame, its first graphical frame, a theme turning on and off, and ui/look
;; turning off arrive in any order.  The oracle is independent of derive: while the module is on and the Doom One
;; stand-in is enabled, every derived surface equals the colours its graphical spec gives (never `unspecified-bg', which
;; its terminal clause holds); with the module off, or no theme on, nothing derived is left.  After every order the
;; derived faces' specs equal their defface specs.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-paths)
(require 'drgnx-color)
(require 'drgnx-faces)
(load (expand-file-name "modules/ui/drgnx-look-derive" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)
(add-to-list 'custom-theme-load-path (expand-file-name "test/fixtures/themes" drgnx-dir))

(defun look-derive-orders-test--specs ()
  (mapcar (lambda (f) (cons f (get f 'face-defface-spec))) drgnx-look-derive--faces))

(defun look-derive-orders-test--audit (on theme originals)
  "A failure string for the state ON (the module runs) and THEME (the stand-in is enabled), or nil."
  (cond
   ((not on)
    (unless (equal originals (look-derive-orders-test--specs))
      "the module is off, and a derived face is not its defface spec"))
   (theme
    (cl-loop for (face attr expect) in '((drgnx-surface-panel :background "#2c3039")
                                         (drgnx-selected-quiet :background nil)
                                         (drgnx-text-muted :foreground nil)
                                         (drgnx-agent-1 :foreground nil))
             thereis (cl-loop for kind in '(gui tty256)
                              for c = (drgnx-face-color face attr kind)
                              unless (and c (drgnx-color-rgb c) (or (null expect) (equal expect c)))
                              return (format "%s %s on %s is %S, not a colour from the graphical spec%s"
                                             face attr kind c (if expect (format " (%s)" expect) "")))))))

(ert-deftest drgnx-look-derive/daemon-orders-end-at-the-defface-specs ()
  "Pattern A: in every order of a terminal frame, a graphical frame, a theme on and off, and the module off, the
derived colours come from the graphical spec while the module and the theme are on, and every derived face is its
defface spec once the module is off."
  (let ((originals (look-derive-orders-test--specs)))
    (unwind-protect
        (drgnx-test-every-order
         :kinds '(tty-frame gui-frame enable-theme disable-theme module-off)
         :sources (list (cons 'frames '((tty-frame) (gui-frame)))
                        (cons 'theme '((enable-theme) (disable-theme)))
                        (cons 'module '((module-off))))
         :init (lambda ()
                 (drgnx-look-derive-off)
                 (mapc #'disable-theme custom-enabled-themes)
                 (unless (custom-theme-p 'doom-one-fixture) (load-theme 'doom-one-fixture t t))
                 (drgnx-look-derive-on)
                 (list t nil nil))
         :step (lambda (st ev)
                 (pcase-let ((`(,on ,theme ,fail) st))
                   (pcase (car ev)
                     ((or 'tty-frame 'gui-frame) (run-hook-with-args 'server-after-make-frame-hook))
                     ('enable-theme (enable-theme 'doom-one-fixture) (setq theme t))
                     ('disable-theme (disable-theme 'doom-one-fixture) (setq theme nil))
                     ('module-off (drgnx-look-derive-off) (setq on nil)))
                   (cons (list on theme (or fail (look-derive-orders-test--audit on theme originals))) nil)))
         :check (lambda (st _order)
                  (or (nth 2 st)
                      (progn (drgnx-look-derive-off)
                             (unless (equal originals (look-derive-orders-test--specs))
                               "after the module is off a derived face is not its defface spec")))))
      (drgnx-look-derive-off)
      (mapc #'disable-theme custom-enabled-themes))))

(provide 'look-derive-orders-test)
;;; look-derive-orders-test.el ends here
