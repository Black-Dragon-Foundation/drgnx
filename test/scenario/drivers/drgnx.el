;;; drgnx.el --- Scenario driver for drgnx -*- lexical-binding: t -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; How the scenarios do things in drgnx's workbench.  Setup goes through drgnx's own functions;
;; the behaviour under test always goes through input events, with the keys the active key
;; profile binds (so the scenarios follow a profile change).

(require 'drgnx-uitest)
(require 'drgnx-explorer)
(require 'drgnx-buffers)

(defun drgnx-driver--key (id)
  "The first key the active profile gives command ID."
  (or (car (car (drgnx-cmd-bound (drgnx-commands-get id))))
      (error "driver: command %s has no key in the active profile" id)))

(defconst drgnx-driver-focus-explorer-keys
  (if (car (drgnx-cmd-bound (drgnx-commands-get 'view-explorer)))
      (drgnx-driver--key 'view-explorer)     ; VS Code's C-S-e shows the Explorer and focuses it
    (drgnx-driver--key 'focus-explorer))
  "Keys that focus the Explorer.")
(defconst drgnx-driver-explorer-down-key (drgnx-driver--key 'explorer-next) "Moves the Explorer selection down.")
(defconst drgnx-driver-explorer-target "drgnx-explorer-mode"
  "How `drgnx-uitest-target-xy' finds the Explorer window (buffer name or major mode).")

(defun drgnx-driver-reset ()
  "A clean layout: sidebar hidden, one editor window."
  (drgnx-wb-hide-sidebar)
  (select-window (drgnx-wb-editor-window))
  (delete-other-windows))

(defun drgnx-driver-open-file (file)
  (select-window (drgnx-wb-editor-window))
  (find-file file))

(defun drgnx-driver--until (secs what pred &optional detail)
  "Setup: wait up to SECS seconds for PRED, else signal that WHAT did not happen (with the string DETAIL returns)."
  (let ((limit (+ (float-time) secs)))
    (while (and (not (funcall pred)) (< (float-time) limit))
      (accept-process-output nil 0.05)
      (redisplay))
    (or (funcall pred)
        (error "driver: %s: not within %d s%s" what secs (if detail (concat "; " (funcall detail)) "")))))

(defun drgnx-driver--hub ()
  "On a Nidhogg with Sjá the hub lists the Explorer's folders (`drgnx-explorer--hub-lists-p').  A session starts no
hub (DRGNX_NO_HUB_START), so the driver runs the checkout's test hub ($DRGNX_RATATOSKR_BIN, which `bin/drgnx test
--scenario' builds) in the foreground once, ended with the session, as the look scenes do, and connects to it."
  (when (drgnx-explorer--hub-lists-p)
    (unless (drgnx-hub-running-p)
      (let ((bin (getenv "DRGNX_RATATOSKR_BIN"))
            (process-environment (cons "RATATOSKR_SUPERVISOR=none" process-environment)))
        (unless (and bin (file-executable-p bin))
          (error "driver: the hub lists the Explorer's folders, and no DRGNX_RATATOSKR_BIN names one"))
        (make-process :name "ratatoskr" :noquery t :connection-type 'pipe
                      :buffer (generate-new-buffer " *ratatoskr*")
                      :command (list bin "serve" "--foreground" "--parent-pid" (number-to-string (emacs-pid))))
        (drgnx-driver--until 30 "hub start" #'drgnx-hub-running-p)))
    (unless (process-live-p drgnx-hub--events) (drgnx-hub-connect))))

(defun drgnx-driver-show-sidebar ()
  "Show the sidebar with the Explorer rooted at the editor's project (as opening that folder would), its rows listed."
  (drgnx-driver--hub)
  (let ((default-directory (with-current-buffer (window-buffer (drgnx-wb-editor-window)) default-directory)))
    (drgnx-explorer-set-roots (list (if-let* ((p (project-current))) (project-root p) default-directory))))
  (drgnx-wb-show-sidebar)
  (when (drgnx-explorer--rows-p)
    ;; the hub's listing of this root, with the editor's file revealed: rows of an earlier scenario's root may still
    ;; be drawn until it arrives
    (let ((root (directory-file-name (expand-file-name (car (drgnx-explorer-roots)))))
          (file (buffer-file-name (window-buffer (drgnx-wb-editor-window)))))
      (drgnx-driver--until 30 (format "the hub's Explorer rows of %s and %s" root file)
                           (lambda () (and (drgnx-driver--explorer-row-pos root)
                                           (or (not file) (drgnx-driver--explorer-row-pos file))))
                           (lambda ()
                             (format "root row %s, file row %s, rows %S"
                                     (drgnx-driver--explorer-row-pos root)
                                     (and file (drgnx-driver--explorer-row-pos file))
                                     (with-current-buffer drgnx-explorer-buffer-name
                                       (buffer-substring-no-properties (point-min) (min (point-max) 400)))))))))

(defun drgnx-driver-explorer-window () (drgnx-wb-section-window 'explorer))
(defun drgnx-driver-buffers-window () (drgnx-wb-section-window 'buffers))
(defun drgnx-driver-editor-window () (drgnx-wb-editor-window))

(defun drgnx-driver-explorer-roots () (drgnx-explorer-roots))

(defun drgnx-driver--explorer-row-pos (path)
  "Start of PATH's drawn Explorer row, or nil: the hub's rows (`drgnx-view-row-start') or the Lisp listing's."
  (with-current-buffer drgnx-explorer-buffer-name
    (let ((path (directory-file-name (expand-file-name path))))
      (if (drgnx-explorer--rows-p) (drgnx-view-row-start drgnx-view path) (drgnx-explorer--row-pos path)))))

(defun drgnx-driver-explorer-collapse (text)
  "Collapse the Explorer folder at path TEXT (relative to the root, e.g. \"src/app\") — setup."
  (with-current-buffer drgnx-explorer-buffer-name
    (let ((pos (drgnx-driver--explorer-row-pos (expand-file-name text (car (drgnx-explorer-roots))))))
      (unless pos (error "driver: no Explorer row for %s" text))
      (when (drgnx-explorer--expanded-p (drgnx-explorer-node-at pos))
        (drgnx-explorer-toggle-at pos)))))

(defun drgnx-driver-buffers-top-row ()
  "The buffer listed on the first visible row of the Buffers panel, or nil."
  (let ((w (drgnx-driver-buffers-window)))
    (with-current-buffer (window-buffer w) (drgnx-buffers-buffer-at (window-start w)))))

(defun drgnx-driver-buffers-row-xy (buffer &optional column-text)
  "Pixel of BUFFER's row in the Buffers panel — on its close button if COLUMN-TEXT is \"×\".
The close button is no buffer text: it is the control (`drgnx-row-control') of the row's tail, an overlay string at
the right edge, so it is found where a click lands on it (`posn-at-x-y' along the row)."
  (let ((win (drgnx-driver-buffers-window)))
    (with-current-buffer (window-buffer win)
      (let* ((row (or (drgnx-buffers--row-pos buffer) (error "driver: no Buffers row for %s" buffer)))
             (xy (or (drgnx-uitest-pos-xy win row) (error "driver: Buffers row of %s is not visible" buffer))))
        (if (not (equal column-text "×"))
            xy
          (let ((f (window-frame win)) (y (cdr xy)) (right (nth 2 (window-body-pixel-edges win))) xs)
            (dotimes (i (- right (car xy)))
              (let* ((x (+ (car xy) i)) (p (posn-at-x-y x y f)) (s (and (eq (posn-window p) win) (posn-string p))))
                (when (and (stringp (car s)) (integerp (cdr s)) (< (cdr s) (length (car s)))
                           (get-text-property (cdr s) 'drgnx-row-control (car s)))
                  (push x xs))))
            (unless xs (error "driver: the Buffers row of %s shows no close button" buffer))
            (cons (/ (+ (car xs) (car (last xs))) 2) y)))))))

(defun drgnx-driver-explorer-pressed-p ()
  "Non-nil while the Explorer counts a mouse button as held."
  (and (drgnx-explorer--held-p) t))

(defun drgnx-driver-explorer-refresh ()
  "Read the Explorer's folders again (setup, after the test wrote files)."
  (drgnx-explorer-refresh))
