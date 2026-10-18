;;; mod-tty-frames-test.el --- batch tests: ui/terminal — what a terminal frame can do, the terminal report -*- lexical-binding: t -*-
;; Batch Emacs has no terminal to ask: terminal parameters and the query are stubbed; the tty tier
;; (test/tty/frames-test.el) runs the real thing.
(require 'ert)
(require 'drgnx)
(load (expand-file-name "modules/ui/drgnx-tty-frames" drgnx-dir) nil t)

(defmacro drgnx-tty-frames-test--terminal (params env &rest body)
  "BODY with the selected frame's terminal holding PARAMS (an alist), the frame's client environment ENV
(\"K=V\" strings), an empty cache and no terminal to ask."
  (declare (indent 2))
  `(let ((table (make-hash-table :test #'eq))
         (drgnx-tty-frames--cache (make-hash-table :test #'equal))
         (old-env (frame-parameter nil 'environment)))
     (pcase-dolist (`(,k . ,v) ,params) (puthash k v table))
     (unwind-protect
         (cl-letf (((symbol-function 'terminal-parameter) (lambda (_term p) (gethash p table)))
                   ((symbol-function 'set-terminal-parameter) (lambda (_term p v) (puthash p v table)))
                   ((symbol-function 'drgnx-tty-frames--ask) (lambda (_frame) nil))
                   ((symbol-function 'display-color-cells) (lambda (&optional _) 256)))
           (set-frame-parameter nil 'environment ,env)
           ,@body)
       (set-frame-parameter nil 'environment old-env))))

(ert-deftest drgnx-tty-frames/caps-of-a-modify-other-keys-terminal ()
  ;; xterm.el turned modifyOtherKeys on (its set string is among the terminal's mode strings)
  (drgnx-tty-frames-test--terminal '((tty-mode-set-strings . ("\e[?2004h" "\e[>4;1m"))) '("TERM=xterm-256color" "XTERM_VERSION=XTerm(397)")
    (let ((caps (drgnx-tty-frame-caps)))
      (should (eq (plist-get caps :keys) 'mok))
      (should (eq (plist-get caps :id) 'xterm))
      (should (eq (plist-get caps :colors) 256))
      (should (equal (terminal-parameter nil 'drgnx-tty-caps) caps))))
  ;; without it, and without kkp, the terminal is legacy; the client's environment names it, not the daemon's
  (drgnx-tty-frames-test--terminal nil '("TERM=xterm-256color" "VTE_VERSION=8000")
    (let ((caps (drgnx-tty-frame-caps)))
      (should (eq (plist-get caps :keys) 'legacy))
      (should (eq (plist-get caps :id) 'vte))))
  ;; Task 5's module marks the terminal when kkp is on
  (drgnx-tty-frames-test--terminal '((drgnx-tty-kkp . t) (tty-mode-set-strings . ("\e[>4;1m"))) '("TERM=xterm-kitty")
    (should (eq (plist-get (drgnx-tty-frame-caps) :keys) 'kkp))))

(ert-deftest drgnx-tty-frames/the-report-lists-what-this-terminal-cannot-send ()
  (let* ((state (make-temp-file "drgnx-tty-frames" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
         (vscode (alist-get 'vscode (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))))
         (drgnx-keys-last (list :layers '((vscode app editing window))
                                :bindings (mapcan (lambda (e) (mapcar (lambda (k) (list :id (car e) :key k))
                                                                      (seq-take-while #'stringp (cdr e))))
                                                  (plist-get vscode :bind)))))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-tty-frame-caps)
                   (lambda (&optional _) '(:id vte :outer nil :version "8000" :keys legacy :osc52 nil :colors 256
                                               :mouse t))))
          (drgnx-tty-frames-write-report (selected-frame))
          (let* ((report (with-temp-buffer
                           (insert-file-contents (expand-file-name "drgnx/terminal-report.eld" state))
                           (read (current-buffer))))
                 (entry (cdr (car (plist-get report :terminals))))
                 (unsendable (plist-get entry :unsendable)))
            (should (= (length (plist-get report :terminals)) 1))
            (should (eq (plist-get (plist-get entry :caps) :keys) 'legacy))
            (should (stringp (plist-get entry :seen)))
            (should (member "C-S-p" unsendable))
            (should (member "C-`" unsendable))
            (should-not (member "C-p" unsendable))
            ;; a second report of the same terminal replaces its entry
            (drgnx-tty-frames-write-report (selected-frame))
            (should (= (length (plist-get (with-temp-buffer
                                            (insert-file-contents (expand-file-name "drgnx/terminal-report.eld" state))
                                            (read (current-buffer)))
                                          :terminals))
                       1))))
      (delete-directory state t))))

(ert-deftest drgnx-tty-frames/toggle-mouse-is-in-every-profile ()
  (dolist (profile '("vscode" "emacs" "vim"))
    (should (string-search "(terminal-toggle-mouse "
                           (with-temp-buffer
                             (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
                             (buffer-string))))))

(ert-deftest drgnx-tty-frames/toggle-mouse-saves-only-when-run-interactively ()
  (let (saved set (drgnx-tty-mouse t))
    (cl-letf (((symbol-function 'customize-save-variable) (lambda (sym val &rest _) (push (list sym val) saved)))
              ((symbol-function 'customize-set-variable) (lambda (sym val &rest _) (push (list sym val) set)))
              ((symbol-function 'message) #'ignore))
      (drgnx-tty-frames-toggle-mouse)
      (should (equal set '((drgnx-tty-mouse nil))))
      (should-not saved)
      (call-interactively #'drgnx-tty-frames-toggle-mouse)
      (should (equal saved '((drgnx-tty-mouse nil)))))))

(ert-deftest drgnx-tty-frames/the-mouse-is-never-turned-on-without-a-terminal-frame ()
  ;; batch Emacs has no terminal frame: a graphical session never gets xterm-mouse-mode from this module
  (let ((xterm-mouse-mode nil) (drgnx-tty-mouse t))
    (drgnx-tty-frames-mouse-apply)
    (should-not xterm-mouse-mode)))
