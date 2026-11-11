;;; runners-view-test.el --- the runner list's rows: columns, reasons, faces -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): a row is text from the runner's record, so these tests feed records and read the text back.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/tools/drgnx-runners-view" drgnx-dir) nil t)

(defun runners-view-test--runner (name state &rest more)
  "A runner record as `runners/list' gives it (a plist, JSON keys as keywords)."
  (append more
          (list :name name :host "h" :trust "mine" :profile "dedicated" :accept "all" :cores 16 :mem_mib 31744
                :disk_free_gb 81 :jobs 4 :checked 50520.0 :state state)))

(ert-deftest drgnx-runners-view/columns-match-the-design ()
  "Pattern D: a ready runner is two lines, the CLI's columns: state dot, name, trust, profile and accept; then size,
jobs, free disk and the last check (UTC); no line is over 60 columns; headers are sentence case."
  (let* ((text (drgnx-runners-view-row (runners-view-test--runner "desktop" "ready")))
         (lines (split-string text "\n" t)))
    (should (= 2 (length lines)))
    (should (equal (substring-no-properties (nth 0 lines))
                   (format "%s desktop        mine      dedicated · all" (drgnx-face-glyph 'dot))))
    (should (equal (substring-no-properties (nth 1 lines)) "  16 cores · 31G · 4 running · 81G free · 14:02"))
    (dolist (l lines) (should (<= (string-width l) 60)))
    (should (string-suffix-p "\n" text))
    ;; numbers are in the code face
    (let ((pos (string-match "16" (nth 1 lines))))
      (should (memq 'drgnx-runners-number (ensure-list (get-text-property pos 'face (nth 1 lines))))))
    ;; the column titles are sentence case
    (should (equal drgnx-runners-view-titles '("Runner" "Trust" "Profile" "Accepts")))))

(ert-deftest drgnx-runners-view/a-benched-row-shows-its-reason ()
  "Pattern D: a runner out of rotation says why on lines of its own, wrapped to 60 columns, in the reason face; a
long name is cut to 14 columns."
  (let* ((why "benched: image pull failed twice (14:02, 14:20), and the next check is not due before you look")
         (text (drgnx-runners-view-row (runners-view-test--runner "a-long-runner-name-here" why)))
         (lines (split-string text "\n" t)))
    (should (string-search "a-long-runner-" (nth 0 lines)))
    (should-not (string-search "a-long-runner-name" (nth 0 lines)))
    (should (string-search "benched: image pull failed twice (14:02, 14:20)" (substring-no-properties text)))
    (should (> (length lines) 2))
    (dolist (l lines) (should (<= (string-width l) 60)))
    (let ((pos (string-match "benched" text)))
      (should (memq 'drgnx-runners-reason (ensure-list (get-text-property pos 'face text)))))
    ;; the dot of a runner out of rotation is the empty one
    (should (string-prefix-p (drgnx-face-glyph 'circle) (nth 0 lines)))))

(ert-deftest drgnx-runners-view/cost-column ()
  "Pattern D: a cloud runner's cost is its own line, `$0.42/h · $3.10 mo'; a cloud runner without a price shows a dash;
a machine of yours has no cost line; no line is over 60 columns."
  (let* ((priced (drgnx-runners-view-row
                  (runners-view-test--runner "spot-1" "ready" :trust "my-cloud" :cost_h 0.42 :cost_month 3.1)))
         (unpriced (drgnx-runners-view-row (runners-view-test--runner "spot-2" "ready" :trust "my-cloud")))
         (mine (drgnx-runners-view-row (runners-view-test--runner "desktop" "ready"))))
    (should (equal (substring-no-properties (nth 2 (split-string priced "\n" t))) "  cost $0.42/h · $3.10 mo"))
    (should (equal (substring-no-properties (nth 2 (split-string unpriced "\n" t))) "  cost —"))
    (should (= 2 (length (split-string mine "\n" t))))
    (dolist (l (split-string priced "\n" t)) (should (<= (string-width l) 60)))))

;; pattern D: a Mac runner's row has the macOS chip after its name and a line of its own: the memory watched by the
;; runner, the account it runs as, and whether the Command Line Tools answer; a sleeping Mac's dot is the subtle one
(ert-deftest drgnx-runners-view/a-mac-row ()
  (let* ((mac (runners-view-test--runner "mini" "ready" :host "drgnx-runner@mini.local" :os "macos 15.6"
                                         :features ["arch:aarch64" "host-jobs" "xcode-clt" "brew:cmake"]))
         (text (drgnx-runners-view-row mac))
         (lines (split-string text "\n" t)))
    (should (string-search "mini macOS" (substring-no-properties (nth 0 lines))))
    (should (eq 'drgnx-runners-os (get-text-property (string-search "macOS" text) 'face text)))
    (should (equal (substring-no-properties (nth 2 lines))
                   "  memory: watched · as drgnx-runner · Command Line Tools"))
    (dolist (l lines) (should (<= (string-width l) 60))))
  (let ((no-clt (drgnx-runners-view-row (runners-view-test--runner "mini" "ready" :host "mini" :os "macos 15.6"
                                                                   :features ["host-jobs"]))))
    (should (string-search "no Command Line Tools" no-clt)))
  ;; a Linux runner has neither
  (let ((linux (drgnx-runners-view-row (runners-view-test--runner "desktop" "ready" :os "fedora 45"))))
    (should-not (string-search "macOS" linux))
    (should-not (string-search "memory: watched" linux)))
  (should (eq 'drgnx-runners-subtle (drgnx-runners-view-dot-face "sleeping" 0))))

(provide 'runners-view-test)
;;; runners-view-test.el ends here
