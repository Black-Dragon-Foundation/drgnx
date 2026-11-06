;;; affected.eld --- which test groups a change can affect (bin/drgnx test --affected)  -*- mode: lisp-data -*-
;; Read by core/drgnx-affected.el; docs/develop/testing.md, "Running only what a change affects".  Shaped like
;; .github/ci/paths.txt: a row is a glob (`*' matches across `/') and the actions it asks for; the first row that
;; matches a changed path wins, and a path no row matches runs everything.
;;
;; Actions:
;;   everything       every group (unit, rust-workspace, domr, ui, scenario, tty; perf stays out, see the doc)
;;   none             nothing (a note nothing builds, installs or reads)
;;   unit             the whole unit suite, and no other group
;;   names            the unit test files that name the changed file's feature (its `require', or its symbols as a
;;                    test name's prefix); none found: the whole unit suite
;;   self             the changed test file itself
;;   rules            the repo-wide rule tests (byte-compile warnings, key snapshots, lints, teardown)
;;   (docs FILE…)     the unit test files that read the docs
;;   (tests FILE…)    those unit test files
;;   (rust CRATE)     the crate and every crate in the workspace that depends on it (from `cargo metadata')
;;   rust-path        the crate the changed path sits in, and its dependents; no crate there: everything
;;   rust-workspace   `cargo test --workspace'
;;   domr             every conformance row;  domr-path: the group of test/conformance/GROUP/…
;;   ui scenario tty perf   that tier
;; A crate whose dependents include drgnx-ratatoskr or domr also asks for the conformance rows.
(:version 1
 :everything (unit rust-workspace domr ui scenario tty)
 ;; where a Lisp source file's feature (its file name) is looked for among the unit tests
 :lisp-roots ("core" "wb" "modules" "keys" "harness" "themes" "init")
 :test-dir "test/unit"
 ;; what a group runs (%f: a test file, %n: a crate, %g: a conformance group or *) and where, and the files whose
 ;; contents key its cache entry (`DIR/**': every file below; `lisp': :lisp-inputs; the group's own test file or
 ;; crate directories, with those of the crates it depends on, are added)
 :kinds
 ((unit          :run ("bin/drgnx" "test" "--container")
                 :inputs (lisp "test/unit/**"))
  (lisp          :run ("env" "DRGNX_TEST_ONLY=%f" "bin/drgnx" "test" "--container")
                 :inputs (lisp))
  (docs          :run ("env" "DRGNX_TEST_ONLY=%f" "bin/drgnx" "test" "--container")
                 :inputs (lisp "docs/**" "README.md"))
  (rules         :run ("env" "DRGNX_TEST_SELECTOR=\"^drgnx-build/\\\\|^drgnx-keys/\\\\|^drgnx-lint/\\\\|^drgnx-teardown/\""
                        "bin/drgnx" "test" "--container")
                 :inputs (lisp "test/unit/**"))
  (rust         :dir "runtime" :run ("cargo" "test" "-p" "%n")
                 :inputs ("runtime/Cargo.toml" "runtime/Cargo.lock" "core/**" "modules/**"))
  (rust-workspace :dir "runtime" :run ("cargo" "test" "--workspace")
                 :inputs ("runtime/**" "core/**" "modules/**"))
  (rust-rules    :dir "runtime"
                 :run ("sh" "-c" "cargo test -p skuld --test real_time_in_tests && cargo test -p drgnx-ratatoskr --test hub_reads_its_clock")
                 :inputs ("runtime/**"))
  (domr          :dir "runtime"
                 :run ("sh" "-c" "cargo build -p domr -p drgnx-ratatoskr && target/debug/domr --hub-bin target/debug/ratatoskr --scenarios ../test/conformance --only '%g'")
                 :inputs ("runtime/**" "core/**" "test/conformance/**"))
  (ui            :run ("bin/drgnx" "test" "--container" "--ui")
                 :inputs (lisp "test/ui/**" "test/live/**"))
  (scenario      :run ("bin/drgnx" "test" "--container" "--scenario")
                 :inputs (lisp "test/scenario/**"))
  (tty           :run ("bin/drgnx" "test" "--container" "--tty")
                 :inputs (lisp "test/tty/**"))
  (perf          :run ("bin/drgnx" "test" "--container" "--perf")
                 :inputs (lisp "test/perf/**")))
 ;; the files every Lisp group reads
 :lisp-inputs ("core/**" "wb/**" "modules/**" "keys/**" "harness/**" "themes/**" "init/**" "settings/**" "etc/**"
               "test/fixtures/**" "test/support/**" "test/*.eld" "bin/drgnx")
 :rules
 (
  ;; notes nothing builds, installs or reads
  ("SECURITY.md" none)
  ("LICENSE" none)
  ("LICENSES/*" none)
  ("runtime/deny.toml" none)
  ;; the model fuzzing targets are their own workspace, built by the fuzz job only
  ("runtime/fuzz/*" none)
  ;; docs: the tests that read them (generated references, the guide's examples, the settings and config pages)
  ("docs/develop/hub.md" (rust drgnx-ratatoskr) (docs "test/unit/config-doc-test.el" "test/unit/settings-doc-test.el"))
  ("docs/*" (docs "test/unit/config-doc-test.el" "test/unit/settings-doc-test.el"))
  ("README.md" (docs "test/unit/config-doc-test.el" "test/unit/settings-doc-test.el"))
  ;; CI's own files are read by the unit suite (ci-workflows-test.el and the like)
  (".github/*" unit)
  (".githooks/*" unit)
  (".gitignore" unit)
  ;; the command, installer, harness, settings, lock, images and test support: everything reads them
  ("bin/*" everything)
  ("install.sh" everything)
  ("harness/*" everything)
  ("settings/*" everything)
  ("etc/drgnx.lock.eld" everything)
  ("test/container/*" everything)
  ("test/support/*" everything)
  ("test/fixtures/*" everything)
  ;; Rust
  ("runtime/Cargo.toml" rust-workspace domr rust-rules)
  ("runtime/Cargo.lock" rust-workspace domr rust-rules)
  ("runtime/protocol/*" rust-workspace domr rust-rules)
  ("runtime/crates/*" rust-path rust-rules)
  ("runtime/conformance/*" rust-path rust-rules)
  ("runtime/*" everything)
  ;; this table and the tool that reads it: nothing else reads either, so the tool's own tests
  ("test/affected.eld" (tests "test/unit/affected-test.el"))
  ("core/drgnx-affected.el" (tests "test/unit/affected-test.el") rules)
  ;; Lisp: the tests that name the file; the Rust tests read core/ and modules/ (the doctor, the launch rows)
  ("core/*" names rules (rust drgnx-ratatoskr))
  ("modules/ui/*" names rules (rust drgnx-ratatoskr) ui scenario)
  ("modules/*" names rules (rust drgnx-ratatoskr))
  ;; UI paths: the GUI and scenario tiers too
  ("wb/*" names rules ui scenario)
  ("themes/*" names rules ui scenario)
  ("etc/icons/*" ui scenario)
  ("keys/*" names rules ui scenario)
  ("init/*" names rules ui scenario)
  ("etc/*" unit)
  ;; tests: their own tier, and the rule tests (the lints read every test file)
  ("test/conformance/*" domr-path)
  ("test/unit/*" self rules)
  ("test/ui/*" ui rules)
  ("test/live/*" ui rules)
  ("test/scenario/*" scenario rules)
  ("test/tty/*" tty rules)
  ("test/perf/*" perf rules)
  ;; any other test/ file (the suite's lists, timing rows, bench, install and bootstrap) and any other path
  ;; matches no row: everything
  ))
