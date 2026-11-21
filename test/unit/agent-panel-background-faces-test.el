;;; agent-panel-background-faces-test.el --- the faces of the background list's card and buttons: boxes with their own colour -*- lexical-binding: t -*-
;; test-class: det
;; Pattern [D]: pure; themes are loaded and read back as face specs.
;; A `:box' with no `:color' takes the foreground of the run it is on, so two runs of different colours (muted text,
;; the accent, the default) end the box there and draw an edge: the card's ring, the buttons' and the key hints' boxes
;; and every face the list's rows put over them must name their ring's colour.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx)
(require 'drgnx-faces)
(require 'drgnx-ui-kit)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-dir) nil t)
(dolist (theme '(drgnx-dark drgnx-light drgnx-high-contrast)) (load-theme theme t t))

(defconst drgnx-bgfaces-test--others
  '(drgnx-agent-panel-subtle drgnx-agent-panel-code drgnx-agent-panel-output drgnx-agent-panel-title
                             drgnx-agent-panel-chip drgnx-agent-panel-tag drgnx-agent-panel-tag-on drgnx-agent-panel-md-link
                             drgnx-selected drgnx-accent drgnx-focus default)
  "The faces besides the kit's that the list's rows run over its card.")

(defun drgnx-bgfaces-test--faces ()
  (append (seq-filter (lambda (f) (string-match-p "\\`drgnx-kit-\\(card\\|button\\|key-hint\\|keyhint\\|chip\\)" (symbol-name f)))
                      (face-list))
          drgnx-bgfaces-test--others))

(defun drgnx-bgfaces-test--bad (theme)
  "The faces of the list under THEME whose `:box' names no colour of its own."
  (mapc #'disable-theme custom-enabled-themes)
  (load-theme theme t)
  (unwind-protect
      (let (bad)
        (dolist (f (drgnx-bgfaces-test--faces))
          (when (facep f)
            (let ((box (face-attribute f :box nil t)))
              (when (and box (not (eq box 'unspecified)) (not (equal box '(:line-width 0)))
                         (not (and (consp box) (stringp (plist-get box :color)))))
                (push (cons f box) bad)))))
        (sort bad (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b))))))
    (mapc #'disable-theme custom-enabled-themes)))

(ert-deftest agent-background-faces/every-box-names-its-colour-dark ()
  (should (equal (drgnx-bgfaces-test--bad 'drgnx-dark) nil)))

(ert-deftest agent-background-faces/every-box-names-its-colour-light ()
  (should (equal (drgnx-bgfaces-test--bad 'drgnx-light) nil)))

;;; agent-panel-background-faces-test.el ends here
