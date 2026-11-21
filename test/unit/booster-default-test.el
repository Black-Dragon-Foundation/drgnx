;;; booster-default-test.el --- the booster only where Nidhogg's framing is off; the events log; the TRAMP guard's place -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: configuration, no process.  The external package (eglot-booster) and the program are stubbed: they
;; are outside services; drgnx's own functions run for real.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'eglot)
(load (expand-file-name "modules/lang/drgnx-lang" drgnx-dir) nil t)
(load (expand-file-name "modules/extra/drgnx-booster" drgnx-dir) nil t)

(defvar nidhogg-workers-framing)
(defvar features)                       ; not special in Emacs (fns.c): a `let' of it needs the declaration

(defun drgnx-booster-test--setup (framing)
  "Run the booster's setup with the program present; non-nil when it turned the booster on."
  (let ((on nil) (features (cons 'nidhogg-workers features)) (nidhogg-workers-framing framing)
        (orig (symbol-function 'require)))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/bin/emacs-lsp-booster"))
              ((symbol-function 'require) (lambda (f &rest a) (if (eq f 'eglot-booster) t (apply orig f a))))
              ((symbol-function 'drgnx-module-set) #'ignore)
              ((symbol-function 'eglot-booster-mode) (lambda (_) (setq on t))))
      (drgnx-booster--setup))
    on))

(ert-deftest drgnx-booster/off-when-framing-is-on ()
  (should-not (drgnx-booster-test--setup t)))

(ert-deftest drgnx-booster/on-when-framing-is-off ()
  (should (drgnx-booster-test--setup nil)))

(ert-deftest drgnx-booster/on-without-the-feature ()
  (let ((on nil) (features (delq 'nidhogg-workers (copy-sequence features))) (nidhogg-workers-framing t)
        (orig (symbol-function 'require)))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/bin/emacs-lsp-booster"))
              ((symbol-function 'require) (lambda (f &rest a) (if (eq f 'eglot-booster) t (apply orig f a))))
              ((symbol-function 'drgnx-module-set) #'ignore)
              ((symbol-function 'eglot-booster-mode) (lambda (_) (setq on t))))
      (drgnx-booster--setup))
    (should on)))

(ert-deftest drgnx-lang/events-log-toggle ()
  (let ((eglot-events-buffer-config '(:size 0 :format full)) (said nil))
    (cl-letf (((symbol-function 'eglot-current-server) (lambda () nil))
              ((symbol-function 'message) (lambda (fmt &rest a) (push (apply #'format fmt a) said))))
      (drgnx-lang-show-lsp-log)
      (should (= (plist-get eglot-events-buffer-config :size) 2000000))
      (drgnx-lang-show-lsp-log)
      (should (= (plist-get eglot-events-buffer-config :size) 0))
      (should (= (length said) 2)))))

(ert-deftest drgnx-lang/framing-engages-under-drgnx ()
  "The regression row of the guard's move: with drgnx's guards installed, Nidhogg's jsonrpc adoption finds no advice
on the reader and frames; the guard is on the batch function instead."
  (require 'nidhogg-workers-jsonrpc)
  (unwind-protect
      (progn
        (drgnx-lang--install-eglot-guards)
        (should-not (nidhogg-workers-jsonrpc--advised-p))
        (should (advice-member-p #'drgnx-lang--answers-on-top-level-timers 'nidhogg-workers-jsonrpc--batch)))
    (drgnx-lang--teardown-eglot-guards)))

(ert-deftest drgnx-lang/guard-stays-on-the-filter-without-the-feature ()
  (unwind-protect
      (cl-letf (((symbol-function 'nidhogg-set-process-framing) nil))
        (drgnx-lang--install-eglot-guards)
        (should (advice-member-p #'drgnx-lang--answers-on-top-level-timers 'jsonrpc--process-filter))
        (should-not (advice-member-p #'drgnx-lang--answers-on-top-level-timers 'nidhogg-workers-jsonrpc--batch)))
    (drgnx-lang--teardown-eglot-guards)))

(ert-deftest drgnx-lang/a-connection-nidhogg-did-not-frame-gets-the-filter-guard ()
  (let ((proc (make-symbol "proc")) (filter #'ignore))
    (cl-letf (((symbol-function 'jsonrpc--process) (lambda (_) proc))
              ((symbol-function 'processp) (lambda (p) (eq p proc)))
              ((symbol-function 'nidhogg-process-framing) (lambda (_) nil))
              ((symbol-function 'process-filter) (lambda (_) filter))
              ((symbol-function 'set-process-filter) (lambda (_ f) (setq filter f))))
      (drgnx-lang--guard-unframed-filter 'server)
      (should (advice-function-member-p #'drgnx-lang--answers-on-top-level-timers filter)))
    ;; a framed one is left alone
    (setq filter #'ignore)
    (cl-letf (((symbol-function 'jsonrpc--process) (lambda (_) proc))
              ((symbol-function 'processp) (lambda (p) (eq p proc)))
              ((symbol-function 'nidhogg-process-framing) (lambda (_) 'content-length))
              ((symbol-function 'process-filter) (lambda (_) filter))
              ((symbol-function 'set-process-filter) (lambda (_ f) (setq filter f))))
      (drgnx-lang--guard-unframed-filter 'server)
      (should (eq filter #'ignore)))))

;;; booster-default-test.el ends here
