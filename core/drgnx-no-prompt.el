;;; drgnx-no-prompt.el --- Run code that must never ask: a would-be question becomes its reason -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-with-no-prompts' runs code that nobody may be there to answer (a pair write's save, a buffer event), so
;; every question it could ask fails at once instead of waiting.  Nothing global changes: the bindings and the
;; function replacements are inside the guard only.  See docs/develop/core.md, "No prompts in automatic paths".

;;; Code:
(require 'cl-lib)

(define-error 'drgnx-would-prompt "Would have asked the user")

(defconst drgnx-no-prompt--asked "it would have asked a question"
  "The reason for a question Emacs refused under `inhibit-interaction' (its signal names none).")

(defun drgnx-no-prompt--supersession (filename)
  "The guard's `ask-user-about-supersession-threat': FILENAME changed on disk since it was read; nothing asks."
  (signal 'drgnx-would-prompt (list (format "%s changed on disk since it was read" (file-name-nondirectory filename)))))

(defun drgnx-no-prompt--lock (file opponent)
  "The guard's `ask-user-about-lock': FILE is locked by OPPONENT; nothing asks."
  (signal 'drgnx-would-prompt (list (format "%s is locked by %s" (file-name-nondirectory file) opponent))))

(defun drgnx-no-prompt--key (&rest _)
  "The guard's `read-key': it reads through `read-key-sequence-vector', which `inhibit-interaction' does not stop."
  (signal 'drgnx-would-prompt (list "it would have read a key")))

(defun drgnx-no-prompt--call (fn)
  "Call FN with no question possible: nil when it ran to its end, else the reason, a string (`drgnx-with-no-prompts')."
  (let ((inhibit-interaction t)
        (delete-old-versions (if (null delete-old-versions) 'keep delete-old-versions))
        (require-final-newline (if (eq require-final-newline 'ask) t require-final-newline)))
    (condition-case err
        (cl-letf (((symbol-function 'read-key) #'drgnx-no-prompt--key)
                  ((symbol-function 'ask-user-about-lock) #'drgnx-no-prompt--lock)
                  ((symbol-function 'ask-user-about-supersession-threat) #'drgnx-no-prompt--supersession)
                  ((symbol-function 'userlock--ask-user-about-supersession-threat) #'drgnx-no-prompt--supersession))
          (funcall fn)
          nil)
      (drgnx-would-prompt (format "%s" (cadr err)))
      (inhibited-interaction drgnx-no-prompt--asked)
      ;; drgnx-guard-mode's own refusal of a prompt in an automatic path (a timer)
      (drgnx-prompt-in-automatic-path drgnx-no-prompt--asked))))

(defmacro drgnx-with-no-prompts (&rest body)
  "Run BODY so that nothing in it can ask you anything: nil when it ran to its end, else WHY, a string saying what it
would have asked about.  BODY's own value is not returned.
- `inhibit-interaction' is t first, so every minibuffer read, `read-char', `read-event', `y-or-n-p' and the C
  callers signal `inhibited-interaction'; `read-key' (which `inhibit-interaction' does not stop) signals
  `drgnx-would-prompt';
- `delete-old-versions' is `keep' where yours is nil (the save would ask whether to delete excess backups), and
  `require-final-newline' t where yours is `ask';
- `ask-user-about-lock', `ask-user-about-supersession-threat' and `userlock--ask-user-about-supersession-threat'
  (called from C by `lock_file') signal `drgnx-would-prompt' with their reason.
The current buffer when it starts is the one whose `require-final-newline' counts (bind it around a save in the
buffer saved).  No global advice: the replacements end with BODY."
  (declare (indent 0) (debug t))
  `(drgnx-no-prompt--call (lambda () ,@body)))

(provide 'drgnx-no-prompt)
;;; drgnx-no-prompt.el ends here
