;;; save-ask-test.el --- batch tests: Save / Don't Save / Cancel -*- lexical-binding: t -*-
;; test-class: det
;; `drgnx-save-ask' (core/drgnx-save-ask.el): the one question a close asks about unsaved changes, and
;; `drgnx-save-ask-discard', which keeps what Don't Save threw away.
(require 'ert)
(require 'drgnx)
(require 'drgnx-guard)
(require 'drgnx-save-ask nil t)
(defvar drgnx-close-discarded)

(defun drgnx-save-ask-test--answer (keys)
  "`drgnx-save-ask' answered with KEYS (a `kbd' string, or a list of events) as if a user were there."
  (let ((noninteractive nil) (inhibit-interaction nil)
        (unread-command-events (if (stringp keys) (listify-key-sequence (kbd keys)) keys)))
    (prog1 (drgnx-save-ask "notes.txt")
      (should-not unread-command-events))))

(ert-deftest drgnx-save-ask/the-three-answers ()
  "s saves, d doesn't, c cancels; Escape and C-g cancel too, and a key that is none of them asks again."
  (should (eq 'save (drgnx-save-ask-test--answer "s")))
  (should (eq 'discard (drgnx-save-ask-test--answer "d")))
  (should (eq 'cancel (drgnx-save-ask-test--answer "c")))
  (should (eq 'cancel (drgnx-save-ask-test--answer "ESC")))
  (should (eq 'cancel (drgnx-save-ask-test--answer '(escape))))
  (should (eq 'cancel (drgnx-save-ask-test--answer "C-g")))
  (should (eq 'save (drgnx-save-ask-test--answer "x s"))))

(ert-deftest drgnx-save-ask/never-asks-where-nobody-can-answer ()
  "In batch, under `inhibit-interaction', in a timer and in other automatic code the answer is Cancel at once: no key
is read, nothing is lost."
  (let ((unread-command-events (list ?d)))
    (should (eq 'cancel (drgnx-save-ask "notes.txt")))                  ; batch: `noninteractive'
    (let ((noninteractive nil))
      (let ((inhibit-interaction t)) (should (eq 'cancel (drgnx-save-ask "notes.txt"))))
      (let ((drgnx-guard--timer-fn 'some-timer)) (should (eq 'cancel (drgnx-save-ask "notes.txt"))))
      (drgnx-automatic (should (eq 'cancel (drgnx-save-ask "notes.txt")))))
    (should (equal '(?d) unread-command-events))))

(ert-deftest drgnx-save-ask/discard-keeps-the-last-five ()
  "Don't Save kills the buffer without a further question, and keeps its text in `drgnx-close-discarded', newest
first, at most five."
  (let ((drgnx-close-discarded nil))
    (dotimes (i 6)
      (let ((b (generate-new-buffer "discard-me")))
        (with-current-buffer b
          (setq buffer-file-name (format "/nonexistent/f%d.txt" i))
          (insert (format "text %d" i)))
        (should (buffer-modified-p b))
        (drgnx-save-ask-discard b)
        (should-not (buffer-live-p b))))
    (should (= 5 (length drgnx-close-discarded)))
    (should (equal "/nonexistent/f5.txt" (plist-get (car drgnx-close-discarded) :file)))
    (should (equal "text 5" (plist-get (car drgnx-close-discarded) :text)))
    (should (equal "/nonexistent/f1.txt" (plist-get (car (last drgnx-close-discarded)) :file)))))
