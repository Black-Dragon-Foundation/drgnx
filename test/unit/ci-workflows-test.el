;;; ci-workflows-test.el --- the workflows read as text: what gates a push to main -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)

(defconst drgnx-ci-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-ci-test--file (rel)
  "The text of the checkout's file REL, or nil outside a checkout that has it."
  (let ((f (expand-file-name rel drgnx-ci-test--root)))
    (when (file-exists-p f)
      (with-temp-buffer (insert-file-contents f) (buffer-string)))))

(defun drgnx-ci-test--yml (name)
  "The text of .github/workflows/NAME, or nil outside a checkout that has it."
  (drgnx-ci-test--file (concat ".github/workflows/" name)))

(defun drgnx-ci-test--action (name)
  "The text of .github/actions/NAME/action.yml, or nil outside a checkout that has it."
  (drgnx-ci-test--file (concat ".github/actions/" name "/action.yml")))

(defconst drgnx-ci-test--actions '("build-test-bins" "fetch-test-bins" "test-image" "gate"))

(defun drgnx-ci-test--has (text &rest needles)
  (dolist (n needles) (should (string-search n text))))

(defun drgnx-ci-test--job (yml id)
  "The text of job ID in YML, up to the next job."
  (let ((start (string-search (concat "\n  " id ":\n") yml)))
    (should start)
    (let ((end (string-match "\n  [a-z0-9-]+:\n" yml (1+ start))))
      (substring yml start end))))

;; The tiers: one definition (drgnx-tiers.yml) of drgnx's Emacs-side jobs, called by drgnx's push workflows on the
;; pinned release and by Nidhogg's CI on the tarballs it built (docs/develop/ci.md, "The tiers workflow").
(ert-deftest drgnx-ci/the-push-workflows-call-the-tiers-workflow ()
  (dolist (spec '(("ci.yml" "unit no-lisp-writes") ("gui.yml" "ui scenario perf") ("macos.yml" "macos")))
    (let ((yml (drgnx-ci-test--yml (car spec))))
      (skip-unless yml)
      (drgnx-ci-test--has yml "uses: ./.github/workflows/drgnx-tiers.yml" "nidhogg: release"
                          (concat "tiers: " (cadr spec) "\n"))
      ;; no test step of its own: the tiers workflow is the one place those steps live
      (should-not (string-search "bin/drgnx test" yml)))))

(ert-deftest drgnx-ci/the-tiers-workflow-runs-each-tier-only-when-asked ()
  (let ((tiers (drgnx-ci-test--yml "drgnx-tiers.yml")))
    (skip-unless tiers)
    (drgnx-ci-test--has tiers "workflow_call:" "drgnx_ref:" "nidhogg:" "tiers:" "drgnx_commit:")
    (dolist (job '("unit" "no-lisp-writes" "ui" "scenario" "perf" "macos"))
      (should (string-search (format "contains(format(' {0} ', inputs.tiers), ' %s ')" job)
                             (drgnx-ci-test--job tiers job))))
    ;; every job checks drgnx out into drgnx/ (in Nidhogg's run the caller's checkout is Nidhogg), at the asked ref
    (let ((count (lambda (needle) (length (drgnx-ci-test--matches (concat "\\(" (regexp-quote needle) "\\)") tiers)))))
      (should (= 7 (funcall count "runs-on:")))
      (should (= 7 (funcall count "          path: drgnx\n")))
      (should (= 7 (funcall count "          ref: ${{ inputs.drgnx_ref }}\n"))))
    ;; the Linux jobs that run Ratatoskr fetch the binaries the run built once; macOS builds its own
    (dolist (job '("unit" "no-lisp-writes" "ui"))
      (drgnx-ci-test--has (drgnx-ci-test--job tiers job) "needs: bins-linux" "uses: ./drgnx/.github/actions/fetch-test-bins"))
    (drgnx-ci-test--has (drgnx-ci-test--job tiers "bins-linux")
                        "uses: ./drgnx/.github/actions/build-test-bins" "name: drgnx-test-bins-linux" "retention-days: 1")
    (drgnx-ci-test--has (drgnx-ci-test--job tiers "macos") "uses: ./drgnx/.github/actions/build-test-bins"
                        "brew install ripgrep rust" "test/container/nidhogg.sh macos")
    ;; `nidhogg: artifact' puts the run's own build under the tests: the overlay on Linux, the tarball on macOS
    (drgnx-ci-test--has tiers "nidhogg-artifact: ${{ inputs.nidhogg == 'artifact' && 'tarball-fedora-45' || '' }}"
                        "name: tarball-macos")))

(ert-deftest drgnx-ci/gui-runs-on-push-to-main ()
  (let ((gui (drgnx-ci-test--yml "gui.yml")) (tiers (drgnx-ci-test--yml "drgnx-tiers.yml")))
    (skip-unless (and gui tiers))
    (drgnx-ci-test--has gui "push:\n    branches: [main, \"ci/**\", \"!ci/joint/**\"]" "schedule:" "workflow_dispatch:"
                        "group: gui-${{ github.ref == 'refs/heads/main' && github.run_id || github.ref }}")
    (drgnx-ci-test--has tiers "bin/drgnx test --container --ui" "bin/drgnx test --container --scenario"
                        "bin/drgnx test --container --perf" "DRGNX_PERF_CPU_FACTOR: \"2\""
                        "DRGNX_PERF_RESULTS: perf-results.json" "if: always()" "name: perf-results")
    ;; the ui job leaves the :timing tests out too (no CI job runs one)
    (should (string-match-p (concat "DRGNX_TEST_NO_TIMING: \"1\"\n\\(?:          [A-Z_]+: .*\n\\)*"
                                    "        run: bin/drgnx test --container --ui")
                            (drgnx-ci-test--job tiers "ui")))))

(ert-deftest drgnx-ci/unit-jobs-rerun-and-skip-wall-clock ()
  (let ((tiers (drgnx-ci-test--yml "drgnx-tiers.yml")))
    (skip-unless tiers)
    (dolist (job '("unit" "no-lisp-writes" "macos"))
      (drgnx-ci-test--has (drgnx-ci-test--job tiers job) "DRGNX_TEST_RERUN: \"1\"" "DRGNX_TEST_NO_TIMING: \"1\"" "DRGNX_TEST_JOBS="))
    (should-not (string-search "(tag :timing)" tiers))
    (should-not (string-search "emacs-30" tiers))))

(ert-deftest drgnx-ci/macos-has-no-time-factor ()
  (dolist (f '("macos.yml" "drgnx-tiers.yml"))
    (let ((yml (drgnx-ci-test--yml f)))
      (skip-unless yml)
      (should-not (string-search "DRGNX_TEST_TIME_FACTOR" yml)))))

(defun drgnx-ci-test--workflows-and-actions (workflows)
  "The text of each of WORKFLOWS and of every local action."
  (append (mapcar #'drgnx-ci-test--yml workflows) (mapcar #'drgnx-ci-test--action drgnx-ci-test--actions)))

(ert-deftest drgnx-ci/actions-are-pinned-by-sha ()
  (dolist (yml (drgnx-ci-test--workflows-and-actions
                '("ci.yml" "gui.yml" "macos.yml" "drgnx-tiers.yml" "tty.yml" "runtime.yml")))
    (let ((pos 0))
      (skip-unless yml)
      (while (string-match "uses: \\([^ \n]+\\)" yml pos)
        (setq pos (match-end 0))
        ;; a workflow or action of this repository (ci.yml calls runtime.yml) is a path, not a pinned action
        (unless (string-prefix-p "./" (match-string 1 yml))
          (should (string-match-p "@[0-9a-f]\\{40\\}\\'" (match-string 1 yml))))))))

(ert-deftest drgnx-ci/ci-calls-the-runtime-and-runs-the-editor-tests-on-its-own-binary ()
  (let ((ci (drgnx-ci-test--yml "ci.yml")) (rt (drgnx-ci-test--yml "runtime.yml"))
        (bins (drgnx-ci-test--action "build-test-bins")))
    (skip-unless (and ci rt bins))
    ;; ci.yml calls runtime.yml (so its jobs are in the CI gate); the tiers build their own Ratatoskr, so a red
    ;; runtime job never skips them (no `needs: runtime', no artifact of another workflow to miss)
    (drgnx-ci-test--has ci "uses: ./.github/workflows/runtime.yml" "uses: ./.github/workflows/drgnx-tiers.yml")
    (should-not (string-search "download-artifact" ci))
    (drgnx-ci-test--has rt "workflow_call:" "--require-all"
                        "xcode-27" "nightly-2026-10-15" "cargo-fuzz --version 0.13.2" "--perf perf-")
    ;; its own triggers carry no push or pull_request: ci.yml's call is that run (a second one would build everything twice)
    (should-not (string-match-p "^  \\(push\\|pull_request\\):" rt))
    ;; the client's tests that need --idle-tick-ms are on the no-skip lists: the binary they use has the test hooks; the
    ;; gateway tests' provider, ratatoskr-mock, is built beside it, and huginn's dump example for the differential test
    (drgnx-ci-test--has bins "-p drgnx-ratatoskr -p domr" "--features drgnx-ratatoskr/test-hooks --bin ratatoskr --bin ratatoskr-mock"
                        "-p huginn --example dump" "DRGNX_RATATOSKR_BIN=" "DRGNX_HUGINN_DUMP=")
    (drgnx-ci-test--has (drgnx-ci-test--action "fetch-test-bins") "runtime/target/debug" "chmod +x"
                        "DRGNX_RATATOSKR_BIN=" "DRGNX_HUGINN_DUMP=")))

;; CI runs on a ci/* branch before main moves, and one always-run gate per push workflow is what branch protection
;; requires: it fails unless every push job succeeded (docs/develop/ci.md, "Gates").
(defun drgnx-ci-test--job-ids (yml)
  (drgnx-ci-test--matches "^  \\([a-z0-9-]+\\):$" (substring yml (string-search "\njobs:\n" yml))))

(ert-deftest drgnx-ci/each-push-workflow-ends-in-one-gate-over-its-push-jobs ()
  ;; (file, the gate's name, the jobs that never run on a push, its push branches)
  (dolist (spec '(("ci.yml" "CI gate" nil "[main, \"ci/**\"]")
                  ("macos.yml" "macOS gate" ("install") "[main, \"ci/**\", \"!ci/joint/**\"]")
                  ("gui.yml" "GUI tier gate" nil "[main, \"ci/**\", \"!ci/joint/**\"]")))
    (let ((yml (drgnx-ci-test--yml (car spec))))
      (skip-unless yml)
      (drgnx-ci-test--has yml (concat "push:\n    branches: " (nth 3 spec))
                          "cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}"
                          "'refs/heads/main' && github.run_id || github.ref }}"
                          (concat "  gate:\n    name: " (nth 1 spec) "\n")
                          "uses: ./.github/actions/gate" "needs: ${{ toJSON(needs) }}")
      (let* ((gate (substring yml (string-search "\n  gate:\n" yml)))
             (needs (and (string-match "^    needs: \\[\\([^]]*\\)\\]$" gate)
                         (split-string (match-string 1 gate) ", *" t))))
        (should (string-match-p "^    if: \\${{ always() \\|^    if: always()$" gate))
        (should (equal (sort (copy-sequence needs) #'string<)
                       (sort (cl-set-difference (drgnx-ci-test--job-ids yml) (cons "gate" (nth 2 spec)) :test #'equal)
                             #'string<)))
        ;; the gate's are the only `needs:' (no job waits on another it does not take data from); a job's own key,
        ;; not the gate action's `needs' input
        (should (= 1 (length (drgnx-ci-test--matches "^    \\(needs\\):" yml))))))
    (drgnx-ci-test--has (drgnx-ci-test--action "gate")
                        "all(.value.result == \"success\" or (.value.result == \"skipped\" and")))

;; A joint round (both repositories change): drgnx's ci/joint/<name> branch runs only what does not need Emacs; the
;; tiers run once, in Nidhogg's run on its new build (docs/develop/ci.md, "Joint rounds").
(ert-deftest drgnx-ci/a-joint-round-skips-the-tiers-only-on-its-own-branch ()
  (let ((ci (drgnx-ci-test--yml "ci.yml")))
    (skip-unless ci)
    (drgnx-ci-test--has (drgnx-ci-test--job ci "tiers") "if: ${{ !startsWith(github.ref, 'refs/heads/ci/joint/') }}")
    ;; the gate lets the tiers be skipped there and nowhere else, and nothing but the tiers
    (drgnx-ci-test--has (drgnx-ci-test--job ci "gate")
                        "allow-skipped: ${{ startsWith(github.ref, 'refs/heads/ci/joint/') && 'tiers' || '' }}")
    (dolist (f '("gui.yml" "macos.yml"))
      (should-not (string-search "allow-skipped" (drgnx-ci-test--yml f))))))

(ert-deftest drgnx-ci/nothing-stops-early ()
  (dolist (yml (drgnx-ci-test--workflows-and-actions
                '("ci.yml" "macos.yml" "gui.yml" "drgnx-tiers.yml" "tty.yml" "images.yml" "bootstrap.yml" "runtime.yml")))
    (skip-unless yml)
    ;; every cargo test runs every crate's tests, every matrix every row, and no job's failure is let off
    (dolist (line (drgnx-ci-test--matches "^\\(.*cargo[^\n]* test .*\\)$" yml))
      (should (string-search "--no-fail-fast" line)))
    (should (= (length (drgnx-ci-test--matches "\\(strategy:\\)" yml))
               (length (drgnx-ci-test--matches "\\(fail-fast: false\\)" yml))))
    (should-not (string-search "continue-on-error" yml))
    (should-not (string-search "needs: runtime" yml))))

;; Caches: a cached input is addressed by a hash of what it is built from, so a stale one cannot be restored.
(defun drgnx-ci-test--matches (re text)
  (let ((pos 0) out)
    (while (string-match re text pos) (push (match-string 1 text) out) (setq pos (match-end 0)))
    (nreverse out)))

(ert-deftest drgnx-ci/every-actions-cache-key-hashes-its-inputs ()
  (dolist (yml (drgnx-ci-test--workflows-and-actions
                '("ci.yml" "macos.yml" "gui.yml" "drgnx-tiers.yml" "tty.yml" "images.yml" "bootstrap.yml" "runtime.yml")))
    (skip-unless yml)
    ;; each actions/cache step: its key line hashes files (hashFiles) and a restore-keys line, when there is one,
    ;; stops short of the hash only by a trailing part (never a bare OS prefix)
    (dolist (step (cdr (split-string yml "uses: actions/cache@")))
      (let ((head (car (split-string step "\n *- " t))))
        (should (string-match "^ *key: \\(.*\\)$" head))
        (should (string-search "hashFiles(" (match-string 1 head)))
        (when (string-match "^ *restore-keys: \\(.*\\)$" head)
          (should (string-search "hashFiles(" (match-string 1 head))))))))

(ert-deftest drgnx-ci/prebuilt-images-are-addressed-by-their-containerfile-hash ()
  (let ((images (drgnx-ci-test--yml "images.yml")) (tty (drgnx-ci-test--yml "tty.yml"))
        (action (drgnx-ci-test--action "test-image")) (tiers (drgnx-ci-test--yml "drgnx-tiers.yml")))
    (skip-unless (and images tty action tiers))
    ;; the tiers' image: the one images.yml publishes for that Containerfile, tagged by the same hash
    (drgnx-ci-test--has action "image=\"ghcr.io/black-dragon-foundation/$NAME:$(sha256sum \"test/container/$FILE\" | cut -c1-16)\""
                        "podman pull -q \"$image\"" "echo \"$VAR=$base\"")
    (let ((pairs (drgnx-ci-test--matches "containerfile: \\([A-Za-z.]+\n *image: [a-z-]+\n *variable: [A-Z_]+\\)" tiers)))
      (should (= 5 (length pairs)))
      (dolist (p pairs)
        (should (string-match "\\`\\([A-Za-z.]+\\)\n *image: \\([a-z-]+\\)\n *variable: \\([A-Z_]+\\)\\'" p))
        (let ((file (match-string 1 p)) (name (match-string 2 p)) (var (match-string 3 p)))
          (should (string-match-p (format "- name: %s\n *file: %s\n" (regexp-quote name) (regexp-quote file)) images))
          (should (equal var (if (equal file "Containerfile") "DRGNX_TEST_IMAGE" "DRGNX_TEST_GUI_IMAGE"))))))
    ;; the terminal tier pulls its own the same way
    (drgnx-ci-test--has tty "image=\"ghcr.io/black-dragon-foundation/drgnx-test-tty:$(sha256sum test/container/Containerfile.tty | cut -c1-16)\""
                        "DRGNX_TEST_TTY_IMAGE=$image" "podman pull -q \"$image\"")
    (drgnx-ci-test--has images "tag=\"$(sha256sum \"test/container/$FILE\" | cut -c1-16)\"" "podman push \"$image:$tag\"")))

;; The overlay (`nidhogg-artifact'): the run's own Nidhogg goes into the test image the same way the pinned release
;; goes into it, through test/container/nidhogg.sh, and never quietly falls back to the release.
(ert-deftest drgnx-ci/the-overlay-installs-the-run-s-tarball-with-nidhogg-sh ()
  (let ((action (drgnx-ci-test--action "test-image")))
    (skip-unless action)
    (drgnx-ci-test--has action "uses: actions/download-artifact@" "name: ${{ inputs.nidhogg-artifact }}"
                        "\"FROM $base\"" "RUN bash /tmp/nidhogg.sh fedora-45 /tmp/nidhogg.tar.xz"
                        "expected one Nidhogg tarball" "echo \"$VAR=localhost/$NAME-nidhogg:run\"")))

(ert-deftest drgnx-ci/nidhogg-sh-installs-a-local-tarball-without-a-download ()
  ;; the macOS branch, run for real on a made-up tarball: brew is a stub, curl is not reachable (a download fails)
  (skip-unless (and (executable-find "tar") (executable-find "xz")))
  (let* ((tmp (make-temp-file "drgnx-nh-local" t))
         (bin (expand-file-name "bin" tmp)) (top (expand-file-name "nidhogg-31.1-nidhogg.9" tmp))
         (app (expand-file-name "Nidhogg.app/Contents/MacOS" top))
         (tarball (expand-file-name "t.tar.xz" tmp)) (env-file (expand-file-name "github-env" tmp)))
    (unwind-protect
        (progn
          (make-directory bin t) (make-directory app t)
          (with-temp-file (expand-file-name "deps.runtime" top) (insert "# none\n"))
          (with-temp-file (expand-file-name "Emacs" app) (insert "#!/bin/sh\necho 'GNU Emacs 31.1 (local)'\n"))
          (set-file-modes (expand-file-name "Emacs" app) #o755)
          (dolist (stub '("brew" "curl"))
            (with-temp-file (expand-file-name stub bin)
              (insert (if (equal stub "curl") "#!/bin/sh\necho curl-called >&2\nexit 7\n" "#!/bin/sh\nexit 0\n")))
            (set-file-modes (expand-file-name stub bin) #o755))
          (should (eq 0 (call-process "tar" nil nil nil "-C" tmp "-cJf" tarball "nidhogg-31.1-nidhogg.9")))
          (with-temp-buffer
            (let ((process-environment
                   (append (list (concat "PATH=" bin ":" (getenv "PATH")) (concat "RUNNER_TEMP=" tmp)
                                 (concat "TMPDIR=" tmp) (concat "GITHUB_ENV=" env-file))
                           process-environment)))
              (should (eq 0 (call-process "bash" nil t nil
                                          (expand-file-name "test/container/nidhogg.sh" drgnx-ci-test--root)
                                          "macos" tarball))))
            (should (string-search "GNU Emacs 31.1 (local)" (buffer-string)))
            (should-not (string-search "curl-called" (buffer-string))))
          (should (equal (with-temp-buffer (insert-file-contents env-file) (buffer-string))
                         (concat "DRGNX_EMACS=" tmp "/nidhogg/Nidhogg.app/Contents/MacOS/Emacs\n"))))
      (delete-directory tmp t))))

(provide 'ci-workflows-test)
;;; ci-workflows-test.el ends here
