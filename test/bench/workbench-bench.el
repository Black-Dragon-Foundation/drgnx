;;; workbench-bench.el --- In-session part of `drgnx test --bench' -*- lexical-binding: t -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Loaded into a GUI session of config=drgnx by harness/drgnx-bench.el.  Every measurement
;; includes a full redisplay; one-off operations are the median of 3 runs, key presses the p95
;; of 50.  treemacs runs like-for-like with drgnx's current features: no git decorations, no
;; file watching, no follow.

(require 'cl-lib)
(require 'seq)

(defvar drgnx-bench--errors nil)

(defun drgnx-bench--ms (setup action &optional n)
  "Median ms of ACTION (after SETUP, a GC and before a full redisplay) over N runs (3)."
  (let (ts)
    (dotimes (_ (or n 3))
      (when setup (funcall setup))
      (garbage-collect)
      (redisplay t)
      (let ((t0 (float-time)))
        (funcall action)
        (redisplay t)
        (push (* 1000.0 (- (float-time) t0)) ts)))
    (nth (/ (length ts) 2) (sort ts #'<))))

(defun drgnx-bench--p95 (step n)
  "p95 ms of STEP followed by a full redisplay, over N steps; an error if the point did not move
(a no-op would look fast)."
  (let ((p0 (point)) ts)
    (dotimes (_ n)
      (let ((t0 (float-time)))
        (funcall step)
        (redisplay t)
        (push (* 1000.0 (- (float-time) t0)) ts)))
    (when (< (count-lines p0 (point)) (/ n 2))
      (error "the selection moved %d rows for %d presses" (count-lines p0 (point)) n))
    (nth (floor (* 0.95 (1- n))) (sort ts #'<))))

(defmacro drgnx-bench--try (tool metric &rest body)
  "BODY's value, or nil with the error noted (a tool that cannot do something is not compared)."
  `(condition-case err (progn ,@body)
     (error (push (format "%s %s: %s" ,tool ,metric (error-message-string err)) drgnx-bench--errors) nil)))

(defun drgnx-bench--new-files (dir n)
  "Add N new files to DIR (unique names each call)."
  (let ((tag (format-time-string "%s%N")))
    (dotimes (i n) (write-region "" nil (expand-file-name (format "new-%s-%03d.txt" tag i) dir) nil 'silent))))

;;;; drgnx

(defun drgnx-bench--drgnx (root)
  (let* ((big (expand-file-name "big" root))
         (leaf (expand-file-name "deep/a/b/c/d/e/f/leaf.txt" root))
         (row (lambda (path) (with-current-buffer drgnx-explorer-buffer-name (drgnx-explorer--row-pos path))))
         (win (lambda () (drgnx-wb-section-window 'explorer)))
         r)
    (delete-other-windows)
    (switch-to-buffer "*scratch*")              ; no file in the editor: no reveal on show
    (setq r (plist-put r :explorer-first
                       (drgnx-bench--try "drgnx" "first"
                         (drgnx-bench--ms (lambda () (drgnx-wb-hide-sidebar) (clrhash drgnx-explorer--cache)
                                            (clrhash drgnx-explorer--expanded)
                                            (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name)))
                                          (lambda () (drgnx-explorer-set-roots (list root)) (drgnx-wb-show-sidebar))))))
    (setq r (plist-put r :explorer-expand
                       (drgnx-bench--try "drgnx" "expand"
                         (drgnx-bench--ms (lambda () (when (drgnx-explorer--expanded-p big)
                                                       (drgnx-explorer-toggle-at (funcall row big))))
                                          (lambda () (drgnx-explorer-toggle-at (funcall row big)))))))
    (setq r (plist-put r :explorer-reveal
                       (drgnx-bench--try "drgnx" "reveal"
                         (drgnx-bench--ms (lambda () (clrhash drgnx-explorer--expanded) (drgnx-explorer--render))
                                          (lambda () (drgnx-explorer-reveal leaf (funcall win)))))))
    (setq r (plist-put r :explorer-key-p95
                       (drgnx-bench--try "drgnx" "keys"
                         (drgnx-explorer-toggle-at (funcall row big))
                         (with-selected-window (funcall win)
                           (goto-char (funcall row big))
                           (drgnx-bench--p95 #'drgnx-explorer-next 50)))))
    (setq r (plist-put r :explorer-refresh
                       (drgnx-bench--try "drgnx" "refresh"
                         (drgnx-bench--ms (lambda () (drgnx-bench--new-files (expand-file-name "d001" root) 100))
                                          #'drgnx-explorer-refresh))))
    r))

;;;; treemacs

(defun drgnx-bench--treemacs (root elpa)
  (when (and elpa (file-directory-p elpa))
    (dolist (d (directory-files elpa t "\\`[^.]"))
      (when (file-directory-p d) (add-to-list 'load-path d)))
    (when (require 'treemacs nil t)
      (setq treemacs-persist-file (make-temp-file "drgnx-bench-treemacs-persist")
            treemacs-last-error-persist-file (make-temp-file "drgnx-bench-treemacs-errors"))
      (treemacs-git-mode -1)
      (treemacs-filewatch-mode -1)
      (treemacs-follow-mode -1)
      (let* ((big (expand-file-name "big" root))
             (leaf (expand-file-name "deep/a/b/c/d/e/f/leaf.txt" root))
             (file (expand-file-name "d000/f000.txt" root))
             (tw (lambda () (treemacs-get-local-window)))
             (kill (lambda ()
                     (when-let* ((w (funcall tw))) (delete-window w))
                     (dolist (b (buffer-list)) (when (string-prefix-p " *Treemacs" (buffer-name b)) (kill-buffer b)))))
             r)
        (drgnx-wb-hide-sidebar)
        (delete-other-windows)
        (find-file file)
        (setq r (plist-put r :explorer-first
                           (drgnx-bench--try "treemacs" "first"
                             (drgnx-bench--ms (lambda () (funcall kill) (select-window (get-buffer-window (get-file-buffer file))))
                                              (lambda () (treemacs-display-current-project-exclusively))))))
        (setq r (plist-put r :explorer-expand
                           (drgnx-bench--try "treemacs" "expand"
                             (drgnx-bench--ms (lambda () (with-selected-window (funcall tw)
                                                           (treemacs-goto-file-node big)
                                                           (when (treemacs-is-node-expanded? (treemacs-current-button))
                                                             (treemacs-toggle-node))))
                                              (lambda () (with-selected-window (funcall tw)
                                                           (treemacs-goto-file-node big) (treemacs-toggle-node)))))))
        (setq r (plist-put r :explorer-reveal
                           (drgnx-bench--try "treemacs" "reveal"
                             (drgnx-bench--ms (lambda () (with-selected-window (funcall tw)
                                                           (treemacs-goto-file-node big)
                                                           (when (treemacs-is-node-expanded? (treemacs-current-button))
                                                             (treemacs-toggle-node))
                                                           (treemacs-goto-file-node (expand-file-name "deep" root))
                                                           (when (treemacs-is-node-expanded? (treemacs-current-button))
                                                             (treemacs-toggle-node t))))
                                              (lambda () (with-selected-window (funcall tw) (treemacs-goto-file-node leaf)))))))
        (setq r (plist-put r :explorer-key-p95
                           (drgnx-bench--try "treemacs" "keys"
                             (with-selected-window (funcall tw)
                               (treemacs-goto-file-node big)
                               (unless (treemacs-is-node-expanded? (treemacs-current-button)) (treemacs-toggle-node))
                               (drgnx-bench--p95 (lambda () (treemacs-next-line 1)) 50)))))
        (setq r (plist-put r :explorer-refresh
                           (drgnx-bench--try "treemacs" "refresh"
                             (drgnx-bench--ms (lambda () (drgnx-bench--new-files (expand-file-name "d001" root) 100))
                                              (lambda () (with-selected-window (funcall tw) (treemacs-refresh)))))))
        (funcall kill)
        r))))

;;;; Buffers: drgnx vs ibuffer

(defun drgnx-bench--buffers (root)
  (delete-other-windows)
  (dotimes (d 5)
    (dotimes (f 100) (find-file-noselect (expand-file-name (format "d%03d/f%03d.txt" (+ 2 d) f) root))))
  (let ((new (lambda () (let ((f (expand-file-name (format "d010/added-%s.txt" (format-time-string "%s%N")) root)))
                          (write-region "" nil f nil 'silent) (find-file-noselect f))))
        mine theirs)
    (drgnx-wb-show-sidebar)
    (setq mine (plist-put mine :buffers-render
                          (drgnx-bench--try "drgnx" "buffers render"
                            (drgnx-bench--ms (lambda () (setq drgnx-buffers--signature nil)) #'drgnx-buffers--refresh))))
    (setq mine (plist-put mine :buffers-update
                          (drgnx-bench--try "drgnx" "buffers update"
                            (drgnx-bench--ms new #'drgnx-buffers--refresh))))
    (setq mine (plist-put mine :buffers-key-p95
                          (drgnx-bench--try "drgnx" "buffers keys"
                            (with-selected-window (drgnx-wb-section-window 'buffers)
                              (goto-char (point-min))
                              (drgnx-bench--p95 #'drgnx-buffers-next 50)))))
    (drgnx-wb-hide-sidebar)
    (require 'ibuffer)
    (setq theirs (plist-put theirs :buffers-render
                            (drgnx-bench--try "ibuffer" "render"
                              (drgnx-bench--ms (lambda () (when (get-buffer "*Ibuffer*") (kill-buffer "*Ibuffer*")))
                                               (lambda () (ibuffer t "*Ibuffer*" nil t))))))
    (setq theirs (plist-put theirs :buffers-update
                            (drgnx-bench--try "ibuffer" "update"
                              (drgnx-bench--ms new (lambda () (with-current-buffer "*Ibuffer*" (ibuffer-update nil t)))))))
    (setq theirs (plist-put theirs :buffers-key-p95
                            (drgnx-bench--try "ibuffer" "keys"
                              (with-selected-window (get-buffer-window "*Ibuffer*")
                                (goto-char (point-min))
                                (drgnx-bench--p95 #'ibuffer-forward-line 50)))))
    (cons mine theirs)))

(defun drgnx-bench-session (root elpa)
  "Measure drgnx, treemacs (when ELPA has it) and ibuffer on the fixture ROOT; JSON for the controller."
  (setq drgnx-bench--errors nil)
  (let* ((inhibit-message t)
         (explorer (drgnx-bench--drgnx root))
         (treemacs (drgnx-bench--treemacs root elpa))
         (buffers (drgnx-bench--buffers root)))
    (drgnx-uitest--json
     (list :drgnx (append explorer (car buffers))
           :treemacs (or treemacs :null)
           :ibuffer (cdr buffers)
           :errors (vconcat (reverse drgnx-bench--errors))))))
