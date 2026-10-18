;;; drgnx-modal-daemon-test.el --- live: Vim's quit commands close windows, never the drgnx daemon -*- lexical-binding: t -*-
;; A daemon session of config drgnx that keeps running in the background, evil from DRGNX_MODAL_ELPA and the Vim
;; stack: `:q' in the only window (one tab), `ZZ' on a changed file, `:qa' — after each the window is gone, the daemon
;; answers on its socket, the layout was saved and ZZ's file was written; with two windows `:q' closes only its own.
;; Without evil the test skips (docs/develop/harness.md, "Modal tests").
(require 'ert)
(require 'cl-lib)
(require 'drgnx-ui)
(load (expand-file-name "test/fixtures/modal-session" drgnx-ui-repo-dir) nil t)

(defun drgnx-modal-daemon-test--windows (sess)
  "How many graphical windows (frames) SESS has."
  (plist-get (drgnx-ui-call sess "(drgnx-uitest-api-gui-frames)") :count))

(defun drgnx-modal-daemon-test--windows-become (sess n)
  "Wait (10 s at most) until SESS has N graphical windows; non-nil when it has."
  (let ((deadline (+ (float-time) 10)))
    (while (and (/= (drgnx-modal-daemon-test--windows sess) n) (< (float-time) deadline)) (sleep-for 0.1))
    (= (drgnx-modal-daemon-test--windows sess) n)))

(defun drgnx-modal-daemon-test--answers-p (sess)
  "Whether the daemon of SESS evaluates (+ 1 1) on its socket."
  (equal (plist-get (drgnx-ui-call sess "(drgnx-uitest--json (list :v (+ 1 1)))" 5) :v) 2))

(defun drgnx-modal-daemon-test--forget-layout (sess)
  "Delete the saved layout of SESS, so the next close shows whether it saves again."
  (drgnx-modal-session-eval sess '(progn (when (file-exists-p (drgnx-persist--file)) (delete-file (drgnx-persist--file))) t)))

(defun drgnx-modal-daemon-test--quit-kept-the-daemon (sess windows)
  "After a quit command: SESS has WINDOWS windows, answers, and wrote its layout."
  (should (drgnx-modal-daemon-test--windows-become sess windows))
  (should (drgnx-modal-daemon-test--answers-p sess))
  (should (drgnx-modal-session-eval sess '(file-exists-p (drgnx-persist--file)))))

(ert-deftest drgnx-live-modal/quit-keeps-the-daemon ()
  (drgnx-modal-session-with (sess :daemon t)
    (let* ((dir (file-name-as-directory (make-temp-file "drgnx-modal-daemon" t)))
           (file (expand-file-name "zz.txt" dir)))
      (unwind-protect
          (progn
            (write-region "one\n" nil file nil 'silent)
            (should (drgnx-modal-session-eval sess '(progn (drgnx-session-set-keep-running t) (and drgnx-keep-running (daemonp)))))
            ;; one window, one tab: :q
            (should (eql 0 (plist-get (drgnx-ui-new-frame sess) :exit)))
            (should (= 1 (drgnx-modal-daemon-test--windows sess)))
            (should (equal (drgnx-modal-session-eval sess '(list (length (drgnx-groups-list)) evil-state)) '(1 normal)))
            (drgnx-modal-daemon-test--forget-layout sess)
            (drgnx-modal-session-act sess ":" '(:type "q") "RET")
            (drgnx-modal-daemon-test--quit-kept-the-daemon sess 0)
            ;; a new window, a changed file: ZZ saves it and closes the window
            (should (eql 0 (plist-get (drgnx-ui-new-frame sess) :exit)))
            (drgnx-modal-session-eval sess `(progn (find-file ,file) (goto-char (point-min)) t))
            (drgnx-modal-session-act sess "i" '(:type "new ") "<escape>")
            (should (drgnx-modal-session-eval sess '(buffer-modified-p)))
            (drgnx-modal-daemon-test--forget-layout sess)
            (drgnx-modal-session-act sess "Z Z")
            (drgnx-modal-daemon-test--quit-kept-the-daemon sess 0)
            (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "new one\n"))
            ;; a new window: :qa
            (should (eql 0 (plist-get (drgnx-ui-new-frame sess) :exit)))
            (drgnx-modal-daemon-test--forget-layout sess)
            (drgnx-modal-session-act sess ":" '(:type "qa") "RET")
            (drgnx-modal-daemon-test--quit-kept-the-daemon sess 0)
            ;; two windows: :q in the second closes only that one
            (should (eql 0 (plist-get (drgnx-ui-new-frame sess) :exit)))
            (should (eql 0 (plist-get (drgnx-ui-new-frame sess) :exit)))
            (should (= 2 (drgnx-modal-daemon-test--windows sess)))
            (drgnx-modal-session-act sess ":" '(:type "q") "RET")
            (should (drgnx-modal-daemon-test--windows-become sess 1))
            (sleep-for 0.5)                                    ; nothing closes the other a moment later
            (should (= 1 (drgnx-modal-daemon-test--windows sess)))
            (should (drgnx-modal-daemon-test--answers-p sess)))
        (delete-directory dir t)))))

;;; drgnx-modal-daemon-test.el ends here
