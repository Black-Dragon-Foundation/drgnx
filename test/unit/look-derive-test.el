;;; look-derive-test.el --- ui/look: surfaces, text and agent colours derived from any theme -*- lexical-binding: t -*-
;; test-class: det
;; Pattern [D]: pure.  Themes are loaded and the derived specs read back through `drgnx-face-color' (no frame is
;; made, no process or timer involved); every theme the test enabled is forgotten again.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-paths)
(require 'drgnx-color)
(require 'drgnx-faces)
(load (expand-file-name "modules/ui/drgnx-look-derive" drgnx-dir) nil t)
(add-to-list 'custom-theme-load-path (expand-file-name "test/fixtures/themes" drgnx-dir))

;; themes made in the tests: declared here, given faces in each test
(deftheme drgnx-derive-test-a "A theme that sets a drgnx surface.")
(deftheme drgnx-derive-test-b "A theme that sets a drgnx surface and is never enabled.")
(deftheme drgnx-derive-test-dup "A dark theme whose keyword and builtin faces share a colour.")
(deftheme drgnx-derive-test-bare "A dark theme that gives only the default colours.")
(deftheme drgnx-derive-test-void "A theme whose default colours are unspecified, as a terminal frame's are.")

(defconst look-derive-test--made
  '(drgnx-derive-test-a drgnx-derive-test-b drgnx-derive-test-dup drgnx-derive-test-bare drgnx-derive-test-void))

(defun look-derive-test--forget (theme)
  "Take THEME's face settings off the faces, and disable it."
  (disable-theme theme)
  (dolist (s (get theme 'theme-settings))
    (when (eq (car s) 'theme-face)
      (put (cadr s) 'theme-face (assq-delete-all theme (copy-sequence (get (cadr s) 'theme-face))))))
  (put theme 'theme-settings nil))

(defun look-derive-test--enable (theme)
  ;; modus declares both its themes when one loads, so "declared" does not mean "loaded": settings do
  (if (get theme 'theme-settings) (enable-theme theme) (load-theme theme t)))

(defmacro look-derive-test--on (themes &rest body)
  "Enable THEMES (a list of names, the last one on top), turn derive on, run BODY, and put everything back."
  (declare (indent 1))
  `(unwind-protect
       (progn (mapc #'disable-theme custom-enabled-themes)
              (mapc #'look-derive-test--enable ,themes)
              (drgnx-look-derive-on)
              ,@body)
     (drgnx-look-derive-off)
     (mapc #'disable-theme custom-enabled-themes)
     (mapc #'look-derive-test--forget look-derive-test--made)))

(defun look-derive-test--bg (face) (drgnx-face-color face :background 'gui))
(defun look-derive-test--fg (face) (drgnx-face-color face :foreground 'gui))

(ert-deftest drgnx-look-derive/the-four-test-themes ()
  "Pattern D: the panel and the gap solve for the bar on modus-operandi, modus-vivendi, leuven and a Doom One stand-in."
  (pcase-dolist (`(,theme ,bar ,panel ,gap)
                 '((modus-operandi 1.20 "#f7f7f7" nil) (leuven 1.20 "#f9f9f9" nil)
                   (doom-one-fixture 1.10 "#2c3039" nil) (modus-vivendi 1.10 nil "#000000")))
    (look-derive-test--on (list theme)
      (let* ((p (look-derive-test--bg 'drgnx-surface-panel))
             (g (look-derive-test--bg 'drgnx-surface-gap))
             (ratio (drgnx-color-contrast p g)))
        (when panel (should (equal panel p)))
        (when gap (should (equal gap g)))
        (should (>= ratio bar))
        (should (< (- ratio bar) 0.02))
        (should (equal (look-derive-test--bg 'drgnx-surface-raised) (look-derive-test--bg 'drgnx-surface-overlay)))
        (should (equal (look-derive-test--bg 'drgnx-surface-raised) (look-derive-test--bg 'drgnx-selected-quiet)))))))

(ert-deftest drgnx-look-derive/subtle-and-muted-meet-4-5 ()
  "Pattern D: subtle and muted text reach 4.5:1 on the editor and every derived surface they sit on."
  (dolist (theme '(modus-operandi modus-vivendi leuven doom-one-fixture))
    (look-derive-test--on (list theme)
      (dolist (surface '(default drgnx-surface-panel drgnx-surface-raised))
        (dolist (text '(drgnx-text-muted drgnx-text-subtle))
          (should (look-derive-test--fg text))
          (should (>= (drgnx-color-contrast (look-derive-test--fg text) (look-derive-test--bg surface)) 4.5)))))))

(ert-deftest drgnx-look-derive/a-mentioned-face-is-left ()
  "Pattern D: a face an enabled theme or a Customize entry sets keeps its colour; a theme loaded with NO-ENABLE does not
count."
  (let ((panel (get 'drgnx-surface-panel 'face-defface-spec))
        (raised (get 'drgnx-surface-raised 'face-defface-spec))
        (gap (get 'drgnx-surface-gap 'face-defface-spec))
        (gap-entries (get 'drgnx-surface-gap 'theme-face))
        (user-settings (get 'user 'theme-settings)))      ; loading a theme applies the user theme again
    (unwind-protect
        (look-derive-test--on '(doom-one-fixture)
          (should-not (equal panel (get 'drgnx-surface-panel 'face-defface-spec)))
          ;; an enabled theme sets the panel
          (custom-theme-set-faces 'drgnx-derive-test-a '(drgnx-surface-panel ((t :background "#123456"))))
          (enable-theme 'drgnx-derive-test-a)
          (should (equal panel (get 'drgnx-surface-panel 'face-defface-spec)))
          (should (equal "#123456" (look-derive-test--bg 'drgnx-surface-panel)))
          (should-not (equal raised (get 'drgnx-surface-raised 'face-defface-spec)))
          ;; a Customize entry sets the gap
          (custom-push-theme 'theme-face 'drgnx-surface-gap 'user 'set '((t :background "#654321")))
          (drgnx-look-derive)
          (should (equal gap (get 'drgnx-surface-gap 'face-defface-spec)))
          ;; a theme that is not enabled sets the overlay: derived all the same
          (custom-theme-set-faces 'drgnx-derive-test-b '(drgnx-surface-overlay ((t :background "#abcdef"))))
          (drgnx-look-derive)
          (should (equal (look-derive-test--bg 'drgnx-surface-raised) (look-derive-test--bg 'drgnx-surface-overlay))))
      (put 'drgnx-surface-gap 'theme-face gap-entries)
      (put 'user 'theme-settings user-settings))))

(ert-deftest drgnx-look-derive/agent-colours-distinct-or-tokens ()
  "Pattern D: an agent colour is its font-lock face's foreground when it is 30 degrees of hue and 15 of delta E from the
others and from the cursor; the keyword and the builtin share a colour here, so the builtin's slot gets the token."
  (custom-theme-set-faces
   'drgnx-derive-test-dup
   '(default ((t :background "#1b1d23" :foreground "#d8dae0")))
   '(cursor ((t :background "#ffffff")))
   '(font-lock-function-name-face ((t :foreground "#4477ee")))
   '(font-lock-keyword-face ((t :foreground "#ee4444")))
   '(font-lock-string-face ((t :foreground "#2a8a2a")))
   '(font-lock-type-face ((t :foreground "#77dddd")))
   '(font-lock-constant-face ((t :foreground "#cc55cc")))
   '(font-lock-builtin-face ((t :foreground "#ee4444")))
   '(link ((t :foreground "#4477ee"))))
  (look-derive-test--on '(drgnx-derive-test-dup)
    (should (equal '("#4477ee" "#ee4444" "#2a8a2a" "#77dddd" "#cc55cc")
                   (mapcar (lambda (i) (look-derive-test--fg (intern (format "drgnx-agent-%d" i)))) '(1 2 3 4 5))))
    (should (equal (drgnx-look-token 'a6 'dark) (look-derive-test--fg 'drgnx-agent-6)))
    (should (equal "#4477ee" (look-derive-test--fg 'drgnx-accent)))))

(ert-deftest drgnx-look-derive/unspecified-colours-never-signal ()
  "Pattern D: a theme that leaves colours unspecified (a terminal frame's `unspecified-bg', no shadow, link, cursor or
syntax colours) makes derive say which faces it could not derive, never signal."
  ;; nothing to start from: the faces stay as they were
  (let ((was (mapcar (lambda (f) (get f 'face-defface-spec)) drgnx-look-derive--faces)))
    (custom-theme-set-faces 'drgnx-derive-test-void
                            '(default ((t :background "unspecified-bg" :foreground "unspecified-fg"))))
    (look-derive-test--on '(drgnx-derive-test-void)
      (should (equal was (mapcar (lambda (f) (get f 'face-defface-spec)) drgnx-look-derive--faces)))
      (should (assq 'drgnx-surface-panel drgnx-look-derive-gaps))))
  ;; only the default colours: the rest falls back to them
  (custom-theme-set-faces 'drgnx-derive-test-bare
                          '(default ((t :background "#1b1d23" :foreground "#d8dae0")))
                          '(shadow ((t :foreground "unspecified-fg")))
                          '(link ((t :foreground "unspecified-fg")))
                          '(cursor ((t :background "unspecified-bg"))))
  (look-derive-test--on '(drgnx-derive-test-bare)
    (dolist (face drgnx-look-derive--faces)
      (let ((v (or (look-derive-test--bg face) (look-derive-test--fg face)
                   (plist-get (drgnx-faces--clause-plist face 'gui) :box))))
        (should v)))
    (should (drgnx-color-rgb (look-derive-test--bg 'drgnx-surface-panel)))
    (should (>= (drgnx-color-contrast (look-derive-test--fg 'drgnx-text-muted)
                                      (look-derive-test--bg 'drgnx-surface-raised))
                4.5))
    ;; the accent falls back to the body text
    (should (equal "#d8dae0" (look-derive-test--fg 'drgnx-accent)))))

(ert-deftest drgnx-look-derive/accent-text-meets-4-5 ()
  "Pattern D: the portal's accent as text is lighter on dark and darker on light, and 4.5:1 on the editor, for GNOME's
nine accents."
  (dolist (accent '("#3584e4" "#2190a4" "#3a944a" "#c88800" "#ed5b00" "#e62d42" "#d56199" "#9141ac" "#6f8396"))
    (let ((rgb (drgnx-color-rgb accent)))
      (dolist (variant '(dark light))
        (let* ((text (drgnx-look-accent-text rgb variant))
               (editor (drgnx-look-token 'editor variant))
               (edge (if (eq variant 'dark) "#000000" "#ffffff")))
          (should (string-match-p "\\`#[0-9a-f]\\{6\\}\\'" text))
          (should (>= (drgnx-color-contrast text editor) 4.5))
          ;; further from the editor than the accent itself, never nearer
          (should (>= (drgnx-color-contrast text editor) (drgnx-color-contrast accent editor)))
          ;; and on the side the variant moves it to: lighter on dark is further from black, darker on light from white
          (should (>= (drgnx-color-contrast text edge) (drgnx-color-contrast accent edge))))))))

(provide 'look-derive-test)
;;; look-derive-test.el ends here
