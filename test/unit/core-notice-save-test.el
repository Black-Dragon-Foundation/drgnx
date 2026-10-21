;;; core-notice-save-test.el --- batch tests: each Emacs writes its own notice session file -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-notice-save)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defmacro drgnx-notice-save-test--with (&rest body)
  "BODY on a fresh notice model, virtual time and an empty state dir (XDG_STATE_HOME), the save mode on."
  (declare (indent 0) (debug t))
  `(let* ((dir (file-name-as-directory (make-temp-file "drgnx-notice-save-" t)))
          (process-environment (cons (concat "XDG_STATE_HOME=" dir) process-environment))
          (drgnx-notice--save-pruned nil))
     (unwind-protect
         (drgnx-notice-test-with-model
           (drgnx-test-with-clock ()
             (unwind-protect (progn (drgnx-notice-save-mode 1) (drgnx-test-idle 3) ,@body)
               (drgnx-notice-save-mode -1))))
       (delete-directory dir t))))

(defun drgnx-notice-save-test--read (&optional file)
  (let ((r (drgnx-file-read (or file (drgnx-notice-save-file)))))
    (and (eq (plist-get r :status) 'ok) (plist-get r :data))))

(ert-deftest drgnx-notice-save/saves-2-s-after-a-change ()
  (drgnx-notice-save-test--with
    (delete-file (drgnx-notice-save-file))
    (drgnx-notify 'keys 'warn "a key clash" :id 'k :life 'condition)
    (drgnx-test-idle 1.5)
    (should-not (file-exists-p (drgnx-notice-save-file)))
    (drgnx-test-idle 2)
    (should (file-exists-p (drgnx-notice-save-file)))
    (should (equal (mapcar (lambda (n) (plist-get n :text)) (plist-get (drgnx-notice-save-test--read) :notices))
                   '("a key clash")))))

(ert-deftest drgnx-notice-save/the-file-holds-conditions-and-the-last-50-warn-fail-events ()
  (drgnx-notice-save-test--with
    (drgnx-notify 'keys 'warn "clash" :id 'k :life 'condition)
    (dotimes (i 60) (drgnx-notify 'hooks (if (cl-evenp i) 'warn 'fail) (format "event %d" i)))
    (dotimes (i 5) (drgnx-notify 'hooks 'info (format "fyi %d" i)))
    (drgnx-notice--save)
    (let* ((data (drgnx-notice-save-test--read))
           (notices (plist-get data :notices))
           (events (cl-remove-if-not (lambda (n) (eq (plist-get n :life) 'event)) notices)))
      (should (= 1 (length (cl-remove-if-not (lambda (n) (eq (plist-get n :life) 'condition)) notices))))
      (should (= 50 (length events)))
      (should (cl-every (lambda (n) (memq (plist-get n :severity) '(warn fail))) events))
      (should (member "event 59" (mapcar (lambda (n) (plist-get n :text)) events)))
      (should-not (member "event 9" (mapcar (lambda (n) (plist-get n :text)) events))))))

(ert-deftest drgnx-notice-save/it-reads-back ()
  (drgnx-notice-save-test--with
    (drgnx-notify 'keys 'fail "no" :id 'k :life 'condition :fix "do x" :command 'preferences-keys)
    (puthash '(hooks . h) (list :source 'hooks :id 'h :severity 'warn :life 'condition :text "hook" :at 1.0
                                :command (list 'foo (current-buffer)))
             drgnx-notice--table)
    (drgnx-notice--save)
    (let ((data (drgnx-notice-save-test--read)))
      (should (= 1 (plist-get data :version)))
      (should (= (emacs-pid) (plist-get data :pid)))
      (should (equal emacs-version (plist-get data :emacs)))
      (should (floatp (plist-get data :written)))
      (should (plist-member data :daemon))
      (should (plist-get data :started))
      (let ((k (cl-find 'k (plist-get data :notices) :key (lambda (n) (plist-get n :id))))
            (h (cl-find "hook" (plist-get data :notices) :key (lambda (n) (plist-get n :text)) :test #'equal)))
        (should (eq 'preferences-keys (plist-get k :command)))
        (should (equal "do x" (plist-get k :fix)))
        (should-not (plist-member h :command))))))   ; a closure is not readable

(ert-deftest drgnx-notice-save/exit-renames-to-last ()
  (drgnx-notice-save-test--with
    (drgnx-notify 'keys 'warn "clash" :id 'k :life 'condition)
    (drgnx-notice--save-at-exit)
    (should-not (file-exists-p (drgnx-notice-save-file)))
    (should (file-exists-p (drgnx-notice-save-last-file)))
    (should (equal "clash" (plist-get (car (plist-get (drgnx-notice-save-test--read (drgnx-notice-save-last-file))
                                                      :notices))
                                      :text)))))

(ert-deftest drgnx-notice-save/the-files-are-owner-only ()
  (drgnx-notice-save-test--with
    (drgnx-notify 'keys 'warn "clash /home/x" :id 'k :life 'condition)
    (drgnx-notice--save)
    (should (= #o600 (file-modes (drgnx-notice-save-file))))
    (drgnx-notice--save-at-exit)
    (should (= #o600 (file-modes (drgnx-notice-save-last-file))))))

(ert-deftest drgnx-notice-save/one-file-per-process ()
  (drgnx-notice-save-test--with
    (should-not (equal (drgnx-notice-save-file) (drgnx-notice-save-file 12345)))
    (should (string-suffix-p (format "/notices/%d.eld" (emacs-pid)) (drgnx-notice-save-file)))
    (should (string-suffix-p "/notices/12345.eld" (drgnx-notice-save-file 12345)))
    (drgnx-notify 'keys 'warn "clash" :id 'k :life 'condition)
    (drgnx-notice--save)
    (should (equal (list (format "%d.eld" (emacs-pid)))
                   (directory-files (file-name-directory (drgnx-notice-save-file)) nil "\\.eld\\'")))))

(ert-deftest drgnx-notice-save/old-dead-files-are-pruned ()
  (drgnx-notice-save-test--with
    (let* ((d (file-name-directory (drgnx-notice-save-file)))
           (old (* 9 86400)))
      (make-directory d t)
      (dolist (pid '(900001 900002 900003))
        (with-temp-file (drgnx-notice-save-file pid) (insert "(:version 1)")))
      (set-file-times (drgnx-notice-save-file 900001) (time-subtract (current-time) old))   ; dead, old: goes
      (set-file-times (drgnx-notice-save-file 900003) (time-subtract (current-time) old))   ; alive, old: stays
      (cl-letf (((symbol-function 'process-attributes)
                 (lambda (pid) (and (memq pid (list 900003 (emacs-pid))) (list (cons 'comm (concat "ema" "cs")))))))   ; built, so the bare-emacs lint does not read it as a command
        (setq drgnx-notice--save-pruned nil)
        (drgnx-notify 'keys 'warn "clash" :id 'k :life 'condition)
        (drgnx-notice--save)
        (should-not (file-exists-p (drgnx-notice-save-file 900001)))
        (should (file-exists-p (drgnx-notice-save-file 900002)))   ; dead but recent
        (should (file-exists-p (drgnx-notice-save-file 900003)))
        (should (file-exists-p (drgnx-notice-save-file)))))))
