;;; look-fonts-test.el --- the font roles: defaults, precedence, provenance -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure).  The role settings of ui/look (modules/ui/drgnx-look-fonts.el) are resolved through six
;; sources; the tests give each a value and read the winner.  Every test restores the faces it touched.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-type-faces)
(load (expand-file-name "modules/ui/drgnx-look-fonts" drgnx-dir) nil t)

(defconst drgnx-look-fonts-test--faces
  '(drgnx-ui-text drgnx-ui-heading drgnx-ui-caption drgnx-ui-title drgnx-code-small drgnx-agent-prose drgnx-terminal
                  fixed-pitch variable-pitch)
  "The faces the tests write to (not `default': its attributes belong to the frame).")

(defun drgnx-look-fonts-test--restore ()
  "Every face the tests touch as it was: no override, no theme or Customize entry, no direct attribute."
  (drgnx-look-fonts-off)
  (dolist (th '(drgnx-fonts-test))
    (when (custom-theme-p th) (disable-theme th))
    (put th 'theme-settings nil))
  (put 'default 'theme-face (assq-delete-all 'drgnx-fonts-test (copy-sequence (get 'default 'theme-face))))
  (put 'user 'theme-settings
       (cl-remove-if (lambda (s) (memq (cadr s) drgnx-look-fonts-test--faces)) (get 'user 'theme-settings)))
  (dolist (f drgnx-look-fonts-test--faces)
    (put f 'theme-face (cl-remove-if (lambda (e) (memq (car e) '(drgnx-fonts-test user))) (get f 'theme-face)))
    (put f 'customized-face nil)
    (put f 'saved-face nil)
    (put f 'face-override-spec nil)
    (set-face-attribute f nil :family 'unspecified :height 'unspecified :weight 'unspecified)
    (dolist (fr (frame-list)) (face-spec-recalc f fr))))

(defmacro drgnx-look-fonts-test--clean (&rest body)
  "BODY with the role state empty; the faces restored after."
  (declare (indent 0))
  `(unwind-protect (progn (drgnx-look-fonts-reset) ,@body)
     (drgnx-look-fonts-test--restore)))

(defun drgnx-look-fonts-test--file (dir name text)
  "A file NAME with TEXT in DIR."
  (let ((f (expand-file-name name dir)))
    (with-temp-file f (insert text))
    f))

(defun drgnx-look-fonts-test--keys (spec)
  "Every keyword that appears in SPEC, a face spec."
  (cl-remove-if-not #'keywordp (flatten-tree spec)))

(ert-deftest drgnx-look-fonts/defaults-match-the-design ()
  "Pattern D: each role's default resolves to the design's table, and each type face's spec says the same."
  (drgnx-look-fonts-test--clean
    (pcase-dolist (`(,role ,family ,height ,weight)
                   '((code "JetBrains Mono" 101 regular) (ui "Adwaita Sans" 0.963 regular)
                     (ui-heading "Adwaita Sans" 0.963 semibold) (ui-caption "Adwaita Sans" 0.889 regular)
                     (title "Adwaita Sans" 1.259 semibold) (code-small "JetBrains Mono" 0.889 regular)
                     (agent "Adwaita Sans" 0.963 regular) (terminal "JetBrains Mono" 1.0 regular)))
      (let ((r (drgnx-look-fonts-resolve role)))
        (should (equal family (plist-get r :family)))
        (should (equal height (plist-get r :height)))
        (should (eq weight (plist-get r :weight)))
        (should (eq 'default (plist-get r :source)))))
    (should (equal '(:family "JetBrains Mono" :fallback ("Adwaita Mono" "monospace") :size 1.0 :weight regular
                             :line-height 21 :ligatures nil)
                   drgnx-look-font-code))
    (should (equal '(:family "Adwaita Sans" :fallback ("Inter" "sans-serif") :size 0.963 :weight regular)
                   drgnx-look-font-ui))
    (should (equal '(:family ui :size 0.963 :weight semibold) drgnx-look-font-ui-heading))
    (should (equal '(:family ui :size 0.889) drgnx-look-font-ui-caption))
    (should (equal '(:family ui :size 1.259 :weight semibold) drgnx-look-font-title))
    (should (equal '(:family code :size 0.889 :line-height 19) drgnx-look-font-code-small))
    (should (equal '(:family ui) drgnx-look-font-agent))
    (should (equal '(:family code) drgnx-look-font-terminal))
    ;; the defface specs are the same defaults
    (pcase-dolist (`(,face ,role) '((drgnx-ui-text ui) (drgnx-ui-heading ui-heading) (drgnx-ui-caption ui-caption)
                                    (drgnx-ui-title title) (drgnx-code-small code-small) (drgnx-agent-prose agent)))
      (let ((attrs (face-spec-choose (face-default-spec face)))
            (r (drgnx-look-fonts-resolve role)))
        (should (equal (plist-get r :family) (plist-get attrs :family)))
        (should (equal (plist-get r :height) (plist-get attrs :height)))
        (should (eq (plist-get r :weight) (plist-get attrs :weight)))))))

(ert-deftest drgnx-look-fonts/px-to-height ()
  "Pattern D: 13.5 px is :height 101 (tenths of a point at 1 pt = 4/3 px); 13 px is the ratio 0.963 of the code size."
  (should (= 101 (drgnx-look-fonts-px-to-height 13.5)))
  (should (= 0.963 (drgnx-look-fonts-px-to-ratio 13)))
  (should (= 1.0 (drgnx-look-fonts-px-to-ratio 13.5)))
  (should (= 0.889 (drgnx-look-fonts-px-to-ratio 12))))

(ert-deftest drgnx-look-fonts/setting-beats-a-theme ()
  "Pattern D: a theme that names a family wins over the default; a setting wins over the theme and writes only the
attributes the user set, as the face's override spec."
  (drgnx-look-fonts-test--clean
    (deftheme drgnx-fonts-test "A theme that names a UI family.")
    (custom-theme-set-faces 'drgnx-fonts-test '(drgnx-ui-text ((t :family "Theme Sans"))))
    (provide-theme 'drgnx-fonts-test)
    (enable-theme 'drgnx-fonts-test)
    (let ((r (drgnx-look-fonts-resolve 'ui)))
      (should (equal "Theme Sans" (plist-get r :family)))
      (should (eq 'theme (plist-get r :source))))
    (let ((drgnx-look-font-ui '(:family "Setting Sans" :fallback ("Inter" "sans-serif") :size 0.963 :weight regular)))
      (drgnx-look-fonts-apply)
      (let ((r (drgnx-look-fonts-resolve 'ui)))
        (should (equal "Setting Sans" (plist-get r :family)))
        (should (eq 'setting (plist-get r :source))))
      (should (equal "Setting Sans" (face-attribute 'drgnx-ui-text :family nil)))
      ;; only the attribute that differs from the default is in the override
      (should (equal '((t :family "Setting Sans")) (get 'drgnx-ui-text 'face-override-spec))))
    ;; the setting back to its default: the override goes, the theme shows again
    (drgnx-look-fonts-apply)
    (should-not (get 'drgnx-ui-text 'face-override-spec))
    (should (equal "Theme Sans" (face-attribute 'drgnx-ui-text :family nil)))))

(ert-deftest drgnx-look-fonts/customize-and-lisp-win-and-say-so ()
  "Pattern D: a `custom-set-faces' entry and a `set-face-attribute' that the config did: drgnx leaves the face,
and the resolution names where it came from."
  (drgnx-look-fonts-test--clean
    (let* ((dir (make-temp-file "look-fonts" t))
           (config (drgnx-look-fonts-test--file
                    dir "config.el"
                    "(setq x 1)\n(set-face-attribute 'drgnx-ui-heading nil :family \"Lisp Sans\")\n"))
           (custom (drgnx-look-fonts-test--file
                    dir "custom.el"
                    "(custom-set-faces\n '(drgnx-ui-caption ((t :family \"Custom Sans\"))))\n")))
      (unwind-protect
          (progn
            (set-face-attribute 'drgnx-ui-heading nil :family "Lisp Sans")
            (custom-set-faces '(drgnx-ui-caption ((t :family "Custom Sans"))))
            (drgnx-look-fonts-snapshot config custom)
            (let ((drgnx-look-font-ui-heading '(:family "Setting Sans" :size 0.963 :weight semibold))
                  (drgnx-look-font-ui-caption '(:family "Setting Sans" :size 0.889)))
              (drgnx-look-fonts-apply)
              (let ((h (drgnx-look-fonts-resolve 'ui-heading)) (c (drgnx-look-fonts-resolve 'ui-caption)))
                (should (eq 'lisp (plist-get h :source)))
                (should (equal "Lisp Sans" (plist-get h :family)))
                (should (equal (concat "config.el:2") (plist-get h :where)))
                (should (eq 'customize (plist-get c :source)))
                (should (equal "Custom Sans" (plist-get c :family)))
                (should (equal "custom.el:2" (plist-get c :where))))
              ;; neither face got an override from the setting, and the user's attributes are still on
              (should-not (get 'drgnx-ui-heading 'face-override-spec))
              (should-not (get 'drgnx-ui-caption 'face-override-spec))
              (should (equal "Lisp Sans" (face-attribute 'drgnx-ui-heading :family nil)))
              (should (equal "Custom Sans" (face-attribute 'drgnx-ui-caption :family nil)))))
        (delete-directory dir t)))))

(defmacro drgnx-look-fonts-test--default-kept (&rest body)
  "BODY, then `default' as it was: its attributes for new frames, no theme of drgnx's, the module off."
  (declare (indent 0))
  `(let ((was (mapcar (lambda (a) (cons a (face-attribute 'default a t))) '(:family :height :weight))))
     (unwind-protect (progn ,@body)
       (dolist (th '(drgnx-dark drgnx-light drgnx-high-contrast))
         (when (custom-theme-enabled-p th) (disable-theme th)))
       (drgnx-look-fonts-off)
       (pcase-dolist (`(,a . ,v) was) (set-face-attribute 'default t a v))
       (dolist (fr (frame-list)) (face-spec-recalc 'default fr)))))

(ert-deftest drgnx-look-fonts/the-code-font-reaches-default-under-a-theme ()
  "Pattern D: drgnx Dark styles `default' (its colours), so Emacs skips `default's defface spec; the code role's
defaults reach it all the same, whether the theme comes before the faces are written or after, and so does the
desktop's font once the code role follows it."
  (drgnx-look-fonts-test--clean
    (drgnx-look-fonts-test--default-kept
      (load-theme 'drgnx-dark t)
      (drgnx-look-fonts-on)
      (should (equal "JetBrains Mono" (face-attribute 'default :family)))
      (load-theme 'drgnx-light t)
      (should (equal "JetBrains Mono" (face-attribute 'default :family)))
      (let ((drgnx-look-font-code 'follow-desktop))
        (drgnx-look-fonts-desktop-answer '(:ui ("Desk Sans" . 14) :code ("Desk Mono" . 12)))
        (should (equal "Desk Mono" (face-attribute 'default :family))))
      ;; a theme that names the family itself still wins over the default
      (deftheme drgnx-fonts-test "A theme that names the code family.")
      (custom-theme-set-faces 'drgnx-fonts-test '(default ((t :family "Theme Mono"))))
      (provide-theme 'drgnx-fonts-test)
      (enable-theme 'drgnx-fonts-test)
      (should (equal "Theme Mono" (face-attribute 'default :family)))
      (should (eq 'theme (plist-get (drgnx-look-fonts-resolve 'code) :source)))
      (disable-theme 'drgnx-fonts-test)
      (put 'default 'theme-face (assq-delete-all 'drgnx-fonts-test (copy-sequence (get 'default 'theme-face))))
      (drgnx-look-fonts-apply)
      (should (equal "JetBrains Mono" (face-attribute 'default :family))))))

(ert-deftest drgnx-look-fonts/your-lisp-default-font-stays ()
  "Pattern D: a `set-face-attribute' on `default' in config.el (after the module's setup noted `default', before
init ended) is your Lisp: it stays with no theme and under drgnx's own, and the resolution says so."
  (drgnx-look-fonts-test--clean
    (drgnx-look-fonts-test--default-kept
      (let* ((dir (make-temp-file "look-fonts" t))
             (config (drgnx-look-fonts-test--file
                      dir "config.el" "(set-face-attribute 'default nil :family \"Iosevka\")\n")))
        (unwind-protect
            (progn
              (drgnx-look-fonts--note-default)
              (set-face-attribute 'default nil :family "Iosevka")
              (drgnx-look-fonts-snapshot config)
              (drgnx-look-fonts-apply)
              (should (equal "Iosevka" (face-attribute 'default :family)))
              (let ((r (drgnx-look-fonts-resolve 'code)))
                (should (eq 'lisp (plist-get r :source)))
                (should (equal "config.el:1" (plist-get r :where))))
              (drgnx-look-fonts-on)
              (load-theme 'drgnx-dark t)
              (should (equal "Iosevka" (face-attribute 'default :family))))
          (delete-directory dir t))))))

(ert-deftest drgnx-look-fonts/no-font-attribute ()
  "Pattern D: no spec drgnx writes holds `:font': it is tied to one display."
  (drgnx-look-fonts-test--clean
    (let ((drgnx-look-font-code '(:family "Code A" :size 1.1 :weight bold))
          (drgnx-look-font-ui '(:family "UI A" :size 1.0 :weight bold))
          (drgnx-look-font-title '(:family "Title A" :size 1.4 :weight bold))
          (drgnx-look-font-terminal 'follow-desktop))
      (drgnx-look-fonts-desktop-answer '(:ui ("Desk Sans" . 14) :code ("Desk Mono" . 12)))
      (drgnx-look-fonts-apply)
      (dolist (f (append drgnx-look-fonts-test--faces '(default)))
        (dolist (spec (list (get f 'face-override-spec) (get f 'face-defface-spec)))
          (should-not (memq :font (drgnx-look-fonts-test--keys spec))))))))

(defun drgnx-look-fonts-test--chrome-heights (code)
  "Each chrome type face's `:height' is the absolute one its ratio gives on a `default' of CODE (tenths of a point):
what Emacs merged the old relative height to."
  (pcase-dolist (`(,face ,ratio) '((drgnx-ui-text 0.963) (drgnx-ui-heading 0.963) (drgnx-ui-caption 0.889)
                                   (drgnx-ui-title 1.259) (drgnx-code-small 0.889)))
    (should (equal (list face (merge-face-attribute :height ratio code)) (list face (face-attribute face :height))))))

(ert-deftest drgnx-look-fonts/the-chrome-faces-have-absolute-heights-that-follow-the-code-size ()
  "Pattern D: the chrome's type faces (UI text, heading, caption, title, small code) get an absolute `:height': the
one their ratio gave on `default' before, at the default size, after a live change of the code size and after a zoom
\(which sets `default' on the graphical frame); the agent's prose stays relative.  A float `:height' made Emacs copy
a font spec at every face run of the bars and the dock rows."
  (drgnx-look-fonts-test--clean
    (drgnx-look-fonts-test--default-kept
      (drgnx-look-fonts-apply)
      (drgnx-look-fonts-test--chrome-heights 101)
      (should (equal 0.963 (face-attribute 'drgnx-agent-prose :height)))
      (let ((drgnx-look-font-code '(:family "JetBrains Mono" :size 1.25)))   ; the debounced end of a live change
        (drgnx-look-fonts-apply)
        (should (= 127 (plist-get (drgnx-look-fonts-resolve 'code) :height)))
        (drgnx-look-fonts-test--chrome-heights 127))
      (drgnx-look-fonts-apply)
      (drgnx-look-fonts-test--chrome-heights 101)
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t)))
        (set-face-attribute 'default (selected-frame) :height 130)   ; what `global-text-scale-adjust' does
        (drgnx-look-fonts--zoomed)
        (drgnx-look-fonts-test--chrome-heights 130)))))

(ert-deftest drgnx-look-fonts/text-scale-reaches-the-chrome-faces ()
  "Pattern D: `text-scale-mode' remaps only `default'; in a scaled buffer each chrome face is remapped to the height
its ratio gives on the scaled `default', and the remap goes when the scale is back at 0 or the module is off."
  (drgnx-look-fonts-test--clean
    (drgnx-look-fonts-on)
    (with-temp-buffer
      (text-scale-set 2)
      (let ((want (merge-face-attribute :height 0.889 (merge-face-attribute :height (expt text-scale-mode-step 2) 101)))
            (spec (cadr (assq 'drgnx-ui-caption face-remapping-alist))))
        (should spec)
        (should (= want (merge-face-attribute :height (plist-get spec :height)
                                              (face-attribute 'drgnx-ui-caption :height)))))
      (text-scale-set 0)
      (should-not face-remapping-alist)
      (text-scale-set 1)
      (drgnx-look-fonts-off)
      (should-not (assq 'drgnx-ui-caption face-remapping-alist))
      (should (assq 'default face-remapping-alist)))))

(provide 'look-fonts-test)
;;; look-fonts-test.el ends here
