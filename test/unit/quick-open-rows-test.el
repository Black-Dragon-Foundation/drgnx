;;; quick-open-rows-test.el --- Quick Open and Find ranked by the hub (search/files rows) -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure).  The hub is stubbed: its sender records what was sent and answers nothing (a silent hub), and the
;; patches are fed by hand, as the `view-patch' events would bring them.  The minibuffer is driven by simulated keys.
(require 'ert)
(require 'ert-x)
(require 'cl-lib)
(require 'drgnx-quick-open)
(require 'drgnx-explorer)
(require 'drgnx-view-env)                ; loaded now, so the stubs below are not replaced by a later `require'

(defun quick-open-rows-test--patch (view base version ops &optional hub)
  (list :view view :class "gui-1" :hub (or hub 7) :base base :version version :env_epoch 0 :ops ops))

(defun quick-open-rows-test--row (path) (list :key path :text path))

(defmacro quick-open-rows-test--hub (sent &rest body)
  "BODY with the hub path on and a silent hub: every call it sends is pushed on SENT as (METHOD PARAMS)."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'drgnx-quick-open--hub-p) (lambda (_root) t))
             ((symbol-function 'drgnx-view-env-register) #'ignore)
             ((symbol-function 'drgnx-view-env-unregister) #'ignore))
     (let ((drgnx-quick-open-send-function (lambda (method params) (push (list method params) ,sent))))
       ,@body)))

(ert-deftest drgnx-quick-open/key-never-waits-for-rows ()
  "A key typed with the hub silent returns at once: the input is in the minibuffer and each key sent its query; nothing
waited for rows."
  (let ((sent nil) seen (dir (file-name-as-directory (make-temp-file "drgnx-qo" t))))
    (unwind-protect
        (quick-open-rows-test--hub sent
          (let ((map (make-sparse-keymap)))
            (keymap-set map "<f5>" (lambda () (interactive) (setq seen (minibuffer-contents-no-properties))))
            (cl-letf (((symbol-function 'drgnx-quick-open--root) (lambda () dir)))
              (minibuffer-with-setup-hook (lambda () (use-local-map (make-composed-keymap map (current-local-map))))
                (should (eq (condition-case nil (ert-simulate-keys (vconcat (kbd "m a p <f5> C-g")) (drgnx-quick-open))
                              (quit 'quit))  ; `should-error' takes only errors
                            'quit))))))
      (delete-directory dir t))
    (should (equal seen "map"))
    (let ((queries (mapcar (lambda (s) (plist-get (cadr s) :query))
                           (seq-filter (lambda (s) (equal (car s) "search/files")) (reverse sent)))))
      (should (equal queries '("" "m" "ma" "map"))))
    ;; the view is closed when Quick Open ends
    (should (equal (car (car sent)) "view/close"))))

(ert-deftest drgnx-quick-open/a-greater-than-sign-turns-it-into-the-palette ()
  "As in VS Code: `>' typed first in Quick Open leaves the files for the command palette, with what follows it typed
already.  No file is opened."
  (let ((sent nil) palette opened (dir (file-name-as-directory (make-temp-file "drgnx-qo" t))))
    (unwind-protect
        (quick-open-rows-test--hub sent
          (cl-letf (((symbol-function 'drgnx-quick-open--root) (lambda () dir))
                    ((symbol-function 'drgnx-palette) (lambda (&optional initial) (setq palette (list initial))))
                    ((symbol-function 'find-file) (lambda (f &rest _) (setq opened f))))
            (ert-simulate-keys (vconcat (kbd ">")) (drgnx-quick-open))))
      (delete-directory dir t))
    (should (equal palette '("")))
    (should-not opened)
    ;; the view is closed all the same
    (should (equal (car (car sent)) "view/close"))))

(ert-deftest drgnx-quick-open/old-rows-stay-until-new-arrive ()
  "A new query leaves the rows shown as they are; the patch that answers it changes them."
  (let* ((sent nil) (r (drgnx-quick-open--rows-make "q" "/r/")))
    (quick-open-rows-test--hub sent
      (drgnx-quick-open--rows-patch r (quick-open-rows-test--patch "q" 0 1 (list (list :reset (list (quick-open-rows-test--row "a.rs") (quick-open-rows-test--row "b.rs"))))))
      (should (equal (drgnx-quick-open--rows-candidates r) '("a.rs" "b.rs")))
      (drgnx-quick-open--rows-query r "b")
      (should (equal (drgnx-quick-open--rows-candidates r) '("a.rs" "b.rs")))
      (should (drgnx-quick-open--rows-patch r (quick-open-rows-test--patch "q" 1 2 (list (list :remove '("a.rs"))))))
      (should (equal (drgnx-quick-open--rows-candidates r) '("b.rs"))))))

(ert-deftest drgnx-quick-open/stale-query-rows-are-dropped ()
  "A patch on an older version (an old query's late rows) is dropped, as is one of another view or hub."
  (let ((r (drgnx-quick-open--rows-make "q" "/r/")))
    (drgnx-quick-open--rows-patch r (quick-open-rows-test--patch "q" 0 1 (list (list :reset (list (quick-open-rows-test--row "a.rs"))))))
    (drgnx-quick-open--rows-patch r (quick-open-rows-test--patch "q" 1 2 (list (list :insert (list :after "a.rs" :rows (list (quick-open-rows-test--row "c.rs")))))))
    (should-not (drgnx-quick-open--rows-patch r (quick-open-rows-test--patch "q" 1 2 (list (list :remove '("a.rs"))))))
    (should-not (drgnx-quick-open--rows-patch r (quick-open-rows-test--patch "other" 2 3 (list (list :remove '("a.rs"))))))
    (should-not (drgnx-quick-open--rows-patch r (quick-open-rows-test--patch "q" 2 3 (list (list :remove '("a.rs"))) 8)))
    (should (equal (drgnx-quick-open--rows-candidates r) '("a.rs" "c.rs")))))

(ert-deftest drgnx-quick-open/remote-folder-keeps-project-find-file ()
  "On a remote folder Quick Open is `project-find-file', and the hub is never asked."
  (let ((sent nil) called)
    (cl-letf (((symbol-function 'drgnx-quick-open--root) (lambda () "/ssh:host:/srv/x/"))
              ((symbol-function 'drgnx-view-env-register) #'ignore)
              ((symbol-function 'call-interactively)
               (lambda (f &rest _) (setq called f))))
      (let ((drgnx-quick-open-send-function (lambda (m p) (push (list m p) sent))))
        (drgnx-quick-open)))
    (should (eq called #'project-find-file))
    (should-not sent)))

(ert-deftest drgnx-quick-open/rows-mark-the-words ()
  "A row's runs in `drgnx-quick-open-match' mark the candidate; the candidate is the path."
  (let ((r (drgnx-quick-open--rows-make "q" "/r/")))
    (drgnx-quick-open--rows-patch r (quick-open-rows-test--patch "q" 0 1 (list (list :reset (list (list :key "src/map.rs" :text "src/map.rs" :runs '((4 7 "drgnx-quick-open-match"))))))))
    (let ((c (car (drgnx-quick-open--rows-candidates r))))
      (should (equal c "src/map.rs"))
      (should (memq 'drgnx-quick-open-match (ensure-list (get-text-property 4 'face c))))
      (should-not (get-text-property 0 'face c)))))

(ert-deftest drgnx-explorer-find/rows-come-from-search-files ()
  "Find asks the hub for each root's files that hold the query (search/files) and filters the tree by the rows it
answers; nothing lists the folder in Lisp."
  (let ((sent nil) (root (file-name-as-directory (make-temp-file "drgnx-find" t))))
    (unwind-protect
        (quick-open-rows-test--hub sent
          (cl-letf (((symbol-function 'drgnx-file-stream-start) (lambda (&rest _) (error "Listed in Lisp")))
                    ((symbol-function 'drgnx-explorer--root-files) (lambda (&rest _) (error "Listed in Lisp"))))
            (let ((drgnx-explorer--roots (list root)) (drgnx-explorer--find nil) (drgnx-explorer--find-views nil))
              (drgnx-explorer--find-apply "map")
              (let ((q (seq-find (lambda (s) (equal (car s) "search/files")) sent)))
                (should q)
                (should (equal (plist-get (cadr q) :query) "map"))
                (should (equal (plist-get (cadr q) :root) root))
                (drgnx-explorer--find-event
                 "view-patch" (quick-open-rows-test--patch (plist-get (cadr q) :view) 0 1
                                                           (list (list :reset (list (quick-open-rows-test--row "src/map.rs")))))))
              (should (equal (plist-get drgnx-explorer--find :files) (list (concat root "src/map.rs")))))))
      (remove-hook 'drgnx-hub-event-functions #'drgnx-explorer--find-event)
      (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
      (delete-directory root t))))

;;; quick-open-rows-test.el ends here
