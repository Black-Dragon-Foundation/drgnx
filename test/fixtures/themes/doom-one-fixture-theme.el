;;; doom-one-fixture-theme.el --- a stand-in for Doom One, to test what drgnx derives from a third-party theme -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The colours of Doom One's default, cursor, shadow, link and syntax faces (the package is not a dependency).  The
;; terminal clause of `default' is unspecified, as in a daemon's first terminal frame: derive must read the graphical
;; clause, never `unspecified-bg'.  `drgnx-look-derive' tests load this with `custom-theme-load-path' pointing here.

;;; Code:
(deftheme doom-one-fixture "A stand-in for Doom One, for tests.")

(custom-theme-set-faces
 'doom-one-fixture
 '(default ((((type tty)) :background "unspecified-bg" :foreground "unspecified-fg")
            (t :background "#282c34" :foreground "#bbc2cf")))
 '(cursor ((t :background "#528bff")))
 '(shadow ((t :foreground "#5b6268")))
 '(link ((t :foreground "#51afef" :underline t)))
 '(font-lock-function-name-face ((t :foreground "#c678dd")))
 '(font-lock-keyword-face ((t :foreground "#51afef")))
 '(font-lock-string-face ((t :foreground "#98be65")))
 '(font-lock-type-face ((t :foreground "#ecbe7b")))
 '(font-lock-constant-face ((t :foreground "#a9a1e1")))
 '(font-lock-builtin-face ((t :foreground "#c678dd"))))

(provide-theme 'doom-one-fixture)
;;; doom-one-fixture-theme.el ends here
