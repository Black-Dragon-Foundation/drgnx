;;; drgnx-persist-first-client-test.el --- live: a daemon's first `emacsclient -c' keeps the restored files -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; A layout with two editor groups (a.txt | b.txt) is saved by one daemon session; a fresh daemon gets that
;; state file and its first `emacsclient -c' (no file) opens: every editor group shows its saved file — the
;; server's *scratch* (shown in a client window that asked for no file) does not replace one — and the
;; workbench was restored exactly once.
(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-ui)

(defun drgnx-persist-first-client--eval (sess form)
  "FORM's value (printed and read back) in daemon session SESS, its graphical window selected when it has one."
  (car (read-from-string
        (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json
                                                 (list :v (prin1-to-string
                                                           (let ((f (seq-find (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list))))
                                                             (if f (with-selected-frame f %s) %s)))))" form form))
                   :v))))

(defconst drgnx-persist-first-client--shown
  "(list (mapcar (lambda (g) (buffer-file-name (window-buffer g))) (drgnx-groups-list))
         (and (seq-some (lambda (w) (equal (buffer-name (window-buffer w)) \"*scratch*\")) (window-list)) t))"
  "Each editor group's file, and whether any window of the graphical frame shows *scratch*.")

(ert-deftest drgnx-persist/a-daemons-first-client-window-keeps-its-restored-files ()
  (let* ((root (make-temp-file "drgnx-first-client" t))
         (project (file-name-as-directory (expand-file-name "project" root)))
         (a (expand-file-name "a.txt" project)) (b (expand-file-name "b.txt" project))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         state names)
    (unwind-protect
        (progn
          (make-directory project t)
          (dolist (f (list a b)) (write-region "x\n" nil f nil 'silent))
          ;; The layout is made and saved (the last window closes) by one daemon, on the tier's monitor size (mutter
          ;; has no scale 2 for a 1400x800 one).
          (let* ((name (plist-get (drgnx-ui-start "drgnx" nil 30 t) :name))
                 (sess (progn (push name names) (drgnx-ui-own-session name))))
            (should (eql 0 (plist-get (drgnx-ui-new-frame sess) :exit)))
            (drgnx-persist-first-client--eval
             sess (format "(progn (find-file %S) (drgnx-chrome-apply nil t) (drgnx-groups-split-right)
                                  (find-file %S) (drgnx-chrome-apply nil t) t)" a b))
            (should (equal (car (drgnx-persist-first-client--eval sess drgnx-persist-first-client--shown)) (list a b)))
            (drgnx-persist-first-client--eval sess "(progn (delete-frame (selected-frame)) t)")
            (setq state (drgnx-persist-first-client--eval
                         sess "(with-temp-buffer (insert-file-contents (drgnx-persist--file)) (buffer-string))"))
            (should (string-match-p "a\\.txt" state))
            (drgnx-ui-stop name)
            (setq names nil))
          ;; A fresh daemon with that state; its first window, no file asked for.
          (let* ((name (plist-get (drgnx-ui-start "drgnx" nil 30 t) :name))
                 (sess (progn (push name names) (drgnx-ui-own-session name))))
            (drgnx-persist-first-client--eval
             sess (format "(progn (make-directory (file-name-directory (drgnx-persist--file)) t)
                                  (write-region %S nil (drgnx-persist--file) nil 'silent)
                                  (defvar drgnx-persist-first-client--restores 0)
                                  (advice-add 'drgnx-persist-restore :after
                                              (lambda (&rest _) (setq drgnx-persist-first-client--restores
                                                                      (1+ drgnx-persist-first-client--restores))))
                                  t)" state))
            (should (eql 0 (plist-get (drgnx-ui-new-frame sess) :exit)))
            (let (shown)
              (condition-case nil
                  (drgnx-test-wait (lambda ()
                                     (equal (setq shown (drgnx-persist-first-client--eval sess drgnx-persist-first-client--shown))
                                            (list (list a b) nil)))
                                   :secs 10 :what "the first client's restored layout")
                (ert-test-failed nil))
              (should (equal shown (list (list a b) nil))))
            (drgnx-test-pause 1 "nothing may restore again a moment later")
            (should (eql 1 (drgnx-persist-first-client--eval sess "drgnx-persist-first-client--restores")))
            (should (equal (drgnx-persist-first-client--eval sess drgnx-persist-first-client--shown) (list (list a b) nil)))))
      (mapc #'drgnx-ui-stop names)
      (delete-directory root t))))

;;; drgnx-persist-first-client-test.el ends here
