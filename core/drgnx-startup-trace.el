;;; drgnx-startup-trace.el --- Where startup time goes: DRGNX_STARTUP_TRACE=FILE -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Loaded by early-init.el when $DRGNX_STARTUP_TRACE names a file: until the first frame is set up
;; (window-setup-hook), every `require' is timed and a CPU profile is taken; then the report — the
;; slowest features, the functions most often on the stack, the phases — is written to that file.
;; Costs nothing unless asked for.  See docs/develop/perf.md.

;;; Code:
(defvar drgnx-startup-trace--t0 (float-time))
(defvar drgnx-startup-trace--requires nil)
(defvar drgnx-startup-trace--marks nil)

(defun drgnx-startup-trace--require (orig feature &rest args)
  (if (featurep feature) (apply orig feature args)
    (let ((t0 (float-time)))
      (prog1 (apply orig feature args)
        (push (cons feature (* 1000 (- (float-time) t0))) drgnx-startup-trace--requires)))))

(defun drgnx-startup-trace-mark (name)
  "Note that startup reached NAME."
  (push (cons name (* 1000 (- (float-time) drgnx-startup-trace--t0))) drgnx-startup-trace--marks))

(defun drgnx-startup-trace--finish ()
  (drgnx-startup-trace-mark 'window-setup)
  (advice-remove 'require #'drgnx-startup-trace--require)
  (let ((profile (and (fboundp 'profiler-cpu-log) (profiler-cpu-log))) (counts (make-hash-table :test #'eq)) top)
    (when (fboundp 'profiler-cpu-stop) (profiler-cpu-stop))
    (when profile
      (maphash (lambda (bt n)
                 (let (seen)
                   (mapc (lambda (f) (when (and (symbolp f) f (not (memq f seen))) (push f seen) (setf (gethash f counts) (+ n (gethash f counts 0)))))
                         bt)))
               profile)
      (maphash (lambda (k v) (push (cons k v) top)) counts))
    (with-temp-file (getenv "DRGNX_STARTUP_TRACE")
      (let ((print-length nil))
        (pp (list :marks (reverse drgnx-startup-trace--marks)
                  :init-ms (and after-init-time (* 1000 (float-time (time-subtract after-init-time before-init-time))))
                  :requires (seq-take (sort drgnx-startup-trace--requires (lambda (a b) (> (cdr a) (cdr b)))) 40)
                  :profile-ms (seq-take (sort top (lambda (a b) (> (cdr a) (cdr b)))) 60))
            (current-buffer))))))

(advice-add 'require :around #'drgnx-startup-trace--require)
(when (fboundp 'profiler-cpu-start) (profiler-cpu-start 1000000))
(add-hook 'after-init-hook (lambda () (drgnx-startup-trace-mark 'after-init)) -100)
(add-hook 'window-setup-hook #'drgnx-startup-trace--finish 100)

(provide 'drgnx-startup-trace)
;;; drgnx-startup-trace.el ends here
