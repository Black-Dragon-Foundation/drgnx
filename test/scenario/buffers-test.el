;;; buffers-test.el --- Scenarios: the Buffers panel (open editors) -*- lexical-binding: t -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; The reference is VS Code's Open Editors list.  See docs/scenarios.md.

(require 'ert)
(require 'drgnx-scenario)
(require 'drgnx-uitest)

(defmacro drgnx-scn--with-sidebar (root &rest body)
  "Fresh fixture ROOT, its main.py open in the editor, the sidebar shown, then BODY."
  (declare (indent 1))
  `(drgnx-scenario-settling
     (drgnx-scenario-load-driver)
     (drgnx-scenario-with-fixture (,root 'basic)
       (drgnx-driver-reset)
       (drgnx-driver-open-file (expand-file-name "src/app/main.py" ,root))
       (drgnx-driver-show-sidebar)
       (drgnx-uitest-run nil)
       ,@body)))

(ert-deftest drgnx-scenario/buffers-header-survives-refresh ()
  "The Buffers panel shows its header line, and keeps it while buffers come and go."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/buffers-header-survives-refresh)
  (drgnx-scenario-settling
   (drgnx-scenario-load-driver)
   (drgnx-scenario-with-fixture (root 'basic)
     (drgnx-driver-reset)
     (let (wiped)
       (drgnx-scenario-watch-nil header-line-format
           (lambda (b) (with-current-buffer b (derived-mode-p 'ibuffer-mode))) wiped
         (drgnx-driver-open-file (expand-file-name "src/app/main.py" root))
         (drgnx-driver-show-sidebar)
         (drgnx-uitest-run nil)
         (drgnx-driver-open-file (expand-file-name "src/app/util.py" root))
         (drgnx-driver-open-file (expand-file-name "README.md" root))
         (let* ((r (drgnx-uitest-run nil))
                (h (window-header-line-height (drgnx-driver-buffers-window))))
           (drgnx-scenario-check
            (> h 0)
            (format "the Buffers panel must show its header; it is %d px — header-line-format was set to nil %d time(s), first by %s"
                    h (length wiped)
                    (if wiped (mapconcat #'symbol-name (car (last wiped)) " ← ") "nobody (never set)"))
            r)))))))

(ert-deftest drgnx-scenario/buffers-scroll-kept ()
  "A scrolled Buffers panel stays scrolled when another file is opened."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/buffers-scroll-kept)
  (drgnx-scn--with-sidebar root
    (dotimes (i 40)
      (let ((f (expand-file-name (format "many/file%02d.txt" i) root)))
        (make-directory (file-name-directory f) t)
        (write-region "x\n" nil f nil 'silent)
        (find-file-noselect f)))
    (drgnx-driver-open-file (expand-file-name "src/app/util.py" root))
    (drgnx-uitest-run nil)
    (let ((w (drgnx-driver-buffers-window)))
      (with-current-buffer (window-buffer w)
        (set-window-start w (save-excursion (goto-char (point-min)) (forward-line 15) (point))))
      (redisplay t)
      (let ((top0 (drgnx-driver-buffers-top-row)))
        (drgnx-scenario-require (buffer-live-p top0) "a buffer on the scrolled panel's top row")
        (drgnx-driver-open-file (expand-file-name "README.md" root))
        (let* ((r (drgnx-uitest-run nil))
               (top (drgnx-driver-buffers-top-row)))
          (drgnx-scenario-check (eq top top0)
                                (format "the panel's view must stay where the user scrolled it: top row was %s, now %s"
                                        (and top0 (buffer-name top0)) (and top (buffer-name top)))
                                r))))))

(ert-deftest drgnx-scenario/buffers-close-hits-row ()
  "Clicking × on a row closes that row's buffer — rows do not move under the pointer when
another file is opened just before the click."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/buffers-close-hits-row)
  (drgnx-scn--with-sidebar root
    (let* ((a (find-file-noselect (expand-file-name "src/app/util.py" root)))
           (b (find-file-noselect (expand-file-name "README.md" root)))
           (c (find-file-noselect (expand-file-name "docs/guide.md" root))))
      (drgnx-driver-open-file (buffer-file-name a))
      (drgnx-driver-open-file (buffer-file-name b))
      (drgnx-driver-open-file (buffer-file-name c))
      (drgnx-uitest-run nil)
      (let ((xy (drgnx-driver-buffers-row-xy b "×")))
        ;; Something else gets focus just before the click (the user switched files).
        (drgnx-driver-open-file (buffer-file-name a))
        (drgnx-uitest-run nil)
        (let* ((r (drgnx-uitest-run (drgnx-uitest-click-events (drgnx-uitest-posn (car xy) (cdr xy)))))
               (killed (seq-remove #'buffer-live-p (list a b c))))
          (drgnx-scenario-check
           (equal killed (list b))
           (format "× on %s's row must close %s and only it; closed: %s"
                   "README.md" "README.md" (if killed (mapcar (lambda (k) (if (eq k a) "util.py" (if (eq k b) "README.md" "guide.md"))) killed) "nothing"))
           r))))))
