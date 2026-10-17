;;; explorer-test.el --- Scenarios: the Explorer (file tree) -*- lexical-binding: t -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; The reference is VS Code's Explorer.  See docs/develop/scenarios.md.

(require 'ert)
(require 'drgnx-scenario)
(require 'drgnx-uitest)

(defmacro drgnx-scn--with-explorer (root &rest body)
  "Fresh fixture ROOT, its main.py open, the sidebar shown and the Explorer focused, then BODY."
  (declare (indent 1))
  `(drgnx-scenario-settling
    (drgnx-scenario-load-driver)
    (drgnx-scenario-with-fixture (,root 'basic)
      (drgnx-driver-reset)
      (drgnx-driver-open-file (expand-file-name "src/app/main.py" ,root))
      (drgnx-driver-show-sidebar)
      (drgnx-uitest-run nil)
      (drgnx-uitest-run (drgnx-uitest-key-events drgnx-driver-focus-explorer-keys))
      (drgnx-uitest-run nil)
      ,@body)))

(defun drgnx-scn--explorer-line ()
  "Text of the Explorer row at point."
  (let ((w (drgnx-driver-explorer-window)))
    (with-current-buffer (window-buffer w)
      (save-excursion (goto-char (window-point w))
                      (string-trim (buffer-substring-no-properties (pos-bol) (pos-eol)))))))

(defun drgnx-scn--click (text &optional count hold)
  "Click the Explorer row showing TEXT; return the jank report."
  (let ((xy (drgnx-uitest-target-xy drgnx-driver-explorer-target text)))
    (drgnx-uitest-run (drgnx-uitest-click-events (drgnx-uitest-posn (car xy) (cdr xy)) 1 count hold))))

(defun drgnx-scn--click-folder-stays ()
  (let* ((r (drgnx-scn--click "docs"))
         (line (drgnx-scn--explorer-line)))
    (drgnx-scenario-check
     (and (string-search "docs" line) (= (plist-get r :oscillations) 0))
     (format "a single click on a folder must keep the selection on it; after %d snap-back(s) it is on %S"
             (plist-get r :oscillations) line)
     r)))

(ert-deftest drgnx-scenario/explorer-click-stays ()
  "Single click on a folder: the selection stays on that folder."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-click-stays)
  (drgnx-scn--with-explorer root
    (drgnx-scn--click-folder-stays)))

(ert-deftest drgnx-scenario/explorer-follow-override ()
  "The override experiment: with the configuration's Explorer follow switched off, the
click-stays scenario passes — so the follow is what breaks it."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-follow-override)
  (drgnx-scenario-load-driver)
  (unless (fboundp 'drgnx-driver-disable-follow) (ert-skip "this configuration has no follow to switch off"))
  (drgnx-driver-disable-follow)
  (drgnx-scenario-settling
   (unwind-protect
       (drgnx-scn--with-explorer root
         (drgnx-scn--click-folder-stays))
     (drgnx-driver-enable-follow))))

(defun drgnx-scn--explorer-has (text)
  (with-current-buffer (window-buffer (drgnx-driver-explorer-window))
    (save-excursion (goto-char (point-min)) (and (search-forward text nil t) t))))

(ert-deftest drgnx-scenario/explorer-expand-stays ()
  "Double click on a collapsed folder: it expands; the selection and the view stay."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-expand-stays)
  (drgnx-scn--with-explorer root
    (let* ((w (drgnx-driver-explorer-window))
           (start (window-start w))
           (r (drgnx-scn--click "docs" 2))
           (line (drgnx-scn--explorer-line))
           (expanded (drgnx-scn--explorer-has "guide.md")))
      (drgnx-scenario-check
       (and expanded (string-search "docs" line) (= (window-start w) start) (= (plist-get r :oscillations) 0))
       (format "a double click must expand the folder and keep selection and view: expanded %s, selection on %S, view %s, %d snap-back(s)"
               expanded line (if (= (window-start w) start) "kept" "moved") (plist-get r :oscillations))
       r))))

(ert-deftest drgnx-scenario/explorer-hold-is-a-click ()
  "Press, hold 300 ms, release without moving the mouse: a click on the row pressed — even if
something reveals the editor's file meanwhile.  (A tree that moves under a held button turns
the release into a drag; with drag-to-move on, that moves files.)"
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-hold-is-a-click)
  (drgnx-scn--with-explorer root
    (let ((w (drgnx-driver-explorer-window)))
      ;; Collapse src/app (above `tests'): revealing main.py would expand it again.
      (drgnx-driver-explorer-collapse "src/app")
      (drgnx-uitest-run nil)
      (drgnx-scenario-require (not (drgnx-scn--explorer-has "util.py")) "src/app collapsed")
      (let* ((events nil)
             (record (lambda () (when (mouse-event-p last-input-event)
                                  (push (car last-input-event) events))))
             (r (progn (add-hook 'pre-command-hook record)
                       (unwind-protect (drgnx-scn--click "tests" 1 0.3)
                         (remove-hook 'pre-command-hook record))))
             (line (drgnx-scn--explorer-line))
             (drag (seq-find (lambda (e) (string-prefix-p "drag-" (symbol-name e))) events)))
        (drgnx-scenario-check
         (and (not drag) (string-search "tests" line) (= (plist-get r :oscillations) 0))
         (format "press-hold-release on a row must be a click on that row: input arrived as %s, selection on %S, %d snap-back(s)"
                 (reverse events) line (plist-get r :oscillations))
         r)))))

(ert-deftest drgnx-scenario/explorer-keys-during-churn ()
  "Moving through the Explorer with keys while buffers come and go in the background: only
the keys move the selection."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-keys-during-churn)
  (drgnx-scn--with-explorer root
    (let* ((w (drgnx-driver-explorer-window))
           (line0 (with-current-buffer (window-buffer w) (line-number-at-pos (window-point w))))
           (churn (run-with-timer 0 0.1 (lambda () (kill-buffer (generate-new-buffer "drgnx-churn"))))))
      (drgnx-scenario-require (timerp churn) "a churn timer")
      (drgnx-uitest-run (drgnx-uitest-key-events (format "%s %s" drgnx-driver-explorer-down-key drgnx-driver-explorer-down-key)))
      ;; Look again after the churn stops: a follower starved during it may fire then.
      (cancel-timer churn)
      (let* ((r (drgnx-uitest-run nil))
             (line (with-current-buffer (window-buffer w) (line-number-at-pos (window-point w)))))
        (drgnx-scenario-check
         (= line (+ line0 2))
         (format "two %s during background churn must leave the selection two rows down (%d → %d); after the churn it is on row %d (%S)" drgnx-driver-explorer-down-key
                 line0 (+ line0 2) line (drgnx-scn--explorer-line))
         r)))))

(ert-deftest drgnx-scenario/explorer-cross-project-keeps-root ()
  "Opening a file of another project keeps the Explorer's root (VS Code keeps its workspace)."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-cross-project-keeps-root)
  (drgnx-scn--with-explorer root
    (drgnx-scenario-with-fixture (other 'second)
      (let* ((roots0 (drgnx-driver-explorer-roots))
             (_ (drgnx-scenario-require (member (file-name-as-directory root) roots0)
                                        "the Explorer showing the fixture before the other project's file opens"))
             (_ (drgnx-driver-open-file (expand-file-name "lib/other.py" other)))
             (r (drgnx-uitest-run nil))
             (roots (drgnx-driver-explorer-roots)))
        (drgnx-scenario-check
         (member (file-name-as-directory root) roots)
         (format "opening a file of another project must not replace the Explorer's root: %S became %S"
                 (mapcar #'file-name-nondirectory (mapcar #'directory-file-name roots0))
                 (mapcar #'file-name-nondirectory (mapcar #'directory-file-name roots)))
         r)))))

(ert-deftest drgnx-scenario/explorer-keys-stay ()
  "Moving through the Explorer with keys: the selection stays where the keys put it."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-keys-stay)
  (drgnx-scn--with-explorer root
    (let* ((w (drgnx-driver-explorer-window))
           (line0 (with-current-buffer (window-buffer w) (line-number-at-pos (window-point w))))
           (r (drgnx-uitest-run (drgnx-uitest-key-events (format "%s %s" drgnx-driver-explorer-down-key drgnx-driver-explorer-down-key))))
           (line (with-current-buffer (window-buffer w) (line-number-at-pos (window-point w)))))
      (drgnx-scenario-check
       (= line (+ line0 2))
       (format "after two %s the selection must be two rows down (row %d); it is on row %d (%S)" drgnx-driver-explorer-down-key
               (+ line0 2) line (drgnx-scn--explorer-line))
       r))))

(ert-deftest drgnx-scenario/explorer-keys-then-background-event ()
  "After browsing with keys, something unrelated creates a buffer in the background (an
agent or status poll): the selection stays where it is."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-keys-then-background-event)
  (drgnx-scn--with-explorer root
    (let ((w (drgnx-driver-explorer-window)))
      (with-selected-window w (forward-line 2))   ; setup: two rows down, without commands
      (drgnx-uitest-run nil)
      (let ((line0 (with-current-buffer (window-buffer w) (line-number-at-pos (window-point w)))))
        (run-with-timer 0.05 nil (lambda () (kill-buffer (generate-new-buffer "drgnx-background"))))
        (let* ((r (drgnx-uitest-run nil))
               (line (with-current-buffer (window-buffer w) (line-number-at-pos (window-point w)))))
          (drgnx-scenario-check
           (= line line0)
           (format "a background buffer event must not move the Explorer selection: row %d became row %d (%S)"
                   line0 line (drgnx-scn--explorer-line))
           r))))))

(ert-deftest drgnx-scenario/explorer-change-during-hold-is-still-a-click ()
  "A folder appears above the row while its button is held (a build, git, another program): the
release is still a click on the row pressed — the tree does not change under a held button."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-change-during-hold-is-still-a-click)
  (drgnx-scn--with-explorer root
    (let* ((events nil)
           (record (lambda () (when (mouse-event-p last-input-event) (push (car last-input-event) events))))
           (_ (run-with-timer 0.1 nil (lambda () (make-directory (expand-file-name "aaa-new" root)))))
           (r (progn (add-hook 'pre-command-hook record)
                     (unwind-protect (drgnx-scn--click "tests" 1 0.4)
                       (remove-hook 'pre-command-hook record))))
           (line (drgnx-scn--explorer-line))
           (drag (seq-find (lambda (e) (string-prefix-p "drag-" (symbol-name e))) events)))
      (drgnx-scenario-check
       (and (not drag) (string-search "tests" line))
       (format "a change during the hold must not turn the click into a drag or move the selection: input %s, selection on %S"
               (reverse events) line)
       r))))

(ert-deftest drgnx-scenario/explorer-external-change-keeps-the-selection ()
  "Browsing with keys, a new folder appears above the selected row: the selection stays on its entry."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/explorer-external-change-keeps-the-selection)
  (drgnx-scn--with-explorer root
    (drgnx-uitest-run (drgnx-uitest-key-events (format "%s %s" drgnx-driver-explorer-down-key drgnx-driver-explorer-down-key)))
    (let ((line0 (drgnx-scn--explorer-line)))
      (make-directory (expand-file-name "aaa-new" root))
      (let* ((r (drgnx-uitest-run nil))
             (line (drgnx-scn--explorer-line)))
        (drgnx-scenario-check
         (and (equal line line0) (drgnx-scn--explorer-has "aaa-new"))
         (format "a new folder must appear without moving the selection: shown %s; selection was on %S, now on %S"
                 (drgnx-scn--explorer-has "aaa-new") line0 line)
         r)))))
