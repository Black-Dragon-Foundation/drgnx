;;; inbox-test.el --- batch tests: the needs-you inbox's rows, answers, keys and kept choice -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-agents)
(load (expand-file-name "modules/ui/drgnx-inbox" drgnx-dir) nil t)

(defvar drgnx-inbox-test--hub nil "The hub calls the mock session made, newest first.")

(defmacro drgnx-inbox-test--with (&rest body)
  "BODY with a mock session `s1' asking permission 7 (and another thing waiting that is no permission), the hub's
calls recorded, the inbox's state file in a temporary folder and nothing of the inbox left after."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "inbox-unit" t)) (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil) (drgnx-inbox--pinned :unread) (drgnx-inbox--answered nil)
          (drgnx-inbox--read nil) (drgnx-agents--sessions nil) (drgnx-inbox-test--hub nil)
          (s (drgnx-agents--make
              :name "fix-explorer" :id "s1" :remote "r1"
              :permissions (list (list :id 7 :title "run a command"
                                       :options (vector (list :optionId "o-once" :kind "allow_once")
                                                        (list :optionId "o-always" :kind "allow_always")
                                                        (list :optionId "o-no" :kind "reject_once")))))))
     (push s drgnx-agents--sessions)
     (pcase-dolist (`(,id ,title ,fn ,doc ,_) drgnx-inbox--commands)
       (drgnx-command-define id :title title :category "Inbox" :command fn :doc doc))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-inbox--state-file) (lambda () (expand-file-name "inbox.eld" dir)))
                   ((symbol-function 'drgnx-agents--remote)
                    (lambda (_s method params &optional _r) (push (cons method params) drgnx-inbox-test--hub))))
           (drgnx-agents--take-attention
            (list :at_work 1 :items (vector (list :session "s1" :id 7 :text "claude · fix-explorer wants to run a command"
                                                  :detail "cargo test -p explorer"))))
           ,@body)
       (drgnx-agents--take-attention (list :at_work 0 :items (vector)))
       (when (get-buffer drgnx-inbox-buffer-name) (kill-buffer drgnx-inbox-buffer-name))
       (delete-directory dir t))))

(defun drgnx-inbox-test--text ()
  (with-current-buffer (drgnx-inbox--render) (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest drgnx-inbox/a-permission-ask-has-its-three-buttons-and-the-header-and-footer ()
  (drgnx-inbox-test--with
    (let ((text (drgnx-inbox-test--text)))
      (dolist (s '("Needs you" "Mark all read" "Pin as side bar" "fix-explorer wants to run a command" "Allow once"
                   "Always for this session" "Deny" "All notices"))
        (should (string-match-p (regexp-quote s) text)))
      (should-not (string-match-p "Unpin" text)))))

(ert-deftest drgnx-inbox/each-answer-sends-its-option-and-the-row-leaves-at-once ()
  (dolist (case '((drgnx-inbox-allow-once "o-once") (drgnx-inbox-allow-session "o-always") (drgnx-inbox-deny "o-no")))
    (drgnx-inbox-test--with
      (should (= 1 (drgnx-needs-you-count)))
      (let ((drgnx-inbox--selected '(permission "s1" . 7))) (funcall (car case)))
      (should (equal (car drgnx-inbox-test--hub) (list "agents/permission" :request 7 :option (cadr case))))
      (should (= 0 (drgnx-needs-you-count)))
      (should (string-match-p "Nothing needs you" (drgnx-inbox-test--text))))))

(ert-deftest drgnx-inbox/a-button-answers-the-row-it-was-drawn-on ()
  (drgnx-inbox-test--with
    (let ((drgnx-inbox--selected nil))
      (drgnx-inbox--press "inbox-allow-once" '(permission "s1" . 7))
      (should (equal (cadr (member :option (car drgnx-inbox-test--hub))) "o-once")))))

(ert-deftest drgnx-inbox/pinned-it-keeps-the-answered-row-faded-until-cleared ()
  (drgnx-inbox-test--with
    (drgnx-inbox--set-pinned t)
    (let ((drgnx-inbox--selected '(permission "s1" . 7))) (drgnx-inbox-allow-once))
    (let ((text (drgnx-inbox-test--text)))
      (should (string-match-p "fix-explorer wants to run a command" text))
      (should (string-match-p "Allowed once" text))
      (should (string-match-p "Clear answered" text))
      (should (string-match-p "Unpin" text)))
    (drgnx-inbox-clear-answered)
    (should-not (string-match-p "fix-explorer" (drgnx-inbox-test--text)))))

(ert-deftest drgnx-inbox/the-choice-is-remembered ()
  (drgnx-inbox-test--with
    (should-not (drgnx-inbox-pinned-p))
    (drgnx-inbox--set-pinned t)
    (setq drgnx-inbox--pinned :unread)       ; a new session reads the file
    (should (drgnx-inbox-pinned-p))
    (drgnx-inbox--set-pinned nil)
    (setq drgnx-inbox--pinned :unread)
    (should-not (drgnx-inbox-pinned-p))))

(ert-deftest drgnx-inbox/up-down-and-enter-move-and-press-the-first-button ()
  (drgnx-inbox-test--with
    (drgnx-notice-set 'wb (list (list :id 'job-1 :text "build failed" :command 'ignore)))
    (let ((first nil))
      (with-current-buffer (drgnx-inbox--render)
        (setq first drgnx-inbox--selected)
        (drgnx-inbox-next)
        (should-not (equal first drgnx-inbox--selected))
        (drgnx-inbox-previous)
        (should (equal first drgnx-inbox--selected))
        ;; Enter presses the permission row's first button: Allow once
        (setq drgnx-inbox--selected '(permission "s1" . 7))
        (drgnx-inbox-press))
      (should (equal (cadr (member :option (car drgnx-inbox-test--hub))) "o-once")))
    (drgnx-notice-set 'wb nil)))

(ert-deftest drgnx-inbox/every-button-and-key-has-a-registry-command ()
  (dolist (spec drgnx-inbox--commands)
    (should (symbolp (car spec)))
    (should (fboundp (nth 2 spec))))
  (dolist (kind drgnx-inbox-kinds)
    (dolist (b (cdr kind))
      (should (assq (intern (car b)) drgnx-inbox--commands)))))

(ert-deftest drgnx-inbox/a-row-has-its-source-on-the-title-line-and-the-detail-in-the-code-font ()
  (drgnx-inbox-test--with
    (let ((text (drgnx-inbox-test--text)))
      (should (string-match-p "^● claude · fix-explorer wants to run a command · agents$" text))
      (should-not (string-match-p "^ *agents$" text))               ; the source has no line of its own
      (should (string-match-p "^  cargo test -p explorer$" text)))
    (with-current-buffer drgnx-inbox-buffer-name
      (goto-char (point-min)) (search-forward "cargo test")
      (should (memq 'drgnx-code-small (ensure-list (get-text-property (1- (point)) 'face)))))))

(ert-deftest drgnx-inbox/the-first-button-is-the-primary-one ()
  (drgnx-inbox-test--with
    (drgnx-inbox-test--text)
    (with-current-buffer drgnx-inbox-buffer-name
      (let ((face (lambda (label) (goto-char (point-min)) (search-forward label)
                    (ensure-list (get-text-property (1- (point)) 'face)))))
        (should (memq 'drgnx-ui-button-primary (funcall face "Allow once")))
        (should-not (memq 'drgnx-ui-button-primary (funcall face "Deny")))))))

(ert-deftest drgnx-inbox/the-card-lists-as-many-items-as-the-pill-counts ()
  (drgnx-inbox-test--with
    (drgnx-notice-set 'wb (list (list :id 'job-1 :text "build failed" :command 'ignore)))
    (should (= (drgnx-needs-you-count) (length (drgnx-needs-you-items))))
    (should (= 2 (length (seq-filter (lambda (l) (string-prefix-p "● " l)) (split-string (drgnx-inbox-test--text) "\n")))))
    (drgnx-notice-set 'wb nil)))

(provide 'inbox-test)
;;; inbox-test.el ends here
