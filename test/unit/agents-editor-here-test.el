;;; agents-editor-here-test.el --- Explorer badges, the status segment, who is here -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  Presence arrives as the hub's `agent-presence' events would; the hub's calls are recorded.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(load (expand-file-name "modules/ui/drgnx-statusbar" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agents-in-editor))

(declare-function drgnx-explorer-add-decorator "drgnx-explorer")
(declare-function drgnx-explorer-remove-decorator "drgnx-explorer")
(declare-function drgnx-agents-editor-here--event "drgnx-agents-editor-here")
(declare-function drgnx-agents-editor-here--user-path "drgnx-agents-editor-here")
(declare-function drgnx-agents-editor-here-choose "drgnx-agents-editor-here")
(declare-function drgnx-agents-editor--event "drgnx-agents-editor")
(declare-function drgnx-agents-editor-ordinal "drgnx-agents-editor")
(defvar drgnx-agents-editor-here--rows)
(defvar drgnx-agent-identity-sessions-function)
(defvar drgnx-agents-editor-here--badges)
(defvar drgnx-agents-editor-here--status)
(defvar drgnx-agents-editor-here--tops)
(defvar drgnx-agents-editor-followed)
(defvar drgnx-explorer-decorators)
(defvar drgnx-statusbar-left)

(defvar drgnx-agents-editor-here-test--root nil)

(defmacro drgnx-agents-editor-here-test--with (&rest body)
  "BODY with the module on, a workspace whose one root is a temp directory (`root') and the hub's calls absorbed."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "agents-here" t)))))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) 1)))
           (drgnx-test-with-modules '(tools/agents-in-editor)
             ;; the workspace: one root (the function is the work space module's, so it is stubbed inside)
             (cl-letf (((symbol-function 'drgnx-work-space-workspace)
                        (lambda (&rest _) (list :id "workspace:000000000000" :roots (list root)))))
               ,@body)))
       (delete-directory root t))))

(defun drgnx-agents-editor-here-test--presence (file &rest entries)
  "Feed the module `agent-presence' data for FILE: ENTRIES are (SESSION MODE LINE).  A session the hub has not named
yet gets the next ordinal first, as its `agent' snapshot would give it."
  (dolist (e entries)
    (unless (drgnx-agents-editor-ordinal (nth 0 e))
      (drgnx-agents-editor-here-test--snapshot
       (nth 0 e) (1+ (length (funcall drgnx-agent-identity-sessions-function))))))
  (apply #'drgnx-agents-editor-here-test--presence-raw file entries))

(defun drgnx-agents-editor-here-test--presence-raw (file &rest entries)
  "Feed the module `agent-presence' data for FILE: ENTRIES are (SESSION MODE LINE), named or not."
  (drgnx-agents-editor-here--event
   "agent-presence"
   (list :file file :rel nil
         :entries (mapcar (lambda (e) (list :session (nth 0 e) :file file :mode (nth 1 e) :line (nth 2 e) :at 1.0 :source "edit"))
                          entries))))

(defun drgnx-agents-editor-here-test--snapshot (sid ordinal &optional last-active)
  "Feed the module the hub's `agent' snapshot of SID with ORDINAL (nil: the session ended) and LAST-ACTIVE."
  (drgnx-agents-editor--event "agent" (list :id sid :session (list :id sid :ordinal ordinal :last_active (or last-active 1.0)))))

(defun drgnx-agents-editor-here-test--marks (s)
  "How many agent marks S holds."
  (let ((n 0) (in nil))
    (dotimes (i (length s))
      (let ((has (and (get-text-property i 'face s) t)))
        (when (and has (not in)) (cl-incf n))
        (setq in has)))
    n))

(ert-deftest drgnx-explorer/decorators-add-and-remove-cleanly ()
  (require 'drgnx-explorer)
  (let ((before drgnx-explorer-decorators))
    (drgnx-explorer-add-decorator #'ignore)
    (drgnx-explorer-add-decorator #'ignore)
    (should (equal (append before '(ignore)) drgnx-explorer-decorators))
    (drgnx-explorer-remove-decorator #'ignore)
    (should (equal before drgnx-explorer-decorators))))

(ert-deftest drgnx-agents-editor/agents-here-segment-sits-after-agents ()
  (let ((before (copy-sequence drgnx-statusbar-left)))
    (drgnx-agents-editor-here-test--with
      (let ((tail (memq 'agents drgnx-statusbar-left)))
        (should tail)
        (should (eq 'agents-here (cadr tail)))
        (should (gethash 'agents-here drgnx-statusbar--segments))))
    (should (equal before drgnx-statusbar-left))
    (should-not (gethash 'agents-here drgnx-statusbar--segments))))

(ert-deftest drgnx-agents-editor/badges-overflow-to-plus-n ()
  (drgnx-agents-editor-here-test--with
    (let ((file (expand-file-name "a.el" root)))
      (drgnx-agents-editor-here-test--presence file '("s1" "edit" 3) '("s2" "write" 4) '("s3" "edit" 5) '("s4" "edit" 6))
      (let ((badge (gethash file drgnx-agents-editor-here--badges)))
        (should (string-search "+1" badge))
        (should (= 3 (drgnx-agents-editor-here-test--marks (substring badge 0 (string-search "+1" badge))))))
      ;; a read is no badge
      (drgnx-agents-editor-here-test--presence file '("s1" "read" 3))
      (should-not (gethash file drgnx-agents-editor-here--badges)))))

(ert-deftest drgnx-agents-editor/folder-dots-per-agent ()
  (drgnx-agents-editor-here-test--with
    (let ((a (expand-file-name "src/deep/a.el" root)) (b (expand-file-name "src/b.el" root)))
      (drgnx-agents-editor-here-test--presence a '("s1" "edit" 1))
      (drgnx-agents-editor-here-test--presence b '("s2" "edit" 1) '("s1" "edit" 2))
      (let ((src (gethash (concat root "src") drgnx-agents-editor-here--badges))
            (deep (gethash (concat root "src/deep") drgnx-agents-editor-here--badges)))
        (should (= 2 (drgnx-agents-editor-here-test--marks src)))
        (should (= 1 (drgnx-agents-editor-here-test--marks deep)))
        (should (gethash (directory-file-name root) drgnx-agents-editor-here--badges))))))

(ert-deftest drgnx-agents-editor/status-marks-overflow ()
  (drgnx-agents-editor-here-test--with
    (dotimes (i 10)
      (drgnx-agents-editor-here-test--presence (expand-file-name (format "f%d.el" i) root) (list (format "s%d" i) "edit" 1)))
    (should (string-search "+2" drgnx-agents-editor-here--status))
    (should (= 8 (drgnx-agents-editor-here-test--marks (substring drgnx-agents-editor-here--status 0
                                                                  (string-search "+2" drgnx-agents-editor-here--status)))))
    (should (equal drgnx-agents-editor-here--status (drgnx-agents-editor-here--segment)))))

(ert-deftest drgnx-agents-editor/who-is-here-row-follows-on-ret ()
  (drgnx-agents-editor-here-test--with
    (let ((file (expand-file-name "a.el" root)) (asked nil))
      (write-region "one\ntwo\nthree\nfour\n" nil file nil 'silent)
      (unwind-protect
          (save-window-excursion
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt candidates &rest _) (setq asked candidates) (car candidates))))
              (drgnx-agents-editor-here-choose (list (list "s1" 1 "edit" file 3))))
            (should (= 1 (length asked)))
            (should (equal "s1" drgnx-agents-editor-followed))
            (should (equal file (buffer-file-name)))
            (should (= 3 (line-number-at-pos))))
        (when-let* ((b (get-file-buffer file))) (kill-buffer b))))))

(ert-deftest drgnx-agents-editor/ordinals-come-from-the-hubs-snapshots ()
  (drgnx-agents-editor-here-test--with
    (let ((file (expand-file-name "a.el" root))
          (by-ordinal (lambda (l) (sort (copy-sequence l) (lambda (a b) (< (car a) (car b)))))))
      (drgnx-agents-editor-here-test--snapshot "s1" 4 20.0)
      (drgnx-agents-editor-here-test--snapshot "s2" 2 10.0)
      ;; identity's reuse past capacity reads the live sessions and when each was last active
      (should (equal '((2 . 10.0) (4 . 20.0)) (funcall by-ordinal (funcall drgnx-agent-identity-sessions-function))))
      (drgnx-agents-editor-here-test--presence-raw file '("s1" "edit" 3) '("s2" "edit" 4))
      (should (equal '(2 4) (mapcar #'cadr drgnx-agents-editor-here--rows)))
      ;; an agent the hub has not named yet gets no mark; its snapshot gives it its own
      (drgnx-agents-editor-here-test--presence-raw file '("s1" "edit" 3) '("s3" "edit" 5))
      (should (equal '(4) (mapcar #'cadr drgnx-agents-editor-here--rows)))
      (drgnx-agents-editor-here-test--snapshot "s3" 1 30.0)
      (should (equal '(1 4) (mapcar #'cadr drgnx-agents-editor-here--rows)))
      ;; an ended session has no ordinal any more
      (drgnx-agents-editor-here-test--snapshot "s1" nil)
      (should (equal '((1 . 30.0) (2 . 10.0)) (funcall by-ordinal (funcall drgnx-agent-identity-sessions-function))))
      (should (equal '(1) (mapcar #'cadr drgnx-agents-editor-here--rows)))))
  (should-not drgnx-agent-identity-sessions-function))

(ert-deftest drgnx-agents-editor/a-worktree-agents-file-lands-on-the-users-tree ()
  ;; the [B] row, with a real hub, comes with the hub's presence feed; this one has a real git worktree
  (drgnx-agents-editor-here-test--with
    (let* ((default-directory root) (tree (file-name-as-directory (expand-file-name "wt/" (file-name-directory (directory-file-name root))))))
      (should (zerop (call-process "git" nil nil nil "init" "-q")))
      (write-region "x\n" nil (expand-file-name "a.el" root) nil 'silent)
      (should (zerop (call-process "git" nil nil nil "add" "a.el")))
      (should (zerop (call-process "git" nil nil nil "-c" "user.name=t" "-c" "user.email=t@t.invalid" "-c" "commit.gpgsign=false"
                                   "commit" "-q" "-m" "base")))
      (unwind-protect
          (progn
            (should (zerop (call-process "git" nil nil nil "worktree" "add" "-q" "-b" "agent-b" (directory-file-name tree))))
            (let ((path (drgnx-agents-editor-here--user-path (list :file (concat tree "a.el") :rel "a.el") (list root))))
              (should (equal (concat root "a.el") path))))
        (ignore-errors (delete-directory tree t))))))

(provide 'agents-editor-here-test)
;;; agents-editor-here-test.el ends here
