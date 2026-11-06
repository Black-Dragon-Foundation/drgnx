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

(provide 'look-fonts-test)
;;; look-fonts-test.el ends here
