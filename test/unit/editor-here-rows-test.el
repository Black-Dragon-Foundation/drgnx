;;; editor-here-rows-test.el --- who is here from the hub's rows -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  The hub's `view-patch'es for the view `agents-here' (its data class) arrive as the event would
;; bring them; the hub's calls are recorded.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(require 'drgnx-view)
(load (expand-file-name "modules/ui/drgnx-statusbar" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agents-in-editor))

(declare-function drgnx-agents-editor-here--event "drgnx-agents-editor-here")
(declare-function drgnx-agents-editor-here--subscribe "drgnx-agents-editor-here")
(declare-function drgnx-agents-editor-here--rows-buffer "drgnx-agents-editor-here")
(defvar drgnx-agents-editor-here--rows)
(defvar drgnx-agents-editor-here--badges)
(defvar drgnx-agents-editor-here--status)
(defvar drgnx-agents-editor-here-ordinal-function)
(defvar drgnx-view-old-path)
(defvar drgnx-hub--events)

(defmacro drgnx-editor-here-rows-test--with (&rest body)
  "BODY with the module on, a workspace whose one root is `root', the hub's calls recorded in `calls' (METHOD .
PARAMS), the subscribed connection a live pipe and `rebuilds' counting `drgnx-agents-editor-here--rebuild'."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "here-rows" t))))
          (conn (make-pipe-process :name "here-rows" :noquery t)) (calls nil) (rebuilds 0))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) 1)))
           (drgnx-test-with-modules '(tools/agents-in-editor)
             (cl-letf (((symbol-function 'drgnx-work-space-workspace)
                        (lambda (&rest _) (list :id "workspace:000000000000" :roots (list root))))
                       ((symbol-function 'drgnx-hub--call-on)
                        (lambda (_p method params &rest _) (push (cons method params) calls) 1))
                       ((symbol-function 'drgnx-agents-editor-here--rebuild) (lambda () (cl-incf rebuilds))))
               (let ((drgnx-view-old-path nil) (drgnx-hub--events conn)
                     (drgnx-agents-editor-here-ordinal-function (lambda (s) (and (equal s "s1") 1))))
                 ,@body))))
       (delete-process conn)
       (delete-directory root t))))

(defun drgnx-editor-here-rows-test--agent (sid ord mode file line)
  (let ((text (format "Agent · %s · %s:%d" mode (file-name-nondirectory file) line)))
    (list :key (concat "a:" sid) :text text
          :props (list (list 0 (length text) "drgnx-presence-session" sid)
                       (list 0 (length text) "drgnx-presence-ordinal" ord)
                       (list 0 (length text) "drgnx-presence-mode" mode)
                       (list 0 (length text) "drgnx-presence-file" file)
                       (list 0 (length text) "drgnx-presence-line" line)))))

(defun drgnx-editor-here-rows-test--path (path ords dir)
  (list :key (concat "p:" path) :text path
        :props (list (list 0 (length path) "drgnx-presence-ordinals" ords)
                     (list 0 (length path) "drgnx-presence-dir" (and dir t)))))

(cl-defun drgnx-editor-here-rows-test--patch (ops &key (hub 7) (base 0) (version 1))
  (list :view "agents-here" :class "data" :hub hub :base base :version version :env_epoch 1 :ops ops))

(ert-deftest drgnx-agents-editor-here/rows-applied-not-rebuilt ()
  "The hub's rows give who is here, the badges and the status segment path by path: a reset, then a replace of one
file's row, then its removal; nothing is rebuilt from the cached presence, and `agent-presence' is the cursors' only."
  (drgnx-editor-here-rows-test--with
    (drgnx-agents-editor-here--subscribe)
    (should (equal (mapcar #'car (reverse calls)) '("view/env" "agents/presence/subscribe")))
    (should (equal "agents-here" (plist-get (cdr (assoc "agents/presence/subscribe" calls)) :view)))
    (let ((file (concat root "src/a.el")) (dir (concat root "src")))
      (drgnx-view-apply-patch
       (drgnx-editor-here-rows-test--patch
        (list (list :reset (list (drgnx-editor-here-rows-test--agent "s1" 1 "edit" file 3)
                                 (drgnx-editor-here-rows-test--path dir '(1) t)
                                 (drgnx-editor-here-rows-test--path file '(1) nil))))))
      (should (equal (mapcar (lambda (r) (list (nth 0 r) (nth 1 r) (nth 3 r) (nth 4 r))) drgnx-agents-editor-here--rows)
                     (list (list "s1" 1 file 3))))
      (should (gethash file drgnx-agents-editor-here--badges))
      (should (gethash dir drgnx-agents-editor-here--badges))
      (should drgnx-agents-editor-here--status)
      ;; a replace of the file's row: only its badge is made again
      (let ((dir-badge (gethash dir drgnx-agents-editor-here--badges)))
        (drgnx-view-apply-patch
         (drgnx-editor-here-rows-test--patch
          (list (list :replace (list (drgnx-editor-here-rows-test--path file '(1 2) nil))))
          :base 1 :version 2))
        (should (eq dir-badge (gethash dir drgnx-agents-editor-here--badges))))
      (drgnx-view-apply-patch
       (drgnx-editor-here-rows-test--patch (list (list :remove (list (concat "p:" file)))) :base 2 :version 3))
      (should-not (gethash file drgnx-agents-editor-here--badges))
      ;; the old feed changes nothing here
      (drgnx-agents-editor-here--event "agent-presence" (list :file file :entries (list (list :session "s1" :mode "edit"))))
      (should (= 0 rebuilds)))))

(ert-deftest drgnx-agents-editor-here/reconnect-redraws-from-reset ()
  "A new hub: the connection's hook subscribes again (the data class's env first), and the new hub's reset replaces
everything held, badges of paths it no longer names included."
  (drgnx-editor-here-rows-test--with
    (let ((old (concat root "old.el")) (new (concat root "new.el")))
      (drgnx-agents-editor-here--subscribe)
      (drgnx-view-apply-patch
       (drgnx-editor-here-rows-test--patch
        (list (list :reset (list (drgnx-editor-here-rows-test--agent "s1" 1 "edit" old 1)
                                 (drgnx-editor-here-rows-test--path old '(1) nil))))))
      (should (gethash old drgnx-agents-editor-here--badges))
      (setq calls nil)
      (run-hooks 'drgnx-hub-connected-functions)
      (should (equal (mapcar #'car (reverse calls)) '("view/env" "agents/presence/subscribe")))
      (drgnx-view-apply-patch
       (drgnx-editor-here-rows-test--patch
        (list (list :reset (list (drgnx-editor-here-rows-test--agent "s1" 1 "pending" new 9)
                                 (drgnx-editor-here-rows-test--path new '(1) nil))))
        :hub 8))
      (should-not (gethash old drgnx-agents-editor-here--badges))
      (should (gethash new drgnx-agents-editor-here--badges))
      (should (equal (nth 3 (car drgnx-agents-editor-here--rows)) new))
      (should (= 0 rebuilds)))))

;;; editor-here-rows-test.el ends here
