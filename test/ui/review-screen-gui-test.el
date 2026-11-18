;;; review-screen-gui-test.el --- GUI tests: the review screen's keys and what they send the hub (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; The hub builds the screen's rows (Rust `review_screen.rs'); these rows put hub-shaped rows (the text properties
;; `drgnx-review-hunk' and `drgnx-action' it gives) in a review-screen buffer on a graphical frame and check what each key
;; asks of the hub: `D' rejects one hunk (a pending mark of that hunk, one steer, no other hunk touched), `r' steers
;; through `agents/send' and never cancels, nothing merges or pushes, `a' marks one hunk.  The hub is stubbed at
;; `drgnx-hub-call': the calls are the rows' evidence.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-ui-review-screen--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "modules/tools"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-review-screen--repo)))
(require 'drgnx)
(require 'drgnx-ui-kit)
(require 'drgnx-work-code)
(require 'drgnx-review-screen)

(defun drgnx-ui-review-screen--hunk-row (path i)
  (propertize (format "  @@ hunk %d of %s\n" i path)
              'drgnx-review-hunk (list :path path :index i :hash (format "h%d" i) :session "s1")))

(defmacro drgnx-ui-review-screen--with (calls &rest body)
  "BODY in a review-screen buffer of session s1 with two hunks of a.rs; each hub call of BODY is pushed on CALLS."
  (declare (indent 1))
  `(let ((,calls nil))
     (skip-unless (display-graphic-p))
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params &optional _cb) (push (cons method params) ,calls))))
       (with-current-buffer (get-buffer-create "*Review: test*")
         (unwind-protect
             (progn
               (drgnx-review-screen-mode)
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (insert (drgnx-ui-review-screen--hunk-row "a.rs" 0) (drgnx-ui-review-screen--hunk-row "a.rs" 1)
                         (propertize "Accept   Request changes\n" 'drgnx-action '("accept"))))
               (setq drgnx-review-screen--session "s1")
               (goto-char (point-min))
               ,@body)
           (kill-buffer (current-buffer)))))))

(ert-deftest drgnx-ui-review-screen/D-rejects-one-hunk ()
  (drgnx-ui-review-screen--with calls
    (forward-line 1)
    (drgnx-review-screen-reject-hunk)
    (let ((marks (cl-remove-if-not (lambda (c) (equal (car c) "review/mark")) calls))
          (sends (cl-remove-if-not (lambda (c) (equal (car c) "agents/send")) calls)))
      (should (= 1 (length marks)))
      (should (equal "a.rs#1" (plist-get (cdr (car marks)) :path)))
      (should (equal "pending" (plist-get (cdr (car marks)) :state)))
      (should (= 1 (length sends)))
      (should (string-search "hunk 1" (plist-get (cdr (car sends)) :text))))))

(ert-deftest drgnx-ui-review-screen/a-accepts-one-hunk-with-its-own-hash ()
  (drgnx-ui-review-screen--with calls
    (drgnx-review-screen-accept-hunk)
    (should (= 1 (length calls)))
    (should (equal "a.rs#0" (plist-get (cdr (car calls)) :path)))
    (should (equal "h0" (plist-get (cdr (car calls)) :hash)))
    (should (equal "accepted" (plist-get (cdr (car calls)) :state)))))

(ert-deftest drgnx-ui-review-screen/request-changes-steers-and-does-not-cancel ()
  (drgnx-ui-review-screen--with calls
    (drgnx-review-screen-request-changes)
    (unwind-protect
        (with-current-buffer "*Request changes*"
          (should (derived-mode-p 'drgnx-review-request-mode))
          (should header-line-format)   ; the kit's text-input round the field
          (insert "Please keep the old name")
          (cl-letf (((symbol-function 'quit-window) #'ignore))
            (drgnx-review-request-send))
          (should (equal '("agents/send") (mapcar #'car calls)))
          (should (string-search "Please keep the old name" (plist-get (cdr (car calls)) :text)))
          (should (equal "s1" (plist-get (cdr (car calls)) :id))))
      (when (get-buffer "*Request changes*") (kill-buffer "*Request changes*")))))

(ert-deftest drgnx-ui-review-screen/merge-goes-through-a-card ()
  "Accept, `A', marks hunks and nothing else: no merge, push or git call; and no action on the screen names one."
  (drgnx-ui-review-screen--with calls
    (drgnx-review-screen-accept)
    (should (= 2 (length calls)))
    (should (cl-every (lambda (c) (equal (car c) "review/mark")) calls))
    (should-not (cl-some (lambda (c) (string-match-p "merge\\|push\\|git/" (car c))) calls))
    (let (actions (pos (point-min)))
      (while (< pos (point-max))
        (when-let* ((a (get-text-property pos 'drgnx-action))) (push (car a) actions))
        (setq pos (or (next-single-property-change pos 'drgnx-action) (point-max))))
      (should-not (cl-some (lambda (a) (member a '("merge" "push"))) actions)))))

(provide 'review-screen-gui-test)
;;; review-screen-gui-test.el ends here
