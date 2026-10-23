;;; work-fixture.el --- test tooling: schema-6 tracker rows written by hand, and a stand-in for the hub -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The editor no longer writes the tracker's nodes and edges (the hub does: graph/put-parsed, graph/record).  Tests
;; that need rows write them here, into a schema-6 work.db made by the local writer (`drgnx-work-db'), and tests of
;; code that sends to the hub run it under `drgnx-work-fixture-with-hub': the hub's calls are answered by a small
;; applier that stores what the real hub stores (the rows only; the real hub is tested by the binary tests).

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-work-db)
(require 'drgnx-hub-client)

(defconst drgnx-work-fixture--columns '(:kind :title :path :line :status :parent :ord :source))

(defun drgnx-work-fixture-put-node (id &rest props)
  "Insert or replace node ID with PROPS (:kind :title :path :line :status :parent :ord :source and
any other keys, kept in its data)."
  (let ((data (cl-loop for (k v) on props by #'cddr unless (memq k drgnx-work-fixture--columns) append (list k v))))
    (sqlite-execute (drgnx-work-db)
                    "insert or replace into node values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                    (list id (and (plist-get props :kind) (symbol-name (plist-get props :kind)))
                          (plist-get props :title) (plist-get props :path) (plist-get props :line)
                          (plist-get props :status) (plist-get props :parent) (plist-get props :ord)
                          (plist-get props :source)
                          (and data (drgnx-records-encode 'drgnx-records-node-data data)) (float-time)))))

(defun drgnx-work-fixture-update-node (id &rest props)
  "Change PROPS of node ID (columns and data), keeping the rest."
  (when-let* ((n (drgnx-work-node id)))
    (cl-loop for (k v) on props by #'cddr do (setq n (plist-put n k v)))
    (apply #'drgnx-work-fixture-put-node id (cl-loop for (k v) on n by #'cddr unless (eq k :id) append (list k v)))))

(defun drgnx-work-fixture-put-edge (src dst kind origin &optional source)
  "The KIND edge SRC → DST, from ORIGIN (`parsed', `inferred', `recorded'): a recorded edge stays recorded."
  (sqlite-execute (drgnx-work-db) "insert into edge values (?, ?, ?, ?, ?) on conflict (src, dst, kind)
                                   do update set origin = excluded.origin, source = excluded.source where edge.origin <> 'recorded'"
                  (list src dst (symbol-name kind) (symbol-name origin) (or source (symbol-name origin)))))

(defun drgnx-work-fixture-forget-source (source)
  "Forget every node and edge SOURCE gave."
  (sqlite-execute (drgnx-work-db) "delete from node where source = ?" (list source))
  (sqlite-execute (drgnx-work-db) "delete from edge where source = ?" (list source)))

(defun drgnx-work-fixture-forget-orphan-commits ()
  "Forget the commits no edge links any more."
  (sqlite-execute (drgnx-work-db) "delete from node where kind = 'commit' and id not in (select src from edge)"))

(defun drgnx-work-fixture-set-file (path mtime) (sqlite-execute (drgnx-work-db) "insert or replace into file values (?, ?)" (list path mtime)))
(defun drgnx-work-fixture-drop-file (path) (sqlite-execute (drgnx-work-db) "delete from file where path = ?" (list path)))

;;;; The hub's side, as far as the rows go

(defun drgnx-work-fixture--list (v) (append v nil))

(defun drgnx-work-fixture--source-text (ref)
  (pcase (plist-get ref :kind)
    ("file" (plist-get ref :path))
    ("spec" (concat "spec " (plist-get ref :path)))
    (k k)))

(defun drgnx-work-fixture--put (params)
  "What graph/put-parsed stores of PARAMS (a plist): the schema-6 rows."
  (let ((sent nil) (changed 0))
    (dolist (g (drgnx-work-fixture--list (plist-get params :gone)))
      (drgnx-work-fixture-forget-source (drgnx-work-fixture--source-text g))
      (drgnx-work-fixture-drop-file (plist-get g :path)))
    (dolist (s (drgnx-work-fixture--list (plist-get params :sources)))
      (let* ((ref (plist-get s :source)) (text (drgnx-work-fixture--source-text ref)) (kind (plist-get ref :kind)))
        (when (member kind '("file" "spec")) (drgnx-work-fixture-forget-source text))
        (dolist (e (drgnx-work-fixture--list (plist-get s :entities)))
          (push (plist-get e :id) sent)
          (cl-incf changed)
          (unless (equal (plist-get e :kind) "file")
            (apply #'drgnx-work-fixture-put-node (plist-get e :id)
                   :kind (intern (plist-get e :kind)) :title (plist-get e :title) :status (plist-get e :status) :source text
                   (cl-loop for (k v) on (plist-get e :data) by #'cddr unless (memq v '(:null :false)) append (list k v)))))
        (dolist (l (drgnx-work-fixture--list (plist-get s :links)))
          (drgnx-work-fixture-put-edge (string-remove-prefix "file:" (plist-get l :src)) (string-remove-prefix "file:" (plist-get l :dst))
                                       (intern (plist-get l :kind)) (intern (or (plist-get l :origin) "parsed")) text))
        (when (and (plist-get s :mtime) (member kind '("file" "spec")))
          (drgnx-work-fixture-set-file (plist-get ref :path) (plist-get s :mtime)))))
    (dolist (u (drgnx-work-fixture--list (plist-get params :updates)))
      (let ((props (and (plist-get u :status) (list :status (plist-get u :status)))))
        (cl-loop for (k v) on (plist-get u :data_patch) by #'cddr
                 do (setq props (append props (list k (if (memq v '(:null :false)) nil v)))))
        (apply #'drgnx-work-fixture-update-node (plist-get u :id) props)
        (cl-incf changed)))
    (dolist (k (drgnx-work-fixture--list (plist-get params :collected)))
      (sqlite-execute (drgnx-work-db) "insert or replace into meta values (?, 'collected')" (list k)))
    ;; the cleanups: a commit no link names, a spec nothing derives from outside a specs/ folder (but what was sent)
    (drgnx-work-fixture-forget-orphan-commits)
    (dolist (s (sqlite-select (drgnx-work-db) "select id, path from node where kind = 'spec'"))
      (unless (or (member (car s) sent) (string-match-p "/specs/" (cadr s))
                  (sqlite-select (drgnx-work-db) "select 1 from edge where dst = ? and kind = 'derives'" (list (car s))))
        (drgnx-work-fixture-forget-source (concat "spec " (cadr s)))
        (drgnx-work-fixture-drop-file (cadr s))))
    (list :changed changed :retired 0 :refused [])))

(defun drgnx-work-fixture--record (params)
  "What graph/record stores of PARAMS: the commits and their recorded links; (:ids [...])."
  (let ((task (plist-get params :task)) (repo (plist-get params :repo)) ids)
    (dolist (c (drgnx-work-fixture--list (plist-get params :commits)))
      (let ((id (concat "commit:" (plist-get c :sha))))
        (drgnx-work-fixture-put-node id :kind 'commit :title (plist-get c :subject) :path repo :source "commit"
                                     :sha (plist-get c :sha) :date (plist-get c :date) :repo repo :seq (plist-get c :seq))
        (drgnx-work-fixture-put-edge id task 'implements 'recorded "recorded")
        (push id ids)))
    (when (plist-get params :collected)
      (sqlite-execute (drgnx-work-db) "insert or replace into meta values (?, 'collected')" (list (plist-get params :collected))))
    (list :ids (vconcat (nreverse ids)))))

(defvar drgnx-work-fixture-calls nil "The hub calls made under `drgnx-work-fixture-with-hub', newest first: (METHOD . PARAMS).")

(defun drgnx-work-fixture--apply (method params)
  (push (cons method params) drgnx-work-fixture-calls)
  (pcase method
    ("graph/put-parsed" (drgnx-work-fixture--put params))
    ("graph/record" (drgnx-work-fixture--record params))
    (_ nil)))

(defmacro drgnx-work-fixture-with-hub (&rest body)
  "Run BODY with the hub's graph calls answered by the applier above (and `drgnx-hub-ensure' a success)."
  (declare (indent 0))
  `(let ((drgnx-work-fixture-calls nil))
     (cl-letf (((symbol-function 'drgnx-hub-ensure) (lambda () t))
               ((symbol-function 'drgnx-hub-call-sync)
                (lambda (method params &optional _timeout) (drgnx-work-fixture--apply method params)))
               ((symbol-function 'drgnx-hub-call)
                (lambda (method params callback &rest _) (funcall callback (drgnx-work-fixture--apply method params) nil) 1)))
       ,@body)))

(provide 'work-fixture)
;;; work-fixture.el ends here
