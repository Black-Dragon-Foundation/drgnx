;;; ci-workflows-test.el --- the workflows read as text: what gates a push to main -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)

(defconst drgnx-ci-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-ci-test--yml (name)
  "The text of .github/workflows/NAME, or nil outside a checkout that has it."
  (let ((f (expand-file-name (concat ".github/workflows/" name) drgnx-ci-test--root)))
    (when (file-exists-p f)
      (with-temp-buffer (insert-file-contents f) (buffer-string)))))

(defun drgnx-ci-test--has (text &rest needles)
  (dolist (n needles) (should (string-search n text))))

(ert-deftest drgnx-ci/gui-runs-on-push-to-main ()
  (let ((gui (drgnx-ci-test--yml "gui.yml")))
    (skip-unless gui)
    (drgnx-ci-test--has gui "push:\n    branches: [main]" "schedule:" "workflow_dispatch:" "group: gui-${{ github.ref }}"
                        "bin/drgnx test --container --ui" "bin/drgnx test --container --scenario" "DRGNX_TEST_NO_TIMING: \"1\""
                        "bin/drgnx test --container --perf" "DRGNX_PERF_CPU_FACTOR: \"2\""
                        "DRGNX_PERF_RESULTS: perf-results.json" "if: always()" "name: perf-results")
    (should (= 3 (with-temp-buffer (insert gui) (goto-char (point-min)) (let ((n 0)) (while (re-search-forward "^  \\(ui\\|scenario\\|perf\\):$" nil t) (cl-incf n)) n))))))

(ert-deftest drgnx-ci/unit-jobs-rerun-and-skip-wall-clock ()
  (dolist (f '("ci.yml" "macos.yml"))
    (let ((yml (drgnx-ci-test--yml f)))
      (skip-unless yml)
      (drgnx-ci-test--has yml "DRGNX_TEST_RERUN: \"1\"" "DRGNX_TEST_NO_TIMING: \"1\"" "DRGNX_TEST_JOBS=")
      (should-not (string-search "(tag :timing)" yml))
      (should-not (string-search "emacs-30" yml)))))

(ert-deftest drgnx-ci/macos-has-no-time-factor ()
  (let ((yml (drgnx-ci-test--yml "macos.yml")))
    (skip-unless yml)
    (should-not (string-search "DRGNX_TEST_TIME_FACTOR" yml))))

(ert-deftest drgnx-ci/actions-are-pinned-by-sha ()
  (dolist (f '("ci.yml" "gui.yml" "macos.yml" "tty.yml"))
    (let ((yml (drgnx-ci-test--yml f)) (pos 0))
      (skip-unless yml)
      (while (string-match "uses: \\([^ \n]+\\)" yml pos)
        (setq pos (match-end 0))
        (should (string-match-p "@[0-9a-f]\\{40\\}\\'" (match-string 1 yml)))))))

(provide 'ci-workflows-test)
;;; ci-workflows-test.el ends here
