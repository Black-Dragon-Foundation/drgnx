;;; keys-diff-test.el --- batch tests: the key-sheet diff against gryphn -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-keys-diff)
(require 'drgnx-paths)

(ert-deftest drgnx-keys-diff/reads-gryphn-sheets-without-running-them ()
  (let ((dir (make-temp-file "drgnx-gryphn" t)))
    (unwind-protect
        (progn
          (write-region "(error \"never run\")\n(gryphn-command-define 'kx-a :title \"A\" :category \"X\" :command #'ignore :key \"<f5>\")\n(dolist (x '(1)) (gryphn-command-define 'kx-b :title \"B\" :category \"X\" :command #'ignore))\n`(gryphn-command-define ',id)\n"
                        nil (expand-file-name "gryphn-x.el" dir) nil 'silent)
          (should (equal (mapcar (lambda (r) (list (car r) (nth 2 r))) (drgnx-keys-diff-gryphn-sheet dir))
                         '((kx-a "<f5>") (kx-b nil)))))
      (delete-directory dir t))))

(ert-deftest drgnx-keys-diff/reads-the-macro-sheet-the-window-numbers-and-native-keys ()
  ;; gryphn's VS Code sheet is a macro table, its window keys are computed, its Emacs keys are :native.
  (let ((dir (make-temp-file "drgnx-gryphn" t)))
    (unwind-protect
        (progn
          (write-region (concat "(defmacro gryphn--keys (category &rest entries) nil)\n"
                                "(gryphn--keys \"File\" (file-save \"C-s\" save-buffer \"Save\" \"Save it\" :menu '(\"File\"))\n"
                                "  (code-format nil eglot-format-buffer \"Format Document\" \"Format\"))\n"
                                "(dotimes (i 2) (let ((n (1+ i))) (gryphn-command-define (intern (format \"go-window-%d\" n)) :title (format \"Window %d\" n) :key (format \"M-%d\" n))))\n"
                                "(dolist (e '((emacs-line-start \"C-a\" move-beginning-of-line \"Line Start\")))\n"
                                "  (pcase-let ((`(,id ,key ,command ,title) e)) (gryphn-command-define id :key key :command command :title title :native t)))\n")
                        nil (expand-file-name "gryphn-keys-x.el" dir) nil 'silent)
          (should (equal (mapcar (lambda (r) (list (car r) (nth 2 r) (nth 4 r))) (drgnx-keys-diff-gryphn-sheet dir))
                         '((file-save "C-s" nil) (code-format nil nil) (go-window-1 "M-1" nil) (go-window-2 "M-2" nil)
                           (emacs-line-start "C-a" native)))))
      (delete-directory dir t))))

(ert-deftest drgnx-keys-diff/a-rebound-native-key-is-a-difference ()
  ;; gryphn leaves the Emacs editing keys alone; so must drgnx's VS Code profile.
  (cl-letf (((symbol-function 'drgnx-keys-diff-gryphn-sheet)
             (lambda (_) '((emacs-line-start "Line Start" "C-a" "x.el" native) (emacs-kill-line "Kill" "C-k" "x.el" native)
                           (emacs-yank "Yank" "C-y" "x.el" native) (emacs-mark "Mark" "C-SPC" "x.el" native))))
            ((symbol-function 'drgnx-keys-diff--drgnx-bindings)
             ;; global bindings only: a key in a mode's own map (the Explorer's C-SPC) leaves Emacs' key alone
             (lambda (_) (list '((select-all "C-a") (keys-sheet "C-k C-s") (explorer-mark "C-SPC")) '(select-all keys-sheet explorer-mark)
                               '((select-all "C-a") (keys-sheet "C-k C-s"))))))
    (should (equal (mapcar (lambda (l) (list (car l) (nth 1 l))) (drgnx-keys-diff "/nowhere"))
                   '((native emacs-line-start) (native emacs-kill-line))))))

(ert-deftest drgnx-keys-diff/the-real-sheet-is-read ()
  (let ((dir (getenv "DRGNX_GRYPHN_DIR")))
    (skip-unless (and dir (file-directory-p dir)))
    (let ((ids (mapcar #'car (drgnx-keys-diff-gryphn-sheet dir))))
      (dolist (id '(file-save edit-move-up view-zoom-in go-window-9 view-panel emacs-line-start))
        (should (memq id ids))))))

(ert-deftest drgnx-keys-diff/nothing-unexplained-against-the-real-gryphn ()
  ;; The M4 exit: every gryphn command is in drgnx with gryphn's key, or explained.
  (let ((dir (getenv "DRGNX_GRYPHN_DIR")))
    (skip-unless (and dir (file-directory-p dir)))
    ;; In its own Emacs: the diff runs every module and loads gryphn's files.
    (let ((out (with-temp-buffer
                 (list (call-process (expand-file-name "bin/drgnx" drgnx-dir) nil t nil "keys" "diff" "--against" "gryphn" dir)
                       (buffer-string)))))
      (should (equal (list (car out) (car (last (split-string (cadr out) "\n" t))))
                     (list 0 (car (last (split-string (cadr out) "\n" t))))))
      (should (string-match-p " 0 unexplained" (cadr out))))))
