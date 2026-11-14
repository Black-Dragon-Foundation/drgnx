;;; wb-buffers-edge-test.el --- batch tests: the Buffers panel with no hub, edge cases -*- lexical-binding: t -*-
;; test-class: det
;; No hub runs: the panel says it waits for one, what it would send is read where it is queued, and its commands act
;; on the buffers.  The rows from a real hub: wb-buffers-test.el.
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/measure-fixture" drgnx-dir) nil t)
(require 'drgnx-buffers)
(require 'drgnx-explorer)
(require 'drgnx-frames)

(defmacro drgnx-buffers-edge--with (dir &rest body)
  "BODY with a fresh bus, an empty Buffers panel shown in the dock, and a temp DIR for files."
  (declare (indent 1))
  `(drgnx-test-with-state
     (let* ((,dir (make-temp-file "drgnx-buffers-edge" t))
            (drgnx-wb--sections nil) (drgnx-buffers--filter nil) (drgnx-buffers-all-windows nil)
            (drgnx-buffers--ids (make-hash-table :test #'eq :weakness 'key))
            (drgnx-buffers--by-id (make-hash-table :test #'equal :weakness 'value))
            (drgnx-buffers--sent (make-hash-table :test #'eq :weakness 'key))
            (drgnx-buffers--next 0) (drgnx-buffers--ops nil) (drgnx-buffers--scope 'all) (drgnx-buffers--pressed nil))
       (unwind-protect
           (progn
             (delete-other-windows)
             (drgnx-buffers-setup)
             (drgnx-signal--flush)
             (drgnx-wb-show-sidebar)
             ,@body)
         (drgnx-wb-hide-sidebar)
         (delete-other-windows)
         (dolist (b (buffer-list))
           (when (and (buffer-file-name b) (string-prefix-p ,dir (buffer-file-name b)))
             (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
         (when (get-buffer drgnx-buffers-buffer-name) (kill-buffer drgnx-buffers-buffer-name))
         (delete-directory ,dir t)))))

(defun drgnx-buffers-edge--open (dir name)
  (let ((f (expand-file-name name dir)))
    (make-directory (file-name-directory f) t)
    (write-region "x\n" nil f nil 'silent)
    (prog1 (find-file-noselect f) (drgnx-signal--flush))))

(defun drgnx-buffers-edge--header (section)
  (format "%s" (window-parameter (drgnx-wb-section-window section) 'header-line-format)))

(ert-deftest drgnx-buffers/the-filter-title-survives-hide-and-show ()
  (drgnx-buffers-edge--with dir
    (drgnx-buffers-edge--open dir "alpha.txt")
    (drgnx-buffers--filter-apply "alp")
    (should (string-search "alp" (drgnx-buffers-edge--header 'buffers)))
    (drgnx-wb-hide-sidebar)
    (drgnx-wb-show-sidebar)
    (should (string-search "alp" (drgnx-buffers-edge--header 'buffers)))
    (drgnx-buffers--filter-apply nil)
    (drgnx-wb-hide-sidebar)
    (drgnx-wb-show-sidebar)
    (should-not (string-search "alp" (drgnx-buffers-edge--header 'buffers)))
    (should (string-search "Open" (drgnx-buffers-edge--header 'buffers)))))   ; the plain title is back

(ert-deftest drgnx-buffers/the-explorer-find-title-survives-hide-and-show ()
  (drgnx-test-with-state
    (let ((dir (file-name-as-directory (make-temp-file "drgnx-find-edge" t)))
          (drgnx-wb--sections nil) (drgnx-explorer-git nil))
      (unwind-protect
          (progn
            (write-region "x\n" nil (expand-file-name "needle.txt" dir) nil 'silent)
            (delete-other-windows)
            (drgnx-explorer-setup)
            (drgnx-explorer-set-roots (list dir))
            (drgnx-wb-show-sidebar)
            (drgnx-explorer--find-apply "needle")
            (should (string-search "needle" (drgnx-buffers-edge--header 'explorer)))
            (drgnx-wb-hide-sidebar)
            (drgnx-wb-show-sidebar)
            (should (string-search "needle" (drgnx-buffers-edge--header 'explorer))))
        (ignore-errors (drgnx-explorer-find-clear))
        (drgnx-wb-hide-sidebar)
        (drgnx-explorer-set-roots nil)
        (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
        (delete-directory dir t)))))

(defun drgnx-buffers-edge--fake-files (n)
  "N user buffers (visiting files that need not exist), oldest first."
  (cl-loop for i below n
           collect (with-current-buffer (generate-new-buffer (format "drgnx-edge-%d" i))
                     (setq buffer-file-name (format "/nonexistent/drgnx-edge-%d" i))
                     (current-buffer))))

(defun drgnx-buffers-edge--kill (bufs)
  (dolist (b bufs) (with-current-buffer b (set-buffer-modified-p nil) (setq buffer-file-name nil)) (kill-buffer b)))

;;; With the hub down

(ert-deftest drgnx-buffers/with-the-hub-down-the-panel-waits-and-the-commands-work ()
  "No hub: the panel's one line says it waits for the hub, nothing is sent (the reconnect sends the whole set), and
Save All saves."
  (drgnx-buffers-edge--with dir
    (let ((a (drgnx-buffers-edge--open dir "a.txt")))
      (with-current-buffer drgnx-buffers-buffer-name
        (should (overlayp drgnx-buffers--waiting))
        (should (string-search "Waiting for the hub" (overlay-get drgnx-buffers--waiting 'before-string))))
      (drgnx-buffers--send)
      (should-not drgnx-buffers--ops)
      (should (zerop drgnx-buffers--sends))
      (with-current-buffer a (insert "y"))
      (drgnx-buffers-save-all)
      (should-not (buffer-modified-p a)))))

(ert-deftest drgnx-buffers/the-set-is-sent-again-in-open-order ()
  "A reconnect (`drgnx-buffers--resend') sends a reset, then every open buffer in the order it was first seen, the
scope and the filter."
  (drgnx-buffers-edge--with dir
    (let* ((bufs (drgnx-buffers-edge--fake-files 3)) (drgnx-buffers--filter "drgnx"))
      (unwind-protect
          (progn
            (drgnx-buffers--set-changed (list (nth 1 bufs) (nth 0 bufs)))
            (drgnx-buffers--set-changed bufs)
            (drgnx-buffers--resend)
            (let ((ops (reverse drgnx-buffers--ops)))
              (should (equal (plist-get (car ops) :op) "reset"))
              (should (equal (seq-filter (lambda (name) (member name (mapcar #'buffer-name bufs)))
                                         (mapcar (lambda (op) (plist-get op :name))
                                                 (seq-filter (lambda (op) (equal (plist-get op :op) "put")) ops)))
                             (mapcar #'buffer-name (list (nth 1 bufs) (nth 0 bufs) (nth 2 bufs)))))
              (should (equal (car (last ops)) '(:op "filter" :text "drgnx")))))
        (drgnx-buffers-edge--kill bufs)))))

(ert-deftest drgnx-buffers/a-closed-buffer-is-removed-and-forgotten ()
  (drgnx-buffers-edge--with dir
    (let* ((bufs (drgnx-buffers-edge--fake-files 2)) (gone (nth 0 bufs)) (id nil))
      (unwind-protect
          (progn
            (drgnx-buffers--set-changed bufs)
            (setq id (gethash gone drgnx-buffers--ids) drgnx-buffers--ops nil)
            (drgnx-buffers-edge--kill (list gone))
            (drgnx-buffers--set-changed (list (nth 1 bufs)))
            (should (equal drgnx-buffers--ops (list (list :op "remove" :id id))))
            (should-not (gethash id drgnx-buffers--by-id)))
        (drgnx-buffers-edge--kill (seq-filter #'buffer-live-p bufs))))))

(ert-deftest drgnx-buffers/this-windows-scope-names-its-buffers ()
  "With several windows the scope is the ids of the window's buffers (the hub keeps them in open order); with
`drgnx-buffers-all-windows' or one window, all.  Only a change is sent."
  (drgnx-buffers-edge--with dir
    (let ((bufs (drgnx-buffers-edge--fake-files 4)))
      (unwind-protect
          (progn
            (drgnx-buffers--set-changed bufs)
            (cl-letf (((symbol-function 'drgnx-frames-count) (lambda () 2))
                      ((symbol-function 'drgnx-frame-buffers) (lambda (&optional _) (list (nth 3 bufs) (nth 1 bufs)))))
              (should (equal (drgnx-buffers--scope-now)
                             (vector (gethash (nth 3 bufs) drgnx-buffers--ids) (gethash (nth 1 bufs) drgnx-buffers--ids))))
              (setq drgnx-buffers--ops nil)
              (drgnx-buffers--scope-sync)
              (should (equal (plist-get (car drgnx-buffers--ops) :op) "scope"))
              (setq drgnx-buffers--ops nil)
              (drgnx-buffers--scope-sync)
              (should-not drgnx-buffers--ops)
              (let ((drgnx-buffers-all-windows t)) (should (eq (drgnx-buffers--scope-now) 'all)))))
        (drgnx-buffers-edge--kill bufs)))))

(defun drgnx-buffers-edge--alloc (n)
  "What telling the hub about N new buffers, then about the same set again, allocates."
  (let ((bufs (drgnx-buffers-edge--fake-files n)) (best nil))
    (unwind-protect
        (setq best (drgnx-test-alloc
                     (let ((drgnx-buffers--ids (make-hash-table :test #'eq :weakness 'key))
                           (drgnx-buffers--by-id (make-hash-table :test #'equal :weakness 'value))
                           (drgnx-buffers--sent (make-hash-table :test #'eq :weakness 'key))
                           (drgnx-buffers--ops nil))
                       (drgnx-buffers--set-changed bufs)
                       (drgnx-buffers--set-changed bufs))))
      (drgnx-buffers-edge--kill bufs))
    best))

(ert-deftest drgnx-buffers/thousands-of-buffers-stay-linear ()
  ;; M3e-7: membership by hash sets.  Four times the buffers must allocate about four times as much, not
  ;; sixteen (quadratic `memq' filters); allocation does not move with the machine's load, where the wall-clock
  ;; form (7x, and 100 ms for 4000 buffers) missed under it.
  (drgnx-test-compile "drgnx-buffers-" "drgnx-frames")
  (let* ((small (drgnx-buffers-edge--alloc 1000)) (big (drgnx-buffers-edge--alloc 4000)))
    (should (<= big (* 5 small)))))

(provide 'wb-buffers-edge-test)
;;; wb-buffers-edge-test.el ends here
