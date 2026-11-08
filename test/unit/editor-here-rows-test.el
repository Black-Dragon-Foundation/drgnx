;;; editor-here-rows-test.el --- who is here from the hub's view model -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  The hub's `view-model's and `view-patch'es for the view `agents-here' (its data class) arrive as
;; the events would bring them; the hub's calls are recorded.  Needs Sjá (a Nidhogg with `nidhogg-view--call'); the
;; tests are skipped elsewhere.
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
(defvar drgnx-view-patch--buffers)
(defvar drgnx-view-model--views)
(defvar drgnx-view-patch--hooked)
(declare-function drgnx-agents-editor-here--take "drgnx-agents-editor-here")

(defmacro drgnx-editor-here-rows-test--with (&rest body)
  "BODY with the module on, a workspace whose one root is `root', the hub's calls recorded in `calls' (METHOD .
PARAMS), the subscribed connection a live pipe and `rebuilds' counting `drgnx-agents-editor-here--rebuild'."
  (declare (indent 0))
  `(let* ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
          (drgnx-view-model--views (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
          (root (file-name-as-directory (file-truename (make-temp-file "here-rows" t))))
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

(defconst drgnx-editor-here-rows-test--descriptor
  (list :scheme "tree" :chain_kinds [] :match_fields ["label"] :lists ["agents" "paths"] :classes ["selected"]
        :flags [] :forms [] :start "agents")
  "The descriptor of the hub's model of who is here.")

(defun drgnx-editor-here-rows-test--agent (sid ord mode file line)
  "The model's node of agent SID."
  (list :id (concat "a:" sid) :kind "agent" :flags 0
        :fields (vector (vector "label" "Agent") (vector "session" sid) (vector "ordinal" ord) (vector "mode" mode)
                        (vector "file" file) (vector "line" line))))

(defun drgnx-editor-here-rows-test--path (path ords dir)
  "The model's node of PATH, shown with the agents ORDS (DIR: a folder)."
  (list :id (concat "p:" path) :kind (if dir "folder" "file") :flags 0
        :fields (vector (vector "path" path) (vector "ordinals" (mapconcat #'number-to-string ords " ")))))

(defun drgnx-editor-here-rows-test--lists (agents paths)
  (list (list :list (list :name "agents" :ids (vconcat (mapcar (lambda (n) (plist-get n :id)) agents))))
        (list :list (list :name "paths" :ids (vconcat (mapcar (lambda (n) (plist-get n :id)) paths))))))

(defun drgnx-editor-here-rows-test--reset (agents paths)
  "A reset op of the model to AGENTS and PATHS (nodes)."
  (list :reset (list :descriptor drgnx-editor-here-rows-test--descriptor :nodes (vconcat agents paths) :edges []
                     :lists (vconcat (mapcar (lambda (l) (plist-get l :list))
                                             (drgnx-editor-here-rows-test--lists agents paths))))))

(defun drgnx-editor-here-rows-test--row (node)
  "NODE's row: its key and text only (what it says is the model's)."
  (let ((key (plist-get node :id)))
    (list :key key :text key :props (list (list 0 (length key) "drgnx-work-id" key)))))

(cl-defun drgnx-editor-here-rows-test--send (model ops &key (hub 7) (base 0) (version 1))
  "The hub's MODEL ops, then the rows OPS naming it, then the module's step after the draw."
  (drgnx-view-model-event (list :view "agents-here" :hub hub :base base :version version :reset (and (eql base 0) t)
                                :model (json-serialize (list :ops (vconcat model)))))
  (drgnx-view-apply-patch (list :view "agents-here" :class "data" :hub hub :base base :version version :env_epoch 1
                                :model version :ops ops))
  (drgnx-agents-editor-here--take))

(ert-deftest drgnx-agents-editor-here/rows-applied-not-rebuilt ()
  "The hub's model gives who is here, the badges and the status segment path by path, as its rows name them: a reset,
then a change of one file's node, then its removal; nothing is rebuilt from the cached presence, and `agent-presence'
is the cursors' only."
  (skip-unless (fboundp 'nidhogg-view--call))
  (drgnx-editor-here-rows-test--with
    (drgnx-agents-editor-here--subscribe)
    (should (equal (mapcar #'car (reverse calls)) '("view/env" "agents/presence/subscribe")))
    (should (equal "agents-here" (plist-get (cdr (assoc "agents/presence/subscribe" calls)) :view)))
    (let* ((file (concat root "src/a.el")) (dir (concat root "src"))
           (agent (drgnx-editor-here-rows-test--agent "s1" 1 "edit" file 3))
           (dnode (drgnx-editor-here-rows-test--path dir '(1) t))
           (fnode (drgnx-editor-here-rows-test--path file '(1) nil)))
      (drgnx-editor-here-rows-test--send
       (list (drgnx-editor-here-rows-test--reset (list agent) (list dnode fnode)))
       (list (list :reset (mapcar #'drgnx-editor-here-rows-test--row (list agent dnode fnode)))))
      (should (equal (mapcar (lambda (r) (list (nth 0 r) (nth 1 r) (nth 3 r) (nth 4 r))) drgnx-agents-editor-here--rows)
                     (list (list "s1" 1 file 3))))
      (should (gethash file drgnx-agents-editor-here--badges))
      (should (gethash dir drgnx-agents-editor-here--badges))
      (should drgnx-agents-editor-here--status)
      ;; one file's node changes: only its badge is made again
      (let ((dir-badge (gethash dir drgnx-agents-editor-here--badges))
            (file-badge (gethash file drgnx-agents-editor-here--badges)))
        (drgnx-editor-here-rows-test--send
         (list (list :nodes (vector (drgnx-editor-here-rows-test--path file '(1 2) nil))))
         (list (list :replace (list (drgnx-editor-here-rows-test--row fnode))))
         :base 1 :version 2)
        (should (eq dir-badge (gethash dir drgnx-agents-editor-here--badges)))
        (should-not (equal file-badge (gethash file drgnx-agents-editor-here--badges))))
      (drgnx-editor-here-rows-test--send
       (cons (list :remove (vector (concat "p:" file))) (cdr (drgnx-editor-here-rows-test--lists (list agent) (list dnode))))
       (list (list :remove (list (concat "p:" file))))
       :base 2 :version 3)
      (should-not (gethash file drgnx-agents-editor-here--badges))
      (should (gethash dir drgnx-agents-editor-here--badges))
      ;; the old feed changes nothing here
      (drgnx-agents-editor-here--event "agent-presence" (list :file file :entries (list (list :session "s1" :mode "edit"))))
      (should (= 0 rebuilds)))))

(ert-deftest drgnx-agents-editor-here/reconnect-redraws-from-reset ()
  "A new hub: the connection's hook subscribes again (the data class's env first), and the new hub's reset replaces
everything held, badges of paths it no longer names included."
  (skip-unless (fboundp 'nidhogg-view--call))
  (drgnx-editor-here-rows-test--with
    (let* ((old (concat root "old.el")) (new (concat root "new.el"))
           (a1 (drgnx-editor-here-rows-test--agent "s1" 1 "edit" old 1))
           (p1 (drgnx-editor-here-rows-test--path old '(1) nil))
           (a2 (drgnx-editor-here-rows-test--agent "s1" 1 "pending" new 9))
           (p2 (drgnx-editor-here-rows-test--path new '(1) nil)))
      (drgnx-agents-editor-here--subscribe)
      (drgnx-editor-here-rows-test--send
       (list (drgnx-editor-here-rows-test--reset (list a1) (list p1)))
       (list (list :reset (mapcar #'drgnx-editor-here-rows-test--row (list a1 p1)))))
      (should (gethash old drgnx-agents-editor-here--badges))
      (setq calls nil)
      (run-hooks 'drgnx-hub-connected-functions)
      (should (equal (mapcar #'car (reverse calls)) '("view/env" "agents/presence/subscribe")))
      (drgnx-editor-here-rows-test--send
       (list (drgnx-editor-here-rows-test--reset (list a2) (list p2)))
       (list (list :reset (mapcar #'drgnx-editor-here-rows-test--row (list a2 p2))))
       :hub 8)
      (should-not (gethash old drgnx-agents-editor-here--badges))
      (should (gethash new drgnx-agents-editor-here--badges))
      (should (equal (nth 3 (car drgnx-agents-editor-here--rows)) new))
      (should (= 0 rebuilds)))))

;;; editor-here-rows-test.el ends here
