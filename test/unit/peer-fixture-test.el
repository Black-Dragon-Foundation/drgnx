;;; peer-fixture-test.el --- scripted peers -*- lexical-binding: t -*-
;; test-class: cond
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/peer-fixture" drgnx-dir) nil t)

(ert-deftest drgnx-peer/one-write-one-filter-call ()
  (let* ((got nil)
         (peer (drgnx-test-peer-make :name "t" :filter (lambda (_p s) (push s got)))))
    (unwind-protect
        (progn
          (drgnx-test-peer-write peer "héllo, a long line\n")
          (should (equal got '("héllo, a long line\n")))
          (should (= 1 (drgnx-test-peer-calls peer)))
          (drgnx-test-peer-write peer "second")
          (should (equal got '("second" "héllo, a long line\n")))
          (should (= 2 (drgnx-test-peer-calls peer))))
      (drgnx-test-peer-close peer))))

;;; peer-fixture-test.el ends here
