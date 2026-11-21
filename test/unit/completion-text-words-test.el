;;; completion-text-words-test.el --- batch tests: no dictionary popup without a word list (audit D4) -*- lexical-binding: t -*-
;; test-class: det

;; The 2026-11-16 audit (D4): typing in a .txt file wrote "Corfu detected an error" with an `ispell-lookup-words'
;; backtrace after each pause: Emacs adds ispell's word completion to text buffers, and Fedora has no word list.

(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "modules/extra/drgnx-completion" drgnx-dir) nil t)
(require 'ispell)

(ert-deftest completion-text-words/none-without-a-word-list ()
  "With no readable word list, text buffers get no dictionary completion, so corfu never calls `ispell-lookup-words'."
  (let ((ispell-complete-word-dict nil) (ispell-alternate-dictionary "/nonexistent/words"))
    (should-not (drgnx-completion-text-words))
    (let ((text-mode-ispell-word-completion (drgnx-completion-text-words)))
      (with-temp-buffer
        (text-mode)
        (should-not (memq 'ispell-completion-at-point completion-at-point-functions))))))

(ert-deftest completion-text-words/kept-with-a-word-list ()
  "With a readable word list, the dictionary's words are offered as before."
  (let* ((words (make-temp-file "words" nil nil "alpha\nbeta\n"))
         (ispell-complete-word-dict words))
    (unwind-protect (should (eq (drgnx-completion-text-words) 'completion-at-point))
      (delete-file words))))

(provide 'completion-text-words-test)
;;; completion-text-words-test.el ends here
