;;; drgnx-persist-reopen-test.el --- live: a daemon that keeps running restores the layout when a window opens again -*- lexical-binding: t -*-
;; The keep-running case: the last window closes, the daemon stays, `emacsclient -c' brings the layout back.
(require 'ert)
(require 'drgnx-ui)

(defun drgnx-persist-reopen--eval (sess form)
  "FORM's value (any Lisp value, printed) from daemon session SESS, with its graphical window selected."
  (car (read-from-string
        (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json
                                                 (list :v (prin1-to-string
                                                           (with-selected-frame (seq-find (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list))
                                                             %s))))" form))
                   :v))))

(defconst drgnx-persist-reopen--layout
  "(list (mapcar (lambda (g) (list (mapcar #'buffer-name (drgnx-chrome-tabs g)) (buffer-name (window-buffer g))))
                (drgnx-groups-list))
        (drgnx-wb-sidebar-showing-p)
        drgnx-explorer--roots
        (mapcar #'window-pixel-width (drgnx-groups-list)))"
  "What a restore must bring back, as the session sees it.")

(ert-deftest drgnx-persist/reopen-brings-the-split-the-file-and-the-folders-back ()
  (let* ((root (make-temp-file "drgnx-reopen" t))
         (project (file-name-as-directory (expand-file-name "project" root)))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (progn (make-directory project t)
                   (dolist (f '("README.md" "a.txt" "b.txt"))
                     (write-region (format "%s\n" f) nil (expand-file-name f project) nil 'silent))
                   (drgnx-ui-start "drgnx" "1400x800" 30 t)))
         (name (plist-get s :name))
         (sess (drgnx-ui-own-session name)))
    (unwind-protect
        (progn
          (should (eql 0 (plist-get (drgnx-ui-new-frame sess) :exit)))     ; the first window: nothing saved yet
          (drgnx-persist-reopen--eval sess (format "(progn (find-file %S) (drgnx-chrome-apply nil t) (drgnx-groups-split-right)
                                                            (find-file %S) (drgnx-chrome-apply nil t)
                                                            (drgnx-explorer-set-roots (list %S)) (drgnx-wb-show-sidebar) t)"
                                                   (expand-file-name "a.txt" project) (expand-file-name "b.txt" project) project))
          (drgnx-ui-measure sess nil)
          (let ((before (drgnx-persist-reopen--eval sess drgnx-persist-reopen--layout)))
            (should (= 2 (length (car before))))
            (should (equal (nth 1 (car (car before))) "a.txt"))
            ;; The last window closes: the daemon stays, the layout is saved.
            (drgnx-persist-reopen--eval sess "(progn (delete-frame (selected-frame)) t)")
            (should (equal (plist-get (drgnx-ui-call sess "(drgnx-uitest-api-gui-frames)") :count) 0))
            (should (eq t (car (read-from-string
                                (plist-get (drgnx-ui-call sess "(drgnx-uitest--json (list :v (prin1-to-string (file-exists-p (drgnx-persist--file)))))") :v)))))
            ;; A new window: same split, same files, same Explorer folders.
            (should (eql 0 (plist-get (drgnx-ui-new-frame sess) :exit)))
            (let ((deadline (+ (float-time) 15)) after)
              (while (and (< (float-time) deadline)
                          (not (equal (butlast (setq after (drgnx-persist-reopen--eval sess drgnx-persist-reopen--layout))) (butlast before))))
                (sleep-for 0.2))
              (should (equal (butlast after) (butlast before)))
              ;; The two halves of the split come back within a few pixels (sidebar and divider rounding).
              (should (= (length (car (last after))) (length (car (last before)))))
              (should (cl-every (lambda (a b) (<= (abs (- a b)) 8)) (car (last after)) (car (last before)))))))
      (drgnx-ui-stop name)
      (delete-directory root t))))
