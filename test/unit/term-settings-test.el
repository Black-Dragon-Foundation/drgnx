;;; term-settings-test.el --- batch tests: Ghostty's options as drgnx's terminal settings -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-terminal" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-term" drgnx-dir) nil t)

(defun drgnx-term-settings-test--fixture ()
  "The pinned names of Ghostty's options."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/fixtures/ghostty-options.txt" drgnx-dir))
    (seq-remove (lambda (l) (or (string-empty-p l) (string-prefix-p "#" l))) (split-string (buffer-string) "\n"))))

(defmacro drgnx-term-settings-test--in-terminal (&rest body)
  "BODY in a terminal buffer that is open as \"t1\" (no hub: what it sends is captured in `sent', newest first)."
  (declare (indent 0))
  `(let ((drgnx-term--buffers (make-hash-table :test #'equal)) (drgnx-term--notices nil) (sent nil)
         (b (generate-new-buffer "*terminal*")))
     (cl-letf (((symbol-function 'drgnx-term--send) (lambda (m p) (push (cons m p) sent)))
               ((symbol-function 'drgnx-notice-set) #'ignore))
       (unwind-protect
           (with-current-buffer b
             (drgnx-term-mode)
             (setq drgnx-term--id "t1" drgnx-term--state 'open)
             (puthash "t1" b drgnx-term--buffers)
             ,@body)
         (with-current-buffer b (setq drgnx-term--state 'exited))
         (kill-buffer b)))))

(ert-deftest drgnx-term-settings/every-ghostty-option-is-classified ()
  ;; each of Ghostty's options has exactly one place, and nothing else is in the table
  (let ((names (drgnx-term-settings-test--fixture)) (table (mapcar #'car drgnx-term-settings-options)))
    (should (= (length names) 204))
    (dolist (n names)
      (should (= (cl-count n table :test #'equal) 1)))
    (should-not (cl-set-difference table names :test #'equal))
    (dolist (r drgnx-term-settings-options)
      (pcase (nth 1 r)
        ((or 'live 'spawn) (should (and (boundp (nth 2 r)) (drgnx-setting-own-p (nth 2 r)))))
        ('face (should (facep (nth 2 r))))
        ('mapped (should (stringp (nth 2 r))))
        ('later (should (stringp (nth 2 r))))
        ('none (should (alist-get (nth 2 r) drgnx-term-settings--reasons)))
        (_ (ert-fail (format "%s: no class %s" (car r) (nth 1 r))))))))

(ert-deftest drgnx-term-settings/reference-is-generated-and-current ()
  (let ((file (expand-file-name "docs/reference/terminal-settings.md" drgnx-dir)))
    (should (file-exists-p file))
    (unless (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) (drgnx-term-settings-reference))
      (ert-fail (concat "docs/reference/terminal-settings.md is out of date; regenerate it with:\n"
                        "  emacs --batch -Q -L core -L wb -L modules/tools -l drgnx-term --eval "
                        "'(drgnx-term-settings-write-reference \"docs/reference/terminal-settings.md\")'")))))

(ert-deftest drgnx-term-settings/colour-options-are-faces-not-settings ()
  ;; every colour option is a face of the terminal's, and no setting of that name holds a colour
  (dolist (o '("background" "foreground" "palette" "bold-color" "faint-opacity" "cursor-color" "cursor-text"
               "selection-background" "selection-foreground" "search-background" "search-foreground"
               "search-selected-background" "search-selected-foreground"))
    (let ((r (assoc o drgnx-term-settings-options)))
      (should (eq (nth 1 r) 'face))
      (should (facep (nth 2 r)))
      (should-not (boundp (intern (concat "drgnx-term-" o))))))
  (dolist (n (number-sequence 0 15)) (should (facep (intern (format "drgnx-term-color-%d" n)))))
  ;; the worker learns the faces' colours, so a program reads them back
  (drgnx-term-settings-test--in-terminal
    (let ((entry (seq-find (lambda (e) (equal (aref e 0) "colours")) (drgnx-term--worker-config))))
      (should entry)
      (should (memq (length (aref entry 1)) '(3 19))))))

(ert-deftest drgnx-term-settings/spawn-setting-only-affects-new-terminals ()
  ;; `drgnx-term-env' and the scope's limits go with `term/open'; an open terminal is not told
  (let ((opens nil))
    (cl-letf (((symbol-function 'drgnx-term--up-p) (lambda () t))
              ((symbol-function 'drgnx-hub--call-on) (lambda (_c m p _f) (when (equal m "term/open") (push p opens))))
              ((symbol-function 'drgnx-term-send-string) #'ignore)
              ((symbol-function 'pop-to-buffer) #'ignore))
      (let ((a (drgnx-term-start temporary-file-directory)) b)
        (unwind-protect
            (let ((drgnx-term-env '("DRGNX_TEST_ENV=1")) (drgnx-term-linux-cgroup-memory-limit "512M")
                  (drgnx-term-linux-cgroup-processes-limit 100))
              (should-not (plist-get (drgnx-setting-meta 'drgnx-term-env) :apply))
              (setq b (drgnx-term-start temporary-file-directory))
              (should (= (length opens) 2))
              (let ((first (cadr opens)) (second (car opens)))
                (should-not (seq-find (lambda (e) (equal (aref e 0) "DRGNX_TEST_ENV")) (plist-get first :env)))
                (should-not (plist-get first :memory_max))
                (should (seq-find (lambda (e) (equal e ["DRGNX_TEST_ENV" "1"])) (plist-get second :env)))
                (should (equal (plist-get second :memory_max) "512M"))
                (should (equal (plist-get second :tasks_max) "100"))))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer a)
            (when b (kill-buffer b))))))))

(ert-deftest drgnx-term-settings/notify-on-command-finish-fires-after-threshold ()
  (drgnx-term-settings-test--in-terminal
    (let ((drgnx-term-notify-on-command-finish 'always) (drgnx-term-notify-on-command-finish-action '(notify bell))
          (drgnx-term-notify-on-command-finish-after 5) (rang 0))
      (cl-letf (((symbol-function 'ding) (lambda (&rest _) (cl-incf rang))))
        ;; a quick command is not told
        (drgnx-term--prompt 3)
        (drgnx-term--prompt 4)
        (should (= rang 0))
        (should-not drgnx-term--notices)
        ;; one that ran past the threshold is: the bell and a notice
        (drgnx-term--prompt 3)
        (setq drgnx-term--command-start (- (float-time) 6))
        (drgnx-term--prompt 4)
        (should (= rang 1))
        (should (string-match-p "Command finished" (plist-get (cdr (assoc "t1" drgnx-term--notices)) :text)))
        ;; `never' tells nothing
        (let ((drgnx-term-notify-on-command-finish 'never))
          (drgnx-term--prompt 3)
          (setq drgnx-term--command-start (- (float-time) 60))
          (drgnx-term--prompt 4)
          (should (= rang 1)))))))

(ert-deftest drgnx-term-settings/copy-on-select-copies ()
  ;; a mouse selection copies at once, without its trailing blanks; off, it copies nothing
  (drgnx-term-settings-test--in-terminal
    (let ((inhibit-read-only t)) (insert "hello world   \nnext"))
    (set-window-buffer (selected-window) (current-buffer))
    (let* ((kill-ring nil) (kill-ring-yank-pointer nil) (interprogram-cut-function nil)
           (posn (lambda (pos) (list (selected-window) pos '(0 . 0) 0 nil pos '(0 . 0) nil '(0 . 0) '(1 . 1))))
           (drag (list 'drag-mouse-1 (funcall posn 1) (funcall posn 15))))
      (let ((drgnx-term-copy-on-select nil))
        (drgnx-term--apply-local)
        (mouse-set-region drag)
        (should-not kill-ring))
      (let ((drgnx-term-copy-on-select t))
        (drgnx-term--apply-local)
        (mouse-set-region drag)
        (should (equal (car kill-ring) "hello world"))))))

(ert-deftest drgnx-term-settings/paste-protection-asks-on-unsafe-paste ()
  (drgnx-term-settings-test--in-terminal
    (let ((asked 0) (kill-ring nil) (kill-ring-yank-pointer nil) (interprogram-paste-function nil))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) (cl-incf asked) nil)))
        ;; one line: no question
        (kill-new "ls -l")
        (drgnx-term-paste)
        (should (= asked 0))
        (should (equal (cdar sent) '(:text "ls -l")))
        ;; lines, and the program did not ask for bracketed paste: asked, and refused, nothing goes
        (setq sent nil)
        (kill-new "ls\nrm -r stuff\n")
        (drgnx-term-paste)
        (should (= asked 1))
        (should-not sent)
        ;; the program asked for bracketed paste: safe
        (setq-local drgnx-view-patch (drgnx-view-patch--make :view "term:t1" :class "term" :term (list :bracketed_paste t)))
        (drgnx-term-paste)
        (should (= asked 1))
        (should (equal (cdar sent) '(:text "ls\nrm -r stuff\n")))
        ;; the end of a bracketed paste inside it is never safe
        (setq sent nil)
        (kill-new "a\e[201~\nb")
        (drgnx-term-paste)
        (should (= asked 2))
        (should-not sent)
        ;; protection off: never asked
        (let ((drgnx-term-clipboard-paste-protection nil))
          (drgnx-term-paste)
          (should (= asked 2))
          (should sent))))))

(provide 'term-settings-test)
;;; term-settings-test.el ends here
