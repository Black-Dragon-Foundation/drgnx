;;; workbench-bench.el --- In-session part of `drgnx test --bench' -*- lexical-binding: t -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Loaded into a GUI session of config=drgnx by harness/drgnx-bench.el.  Every measurement
;; includes a full redisplay; one-off operations are the median of 3 runs, key presses the p95
;; of 300.  treemacs runs like-for-like: no file watching, no follow, git off (on for both tools
;; in the two git rows).

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

(defun drgnx-bench--no-git-timer ()
  "Cancel a pending background git refresh (it would run inside a later measurement)."
  (when (timerp drgnx-explorer--git-timer) (cancel-timer drgnx-explorer--git-timer))
  (setq drgnx-explorer--git-timer nil))

(defun drgnx-bench--drgnx (root)
  (let* ((big (expand-file-name "big" root))
         (leaf (expand-file-name "deep/a/b/c/d/e/f/leaf.txt" root))
         (row (lambda (path) (with-current-buffer drgnx-explorer-buffer-name (drgnx-explorer--row-pos path))))
         (win (lambda () (drgnx-wb-section-window 'explorer)))
         r)
    (delete-other-windows)
    (switch-to-buffer "*scratch*")              ; no file in the editor: no reveal on show
    (setq drgnx-explorer-git nil)               ; like treemacs: git off, then on for the git rows
    (setq r (plist-put r :explorer-first
                       (drgnx-bench--try "drgnx" "first"
                         (drgnx-bench--ms (lambda () (drgnx-wb-hide-sidebar) (clrhash drgnx-explorer--cache)
                                            (clrhash drgnx-explorer--expanded)
                                            (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name)))
                                          (lambda () (drgnx-explorer-set-roots (list root)) (drgnx-wb-show-sidebar))))))
    ;; With git: the render, the whole repository's status, and the visible rows repainted with it.
    (setq r (plist-put r :explorer-first-git
                       (drgnx-bench--try "drgnx" "first with git"
                         (unwind-protect
                             (drgnx-bench--ms (lambda () (drgnx-wb-hide-sidebar) (clrhash drgnx-explorer--cache)
                                                (clrhash drgnx-explorer--expanded) (clrhash drgnx-git--repos)
                                                (drgnx-bench--no-git-timer) (setq drgnx-explorer-git t)
                                                (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name)))
                                              (lambda () (drgnx-explorer-set-roots (list root)) (drgnx-wb-show-sidebar)
                                                (drgnx-git-refresh (file-name-as-directory root) t)
                                                (unless (drgnx-git-status (expand-file-name "d000/f000.txt" root))
                                                  (error "no git status was read"))))
                           (drgnx-bench--no-git-timer) (setq drgnx-explorer-git nil)))))
    (setq r (plist-put r :git-status
                       (drgnx-bench--try "drgnx" "git status"
                         (drgnx-bench--ms (lambda () (clrhash drgnx-git--repos))
                                          (lambda ()
                                            (drgnx-git-refresh (file-name-as-directory root) t)
                                            (unless (drgnx-git-status (expand-file-name "d000/f000.txt" root))
                                              (error "no git status was read")))))))
    (setq r (plist-put r :explorer-expand
                       (drgnx-bench--try "drgnx" "expand"
                         (drgnx-bench--ms (lambda () (when (drgnx-explorer--expanded-p big)
                                                       (drgnx-explorer-toggle-at (funcall row big)))
                                            (clrhash drgnx-explorer--cache))     ; read the disk, like treemacs
                                          (lambda () (drgnx-explorer-toggle-at (funcall row big)))))))
    ;; With git: the status is known (read in the background); the new rows are painted with it.
    (setq r (plist-put r :explorer-expand-git
                       (drgnx-bench--try "drgnx" "expand with git"
                         (unwind-protect
                             (progn
                               (setq drgnx-explorer-git t)
                               (drgnx-git-refresh (file-name-as-directory root) t)
                               (drgnx-bench--ms (lambda () (when (drgnx-explorer--expanded-p big)
                                                             (drgnx-explorer-toggle-at (funcall row big)))
                                                  (clrhash drgnx-explorer--cache))
                                                (lambda () (drgnx-explorer-toggle-at (funcall row big)))))
                           (drgnx-bench--no-git-timer) (setq drgnx-explorer-git nil)))))
    (setq r (plist-put r :explorer-reveal
                       (drgnx-bench--try "drgnx" "reveal"
                         (drgnx-bench--ms (lambda () (clrhash drgnx-explorer--expanded) (drgnx-explorer--render))
                                          (lambda () (drgnx-explorer-reveal leaf (funcall win)))))))
    (setq r (plist-put r :explorer-key-p95
                       (drgnx-bench--try "drgnx" "keys"
                         (drgnx-explorer-toggle-at (funcall row big))
                         (with-selected-window (funcall win)
                           (goto-char (funcall row big))
                           (drgnx-bench--p95 #'drgnx-explorer-next 300)))))
    (setq r (plist-put r :explorer-refresh
                       (drgnx-bench--try "drgnx" "refresh"
                         ;; d001 expanded: the 100 new files must appear (checked).  Live updates held back
                         ;; (like treemacs, no file watching): `redisplay' runs due timers, and the watch's
                         ;; would show the files before the measured refresh.
                         (let ((d001 (expand-file-name "d001" root)) (drgnx-explorer-event-delay 3600))
                           (unless (drgnx-explorer--expanded-p d001) (drgnx-explorer-toggle-at (funcall row d001)))
                           (drgnx-bench--ms (lambda () (drgnx-bench--new-files d001 100))
                                            (lambda ()
                                              (let ((n (with-current-buffer drgnx-explorer-buffer-name (count-lines (point-min) (point-max)))))
                                                (drgnx-explorer-refresh)
                                                (unless (= (+ n 100) (with-current-buffer drgnx-explorer-buffer-name
                                                                       (count-lines (point-min) (point-max))))
                                                  (error "refresh did not show the 100 new files")))))))))
    (when (timerp drgnx-explorer--event-timer) (cancel-timer drgnx-explorer--event-timer))
    (setq drgnx-explorer--event-timer nil drgnx-explorer--dirty nil)
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
                               (drgnx-bench--p95 (lambda () (treemacs-next-line 1)) 300)))))
        (setq r (plist-put r :explorer-refresh
                           (drgnx-bench--try "treemacs" "refresh"
                             (let ((d001 (expand-file-name "d001" root)))
                               (with-selected-window (funcall tw)
                                 (treemacs-goto-file-node d001)
                                 (unless (treemacs-is-node-expanded? (treemacs-current-button)) (treemacs-toggle-node)))
                               (drgnx-bench--ms (lambda () (drgnx-bench--new-files d001 100))
                                                (lambda ()
                                                  (with-selected-window (funcall tw)
                                                    (let ((n (count-lines (point-min) (point-max))))
                                                      (treemacs-refresh)
                                                      (unless (= (+ n 100) (count-lines (point-min) (point-max)))
                                                        (error "refresh did not show the 100 new files"))))))))))
        (when (executable-find "git")
          (treemacs-git-mode 'simple)
          (setq r (plist-put r :explorer-first-git
                             (drgnx-bench--try "treemacs" "first with git"
                               (drgnx-bench--ms (lambda () (funcall kill) (select-window (get-buffer-window (get-file-buffer file))))
                                                (lambda () (treemacs-display-current-project-exclusively))))))
          (setq r (plist-put r :explorer-expand-git
                             (drgnx-bench--try "treemacs" "expand with git"
                               (drgnx-bench--ms (lambda () (with-selected-window (funcall tw)
                                                             (treemacs-goto-file-node big)
                                                             (when (treemacs-is-node-expanded? (treemacs-current-button))
                                                               (treemacs-toggle-node))))
                                                (lambda () (with-selected-window (funcall tw)
                                                             (treemacs-goto-file-node big) (treemacs-toggle-node)))))))
          (treemacs-git-mode -1))
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
                            ;; Like ibuffer: a fresh panel buffer, its window and the render.
                            (drgnx-bench--ms (lambda () (drgnx-wb-hide-sidebar) (setq drgnx-buffers--signature nil)
                                               (kill-buffer drgnx-buffers-buffer-name))
                                             #'drgnx-wb-show-sidebar))))
    (setq mine (plist-put mine :buffers-update
                          (drgnx-bench--try "drgnx" "buffers update"
                            (drgnx-bench--ms new #'drgnx-signal--flush))))      ; the change bus included
    (setq mine (plist-put mine :buffers-key-p95
                          (drgnx-bench--try "drgnx" "buffers keys"
                            (with-selected-window (drgnx-wb-section-window 'buffers)
                              (goto-char (point-min))
                              (drgnx-bench--p95 #'drgnx-buffers-next 300)))))
    ;; ibuffer in the same frame (the sidebar stays): a key press redisplays the same windows.
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
                                (drgnx-bench--p95 #'ibuffer-forward-line 300)))))
    (drgnx-wb-hide-sidebar)
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
