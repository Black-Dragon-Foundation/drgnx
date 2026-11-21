;;; look-fonts-orders-test.el --- font precedence in every order the sources arrive in -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: orders
;; Pattern A.  The core of the font roles (`drgnx-look-fonts-resolve-in': layers in, one resolution out) takes the
;; sources as they arrive: the snapshot of your Lisp at the end of init, a theme load, a change of the setting, a
;; Customize entry and the desktop's answer, for a role and for a role that takes its family from it.  The oracle is
;; independent of the core: it keeps what arrived and picks by the written precedence.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-type-faces)
(load (expand-file-name "modules/ui/drgnx-look-fonts" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)

(defconst drgnx-look-fonts-orders-test--precedence
  '(lisp customize setting theme desktop default)
  "The sources, highest first (the design's \"Where a value comes from\").")

(defun drgnx-look-fonts-orders-test--oracle (arrived role)
  "The family ROLE must have, from ARRIVED, an alist ((ROLE . SOURCE) ...) of what arrived: the highest source that
named ROLE; a role that took its family from `ui' and nothing named takes the oracle's answer for `ui'."
  (let* ((own (cl-loop for src in drgnx-look-fonts-orders-test--precedence
                       when (member (cons role src) arrived) return src)))
    (cond (own (format "%s-%s" role own))
          ((memq role '(ui-heading ui-caption)) (drgnx-look-fonts-orders-test--oracle arrived 'ui))
          (t (format "%s-default" role)))))

(defun drgnx-look-fonts-orders-test--layers (arrived role)
  "The layers the core gets for ROLE from ARRIVED: one per arrived source, named after the role and the source."
  (let (layers)
    (dolist (src drgnx-look-fonts-orders-test--precedence)
      (when (member (cons role src) arrived)
        (push (cons src (list :family (format "%s-%s" role src))) layers)))
    (setq layers (nreverse layers))
    (append layers (list (cons 'default (if (memq role '(ui-heading ui-caption)) '(:family ui)
                                          (list :family (format "%s-default" role))))))))

(defun drgnx-look-fonts-orders-test--run (check-fn)
  "Every order of a user's three events, a theme load, and the desktop's answer, for `ui' and `ui-heading'."
  (drgnx-test-every-order
   :kinds '(after-init-snapshot customize-set setting-change theme-load desktop-answer)
   :sources (list (cons 'user (list '(after-init-snapshot ui lisp) '(customize-set ui customize)
                                    '(setting-change ui setting)))
                  (cons 'theme (list '(theme-load ui-heading theme)))
                  (cons 'desktop (list '(desktop-answer ui desktop))))
   :init (lambda () (cons nil nil))
   ;; the resolution is checked after every event: the sources that arrived so far decide
   :step (lambda (st ev)
           (let ((arrived (cons (cons (nth 1 ev) (nth 2 ev)) (car st))))
             (cons (cons arrived (or (cdr st) (funcall check-fn arrived))) nil)))
   :check (lambda (st _order) (cdr st))
   :kind-of #'car))

(ert-deftest drgnx-look-fonts/precedence-in-every-order ()
  "Pattern A: in every order the sources arrive in, the resolved family of each role is the highest-precedence
source present, and a role that takes its family from `ui' follows `ui' when nothing named it."
  (let ((followed nil))
    (drgnx-look-fonts-orders-test--run
     (lambda (arrived)
       (cl-loop
        for role in '(ui ui-heading ui-caption)
        for got = (plist-get (drgnx-look-fonts-resolve-in
                              role (lambda (r) (drgnx-look-fonts-orders-test--layers arrived r)))
                             :family)
        for want = (drgnx-look-fonts-orders-test--oracle arrived role)
        do (when (and (eq role 'ui-caption) (string-prefix-p "ui-" got)) (setq followed t))
        unless (equal got want)
        return (format "%s: the core says %S, the precedence says %S, after %S" role got want arrived))))
    (should followed)))

(provide 'look-fonts-orders-test)
;;; look-fonts-orders-test.el ends here
