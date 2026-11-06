;;; no-prompt-test.el --- batch tests: code that must never ask -*- lexical-binding: t -*-
;; test-class: det
;; `drgnx-with-no-prompts' (core/drgnx-no-prompt.el): every way the code inside could ask the user signals instead,
;; and the guard returns what it would have asked about.  Nothing waits: each question signals before it reads.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-no-prompt nil t)

(ert-deftest drgnx-no-prompt/read-char-and-read-key-signal ()
  "A body that asks nothing returns nil; one that reads a key, a character, an event, a line or a yes-or-no returns
its reason instead of waiting."
  (should-not (drgnx-with-no-prompts (+ 1 2)))
  (dolist (ask (list #'read-char #'read-key #'read-event
                     (lambda () (read-from-minibuffer "Name: "))
                     (lambda () (y-or-n-p "Go on? "))
                     (lambda () (yes-or-no-p "Really? "))))
    (let ((why (drgnx-with-no-prompts (funcall ask))))
      (should (stringp why))
      (should (string-match-p "would have \\(?:asked\\|read a key\\)" why)))))

(ert-deftest drgnx-no-prompt/supersession-names-its-reason ()
  "The lock and supersession questions (`lock_file''s, from C) signal with what they are about: the file changed on
disk, or another Emacs holds its lock.  Outside the guard they are Emacs's own again."
  (let ((lock (symbol-function 'ask-user-about-lock))
        (threat (symbol-function 'ask-user-about-supersession-threat)))
    (let ((why (drgnx-with-no-prompts (ask-user-about-supersession-threat "/p/notes.txt"))))
      (should (string-match-p "notes.txt changed on disk" why)))
    (let ((why (drgnx-with-no-prompts (userlock--ask-user-about-supersession-threat "/p/notes.txt"))))
      (should (string-match-p "notes.txt changed on disk" why)))
    (let ((why (drgnx-with-no-prompts (ask-user-about-lock "/p/notes.txt" "someone@host (pid 7)"))))
      (should (string-match-p "notes.txt is locked by someone@host" why)))
    (should (eq (symbol-function 'ask-user-about-lock) lock))
    (should (eq (symbol-function 'ask-user-about-supersession-threat) threat))))

;;; no-prompt-test.el ends here
