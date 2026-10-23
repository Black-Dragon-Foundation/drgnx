;;; huginn-diff-test.el --- batch tests: Nidhogg's reader against huginn's, the editor's side of the differential -*- lexical-binding: t -*-
;; The committed dumps (test/fixtures/huginn/corpus/accept/*.json, random-seeded.dump) are what Emacs's `read' (behind
;; core/drgnx-file.el) gave; huginn's tests (runtime/crates/huginn/tests/differential.rs) hold huginn to them.  Here
;; Emacs regenerates them and must agree with the files (no drift), and a fresh seed is read by both live: the
;; `dump' example of huginn is run on a file of random data (DRGNX_HUGINN_DUMP names the built binary).
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'drgnx-file)
(load (expand-file-name "test/fixtures/huginn/gen.el" drgnx-dir) nil t)

(defun huginn-diff-test--slurp (file)
  "FILE's text as UTF-8."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
    (buffer-string)))

(defun huginn-diff-test--float-value (text)
  "The float a dump's TEXT stands for (Emacs's or Rust's spelling)."
  (car (read-from-string text)))

(defun huginn-diff-test--same (a b)
  "Whether the dumps A and B (parsed JSON, arrays as lists) agree: floats by value (NaN equals NaN, -0.0 is not 0.0)."
  (pcase (list a b)
    (`(("float" ,x) ("float" ,y))
     (let ((fx (huginn-diff-test--float-value x)) (fy (huginn-diff-test--float-value y)))
       (or (and (isnan fx) (isnan fy)) (equal fx fy))))
    (`(,(pred consp) ,(pred consp))
     (and (= (length a) (length b)) (cl-every #'huginn-diff-test--same a b)))
    (_ (equal a b))))

(defun huginn-diff-test--parse (json)
  "The JSON string as lists and strings."
  (json-parse-string json :array-type 'list))

(ert-deftest drgnx-huginn/committed-dumps-are-current ()
  "Every accept file's .json and the random file's dumps are what Emacs reads now; every refuse file is refused
here (but for the listed divergence, kind CharName, which Emacs reads); no dump without its source."
  (let ((bad nil) (accept (huginn-gen--corpus-files "accept")) (refuse (huginn-gen--corpus-files "refuse")))
    (should (>= (length accept) 40))
    (should (>= (length refuse) 40))
    (dolist (f accept)
      (let ((json (concat (file-name-sans-extension f) ".json")))
        (cond ((not (file-exists-p json)) (push (format "%s: no .json" f) bad))
              ((not (equal (huginn-gen-file-dump f) (string-trim-right (huginn-diff-test--slurp json))))
               (push (format "%s: the dump is stale" f) bad)))))
    (dolist (j (directory-files (huginn-gen--path "corpus/accept") t "\\.json\\'"))
      (unless (file-exists-p (concat (file-name-sans-extension j) ".el")) (push (format "%s: no .el" j) bad)))
    (dolist (f refuse)
      (let ((r (huginn-gen-file-parse f)))
        (if (equal (huginn-gen-refuse-kind f) "CharName")
            (unless (memq (car r) '(ok absent)) (push (format "%s: Emacs should read it" f) bad))
          (unless (eq (car r) 'problem) (push (format "%s: Emacs should refuse it" f) bad)))))
    (let ((want (split-string (huginn-diff-test--slurp (huginn-gen--path "random-seeded.dump")) "\n" t))
          (got (huginn-gen-dump-lines (huginn-gen--path "random-seeded.eld"))))
      (unless (equal want got) (push "random-seeded.dump is stale" bad)))
    (should-not bad)))

(ert-deftest drgnx-huginn/differential-fresh-seed ()
  "A seed from the clock: 500 random data, read by Emacs here and by huginn's dump example; the dumps agree."
  (let ((dump (getenv "DRGNX_HUGINN_DUMP")))
    (unless (and dump (file-executable-p dump))
      (ert-skip "DRGNX_HUGINN_DUMP is not set to the built huginn dump example (CI sets it)"))
    (let* ((seed (floor (float-time)))
           (rows (huginn-gen-random-data seed 500))
           (file (make-temp-file "huginn-diff" nil ".eld")))
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (concat (mapconcat #'car rows "\n") "\n") nil file nil 'silent))
            (let ((lines (with-temp-buffer
                           (should (eq 0 (call-process dump nil t nil file)))
                           (split-string (buffer-string) "\n" t))))
              (ert-info ((format "seed %d" seed))
                (should (= (length lines) (length rows)))
                (cl-loop for row in rows for line in lines for i from 0
                         do (ert-info ((format "datum %d: %s" i (car row)))
                              (should (huginn-diff-test--same (huginn-diff-test--parse (huginn-gen-dump (cdr row)))
                                                              (huginn-diff-test--parse line))))))))
        (delete-file file)))))

;;; huginn-diff-test.el ends here
