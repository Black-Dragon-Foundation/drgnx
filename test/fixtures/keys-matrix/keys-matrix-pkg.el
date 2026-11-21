;;; keys-matrix-pkg.el --- a package stand-in for the keys matrix (test/unit/keys-matrix-test.el) -*- lexical-binding: t -*-
;; Loaded with `load' (never `require') once per case, after `keys-matrix-pkg-reset': it has a mode and a mode map
;; of its own, and writes the global keys `keys-matrix-pkg-global' names the way packages do.  Its own
;; `load-file-name' is this file, so a scope opened by config.el never counts its writes as yours.

(defvar keys-matrix-pkg-global nil
  "Global writes this package makes when it loads: a list of (STYLE KEY), STYLE `define-key' (into `global-map'),
`current-global-map' (into whatever map is current, as magit does) or `global-set-key'.  Each binds KEY to
`keys-matrix-pkg-glob'.")

(defvar keys-matrix-pkg-mode-keys nil "Keys this package binds in its own mode map, each to `keys-matrix-pkg-own'.")

(defun keys-matrix-pkg-glob () "A package's global command." (interactive))
(defun keys-matrix-pkg-own () "A package's mode-map command." (interactive))

(defvar keys-matrix-pkg-mode-map
  (let ((m (make-sparse-keymap)))
    (dolist (k keys-matrix-pkg-mode-keys) (define-key m (kbd k) #'keys-matrix-pkg-own))
    m)
  "The package's mode map.")

(define-derived-mode keys-matrix-pkg-mode fundamental-mode "KMP" "The package's major mode.")

(define-derived-mode keys-matrix-pkg-child-mode keys-matrix-pkg-mode "KMP/c" "A mode derived from the package's.")

(dolist (w keys-matrix-pkg-global)
  (pcase (car w)
    ('define-key (define-key global-map (kbd (cadr w)) #'keys-matrix-pkg-glob))
    ('current-global-map (define-key (current-global-map) (kbd (cadr w)) #'keys-matrix-pkg-glob))
    ('global-set-key (global-set-key (kbd (cadr w)) #'keys-matrix-pkg-glob))))

(provide 'keys-matrix-pkg)
;;; keys-matrix-pkg.el ends here
