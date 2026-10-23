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
    (drgnx-ci-test--has gui "push:\n    branches: [main, \"ci/**\"]" "schedule:" "workflow_dispatch:"
                        "group: gui-${{ github.ref == 'refs/heads/main' && github.run_id || github.ref }}"
                        "bin/drgnx test --container --ui" "bin/drgnx test --container --scenario" "DRGNX_TEST_NO_TIMING: \"1\""
                        "bin/drgnx test --container --perf" "DRGNX_PERF_CPU_FACTOR: \"2\""
                        "DRGNX_PERF_RESULTS: perf-results.json" "if: always()" "name: perf-results")
    ;; the ui job leaves the :timing tests out too (no CI job runs one)
    (should (string-match-p "bin/drgnx test --container --ui" gui))
    (should (string-match-p "DRGNX_TEST_NO_TIMING: \"1\"\n        run: bin/drgnx test --container --ui" gui))
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
  (dolist (f '("ci.yml" "gui.yml" "macos.yml" "tty.yml" "runtime.yml"))
    (let ((yml (drgnx-ci-test--yml f)) (pos 0))
      (skip-unless yml)
      (while (string-match "uses: \\([^ \n]+\\)" yml pos)
        (setq pos (match-end 0))
        ;; a workflow of this repository (ci.yml calls runtime.yml) is a path, not an action
        (unless (string-prefix-p "./.github/workflows/" (match-string 1 yml))
          (should (string-match-p "@[0-9a-f]\\{40\\}\\'" (match-string 1 yml))))))))

(ert-deftest drgnx-ci/ci-calls-the-runtime-and-runs-the-editor-tests-on-its-own-binary ()
  (let ((ci (drgnx-ci-test--yml "ci.yml")) (rt (drgnx-ci-test--yml "runtime.yml")) (macos (drgnx-ci-test--yml "macos.yml")))
    (skip-unless (and ci rt macos))
    ;; ci.yml calls runtime.yml (so its jobs are in the CI gate); the unit suite builds its own Ratatoskr, so a red
    ;; runtime job never skips it (no `needs: runtime', no artifact to miss)
    (drgnx-ci-test--has ci "uses: ./.github/workflows/runtime.yml" "DRGNX_RATATOSKR_BIN=")
    (should-not (string-search "download-artifact" ci))
    (drgnx-ci-test--has rt "workflow_call:" "--require-all"
                        "xcode-27" "nightly-2026-10-15" "cargo-fuzz --version 0.13.2" "--perf perf-")
    ;; its own triggers carry no push or pull_request: ci.yml's call is that run (a second one would build everything twice)
    (should-not (string-match-p "^  \\(push\\|pull_request\\):" rt))
    (drgnx-ci-test--has macos "DRGNX_RATATOSKR_BIN=" "brew install ripgrep rust")
    ;; the client's tests that need --idle-tick-ms are on the no-skip lists: the binary they use has the test hooks; the
    ;; gateway tests' provider, ratatoskr-mock, is built beside it
    (dolist (yml (list ci macos))
      (drgnx-ci-test--has yml "-p drgnx-ratatoskr -p domr" "--features drgnx-ratatoskr/test-hooks --bin ratatoskr --bin ratatoskr-mock"))))

;; CI runs on a ci/* branch before main moves, and one always-run gate per push workflow is what branch protection
;; requires: it fails unless every push job succeeded (docs/develop/ci.md, "Gates").
(defun drgnx-ci-test--job-ids (yml)
  (drgnx-ci-test--matches "^  \\([a-z0-9-]+\\):$" (substring yml (string-search "\njobs:\n" yml))))

(ert-deftest drgnx-ci/each-push-workflow-ends-in-one-gate-over-its-push-jobs ()
  ;; (file, the gate's name, the jobs that never run on a push)
  (dolist (spec '(("ci.yml" "CI gate" nil) ("macos.yml" "macOS gate" ("install")) ("gui.yml" "GUI tier gate" nil)))
    (let ((yml (drgnx-ci-test--yml (car spec))))
      (skip-unless yml)
      (drgnx-ci-test--has yml "push:\n    branches: [main, \"ci/**\"]"
                          "cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}"
                          "'refs/heads/main' && github.run_id || github.ref }}"
                          (concat "  gate:\n    name: " (nth 1 spec) "\n")
                          "jq -e 'all(.[]; .result == \"success\")'")
      (let* ((gate (substring yml (string-search "\n  gate:\n" yml)))
             (needs (and (string-match "^    needs: \\[\\([^]]*\\)\\]$" gate)
                         (split-string (match-string 1 gate) ", *" t))))
        (should (string-match-p "^    if: \\${{ always() \\|^    if: always()$" gate))
        (should (equal (sort (copy-sequence needs) #'string<)
                       (sort (cl-set-difference (drgnx-ci-test--job-ids yml) (cons "gate" (nth 2 spec)) :test #'equal)
                             #'string<)))
        ;; the gate's are the only `needs:' (no job waits on another it does not take data from)
        (should (= 1 (length (let ((case-fold-search nil)) ; not the gate's NEEDS variable
                               (drgnx-ci-test--matches "^ +\\(needs\\):" yml)))))))))

(ert-deftest drgnx-ci/nothing-stops-early ()
  (dolist (f '("ci.yml" "macos.yml" "gui.yml" "tty.yml" "images.yml" "bootstrap.yml" "runtime.yml"))
    (let ((yml (drgnx-ci-test--yml f)))
      (skip-unless yml)
      ;; every cargo test runs every crate's tests, every matrix every row, and no job's failure is let off
      (dolist (line (drgnx-ci-test--matches "^\\(.*cargo[^\n]* test .*\\)$" yml))
        (should (string-search "--no-fail-fast" line)))
      (should (= (length (drgnx-ci-test--matches "\\(strategy:\\)" yml))
                 (length (drgnx-ci-test--matches "\\(fail-fast: false\\)" yml))))
      (should-not (string-search "continue-on-error" yml))
      (should-not (string-search "needs: runtime" yml)))))

;; Caches: a cached input is addressed by a hash of what it is built from, so a stale one cannot be restored.
(defun drgnx-ci-test--matches (re text)
  (let ((pos 0) out)
    (while (string-match re text pos) (push (match-string 1 text) out) (setq pos (match-end 0)))
    (nreverse out)))

(ert-deftest drgnx-ci/every-actions-cache-key-hashes-its-inputs ()
  (dolist (f '("ci.yml" "macos.yml" "gui.yml" "tty.yml" "images.yml" "bootstrap.yml" "runtime.yml"))
    (let ((yml (drgnx-ci-test--yml f)))
      (skip-unless yml)
      ;; each actions/cache step: its key line hashes files (hashFiles) and a restore-keys line, when there is one,
      ;; stops short of the hash only by a trailing part (never a bare OS prefix)
      (dolist (step (cdr (split-string yml "uses: actions/cache@")))
        (let ((head (car (split-string step "\n      - " t))))
          (should (string-match "^ *key: \\(.*\\)$" head))
          (should (string-search "hashFiles(" (match-string 1 head)))
          (when (string-match "^ *restore-keys: \\(.*\\)$" head)
            (should (string-search "hashFiles(" (match-string 1 head)))))))))

(ert-deftest drgnx-ci/prebuilt-images-are-addressed-by-their-containerfile-hash ()
  (let ((images (drgnx-ci-test--yml "images.yml")))
    (skip-unless images)
    (dolist (f '("ci.yml" "gui.yml" "tty.yml"))
      (let ((yml (drgnx-ci-test--yml f)))
        (skip-unless yml)
        (let ((pulls (drgnx-ci-test--matches
                      "image=\"ghcr.io/black-dragon-foundation/\\([^:]+\\):\\$(sha256sum test/container/\\([A-Za-z.]+\\) | cut -c1-16)\"" yml)))
          (should pulls)
          ;; every pull is of an image images.yml publishes, from the same Containerfile, tagged by the same hash
          (let ((all (drgnx-ci-test--matches "image=\"ghcr.io/black-dragon-foundation/\\([^:]+\\)" yml)))
            (should (= (length all) (length pulls))))))
      (let ((yml (drgnx-ci-test--yml f)) (pos 0))
        (skip-unless yml)
        (while (string-match "ghcr.io/black-dragon-foundation/\\([^:]+\\):\\$(sha256sum test/container/\\([A-Za-z.]+\\) " yml pos)
          (setq pos (match-end 0))
          (should (string-match-p (format "- name: %s\n *file: %s\n" (regexp-quote (match-string 1 yml)) (regexp-quote (match-string 2 yml)))
                                  images)))))
    (drgnx-ci-test--has images "tag=\"$(sha256sum \"test/container/$FILE\" | cut -c1-16)\"" "podman push \"$image:$tag\"")
    ;; a pulled image falls back to building, never to nothing; the run uses the image through its env variable
    (dolist (spec '(("ci.yml" "DRGNX_TEST_IMAGE") ("gui.yml" "DRGNX_TEST_GUI_IMAGE") ("tty.yml" "DRGNX_TEST_TTY_IMAGE")))
      (let ((yml (drgnx-ci-test--yml (car spec))))
        (skip-unless yml)
        (drgnx-ci-test--has yml (concat (cadr spec) "=$image") "podman pull -q \"$image\"" "else the")))))

(provide 'ci-workflows-test)
;;; ci-workflows-test.el ends here
