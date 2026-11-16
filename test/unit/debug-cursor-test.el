;;; debug-cursor-test.el --- batch tests: the debug views draw no cursor box (audit S3) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug" drgnx-dir) nil t)

(ert-deftest drgnx-debug/the-run-and-debug-view-and-the-graph-show-no-cursor-box ()
  (dolist (mode '(drgnx-debug-view-mode drgnx-debug-heap-mode))
    (with-temp-buffer
      (funcall mode)
      (should-not cursor-type))))

(provide 'debug-cursor-test)
;;; debug-cursor-test.el ends here
