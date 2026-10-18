;;; jobs-systemd-args-test.el --- batch tests: the argument list of the systemd launcher (pure; no unit is created) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-jobs)

(defun drgnx-jobs-systemd-test--args (&rest args)
  "`drgnx-jobs--systemd-args' with PATH and HOME fixed."
  (let ((process-environment (append (list "PATH=/usr/bin:/bin" "HOME=/home/x") process-environment)))
    (apply #'drgnx-jobs--systemd-args args)))

(ert-deftest drgnx-jobs-systemd/user-unit-named-after-the-job ()
  (let ((a (drgnx-jobs-systemd-test--args "20260101-000000-1" "/work/dir" "echo hi" nil)))
    (should (equal (car a) "--user"))
    (should (member "--collect" a))
    (should (member "--unit=drgnx-job-20260101-000000-1" a))
    (should (member "--working-directory=/work/dir" a))
    (should (equal (last a 3) '("sh" "-c" "echo hi")))))

(ert-deftest drgnx-jobs-systemd/limits-only-when-asked ()
  (let ((plain (drgnx-jobs-systemd-test--args "j" "/w" "l" nil))
        (capped (drgnx-jobs-systemd-test--args "j" "/w" "l" nil nil "1G" 10)))
    (should-not (seq-some (lambda (x) (string-match-p "MemoryMax\\|MemorySwapMax\\|Nice" x)) plain))
    (should-not (member "-p" plain))
    (should (equal (seq-subseq capped (seq-position capped "-p") (+ 6 (seq-position capped "-p")))
                   '("-p" "MemoryMax=1G" "-p" "MemorySwapMax=0" "-p" "Nice=10")))
    (let ((only-nice (drgnx-jobs-systemd-test--args "j" "/w" "l" nil nil nil 5)))
      (should (member "Nice=5" only-nice))
      (should-not (seq-some (lambda (x) (string-match-p "Memory" x)) only-nice)))))

(ert-deftest drgnx-jobs-systemd/env-travels-by-name-never-by-value ()
  (let* ((a (drgnx-jobs-systemd-test--args "j" "/w" "l" '("API_KEY=sekrit-value" "OTHER=a=b") "T1"))
         (line (mapconcat #'identity a " ")))
    (should (member "--setenv=API_KEY" a))
    (should (member "--setenv=OTHER" a))
    (should-not (string-search "sekrit-value" line))
    (should-not (string-search "a=b" line))
    (should (member "--setenv=DRGNX_TASK=T1" a))
    (should (member "--setenv=PATH=/usr/bin:/bin" a))
    (should (member "--setenv=HOME=/home/x" a))
    (should-not (member "--setenv=DRGNX_TASK=T1" (drgnx-jobs-systemd-test--args "j" "/w" "l" nil)))))

(ert-deftest drgnx-jobs-systemd/a-working-directory-with-spaces-and-quotes-stays-one-argument ()
  ;; the list goes to `call-process' as is: no shell, so no quoting to get wrong
  (let* ((cwd "/tmp/my dir/it's \"x\" $HOME;rm")
         (a (drgnx-jobs-systemd-test--args "j" cwd "l" nil)))
    (should (member (concat "--working-directory=" cwd) a))
    (should (= 1 (seq-count (lambda (x) (string-prefix-p "--working-directory=" x)) a)))))

(ert-deftest drgnx-jobs-systemd/the-wrapper-line-is-the-last-argument-whole ()
  (let* ((line "p='/a b/pid'; echo $$ > \"$p\"; foo 'it'\\''s' > \"$l\" 2>&1 & wait $!")
         (a (drgnx-jobs-systemd-test--args "j" "/w" line nil nil "2G" 10)))
    ;; whole: one argument, not split or quoted; systemd would expand a `$', so each is doubled (JOBS-2)
    (should (equal (last a 3) (list "sh" "-c" (string-replace "$" "$$" line))))))

;;; jobs-systemd-args-test.el ends here
