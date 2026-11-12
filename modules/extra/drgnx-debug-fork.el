;;; drgnx-debug-fork.el --- Debugging: what-if forks of a recorded run -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The editor's half of what-if forks (docs/guide/debugging.md, "What-if forks"; the hub's `debug/fork').  Fork from
;; Here (`debug-fork') replays a recorded run in a sealed copy up to a point (a stop of the run, or a line's N-th
;; pass), changes a value there or runs edited code, and runs on to the next stop, the end, or a probe's next hit.
;; The hub sends `debug-fork' as the fork goes; the What-if tab shows the fork beside its run: "matched on N of M
;; hits" before the point, the first difference, each probe's values after it, and how each ended.  A code what-if
;; opens the fork's tree first (Open Fork); Run Fork runs it once edited, and Take Fork's Change shows each changed
;; file as a review card whose Apply puts the fork's text into your buffer (undoable, not saved).
;;
;; Where "here" is comes from the recorded run being shown: `drgnx-debug-fork-point-function'.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-debug-launch (expand-file-name "drgnx-debug-launch" (file-name-directory (macroexp-file-name))))
(declare-function drgnx-hub-call-sync "drgnx-hub-client")
(defvar drgnx-hub-event-functions)

(defgroup drgnx-debug-fork nil "What-if forks." :group 'drgnx)

(defface drgnx-debug-fork-same '((t :inherit shadow))
  "A value the fork shares with its run."
  :group 'drgnx-debug-fork)
(defface drgnx-debug-fork-differs '((t :inherit warning))
  "A value the fork changed."
  :group 'drgnx-debug-fork)
(defface drgnx-debug-fork-heading '((t :inherit bold))
  "A heading of the What-if tab."
  :group 'drgnx-debug-fork)

(defvar drgnx-debug-fork-point-function nil
  "A function of no arguments: the recorded run and point being shown, as (RUN . AT), AT a plist `(:stop INDEX)' or
`(:path P :line L :hit N)'; nil when none is.  The recorded runs' timeline sets it.")

(defvar drgnx-debug-fork--views (make-hash-table :test #'equal)
  "Each fork's last `debug-fork' view, by id.")

(defvar drgnx-debug-fork-last nil "The id of the fork made last.")

(defun drgnx-debug-fork--read-change ()
  "Ask what the fork changes: a plist for `debug/fork''s :change, or nil for nothing."
  (pcase (completing-read "Fork from here: " '("Set a value…" "Edit the code" "Nothing (replay the run)") nil t)
    ("Set a value…"
     (let ((name (read-string "Value (a name path such as item.reserve): "))
           (text (read-string "New value (an expression): ")))
       (list :value (list :path (vconcat (split-string name "\\." t)) :text text))))
    ("Edit the code" (list :code t))
    (_ nil)))

(defun drgnx-debug-fork--read-until ()
  "Ask where the fork ends: `debug/fork''s :until."
  (pcase (completing-read "Run the fork until: " '("the next stop" "the end" "a probe's next hit") nil t)
    ("the end" "exit")
    ("a probe's next hit" (list :probe (read-string "Probe: ")))
    (_ "stop")))

(defun drgnx-debug-fork (run at &optional change until)
  "Fork recorded RUN at AT (`drgnx-debug-fork-point-function''s form), with CHANGE, running UNTIL: its id.
Interactively the point is the one being shown, and the change and the end are asked."
  (interactive
   (let ((here (and drgnx-debug-fork-point-function (funcall drgnx-debug-fork-point-function))))
     (unless here (user-error "No recorded run is shown here: fork from a stop of a recorded run"))
     (list (car here) (cdr here) (drgnx-debug-fork--read-change) (drgnx-debug-fork--read-until))))
  (let ((inputs nil) (confirm nil) (result nil))
    (while (not result)
      (let ((r (drgnx-hub-call-sync "debug/fork"
                                    (append (list :run run :at at :until (or until "stop") :confirm (if confirm t :false))
                                            (when change (list :change change))
                                            (when inputs (list :inputs (vconcat inputs)))))))
        (cond
         ((plist-get r :fork) (setq result (plist-get r :fork)))
         ((plist-get r :ask)
          (if (yes-or-no-p (concat (plist-get r :ask) ".  Fork anyway? "))
              (setq confirm t)
            (user-error "No fork")))
         ((plist-get r :needs)
          (setq inputs (append inputs (delq nil (mapcar #'drgnx-debug-launch--ask (append (plist-get r :needs) nil))))))
         (t (user-error "The hub made no fork")))))
    (setq drgnx-debug-fork-last result)
    (message "Fork %s: replaying the run…" result)
    result))

(defun drgnx-debug-fork--read-fork ()
  "A fork's id: the last one, or asked among the hub's."
  (let ((ids (hash-table-keys drgnx-debug-fork--views)))
    (cond ((null ids) (user-error "No fork"))
          ((and drgnx-debug-fork-last (member drgnx-debug-fork-last ids) (not current-prefix-arg)) drgnx-debug-fork-last)
          (t (completing-read "Fork: " ids nil t)))))

(defun drgnx-debug-fork-run (fork)
  "Run FORK, a code what-if whose tree was edited."
  (interactive (list (drgnx-debug-fork--read-fork)))
  (drgnx-hub-call-sync "debug/fork/run" (list :fork fork))
  (message "Fork %s: running the edited code…" fork))

(defun drgnx-debug-fork-drop (fork)
  "FORK goes, with its tree."
  (interactive (list (drgnx-debug-fork--read-fork)))
  (drgnx-hub-call-sync "debug/fork/drop" (list :fork fork))
  (remhash fork drgnx-debug-fork--views)
  (when-let* ((b (get-buffer (drgnx-debug-fork--buffer-name fork)))) (kill-buffer b)))

(defun drgnx-debug-fork--tree (fork)
  "FORK's tree, or an error."
  (or (plist-get (gethash fork drgnx-debug-fork--views) :tree)
      (user-error "Fork %s has no tree yet" fork)))

(defun drgnx-debug-fork--root (fork)
  "The project FORK's run ran in."
  (plist-get (gethash fork drgnx-debug-fork--views) :root))

(defun drgnx-debug-fork--in-tree (file fork)
  "FILE of the project as it is in FORK's tree (FILE itself when it is not in the project)."
  (let ((root (file-name-as-directory (or (drgnx-debug-fork--root fork) "/nonexistent")))
        (tree (file-name-as-directory (drgnx-debug-fork--tree fork))))
    (if (string-prefix-p root file) (concat tree (substring file (length root))) file)))

(defun drgnx-debug-fork-open (fork)
  "Open FORK's tree beside this file: this file as the fork has it, else the tree's folder."
  (interactive (list (drgnx-debug-fork--read-fork)))
  (let ((there (and buffer-file-name (drgnx-debug-fork--in-tree buffer-file-name fork))))
    (find-file-other-window (if (and there (file-exists-p there)) there (drgnx-debug-fork--tree fork)))))

;;;; The What-if tab

(defun drgnx-debug-fork--buffer-name (fork) (format "*What if: %s*" fork))

(defun drgnx-debug-fork--end-text (end)
  "How a side ended, as text."
  (pcase (plist-get end :kind)
    ("stop" (format "stopped at %s:%s (%s)" (file-name-nondirectory (or (plist-get end :path) "?"))
                    (plist-get end :line) (plist-get end :reason)))
    ("exit" (format "exited with code %s" (or (plist-get end :code) "?")))
    ("probe" (format "probe %s hit: %s" (plist-get end :probe) (plist-get end :value)))
    (_ "not recorded")))

(defun drgnx-debug-fork--insert-view (v)
  "Insert view V of a fork."
  (let ((m (plist-get v :matched)) (at (plist-get v :at)))
    (insert (propertize (format "What if: fork %s of run %s" (plist-get v :fork) (plist-get v :run))
                        'face 'drgnx-debug-fork-heading) "\n")
    (pcase (plist-get v :state)
      ("failed" (insert "The fork failed: " (or (plist-get v :error) "?") "\n"))
      ("editing" (insert "Edit the fork's tree (Open Fork), then Run Fork.\n  " (or (plist-get v :tree) "") "\n"))
      ((or "preparing" "running") (insert "Replaying the run…\n"))
      ("done"
       (insert (format "From %s:%s, hit %s" (file-name-nondirectory (or (plist-get at :path) "?"))
                       (plist-get at :line) (plist-get at :hit)))
       (when-let* ((s (plist-get at :steps)) ((> (length s) 0))) (insert (format ", then %d steps" (length s))))
       (insert "\n")
       (insert (propertize (format "Matched on %s of %s hits" (plist-get m :matched) (plist-get m :of))
                           'face (if (equal (plist-get m :matched) (plist-get m :of))
                                     'drgnx-debug-fork-same 'drgnx-debug-fork-differs))
               "\n")
       (when-let* ((f (plist-get m :first)))
         (insert (propertize (format "First difference: probe %s, hit %s: %s then, %s now"
                                     (plist-get f :probe) (plist-get f :hit) (plist-get f :then)
                                     (or (plist-get f :now) "no hit"))
                             'face 'drgnx-debug-fork-differs)
                 "\n"))
       (when-let* ((a (plist-get v :applied))) (insert (format "Changed to: %s\n" a)))
       (insert "\n" (propertize "After the point" 'face 'drgnx-debug-fork-heading) "\n")
       (dolist (l (append (plist-get v :lanes) nil))
         (let ((then (append (plist-get l :then) nil)) (now (append (plist-get l :now) nil)))
           (insert (format "  %s\n    then  " (plist-get l :probe)))
           (insert (string-join then " ") "\n    now   ")
           (cl-loop for x in now for i from 0
                    do (insert (propertize x 'face (if (equal x (nth i then)) 'drgnx-debug-fork-same
                                                     'drgnx-debug-fork-differs))
                               " "))
           (insert "\n")))
       (insert (format "\nThe run: %s\nThe fork: %s\n"
                       (drgnx-debug-fork--end-text (plist-get v :then))
                       (drgnx-debug-fork--end-text (plist-get v :now))))
       (when-let* ((c (plist-get v :changed)) ((> (length c) 0)))
         (insert (format "\nThe fork's code differs in %d file(s): Take Fork's Change.\n" (length c))))))))

(define-derived-mode drgnx-debug-fork-mode special-mode "What if"
  "The What-if tab: a fork beside its run.")

(defun drgnx-debug-fork-show (fork)
  "The What-if tab of FORK."
  (interactive (list (drgnx-debug-fork--read-fork)))
  (pop-to-buffer (drgnx-debug-fork--render fork)))

(defun drgnx-debug-fork--render (fork)
  "FORK's What-if buffer, drawn from its last view."
  (with-current-buffer (get-buffer-create (drgnx-debug-fork--buffer-name fork))
    (unless (derived-mode-p 'drgnx-debug-fork-mode) (drgnx-debug-fork-mode))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (drgnx-debug-fork--insert-view (gethash fork drgnx-debug-fork--views))
      (goto-char (point-min)))
    (current-buffer)))

(defun drgnx-debug-fork--event (event data)
  "`drgnx-hub-event-functions': a fork changed (`debug-fork')."
  (when (equal event "debug-fork")
    (let ((id (plist-get data :fork)))
      (if (equal (plist-get data :state) "dropped")
          (remhash id drgnx-debug-fork--views)
        (puthash id data drgnx-debug-fork--views)
        (when (or (get-buffer (drgnx-debug-fork--buffer-name id))
                  (member (plist-get data :state) '("done" "failed" "editing")))
          (let ((b (drgnx-debug-fork--render id)))
            (unless (get-buffer-window b) (display-buffer b))))))))

;;;; Taking the fork's change back

(defun drgnx-debug-fork-take (fork)
  "Each file FORK's code changed, as a review card: Apply puts the fork's text in your buffer (undoable, unsaved)."
  (interactive (list (drgnx-debug-fork--read-fork)))
  (let ((changed (append (plist-get (gethash fork drgnx-debug-fork--views) :changed) nil))
        (root (drgnx-debug-fork--root fork)))
    (unless changed (user-error "Fork %s changed no file" fork))
    (dolist (rel changed)
      (let* ((mine (expand-file-name rel root))
             (theirs (drgnx-debug-fork--in-tree mine fork))
             (buf (find-file-noselect mine)))
        (drgnx-debug-fork--card buf theirs rel)))))

(defun drgnx-debug-fork--card (buffer theirs rel)
  "A review card for BUFFER against the fork's file THEIRS (REL, the project's name of it)."
  (let ((diff (with-temp-buffer
                (let ((new (generate-new-buffer " *fork-file*" t)))
                  (unwind-protect
                      (progn
                        (with-current-buffer new (insert-file-contents theirs))
                        (diff-no-select buffer new nil t (current-buffer)))
                    (kill-buffer new)))
                (buffer-string))))
    (if (yes-or-no-p (format "%s\nTake the fork's %s into your buffer? " diff rel))
        (with-current-buffer buffer
          (let ((new (generate-new-buffer " *fork-file*" t)))
            (unwind-protect
                (progn (with-current-buffer new (insert-file-contents theirs))
                       (replace-region-contents (point-min) (point-max) new))
              (kill-buffer new)))
          (message "%s: the fork's change is in your buffer (not saved)" rel))
      (message "%s: left as it is" rel))))

(provide 'drgnx-debug-fork)
;;; drgnx-debug-fork.el ends here
