;;; ci-workflows-test.el --- the workflows read as text: what gates a push to main -*- lexical-binding: t -*-
;; test-class: det
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

(defconst drgnx-ci-test--actions '("build-test-bins" "fetch-test-bins" "test-image" "gate" "test-elpa"))

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
  ;; (file, its `tiers:' line): the path filter's tiers, all of the workflow's when it said nothing
  (dolist (spec '(("ci.yml" "${{ needs.changes.outputs.tiers || 'unit no-lisp-writes hub-chaos' }}")
                  ("gui.yml" "${{ needs.changes.outputs.tiers || 'ui scenario perf' }}")
                  ("macos.yml" "macos") ("tty.yml" "tty")))
    (let ((yml (drgnx-ci-test--yml (car spec))))
      (skip-unless yml)
      ;; Nidhogg's integration line while drgnx's next release is unreleased, its App passed on
      (drgnx-ci-test--has yml "uses: ./.github/workflows/drgnx-tiers.yml" "nidhogg: line"
                          "NIDHOGG_LINE_APP_ID: ${{ secrets.NIDHOGG_LINE_APP_ID }}"
                          "NIDHOGG_LINE_APP_KEY: ${{ secrets.NIDHOGG_LINE_APP_KEY }}"
                          (concat "tiers: " (cadr spec) "\n"))
      ;; no test step of its own: the tiers workflow is the one place those steps live
      (should-not (string-search "bin/drgnx test" yml)))))

(ert-deftest drgnx-ci/the-tiers-fail-a-missing-nidhogg-primitive-on-the-line ()
  ;; on `nidhogg: line' / `artifact' every test job runs strict (a missing primitive fails, as in the local runs);
  ;; on `release' the value is empty, which drgnx-test-require-nidhogg reads as off (it compares to "1")
  (let ((tiers (drgnx-ci-test--yml "drgnx-tiers.yml")))
    (skip-unless tiers)
    (drgnx-ci-test--has tiers "\nenv:\n  DRGNX_NIDHOGG_STRICT: ${{ (inputs.nidhogg == 'line' || inputs.nidhogg == 'artifact') && '1' || '' }}\n")))

(ert-deftest drgnx-ci/the-tiers-workflow-runs-each-tier-only-when-asked ()
  (let ((tiers (drgnx-ci-test--yml "drgnx-tiers.yml")))
    (skip-unless tiers)
    (drgnx-ci-test--has tiers "workflow_call:" "drgnx_ref:" "nidhogg:" "tiers:" "drgnx_commit:")
    (dolist (job '("unit" "no-lisp-writes" "hub-chaos" "ui" "scenario" "perf" "tty" "timing" "macos"))
      (should (string-search (format "contains(format(' {0} ', inputs.tiers), ' %s ')" job)
                             (drgnx-ci-test--job tiers job))))
    ;; every job checks drgnx out into drgnx/ (in Nidhogg's run the caller's checkout is Nidhogg), at the asked ref
    (let ((count (lambda (needle) (length (drgnx-ci-test--matches (concat "\\(" (regexp-quote needle) "\\)") tiers)))))
      (should (= 11 (funcall count "runs-on:")))   ; the ten tiers and nidhogg-line
      (should (= 11 (funcall count "          path: drgnx\n")))
      (should (= 11 (funcall count "          ref: ${{ inputs.drgnx_ref || github.event.pull_request.head.sha }}\n"))))
    ;; the Linux jobs that run Ratatoskr fetch the binaries the run built once; macOS builds its own
    (dolist (job '("unit" "no-lisp-writes" "hub-chaos" "ui" "perf"))
      (drgnx-ci-test--has (drgnx-ci-test--job tiers job) "needs: [bins-linux, nidhogg-line]" "uses: ./drgnx/.github/actions/fetch-test-bins"))
    ;; and bins-linux runs for each of them
    (dolist (tier '("unit" "no-lisp-writes" "hub-chaos" "ui" "perf"))
      (should (string-search (format "contains(format(' {0} ', inputs.tiers), ' %s ')" tier)
                             (drgnx-ci-test--job tiers "bins-linux"))))
    (drgnx-ci-test--has (drgnx-ci-test--job tiers "bins-linux")
                        "uses: ./drgnx/.github/actions/build-test-bins" "name: drgnx-test-bins-linux" "retention-days: 1")
    (drgnx-ci-test--has (drgnx-ci-test--job tiers "macos") "uses: ./drgnx/.github/actions/build-test-bins"
                        "brew install ripgrep\n" "rustup toolchain install stable --profile minimal"
                        "test/container/nidhogg.sh macos")
    ;; neither macOS job installs Homebrew's rust (the image's rustup is quicker)
    (should-not (string-search "brew install ripgrep rust" tiers))
    (should-not (string-search "brew install rust" (drgnx-ci-test--yml "runtime.yml")))
    ;; `nidhogg: artifact' puts the run's own build under the tests: the overlay on Linux, the tarball on macOS
    (drgnx-ci-test--has tiers "nidhogg-artifact: ${{ (inputs.nidhogg == 'artifact' || inputs.nidhogg == 'line') && 'tarball-fedora-45' || '' }}"
                        "name: tarball-macos")))

(ert-deftest drgnx-ci/nidhogg-line-installs-the-line-s-green-build-or-fails ()
  ;; `nidhogg: line': the nidhogg-line job copies the tarballs of Nidhogg's green build of the line's head into the run
  ;; under the artifact names, every tier job waits for it and installs them as `artifact' does; it never falls back
  (let ((tiers (drgnx-ci-test--yml "drgnx-tiers.yml"))
        (sh (drgnx-ci-test--file ".github/ci/nidhogg-line.sh"))
        (line (drgnx-ci-test--file ".github/ci/nidhogg-line")))
    (skip-unless (and tiers sh line))
    (drgnx-ci-test--has (drgnx-ci-test--job tiers "nidhogg-line")
                        "if: ${{ inputs.nidhogg == 'line' }}" "uses: actions/create-github-app-token@"
                        "permission-actions: read" "repositories: nidhogg" "bash drgnx/.github/ci/nidhogg-line.sh $NAMES"
                        "run-id: ${{ steps.line.outputs.run }}" "github-token: ${{ steps.token.outputs.token }}"
                        "uses: actions/upload-artifact@" "name: tarball-fedora-45" "name: tarball-macos")
    (dolist (job '("unit" "no-lisp-writes" "hub-chaos" "ui" "scenario" "perf" "tty" "timing" "macos"))
      (drgnx-ci-test--has (drgnx-ci-test--job tiers job) "nidhogg-line" "needs.nidhogg-line.result != 'failure'"))
    (drgnx-ci-test--has (drgnx-ci-test--job tiers "macos") "if [ \"$MODE\" = artifact ] || [ \"$MODE\" = line ]; then")
    (drgnx-ci-test--has sh "status=completed" "never falls back to the release" "exit 1")
    (should (string-match-p "^[a-z0-9][a-z0-9./_-]*$" line))))   ; a line of its own names the branch

(defun drgnx-ci-test--line (artifacts runs)
  "Run nidhogg-line.sh for ARTIFACTS with a stub git and gh; RUNS is ((ID JOBS ARTIFACTS)...) newest first.
Returns (EXIT . OUTPUT)."
  (let* ((dir (make-temp-file "drgnx-line" t)) (bin (expand-file-name "bin" dir)) (data (expand-file-name "data" dir))
         (ci (expand-file-name "ci" dir)))
    (unwind-protect
        (progn
          (dolist (d (list bin data ci)) (make-directory d))
          (dolist (f '("nidhogg-line" "nidhogg-line.sh"))
            (copy-file (expand-file-name (concat ".github/ci/" f) drgnx-ci-test--root) (expand-file-name f ci)))
          (with-temp-file (expand-file-name "runs" data)
            (dolist (r runs) (insert (format "%s\n" (car r)))))
          (dolist (r runs)
            (with-temp-file (expand-file-name (format "jobs-%s" (car r)) data) (dolist (j (nth 1 r)) (insert j "\n")))
            (with-temp-file (expand-file-name (format "artifacts-%s" (car r)) data) (dolist (a (nth 2 r)) (insert a "\n"))))
          (with-temp-file (expand-file-name "git" bin) (insert "#!/bin/sh\nprintf 'abc123def456\\trefs/heads/x\\n'\n"))
          (with-temp-file (expand-file-name "gh" bin)
            (insert "#!/bin/sh\ncase \"$2\" in\n *workflows/build.yml/runs*) cat \"$DATA/runs\" ;;\n"
                    " */runs/*/jobs*) r=${2#*/runs/}; cat \"$DATA/jobs-${r%%/*}\" ;;\n"
                    " */runs/*/artifacts*) r=${2#*/runs/}; cat \"$DATA/artifacts-${r%%/*}\" ;;\nesac\n"))
          (set-file-modes (expand-file-name "git" bin) #o755)
          (set-file-modes (expand-file-name "gh" bin) #o755)
          (let ((process-environment (append (list (format "PATH=%s:%s" bin (getenv "PATH")) (concat "DATA=" data))
                                             process-environment)))
            (with-temp-buffer
              (let ((rc (apply #'call-process "bash" nil t nil (expand-file-name "nidhogg-line.sh" ci) artifacts)))
                (cons rc (buffer-string))))))
      (delete-directory dir t))))

(ert-deftest drgnx-ci/the-line-takes-the-head-s-run-whose-tarball-jobs-passed ()
  ;; the run may be red (its test jobs); what counts is the job that builds each asked tarball, and the artifact
  (skip-unless (drgnx-ci-test--file ".github/ci/nidhogg-line.sh"))
  (let* ((both '("Linux (fedora-45)" "macOS (NS app)")) (arts '("tarball-fedora-45" "tarball-macos"))
         (red (list "7" both arts)))
    ;; a red run whose tarball jobs succeeded is picked
    (let ((r (drgnx-ci-test--line '("tarball-fedora-45" "tarball-macos") (list red))))
      (should (= 0 (car r)))
      (should (string-match-p "^commit=abc123def456$" (cdr r)))
      (should (string-match-p "^run=7$" (cdr r))))
    ;; the newest run whose tarball job failed is skipped for an older one that has it
    (let ((r (drgnx-ci-test--line '("tarball-macos") (list (list "9" '("Linux (fedora-45)") arts) red))))
      (should (= 0 (car r)))
      (should (string-match-p "^run=7$" (cdr r))))
    ;; only the asked tarballs' jobs matter
    (let ((r (drgnx-ci-test--line '("tarball-fedora-45") (list (list "5" '("Linux (fedora-45)") '("tarball-fedora-45"))))))
      (should (= 0 (car r))))
    ;; a tarball job that failed, or an expired artifact: one error, exit 1, no run= line
    (dolist (runs (list (list (list "8" '("Linux (fedora-45)") arts))
                        (list (list "8" both '("tarball-fedora-45")))))
      (let ((r (drgnx-ci-test--line '("tarball-fedora-45" "tarball-macos") runs)))
        (should (= 1 (car r)))
        (should (string-match-p "::error::" (cdr r)))
        (should-not (string-match-p "^run=" (cdr r)))))))

(ert-deftest drgnx-ci/gui-runs-on-push-to-main ()
  (let ((gui (drgnx-ci-test--yml "gui.yml")) (tiers (drgnx-ci-test--yml "drgnx-tiers.yml")))
    (skip-unless (and gui tiers))
    (drgnx-ci-test--has gui "push:\n    branches: [main, \"ci/**\", \"!ci/joint/**\"]" "schedule:" "workflow_dispatch:"
                        "group: gui-${{ github.event_name }}-${{ github.ref == 'refs/heads/main' && github.run_id || github.ref }}")
    (drgnx-ci-test--has tiers "bin/drgnx test --container --ui" "bin/drgnx test --container --scenario"
                        "bin/drgnx test --container --perf" "DRGNX_PERF_CPU_FACTOR: \"2\""
                        "DRGNX_PERF_RESULTS: perf-results.json" "if: always()" "name: perf-results")
    ;; the pinned child-frame packages are in the image: the ui job fetches nothing for them
    (should-not (string-search "actions/cache" (drgnx-ci-test--job tiers "ui")))
    (should-not (string-search "childframe-elpa.sh" (drgnx-ci-test--job tiers "ui")))
    ;; the ui job leaves the :timing tests out too (no CI job runs one)
    (should (string-match-p (concat "DRGNX_TEST_NO_TIMING: \"1\"\n\\(?:          [A-Z_]+: .*\n\\)*"
                                    "        run: bin/drgnx test --container --ui")
                            (drgnx-ci-test--job tiers "ui")))))

(ert-deftest drgnx-ci/the-gui-image-bakes-the-pinned-child-frame-packages ()
  ;; The pins' sha256 is written in Containerfile.gui and checked at build: a pins file other than the one reviewed
  ;; fails the build (the image's tag hashes both files: test/container/image-tag.sh).
  (let ((file (drgnx-ci-test--file "test/container/Containerfile.gui"))
        (pins (drgnx-ci-test--file "test/container/childframe-packages.eld")))
    (skip-unless (and file pins))
    (should (string-search (secure-hash 'sha256 pins) file))
    (drgnx-ci-test--has file "childframe-elpa.sh /opt/childframe-elpa")))

(ert-deftest drgnx-ci/unit-jobs-rerun-and-skip-wall-clock ()
  (let ((tiers (drgnx-ci-test--yml "drgnx-tiers.yml")))
    (skip-unless tiers)
    (dolist (job '("unit" "no-lisp-writes" "macos"))
      (drgnx-ci-test--has (drgnx-ci-test--job tiers job) "DRGNX_TEST_RERUN: \"1\"" "DRGNX_TEST_NO_TIMING: \"1\"" "DRGNX_TEST_JOBS="))
    (should-not (string-search "(tag :timing)" tiers))
    (should-not (string-search "emacs-30" tiers))))

(ert-deftest drgnx-ci/the-modal-and-kitty-tiers-get-the-pinned-evil-and-kkp ()
  ;; without DRGNX_MODAL_ELPA / DRGNX_USER_ELPA the evil teardown, the modal isolation test and kitty's kkp tests skip,
  ;; and so do Quick Open's vertico rows, which test/no-skip.eld then fails: in the gate's job too
  (let ((tiers (drgnx-ci-test--yml "drgnx-tiers.yml")) (action (drgnx-ci-test--action "test-elpa")))
    (skip-unless (and tiers action))
    (drgnx-ci-test--has action "test/container/modal-elpa.sh" "echo \"DRGNX_MODAL_ELPA=" "echo \"DRGNX_USER_ELPA="
                        "etc/drgnx.lock.eld")
    (dolist (job '("unit" "no-lisp-writes" "ui" "tty"))
      (drgnx-ci-test--has (drgnx-ci-test--job tiers job) "uses: ./drgnx/.github/actions/test-elpa"))))

(ert-deftest drgnx-ci/the-timing-lane-judges-and-calibrates-in-the-image ()
  ;; the lane's own self-test: the verdict rules, and a calibration run in the tests' image (a CI runner has no Emacs)
  (let ((script (expand-file-name "test/timing-lane.sh" drgnx-ci-test--root)))
    (skip-unless (and (file-exists-p script) (executable-find "bash")))
    (with-temp-buffer
      (should (eql 0 (call-process "bash" nil t nil script "--self-test")))
      (should (string-search "timing-lane self-test: ok" (buffer-string))))))

(ert-deftest drgnx-ci/no-job-runs-on-a-moving-image-label ()
  ;; `ubuntu-latest' moves to 26.04 by 2026-11-19: every job names its image
  (dolist (yml (drgnx-ci-test--workflows-and-actions
                '("ci.yml" "macos.yml" "gui.yml" "drgnx-tiers.yml" "tty.yml" "images.yml" "bootstrap.yml" "runtime.yml")))
    (skip-unless yml)
    (should-not (string-match-p "runs-on:.*-latest" yml))))

(ert-deftest drgnx-ci/the-escape-suite-also-runs-on-26.04-without-the-sysctl ()
  (let* ((rt (drgnx-ci-test--yml "runtime.yml")) (job (and rt (drgnx-ci-test--job rt "escape-host"))))
    (skip-unless job)
    (drgnx-ci-test--has job "ubuntu-26.04, ubuntu-26.04-arm" "sudo install -m 0755 \"$RUNNER_TEMP/bwrap/bwrap\" /usr/bin/bwrap"
                        ;; this architecture's prebuilt bubblewrap, else the image's own recipe here
                        "bash .github/ci/ghcr.sh file \"$REF\" bwrap \"$RUNNER_TEMP/bwrap\""
                        "sh .github/ci/bwrap/build.sh \"$RUNNER_TEMP/bwrap\"")
    (drgnx-ci-test--has (drgnx-ci-test--file ".github/ci/bwrap/build.sh") "-Dtests=false" "bubblewrap-0.12.0.tar.xz")
    (drgnx-ci-test--has (drgnx-ci-test--file ".github/ci/bwrap/Containerfile") "RUN sh /tmp/build.sh /out" "FROM scratch")
    ;; the sysctl step is for the 24.04 legs only
    (let ((step (string-search "AppArmor's restriction lifted" job)))
      (should step)
      (should (string-search "if: ${{ !startsWith(matrix.os, 'ubuntu-26.04') }}" job step)))
    ;; one report and one cache per image
    (drgnx-ci-test--has job "escape-report-host-${{ matrix.os }}" "-escape-${{ matrix.os }}-")))

(ert-deftest drgnx-ci/the-escape-legs-run-the-browser-rows-in-a-vm ()
  ;; the agent browser's rows need Landlock ABI 9 (Linux 7.1), and the runners boot Linux 7.0 (ABI 8): the x64 escape
  ;; legs run them in a Fedora 45 VM under KVM, after the host sandbox lane, which leaves out exactly them (the names
  ;; their binary lists), so they neither fail there nor go unrun. The arm legs have no KVM, and emulated the guest
  ;; never answered; the rows' one arm64-specific part, the browser's seccomp filter, is installed for real by gleipnir's
  ;; own tests on the arm runner, so the arm legs skip the VM and say why
  (let* ((rt (drgnx-ci-test--yml "runtime.yml")) (job (and rt (drgnx-ci-test--job rt "escape-host")))
         (vm (drgnx-ci-test--file ".github/ci/browser-vm.sh")))
    (skip-unless job)
    (should vm)
    (drgnx-ci-test--has job "--test browser_sandboxed -- --list --format terse --ignored"
                        "bash .github/ci/browser-vm.sh up \"$RUNNER_TEMP/vm\""
                        "bash .github/ci/browser-vm.sh put \"$RUNNER_TEMP/vm\" /usr/bin/bwrap"
                        "'$bin' --ignored --test-threads 1")
    (let* ((lane (string-search "name: agent core, sandbox lane" job))
           (in-vm (string-search "name: the agent browser's rows in a Fedora 45 VM" job))
           (step (and in-vm (substring job in-vm (string-search "\n      - " job in-vm))))
           (arm (string-search "name: the agent browser's rows skip on arm64" job)))
      (should (and lane in-vm (< lane in-vm)))
      (should (string-search "runner.arch == 'X64'" step))
      (should (and arm (string-search "runner.arch == 'ARM64'" job arm))))
    ;; the x86_64 image is pinned by its sha256, which is checked; no arm64 image; the script is shellchecked
    (drgnx-ci-test--has vm "Fedora-Cloud-Base-Generic-45-" "sha256sum -c -" "x86_64)")
    (should-not (string-search "aarch64)" vm))
    (should (= 1 (length (drgnx-ci-test--matches "sha=\\([0-9a-f]\\{64\\}\\)" vm))))
    (drgnx-ci-test--has (drgnx-ci-test--yml "ci.yml") " .github/ci/browser-vm.sh ")))

(ert-deftest drgnx-ci/the-msrv-is-one-number ()
  ;; 1.95 since 2026-11-06 (wasmtime's 48 LTS needs it): the workspace's rust-version, the job that builds with it, and
  ;; install.sh's floor; the toolchain install.sh's private rustup brings is not older
  (let* ((rt (drgnx-ci-test--yml "runtime.yml")) (job (and rt (drgnx-ci-test--job rt "msrv")))
         (cargo (drgnx-ci-test--file "runtime/Cargo.toml")) (install (drgnx-ci-test--file "install.sh"))
         (private (and install (string-match "\nRUST_PRIVATE=\\([0-9.]+\\)\n" install) (match-string 1 install))))
    (skip-unless (and job cargo install))
    (should (string-search "\nrust-version = \"1.95\"\n" cargo))
    (drgnx-ci-test--has job "name: MSRV 1.95 builds\n" "-msrv195-mt1-1.95.0-" "rustup toolchain install 1.95.0 --profile minimal\n"
                        "cargo +1.95.0 build --locked --manifest-path runtime/Cargo.toml\n" "RUSTUP_TOOLCHAIN: 1.95.0\n")
    (should (string-search "\nRUST_MIN=1.95\n" install))
    (should private)
    (should (version<= "1.95" private))))

(ert-deftest drgnx-ci/the-rust-test-jobs-have-the-models-and-linux-has-llvmpipe ()
  ;; the tests that run the built-in model fail without DRGNX_TEST_MODELS, the GPU tests without DRGNX_TEST_ADAPTER
  ;; (never a skip): both workspace test jobs fetch the pinned files before `cargo test', and the Fedora 45 one runs
  ;; the shaders on llvmpipe; macOS has no adapter and ignores its GPU rows
  (let* ((rt (drgnx-ci-test--yml "runtime.yml")) (list (drgnx-ci-test--file ".github/ci/models.txt"))
         (packages (drgnx-ci-test--file "test/container/rust-packages.sh")))
    (skip-unless (and rt packages))
    (should list)
    (dolist (job '("linux" "macos"))
      (let* ((text (drgnx-ci-test--job rt job))
             (fetch (string-search "models.sh ../test-models\n" text))
             (test (string-search "--no-fail-fast --" text)))
        (drgnx-ci-test--has text "key: models-${{ hashFiles('.github/ci/models.txt') }}\n" "enableCrossOsArchive: true\n"
                            "echo \"DRGNX_TEST_MODELS=$(cd ../test-models && pwd)\" >> \"$GITHUB_ENV\"\n")
        (should (and fetch test (< fetch test)))
        (should (string-search "env.CACHE_SAVE == 'true' && steps.models.outputs.cache-hit != 'true'" text))))
    (should (string-match-p "DRGNX_TEST_ADAPTER: llvmpipe\n *run: cargo test --locked --no-fail-fast --workspace"
                            (drgnx-ci-test--job rt "linux")))
    (should-not (string-search "DRGNX_TEST_ADAPTER:" (drgnx-ci-test--job rt "macos")))
    (drgnx-ci-test--has packages "vulkan-loader mesa-vulkan-drivers")
    (should (string-search "https://huggingface.co/$repo/resolve/$rev/$name" (drgnx-ci-test--file ".github/ci/models.sh")))))

(ert-deftest drgnx-ci/the-runner-crates-are-checked-for-android-built-static-and-denied ()
  ;; forseti and sleipnir's protocol and sync are what jobq and the Android door take; the runner ships static (musl)
  (let* ((rt (drgnx-ci-test--yml "runtime.yml"))
         (android (and rt (drgnx-ci-test--job rt "android")))
         (containers (and rt (drgnx-ci-test--job rt "agent-containers")))
         (deny (and rt (drgnx-ci-test--job rt "deny"))))
    (skip-unless (and android containers deny))
    (drgnx-ci-test--has android
                        "--target aarch64-linux-android -p runstav -p draugr -p eitri -p gleipnir -p huginn -p heimdall -p drgnx-ratatoskr -p forseti\n"
                        "--target aarch64-linux-android -p sleipnir --no-default-features --features proto,sync\n"
                        "--all-targets -p runstav -p draugr -p eitri -p gleipnir -p mimir -p bifrost -p huginn -p heimdall -p forseti -- -D warnings\n"
                        "--all-targets -p sleipnir --no-default-features --features proto,sync -- -D warnings\n")
    (drgnx-ci-test--has containers
                        "-p sleipnir --no-default-features --features linux,sync --target x86_64-unknown-linux-musl --target-dir runtime/target/fwd\n")
    ;; deny reads the whole workspace (every crate under crates/) for every target the crates ship to
    (drgnx-ci-test--has deny "run: cargo-deny --manifest-path runtime/Cargo.toml check\n")
    (drgnx-ci-test--has (drgnx-ci-test--file "runtime/Cargo.toml") "members = [\"conformance\", \"crates/*\"]")
    (drgnx-ci-test--has (drgnx-ci-test--file "runtime/deny.toml") "\"x86_64-unknown-linux-musl\"" "\"aarch64-linux-android\"")))

(ert-deftest drgnx-ci/every-rust-timing-test-is-in-the-timing-list ()
  ;; the Rust tests marked #[ignore = "timing: …"] run in the timing lane's Rust step and nowhere else
  (let ((list-file (expand-file-name "test/timing-rust.txt" drgnx-ci-test--root))
        (src (expand-file-name "runtime" drgnx-ci-test--root)) found listed)
    (skip-unless (and (file-exists-p list-file) (file-directory-p src)))
    (dolist (f (directory-files-recursively src "\\.rs\\'"))
      (unless (string-match-p "/target/" f)
        (with-temp-buffer
          (insert-file-contents f)
          (while (re-search-forward "#\\[ignore = \"timing:[^]]*\\]\\s-*\\(?:async \\)?fn \\([a-z0-9_]+\\)" nil t)
            (push (match-string 1) found)))))
    (should found)
    (with-temp-buffer
      (insert-file-contents list-file)
      (while (not (eobp))
        (let ((line (buffer-substring (line-beginning-position) (line-end-position))))
          (unless (string-match-p "\\`\\s-*\\(#\\|\\'\\)" line)
            (push (nth 2 (split-string line)) listed)))
        (forward-line 1)))
    (should (equal (sort (copy-sequence found) #'string<) (sort (copy-sequence listed) #'string<)))))

(ert-deftest drgnx-ci/a-run-of-ignored-tests-skips-the-timing-rows ()
  ;; the timing rows are #[ignore] too: a `cargo test … -- --ignored' of a crate the timing list names skips that
  ;; crate's rows (a debug build on a shared runner judged a release budget: search/query p95 in the escape legs)
  (let ((rt (drgnx-ci-test--yml "runtime.yml")) (rows (drgnx-ci-test--file "test/timing-rust.txt")) timed (runs 0))
    (skip-unless (and rt rows))
    (dolist (line (split-string rows "\n" t))
      (unless (string-match-p "\\`\\s-*#" line) (push (car (split-string line)) timed)))
    (dolist (line (split-string rt "\n"))
      (when (and (string-match-p "cargo test .*-- --ignored" line) (string-match "-p \\([a-z0-9-]+\\)" line)
                 (member (match-string 1 line) timed))
        (setq runs (1+ runs))
        (should (string-suffix-p " $skips" line))))
    ;; two runs: the escape-host's sandbox lane and the macos job's ssh rows (--test macos)
    (should (= runs 2))
    (drgnx-ci-test--has (drgnx-ci-test--job rt "escape-host")
                        "skips=$(sed 's/#.*//' test/timing-rust.txt | awk '$1 == \"drgnx-ratatoskr\" { printf \" --skip %s\", $3 }')\n")))

(ert-deftest drgnx-ci/the-timing-job-runs-the-rust-timing-tests-report-only ()
  (let* ((tiers (drgnx-ci-test--yml "drgnx-tiers.yml")) (script (expand-file-name "test/timing-rust.sh" drgnx-ci-test--root)))
    (skip-unless (and tiers (file-exists-p script)))
    (drgnx-ci-test--has (drgnx-ci-test--job tiers "timing") "test/timing-rust.sh --report" "drgnx-timing-rust-report")
    (should (file-executable-p script))
    ;; report only: the script exits 0 whatever the tests said
    (with-temp-buffer (insert-file-contents script) (should (string-search "\nexit 0\n" (buffer-string))))))

(ert-deftest drgnx-ci/linux-unit-jobs-fail-a-det-test-that-uses-real-time ()
  ;; the runtime audit on and failing (docs/develop/harness.md, "The audit"): with the pre-flight off, CI is where a
  ;; det test that really sleeps, waits or starts a process turns red
  (let ((tiers (drgnx-ci-test--yml "drgnx-tiers.yml")))
    (skip-unless tiers)
    (dolist (job '("unit" "no-lisp-writes"))
      (drgnx-ci-test--has (drgnx-ci-test--job tiers job) "DRGNX_TEST_AUDIT: \"1\"" "DRGNX_TEST_AUDIT_FAIL: \"1\""))))

;; Hub chaos (docs/develop/ci.md, "Hub chaos"): the pre-flight's P3-hub step as a gating job, on every push.
(ert-deftest drgnx-ci/hub-chaos-runs-the-hub-files-per-seed-without-a-rerun ()
  (let ((tiers (drgnx-ci-test--yml "drgnx-tiers.yml")) (ci (drgnx-ci-test--yml "ci.yml"))
        (fixture (drgnx-ci-test--file "test/fixtures/hub-chaos-fixture.el")))
    (skip-unless (and tiers ci fixture))
    (let ((job (drgnx-ci-test--job tiers "hub-chaos")))
      ;; the files P3-hub selects, seeds 1 to 3, each seed's red named with its replay
      (drgnx-ci-test--has job "DRGNX_TEST_SELECTOR: '\"^drgnx-\\\\(hub-client\\\\|ai-gateway\\\\)/\"'"
                          "for seed in 1 2 3; do" "DRGNX_TEST_HUB_CHAOS=$seed" "bin/drgnx test --container"
                          "DRGNX_TEST_NO_TIMING: \"1\"" "::error title=Hub chaos seed $seed::"
                          ;; a seed that ran no test is red too
                          "s/^drgnx: [0-9]+ test files.*: ([0-9]+) tests,.*/\\1/p")
      ;; a red under chaos is a race: never rerun, never let off
      ;; after the seeds, the gated files once per swapped pair of lines across connections
      (drgnx-ci-test--has job "bin/drgnx test --orders --container")
      (should (< (string-search "for seed in 1 2 3; do" job) (string-search "bin/drgnx test --orders" job)))
      (should-not (string-search "DRGNX_TEST_RERUN" job))
      (should-not (string-search "selector: ${{" job)))
    ;; the fixture reads the variable the job sets
    (should (string-search "(getenv \"DRGNX_TEST_HUB_CHAOS\")" fixture))
    ;; in CI gate: a push runs it (the gate needs the tiers job, which fails when it does)
    (drgnx-ci-test--has (drgnx-ci-test--job ci "changes") "PUSH: rt-linux rt-msrv rt-escape rt-containers rt-android rt-deny rt-fuzz rt-macos unit no-lisp-writes hub-chaos\n")))

(ert-deftest drgnx-ci/macos-has-no-time-factor ()
  (dolist (f '("macos.yml" "drgnx-tiers.yml"))
    (let ((yml (drgnx-ci-test--yml f)))
      (skip-unless yml)
      (should-not (string-search "DRGNX_TEST_TIME_FACTOR" yml)))))

(ert-deftest drgnx-ci/macos-jobs-select-the-git-the-hub-trusts-before-their-tests ()
  ;; pattern D: the hub runs only the git of the developer dir xcode-select names and refuses the image's Xcode under
  ;; /Applications, so without the Command Line Tools no folder is a project and a task cannot be made
  (dolist (spec '(("drgnx-tiers.yml" "macos" "bin/drgnx test") ("runtime.yml" "macos" "cargo test")))
    (let ((yml (drgnx-ci-test--yml (nth 0 spec))))
      (skip-unless yml)
      (let* ((job (drgnx-ci-test--job yml (nth 1 spec)))
             (select (string-search "sudo xcode-select -s /Library/Developer/CommandLineTools" job))
             (tests (string-search (nth 2 spec) job)))
        (should select)
        (should tests)
        (should (< select tests))))))

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
  ;; (file, the gate's name line, the jobs that never run on a push, its push branches); a narrowed run's CI gate is
  ;; "CI gate (partial)", which branch protection never takes for the full one
  (dolist (spec '(("ci.yml" "${{ needs.changes.outputs.partial == 'true' && 'CI gate (partial)' || 'CI gate' }}" nil
                   "[main, \"ci/**\"]")
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
        ;; besides the gate's, a job waits only for the path filter and the images it pulls (no job waits on another it
        ;; does not take data from); a job's own key, not the gate action's `needs' input
        (dolist (n (drgnx-ci-test--matches "^    needs: \\[\\([^]]*\\)\\]$"
                                           (substring yml 0 (string-search "\n  gate:\n" yml))))
          (should (equal (split-string n ", *" t) '("changes" "images"))))
        (dolist (n (drgnx-ci-test--matches "^    needs: \\([^[\n]*\\)$" yml))
          (should (equal n "changes")))
        ;; the gate lets a job be skipped only when the path filter skipped it (or on a joint round, below)
        (dolist (line (drgnx-ci-test--matches "^ *\\(\\${{ needs.changes[^\n]*\\)$" gate))
          (should (string-match-p "\\`\\${{ needs.changes.result == 'success' && needs.changes.outputs.[a-z]+ == '' && '[a-z]+' || '' }}\\'"
                                  line)))))
    (drgnx-ci-test--has (drgnx-ci-test--action "gate")
                        "all(.value.result == \"success\" or (.value.result == \"skipped\" and")))

;; A joint round (both repositories change): drgnx's ci/joint/<name> branch runs only what does not need Emacs; the
;; tiers run once, in Nidhogg's run on its new build (docs/develop/ci.md, "Joint rounds").
(ert-deftest drgnx-ci/a-joint-round-skips-the-tiers-only-on-its-own-branch ()
  (let ((ci (drgnx-ci-test--yml "ci.yml")))
    (skip-unless ci)
    (drgnx-ci-test--has (drgnx-ci-test--job ci "tiers") "if: ${{ !cancelled() && !startsWith(github.ref, 'refs/heads/ci/joint/') && ")
    ;; the gate lets the tiers be skipped there and nowhere else, and nothing but the tiers
    (drgnx-ci-test--has (drgnx-ci-test--job ci "gate")
                        "allow-skipped: >-\n            ${{ startsWith(github.ref, 'refs/heads/ci/joint/') && 'tiers' || '' }}\n")
    (dolist (f '("gui.yml" "macos.yml"))
      (should-not (string-search "ci/joint/" (drgnx-ci-test--job (drgnx-ci-test--yml f) "gate"))))))

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
    ;; each actions/cache step: its key line hashes files (hashFiles), or is a save's that takes its restore's key;
    ;; a restore-keys line, when there is one, stops short of the hash only by a trailing part (never a bare OS
    ;; prefix), except where any older entry is safe: cargo's (cargo rebuilds what is stale; the key names the
    ;; toolchain) and the fuzz corpora (more inputs only reach further)
    (dolist (step (cdr (split-string yml "uses: actions/cache\\(?:/restore\\|/save\\)?@")))
      (let ((head (car (split-string step "\n *- " t))))
        (should (string-match "^ *key: \\(.*\\)$" head))
        (let ((key (match-string 1 head)))
          (should (or (string-search "hashFiles(" key)
                      (string-match-p "\\`\\${{ steps\\.[a-z-]+\\.outputs\\.cache-primary-key }}\\'" key))))
        (when (string-match "^ *restore-keys: \\(.*\\)$" head)
          (let ((rk (match-string 1 head)))
            (should (or (string-search "hashFiles(" rk)
                        (and (string-prefix-p "cargo-" rk)
                             (string-match-p "steps\\.rv\\.outputs\\.v\\|1\\.95\\.0\\|env\\.NIGHTLY" rk))
                        (string-prefix-p "fuzz-corpus-" rk)
                        ;; the registry: an older index and set of .crate files only lack crates cargo then fetches
                        (string-prefix-p "cargo-registry-" rk)))))))))

;; A cache is written only by a trusted run (a push or a manual run of main, the daily run, or, for the test ELPA and
;; the like, a pull request from a branch of this repository, whose cache GitHub scopes to its merge ref); runtime.yml's
;; and the test binaries' only by main.  Never by a ci/* branch or a fork's pull request, and the cargo caches are pruned first (.github/ci/cargo-prune.sh).
(defconst drgnx-ci-test--own-pr "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository")

(ert-deftest drgnx-ci/no-fork-pull-request-writes-a-cache ()
  (dolist (yml (drgnx-ci-test--workflows-and-actions
                '("ci.yml" "macos.yml" "gui.yml" "drgnx-tiers.yml" "tty.yml" "images.yml" "bootstrap.yml" "runtime.yml")))
    (skip-unless yml)
    (dolist (c (drgnx-ci-test--matches "if: \\(.*\\)\n *uses: actions/cache/save@" yml))
      (should (or (string-search "steps.prune.outcome == 'success'" c)
                  ;; runtime.yml's main-only flag (no pull request): the Nidhogg tarball
                  (and (string-search "env.CACHE_SAVE == 'true'" c) (not (string-search "CACHE_SAVE_PR" c)))
                  (string-search "github.event_name == 'schedule' || (github.event_name == 'push' && github.ref == 'refs/heads/main')" c))))
    ;; an action the tiers run on another commit than the workflow's own (Nidhogg's drgnx_ref) saves only its own
    (when (string-search "inputs.dir" yml)
      (dolist (c (append (drgnx-ci-test--matches "if: \\(.*\\)\n *uses: actions/cache/save@" yml)
                         (drgnx-ci-test--matches "id: prune\n *if: \\(.*\\)\n" yml)))
        (unless (string-search "steps.prune.outcome == 'success'" c)
          (should (string-search "steps.own.outputs.commit == (github.event.pull_request.head.sha || github.sha)" c))
          (should (string-search "github.repository == 'Black-Dragon-Foundation/drgnx'" c)))))
    ;; a pull request saves only when its head is a branch of this repository, or never (the main-only conditions)
    (dolist (c (append (drgnx-ci-test--matches "if: \\(.*\\)\n *uses: actions/cache/save@" yml)
                       (drgnx-ci-test--matches "id: prune\n *if: \\(.*\\)\n" yml)))
      (when (string-search "'pull_request'" c)
        (should (or (string-search drgnx-ci-test--own-pr c)
                    (string-search "github.event_name != 'pull_request' && github.ref == 'refs/heads/main'" c)))))
    (dolist (c (drgnx-ci-test--matches "id: prune\n *if: \\(.*\\)\n" yml))
      (should (or (string-search "env.CACHE_SAVE == 'true'" c)
                  (string-search "github.event_name != 'pull_request' && github.ref == 'refs/heads/main'" c)))
      ;; ci/* branches restore only
      (should-not (string-search "refs/heads/ci/" c))))
  (let ((rt (drgnx-ci-test--yml "runtime.yml")))
    (skip-unless rt)
    (drgnx-ci-test--has rt "CACHE_SAVE: ${{ github.event_name != 'pull_request' && github.ref == 'refs/heads/main' }}"
                        "CARGO_INCREMENTAL: \"0\"")
    ;; runtime.yml's caches are saved by main only: a pull request restores them and writes none
    (should-not (string-search "CACHE_SAVE_PR" rt))))

(ert-deftest drgnx-ci/the-fuzz-targets-are-built-once-for-the-four-shards ()
  ;; one build job (the only one with the fuzz cargo cache) uploads each shard's binaries; a shard downloads its own
  ;; and builds nothing
  (let* ((rt (drgnx-ci-test--yml "runtime.yml"))
         (build (and rt (drgnx-ci-test--job rt "fuzz-build"))) (shard (and rt (drgnx-ci-test--job rt "fuzz"))))
    (skip-unless (and build shard))
    (drgnx-ci-test--has build "cargo \"+$NIGHTLY\" fuzz build --fuzz-dir runtime/fuzz" "cargo-fuzz --version 0.13.2"
                        "key: cargo-${{ runner.os }}-fuzz-")
    (dotimes (n 4) (drgnx-ci-test--has build (format "name: fuzz-bins-%d\n" n)))
    (drgnx-ci-test--has shard "needs: fuzz-build" "name: fuzz-bins-${{ matrix.shard }}" "detect_odr_violation=0"
                        "\"-artifact_prefix=runtime/fuzz/artifacts/$target/\"" "\"runtime/fuzz/corpus/$target\"")
    (should-not (string-match-p "^ *\\(?:- \\)?\\(?:run: \\)?\\(?:cargo\\|rustup\\) \\|key: cargo-" shard))))

(ert-deftest drgnx-ci/the-macos-jobs-keep-the-nidhogg-release-tarball ()
  ;; both macOS jobs restore the pinned release by the hash of nidhogg.sh into NIDHOGG_DOWNLOADS, which nidhogg.sh
  ;; checks against the pin on every use; only main saves it, and Nidhogg's run (its own tarball) never touches it
  (let ((rt (drgnx-ci-test--yml "runtime.yml")) (tiers (drgnx-ci-test--yml "drgnx-tiers.yml"))
        (sh (drgnx-ci-test--file "test/container/nidhogg.sh")))
    (skip-unless (and rt tiers sh))
    (dolist (job (list (drgnx-ci-test--job rt "macos") (drgnx-ci-test--job tiers "macos")))
      (drgnx-ci-test--has job "path: ${{ runner.temp }}/nidhogg-downloads"
                          "key: nidhogg-release-${{ runner.os }}-${{ runner.arch }}-${{ hashFiles('"
                          "NIDHOGG_DOWNLOADS: ${{ runner.temp }}/nidhogg-downloads"
                          "key: ${{ steps.nidhogg-tarball.outputs.cache-primary-key }}"))
    (drgnx-ci-test--has (drgnx-ci-test--job tiers "macos") "if: ${{ !cancelled() && inputs.nidhogg == 'release' }}")
    (drgnx-ci-test--has sh "\"$NIDHOGG_DOWNLOADS/$tarball\"" "if verify >/dev/null 2>&1; then")))

(ert-deftest drgnx-ci/nidhogg-sh-never-uses-a-kept-tarball-that-fails-the-pin ()
  :tags '(:cond)
  ;; a kept tarball that does not match the pinned checksum is not used: nidhogg.sh downloads (curl, a stub that
  ;; fails here) and stops, never unpacking the kept one
  (skip-unless (executable-find "bash"))
  (let* ((sh (drgnx-ci-test--file "test/container/nidhogg.sh"))
         (version (and sh (string-match "^NIDHOGG_VERSION=\\([^ \n]+\\)" sh) (match-string 1 sh)))
         (tmp (make-temp-file "drgnx-nh-kept" t)) (bin (expand-file-name "bin" tmp))
         (kept (expand-file-name "kept" tmp)))
    (unwind-protect
        (progn
          (should version)
          (make-directory bin t) (make-directory kept t)
          (with-temp-file (expand-file-name (format "nidhogg-%s-macos-arm64.tar.xz" version) kept) (insert "not it"))
          (dolist (stub '("brew" "curl"))
            (with-temp-file (expand-file-name stub bin)
              (insert (if (equal stub "curl") "#!/bin/sh\necho curl-called >&2\nexit 7\n" "#!/bin/sh\nexit 0\n")))
            (set-file-modes (expand-file-name stub bin) #o755))
          (with-temp-buffer
            (let ((process-environment
                   (append (list (concat "PATH=" bin ":" (getenv "PATH")) (concat "RUNNER_TEMP=" tmp)
                                 (concat "TMPDIR=" tmp) (concat "NIDHOGG_DOWNLOADS=" kept) "GITHUB_ENV=")
                           process-environment)))
              (should-not (eq 0 (call-process "bash" nil t nil
                                              (expand-file-name "test/container/nidhogg.sh" drgnx-ci-test--root)
                                              "macos"))))
            (should (string-search "does not match its checksum: downloading it" (buffer-string)))
            (should (string-search "curl-called" (buffer-string)))
            (should-not (file-exists-p (expand-file-name "nidhogg" tmp)))))
      (delete-directory tmp t))))

(ert-deftest drgnx-ci/a-restored-target-sees-unchanged-files-as-old ()
  ;; every job that restores runtime/target gives the files their last commit's time before cargo runs (and has the
  ;; history for it), and records the commit its saved target was built from, only when every step before passed (a
  ;; half-done build stamped with its commit would pass its stale outputs off as fresh); the registry is its own entry
  (dolist (yml (list (drgnx-ci-test--yml "runtime.yml") (drgnx-ci-test--action "build-test-bins")))
    (skip-unless yml)
    (let ((restores (length (drgnx-ci-test--matches "uses: actions/cache/restore@[^\n]*\n *with:\n *path: \\(\\(?:\\${{ inputs\\.dir }}/\\)?runtime/target\\)\n" yml)))
          (stamps (drgnx-ci-test--matches "^\\(.*rev-parse HEAD > [^\n]*runtime/target/\\.drgnx-built-from.*\\)$" yml)))
      (should (> restores 0))
      (should (= restores (length (drgnx-ci-test--matches "\\(commit-times\\.sh runtime/target/\\.drgnx-built-from\\)" yml))))
      (should (= restores (length stamps)))
      (dolist (s stamps)
        (should (string-match-p "if \\[ \"\\${{ \\(?:job\\.status\\|steps\\.build\\.outcome\\) }}\" = success \\]; then" s)))
      (should-not (string-match-p "path: |\n *~/\\.cargo/registry/index\n *~/\\.cargo/registry/cache\n *\\(?:\\${{ inputs\\.dir }}/\\)?runtime/target" yml))))
  (should (string-search "fetch-depth: 0" (drgnx-ci-test--yml "runtime.yml")))
  (should (= 2 (length (drgnx-ci-test--matches "\\(fetch-depth: 0\\)" (drgnx-ci-test--yml "drgnx-tiers.yml"))))))

(ert-deftest drgnx-ci/a-pull-request-runs-its-head-not-the-merge-commit ()
  ;; main moves to a pull request's head by fast-forward: every checkout of the workflows a pull request runs takes the
  ;; head (on other events the expression is empty: the event's own commit), the path filter diffs the head, and the
  ;; head must descend from main's tip
  (dolist (name '("ci.yml" "macos.yml" "gui.yml" "runtime.yml" "drgnx-tiers.yml" "images.yml"))
    (let ((yml (drgnx-ci-test--yml name)))
      (skip-unless yml)
      (should (= (length (drgnx-ci-test--matches "\\(uses: actions/checkout@\\)" yml))
                 (length (drgnx-ci-test--matches "\\(ref: \\${{ \\(?:inputs\\.drgnx_ref || \\)?github\\.event\\.pull_request\\.head\\.sha }}\\)" yml))))))
  (dolist (name '("ci.yml" "macos.yml" "gui.yml"))
    (should (string-search "SHA: ${{ github.event.pull_request.head.sha || github.sha }}" (drgnx-ci-test--yml name))))
  ;; main's protection requires each of the three gates, and only a pull request's own run of a workflow counts
  ;; there (a dispatched run's gate does not), so every gated workflow runs on pull requests
  (dolist (name '("ci.yml" "macos.yml" "gui.yml"))
    (should (string-match-p "^  pull_request:" (drgnx-ci-test--yml name))))
  (drgnx-ci-test--has (drgnx-ci-test--yml "ci.yml")
                      "name: The pull request's head descends from the default branch's tip"
                      "compare/$tip...$HEAD_SHA"))

(ert-deftest drgnx-ci/a-drgnx-ref-is-checked-before-its-checkout-runs ()
  ;; a checkout of drgnx_ref (Nidhogg's run names it) is followed at once by the check that it is a commit on one of
  ;; drgnx's own branches, before any of the checkout's actions run: a pull request's or a fork's commit is refused
  (let ((tiers (drgnx-ci-test--yml "drgnx-tiers.yml")))
    (skip-unless tiers)
    (let ((checkouts (drgnx-ci-test--matches "ref: \\${{ inputs\\.drgnx_ref || github\\.event\\.pull_request\\.head\\.sha }}\n\\(\\(?:.*\n\\)\\{3\\}\\)" tiers)))
      (should (= (length checkouts) (length (drgnx-ci-test--matches "\\(uses: actions/checkout@\\)" tiers))))
      (dolist (c checkouts)
        (should (string-match-p "persist-credentials: false\n *- name: drgnx_ref is a commit on one of drgnx's own branches\n" c))))
    (should (string-search "refs/pull/*|pull/*)" tiers))
    (should (string-search "branch --contains \"$sha\"" tiers))))

(ert-deftest drgnx-ci/test-binaries-cache-is-saved-only-by-trusted-runs ()
  ;; drgnx-tiers.yml runs from Nidhogg too, with a drgnx commit Nidhogg names: only drgnx's own run of its own commit
  ;; writes the cache, so a drgnx_ref never reaches a default branch's cache scope
  (let ((bins (drgnx-ci-test--action "build-test-bins")))
    (skip-unless bins)
    (should-not (string-search "uses: actions/cache@" bins))
    ;; the registry's and the target's
    (should (= 2 (length (drgnx-ci-test--matches "uses: \\(actions/cache/restore@\\)" bins))))
    (should (string-match "id: prune\n *if: \\(.*\\)\n" bins))
    (let ((cond (match-string 1 bins)))
      (dolist (s (list "github.event_name != 'pull_request'" "github.ref == 'refs/heads/main'"
                       "steps.own.outputs.commit == (github.event.pull_request.head.sha || github.sha)"
                       "github.repository == 'Black-Dragon-Foundation/drgnx'"))
        (should (string-search s cond)))
      (should-not (string-search "nidhogg-31" cond)))
    ;; the binaries stay for the upload; the save takes the restore's key
    (drgnx-ci-test--has bins "cargo-prune.sh\" \"$DIR/runtime/Cargo.toml\" \"$DIR/runtime/target\" --keep-bins"
                        "key: ${{ steps.bins-cache.outputs.cache-primary-key }}")))

;; The path filter (docs/develop/ci.md, "Path filter"): its rules and the table's bite cases, and the workflows pass on
;; what it decided.
(ert-deftest drgnx-ci/the-path-filter-bites ()
  :tags '(:cond)
  (let ((script (expand-file-name ".github/ci/changes.sh" drgnx-ci-test--root))
        (table (expand-file-name ".github/ci/paths.txt" drgnx-ci-test--root)))
    (skip-unless (and (file-exists-p script) (executable-find "bash")))
    (with-temp-buffer
      (should (eq 0 (call-process "bash" nil t nil script table "--self-test")))
      (should (string-match-p "changes.sh self-test: ok" (buffer-string))))
    ;; every id of the table is a job of the workflow it names
    (let* ((text (drgnx-ci-test--file ".github/ci/paths.txt"))
           (ids (and (string-match "^jobs: \\(.*\\)$" text) (split-string (match-string 1 text))))
           (rt (drgnx-ci-test--yml "runtime.yml")) (tiers (drgnx-ci-test--yml "drgnx-tiers.yml")))
      (should (member "rt-linux" ids))
      (dolist (id ids)
        (if (string-prefix-p "rt-" id)
            (should (string-search (format "contains(format(' {0} ', inputs.only), ' %s ')" id) rt))
          (should (string-search (format "contains(format(' {0} ', inputs.tiers), ' %s ')" id) tiers)))))
    (dolist (spec '(("ci.yml" "CI gate") ("macos.yml" "macOS gate") ("gui.yml" "GUI tier gate")))
      (let ((yml (drgnx-ci-test--yml (car spec))))
        (drgnx-ci-test--has (drgnx-ci-test--job yml "changes")
                            "run: bash .github/ci/changes.sh .github/ci/paths.txt | tee -a \"$GITHUB_OUTPUT\""
                            (concat "GATE: " (cadr spec) "\n") "checks: read")))
    (drgnx-ci-test--has (drgnx-ci-test--yml "ci.yml") "only: ${{ needs.changes.outputs.runtime }}"
                        "selector: ${{ inputs.selector }}" "SELECTOR: ${{ inputs.selector }}" "REQUEST: ${{ inputs.jobs }}")))

(ert-deftest drgnx-ci/prebuilt-images-are-addressed-by-their-containerfile-hash ()
  (let ((images (drgnx-ci-test--yml "images.yml")) (tty (drgnx-ci-test--yml "tty.yml"))
        (action (drgnx-ci-test--action "test-image")) (tiers (drgnx-ci-test--yml "drgnx-tiers.yml"))
        (rt (drgnx-ci-test--yml "runtime.yml")))
    (skip-unless (and images tty action tiers rt))
    ;; the tiers' image: the one images.yml publishes for that Containerfile, under the same tag (image-tag.sh), pulled
    ;; by the digest GHCR holds for it
    (drgnx-ci-test--has action "tag=\"$(bash test/container/image-tag.sh \"test/container/$FILE\")\""
                        "image=\"$(bash .github/ci/ghcr.sh ref \"$NAME\" \"$tag\")\""
                        "podman pull -q \"$image\"" "echo \"$VAR=$base\"")
    (let ((pairs (drgnx-ci-test--matches "containerfile: \\([A-Za-z.]+\n *image: [a-z-]+\n *variable: [A-Z_]+\\)" tiers)))
      (should (= 9 (length pairs)))
      (dolist (p pairs)
        (should (string-match "\\`\\([A-Za-z.]+\\)\n *image: \\([a-z-]+\\)\n *variable: \\([A-Z_]+\\)\\'" p))
        (let ((file (match-string 1 p)) (name (match-string 2 p)) (var (match-string 3 p)))
          (should (string-match-p (format "- name: %s\n *file: test/container/%s\n" (regexp-quote name) (regexp-quote file))
                                  images))
          (should (equal var (pcase file ("Containerfile" "DRGNX_TEST_IMAGE") ("Containerfile.tty" "DRGNX_TEST_TTY_IMAGE")
                                    ("Containerfile.rust" "DRGNX_TEST_RUST_IMAGE") (_ "DRGNX_TEST_GUI_IMAGE")))))))
    ;; the terminal tier pulls its own through the same action
    (drgnx-ci-test--has (drgnx-ci-test--job tiers "tty") "containerfile: Containerfile.tty" "image: drgnx-test-tty"
                        "variable: DRGNX_TEST_TTY_IMAGE")
    (drgnx-ci-test--has images "tag=\"$(bash test/container/image-tag.sh \"$FILE\")${ARCH:+-$ARCH}\""
                        "podman push \"$image:$tag\"")
    ;; the runtime's Fedora 45 job runs in the Rust image (by digest) when there is one, else installs what it holds
    (drgnx-ci-test--has (drgnx-ci-test--job rt "images")
                        "ghcr.sh ref drgnx-test-rust \"$(bash test/container/image-tag.sh test/container/Containerfile.rust)\"")
    ;; the escape legs look their architecture's bubblewrap up themselves (no job to wait for)
    (drgnx-ci-test--has (drgnx-ci-test--job rt "escape-host")
                        "ghcr.sh ref drgnx-bwrap \"$(bash test/container/image-tag.sh .github/ci/bwrap/Containerfile)-$ARCH\"")
    (should-not (string-search "needs: images" (drgnx-ci-test--job rt "escape-host")))
    (drgnx-ci-test--has (drgnx-ci-test--job rt "linux")
                        "|| fromJSON('{\"image\":\"registry.fedoraproject.org/fedora:45\",\"options\":\"--init\"}') }}"
                        "run: sh test/container/rust-packages.sh" "if: ${{ env.PREBUILT == '' }}")))

(ert-deftest drgnx-ci/a-job-container-names-credentials-only-with-its-image ()
  ;; GitHub refuses a job whose container `credentials' come out empty ("Unexpected value ''") before any step runs:
  ;; the Rust job's fallback to plain Fedora (no prebuilt image for its inputs yet) never started. So no workflow
  ;; has a `credentials:' block, and the Rust job's container is one expression: the prebuilt image with a token to
  ;; pull it, else plain Fedora with none
  (dolist (f '("ci.yml" "macos.yml" "gui.yml" "drgnx-tiers.yml" "tty.yml" "images.yml" "bootstrap.yml" "runtime.yml"))
    (let ((yml (drgnx-ci-test--yml f)))
      (skip-unless yml)
      (should-not (string-match-p "^ +credentials:" yml))))
  (let* ((linux (drgnx-ci-test--job (drgnx-ci-test--yml "runtime.yml") "linux"))
         (start (string-search "\n    container: >-\n      ${{ needs.images.outputs.rust\n" linux))
         (end (and start (string-search " }}\n" linux start)))
         (expr (and end (substring linux start end)))
         (or-at (and expr (string-search "\n      || " expr))))
    (should or-at)
    (drgnx-ci-test--has (substring expr 0 or-at) "\"credentials\":{{\"username\":\"{1}\",\"password\":\"{2}\"}}"
                        "needs.images.outputs.rust, github.actor, github.token" "\"options\":\"--init\"")
    (should (equal (substring expr or-at)
                   "\n      || fromJSON('{\"image\":\"registry.fedoraproject.org/fedora:45\",\"options\":\"--init\"}')"))))

(ert-deftest drgnx-ci/test-images-are-built-on-published-bases ()
  ;; each test image adds Nidhogg and a few small files to a base of only the Fedora packages (test/container/base/);
  ;; images.yml publishes the bases first, then the images FROM the one it pulled, and the base's tag is part of the
  ;; image's (image-tag.sh reads the `# base:' line)
  (let ((images (drgnx-ci-test--yml "images.yml")))
    (skip-unless images)
    (dolist (c '(("Containerfile" "drgnx-base-test" "base/Containerfile")
                 ("Containerfile.gui" "drgnx-base-gui" "base/Containerfile.gui")
                 ("Containerfile.tty" "drgnx-base-tty" "base/Containerfile.tty")))
      (let ((top (drgnx-ci-test--file (concat "test/container/" (car c))))
            (base (drgnx-ci-test--file (concat "test/container/" (nth 2 c)))))
        (should top)
        (should base)
        (drgnx-ci-test--has top (format "# base: %s %s\n" (nth 1 c) (nth 2 c)) "ARG BASE\n" "FROM ${BASE}\n"
                            "COPY nidhogg.sh")
        (should-not (string-search "dnf" top))
        (drgnx-ci-test--has base "FROM registry.fedoraproject.org/fedora:" "dnf -y")
        (should-not (string-search "nidhogg" base))
        (should (string-match-p (format "- name: %s\n *file: test/container/%s\n" (regexp-quote (nth 1 c)) (regexp-quote (nth 2 c)))
                                images))))
    ;; the images are built after the bases, on the base GHCR holds for the checkout's base tag
    (drgnx-ci-test--has images "needs: bases" "BASE_FILE: ${{ matrix.base-file }}"
                        "--build-arg \"BASE=$base\"")))

(ert-deftest drgnx-ci/a-round-builds-each-missing-image-once-before-its-jobs ()
  ;; The tiers' and the runtime's images were built by every job of a round whose inputs changed (seven builds a run):
  ;; images.yml published only on main. Now ci.yml and gui.yml call it first, for this repository's own pushes and
  ;; pull requests (never a fork's: its token cannot push, and its jobs build their own), and the jobs that pull
  ;; images wait for it whatever it did; the gate lets it be skipped only on a fork's pull request
  (let ((images (drgnx-ci-test--yml "images.yml"))
        (own "if: ${{ github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository }}")
        (fork "${{ github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && 'images' || '' }}"))
    (skip-unless images)
    (drgnx-ci-test--has images "on:\n  workflow_call:\n" "workflow_dispatch:" "schedule:"
                        "group: images-${{ github.workflow }}-${{ github.ref }}")
    (should-not (string-match-p "^  \\(push\\|pull_request\\):" images))
    ;; a call or a manual run builds only the tags GHCR lacks; this workflow's own weekly run rebuilds them all (a
    ;; caller's nightly does not); main moves the `f45' name to a tag an earlier round built
    (drgnx-ci-test--has images
                        "REBUILD: ${{ github.workflow == 'Test images' && github.event_name == 'schedule' }}"
                        "if [ \"$REBUILD\" != true ] && have=\"$(bash .github/ci/ghcr.sh ref \"$NAME\" \"$tag\")\" && [ -n \"$have\" ]; then"
                        "podman tag \"$have\" \"$image:f45\"" "if [ \"$moving\" = refs/heads/main ]; then podman tag")
    (should-not (string-search "$EVENT" images))
    (dolist (spec '(("ci.yml" "runtime" "tiers") ("gui.yml" "tiers")))
      (let ((yml (drgnx-ci-test--yml (car spec))))
        (drgnx-ci-test--has (drgnx-ci-test--job yml "images") own "packages: write"
                            "uses: ./.github/workflows/images.yml")
        (dolist (j (cdr spec))
          (drgnx-ci-test--has (drgnx-ci-test--job yml j) "needs: [changes, images]" "if: ${{ !cancelled() && "))
        (drgnx-ci-test--has (drgnx-ci-test--job yml "gate") fork)
        ;; no other job may push: only the images job asks for packages: write
        (should (= 1 (length (drgnx-ci-test--matches "\\(packages: write\\)" yml))))))))

(ert-deftest drgnx-ci/an-image-tag-hashes-every-file-it-copies ()
  :tags '(:cond)
  ;; image-tag.sh over a made-up context: an edit of a copied file (one named, one in a copied directory) is a new
  ;; tag, an edit of a file nothing copies is not, and a missing source is an error, never a tag
  (let ((script (expand-file-name "test/container/image-tag.sh" drgnx-ci-test--root)))
    (skip-unless (and (file-exists-p script) (executable-find "bash")))
    (let* ((tmp (make-temp-file "drgnx-image-tag" t)) (cf (expand-file-name "Containerfile" tmp))
           (put (lambda (rel text) (with-temp-file (expand-file-name rel tmp) (insert text))))
           (tag (lambda ()
                  (with-temp-buffer
                    (list (call-process "bash" nil t nil script cf) (string-trim (buffer-string)))))))
      (unwind-protect
          (progn
            (make-directory (expand-file-name "d" tmp))
            (funcall put "Containerfile" "FROM x\nCOPY a \\\n  d /tmp/\nCOPY --from=build /y /z\n")
            (funcall put "a" "1") (funcall put "d/b" "2") (funcall put "other" "3")
            (let ((first (funcall tag)))
              (should (equal 0 (car first)))
              (should (string-match-p "\\`[0-9a-f]\\{16\\}\\'" (cadr first)))
              (funcall put "other" "4")
              (should (equal first (funcall tag)))
              (funcall put "d/b" "5")
              (let ((second (funcall tag)))
                (should-not (equal first second))
                (funcall put "a" "6")
                (should-not (equal second (funcall tag)))))
            (delete-file (expand-file-name "a" tmp))
            (should (equal 1 (car (funcall tag)))))
        (delete-directory tmp t)))))

;; The overlay (`nidhogg-artifact'): the run's own Nidhogg goes into the test image the same way the pinned release
;; goes into it, through test/container/nidhogg.sh, and never quietly falls back to the release.
(ert-deftest drgnx-ci/the-overlay-installs-the-run-s-tarball-with-nidhogg-sh ()
  (let ((action (drgnx-ci-test--action "test-image")))
    (skip-unless action)
    (drgnx-ci-test--has action "uses: actions/download-artifact@" "name: ${{ inputs.nidhogg-artifact }}"
                        "\"FROM $base\"" "RUN rm -rf /opt/nidhogg/* && bash /tmp/nidhogg.sh fedora-45 /tmp/nidhogg.tar.xz"
                        "expected one Nidhogg tarball" "echo \"$VAR=localhost/$NAME-nidhogg:run\"")))

(ert-deftest drgnx-ci/nidhogg-sh-installs-a-local-tarball-without-a-download ()
  :tags '(:cond)
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
